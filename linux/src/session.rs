//! Session controller: state transitions, cancellation, timeouts, cleanup.
//!
//! One push-to-talk gesture is one session. Every asynchronous result carries the
//! session id it belongs to, so a late transcript from a cancelled, timed out, or
//! finished session can never reach the output adapter.

use std::collections::VecDeque;
use std::sync::Arc;
use std::time::Duration;

use tokio::sync::mpsc::error::TrySendError;
use tokio::sync::{mpsc, oneshot};

use crate::audio::{AudioFactory, CaptureChild};
use crate::config::{CHUNK_BYTES, Config};
use crate::ipc::{Response, State};
use crate::log;
use crate::output::{Delivery, TextOutput, deliver};
use crate::transport::{TranscriptEvent, TranscriptionTransport, TransportFactory};

/// How many raw capture buffers get a level line. One buffer is roughly 170 ms,
/// so this covers the first couple of seconds of a session.
const LEVEL_SAMPLES: u32 = 12;

/// A CLI command forwarded to the controller.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Command {
    Start,
    Stop,
    Cancel,
    Status,
}

struct CommandRequest {
    command: Command,
    reply: oneshot::Sender<Response>,
}

/// Client side of the controller channel.
#[derive(Clone)]
pub struct ControllerHandle {
    sender: mpsc::Sender<CommandRequest>,
}

impl ControllerHandle {
    /// Sends a command and waits for its acknowledgement. The acknowledgement
    /// never waits for transcription to finish.
    pub async fn send(&self, command: Command) -> Response {
        let (reply, receiver) = oneshot::channel();
        if self
            .sender
            .send(CommandRequest { command, reply })
            .await
            .is_err()
        {
            return Response::error(State::Idle, "the session controller has stopped");
        }
        receiver.await.unwrap_or_else(|_| {
            Response::error(State::Idle, "the session controller dropped the request")
        })
    }
}

/// Everything the controller needs, with each boundary replaceable in tests.
pub struct ControllerDeps {
    pub config: Config,
    pub audio: Arc<dyn AudioFactory>,
    pub transport: Arc<dyn TransportFactory>,
    pub output: Arc<dyn TextOutput>,
}

/// Starts the controller task.
pub fn spawn(deps: ControllerDeps) -> ControllerHandle {
    let (sender, commands) = mpsc::channel(64);
    let (events, incoming) = mpsc::channel(512);
    tokio::spawn(async move {
        Actor {
            deps,
            events,
            session: None,
            state: State::Idle,
            next_session: 0,
        }
        .run(commands, incoming)
        .await;
    });
    ControllerHandle { sender }
}

/// Internal event. Each variant names the session it belongs to.
enum Event {
    Ready(String),
    Audio(String, Vec<u8>),
    AudioEnded(String),
    Interim(String),
    Final(String, String),
    TransportFailed(String, String),
    TransportClosed(String),
    Tick(String),
    RecordingLimit(String),
    SetupTimeout(String),
    FinalizationTimeout(String),
}

/// Message from the controller to the transport writer task.
enum TransportCommand {
    Audio(Vec<u8>),
    Commit,
}

struct Session {
    id: String,
    capture: Option<Box<dyn CaptureChild>>,
    transport: mpsc::Sender<TransportCommand>,
    transport_task: tokio::task::JoinHandle<()>,
    ready: bool,
    capture_ended: bool,
    committed: bool,
    first_audio_logged: bool,
    levels_logged: u32,
    pending: VecDeque<Vec<u8>>,
    frame: Vec<u8>,
    /// Dropping this ends the per-session flush ticker.
    _ticker: oneshot::Sender<()>,
}

impl Drop for Session {
    fn drop(&mut self) {
        self.transport_task.abort();
    }
}

impl Session {
    /// Audio captured but not yet handed to the transport.
    fn unsent_bytes(&self) -> usize {
        self.pending.iter().map(Vec::len).sum::<usize>() + self.frame.len()
    }
}

struct Actor {
    deps: ControllerDeps,
    events: mpsc::Sender<Event>,
    session: Option<Session>,
    state: State,
    next_session: u64,
}

impl Actor {
    async fn run(
        mut self,
        mut commands: mpsc::Receiver<CommandRequest>,
        mut incoming: mpsc::Receiver<Event>,
    ) {
        loop {
            tokio::select! {
                command = commands.recv() => match command {
                    Some(request) => self.handle_command(request).await,
                    None => break,
                },
                event = incoming.recv() => match event {
                    Some(event) => self.handle_event(event).await,
                    None => break,
                },
            }
        }
    }

    async fn handle_command(&mut self, request: CommandRequest) {
        let response = match request.command {
            Command::Status => self.status(),
            Command::Start => self.start().await,
            Command::Stop => self.stop(),
            Command::Cancel => self.cancel(),
        };
        let _ = request.reply.send(response);
    }

    fn status(&self) -> Response {
        match &self.session {
            Some(session) => Response::ok(self.state).with_session(session.id.clone()),
            None => Response::ok(self.state),
        }
    }

    async fn start(&mut self) -> Response {
        match self.state {
            // Harmless: a repeated press must not disturb a running recording.
            State::Recording => Response::ok(State::Recording),
            State::Finalizing => Response::error(
                State::Finalizing,
                "a previous session is still finalizing; wait for it or cancel it",
            ),
            State::Idle => match self.begin() {
                Ok(session) => {
                    let id = session.id.clone();
                    self.session = Some(session);
                    self.state = State::Recording;
                    log::info(&format!("{id}: recording"));
                    Response::ok(State::Recording).with_session(id)
                }
                Err(error) => {
                    log::info(&format!("could not start recording: {error}"));
                    Response::error(State::Idle, error)
                }
            },
        }
    }

    fn begin(&mut self) -> Result<Session, String> {
        if self.deps.config.api_key.is_none() {
            return Err("OPENAI_API_KEY is not set".to_string());
        }
        self.next_session += 1;
        let id = format!("s{}", self.next_session);

        // Capture and the provider connection start together; the controller
        // buffers audio until the provider session reports that it is ready.
        let capture = self
            .deps
            .audio
            .create()
            .spawn()
            .map_err(|error| format!("could not start microphone capture: {error}"))?;
        let transport = self.deps.transport.create();
        let (transport_sender, transport_commands) = mpsc::channel(16);
        let transport_task = tokio::spawn(transport_task(
            id.clone(),
            transport,
            transport_commands,
            self.events.clone(),
        ));
        tokio::spawn(audio_task(id.clone(), capture.chunks, self.events.clone()));
        tokio::spawn(fire_after(
            self.deps.config.setup_timeout,
            Event::SetupTimeout(id.clone()),
            self.events.clone(),
        ));
        tokio::spawn(fire_after(
            self.deps.config.recording_limit,
            Event::RecordingLimit(id.clone()),
            self.events.clone(),
        ));
        // The sender lives in the session, so dropping the session ends the ticker.
        let (ticker_stop, ticker) = oneshot::channel();
        tokio::spawn(ticker_task(id.clone(), self.events.clone(), ticker));

        Ok(Session {
            id,
            capture: Some(capture.child),
            transport: transport_sender,
            transport_task,
            ready: false,
            capture_ended: false,
            committed: false,
            first_audio_logged: false,
            levels_logged: 0,
            pending: VecDeque::new(),
            frame: Vec::new(),
            _ticker: ticker_stop,
        })
    }

    /// Stop is acknowledged immediately; capture drains and the commit is sent
    /// from the event loop so release never waits for the network.
    fn stop(&mut self) -> Response {
        match self.state {
            // Harmless: a release without a press must do nothing.
            State::Idle => Response::ok(State::Idle),
            State::Finalizing => Response::ok(State::Finalizing),
            State::Recording => {
                if let Some(session) = self.session.as_mut()
                    && let Some(child) = session.capture.as_mut()
                {
                    child.request_stop();
                }
                if let Some(session) = &self.session {
                    tokio::spawn(fire_after(
                        self.deps.config.finalization_timeout,
                        Event::FinalizationTimeout(session.id.clone()),
                        self.events.clone(),
                    ));
                }
                self.state = State::Finalizing;
                log::info("capture stopping; waiting for the final transcript");
                Response::ok(State::Finalizing)
            }
        }
    }

    fn cancel(&mut self) -> Response {
        if self.session.is_none() {
            return Response::ok(State::Idle);
        }
        log::info("cancelling the session");
        self.discard();
        Response::ok(State::Idle)
    }

    /// Drops the session. Late events for the discarded id are ignored because
    /// no session carries that id any more.
    fn discard(&mut self) {
        if let Some(mut session) = self.session.take()
            && let Some(child) = session.capture.as_mut()
        {
            child.kill();
            child.try_reap();
            // Session::drop aborts all network work, including queued commands.
        }
        self.state = State::Idle;
    }

    async fn abort(&mut self, reason: &str) {
        let had_session = self.session.is_some();
        self.discard();
        if had_session {
            log::info(reason);
            let output = self.deps.output.clone();
            let message = format!("Whistt: {reason}");
            tokio::task::spawn_blocking(move || {
                let _ = output.notify(&message);
            });
        }
    }

    fn is_current(&self, id: &str) -> bool {
        self.session
            .as_ref()
            .is_some_and(|session| session.id == id)
    }

    async fn handle_event(&mut self, event: Event) {
        match event {
            Event::Ready(id) => {
                if !self.is_current(&id) {
                    return;
                }
                if let Some(session) = self.session.as_mut() {
                    session.ready = true;
                }
                log::debug(&format!("{id}: provider session ready"));
                self.pump().await;
            }
            Event::Audio(id, bytes) => {
                if !self.is_current(&id) {
                    return;
                }
                self.ingest(bytes).await;
            }
            Event::AudioEnded(id) => {
                if !self.is_current(&id) {
                    return;
                }
                if let Some(session) = self.session.as_mut()
                    && let Some(child) = session.capture.as_mut()
                {
                    child.try_reap();
                }
                if self.state == State::Recording {
                    // Capture died without a release.
                    self.abort("microphone capture stopped unexpectedly").await;
                    return;
                }
                if let Some(session) = self.session.as_mut() {
                    session.capture_ended = true;
                }
                self.finish_capture().await;
            }
            // Interim hypotheses are revisable, so they stay internal.
            Event::Interim(id) => {
                if self.is_current(&id) {
                    log::debug(&format!(
                        "{id}: interim transcript received; not delivering it"
                    ));
                }
            }
            Event::Final(id, text) => self.deliver_final(id, text).await,
            Event::TransportFailed(id, message) => {
                if !self.is_current(&id) {
                    return;
                }
                self.abort(&format!("transcription failed: {message}"))
                    .await;
            }
            Event::TransportClosed(id) => {
                if !self.is_current(&id) {
                    return;
                }
                self.abort("the transcription connection closed before a final transcript arrived")
                    .await;
            }
            Event::Tick(id) => {
                if self.is_current(&id) {
                    self.pump().await;
                }
            }
            Event::RecordingLimit(id) => {
                if !self.is_current(&id) || self.state != State::Recording {
                    return;
                }
                let seconds = self.deps.config.recording_limit.as_secs();
                self.abort(&format!("the {seconds} second recording limit was reached"))
                    .await;
            }
            Event::SetupTimeout(id) => {
                if !self.is_current(&id) {
                    return;
                }
                let ready = self.session.as_ref().is_some_and(|session| session.ready);
                if !ready {
                    self.abort("the transcription connection was not ready in time")
                        .await;
                }
            }
            Event::FinalizationTimeout(id) => {
                if !self.is_current(&id) || self.state != State::Finalizing {
                    return;
                }
                self.abort("timed out waiting for the final transcript")
                    .await;
            }
        }
    }

    /// Splits capture bytes into whole 100 ms chunks, preserving sample
    /// boundaries. Nothing is dropped: audio waits in `pending` until the
    /// transport accepts it, and exceeding the bound aborts the session.
    async fn ingest(&mut self, bytes: Vec<u8>) {
        let mut overflow = false;
        let mut first_audio = false;
        let mut sample_level = None;
        if let Some(session) = self.session.as_mut() {
            if !session.first_audio_logged {
                session.first_audio_logged = true;
                first_audio = true;
            }
            if session.levels_logged < LEVEL_SAMPLES {
                session.levels_logged += 1;
                sample_level = Some((session.levels_logged, pcm16_level(&bytes)));
            }
            session.frame.extend_from_slice(&bytes);
            while session.frame.len() >= CHUNK_BYTES {
                let chunk: Vec<u8> = session.frame.drain(..CHUNK_BYTES).collect();
                session.pending.push_back(chunk);
            }
            overflow = session.unsent_bytes() > self.deps.config.max_unsent_bytes();
        }
        if overflow {
            let seconds = self.deps.config.max_unsent_audio.as_secs();
            self.abort(&format!(
                "more than {seconds} seconds of audio could not be sent"
            ))
            .await;
            return;
        }
        if first_audio && let Some(session) = self.session.as_ref() {
            // The gap between "recording" and this line is what a speaker clips
            // if they start talking the moment the key goes down.
            log::debug(&format!(
                "{}: first audio byte received from the microphone",
                session.id
            ));
        }
        if let Some((index, (peak, rms))) = sample_level
            && let Some(session) = self.session.as_ref()
        {
            // Levels, never audio, so a clipped onset can be told apart from a
            // microphone that was still silent when the speaker started.
            log::debug(&format!(
                "{}: capture level {index} peak {peak} rms {rms}",
                session.id
            ));
        }
        self.pump().await;
    }

    /// Flushes the trailing partial chunk once capture has ended.
    async fn finish_capture(&mut self) {
        if let Some(session) = self.session.as_mut()
            && !session.frame.is_empty()
        {
            let mut tail = std::mem::take(&mut session.frame);
            if tail.len() % 2 != 0 {
                // A half sample cannot exist in an s16 stream; drop the byte
                // rather than send something the provider cannot decode.
                tail.pop();
            }
            if !tail.is_empty() {
                session.pending.push_back(tail);
            }
        }
        self.pump().await;
    }

    /// Moves buffered audio to the transport and commits exactly once, after
    /// capture has drained and every byte has been queued.
    async fn pump(&mut self) {
        let mut committed = false;
        let mut closed = false;
        if let Some(session) = self.session.as_mut() {
            // Audio may only reach the provider once the session is configured;
            // until then it waits in `pending`, bounded by the caller's limit.
            if session.ready {
                while let Some(chunk) = session.pending.pop_front() {
                    match session.transport.try_send(TransportCommand::Audio(chunk)) {
                        Ok(()) => {}
                        Err(TrySendError::Full(TransportCommand::Audio(chunk))) => {
                            // The socket is behind; keep the audio and retry later.
                            session.pending.push_front(chunk);
                            break;
                        }
                        Err(TrySendError::Full(_)) => break,
                        Err(TrySendError::Closed(_)) => {
                            closed = true;
                            break;
                        }
                    }
                }
            }
            if !closed
                && session.ready
                && session.capture_ended
                && session.pending.is_empty()
                && !session.committed
            {
                match session.transport.try_send(TransportCommand::Commit) {
                    Ok(()) => {
                        session.committed = true;
                        committed = true;
                    }
                    Err(TrySendError::Full(_)) => {}
                    Err(TrySendError::Closed(_)) => closed = true,
                }
            }
        }
        if closed {
            self.abort("the transcription connection closed").await;
            return;
        }
        if committed {
            let id = self
                .session
                .as_ref()
                .map(|session| session.id.clone())
                .unwrap_or_default();
            log::debug(&format!(
                "{id}: turn committed; waiting for the final transcript"
            ));
        }
    }

    async fn deliver_final(&mut self, id: String, text: String) {
        if !self.is_current(&id) {
            log::debug(&format!("{id}: ignoring a stale transcript"));
            return;
        }
        if self.state != State::Finalizing {
            log::debug(&format!("{id}: ignoring a transcript outside finalization"));
            return;
        }
        if text.trim().is_empty() {
            // A session that produced no text has nothing to insert.
            log::info(&format!(
                "{id}: the final transcript was empty; nothing to insert"
            ));
            self.discard();
            return;
        }
        log::info(&format!(
            "{id}: final transcript received ({} characters)",
            text.chars().count()
        ));
        // Leave finalization before typing so a slow insertion cannot block the
        // next session, then deliver exactly once.
        self.discard();
        let output = self.deps.output.clone();
        tokio::task::spawn_blocking(move || match deliver(output.as_ref(), &text) {
            Delivery::Inserted => log::info("typed the transcript into the focused application"),
            Delivery::Copied { .. } => {
                log::info("could not type the transcript; copied it to the clipboard")
            }
            Delivery::Failed { .. } => log::info("could not type or copy the transcript"),
        });
    }
}

/// Peak and RMS of one PCM16 buffer. Used only for diagnostics: a clipped onset
/// looks different when the microphone was still silent than when the audio
/// really was dropped, and neither case needs audio to be logged.
fn pcm16_level(bytes: &[u8]) -> (i32, i32) {
    let mut peak = 0i32;
    let mut sum = 0i64;
    let mut count = 0i64;
    for sample in bytes.as_chunks::<2>().0 {
        let value = i32::from(i16::from_le_bytes(*sample));
        peak = peak.max(value.abs());
        sum += i64::from(value) * i64::from(value);
        count += 1;
    }
    let rms = if count == 0 {
        0
    } else {
        ((sum / count) as f64).sqrt() as i32
    };
    (peak, rms)
}

async fn fire_after(delay: Duration, event: Event, events: mpsc::Sender<Event>) {
    tokio::time::sleep(delay).await;
    let _ = events.send(event).await;
}

/// Retries the audio queue so a temporarily full transport channel still drains
/// when no other event arrives.
async fn ticker_task(
    session: String,
    events: mpsc::Sender<Event>,
    mut stop: oneshot::Receiver<()>,
) {
    loop {
        tokio::select! {
            _ = &mut stop => break,
            _ = tokio::time::sleep(Duration::from_millis(20)) => {
                if events.send(Event::Tick(session.clone())).await.is_err() {
                    break;
                }
            }
        }
    }
}

async fn audio_task(
    session: String,
    mut chunks: mpsc::Receiver<Vec<u8>>,
    events: mpsc::Sender<Event>,
) {
    while let Some(chunk) = chunks.recv().await {
        if events
            .send(Event::Audio(session.clone(), chunk))
            .await
            .is_err()
        {
            return;
        }
    }
    let _ = events.send(Event::AudioEnded(session)).await;
}

async fn transport_task(
    session: String,
    mut transport: Box<dyn TranscriptionTransport>,
    mut commands: mpsc::Receiver<TransportCommand>,
    events: mpsc::Sender<Event>,
) {
    if let Err(error) = transport.connect().await {
        let _ = events.send(Event::TransportFailed(session, error)).await;
        return;
    }
    let Some((mut writer, mut reader)) = transport.split() else {
        let _ = events
            .send(Event::TransportFailed(
                session,
                "the realtime socket was lost during setup".to_string(),
            ))
            .await;
        return;
    };

    let reader_events = events.clone();
    let reader_session = session.clone();
    let read = async move {
        loop {
            match reader.next_event().await {
                Some(TranscriptEvent::Ready) => {
                    if reader_events
                        .send(Event::Ready(reader_session.clone()))
                        .await
                        .is_err()
                    {
                        break;
                    }
                }
                Some(TranscriptEvent::Interim(_)) => {
                    if reader_events
                        .send(Event::Interim(reader_session.clone()))
                        .await
                        .is_err()
                    {
                        break;
                    }
                }
                Some(TranscriptEvent::Final(text)) => {
                    if reader_events
                        .send(Event::Final(reader_session.clone(), text))
                        .await
                        .is_err()
                    {
                        break;
                    }
                }
                Some(TranscriptEvent::Failed(error)) => {
                    let _ = reader_events
                        .send(Event::TransportFailed(reader_session, error))
                        .await;
                    break;
                }
                None => {
                    let _ = reader_events
                        .send(Event::TransportClosed(reader_session))
                        .await;
                    break;
                }
            }
        }
    };

    let write = async move {
        // The writer drains in order, so the commit can never overtake audio.
        let mut appended_any_audio = false;
        while let Some(command) = commands.recv().await {
            let result = match command {
                TransportCommand::Audio(pcm) => {
                    let result = writer.send_audio(pcm).await;
                    if result.is_ok() && !appended_any_audio {
                        appended_any_audio = true;
                        log::debug(&format!(
                            "{session}: first audio append sent to the provider"
                        ));
                    }
                    result
                }
                TransportCommand::Commit => writer.commit().await,
            };
            if let Err(error) = result {
                let _ = events
                    .send(Event::TransportFailed(session.clone(), error))
                    .await;
                break;
            }
        }
        writer.close().await;
    };
    // Both halves belong to this task. Aborting it drops network awaits and
    // buffered commands; completion of either half also drops the other.
    tokio::select! {
        _ = read => {},
        _ = write => {},
    }
}

#[cfg(test)]
mod tests {
    use super::pcm16_level;

    #[test]
    fn level_reports_silence_and_signal() {
        assert_eq!(pcm16_level(&[0, 0, 0, 0]), (0, 0));
        // 1000 and -1000 as little-endian PCM16.
        assert_eq!(pcm16_level(&[0xE8, 0x03, 0x18, 0xFC]), (1000, 1000));
        assert_eq!(pcm16_level(&[]), (0, 0));
    }
}

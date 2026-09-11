#![allow(dead_code)]

//! Fakes for the replaceable boundaries, plus small test helpers.
//!
//! Every fake is driven from the test side, so ordering, readiness, failures,
//! and timeouts are all deterministic without a microphone or a network.

use std::collections::VecDeque;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use futures_util::future::BoxFuture;
use tokio::sync::{Notify, mpsc};

use whistt::audio::{AudioCapture, AudioFactory, CaptureChild, CaptureSession};
use whistt::config::{Config, DEFAULT_MODEL};
use whistt::ipc::State;
use whistt::output::TextOutput;
use whistt::session::{Command, ControllerDeps, ControllerHandle};
use whistt::transport::{
    TranscriptEvent, TranscriptionTransport, TransportFactory, TransportReader, TransportWriter,
};

pub fn test_config() -> Config {
    Config {
        api_key: Some("test-key".to_string()),
        model: DEFAULT_MODEL.to_string(),
        device: None,
        socket_path: std::env::temp_dir().join("whistt-test/daemon.sock"),
        recording_limit: Duration::from_secs(2),
        setup_timeout: Duration::from_millis(500),
        finalization_timeout: Duration::from_secs(2),
        max_unsent_audio: Duration::from_secs(5),
    }
}

// ---------------------------------------------------------------- audio fake

#[derive(Default)]
struct AudioState {
    initial: VecDeque<Vec<u8>>,
    drain: VecDeque<Vec<u8>>,
    stop_requested: bool,
    killed: bool,
    reaps: usize,
}

/// One scripted capture child.
#[derive(Clone, Default)]
pub struct FakeAudioControl {
    state: Arc<Mutex<AudioState>>,
    notify: Arc<Notify>,
}

impl FakeAudioControl {
    pub fn new() -> Self {
        Self::default()
    }

    /// Bytes the microphone produced before the release.
    pub fn push_initial(&self, bytes: Vec<u8>) {
        self.state.lock().unwrap().initial.push_back(bytes);
    }

    /// Bytes still in the pipe when the release arrives; only delivered after a
    /// graceful stop, never after a kill.
    pub fn push_drain(&self, bytes: Vec<u8>) {
        self.state.lock().unwrap().drain.push_back(bytes);
    }

    pub fn stop_requested(&self) -> bool {
        self.state.lock().unwrap().stop_requested
    }

    pub fn killed(&self) -> bool {
        self.state.lock().unwrap().killed
    }

    pub fn reaps(&self) -> usize {
        self.state.lock().unwrap().reaps
    }
}

/// Audio scripted for one session: what the microphone produced before the
/// release, and what is still in the pipe when the release arrives.
type ScriptedAudio = (Vec<Vec<u8>>, Vec<Vec<u8>>);

/// Hands out one control per session so tests can address them by index.
#[derive(Clone, Default)]
pub struct FakeAudioPool {
    sessions: Arc<Mutex<Vec<FakeAudioControl>>>,
    queued: Arc<Mutex<VecDeque<ScriptedAudio>>>,
}

impl FakeAudioPool {
    pub fn new() -> Self {
        Self::default()
    }

    /// Queues the initial and drain chunks for the next created session.
    pub fn script(&self, initial: Vec<Vec<u8>>, drain: Vec<Vec<u8>>) {
        self.queued.lock().unwrap().push_back((initial, drain));
    }

    /// Queues only initial audio, which is the common case.
    pub fn script_initial(&self, initial: Vec<Vec<u8>>) {
        self.script(initial, Vec::new());
    }

    pub fn session(&self, index: usize) -> FakeAudioControl {
        self.sessions
            .lock()
            .unwrap()
            .get(index)
            .cloned()
            .unwrap_or_else(|| panic!("no capture session at index {index}"))
    }

    pub fn count(&self) -> usize {
        self.sessions.lock().unwrap().len()
    }
}

impl AudioFactory for FakeAudioPool {
    fn create(&self) -> Box<dyn AudioCapture> {
        let control = FakeAudioControl::new();
        if let Some((initial, drain)) = self.queued.lock().unwrap().pop_front() {
            for chunk in initial {
                control.push_initial(chunk);
            }
            for chunk in drain {
                control.push_drain(chunk);
            }
        }
        self.sessions.lock().unwrap().push(control.clone());
        Box::new(FakeAudioCapture { control })
    }
}

struct FakeAudioCapture {
    control: FakeAudioControl,
}

impl AudioCapture for FakeAudioCapture {
    fn spawn(&mut self) -> Result<CaptureSession, String> {
        let (sender, receiver) = mpsc::channel(64);
        let control = self.control.clone();
        tokio::spawn(async move {
            loop {
                let next = control.state.lock().unwrap().initial.pop_front();
                match next {
                    Some(chunk) => {
                        if sender.send(chunk).await.is_err() {
                            return;
                        }
                    }
                    None => break,
                }
            }
            // Wait for the release (or a kill) before draining the pipe.
            loop {
                {
                    let state = control.state.lock().unwrap();
                    if state.killed {
                        return;
                    }
                    if state.stop_requested {
                        break;
                    }
                }
                control.notify.notified().await;
            }
            loop {
                if control.state.lock().unwrap().killed {
                    return;
                }
                let next = control.state.lock().unwrap().drain.pop_front();
                match next {
                    Some(chunk) => {
                        if sender.send(chunk).await.is_err() {
                            return;
                        }
                    }
                    None => break,
                }
            }
        });
        Ok(CaptureSession {
            chunks: receiver,
            child: Box::new(FakeChild {
                control: self.control.clone(),
            }),
        })
    }
}

struct FakeChild {
    control: FakeAudioControl,
}

impl CaptureChild for FakeChild {
    fn request_stop(&mut self) {
        self.control.state.lock().unwrap().stop_requested = true;
        self.control.notify.notify_one();
    }

    fn kill(&mut self) {
        self.control.state.lock().unwrap().killed = true;
        self.control.notify.notify_one();
    }

    fn try_reap(&mut self) {
        self.control.state.lock().unwrap().reaps += 1;
    }
}

// ------------------------------------------------------------ transport fake

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum TransportLog {
    Connect,
    Audio(Vec<u8>),
    Commit,
    Close,
}

#[derive(Clone, Default)]
struct TransportSettings {
    connect_error: Option<String>,
    connect_delay: Duration,
    finish_on_commit: bool,
}

#[derive(Default)]
struct TransportState {
    log: Vec<TransportLog>,
    incoming: VecDeque<TranscriptEvent>,
    stream_ended: bool,
    settings: TransportSettings,
}

/// One scripted provider session.
#[derive(Clone, Default)]
pub struct FakeTransportControl {
    state: Arc<Mutex<TransportState>>,
    notify: Arc<Notify>,
}

impl FakeTransportControl {
    pub fn new() -> Self {
        Self::default()
    }

    /// Queue an incoming provider event.
    pub fn push(&self, event: TranscriptEvent) {
        self.state.lock().unwrap().incoming.push_back(event);
        self.notify.notify_one();
    }

    /// End the connection, which the reader reports as `None`.
    pub fn end_stream(&self) {
        self.state.lock().unwrap().stream_ended = true;
        self.notify.notify_one();
    }

    pub fn log(&self) -> Vec<TransportLog> {
        self.state.lock().unwrap().log.clone()
    }

    pub fn audio(&self) -> Vec<Vec<u8>> {
        self.log()
            .into_iter()
            .filter_map(|entry| match entry {
                TransportLog::Audio(bytes) => Some(bytes),
                _ => None,
            })
            .collect()
    }

    pub fn commits(&self) -> usize {
        self.log()
            .into_iter()
            .filter(|entry| *entry == TransportLog::Commit)
            .count()
    }

    pub fn connects(&self) -> usize {
        self.log()
            .into_iter()
            .filter(|entry| *entry == TransportLog::Connect)
            .count()
    }

    pub async fn wait_for_audio(&self, chunks: usize) {
        self.wait_for(|state| {
            state
                .log
                .iter()
                .filter(|entry| matches!(entry, TransportLog::Audio(_)))
                .count()
                >= chunks
        })
        .await;
    }

    pub async fn wait_for_commit(&self) {
        self.wait_for(|state| state.log.contains(&TransportLog::Commit))
            .await;
    }

    async fn wait_for(&self, mut predicate: impl FnMut(&TransportState) -> bool) {
        for _ in 0..1000 {
            if predicate(&self.state.lock().unwrap()) {
                return;
            }
            tokio::time::sleep(Duration::from_millis(5)).await;
        }
        panic!("timed out waiting for the fake transport");
    }
}

/// Hands out one control per session so tests can address them by index.
#[derive(Clone, Default)]
pub struct FakeTransportPool {
    sessions: Arc<Mutex<Vec<FakeTransportControl>>>,
    settings: Arc<Mutex<TransportSettings>>,
}

impl FakeTransportPool {
    pub fn new() -> Self {
        Self::default()
    }

    /// Make the next created session fail during connection setup.
    pub fn fail_connect(&self, message: &str) {
        self.settings.lock().unwrap().connect_error = Some(message.to_string());
    }

    /// Make the next created session take time to become ready.
    pub fn delay_connect(&self, delay: Duration) {
        self.settings.lock().unwrap().connect_delay = delay;
    }

    /// End the stream as soon as the turn is committed.
    pub fn finish_on_commit(&self) {
        self.settings.lock().unwrap().finish_on_commit = true;
    }

    pub fn session(&self, index: usize) -> FakeTransportControl {
        self.sessions
            .lock()
            .unwrap()
            .get(index)
            .cloned()
            .unwrap_or_else(|| panic!("no provider session at index {index}"))
    }

    pub fn count(&self) -> usize {
        self.sessions.lock().unwrap().len()
    }
}

impl TransportFactory for FakeTransportPool {
    fn create(&self) -> Box<dyn TranscriptionTransport> {
        let control = FakeTransportControl::new();
        control.state.lock().unwrap().settings = self.settings.lock().unwrap().clone();
        self.sessions.lock().unwrap().push(control.clone());
        Box::new(FakeTransport { control })
    }
}

struct FakeTransport {
    control: FakeTransportControl,
}

impl TranscriptionTransport for FakeTransport {
    fn connect(&mut self) -> BoxFuture<'_, Result<(), String>> {
        Box::pin(async move {
            let (delay, error) = {
                let mut state = self.control.state.lock().unwrap();
                state.log.push(TransportLog::Connect);
                (
                    state.settings.connect_delay,
                    state.settings.connect_error.clone(),
                )
            };
            if !delay.is_zero() {
                tokio::time::sleep(delay).await;
            }
            match error {
                Some(message) => Err(message),
                None => Ok(()),
            }
        })
    }

    fn split(&mut self) -> Option<(Box<dyn TransportWriter>, Box<dyn TransportReader>)> {
        Some((
            Box::new(FakeWriter {
                control: self.control.clone(),
            }),
            Box::new(FakeReader {
                control: self.control.clone(),
            }),
        ))
    }
}

struct FakeWriter {
    control: FakeTransportControl,
}

impl TransportWriter for FakeWriter {
    fn send_audio(&mut self, pcm: Vec<u8>) -> BoxFuture<'_, Result<(), String>> {
        Box::pin(async move {
            self.control
                .state
                .lock()
                .unwrap()
                .log
                .push(TransportLog::Audio(pcm));
            Ok(())
        })
    }

    fn commit(&mut self) -> BoxFuture<'_, Result<(), String>> {
        Box::pin(async move {
            let finish = {
                let mut state = self.control.state.lock().unwrap();
                state.log.push(TransportLog::Commit);
                state.settings.finish_on_commit
            };
            if finish {
                self.control.end_stream();
            }
            Ok(())
        })
    }

    fn close(&mut self) -> BoxFuture<'_, ()> {
        Box::pin(async move {
            self.control
                .state
                .lock()
                .unwrap()
                .log
                .push(TransportLog::Close);
        })
    }
}

struct FakeReader {
    control: FakeTransportControl,
}

impl TransportReader for FakeReader {
    fn next_event(&mut self) -> BoxFuture<'_, Option<TranscriptEvent>> {
        Box::pin(async move {
            loop {
                {
                    let mut state = self.control.state.lock().unwrap();
                    if let Some(event) = state.incoming.pop_front() {
                        return Some(event);
                    }
                    if state.stream_ended {
                        return None;
                    }
                }
                self.control.notify.notified().await;
            }
        })
    }
}

// -------------------------------------------------------------- output fake

#[derive(Default)]
struct OutputState {
    inserts: Vec<String>,
    copies: Vec<String>,
    notifications: Vec<String>,
    fail_insert: bool,
    fail_copy: bool,
}

/// Records what the controller tried to deliver.
#[derive(Default)]
pub struct FakeOutput {
    state: Mutex<OutputState>,
}

impl FakeOutput {
    pub fn new() -> Self {
        Self::default()
    }

    /// Every insertion attempt fails.
    pub fn failing_insert() -> Self {
        let output = Self::default();
        output.state.lock().unwrap().fail_insert = true;
        output
    }

    /// Insertion and the clipboard both fail.
    pub fn failing_insert_and_copy() -> Self {
        let output = Self::default();
        {
            let mut state = output.state.lock().unwrap();
            state.fail_insert = true;
            state.fail_copy = true;
        }
        output
    }

    /// Insertion attempts, including failed ones, so "no retry" is provable.
    pub fn insert_attempts(&self) -> Vec<String> {
        self.state.lock().unwrap().inserts.clone()
    }

    pub fn copies(&self) -> Vec<String> {
        self.state.lock().unwrap().copies.clone()
    }

    pub fn notifications(&self) -> Vec<String> {
        self.state.lock().unwrap().notifications.clone()
    }

    pub async fn wait_for_inserts(&self, count: usize) {
        for _ in 0..1000 {
            if self.state.lock().unwrap().inserts.len() >= count {
                return;
            }
            tokio::time::sleep(Duration::from_millis(5)).await;
        }
        panic!("timed out waiting for {count} insertion(s)");
    }
}

impl TextOutput for FakeOutput {
    fn insert(&self, text: &str) -> Result<(), String> {
        let mut state = self.state.lock().unwrap();
        state.inserts.push(text.to_string());
        if state.fail_insert {
            return Err("wtype is not available".to_string());
        }
        Ok(())
    }

    fn copy(&self, text: &str) -> Result<(), String> {
        let mut state = self.state.lock().unwrap();
        state.copies.push(text.to_string());
        if state.fail_copy {
            return Err("wl-copy is not available".to_string());
        }
        Ok(())
    }

    fn notify(&self, message: &str) -> Result<(), String> {
        self.state
            .lock()
            .unwrap()
            .notifications
            .push(message.to_string());
        Ok(())
    }
}

// ------------------------------------------------------------------ harness

pub struct Harness {
    pub controller: ControllerHandle,
    pub audio: FakeAudioPool,
    pub transport: FakeTransportPool,
    pub output: Arc<FakeOutput>,
}

/// Builds a controller wired entirely to fakes.
pub fn harness(config: Config) -> Harness {
    let audio = FakeAudioPool::new();
    let transport = FakeTransportPool::new();
    let output = Arc::new(FakeOutput::new());
    let deps = ControllerDeps {
        config,
        audio: Arc::new(audio.clone()),
        transport: Arc::new(transport.clone()),
        output: output.clone(),
    };
    Harness {
        controller: whistt::session::spawn(deps),
        audio,
        transport,
        output,
    }
}

/// Polls `status` until the controller reports `state`.
pub async fn wait_for_state(controller: &ControllerHandle, state: State) {
    for _ in 0..1200 {
        if controller.send(Command::Status).await.state == state {
            return;
        }
        tokio::time::sleep(Duration::from_millis(5)).await;
    }
    panic!("timed out waiting for state {}", state.as_str());
}

/// Gives the controller a moment to process anything already queued.
pub async fn settle() {
    for _ in 0..20 {
        tokio::task::yield_now().await;
    }
    tokio::time::sleep(Duration::from_millis(30)).await;
}

/// A fresh temporary directory that exists for the duration of one test binary.
pub fn temporary_directory(name: &str) -> std::path::PathBuf {
    let directory = std::env::temp_dir().join(format!("whistt-test-{}-{name}", std::process::id()));
    let _ = std::fs::remove_dir_all(&directory);
    std::fs::create_dir_all(&directory).expect("could not create the temporary directory");
    directory
}

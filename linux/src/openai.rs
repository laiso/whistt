//! OpenAI transcription-intent WebSocket transport.
//!
//! Follows the same wire protocol as the macOS application: the transcription
//! intent endpoint, a transcription session with manual turn detection, base64
//! PCM appends, and one explicit commit per push-to-talk turn.

use base64::Engine as _;
use base64::engine::general_purpose::STANDARD as BASE64;
use futures_util::future::BoxFuture;
use futures_util::stream::{SplitSink, SplitStream};
use futures_util::{SinkExt, StreamExt};
use tokio::net::TcpStream;
use tokio_tungstenite::tungstenite::Message;
use tokio_tungstenite::tungstenite::client::IntoClientRequest;
use tokio_tungstenite::tungstenite::http::HeaderValue;
use tokio_tungstenite::{MaybeTlsStream, WebSocketStream, connect_async};

use crate::config::SAMPLE_RATE;
use crate::log;
use crate::transport::{
    TranscriptEvent, TranscriptionTransport, TransportFactory, TransportReader, TransportWriter,
};

type Socket = WebSocketStream<MaybeTlsStream<TcpStream>>;

/// The transcription-intent endpoint. The `model` query parameter is the
/// conversational realtime model and is deliberately not sent; the
/// transcription model travels in `session.audio.input.transcription.model`.
const REALTIME_URL: &str = "wss://api.openai.com/v1/realtime?intent=transcription";

pub struct OpenAiTransportFactory {
    pub api_key: String,
    pub model: String,
}

impl TransportFactory for OpenAiTransportFactory {
    fn create(&self) -> Box<dyn TranscriptionTransport> {
        Box::new(OpenAiTransport {
            api_key: self.api_key.clone(),
            model: self.model.clone(),
            socket: None,
        })
    }
}

struct OpenAiTransport {
    api_key: String,
    model: String,
    socket: Option<Socket>,
}

impl TranscriptionTransport for OpenAiTransport {
    fn connect(&mut self) -> BoxFuture<'_, Result<(), String>> {
        Box::pin(async move {
            let mut request = REALTIME_URL
                .into_client_request()
                .map_err(|error| format!("invalid realtime URL: {error}"))?;
            let header = HeaderValue::from_str(&format!("Bearer {}", self.api_key))
                .map_err(|_| "OPENAI_API_KEY cannot be sent as an HTTP header".to_string())?;
            request.headers_mut().insert("Authorization", header);

            let (socket, _response) = connect_async(request).await.map_err(|error| {
                format!("could not connect to the OpenAI realtime endpoint: {error}")
            })?;
            self.socket = Some(socket);

            let update = session_update(&self.model);
            let socket = self
                .socket
                .as_mut()
                .ok_or_else(|| "the realtime socket was lost during setup".to_string())?;
            socket.send(Message::text(update)).await.map_err(|error| {
                format!("could not configure the transcription session: {error}")
            })?;
            Ok(())
        })
    }

    fn split(&mut self) -> Option<(Box<dyn TransportWriter>, Box<dyn TransportReader>)> {
        let socket = self.socket.take()?;
        let (sink, stream) = socket.split();
        Some((
            Box::new(OpenAiWriter { sink }),
            Box::new(OpenAiReader { stream }),
        ))
    }
}

struct OpenAiWriter {
    sink: SplitSink<Socket, Message>,
}

impl TransportWriter for OpenAiWriter {
    fn send_audio(&mut self, pcm: Vec<u8>) -> BoxFuture<'_, Result<(), String>> {
        Box::pin(async move {
            let payload = serde_json::json!({
                "type": "input_audio_buffer.append",
                "audio": BASE64.encode(&pcm),
            })
            .to_string();
            self.sink
                .send(Message::text(payload))
                .await
                .map_err(|error| format!("could not send audio: {error}"))
        })
    }

    fn commit(&mut self) -> BoxFuture<'_, Result<(), String>> {
        Box::pin(async move {
            let payload = serde_json::json!({ "type": "input_audio_buffer.commit" }).to_string();
            self.sink
                .send(Message::text(payload))
                .await
                .map_err(|error| format!("could not commit the turn: {error}"))
        })
    }

    fn close(&mut self) -> BoxFuture<'_, ()> {
        Box::pin(async move {
            let _ = self.sink.close().await;
        })
    }
}

struct OpenAiReader {
    stream: SplitStream<Socket>,
}

impl TransportReader for OpenAiReader {
    fn next_event(&mut self) -> BoxFuture<'_, Option<TranscriptEvent>> {
        Box::pin(async move {
            loop {
                match self.stream.next().await {
                    Some(Ok(Message::Text(text))) => {
                        if let Some(event) = decode_event(text.as_str()) {
                            return Some(event);
                        }
                    }
                    Some(Ok(Message::Close(_))) | None => return None,
                    Some(Ok(_)) => continue,
                    Some(Err(error)) => {
                        return Some(TranscriptEvent::Failed(format!(
                            "realtime socket error: {error}"
                        )));
                    }
                }
            }
        })
    }
}

/// The transcription session configuration, matching the macOS payload,
/// including `turn_detection: null` for manual commit.
fn session_update(model: &str) -> String {
    serde_json::json!({
        "type": "session.update",
        "session": {
            "type": "transcription",
            "audio": {
                "input": {
                    "format": { "type": "audio/pcm", "rate": SAMPLE_RATE },
                    "transcription": { "model": model },
                    "turn_detection": serde_json::Value::Null,
                }
            }
        }
    })
    .to_string()
}

/// Maps one provider message onto a normalized event.
///
/// Returns `None` for messages that carry nothing the session needs, including
/// malformed JSON and unknown types. `session.created` is intentionally not
/// reported as ready: only `session.updated` proves our `session.update` was
/// applied, so audio is never appended against an unconfigured session.
fn decode_event(message: &str) -> Option<TranscriptEvent> {
    let value: serde_json::Value = match serde_json::from_str(message) {
        Ok(value) => value,
        Err(error) => {
            log::debug(&format!("ignoring a malformed provider message: {error}"));
            return None;
        }
    };
    let kind = value.get("type").and_then(|kind| kind.as_str())?;
    match kind {
        "session.updated" => Some(TranscriptEvent::Ready),
        "conversation.item.input_audio_transcription.completed"
        | "response.audio_transcript.done"
        | "response.text.done" => {
            let text = text_field(&value);
            Some(TranscriptEvent::Final(text))
        }
        "conversation.item.input_audio_transcription.delta"
        | "response.audio_transcript.delta"
        | "response.text.delta" => {
            let delta = value
                .get("delta")
                .and_then(|delta| delta.as_str())
                .unwrap_or_default();
            if delta.is_empty() {
                None
            } else {
                Some(TranscriptEvent::Interim(delta.to_string()))
            }
        }
        "conversation.item.input_audio_transcription.failed" => {
            Some(TranscriptEvent::Failed(error_message(&value)))
        }
        "error" => Some(TranscriptEvent::Failed(error_message(&value))),
        // `conversation.item.added` and `conversation.item.done` repeat the item
        // transcript and can arrive before the completed event. Ignoring them
        // keeps the final-only output contract from inserting text early.
        _ => None,
    }
}

fn text_field(value: &serde_json::Value) -> String {
    value
        .get("transcript")
        .or_else(|| value.get("text"))
        .and_then(|text| text.as_str())
        .unwrap_or_default()
        .to_string()
}

fn error_message(value: &serde_json::Value) -> String {
    match value
        .get("error")
        .and_then(|error| error.get("message"))
        .and_then(|message| message.as_str())
    {
        Some(message) => message.to_string(),
        None => "the provider reported an error without a message".to_string(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn session_update_matches_the_macos_payload() {
        let update: serde_json::Value =
            serde_json::from_str(&session_update("gpt-transcribe")).unwrap();
        assert_eq!(update["type"], "session.update");
        assert_eq!(update["session"]["type"], "transcription");
        assert_eq!(
            update["session"]["audio"]["input"]["format"]["type"],
            "audio/pcm"
        );
        assert_eq!(
            update["session"]["audio"]["input"]["format"]["rate"],
            24_000
        );
        assert_eq!(
            update["session"]["audio"]["input"]["transcription"]["model"],
            "gpt-transcribe"
        );
        assert!(update["session"]["audio"]["input"]["turn_detection"].is_null());
    }

    #[test]
    fn only_session_updated_marks_the_session_ready() {
        assert_eq!(
            decode_event(r#"{"type":"session.updated"}"#),
            Some(TranscriptEvent::Ready)
        );
        assert_eq!(decode_event(r#"{"type":"session.created"}"#), None);
    }

    #[test]
    fn completed_events_are_final_and_deltas_are_interim() {
        assert_eq!(
            decode_event(
                r#"{"type":"conversation.item.input_audio_transcription.completed","transcript":"こんにちは"}"#
            ),
            Some(TranscriptEvent::Final("こんにちは".to_string()))
        );
        assert_eq!(
            decode_event(
                r#"{"type":"conversation.item.input_audio_transcription.delta","delta":"こん"}"#
            ),
            Some(TranscriptEvent::Interim("こん".to_string()))
        );
        assert_eq!(
            decode_event(
                r#"{"type":"conversation.item.input_audio_transcription.delta","delta":""}"#
            ),
            None
        );
    }

    #[test]
    fn conversation_items_never_produce_output() {
        let item = r#"{"type":"conversation.item.done","item":{"content":[{"transcript":"早すぎる挿入"}]}}"#;
        assert_eq!(decode_event(item), None);
        assert_eq!(
            decode_event(r#"{"type":"conversation.item.added","item":{"content":[]}}"#),
            None
        );
    }

    #[test]
    fn errors_and_malformed_messages_are_handled() {
        assert_eq!(
            decode_event(r#"{"type":"error","error":{"message":"Invalid API key"}}"#),
            Some(TranscriptEvent::Failed("Invalid API key".to_string()))
        );
        assert_eq!(decode_event("not json"), None);
        assert_eq!(decode_event(r#"{"no":"type"}"#), None);
        assert_eq!(decode_event(r#"{"type":"something.new"}"#), None);
    }
}

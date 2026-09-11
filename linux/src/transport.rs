//! Provider-neutral transcription transport boundary.
//!
//! A transport owns its connection lifecycle, wire format, and translation into
//! these normalized events. Nothing provider-specific crosses this boundary, and
//! the output layer never sees an event other than a completed transcript.
//!
//! Reading and writing are separate halves so a `select!` loop never has to hold
//! two mutable borrows of the same session at once.

use futures_util::future::BoxFuture;

/// One normalized event from a transcription provider.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum TranscriptEvent {
    /// The session is configured and can accept audio.
    Ready,
    /// A revisable hypothesis. Kept internal because the OpenAI transcription
    /// intent does not prove that a delta is append-safe.
    Interim(String),
    /// A completed transcript for the push-to-talk turn.
    Final(String),
    /// Terminal provider failure, including authentication and protocol errors.
    Failed(String),
}

/// Connection setup for one session. Call [`TranscriptionTransport::split`]
/// afterwards to drive reads and writes concurrently.
pub trait TranscriptionTransport: Send {
    fn connect(&mut self) -> BoxFuture<'_, Result<(), String>>;
    /// Returns the two halves, or `None` when the connection never succeeded.
    fn split(&mut self) -> Option<(Box<dyn TransportWriter>, Box<dyn TransportReader>)>;
}

/// The sending half.
pub trait TransportWriter: Send {
    fn send_audio(&mut self, pcm: Vec<u8>) -> BoxFuture<'_, Result<(), String>>;
    fn commit(&mut self) -> BoxFuture<'_, Result<(), String>>;
    fn close(&mut self) -> BoxFuture<'_, ()>;
}

/// The receiving half. `next_event` must be cancel-safe: dropping the returned
/// future never loses an already received message.
pub trait TransportReader: Send {
    fn next_event(&mut self) -> BoxFuture<'_, Option<TranscriptEvent>>;
}

/// Creates one [`TranscriptionTransport`] per recording session.
pub trait TransportFactory: Send + Sync {
    fn create(&self) -> Box<dyn TranscriptionTransport>;
}

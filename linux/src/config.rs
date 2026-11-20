//! Process configuration.
//!
//! Credentials come from the environment and are deliberately separate from
//! model and device settings, which are ordinary values.

use std::path::PathBuf;
use std::str::FromStr;
use std::time::Duration;

/// Default OpenAI transcription model; matches the macOS application default.
pub const DEFAULT_MODEL: &str = "gpt-transcribe";

/// Capture format the OpenAI transcription session expects.
pub const SAMPLE_RATE: u32 = 24_000;
pub const CHANNELS: u16 = 1;
pub const BYTES_PER_SAMPLE: usize = 2;

/// Bytes produced by one second of capture (48,000 at 24 kHz mono s16).
pub const BYTES_PER_SECOND: usize = SAMPLE_RATE as usize * CHANNELS as usize * BYTES_PER_SAMPLE;

/// Roughly 100 ms of audio: the unit appended to the provider session.
pub const CHUNK_BYTES: usize = BYTES_PER_SECOND / 10;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum OutputMode {
    Type,
    Paste,
}

impl FromStr for OutputMode {
    type Err = String;

    fn from_str(value: &str) -> Result<Self, Self::Err> {
        match value.trim().to_ascii_lowercase().as_str() {
            "type" => Ok(Self::Type),
            "paste" => Ok(Self::Paste),
            _ => Err("WHISTT_OUTPUT must be 'type' or 'paste'".to_string()),
        }
    }
}

#[derive(Debug, Clone)]
pub struct Config {
    /// `OPENAI_API_KEY`. Required before any recording session can start.
    pub api_key: Option<String>,
    /// `WHISTT_MODEL`, defaulting to [`DEFAULT_MODEL`].
    pub model: String,
    /// Optional ISO-639-1 transcription hint from `WHISTT_LANGUAGE`.
    pub language: Option<String>,
    /// `WHISTT_OUTPUT`, defaulting to lossless clipboard-backed paste.
    pub output_mode: OutputMode,
    /// `WHISTT_PASTE_CHORD`, defaulting to `shift+insert`.
    pub paste_chord: String,
    /// `WHISTT_DEVICE`, forwarded to `pw-record --target`.
    pub device: Option<String>,
    /// Unix socket the daemon listens on.
    pub socket_path: PathBuf,
    /// Hard limit on one recording session.
    pub recording_limit: Duration,
    /// Limit on connecting and configuring the provider session.
    pub setup_timeout: Duration,
    /// Limit on waiting for the final transcript after committing.
    pub finalization_timeout: Duration,
    /// Maximum audio that may be captured but not yet handed to the provider.
    pub max_unsent_audio: Duration,
}

impl Config {
    /// Reads configuration from the process environment.
    ///
    /// A missing API key is not an error here: `whistt status` and
    /// `whistt record stop` must work against a running daemon regardless,
    /// and the daemon reports the missing key when a session starts.
    pub fn from_env() -> Result<Self, String> {
        Ok(Self {
            api_key: non_empty(std::env::var("OPENAI_API_KEY").ok()),
            model: non_empty(std::env::var("WHISTT_MODEL").ok())
                .unwrap_or_else(|| DEFAULT_MODEL.to_string()),
            language: non_empty(std::env::var("WHISTT_LANGUAGE").ok()),
            output_mode: std::env::var("WHISTT_OUTPUT")
                .unwrap_or_else(|_| "paste".to_string())
                .parse()?,
            paste_chord: non_empty(std::env::var("WHISTT_PASTE_CHORD").ok())
                .unwrap_or_else(|| "shift+insert".to_string()),
            device: non_empty(std::env::var("WHISTT_DEVICE").ok()),
            socket_path: default_socket_path()?,
            recording_limit: Duration::from_secs(60),
            setup_timeout: Duration::from_secs(10),
            finalization_timeout: Duration::from_secs(30),
            max_unsent_audio: Duration::from_secs(5),
        })
    }

    /// The unsent-audio bound expressed in bytes.
    pub fn max_unsent_bytes(&self) -> usize {
        (self.max_unsent_audio.as_millis() as usize * BYTES_PER_SECOND) / 1000
    }
}

/// `$XDG_RUNTIME_DIR/whistt/daemon.sock`.
pub fn default_socket_path() -> Result<PathBuf, String> {
    let runtime = std::env::var_os("XDG_RUNTIME_DIR").ok_or_else(|| {
        "XDG_RUNTIME_DIR is not set; Whistt needs a private runtime directory".to_string()
    })?;
    Ok(PathBuf::from(runtime).join("whistt").join("daemon.sock"))
}

fn non_empty(value: Option<String>) -> Option<String> {
    value.filter(|value| !value.trim().is_empty())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn chunk_is_one_tenth_of_a_second() {
        assert_eq!(BYTES_PER_SECOND, 48_000);
        assert_eq!(CHUNK_BYTES, 4_800);
    }

    #[test]
    fn unsent_bound_is_five_seconds_of_audio() {
        let config = Config {
            api_key: None,
            model: DEFAULT_MODEL.to_string(),
            language: None,
            output_mode: OutputMode::Paste,
            paste_chord: "shift+insert".to_string(),
            device: None,
            socket_path: PathBuf::from("/tmp/x.sock"),
            recording_limit: Duration::from_secs(60),
            setup_timeout: Duration::from_secs(10),
            finalization_timeout: Duration::from_secs(30),
            max_unsent_audio: Duration::from_secs(5),
        };
        assert_eq!(config.max_unsent_bytes(), 240_000);
    }

    #[test]
    fn output_modes_are_strict() {
        assert_eq!("type".parse(), Ok(OutputMode::Type));
        assert_eq!("PASTE".parse(), Ok(OutputMode::Paste));
        assert!("clipboard".parse::<OutputMode>().is_err());
    }
}

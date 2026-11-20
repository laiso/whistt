//! Newline-delimited JSON protocol between the CLI and the daemon.

use serde::{Deserialize, Serialize};

/// Session state exposed to the CLI.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum State {
    Idle,
    Recording,
    Finalizing,
}

impl State {
    pub fn as_str(self) -> &'static str {
        match self {
            State::Idle => "idle",
            State::Recording => "recording",
            State::Finalizing => "finalizing",
        }
    }
}

/// One request line.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "command", rename_all = "snake_case")]
pub enum Request {
    Start,
    Stop,
    Cancel,
    Status,
}

/// One response line. Commands are acknowledged as soon as they are accepted;
/// they never wait for transcription to finish.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Response {
    pub ok: bool,
    pub state: State,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub session: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
}

impl Response {
    pub fn ok(state: State) -> Self {
        Self {
            ok: true,
            state,
            session: None,
            error: None,
        }
    }

    pub fn error(state: State, message: impl Into<String>) -> Self {
        Self {
            ok: false,
            state,
            session: None,
            error: Some(message.into()),
        }
    }

    pub fn with_session(mut self, session: impl Into<String>) -> Self {
        self.session = Some(session.into());
        self
    }
}

/// Encodes a value as one protocol line, including the trailing newline.
pub fn encode_line<T: Serialize>(value: &T) -> Result<String, String> {
    let mut line = serde_json::to_string(value)
        .map_err(|error| format!("could not encode request: {error}"))?;
    line.push('\n');
    Ok(line)
}

/// Decodes one protocol line.
pub fn decode_line<T: for<'de> Deserialize<'de>>(line: &str) -> Result<T, String> {
    serde_json::from_str(line.trim()).map_err(|error| format!("could not decode request: {error}"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn requests_use_a_command_tag() {
        assert_eq!(
            encode_line(&Request::Start).unwrap(),
            "{\"command\":\"start\"}\n"
        );
        assert_eq!(
            decode_line::<Request>("{\"command\":\"cancel\"}\n").unwrap(),
            Request::Cancel
        );
    }

    #[test]
    fn responses_omit_absent_fields() {
        let line = encode_line(&Response::ok(State::Recording)).unwrap();
        assert_eq!(line, "{\"ok\":true,\"state\":\"recording\"}\n");
    }

    #[test]
    fn responses_round_trip() {
        let response = Response::error(State::Finalizing, "busy").with_session("s7");
        let decoded: Response = decode_line(&encode_line(&response).unwrap()).unwrap();
        assert_eq!(decoded, response);
        assert_eq!(decoded.error.as_deref(), Some("busy"));
        assert_eq!(decoded.session.as_deref(), Some("s7"));
    }

    #[test]
    fn unknown_commands_are_rejected() {
        assert!(decode_line::<Request>("{\"command\":\"explode\"}\n").is_err());
        assert!(decode_line::<Request>("not json\n").is_err());
    }
}

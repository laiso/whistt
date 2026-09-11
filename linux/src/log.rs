//! Minimal logging for a background daemon.
//!
//! Nothing here ever prints credentials, audio samples, or transcript text.
//! Call sites pass metadata only (session ids, byte counts, states, errors).

use std::sync::OnceLock;

static VERBOSE: OnceLock<bool> = OnceLock::new();

fn verbose() -> bool {
    *VERBOSE.get_or_init(|| {
        matches!(
            std::env::var("WHISTT_LOG").as_deref(),
            Ok("debug") | Ok("trace")
        )
    })
}

/// Operational message: state changes and failures worth showing in a terminal.
pub fn info(message: &str) {
    eprintln!("whistt: {message}");
}

/// Diagnostic detail, enabled with `WHISTT_LOG=debug`.
pub fn debug(message: &str) {
    if verbose() {
        eprintln!("whistt[debug]: {message}");
    }
}

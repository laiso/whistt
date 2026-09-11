//! Minimal logging for a background daemon.
//!
//! Nothing here ever prints credentials, audio samples, or transcript text.
//! Call sites pass metadata only (session ids, byte counts, states, errors).
//!
//! Every line carries the elapsed time since the daemon started. Push-to-talk
//! failures are usually timing failures, and a log without timings cannot show
//! when the microphone actually started relative to the key press.

use std::sync::OnceLock;
use std::time::Instant;

static VERBOSE: OnceLock<bool> = OnceLock::new();
static START: OnceLock<Instant> = OnceLock::new();

fn verbose() -> bool {
    *VERBOSE.get_or_init(|| {
        matches!(
            std::env::var("WHISTT_LOG").as_deref(),
            Ok("debug") | Ok("trace")
        )
    })
}

fn elapsed() -> String {
    let start = START.get_or_init(Instant::now);
    format!("+{:7.3}s ", start.elapsed().as_secs_f64())
}

/// Operational message: state changes and failures worth showing in a terminal.
pub fn info(message: &str) {
    eprintln!("whistt: {}{message}", elapsed());
}

/// Diagnostic detail, enabled with `WHISTT_LOG=debug`.
pub fn debug(message: &str) {
    if verbose() {
        eprintln!("whistt[debug]: {}{message}", elapsed());
    }
}

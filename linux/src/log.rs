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

/// Whether transcript text may be logged. Off by default, and never enabled by
/// `WHISTT_LOG=debug`, because a transcript is the user's speech. It exists so a
/// report like "the first character is missing" can be split into "the
/// transcript was short" and "the insertion dropped it".
pub fn transcripts_enabled() -> bool {
    static ENABLED: OnceLock<bool> = OnceLock::new();
    *ENABLED.get_or_init(|| {
        matches!(
            std::env::var("WHISTT_LOG_TRANSCRIPTS").as_deref(),
            Ok("1") | Ok("true") | Ok("yes")
        )
    })
}

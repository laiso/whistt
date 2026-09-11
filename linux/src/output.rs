//! Text delivery into the focused application.
//!
//! Text reaches `wtype` through stdin only. It is never interpolated into a
//! shell command, and a failed insertion is never retried: a partial insertion
//! cannot be rolled back in another application, so the transcript is copied to
//! the clipboard instead.

use std::ffi::OsString;
use std::process::Stdio;
use std::time::Duration;
use tokio::io::AsyncWriteExt;
use tokio::process::Command;

/// Delivery primitives. Faked in tests.
pub trait TextOutput: Send + Sync {
    /// Type the text into the focused application.
    fn insert(&self, text: &str) -> Result<(), String>;
    /// Put the full text on the clipboard.
    fn copy(&self, text: &str) -> Result<(), String>;
    /// Report a problem to the user.
    fn notify(&self, message: &str) -> Result<(), String>;
}

/// What happened to one finalized transcript.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Delivery {
    Inserted,
    Copied {
        insert_error: String,
    },
    Failed {
        insert_error: String,
        copy_error: String,
    },
}

/// Inserts once, and falls back to the clipboard without retrying the insertion.
pub fn deliver(output: &dyn TextOutput, text: &str) -> Delivery {
    match output.insert(text) {
        Ok(()) => Delivery::Inserted,
        Err(insert_error) => match output.copy(text) {
            Ok(()) => {
                let _ = output.notify(&format!(
                    "Whistt: could not type the transcript ({insert_error}); it is on the clipboard"
                ));
                Delivery::Copied { insert_error }
            }
            Err(copy_error) => {
                let _ = output.notify(&format!(
                    "Whistt: could not type the transcript ({insert_error}) or copy it ({copy_error})"
                ));
                Delivery::Failed {
                    insert_error,
                    copy_error,
                }
            }
        },
    }
}

/// A program plus fixed arguments.
#[derive(Debug, Clone)]
pub struct CommandSpec {
    pub program: OsString,
    pub args: Vec<OsString>,
}

impl CommandSpec {
    pub fn new(
        program: impl Into<OsString>,
        args: impl IntoIterator<Item = impl Into<OsString>>,
    ) -> Self {
        Self {
            program: program.into(),
            args: args.into_iter().map(Into::into).collect(),
        }
    }
}

/// The production adapter: `wtype`, `wl-copy`, and Hyprland notifications.
pub struct ProcessOutput {
    pub insert: CommandSpec,
    pub copy: CommandSpec,
    pub notify: CommandSpec,
}

impl ProcessOutput {
    pub fn system() -> Self {
        Self {
            insert: CommandSpec::new("wtype", ["-"]),
            copy: CommandSpec::new("wl-copy", [] as [&str; 0]),
            notify: CommandSpec::new("hyprctl", ["notify", "-1", "5000", "0"]),
        }
    }
}

impl Default for ProcessOutput {
    fn default() -> Self {
        Self::system()
    }
}

impl TextOutput for ProcessOutput {
    fn insert(&self, text: &str) -> Result<(), String> {
        run_with_stdin(&self.insert, text)
    }

    fn copy(&self, text: &str) -> Result<(), String> {
        run_with_stdin(&self.copy, text)
    }

    fn notify(&self, message: &str) -> Result<(), String> {
        let mut spec = self.notify.clone();
        spec.args.push(OsString::from(message));
        run_process(&spec, None, Duration::from_secs(5))
    }
}

fn run_with_stdin(spec: &CommandSpec, input: &str) -> Result<(), String> {
    run_process(spec, Some(input), Duration::from_secs(5))
}

fn run_process(spec: &CommandSpec, input: Option<&str>, timeout: Duration) -> Result<(), String> {
    let program = spec.program.to_string_lossy().into_owned();
    let runtime = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .map_err(|error| error.to_string())?;
    runtime.block_on(async {
        let mut child = Command::new(&spec.program)
            .args(&spec.args)
            .stdin(if input.is_some() {
                Stdio::piped()
            } else {
                Stdio::null()
            })
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .kill_on_drop(true)
            .spawn()
            .map_err(|error| format!("could not start {program}: {error}"))?;
        let result = tokio::time::timeout(timeout, async {
            if let Some(input) = input {
                let mut stdin = child
                    .stdin
                    .take()
                    .ok_or_else(|| format!("{program} did not accept stdin"))?;
                stdin
                    .write_all(input.as_bytes())
                    .await
                    .map_err(|error| format!("could not write to {program}: {error}"))?;
                // Close stdin without appending a newline.
            }
            let status = child
                .wait()
                .await
                .map_err(|error| format!("could not wait for {program}: {error}"))?;
            if status.success() {
                Ok(())
            } else {
                Err(format!("{program} exited with {status}"))
            }
        })
        .await;
        match result {
            Ok(Ok(())) => Ok(()),
            result => {
                // Kill and reap on write errors as well as deadline expiry.
                let _ = child.kill().await;
                match result {
                    Ok(Err(error)) => Err(error),
                    Err(_) => Err(format!("{program} timed out")),
                    Ok(Ok(())) => unreachable!(),
                }
            }
        }
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn deadlines_cover_blocked_stdin_and_process_exit() {
        let spec = CommandSpec::new("sleep", ["30"]);
        for input in [None, Some("x".repeat(1_000_000))] {
            let start = std::time::Instant::now();
            let result = run_process(&spec, input.as_deref(), Duration::from_millis(50));
            assert!(result.unwrap_err().contains("timed out"));
            assert!(start.elapsed() < Duration::from_secs(2));
        }
    }
}

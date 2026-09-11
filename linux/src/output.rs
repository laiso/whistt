//! Text delivery into the focused application.
//!
//! Text reaches `wtype` through stdin only. It is never interpolated into a
//! shell command, and a failed insertion is never retried: a partial insertion
//! cannot be rolled back in another application, so the transcript is copied to
//! the clipboard instead.

use std::ffi::OsString;
use std::io::Write;
use std::process::{Command, Stdio};

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
        let status = Command::new(&spec.program)
            .args(&spec.args)
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .status()
            .map_err(|error| {
                format!(
                    "could not start {}: {error}",
                    spec.program.to_string_lossy()
                )
            })?;
        if status.success() {
            Ok(())
        } else {
            Err(format!(
                "{} exited with {status}",
                spec.program.to_string_lossy()
            ))
        }
    }
}

fn run_with_stdin(spec: &CommandSpec, input: &str) -> Result<(), String> {
    let program = spec.program.to_string_lossy().into_owned();
    let mut child = Command::new(&spec.program)
        .args(&spec.args)
        .stdin(Stdio::piped())
        .stdout(Stdio::null())
        .stderr(Stdio::piped())
        .spawn()
        .map_err(|error| format!("could not start {program}: {error}"))?;

    {
        let mut stdin = child
            .stdin
            .take()
            .ok_or_else(|| format!("{program} did not accept stdin"))?;
        stdin
            .write_all(input.as_bytes())
            .map_err(|error| format!("could not write to {program}: {error}"))?;
        // Dropping stdin closes the pipe so the child sees end of input. No
        // newline is appended, so the focused application never sees an Enter.
    }

    let output = child
        .wait_with_output()
        .map_err(|error| format!("could not wait for {program}: {error}"))?;
    if output.status.success() {
        return Ok(());
    }
    let detail: String = String::from_utf8_lossy(&output.stderr)
        .trim()
        .chars()
        .take(200)
        .collect();
    Err(format!("{program} exited with {}: {detail}", output.status))
}

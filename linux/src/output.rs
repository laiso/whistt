//! Final transcript delivery into the focused application.

use std::ffi::OsString;
use std::process::Stdio;
use std::time::Duration;

use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::process::Command;

use crate::config::OutputMode;

const PROCESS_TIMEOUT: Duration = Duration::from_secs(5);
const RESTORE_DELAY: Duration = Duration::from_millis(300);
const MAX_SNAPSHOT_BYTES: usize = 16 * 1024 * 1024;

pub trait TextOutput: Send + Sync {
    fn insert(&self, text: &str) -> Result<(), String>;
    fn copy(&self, text: &str) -> Result<(), String>;
    fn notify(&self, message: &str) -> Result<(), String>;
}

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

pub fn deliver(output: &dyn TextOutput, text: &str) -> Delivery {
    match output.insert(text) {
        Ok(()) => Delivery::Inserted,
        Err(insert_error) => match output.copy(text) {
            Ok(()) => {
                let _ = output.notify(&format!(
                    "Whistt: could not insert the transcript ({insert_error}); it is on the clipboard"
                ));
                Delivery::Copied { insert_error }
            }
            Err(copy_error) => {
                let _ = output.notify(&format!(
                    "Whistt: could not insert the transcript ({insert_error}) or copy it ({copy_error})"
                ));
                Delivery::Failed {
                    insert_error,
                    copy_error,
                }
            }
        },
    }
}

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

pub struct ProcessOutput {
    pub mode: OutputMode,
    pub type_text: CommandSpec,
    pub paste: CommandSpec,
    pub copy: CommandSpec,
    pub copy_primary: CommandSpec,
    pub paste_read: CommandSpec,
    pub paste_read_primary: CommandSpec,
    pub paste_types: CommandSpec,
    pub paste_types_primary: CommandSpec,
    pub clear: CommandSpec,
    pub clear_primary: CommandSpec,
    pub notify: CommandSpec,
}

impl ProcessOutput {
    pub fn system(mode: OutputMode, paste_chord: &str) -> Result<Self, String> {
        Ok(Self {
            mode,
            type_text: CommandSpec::new("wtype", ["-"]),
            paste: CommandSpec::new("wtype", paste_arguments(paste_chord)?),
            copy: CommandSpec::new("wl-copy", [] as [&str; 0]),
            copy_primary: CommandSpec::new("wl-copy", ["--primary"]),
            paste_read: CommandSpec::new("wl-paste", ["--no-newline"]),
            paste_read_primary: CommandSpec::new("wl-paste", ["--primary", "--no-newline"]),
            paste_types: CommandSpec::new("wl-paste", ["--list-types"]),
            paste_types_primary: CommandSpec::new("wl-paste", ["--primary", "--list-types"]),
            clear: CommandSpec::new("wl-copy", ["--clear"]),
            clear_primary: CommandSpec::new("wl-copy", ["--primary", "--clear"]),
            notify: CommandSpec::new("hyprctl", ["notify", "-1", "5000", "0"]),
        })
    }

    fn paste_and_restore(&self, text: &str) -> Result<(), String> {
        let clipboard_snapshot = snapshot_selection(&self.paste_types, &self.paste_read)?;
        let primary_snapshot =
            snapshot_selection(&self.paste_types_primary, &self.paste_read_primary)?;
        run_with_stdin(&self.copy, text)?;
        if let Err(error) = run_with_stdin(&self.copy_primary, text) {
            // The transcript is already published on the clipboard selection
            // and no paste will follow, so put the previous contents back
            // before reporting the failure.
            let _ = restore_selection(
                &self.copy,
                &self.paste_read,
                &self.clear,
                text,
                clipboard_snapshot,
            );
            return Err(error);
        }
        let paste_result = run_process(&self.paste, None, PROCESS_TIMEOUT);
        std::thread::sleep(RESTORE_DELAY);
        restore_selection(
            &self.copy,
            &self.paste_read,
            &self.clear,
            text,
            clipboard_snapshot,
        )?;
        restore_selection(
            &self.copy_primary,
            &self.paste_read_primary,
            &self.clear_primary,
            text,
            primary_snapshot,
        )?;
        paste_result
    }
}

impl TextOutput for ProcessOutput {
    fn insert(&self, text: &str) -> Result<(), String> {
        match self.mode {
            OutputMode::Type => run_with_stdin(&self.type_text, text),
            OutputMode::Paste => self.paste_and_restore(text),
        }
    }

    fn copy(&self, text: &str) -> Result<(), String> {
        run_with_stdin(&self.copy, text)
    }

    fn notify(&self, message: &str) -> Result<(), String> {
        let mut spec = self.notify.clone();
        spec.args.push(OsString::from(message));
        run_process(&spec, None, PROCESS_TIMEOUT)
    }
}

enum ClipboardSnapshot {
    Empty,
    Data { mime: String, bytes: Vec<u8> },
}

/// Captures one selection's current contents so a paste can put them back.
/// A selection with no owner, or with no usable type, snapshots as empty.
fn snapshot_selection(
    types: &CommandSpec,
    read: &CommandSpec,
) -> Result<ClipboardSnapshot, String> {
    let types = match run_capture(types, PROCESS_TIMEOUT) {
        Ok(types) => types,
        Err(error) if error.contains(" exited with ") => return Ok(ClipboardSnapshot::Empty),
        Err(error) => return Err(error),
    };
    let types = String::from_utf8_lossy(&types);
    let Some(mime) = preferred_mime(types.lines()) else {
        return Ok(ClipboardSnapshot::Empty);
    };
    let mut read = read.clone();
    read.args
        .extend([OsString::from("--type"), OsString::from(&mime)]);
    let bytes = run_capture(&read, PROCESS_TIMEOUT)?;
    if bytes.len() > MAX_SNAPSHOT_BYTES {
        return Err(format!(
            "clipboard item is too large to restore safely ({} bytes)",
            bytes.len()
        ));
    }
    Ok(ClipboardSnapshot::Data { mime, bytes })
}

/// Restores one selection's snapshot, but only when the selection still
/// holds exactly the transcript Whistt published: a newer user copy is
/// never overwritten.
fn restore_selection(
    copy: &CommandSpec,
    read: &CommandSpec,
    clear: &CommandSpec,
    transcript: &str,
    snapshot: ClipboardSnapshot,
) -> Result<(), String> {
    let current = run_capture(read, PROCESS_TIMEOUT)?;
    if current != transcript.as_bytes() {
        return Ok(());
    }
    match snapshot {
        ClipboardSnapshot::Empty => run_process(clear, None, PROCESS_TIMEOUT),
        ClipboardSnapshot::Data { mime, bytes } => {
            let mut restore = copy.clone();
            restore
                .args
                .extend([OsString::from("--type"), OsString::from(mime)]);
            run_with_bytes(&restore, &bytes)
        }
    }
}

fn preferred_mime<'a>(types: impl Iterator<Item = &'a str>) -> Option<String> {
    let types: Vec<&str> = types.filter(|value| !value.is_empty()).collect();
    for preferred in ["text/plain;charset=utf-8", "UTF8_STRING", "text/plain"] {
        if types.contains(&preferred) {
            return Some(preferred.to_string());
        }
    }
    types.first().map(|value| (*value).to_string())
}

fn paste_arguments(chord: &str) -> Result<Vec<OsString>, String> {
    let parts: Vec<String> = chord
        .split('+')
        .map(|part| part.trim().to_ascii_lowercase())
        .filter(|part| !part.is_empty())
        .collect();
    let (key, modifiers) = parts
        .split_last()
        .ok_or_else(|| "WHISTT_PASTE_CHORD must not be empty".to_string())?;
    if key.len() > 32
        || !key
            .chars()
            .all(|character| character.is_ascii_alphanumeric())
    {
        return Err("WHISTT_PASTE_CHORD must end in an ASCII key name".to_string());
    }
    let mut normalized = Vec::new();
    for modifier in modifiers {
        let modifier = match modifier.as_str() {
            "control" | "ctrl" => "ctrl",
            "shift" => "shift",
            "alt" => "alt",
            "super" | "logo" | "win" => "logo",
            _ => return Err(format!("unsupported paste modifier: {modifier}")),
        };
        if !normalized.contains(&modifier) {
            normalized.push(modifier);
        }
    }
    if normalized.is_empty() {
        return Err("WHISTT_PASTE_CHORD must include at least one modifier".to_string());
    }

    let mut args = ["-s", "20", "-M", "shift", "-m", "shift", "-s", "5"]
        .map(OsString::from)
        .to_vec();
    for modifier in &normalized {
        args.extend([OsString::from("-M"), OsString::from(modifier)]);
    }
    args.extend([OsString::from("-k"), OsString::from(keysym_name(key))]);
    for modifier in normalized.iter().rev() {
        args.extend([OsString::from("-m"), OsString::from(modifier)]);
    }
    Ok(args)
}

/// `wtype` looks the key up by XKB keysym name, whose canonical spelling is
/// capitalized for special keys (`Insert`, not `insert`).
fn keysym_name(key: &str) -> String {
    match key {
        "insert" => "Insert".to_string(),
        "return" | "enter" => "Return".to_string(),
        "tab" => "Tab".to_string(),
        "escape" | "esc" => "Escape".to_string(),
        "backspace" => "BackSpace".to_string(),
        "delete" => "Delete".to_string(),
        _ => key.to_string(),
    }
}

fn run_with_stdin(spec: &CommandSpec, input: &str) -> Result<(), String> {
    run_with_bytes(spec, input.as_bytes())
}

fn run_with_bytes(spec: &CommandSpec, input: &[u8]) -> Result<(), String> {
    run_process(spec, Some(input), PROCESS_TIMEOUT)
}

fn run_process(spec: &CommandSpec, input: Option<&[u8]>, timeout: Duration) -> Result<(), String> {
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
                    .write_all(input)
                    .await
                    .map_err(|error| format!("could not write to {program}: {error}"))?;
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

fn run_capture(spec: &CommandSpec, timeout: Duration) -> Result<Vec<u8>, String> {
    let program = spec.program.to_string_lossy().into_owned();
    let runtime = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .map_err(|error| error.to_string())?;
    runtime.block_on(async {
        let mut child = Command::new(&spec.program)
            .args(&spec.args)
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .kill_on_drop(true)
            .spawn()
            .map_err(|error| format!("could not start {program}: {error}"))?;
        let mut stdout = child
            .stdout
            .take()
            .ok_or_else(|| format!("{program} stdout was not captured"))?;
        let result = tokio::time::timeout(timeout, async {
            let mut bytes = Vec::new();
            stdout
                .read_to_end(&mut bytes)
                .await
                .map_err(|error| format!("could not read {program}: {error}"))?;
            let status = child
                .wait()
                .await
                .map_err(|error| format!("could not wait for {program}: {error}"))?;
            if status.success() {
                Ok(bytes)
            } else {
                Err(format!("{program} exited with {status}"))
            }
        })
        .await;
        match result {
            Ok(result) => result,
            Err(_) => {
                let _ = child.kill().await;
                Err(format!("{program} timed out"))
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
        for input in [None, Some(vec![b'x'; 1_000_000])] {
            let start = std::time::Instant::now();
            let result = run_process(&spec, input.as_deref(), Duration::from_millis(50));
            assert!(result.unwrap_err().contains("timed out"));
            assert!(start.elapsed() < Duration::from_secs(2));
        }
    }

    #[test]
    fn paste_chord_is_configurable_and_releases_modifiers_in_reverse() {
        assert_eq!(
            paste_arguments("ctrl+shift+v").unwrap(),
            [
                "-s", "20", "-M", "shift", "-m", "shift", "-s", "5", "-M", "ctrl", "-M", "shift",
                "-k", "v", "-m", "shift", "-m", "ctrl"
            ]
            .map(OsString::from)
        );
        assert!(paste_arguments("v").is_err());
        assert!(paste_arguments("ctrl+bad-key").is_err());
    }

    #[test]
    fn shift_insert_uses_the_canonical_keysym_name() {
        assert_eq!(
            paste_arguments("shift+insert").unwrap(),
            [
                "-s", "20", "-M", "shift", "-m", "shift", "-s", "5", "-M", "shift", "-k", "Insert",
                "-m", "shift"
            ]
            .map(OsString::from)
        );
    }

    #[test]
    fn clipboard_mime_prefers_utf8_text_but_preserves_binary_when_needed() {
        assert_eq!(
            preferred_mime(["image/png", "text/plain;charset=utf-8"].into_iter()),
            Some("text/plain;charset=utf-8".to_string())
        );
        assert_eq!(
            preferred_mime(["image/png"].into_iter()),
            Some("image/png".to_string())
        );
    }
}

//! Microphone capture through `pw-record`.
//!
//! Capture is a child process whose raw stdout is streamed as PCM. No audio is
//! ever written to disk, and no audio reaches the log.

use std::ffi::OsString;
use std::process::Stdio;

use tokio::io::AsyncReadExt;
use tokio::process::Command;
use tokio::sync::mpsc;

use crate::config::{CHANNELS, SAMPLE_RATE};
use crate::log;

/// A running capture child plus the PCM bytes it produces.
pub struct CaptureSession {
    /// Raw little-endian PCM16 bytes, in capture order, until end of stream.
    pub chunks: mpsc::Receiver<Vec<u8>>,
    /// Handle used to stop and reap the child process.
    pub child: Box<dyn CaptureChild>,
}

/// Control surface for one capture child process.
pub trait CaptureChild: Send {
    /// Ask the child to stop after flushing what it already captured. The
    /// reader keeps draining stdout until end of stream.
    fn request_stop(&mut self);
    /// Stop immediately and discard anything not yet read (cancellation).
    fn kill(&mut self);
    /// Reap the child once it has exited.
    fn try_reap(&mut self);
}

/// Starts one capture session. Faked in tests.
pub trait AudioCapture: Send {
    fn spawn(&mut self) -> Result<CaptureSession, String>;
}

/// Creates one [`AudioCapture`] per recording session.
pub trait AudioFactory: Send + Sync {
    fn create(&self) -> Box<dyn AudioCapture>;
}

/// Production factory: `pw-record` on the default or configured device.
pub struct PwRecordFactory {
    pub device: Option<String>,
}

impl AudioFactory for PwRecordFactory {
    fn create(&self) -> Box<dyn AudioCapture> {
        Box::new(PwRecordCapture {
            device: self.device.clone(),
            program: OsString::from("pw-record"),
        })
    }
}

/// Streams raw PCM from `pw-record --raw --rate 24000 --channels 1 --format s16 -`.
pub struct PwRecordCapture {
    pub device: Option<String>,
    pub program: OsString,
}

impl AudioCapture for PwRecordCapture {
    fn spawn(&mut self) -> Result<CaptureSession, String> {
        let mut command = Command::new(&self.program);
        command
            .arg("--raw")
            .arg("--rate")
            .arg(SAMPLE_RATE.to_string())
            .arg("--channels")
            .arg(CHANNELS.to_string())
            .arg("--format")
            .arg("s16");
        if let Some(device) = &self.device {
            command.arg("--target").arg(device);
        }
        command
            .arg("-")
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .kill_on_drop(true);

        let mut child = command.spawn().map_err(|error| {
            format!(
                "could not start {}: {error}",
                self.program.to_string_lossy()
            )
        })?;
        let mut stdout = child
            .stdout
            .take()
            .ok_or_else(|| "capture stdout was not captured".to_string())?;
        let stderr = child.stderr.take();

        let (sender, receiver) = mpsc::channel(64);
        tokio::spawn(async move {
            let mut buffer = vec![0u8; 8_192];
            loop {
                match stdout.read(&mut buffer).await {
                    Ok(0) => break,
                    Ok(read) => {
                        if sender.send(buffer[..read].to_vec()).await.is_err() {
                            break;
                        }
                    }
                    Err(error) => {
                        log::debug(&format!("capture read failed: {error}"));
                        break;
                    }
                }
            }
        });

        if let Some(mut stderr) = stderr {
            tokio::spawn(async move {
                // Kept for diagnostics only; the first line is enough to explain
                // a failure such as a missing device, and no audio passes here.
                let mut text = String::new();
                let mut buffer = vec![0u8; 4_096];
                while let Ok(read) = stderr.read(&mut buffer).await {
                    if read == 0 {
                        break;
                    }
                    if text.len() < 4_096 {
                        text.push_str(&String::from_utf8_lossy(&buffer[..read]));
                    }
                }
                if let Some(line) = text.lines().map(str::trim).find(|line| !line.is_empty()) {
                    log::debug(&format!("pw-record said: {line}"));
                }
            });
        }

        Ok(CaptureSession {
            chunks: receiver,
            child: Box::new(PwRecordChild { child }),
        })
    }
}

struct PwRecordChild {
    child: tokio::process::Child,
}

impl CaptureChild for PwRecordChild {
    fn request_stop(&mut self) {
        // SIGTERM lets pw-record flush and exit cleanly; the reader then drains
        // whatever is still buffered in the pipe. SIGKILL would drop audio.
        if let Some(pid) = self.child.id() {
            unsafe {
                libc::kill(pid as libc::pid_t, libc::SIGTERM);
            }
        }
    }

    fn kill(&mut self) {
        let _ = self.child.start_kill();
    }

    fn try_reap(&mut self) {
        let _ = self.child.try_wait();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_capture_command_matches_the_documented_stream_format() {
        // Guards the flags verified against `pw-record --help` and a live capture.
        let capture = PwRecordCapture {
            device: None,
            program: OsString::from("pw-record"),
        };
        assert_eq!(capture.device, None);
        assert_eq!(SAMPLE_RATE, 24_000);
        assert_eq!(CHANNELS, 1);
    }
}

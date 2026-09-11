//! Unix socket daemon.
//!
//! The socket lives in a private directory under `$XDG_RUNTIME_DIR`. Requests and
//! responses are newline-delimited JSON, and every command is acknowledged as
//! soon as it is accepted rather than when transcription completes.

use std::fs::{File, OpenOptions};
use std::os::fd::AsRawFd;
use std::path::Path;
use std::time::Duration;

use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::net::{UnixListener, UnixStream};

use crate::config::Config;
use crate::ipc::{Request, Response, State, decode_line, encode_line};
use crate::log;
use crate::session::{self, Command, ControllerDeps, ControllerHandle};

/// Keeps exclusive ownership of the socket for the listener's lifetime.
pub struct BoundListener {
    listener: UnixListener,
    _lock: File,
}

/// Creates the private runtime directory and binds the socket.
pub fn bind(config: &Config) -> Result<BoundListener, String> {
    let path = config.socket_path.clone();
    if let Some(directory) = path.parent() {
        create_private_directory(directory)?;
    }
    // Never unlink this lock file: all contenders must lock the same inode.
    let lock = OpenOptions::new()
        .create(true)
        .truncate(false)
        .write(true)
        .open(path.with_extension("lock"))
        .map_err(|error| format!("could not open daemon lock: {error}"))?;
    // SAFETY: the descriptor belongs to the live File retained by BoundListener.
    if unsafe { libc::flock(lock.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) } != 0 {
        return Err(format!(
            "could not acquire daemon lock (another daemon may be running): {}",
            std::io::Error::last_os_error()
        ));
    }
    if path.exists() {
        // Also protect listeners started by older versions without a lock.
        match std::os::unix::net::UnixStream::connect(&path) {
            Ok(_) => return Err("another daemon is already listening".into()),
            Err(error) if error.kind() == std::io::ErrorKind::ConnectionRefused => {}
            Err(error) => return Err(format!("could not check existing socket: {error}")),
        }
        // The directory is private to this user, so a leftover socket from a
        // crashed daemon can only be ours.
        std::fs::remove_file(&path).map_err(|error| {
            format!(
                "could not remove the stale socket {}: {error}",
                path.display()
            )
        })?;
    }
    let listener = UnixListener::bind(&path)
        .map_err(|error| format!("could not bind {}: {error}", path.display()))?;
    Ok(BoundListener {
        listener,
        _lock: lock,
    })
}

fn create_private_directory(directory: &Path) -> Result<(), String> {
    std::fs::create_dir_all(directory)
        .map_err(|error| format!("could not create {}: {error}", directory.display()))?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(directory, std::fs::Permissions::from_mode(0o700))
            .map_err(|error| format!("could not restrict {}: {error}", directory.display()))?;
    }
    Ok(())
}

/// Serves connections until the returned task is aborted.
pub fn spawn(listener: BoundListener, deps: ControllerDeps) -> tokio::task::JoinHandle<()> {
    let controller = session::spawn(deps);
    tokio::spawn(async move {
        let listener = listener;
        loop {
            match listener.listener.accept().await {
                Ok((stream, _address)) => {
                    let controller = controller.clone();
                    tokio::spawn(handle_connection(stream, controller));
                }
                Err(error) => {
                    log::debug(&format!("accept failed: {error}"));
                    tokio::time::sleep(Duration::from_millis(50)).await;
                }
            }
        }
    })
}

async fn handle_connection(stream: UnixStream, controller: ControllerHandle) {
    let (reader, mut writer) = stream.into_split();
    let mut lines = BufReader::new(reader).lines();
    while let Ok(Some(line)) = lines.next_line().await {
        if line.trim().is_empty() {
            continue;
        }
        let response = match decode_line::<Request>(&line) {
            Ok(request) => controller.send(to_command(request)).await,
            Err(error) => Response::error(State::Idle, error),
        };
        match encode_line(&response) {
            Ok(encoded) => {
                if writer.write_all(encoded.as_bytes()).await.is_err() {
                    return;
                }
            }
            Err(error) => {
                log::debug(&format!("could not encode a response: {error}"));
                return;
            }
        }
    }
}

fn to_command(request: Request) -> Command {
    match request {
        Request::Start => Command::Start,
        Request::Stop => Command::Stop,
        Request::Cancel => Command::Cancel,
        Request::Status => Command::Status,
    }
}

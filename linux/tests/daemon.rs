//! Daemon and CLI integration tests over a real Unix socket.

mod common;

use std::path::PathBuf;
use std::sync::Arc;
use std::time::Duration;

use common::{FakeAudioPool, FakeOutput, FakeTransportPool, temporary_directory, test_config};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::net::UnixStream;
use whistt::config::Config;
use whistt::ipc::{Request, Response, State, decode_line, encode_line};
use whistt::session::ControllerDeps;

struct Daemon {
    socket: PathBuf,
    directory: PathBuf,
    server: tokio::task::JoinHandle<()>,
    transport: FakeTransportPool,
}

impl Daemon {
    async fn start(mut config: Config, label: &str) -> Self {
        let directory = temporary_directory(label);
        config.socket_path = directory.join("whistt").join("daemon.sock");
        let transport = FakeTransportPool::new();
        let deps = ControllerDeps {
            config: config.clone(),
            audio: Arc::new(FakeAudioPool::new()),
            transport: Arc::new(transport.clone()),
            output: Arc::new(FakeOutput::new()),
        };
        let listener = whistt::daemon::bind(&config).expect("the socket should bind");
        let server = whistt::daemon::spawn(listener, deps);
        Self {
            socket: config.socket_path,
            directory,
            server,
            transport,
        }
    }

    async fn send(&self, request: Request) -> Response {
        let stream = UnixStream::connect(&self.socket)
            .await
            .expect("the daemon should accept");
        let (reader, mut writer) = stream.into_split();
        writer
            .write_all(encode_line(&request).unwrap().as_bytes())
            .await
            .unwrap();
        let mut lines = BufReader::new(reader).lines();
        let line = lines.next_line().await.unwrap().expect("a response line");
        decode_line::<Response>(&line).unwrap()
    }
}

impl Drop for Daemon {
    fn drop(&mut self) {
        self.server.abort();
        let _ = std::fs::remove_dir_all(&self.directory);
    }
}

#[tokio::test]
async fn a_command_is_acknowledged_before_transcription_finishes() {
    let mut config = test_config();
    config.setup_timeout = Duration::from_secs(30);
    let daemon = Daemon::start(config, "ack").await;

    // The provider never reports readiness, so nothing can complete.
    let started = daemon.send(Request::Start).await;
    assert!(started.ok);
    assert_eq!(started.state, State::Recording);
    assert_eq!(daemon.transport.count(), 1);
    assert_eq!(
        daemon.transport.session(0).commits(),
        0,
        "the acknowledgement must not wait for transcription"
    );

    assert_eq!(daemon.send(Request::Status).await.state, State::Recording);
    assert_eq!(daemon.send(Request::Cancel).await.state, State::Idle);
    assert_eq!(daemon.send(Request::Status).await.state, State::Idle);
}

#[tokio::test]
async fn status_is_available_while_idle() {
    let daemon = Daemon::start(test_config(), "idle").await;
    let response = daemon.send(Request::Status).await;
    assert!(response.ok);
    assert_eq!(response.state, State::Idle);
    assert!(response.session.is_none());
}

#[tokio::test]
async fn a_release_without_a_press_is_harmless_over_the_protocol() {
    let daemon = Daemon::start(test_config(), "stop-idle").await;
    let response = daemon.send(Request::Stop).await;
    assert!(response.ok);
    assert_eq!(response.state, State::Idle);
}

#[test]
fn a_missing_daemon_produces_a_clear_error() {
    let directory = temporary_directory("no-daemon");
    let output = std::process::Command::new(env!("CARGO_BIN_EXE_whistt"))
        .arg("status")
        .env("XDG_RUNTIME_DIR", &directory)
        .output()
        .expect("the whistt binary should run");

    assert!(!output.status.success());
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(stderr.contains("no daemon is listening"), "{stderr}");
    assert!(stderr.contains("whistt daemon"), "{stderr}");
    let _ = std::fs::remove_dir_all(directory);
}

#[test]
fn the_daemon_refuses_to_start_without_credentials() {
    let directory = temporary_directory("no-credentials");
    let output = std::process::Command::new(env!("CARGO_BIN_EXE_whistt"))
        .arg("daemon")
        .env("XDG_RUNTIME_DIR", &directory)
        .env_remove("OPENAI_API_KEY")
        .output()
        .expect("the whistt binary should run");

    assert!(!output.status.success());
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(stderr.contains("OPENAI_API_KEY is not set"), "{stderr}");
    let _ = std::fs::remove_dir_all(directory);
}

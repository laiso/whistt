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

#[tokio::test]
async fn a_second_daemon_cannot_replace_the_live_socket() {
    let daemon = Daemon::start(test_config(), "duplicate").await;
    assert_eq!(daemon.send(Request::Start).await.state, State::Recording);
    let mut config = test_config();
    config.socket_path = daemon.socket.clone();
    assert!(whistt::daemon::bind(&config).is_err());
    assert_eq!(daemon.send(Request::Status).await.state, State::Recording);
    assert_eq!(daemon.send(Request::Cancel).await.state, State::Idle);
}

#[tokio::test]
async fn a_stale_socket_can_be_rebound_after_ownership_is_released() {
    let directory = temporary_directory("stale");
    let mut config = test_config();
    config.socket_path = directory.join("daemon.sock");
    let first = whistt::daemon::bind(&config).unwrap();
    assert!(whistt::daemon::bind(&config).is_err());
    drop(first);
    let second = whistt::daemon::bind(&config).unwrap();
    drop(second);
    std::fs::remove_dir_all(directory).unwrap();
}

#[tokio::test]
async fn malformed_request_reports_the_live_daemon_state() {
    let mut config = test_config();
    config.setup_timeout = Duration::from_secs(30);
    let daemon = Daemon::start(config, "malformed-state").await;
    assert_eq!(daemon.send(Request::Start).await.state, State::Recording);

    let stream = UnixStream::connect(&daemon.socket).await.unwrap();
    let (reader, mut writer) = stream.into_split();
    writer
        .write_all(b"{\"command\":\"unknown\"}\n")
        .await
        .unwrap();
    let mut lines = BufReader::new(reader).lines();
    let line = lines.next_line().await.unwrap().unwrap();
    let response = decode_line::<Response>(&line).unwrap();
    assert!(!response.ok);
    assert_eq!(response.state, State::Recording);

    assert_eq!(daemon.send(Request::Cancel).await.state, State::Idle);
}

#[tokio::test]
async fn bar_status_script_handles_live_daemon_missing_binary_and_hung_socket() {
    use std::os::unix::fs::PermissionsExt;

    let manifest_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let script = manifest_dir.join("integration/quickshell/whistt-status");
    let bin_exe = PathBuf::from(env!("CARGO_BIN_EXE_whistt"));

    let mut config = test_config();
    config.setup_timeout = Duration::from_secs(30);
    let daemon = Daemon::start(config, "bar-status").await;
    let bin_dir = daemon.directory.join("bin");
    std::fs::create_dir_all(&bin_dir).unwrap();
    std::os::unix::fs::symlink(&bin_exe, bin_dir.join("whistt")).unwrap();
    let path_with_whistt = format!(
        "{}:{}",
        bin_dir.display(),
        std::env::var("PATH").unwrap_or_default()
    );

    // 1. Live daemon in `idle` state.
    let idle_out = tokio::process::Command::new(&script)
        .env("XDG_RUNTIME_DIR", &daemon.directory)
        .env("PATH", &path_with_whistt)
        .output()
        .await
        .unwrap();
    assert!(idle_out.status.success());
    let idle_json: serde_json::Value = serde_json::from_slice(&idle_out.stdout).unwrap();
    assert_eq!(idle_json["tooltip"], "Whistt: idle");
    assert_eq!(idle_json["class"], "");

    // 2. Live daemon in `recording` state.
    assert_eq!(daemon.send(Request::Start).await.state, State::Recording);
    let rec_out = tokio::process::Command::new(&script)
        .env("XDG_RUNTIME_DIR", &daemon.directory)
        .env("PATH", &path_with_whistt)
        .output()
        .await
        .unwrap();
    assert!(rec_out.status.success());
    let rec_json: serde_json::Value = serde_json::from_slice(&rec_out.stdout).unwrap();
    assert_eq!(rec_json["tooltip"], "Whistt: recording");
    assert_eq!(rec_json["class"], "");
    assert_eq!(daemon.send(Request::Cancel).await.state, State::Idle);

    // 3. Missing `whistt` binary AND unset `HOME` (verifies `set -u` safety).
    let missing_dir = temporary_directory("bar-missing");
    let missing_out = tokio::process::Command::new(&script)
        .env("XDG_RUNTIME_DIR", &missing_dir)
        .env_remove("HOME")
        .env("PATH", "/usr/bin:/bin")
        .output()
        .await
        .unwrap();
    assert!(missing_out.status.success());
    let missing_json: serde_json::Value = serde_json::from_slice(&missing_out.stdout).unwrap();
    assert_eq!(missing_json["tooltip"], "Whistt: not running");
    assert_eq!(missing_json["class"], "active");
    let _ = std::fs::remove_dir_all(missing_dir);

    // 4. Hung Unix socket that accepts connections without ever replying.
    let hung_dir = temporary_directory("bar-hung");
    let hung_sock_dir = hung_dir.join("whistt");
    std::fs::create_dir_all(&hung_sock_dir).unwrap();
    std::fs::set_permissions(&hung_sock_dir, std::fs::Permissions::from_mode(0o700)).unwrap();
    let hung_listener =
        std::os::unix::net::UnixListener::bind(hung_sock_dir.join("daemon.sock")).unwrap();
    let start = std::time::Instant::now();
    let hung_out = tokio::process::Command::new(&script)
        .env("XDG_RUNTIME_DIR", &hung_dir)
        .env("PATH", &path_with_whistt)
        .output()
        .await
        .unwrap();
    assert!(hung_out.status.success());
    assert!(
        start.elapsed() < Duration::from_secs(3),
        "bar status script must time out promptly on a hung daemon socket"
    );
    let hung_json: serde_json::Value = serde_json::from_slice(&hung_out.stdout).unwrap();
    assert_eq!(hung_json["tooltip"], "Whistt: not running");
    assert_eq!(hung_json["class"], "active");
    drop(hung_listener);
    let _ = std::fs::remove_dir_all(hung_dir);
}

#[test]
fn binding_scripts_reject_unsafe_inputs_and_verify_with_mocked_hyprctl() {
    use std::os::unix::fs::PermissionsExt;

    let manifest_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let apply_script = manifest_dir.join("scripts/apply-binding.sh");
    let check_script = manifest_dir.join("scripts/check-binding.sh");
    let directory = temporary_directory("binding-scripts");
    let stub_bin = directory.join("bin");
    std::fs::create_dir_all(&stub_bin).unwrap();
    let bindings_file = directory.join("bindings.lua");

    let hyprctl = stub_bin.join("hyprctl");
    std::fs::write(
        &hyprctl,
        r#"#!/bin/sh
case "$1" in
  reload) exit 0 ;;
  configerrors) exit 0 ;;
  binds)
    cat <<'JSON'
[
  {"key":"Alt_R","modmask":0,"release":false,"repeat":false,"non_consuming":false,"description":"Whistt push-to-talk (start)"},
  {"key":"Alt_R","modmask":8,"release":true,"repeat":false,"non_consuming":false,"description":"Whistt push-to-talk (stop)"}
]
JSON
    ;;
  devices)
    cat <<'JSON'
{"keyboards":[{"name":"test-kb","capsLock":false}]}
JSON
    ;;
  *) exit 1 ;;
esac
"#,
    )
    .unwrap();
    let mut perms = std::fs::metadata(&hyprctl).unwrap().permissions();
    perms.set_mode(0o755);
    std::fs::set_permissions(&hyprctl, perms).unwrap();

    let whistt_stub = stub_bin.join("whistt");
    std::fs::write(&whistt_stub, "#!/bin/sh\nexit 1\n").unwrap();
    let mut wperms = std::fs::metadata(&whistt_stub).unwrap().permissions();
    wperms.set_mode(0o755);
    std::fs::set_permissions(&whistt_stub, wperms).unwrap();

    let mocked_path = format!(
        "{}:{}",
        stub_bin.display(),
        std::env::var("PATH").unwrap_or_default()
    );

    // 1. Modifier key without RELEASE_MODIFIER is rejected before editing bindings.lua.
    let missing_mod = std::process::Command::new(&apply_script)
        .arg("Alt_R")
        .env("HYPRLAND_BINDINGS", &bindings_file)
        .env("PATH", &mocked_path)
        .output()
        .unwrap();
    assert_eq!(missing_mod.status.code(), Some(2));
    assert!(!bindings_file.exists());

    // 2. Quote injection in key name is rejected.
    let bad_key = std::process::Command::new(&apply_script)
        .arg("Alt_R\"); os.execute(\"id")
        .env("HYPRLAND_BINDINGS", &bindings_file)
        .env("PATH", &mocked_path)
        .output()
        .unwrap();
    assert_eq!(bad_key.status.code(), Some(2));
    assert!(!bindings_file.exists());

    // 3. Valid modifier key + RELEASE_MODIFIER applies cleanly.
    let applied = std::process::Command::new(&apply_script)
        .args(["Alt_R", "ALT"])
        .env("HYPRLAND_BINDINGS", &bindings_file)
        .env("PATH", &mocked_path)
        .output()
        .unwrap();
    assert!(
        applied.status.success(),
        "{}",
        String::from_utf8_lossy(&applied.stderr)
    );
    let written = std::fs::read_to_string(&bindings_file).unwrap();
    assert!(written.contains("o.bind(\"Alt_R\""));
    assert!(written.contains("o.bind(\"ALT + Alt_R\""));

    // 4. `check-binding.sh` passes when no daemon socket exists.
    let check_ok = std::process::Command::new(&check_script)
        .arg("Alt_R")
        .env("XDG_RUNTIME_DIR", &directory)
        .env("PATH", &mocked_path)
        .output()
        .unwrap();
    assert!(
        check_ok.status.success(),
        "{}{}",
        String::from_utf8_lossy(&check_ok.stdout),
        String::from_utf8_lossy(&check_ok.stderr)
    );

    // 5. `check-binding.sh` fails if a stale daemon socket exists and `whistt status` fails.
    let sock_dir = directory.join("whistt");
    std::fs::create_dir_all(&sock_dir).unwrap();
    let stale_listener =
        std::os::unix::net::UnixListener::bind(sock_dir.join("daemon.sock")).unwrap();
    let check_stale = std::process::Command::new(&check_script)
        .arg("Alt_R")
        .env("XDG_RUNTIME_DIR", &directory)
        .env("PATH", &mocked_path)
        .output()
        .unwrap();
    assert!(
        !check_stale.status.success(),
        "stale/failing daemon status must fail check-binding.sh"
    );
    drop(stale_listener);
    let _ = std::fs::remove_dir_all(directory);
}

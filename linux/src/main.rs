//! Whistt CLI: `daemon`, `record start|stop|cancel`, and `status`.

use std::process::ExitCode;
use std::sync::Arc;

use clap::{Parser, Subcommand};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::net::UnixStream;

use whistt::audio::PwRecordFactory;
use whistt::config::Config;
use whistt::daemon;
use whistt::ipc::{Request, Response, decode_line, encode_line};
use whistt::log;
use whistt::openai::OpenAiTransportFactory;
use whistt::output::ProcessOutput;
use whistt::session::ControllerDeps;

#[derive(Parser)]
#[command(
    name = "whistt",
    about = "Push-to-talk dictation for Omarchy and Hyprland"
)]
struct Cli {
    #[command(subcommand)]
    command: Top,
}

#[derive(Subcommand)]
enum Top {
    /// Run the background daemon in the foreground.
    Daemon,
    /// Control microphone capture.
    Record {
        #[command(subcommand)]
        action: RecordAction,
    },
    /// Print the current session state.
    Status,
}

#[derive(Subcommand)]
enum RecordAction {
    /// Start a push-to-talk session.
    Start,
    /// Stop capture and insert the completed transcript.
    Stop,
    /// Discard the session without inserting anything.
    Cancel,
}

#[tokio::main]
async fn main() -> ExitCode {
    let cli = Cli::parse();
    let config = match Config::from_env() {
        Ok(config) => config,
        Err(error) => {
            eprintln!("whistt: {error}");
            return ExitCode::FAILURE;
        }
    };
    match run(cli.command, config).await {
        Ok(()) => ExitCode::SUCCESS,
        Err(error) => {
            eprintln!("whistt: {error}");
            ExitCode::FAILURE
        }
    }
}

async fn run(command: Top, config: Config) -> Result<(), String> {
    match command {
        Top::Daemon => run_daemon(config).await,
        Top::Status => {
            let response = request(&config, Request::Status).await?;
            report(Request::Status, response)
        }
        Top::Record { action } => {
            let command = match action {
                RecordAction::Start => Request::Start,
                RecordAction::Stop => Request::Stop,
                RecordAction::Cancel => Request::Cancel,
            };
            let response = request(&config, command).await?;
            report(command, response)
        }
    }
}

async fn run_daemon(config: Config) -> Result<(), String> {
    let socket_path = config.socket_path.clone();
    let api_key = config
        .api_key
        .clone()
        .ok_or("OPENAI_API_KEY is not set; Whistt reads it from the process environment")?;

    let listener = daemon::bind(&config)?;
    log::info(&format!("listening on {}", socket_path.display()));
    log::info(&format!(
        "model {}; capture through pw-record; text through wtype",
        config.model
    ));

    let deps = ControllerDeps {
        audio: Arc::new(PwRecordFactory {
            device: config.device.clone(),
        }),
        transport: Arc::new(OpenAiTransportFactory {
            api_key,
            model: config.model.clone(),
        }),
        output: Arc::new(ProcessOutput::system()),
        config,
    };
    let server = daemon::spawn(listener, deps);

    tokio::signal::ctrl_c()
        .await
        .map_err(|error| format!("could not listen for Ctrl+C: {error}"))?;
    server.abort();
    let _ = std::fs::remove_file(&socket_path);
    log::info("stopped");
    Ok(())
}

async fn request(config: &Config, request: Request) -> Result<Response, String> {
    let stream = UnixStream::connect(&config.socket_path)
        .await
        .map_err(|error| {
            format!(
                "no daemon is listening on {} ({error}); start one with `whistt daemon`",
                config.socket_path.display()
            )
        })?;
    let (reader, mut writer) = stream.into_split();
    writer
        .write_all(encode_line(&request)?.as_bytes())
        .await
        .map_err(|error| format!("could not send the command: {error}"))?;
    let mut lines = BufReader::new(reader).lines();
    let line = lines
        .next_line()
        .await
        .map_err(|error| format!("could not read the response: {error}"))?
        .ok_or("the daemon closed the connection without responding")?;
    decode_line::<Response>(&line)
}

fn report(request: Request, response: Response) -> Result<(), String> {
    if !response.ok {
        return Err(response
            .error
            .unwrap_or_else(|| "the daemon rejected the command".to_string()));
    }
    if request == Request::Status {
        println!("{}", response.state.as_str());
    } else {
        println!("ok: {}", response.state.as_str());
    }
    Ok(())
}

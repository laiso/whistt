//! Session-controller tests.
//!
//! Every boundary is a fake, so ordering, readiness, cancellation, limits, and
//! failures are exercised without a microphone, a network, or a keyboard.

mod common;

use std::time::Duration;

use common::{harness, settle, test_config, wait_for_state};
use whistt::ipc::State;
use whistt::session::Command;
use whistt::transport::TranscriptEvent;

const CHUNK_BYTES: usize = 4_800;

fn chunk(fill: u8) -> Vec<u8> {
    vec![fill; CHUNK_BYTES]
}

#[tokio::test]
async fn start_then_stop_sends_every_chunk_before_one_commit_and_inserts_once() {
    let mut config = test_config();
    config.setup_timeout = Duration::from_secs(5);
    let harness = harness(config);
    harness.audio.script(vec![chunk(1)], vec![vec![2u8; 2_400]]);

    let started = harness.controller.send(Command::Start).await;
    assert!(started.ok);
    assert_eq!(started.state, State::Recording);
    assert!(started.session.is_some());

    let provider = harness.transport.session(0);
    provider.push(TranscriptEvent::Ready);
    provider.wait_for_audio(1).await;

    let stopped = harness.controller.send(Command::Stop).await;
    assert_eq!(stopped.state, State::Finalizing);
    provider.wait_for_commit().await;

    provider.push(TranscriptEvent::Final("こんにちは\n世界".to_string()));
    harness.output.wait_for_inserts(1).await;

    assert_eq!(provider.audio(), vec![chunk(1), vec![2u8; 2_400]]);
    assert_eq!(provider.commits(), 1);
    assert_eq!(
        harness.output.insert_attempts(),
        vec!["こんにちは\n世界".to_string()]
    );
    assert_eq!(
        harness.controller.send(Command::Status).await.state,
        State::Idle
    );
    assert!(harness.audio.session(0).stop_requested());
}

#[tokio::test]
async fn a_release_before_readiness_buffers_audio_and_commits_only_after_flushing() {
    let mut config = test_config();
    config.setup_timeout = Duration::from_secs(5);
    let harness = harness(config);
    harness.audio.script_initial(vec![chunk(1), chunk(2)]);

    assert_eq!(
        harness.controller.send(Command::Start).await.state,
        State::Recording
    );
    // Release immediately, while the provider is still connecting.
    assert_eq!(
        harness.controller.send(Command::Stop).await.state,
        State::Finalizing
    );

    let provider = harness.transport.session(0);
    settle().await;
    assert_eq!(
        provider.commits(),
        0,
        "the turn must not be committed before readiness"
    );
    assert!(
        provider.audio().is_empty(),
        "audio must be buffered until the provider session is ready"
    );

    provider.push(TranscriptEvent::Ready);
    provider.wait_for_commit().await;
    provider.push(TranscriptEvent::Final("ok".to_string()));
    harness.output.wait_for_inserts(1).await;

    assert_eq!(provider.audio(), vec![chunk(1), chunk(2)]);
    assert_eq!(provider.commits(), 1);
}

#[tokio::test]
async fn a_second_start_while_recording_is_harmless() {
    let mut config = test_config();
    config.setup_timeout = Duration::from_secs(5);
    let harness = harness(config);
    harness.audio.script_initial(vec![chunk(1)]);

    assert_eq!(
        harness.controller.send(Command::Start).await.state,
        State::Recording
    );
    let provider = harness.transport.session(0);
    provider.push(TranscriptEvent::Ready);
    provider.wait_for_audio(1).await;

    let again = harness.controller.send(Command::Start).await;
    assert!(again.ok);
    assert_eq!(again.state, State::Recording);
    assert_eq!(
        harness.audio.count(),
        1,
        "a repeated press must not start a second capture"
    );
    assert_eq!(harness.transport.count(), 1);
}

#[tokio::test]
async fn a_release_while_idle_is_harmless() {
    let harness = harness(test_config());

    let response = harness.controller.send(Command::Stop).await;
    assert!(response.ok);
    assert_eq!(response.state, State::Idle);

    settle().await;
    assert!(harness.output.insert_attempts().is_empty());
    assert_eq!(harness.transport.count(), 0);
}

#[tokio::test]
async fn a_start_during_finalization_is_rejected() {
    let mut config = test_config();
    config.finalization_timeout = Duration::from_secs(5);
    let harness = harness(config);
    harness.audio.script_initial(vec![chunk(1)]);

    harness.controller.send(Command::Start).await;
    let provider = harness.transport.session(0);
    provider.push(TranscriptEvent::Ready);
    provider.wait_for_audio(1).await;
    harness.controller.send(Command::Stop).await;
    provider.wait_for_commit().await;

    let rejected = harness.controller.send(Command::Start).await;
    assert!(!rejected.ok);
    assert_eq!(rejected.state, State::Finalizing);
    assert!(rejected.error.unwrap_or_default().contains("finalizing"));

    provider.push(TranscriptEvent::Final("done".to_string()));
    harness.output.wait_for_inserts(1).await;
}

#[tokio::test]
async fn cancel_discards_the_session_and_ignores_late_transcripts() {
    let mut config = test_config();
    config.finalization_timeout = Duration::from_secs(5);
    let harness = harness(config);
    harness.audio.script_initial(vec![chunk(1)]);

    harness.controller.send(Command::Start).await;
    let provider = harness.transport.session(0);
    provider.push(TranscriptEvent::Ready);
    provider.wait_for_audio(1).await;
    harness.controller.send(Command::Stop).await;
    provider.wait_for_commit().await;

    assert_eq!(
        harness.controller.send(Command::Cancel).await.state,
        State::Idle
    );
    provider.push(TranscriptEvent::Final("must not appear".to_string()));
    settle().await;
    settle().await;

    assert!(harness.output.insert_attempts().is_empty());
    assert_eq!(
        harness.controller.send(Command::Status).await.state,
        State::Idle
    );
    assert!(
        harness.audio.session(0).killed(),
        "cancel must stop the capture child"
    );
}

#[tokio::test]
async fn a_transcript_from_an_earlier_session_never_reaches_the_output() {
    let mut config = test_config();
    config.setup_timeout = Duration::from_secs(5);
    config.finalization_timeout = Duration::from_secs(5);
    let harness = harness(config);
    harness.audio.script_initial(vec![chunk(1)]);
    harness.audio.script_initial(vec![chunk(2)]);

    // First session, cancelled while recording.
    harness.controller.send(Command::Start).await;
    let first = harness.transport.session(0);
    first.push(TranscriptEvent::Ready);
    first.wait_for_audio(1).await;
    harness.controller.send(Command::Cancel).await;

    // Second session runs to completion.
    harness.controller.send(Command::Start).await;
    let second = harness.transport.session(1);
    second.push(TranscriptEvent::Ready);
    second.wait_for_audio(1).await;
    harness.controller.send(Command::Stop).await;
    second.wait_for_commit().await;
    second.push(TranscriptEvent::Final("second".to_string()));
    harness.output.wait_for_inserts(1).await;

    // The cancelled session's provider is still connected and answers late.
    first.push(TranscriptEvent::Final("first".to_string()));
    settle().await;

    assert_eq!(harness.output.insert_attempts(), vec!["second".to_string()]);
}

#[tokio::test]
async fn audio_that_cannot_be_sent_within_the_bound_aborts_the_session() {
    let mut config = test_config();
    config.setup_timeout = Duration::from_secs(30);
    config.max_unsent_audio = Duration::from_millis(100); // one chunk
    let harness = harness(config);
    harness
        .audio
        .script_initial(vec![chunk(1), chunk(2), chunk(3)]);

    harness.controller.send(Command::Start).await;
    // The provider never reports readiness, so nothing can be handed over.
    wait_for_state(&harness.controller, State::Idle).await;

    assert!(harness.output.insert_attempts().is_empty());
    let notifications = harness.output.notifications();
    assert!(
        notifications
            .iter()
            .any(|message| message.contains("could not be sent")),
        "{notifications:?}"
    );
    assert!(harness.audio.session(0).killed());
}

#[tokio::test]
async fn exceeding_the_recording_limit_aborts_and_reports() {
    let mut config = test_config();
    config.recording_limit = Duration::from_millis(100);
    config.setup_timeout = Duration::from_secs(30);
    let harness = harness(config);
    harness.audio.script_initial(vec![chunk(1)]);

    harness.controller.send(Command::Start).await;
    let provider = harness.transport.session(0);
    provider.push(TranscriptEvent::Ready);
    provider.wait_for_audio(1).await;

    wait_for_state(&harness.controller, State::Idle).await;
    assert!(harness.output.insert_attempts().is_empty());
    assert!(
        harness
            .output
            .notifications()
            .iter()
            .any(|message| message.contains("recording limit")),
        "{:?}",
        harness.output.notifications()
    );
    assert!(harness.audio.session(0).killed());
}

#[tokio::test]
async fn a_provider_that_never_becomes_ready_hits_the_setup_timeout() {
    let mut config = test_config();
    config.setup_timeout = Duration::from_millis(100);
    config.recording_limit = Duration::from_secs(30);
    let harness = harness(config);

    assert_eq!(
        harness.controller.send(Command::Start).await.state,
        State::Recording
    );
    wait_for_state(&harness.controller, State::Idle).await;

    assert!(harness.output.insert_attempts().is_empty());
    assert!(
        harness
            .output
            .notifications()
            .iter()
            .any(|message| message.contains("not ready in time")),
        "{:?}",
        harness.output.notifications()
    );
}

#[tokio::test]
async fn a_missing_final_transcript_hits_the_finalization_timeout() {
    let mut config = test_config();
    config.setup_timeout = Duration::from_secs(5);
    config.finalization_timeout = Duration::from_millis(100);
    let harness = harness(config);
    harness.audio.script_initial(vec![chunk(1)]);

    harness.controller.send(Command::Start).await;
    let provider = harness.transport.session(0);
    provider.push(TranscriptEvent::Ready);
    provider.wait_for_audio(1).await;
    harness.controller.send(Command::Stop).await;
    provider.wait_for_commit().await;

    wait_for_state(&harness.controller, State::Idle).await;
    assert!(harness.output.insert_attempts().is_empty());
    assert!(
        harness
            .output
            .notifications()
            .iter()
            .any(|message| message.contains("timed out")),
        "{:?}",
        harness.output.notifications()
    );
}

#[tokio::test]
async fn a_connection_failure_aborts_without_inserting_or_replaying() {
    let harness = harness(test_config());
    harness.transport.fail_connect("Invalid API key");
    harness.audio.script_initial(vec![chunk(1)]);

    assert_eq!(
        harness.controller.send(Command::Start).await.state,
        State::Recording
    );
    wait_for_state(&harness.controller, State::Idle).await;

    assert!(harness.output.insert_attempts().is_empty());
    assert!(
        harness
            .output
            .notifications()
            .iter()
            .any(|message| message.contains("Invalid API key")),
        "{:?}",
        harness.output.notifications()
    );
    // A failed session is never replayed on its own.
    settle().await;
    assert_eq!(harness.transport.count(), 1);
    assert_eq!(
        harness.controller.send(Command::Status).await.state,
        State::Idle
    );
}

#[tokio::test]
async fn a_provider_error_during_recording_aborts_the_session() {
    let mut config = test_config();
    config.setup_timeout = Duration::from_secs(5);
    let harness = harness(config);
    harness.audio.script_initial(vec![chunk(1)]);

    harness.controller.send(Command::Start).await;
    let provider = harness.transport.session(0);
    provider.push(TranscriptEvent::Ready);
    provider.wait_for_audio(1).await;
    provider.push(TranscriptEvent::Failed(
        "model gpt-transcribe is not available".to_string(),
    ));

    wait_for_state(&harness.controller, State::Idle).await;
    assert!(harness.output.insert_attempts().is_empty());
    assert!(
        harness
            .output
            .notifications()
            .iter()
            .any(|message| message.contains("not available")),
        "{:?}",
        harness.output.notifications()
    );
    assert!(harness.audio.session(0).killed());
}

#[tokio::test]
async fn losing_the_connection_during_finalization_aborts_instead_of_inserting() {
    let mut config = test_config();
    config.setup_timeout = Duration::from_secs(5);
    config.finalization_timeout = Duration::from_secs(5);
    let harness = harness(config);
    harness.audio.script_initial(vec![chunk(1)]);

    harness.controller.send(Command::Start).await;
    let provider = harness.transport.session(0);
    provider.push(TranscriptEvent::Ready);
    provider.wait_for_audio(1).await;
    harness.controller.send(Command::Stop).await;
    provider.wait_for_commit().await;
    provider.end_stream();

    wait_for_state(&harness.controller, State::Idle).await;
    assert!(harness.output.insert_attempts().is_empty());
    assert!(
        harness
            .output
            .notifications()
            .iter()
            .any(|message| message.contains("closed")),
        "{:?}",
        harness.output.notifications()
    );
}

#[tokio::test]
async fn interim_transcripts_are_never_delivered() {
    let mut config = test_config();
    config.setup_timeout = Duration::from_secs(5);
    config.finalization_timeout = Duration::from_secs(5);
    let harness = harness(config);
    harness.audio.script_initial(vec![chunk(1)]);

    harness.controller.send(Command::Start).await;
    let provider = harness.transport.session(0);
    provider.push(TranscriptEvent::Ready);
    provider.wait_for_audio(1).await;
    harness.controller.send(Command::Stop).await;
    provider.wait_for_commit().await;

    provider.push(TranscriptEvent::Interim("こん".to_string()));
    provider.push(TranscriptEvent::Interim("こんにちは".to_string()));
    settle().await;
    assert!(
        harness.output.insert_attempts().is_empty(),
        "interim text was inserted"
    );

    provider.push(TranscriptEvent::Final("こんにちは".to_string()));
    harness.output.wait_for_inserts(1).await;
    assert_eq!(
        harness.output.insert_attempts(),
        vec!["こんにちは".to_string()]
    );
}

#[tokio::test]
async fn duplicate_completions_produce_exactly_one_insertion() {
    let mut config = test_config();
    config.setup_timeout = Duration::from_secs(5);
    config.finalization_timeout = Duration::from_secs(5);
    let harness = harness(config);
    harness.audio.script_initial(vec![chunk(1)]);

    harness.controller.send(Command::Start).await;
    let provider = harness.transport.session(0);
    provider.push(TranscriptEvent::Ready);
    provider.wait_for_audio(1).await;
    harness.controller.send(Command::Stop).await;
    provider.wait_for_commit().await;

    provider.push(TranscriptEvent::Final("same".to_string()));
    provider.push(TranscriptEvent::Final("same".to_string()));
    harness.output.wait_for_inserts(1).await;
    settle().await;

    assert_eq!(harness.output.insert_attempts(), vec!["same".to_string()]);
}

#[tokio::test]
async fn an_empty_transcript_inserts_nothing() {
    let mut config = test_config();
    config.setup_timeout = Duration::from_secs(5);
    config.finalization_timeout = Duration::from_secs(5);
    let harness = harness(config);
    harness.audio.script_initial(vec![chunk(1)]);

    harness.controller.send(Command::Start).await;
    let provider = harness.transport.session(0);
    provider.push(TranscriptEvent::Ready);
    provider.wait_for_audio(1).await;
    harness.controller.send(Command::Stop).await;
    provider.wait_for_commit().await;
    provider.push(TranscriptEvent::Final("   \n".to_string()));

    wait_for_state(&harness.controller, State::Idle).await;
    assert!(harness.output.insert_attempts().is_empty());
}

#[tokio::test]
async fn a_missing_api_key_prevents_starting() {
    let mut config = test_config();
    config.api_key = None;
    let harness = harness(config);

    let response = harness.controller.send(Command::Start).await;
    assert!(!response.ok);
    assert!(
        response
            .error
            .unwrap_or_default()
            .contains("OPENAI_API_KEY")
    );
    assert_eq!(
        harness.transport.count(),
        0,
        "no provider session may be opened"
    );
    assert_eq!(harness.audio.count(), 0);
}

#[tokio::test]
async fn repeated_sessions_each_insert_once() {
    let mut config = test_config();
    config.setup_timeout = Duration::from_secs(5);
    config.finalization_timeout = Duration::from_secs(5);
    let harness = harness(config);
    harness.audio.script_initial(vec![chunk(1)]);
    harness.audio.script_initial(vec![chunk(2)]);

    for (index, expected) in ["first turn", "second turn"].iter().enumerate() {
        harness.controller.send(Command::Start).await;
        let provider = harness.transport.session(index);
        provider.push(TranscriptEvent::Ready);
        provider.wait_for_audio(1).await;
        harness.controller.send(Command::Stop).await;
        provider.wait_for_commit().await;
        provider.push(TranscriptEvent::Final((*expected).to_string()));
        harness.output.wait_for_inserts(index + 1).await;
        wait_for_state(&harness.controller, State::Idle).await;
    }

    assert_eq!(
        harness.output.insert_attempts(),
        vec!["first turn".to_string(), "second turn".to_string()]
    );
    assert_eq!(harness.transport.count(), 2);
    assert_eq!(harness.audio.count(), 2);
}

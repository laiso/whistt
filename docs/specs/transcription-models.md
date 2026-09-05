# Transcription Models

This specification defines the transcription models exposed by Whistt.

## Supported models

| Provider | Model | Delivery | Reference price/hour |
|---|---|---|---:|
| OpenAI | `gpt-transcribe` | Final transcript after the push-to-talk turn is committed | $0.27 |
| OpenAI | `gpt-live-transcribe` | Final transcript after the push-to-talk turn is committed | $1.02 |
| Google Gemini | `gemini-3.5-transcribe-live` | Revisable interim results kept internal; final transcript is inserted | approx. $0.54 |
| Meta | `muse-voice-transcribe-1.0` | Final transcript only | $0.18 |
| xAI | `xai-streaming-stt` | Revisable interim results kept internal; final transcript is inserted | $0.20 |
| Microsoft Azure | `mai-transcribe-2` | Final transcript only; preview | $0.10* |
| ElevenLabs | `scribe_v2_realtime` | Revisable interim results kept internal; final transcript is inserted after a manual commit | $0.39 |

## Requirements

- The model menu shall expose only the models in the supported-model table.
- The first model in the table, `gpt-transcribe`, shall be the default.
- A saved or environment-provided model that is not supported shall fall back to the default and a stale saved value shall be replaced.
- Whistt shall use one output path for every supported model: interim events remain internal and only the completed transcript is inserted once.
- Both `gpt-transcribe` and `gpt-live-transcribe` shall commit audio when push-to-talk ends and use that final-only output path.
- Real-time cursor insertion from transcript deltas is outside the current output contract. It may be added separately for models that provide append-safe deltas; see GitHub issue #17.
- Whistt shall not expose `gpt-realtime-whisper`.
- Model selection controls shall present a flat list whose rows show vendor, model name, and reference price in US dollars per audio hour. Delivery semantics shall not be used as section headings. Prices are informational and shall not be treated as billing guarantees.
- Adding or replacing a model requires confirmation that its production API accepts Whistt's audio format and push-to-talk lifecycle.

## Automated coverage

- `TranscriptionModelCatalogTests` verifies the supported model order, default and stale-value fallback, provider grouping, reference-price coverage, and display labels.
- `FinalTranscriptOutputGateTests` verifies that interim events remain internal, completed transcripts are emitted once, and a new capture resets duplicate suppression.
- `RealtimeProtocolTests` verifies that the selected model is encoded into the OpenAI transcription session and that delta and final event variants decode correctly.
- `ElevenLabsScribeProtocolTests` verifies WebSocket URL query parameters, audio chunk encoding, commit messages, and partial/committed/error event decoding.

The opt-in `Tests/E2E/run-openai-transcription.sh` test connects the shared OpenAI probe to the production Realtime API with both supported OpenAI models. It sends a caller-provided 16-bit, 24 kHz, mono PCM speech fixture in raw or WAVE form and requires a committed turn and a non-empty final transcript. Set `OPENAI_API_KEY` and `WHISTT_E2E_AUDIO_FILE`, then run `make test-e2e-openai`. Set `WHISTT_E2E_EXPECTED_TEXT` when the fixture has a stable phrase that must appear in the result. This test is intentionally excluded from CI because it requires a secret, consumes a billed external service, and depends on model availability.

## End-to-end acceptance scenarios

```gherkin
Feature: Select and use transcription models

  Background:
    Given Whistt is running as a menu bar application
    And Accessibility and Microphone permissions are granted
    And a text editor is the focused application

  Scenario Outline: AT-TRANSCRIPTION-001 — Dictate once with an OpenAI model
    Given a valid OpenAI API key with access to "<model>" is stored
    And "<model>" is selected
    When the user holds the configured shortcut
    And says "Whistt end to end transcription test"
    And releases the shortcut
    Then no interim transcript is inserted while recording
    And one completed transcript is inserted into the focused editor
    And no phrase is inserted twice

    Examples:
      | model               |
      | gpt-transcribe      |
      | gpt-live-transcribe |

  Scenario: AT-TRANSCRIPTION-002 — Copy one completed transcript
    Given a supported transcription model is configured
    And the output mode is Clipboard
    When the user completes one push-to-talk turn
    Then the clipboard is updated once with the completed transcript
    And interim transcripts do not create clipboard entries

  Scenario: AT-TRANSCRIPTION-003 — Cancel a turn before finalization
    Given a supported transcription model is configured
    When the user starts a push-to-talk turn
    And cancels it with another key or mouse input
    Then no interim or completed transcript is inserted
    And a late result from the cancelled session is ignored

  Scenario: AT-TRANSCRIPTION-004 — Fall back from a removed model
    Given the saved model is "gpt-realtime-whisper"
    When Whistt launches
    Then "gpt-transcribe" is selected
    And the stale saved value is replaced

  Scenario: AT-TRANSCRIPTION-005 — Inspect the flat model menu
    When the user opens the model selector
    Then every supported model appears once
    And every row shows its vendor, model name, and reference price per hour
    And delivery semantics are not shown as section headings
```

`AT-TRANSCRIPTION-001` is partially automated by the opt-in production-API E2E test, through receipt of a final transcript. Insertion into another application and the remaining scenarios cross macOS global input, Accessibility, clipboard history, Keychain, or application relaunch boundaries and remain manual until a signed UI-test host can control those services reliably.

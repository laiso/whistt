# MAI-Transcribe-2 Voice Live Support — Implementation Results (2026-09-04)

Status: **complete**.

## Live verification findings

- Real-speech verification passed. Japanese audio (24 kHz / mono / PCM16, generated with `say`) was streamed in real time through `azure-voice-live-probe`, and an accurate Japanese transcript arrived via `conversation.item.input_audio_transcription.completed`.
- **No interim results are emitted** — mai-transcribe-2 over Voice Live is final-only. `TranscriptRevisionBuffer` is not needed; Azure is classified with Meta/xAI as a "final transcript only" provider.
- Omitting `language` in `session.update` still transcribes correctly via auto-detection (verified with `language: null`).
- With an invalid API key the server rejects the session and the transport reaches `onError` immediately, leaving the app in a retryable state.

## What was implemented

- Added `AzureVoiceLiveProtocol.swift`, `AzureVoiceLiveWS.swift`, and `AzureVoiceLiveSettings.swift`; integrated Azure into `TranscriptionProvider`, the transport factory, the menu, and the settings screen.
  - The endpoint is stored in `UserDefaults` (`WHISTT_AZURE_SPEECH_ENDPOINT`), validated as an `https://` URL with a host, and normalized by stripping trailing slashes. Resolution order: process environment / `.env` > stored value.
  - "API Keys…" was renamed to "Provider Settings…". The Azure row has two fields — API Key (Keychain) and Endpoint (`UserDefaults`) — a status label (`Configured` / `API key missing` / `Endpoint missing`), and `Remove` clears both.
  - When Azure configuration is incomplete, the app opens the Provider Settings screen instead of the key-only dialog.
- `Tools/AzureVoiceLiveProbe` now drives the real `AzureVoiceLiveTransport` end to end: `swift run azure-voice-live-probe /path/to/audio.raw`.

## Verification

- `swift test`: all 109 tests pass (including 16 new tests for protocol parsing and endpoint settings).
- `make build`: succeeds.

## Open items

- Pricing — whether the limited-time `$0.10 / audio hour` rate applies to Voice Live, and whether the hosted conversation model adds charges — must be confirmed on the actual Azure bill.
- Preview-specification change risk remains: Voice Live and mai-transcribe-2 are both preview features.

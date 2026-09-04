# MAI-Transcribe-2 Voice Live Support — Plan

## Goal

Evaluate whether Microsoft Voice Live API's `mai-transcribe-2` can be added as a real-time transcription provider in Whistt, and make it usable with the same experience as the existing OpenAI, Gemini, Meta, and xAI providers.

## What was known before implementation

- Authentication works with `AZURE_SPEECH_API_KEY` and `AZURE_SPEECH_ENDPOINT` from `.env`.
- The file-based MAI-Transcribe-2 API returns HTTP 200 and accepts the model selection.
- The Voice Live WebSocket is reachable.
- Setting `input_audio_transcription.model` to `mai-transcribe-2` is echoed back in `session.updated`.
- A connection smoke check existed as `Tools/AzureVoiceLiveProbe` plus a SwiftPM target.
- Real audio transmission, interim results, final results, and teardown were not yet verified.

## Implementation approach

1. **Live Voice Live verification**
   - Send 24 kHz / mono / PCM16 audio in small chunks.
   - Confirm `input_audio_buffer.append` and the end / commit operations.
   - Record interim strings, finalized strings, and turn completion events.
   - Confirm `mai-transcribe-2` actually converts speech to text.

2. **Protocol isolation**
   - Put Azure-specific request generation and response parsing into types that are independent of UI and recording logic.
   - Preserve unknown events in a diagnosable form instead of dropping them.
   - Never log the API key or the endpoint.

3. **TranscriptionTransport integration**
   - Add a transport for Azure Voice Live.
   - Normalize events to the existing `ready`, `revision` / `partial`, `final`, and `turnComplete` set.
   - Align manual push-to-talk start and end with the existing providers.
   - Use `TranscriptRevisionBuffer` if interim strings revise earlier text.

4. **Settings UI**
   - Add Microsoft/Azure to the provider list.
   - Store the API key securely in the macOS Keychain.
   - The endpoint is not a secret, so it is stored as a regular preference in `UserDefaults`.
   - The model is fixed to `mai-transcribe-2` for now.
   - `.env` continues to use `AZURE_SPEECH_API_KEY` and `AZURE_SPEECH_ENDPOINT`.

### Microsoft/Azure authentication UI spec

- The current "API Keys…" screen becomes "Provider Settings…", a screen that also handles connection settings beyond keys.
- OpenAI, Gemini, Meta, and xAI keep one API key field per provider as before.
- The Microsoft/Azure row shows:
  - `API Key`: masked text field, stored in the Keychain.
  - `Endpoint`: plain text field, e.g. `https://<resource>.services.ai.azure.com/`, stored in `UserDefaults`.
  - `Save`: validates both fields and stores them in one action.
  - `Remove`: deletes both the API key and the endpoint.
  - Status label: one of `Configured`, `API key missing`, `Endpoint missing`.
- The endpoint is normalized by trimming surrounding whitespace and trailing slashes before saving.
- Only `https://` URLs with a host name are accepted; anything else is rejected.
- In development launches with environment variables set, `.env` / process environment still take precedence over saved values, as with the other providers.
- When Azure configuration is missing at recording start, the app opens the settings screen instead of the existing key-only dialog.

5. **Tests and documentation**
   - Add unit tests for message generation, event parsing, and provider selection.
   - Run `swift test` and build the app.
   - Document required configuration, preview status, and supported regions in README and ARCHITECTURE.

## Completion criteria

- Audio recorded with Option + Space is streamed to Voice Live in real time.
- Japanese interim or finalized results reach Whistt.
- After recording ends, the final text is output exactly once, via typing or the clipboard.
- Authentication failure, model rejection, and network loss all return the app to a retryable state.
- Tests and builds for the existing providers keep passing.

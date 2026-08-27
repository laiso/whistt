# Use ChatGPT Subscription Auth for Speech Recognition Without Additional OpenAI API Billing

## Purpose

Investigate whether a client app can use a user's existing ChatGPT Plus/Pro subscription via ChatGPT/Codex OAuth to support speech recognition and AI requests without requiring separate OpenAI Platform API usage-based billing.

The goal is to let users bring their own ChatGPT subscription and avoid extra paid API-key costs, especially for realtime speech-to-text.

## Background

Codex OAuth tokens can be used with the ChatGPT backend Codex Responses endpoint:

```text
POST https://chatgpt.com/backend-api/codex/responses
```

However, the same token does not work with the public OpenAI Platform Responses endpoint:

```text
POST https://api.openai.com/v1/responses
=> HTTP 401
=> missing scope: api.responses.write
```

This means ChatGPT/Codex subscription tokens should be treated as credentials for ChatGPT backend Codex APIs, not as general OpenAI Platform API credentials.

## Findings

### Codex Responses API

Working path:

```text
ChatGPT/Codex OAuth token
-> chatgpt.com/backend-api/codex/responses
```

Required headers include:

```http
Authorization: Bearer <codex oauth access token>
chatgpt-account-id: <chatgpt_account_id from JWT>
originator: <client identifier>
OpenAI-Beta: responses=experimental
accept: text/event-stream
content-type: application/json
```

### Realtime speech recognition

The Realtime transcription endpoint could not be confirmed to work with a Codex OAuth token alone:

```text
wss://api.openai.com/v1/realtime?intent=transcription
Authorization: Bearer <codex oauth access token>
```

Observed behavior:

- OAuth token + transcription intent returned server errors.
- Some Realtime WebSocket variants opened but failed with request/model errors.
- Minting a Realtime client secret with the OAuth token returned success, but connecting with the minted ephemeral key still failed.

The openai/codex repository contains realtime/voice-related code, but the current implementation still appears to require API-key auth for Realtime sessions.

## Problem

We can use the subscription token for Codex Responses, but we cannot currently rely on the same subscription token for Realtime speech recognition.

This creates a gap for the original goal: avoiding additional usage-based OpenAI Platform API billing. If speech-to-text still requires an OpenAI API key, then the app cannot fully operate under the user's ChatGPT subscription.

## Proposed direction

Separate speech recognition from Codex inference:

```text
Speech recognition
-> transcript text
-> app prompt/input layer
-> ChatGPT/Codex OAuth Responses API
```

Recommended speech recognition options:

1. Local speech-to-text
   - Whisper.cpp
   - MLX Whisper on Apple Silicon
   - macOS Speech framework

2. Non-OpenAI speech recognition APIs, if cloud STT is acceptable
   - Apple Speech framework / SpeechAnalyzer where available
   - Deepgram
   - AssemblyAI
   - Google Cloud Speech-to-Text
   - Azure AI Speech
   - AWS Transcribe

3. OpenAI Realtime transcription only as an optional API-key-backed mode
   - This should be clearly labeled as usage-billed and outside the subscription-only goal.

## Acceptance criteria

- Document which parts can run under ChatGPT/Codex OAuth subscription auth.
- Confirm that Codex Responses works with subscription OAuth tokens.
- Treat OpenAI Platform Realtime transcription as unsupported for subscription-only mode unless proven otherwise.
- Add an abstraction for speech recognition providers so OpenAI, local STT, OS STT, and third-party STT can be swapped.
- Ensure the default subscription-only path does not require an OpenAI Platform API key.

## Open questions

- Is there an official supported Realtime speech recognition endpoint for ChatGPT/Codex OAuth tokens?
- Can Codex Realtime voice APIs be used by third-party clients without API-key auth?
- Which local or non-OpenAI STT provider should be the default fallback?
- Should the app expose OpenAI API-key Realtime transcription as an optional paid mode?

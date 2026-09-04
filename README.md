# Whistt

Native push-to-talk voice input for macOS.

Hold **⌥ Option + Space**, speak, and release. Whistt types the transcript at your cursor or copies it to the clipboard.

![Whistt demo](assets/demo.gif)

Bring your own credentials and switch between OpenAI Realtime, Google Gemini Live, Meta Muse Voice Transcribe, xAI Speech-to-Text, and Microsoft Azure Voice Live.

## Provider comparison

| Provider | Model | Interim results | Required settings | Reference price/hour |
|---|---|---|---|---:|
| Microsoft (preview) | `mai-transcribe-2` | None (final only) | API key + Endpoint | **$0.10**※ |
| Meta | `muse-voice-transcribe-1.0` | None (final only) | API key | **$0.18** |
| xAI | Streaming STT | Revising internally (final only) | API key | **$0.20** |
| OpenAI | `gpt-transcribe` | None (after-turn transcription) | API key | **$0.27** |
| Gemini | `gemini-3.5-transcribe-live` | Revising (not typed) | API key | **approx. $0.54** |
| OpenAI | `gpt-realtime-whisper` | Streaming deltas (typed live) | API key | **$1.02** |

Reference prices as of September 2026. ※ Azure's introductory rate and any additional Voice Live charges should be confirmed on your bill. `gpt-transcribe` is not yet selectable in Whistt.

## Requirements

- macOS 26.2+
- Credentials for [OpenAI](https://platform.openai.com/api-keys), [Gemini](https://aistudio.google.com/app/apikey), [Meta](https://dev.meta.ai/), [xAI](https://console.x.ai/), or Azure Voice Live

## Install

Download the latest unsigned build from [GitHub Releases](https://github.com/laiso/whistt/releases) and move Whistt to `/Applications`.

On first launch, macOS may block the app. Open **System Settings → Privacy & Security** and select **Open Anyway**.

<img src="assets/open-anyway.png" alt="Open Anyway in Privacy & Security" width="500">

## Set up and use

1. Add credentials when prompted or from **Provider Settings…**. Azure also requires its Voice Live endpoint.

   <img src="assets/api-key-dialog.png" alt="API key prompt" width="360">

2. Grant **Microphone** and **Accessibility** permissions in System Settings, then relaunch Whistt.

   <img src="assets/accessibility.png" alt="Whistt in Accessibility settings" width="360">

3. Hold **⌥ Option + Space**, speak, and release.

Use the menu bar to select a provider and switch between typing at the cursor and copying to the clipboard.

<img src="assets/menu-bar.png" alt="Whistt menu bar controls" width="500">

## Troubleshooting

- **No text appears** — grant Accessibility permission to Whistt.
- **The shortcut appears in the focused app** — check Accessibility permission. Whistt recovers automatically after permission is granted.
- **Provider Settings opens when recording** — add the selected provider's missing credentials. Azure requires both an API key and endpoint.
- **Gemini returns no text** — confirm the Gemini key has Live API access.

## Develop

Open `Whistt/Whistt.xcodeproj` in Xcode, or use:

```sh
make build
make test
make debug
```

Technical contracts live in [`docs/specs`](docs/specs/). Historical decisions are stored in the project-local `whistt-decisions` skill.

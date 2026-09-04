# Whistt

Native push-to-talk voice input for macOS.

Hold **⌥ Option + Space**, speak, and release. Whistt types the transcript at your cursor or copies it to the clipboard.

![Whistt demo](assets/demo.gif)

Bring your own API key and switch between OpenAI Realtime, Google Gemini Live, Meta Muse Voice Transcribe, and xAI Speech-to-Text.

## Provider comparison

| Provider | Model | Interim results | Required settings | Reference price/hour |
|---|---|---|---|---:|
| Meta | `muse-voice-transcribe-1.0` | None (final only) | `META_API_KEY` | **$0.18** |
| xAI | Streaming STT | Revising internally (final only) | `XAI_API_KEY` | **$0.20** |
| OpenAI | `gpt-transcribe` | None (after-turn transcription) | `OPENAI_API_KEY` | **$0.27** |
| Gemini | `gemini-3.5-transcribe-live` | Revising (not typed) | `GEMINI_API_KEY` | **approx. $0.54** |
| OpenAI | `gpt-realtime-whisper` | Streaming deltas (typed live) | `OPENAI_API_KEY` | **$1.02** |

Reference prices as of September 2026. `gpt-transcribe` is not yet selectable in Whistt's model menu.

## Requirements

- macOS 26.2+
- An API key for [OpenAI](https://platform.openai.com/api-keys), [Gemini](https://aistudio.google.com/app/apikey), [Meta](https://dev.meta.ai/), or [xAI](https://console.x.ai/)

## Install

Download the latest unsigned build from [GitHub Releases](https://github.com/laiso/whistt/releases) and move Whistt to `/Applications`.

On first launch, macOS may block the app. Open **System Settings → Privacy & Security** and select **Open Anyway**.

<img src="assets/open-anyway.png" alt="Open Anyway in Privacy & Security" width="500">

## Set up and use

1. Add an API key when prompted.

   <img src="assets/api-key-dialog.png" alt="API key prompt" width="360">

2. Grant **Microphone** and **Accessibility** permissions in System Settings, then relaunch Whistt.

   <img src="assets/accessibility.png" alt="Whistt in Accessibility settings" width="360">

3. Hold **⌥ Option + Space**, speak, and release.

Use the menu bar to select a provider and switch between typing at the cursor and copying to the clipboard.

<img src="assets/menu-bar.png" alt="Whistt menu bar controls" width="500">

## Troubleshooting

- **No text appears** — grant Accessibility permission to Whistt.
- **The shortcut appears in the focused app** — check Accessibility permission. Whistt recovers automatically after permission is granted.
- **The API key prompt reappears** — add the selected provider's key again.
- **Gemini returns no text** — confirm the Gemini key has Live API access.

## Develop

Open `Whistt/Whistt.xcodeproj` in Xcode, or use:

```sh
make build
make test
make debug
```

Technical contracts live in [`docs/specs`](docs/specs/). Historical decisions are stored in the project-local `whistt-decisions` skill.

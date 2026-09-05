# Whistt

Native push-to-talk voice input for macOS.

Hold **Right Option**, speak, and release. Whistt types the transcript at your cursor or copies it to the clipboard.

![Whistt demo](assets/demo.gif)

Bring your own credentials and switch between OpenAI Realtime, Google Gemini Live, Meta Muse Voice Transcribe, xAI Speech-to-Text, Microsoft Azure Voice Live, and ElevenLabs Scribe v2 Realtime.

## Provider comparison

| Provider | Model | Interim results | Required settings | Reference price/hour |
|---|---|---|---|---:|
| Microsoft (preview) | `mai-transcribe-2` | None (final only) | API key + Endpoint | **$0.10**※ |
| Meta | `muse-voice-transcribe-1.0` | None (final only) | API key | **$0.18** |
| xAI | Streaming STT | Revising internally (final only) | API key | **$0.20** |
| OpenAI | `gpt-transcribe` | None (after-turn transcription) | API key | **$0.27** |
| ElevenLabs | `scribe_v2_realtime` | Revising (not typed) | API key | **$0.39** |
| Gemini | `gemini-3.5-transcribe-live` | Revising (not typed) | API key | **approx. $0.54** |
| OpenAI | `gpt-live-transcribe` | None (after-turn transcription) | API key | **$1.02** |

Reference prices as of September 2026. ※ Azure's introductory rate and any additional Voice Live charges should be confirmed on your bill.

## Requirements

- macOS 26.2+
- Credentials for [OpenAI](https://platform.openai.com/api-keys), [Gemini](https://aistudio.google.com/app/apikey), [Meta](https://dev.meta.ai/), [xAI](https://console.x.ai/), Azure Voice Live, or [ElevenLabs](https://elevenlabs.io/app/settings/api-keys)

## Install

Download the latest unsigned build from [GitHub Releases](https://github.com/laiso/whistt/releases) and move Whistt to `/Applications`.

On first launch, macOS may block the app. Open **System Settings → Privacy & Security** and select **Open Anyway**.

<img src="assets/open-anyway.png" alt="Open Anyway in Privacy & Security" width="500">

## Set up and use

1. Open **Settings… → Providers** and add credentials for the provider you want to use. Azure also requires its Voice Live endpoint.

2. Grant **Microphone** and **Accessibility** permissions in System Settings, then relaunch Whistt.

   <img src="assets/accessibility.png" alt="Whistt in Accessibility settings" width="360">

3. Hold **Right Option**, speak, and release.

Use the menu bar to select a provider and switch between typing at the cursor and copying to the clipboard.

<img src="assets/menu-bar.png" alt="Whistt menu bar controls" width="500">

Settings also controls the output mode, model, push-to-talk shortcut, launch-at-login behavior, and recording-start sound. For local development, provider credentials and the Azure endpoint can be supplied through process environment variables or `.env`; environment values take precedence over saved settings.

## Troubleshooting

- **No text appears** — grant Accessibility permission to Whistt.
- **The shortcut appears in the focused app** — check Accessibility permission. Whistt recovers automatically after permission is granted.
- **Settings opens when recording** — add the selected provider's missing credentials in **Settings → Providers**. Azure requires both an API key and endpoint.
- **Gemini returns no text** — confirm the Gemini key has Live API access.

## Develop

Open `Whistt/Whistt.xcodeproj` in Xcode, or use:

```sh
make build
make test
make debug
```

Technical contracts live in [`docs/specs`](docs/specs/). Historical decisions are stored in the project-local `whistt-decisions` skill.

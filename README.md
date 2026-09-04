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

## Run

Requires macOS 26.2+ and Xcode 16+.

1. Open `Whistt/Whistt.xcodeproj` and press ⌘R.
2. Add a provider API key when prompted.
3. Grant Microphone and Accessibility permissions.

Development commands:

```sh
make build
make test
make debug
```

Unsigned builds are available from [GitHub Releases](https://github.com/laiso/whistt/releases). On first launch, allow Whistt from **System Settings → Privacy & Security**.

## Documentation

- [Technical specifications](docs/specs/)
- Historical decisions are stored in the project-local `whistt-decisions` skill.

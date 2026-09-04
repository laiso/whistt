# Whistt

Native push-to-talk voice input for macOS.

Hold **⌥ Option + Space**, speak, and release. Whistt types the transcript at your cursor or copies it to the clipboard.

![Whistt demo](assets/demo.gif)

Bring your own API key and switch between OpenAI Realtime, Google Gemini Live, Meta Muse Voice Transcribe, and xAI Speech-to-Text.

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

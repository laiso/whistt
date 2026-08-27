# Whistt — Mac native real-time voice input

Hold **⌥ Option + Space** to talk; speech is streamed to OpenAI Realtime or Google Gemini Live Transcription and the resulting text is typed at the current cursor position.

![demo](assets/demo.gif)

Menu Bar app. Native Swift / AVFoundation / URLSessionWebSocketTask — no third-party deps.

## Why Whistt?

Most voice-input apps hide the transcription model behind their service. Whistt is an open-source client for trying newly released real-time transcription models in an actual macOS dictation workflow: choose the provider and model, bring your own API key, and compare results without an opaque intermediary.

## Requirements

- macOS 26.2+ / Xcode 16+
- At least one provider API key:
  - OpenAI API key with Realtime API access — <https://platform.openai.com/api-keys>
  - Gemini API key — <https://aistudio.google.com/app/apikey>

## Run

1. Open `Whistt/Whistt.xcodeproj` and ⌘R.
2. Paste the selected provider's API key when prompted. OpenAI and Gemini keys are stored as separate entries in the macOS Keychain.

   <img src="assets/api-key-dialog.png" alt="OpenAI API Key prompt" width="360">
3. Grant **Microphone** + **Accessibility** permissions in System Settings, then relaunch.

   <img src="assets/accessibility.png" alt="Accessibility settings with Whistt enabled" width="360">
4. Hold ⌥+Space, speak, release — text appears at your cursor.

Switch between **Type at cursor** / **Clipboard** output and pick an OpenAI or Google Gemini transcription model from the menu bar. Gemini uses `gemini-3.5-transcribe-live`, Japanese (`ja-JP`), and manual push-to-talk VAD. Its interim hypotheses are not typed because they can revise earlier text; only finalized text is inserted.

The menu provides independent **Set/Clear OpenAI API Key** and **Set/Clear Gemini API Key** actions. For local development, `OPENAI_API_KEY` and `GEMINI_API_KEY` can be supplied through process environment variables or `.env`; the selected provider's key is migrated to Keychain on first use.

<img src="assets/menu-bar.png" alt="Menu bar dropdown" width="500">

### Run the development build from Terminal

From the repository root, build the Debug app, export the values in `.env` to the app process, and launch it in the foreground:

```sh
xcodebuild \
  -project Whistt/Whistt.xcodeproj \
  -scheme Whistt \
  -configuration Debug \
  -derivedDataPath .build/xcode \
  build

set -a
source .env
set +a
.build/xcode/Build/Products/Debug/Whistt.app/Contents/MacOS/Whistt
```

The process environment takes precedence over Keychain, so this launch method uses `OPENAI_API_KEY` and `GEMINI_API_KEY` from the repository's `.env`. Keep this terminal open while using Whistt; press `Ctrl-C` to stop it. The `.env` file must contain shell-compatible `KEY=value` entries and should have mode `600` (`chmod 600 .env`).


## Install from GitHub Release (unsigned)

Releases are distributed **unsigned**, so the first launch from `/Applications/` will be blocked by Gatekeeper. Two ways to bypass:

- **Terminal**: `xattr -dr com.apple.quarantine /Applications/Whistt.app`
- **GUI**: open System Settings → Privacy & Security, scroll to the "Whistt was blocked to protect your Mac" row and click **Open Anyway**.

  <img src="assets/open-anyway.png" alt="Open Anyway button in Privacy & Security" width="500">

## Troubleshooting

- **No text appears** — Accessibility permission isn't granted to `Whistt.app`.
- **Space leaks into the focused app** — Accessibility wasn't granted yet; the app auto-recovers within ~2 s after granting (no relaunch needed since v0.1.1).
- **Key dialog reappears** — the Keychain entry is missing or empty; paste the key again.
- **Gemini finishes but no text appears** — confirm that `gemini-3.5-transcribe-live` is selected and the Gemini key has Live API access.

## Gemini Live API probe

The end-to-end probe sends raw PCM16LE, 16 kHz, mono audio through the same Gemini wire protocol used by the app:

```sh
swift run gemini-live-probe /path/to/audio.raw
```

It reads `GEMINI_API_KEY` through `EnvLoader`, never prints the credential, and exits successfully only after receiving a finalized transcript.

## More

- Architecture & module layout → `ARCHITECTURE.md`.
- Key sources (env var override, legacy `.env` migration), advanced model notes → ARCHITECTURE.md "Design highlights".

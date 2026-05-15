# Whistt — Mac native real-time voice input

Hold **⌥ Option + Space** to talk; speech is streamed to OpenAI's Realtime transcription API and the resulting text is typed at the current cursor position.

![demo](assets/demo.gif)

Menu Bar app. Native Swift / AVFoundation / URLSessionWebSocketTask — no third-party deps.

## Requirements

- macOS 26.2+ / Xcode 16+
- An OpenAI API key with Realtime API access — issue one at <https://platform.openai.com/api-keys>

## Run

1. Open `Whistt/Whistt.xcodeproj` and ⌘R.
2. Paste your API key when prompted (stored in the macOS Keychain).

   <img src="assets/api-key-dialog.png" alt="OpenAI API Key prompt" width="360">
3. Grant **Microphone** + **Accessibility** permissions in System Settings, then relaunch.

   <img src="assets/accessibility.png" alt="Accessibility settings with Whistt enabled" width="360">
4. Hold ⌥+Space, speak, release — text appears at your cursor.

Switch between **Type at cursor** / **Clipboard** output and pick a transcription model from the menu bar. Default model is `gpt-realtime-whisper` (~$0.017/min); see <https://openai.com/api/pricing/> for others.

<img src="assets/menu-bar.png" alt="Menu bar dropdown" width="500">


## Troubleshooting

- **No text appears** — Accessibility permission isn't granted to `Whistt.app`.
- **Key dialog reappears** — the Keychain entry is missing or empty; paste the key again.

## More

- Architecture & module layout → `ARCHITECTURE.md`.
- Key sources (env var override, legacy `.env` migration), advanced model notes → ARCHITECTURE.md "Design highlights".

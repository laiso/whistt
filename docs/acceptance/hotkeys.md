# Hotkey acceptance tests

## AT-HOTKEY-001: Set and use a custom shortcut

**Status:** `manual`

### Preconditions

- Whistt is running as a menu bar app.
- Accessibility and Microphone permissions are granted.
- A transcription provider and valid API key are configured.

### Steps

1. Open **Shortcut → Customize…** from the Whistt menu.
2. Press a key combination containing at least one modifier, such as **⌘K**.
3. Release the keys and select **Save**.
4. Hold the saved shortcut, speak, and release it.
5. Quit and relaunch Whistt.

### Expected results

- The recorder shows the pressed combination and enables **Save**.
- The Shortcut menu and hold-to-talk hint show the saved combination.
- Holding the shortcut starts recording and releasing it stops recording.
- The shortcut keystroke does not leak into the focused application.
- The saved shortcut remains selected after relaunch.

### Automation

Not automated. A future macOS UI test should launch the `LSUIElement` app, operate the status menu, synthesize the key combination, and verify both the recorder and persisted menu state.

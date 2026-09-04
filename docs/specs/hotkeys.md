# Hotkey specification

## Requirements

- On a fresh installation with no saved shortcut, Whistt shall use **Right Option** as the default push-to-talk shortcut.
- Whistt shall show exactly three recommended shortcuts: **Right Option (Default)**, **Right Control**, and **Right Command**.
- Whistt shall offer arbitrary supported key combinations through **Customize…** rather than listing additional presets.
- When the user selects **Shortcut → Customize…**, Whistt shall present the shortcut recorder after status-menu tracking has finished.
- While the shortcut recorder is active, Whistt shall receive and display the user's supported key combination.
- When a valid shortcut is captured, Whistt shall enable **Save**.
- When the user saves a shortcut, Whistt shall update the Shortcut menu and hold-to-talk hint.
- When the configured shortcut is held, Whistt shall start recording and suppress the shortcut keystroke in the focused application.
- When the configured shortcut is released, Whistt shall stop recording.
- When Whistt is relaunched, it shall restore the saved shortcut.

## Acceptance scenarios

```gherkin
Feature: Custom push-to-talk shortcuts

  Background:
    Given Whistt is running as a menu bar application
    And Accessibility and Microphone permissions are granted
    And a transcription provider with valid credentials is configured

  Scenario: AT-HOTKEY-001 — Set and use a custom shortcut
    When the user opens "Shortcut → Customize…"
    And presses a supported key combination such as Command-K
    And releases the keys
    Then the recorder displays the captured combination
    And the Save button is enabled

    When the user selects Save
    Then the Shortcut menu displays the saved combination
    And the hold-to-talk hint displays the saved combination

    When the user holds the saved shortcut
    Then recording starts
    And the shortcut keystroke does not reach the focused application

    When the user releases the shortcut
    Then recording stops

    When the user quits and relaunches Whistt
    Then the saved shortcut remains selected

  Scenario: AT-HOTKEY-002 — Use the default shortcut on a fresh installation
    Given Whistt has no saved shortcut
    When Whistt launches
    Then the current shortcut is Right Option

    When the user holds Right Option
    Then recording starts

    When the user releases Right Option
    Then recording stops
```

## Automation status

Unit tests verify the default and three recommendations, binding validity and persistence, and the recording start/stop lifecycle. The complete `LSUIElement` menu and shortcut-recorder flows in `AT-HOTKEY-001` and `AT-HOTKEY-002` remain manual Gherkin scenarios until macOS UI automation can synthesize global shortcuts and verify the focused application end to end.

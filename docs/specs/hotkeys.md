# Hotkey specification

## Requirements

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
```

## Automation status

`AT-HOTKEY-001` is manual. A future macOS UI test should launch the `LSUIElement` application, operate the status menu, synthesize the shortcut, and verify the recorder and persisted menu state end to end.

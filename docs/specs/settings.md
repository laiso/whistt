# Settings specification

## Requirements

- Whistt shall provide a native macOS Settings window with General, Shortcut, and Providers tabs.
- Changes made in Settings and the status menu shall stay synchronized and apply immediately.
- Whistt shall persist the output mode and recording-start sound preference between launches.
- Whistt shall manage launch-at-login through the macOS login-item service and surface approval or registration errors near the toggle.
- Whistt shall never display an API key that is already stored in Keychain.
- When the selected provider is incomplete, Whistt shall open Settings on the Providers tab.

## Acceptance scenarios

```gherkin
Feature: Native application settings

  Scenario: Change a quick setting from either surface
    Given Whistt is running
    When the user changes Output or Model in Settings
    Then the status menu reflects the same selection
    And the new value is used immediately

    When the user changes the same setting in the status menu
    Then Settings reflects that selection

  Scenario: Configure a provider securely
    When the user opens Settings and selects Providers
    And configures a provider with a valid API key
    Then the provider status becomes Configured
    And the stored API key is not displayed

  Scenario: Restore persistent preferences
    Given the user selected Clipboard output
    And disabled the recording-start sound
    When Whistt is quit and relaunched
    Then Clipboard remains selected
    And the recording-start sound remains disabled

  Scenario: Approve launch at login in System Settings
    Given launch at login requires approval
    And the General settings pane remains open
    When the user enables Whistt in System Settings
    And returns to Whistt
    Then the launch-at-login toggle reflects the current system status
    And the approval warning is updated without reopening Settings
```

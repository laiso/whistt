# Settings specification

## Requirements

- Whistt shall provide a native macOS Settings window with General, Shortcut, and Providers tabs.
- Changes made in Settings and the status menu shall stay synchronized and apply immediately.
- Whistt shall persist the output mode and recording-start sound preference between launches.
- Whistt shall manage launch-at-login through the macOS login-item service and surface approval or registration errors near the toggle.
- Whistt shall never display an API key that is already stored in Keychain.
- While a newly entered OpenAI API key remains in the configuration sheet, Whistt shall check access to every supported OpenAI transcription model after a short typing pause and show the result for each model without displaying the key.
- Model-access verification failure shall not delete or replace a previously stored API key. Network and permission failures shall be presented as availability results rather than treated as proof that the key is invalid.
- When the selected provider is incomplete, Whistt shall open Settings on the Providers tab.

## Automated coverage

- `AppPreferencesTests` verifies output-mode and recording-start-sound defaults and persistence.
- `ProviderConfigurationServiceTests` verifies API-key preservation, Azure endpoint validation and normalization, mutation ordering, configuration status, failure behavior, and removal.
- `OpenAIModelAccessCheckerTests` verifies request construction, successful access, API and transport failures, concurrent result ordering, and empty input without using the live API.
- `OpenAIModelAccessValidatorTests` verifies key normalization, debounce ordering, blank input, and cancellation of stale checks.
- `ShortcutEngineTests` verifies shortcut persistence and the recording lifecycle independently of the macOS UI.

Run `swift test` for this coverage. The scenarios below are limited to behavior that crosses the real macOS UI or system services and is not covered by the package tests.

## Manual end-to-end scenarios

```gherkin
Feature: Native application settings

  Scenario: Settings and status menu stay synchronized
    Given Whistt is running
    When the user changes Output or Model in Settings
    Then the status menu reflects the same selection
    When the user changes the same setting in the status menu
    Then Settings reflects that selection

  Scenario: Configure a provider without revealing its secret
    When the user opens Settings and selects Providers
    And configures a provider with a valid API key
    Then the provider status becomes Configured
    And the stored API key is not displayed

  Scenario: AT-SETTINGS-001 — Verify access for a new OpenAI API key
    When the user opens the OpenAI provider configuration
    And enters a valid API key
    And stops typing for at least 600 milliseconds
    Then Whistt checks access to "gpt-transcribe"
    And Whistt checks access to "gpt-live-transcribe"
    And the result for each model is displayed
    And the API key is not displayed outside the secure input field

  Scenario: AT-SETTINGS-002 — Replace a pending model-access check
    When the user changes the OpenAI API key before its access check finishes
    Then the result from the earlier key is ignored
    And only results for the latest key are displayed

  Scenario: AT-SETTINGS-003 — Preserve a stored key after a verification failure
    Given an OpenAI API key is already stored in Keychain
    When a newly entered key cannot access a supported model
    Then the stored key is not deleted or replaced until the user selects Save
    And the unavailable model is identified without exposing either key

  Scenario: Approve launch at login in System Settings
    Given launch at login requires approval
    And the General settings pane remains open
    When the user enables Whistt in System Settings
    And returns to Whistt
    Then the launch-at-login toggle reflects the current system status
    And the approval warning is updated without reopening Settings
```

# ADR 0005: Separate Provider Secrets From Non-Secret Settings

- Status: Accepted
- Date: 2026-09-04

## Context

Provider configuration can include both secrets and ordinary values. API keys require protected storage, while values such as the Azure Voice Live endpoint need validation and convenient editing but do not benefit from Keychain storage. Unsigned probe CLIs cannot rely on the app's Keychain access.

## Decision

Store provider API keys as separate accounts in the macOS Keychain. Store non-secret provider settings in application preferences; specifically, store the normalized Azure endpoint in `UserDefaults`.

Allow process environment values to override stored app configuration for local development. Let probe CLIs resolve credentials and settings from the environment or `.env` instead of the app's Keychain entries.

## Consequences

- Secrets are not stored in preferences or committed configuration.
- Provider settings can combine protected and ordinary fields in one UI without treating every value as a credential.
- App and CLI configuration paths intentionally differ.
- Adding a provider requires classifying each configuration value as secret or non-secret before choosing its storage.

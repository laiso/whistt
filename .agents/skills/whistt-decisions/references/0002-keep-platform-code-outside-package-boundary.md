# ADR 0002: Keep Platform UI and Audio Capture Outside the Package Boundary

- Status: Accepted
- Date: 2026-09-04

## Context

Whistt is a macOS application, but its provider protocols, transports, buffering, and configuration logic also need fast automated tests and command-line probes. Application UI and microphone capture make those consumers harder to build and isolate.

## Decision

Keep macOS UI, global input handling, microphone capture, and cursor output in the Xcode application target. Keep shared transport and protocol logic behind a Swift package boundary that does not depend on AppKit or AVFoundation runtime behavior.

The application, tests, and provider probe CLIs may share source files across that boundary. Shared files must continue to compile for every declared consumer.

## Consequences

- Provider protocols and streaming behavior can be tested with `swift test` without launching the application.
- Probe CLIs exercise the same transport code used by the app.
- Application-only behavior still requires an Xcode build or manual macOS testing.
- Moving a shared file or adding a framework import can break consumers that are not visible from the edited file alone.

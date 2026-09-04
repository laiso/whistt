---
name: whistt-context
description: Locate Whistt's current specifications and non-obvious cross-cutting constraints before changes that span providers, audio capture, transcript output, credentials, or build boundaries. Do not use for isolated implementation work whose behavior is clear from code and tests.
---

# Whistt context

Use this skill to find context that cannot be recovered reliably from a single source file. Inspect code and tests for current structure rather than maintaining a duplicate architecture map.

## Sources of truth

1. Code and tests define implemented behavior.
2. `docs/specs/` defines current feature and technical contracts.
3. `whistt-decisions` preserves historical intent and tradeoffs; it does not define current behavior.

When these disagree, update the applicable specification with the implementation and tests. Do not rewrite history in an accepted decision record.

## Read by change area

- Shortcut behavior: read `docs/specs/hotkeys.md`.
- CI triggers, required checks, or release verification: read decision 0001.
- App/package dependency boundary: read decision 0002.
- Provider result normalization or cursor output: read decision 0003.
- Push-to-talk lifecycle or interim transcript delivery: read decision 0004.
- Credential or non-secret provider setting storage: read decision 0005.

## Cross-cutting constraints

- Keep application UI, microphone capture, and other AppKit/AVFoundation runtime behavior out of the Swift package boundary used by tests and probe CLIs.
- Provider transports own connection lifecycle, wire formats, and conversion into provider-neutral transcript revisions. Output layers must not interpret provider protocol events.
- Treat provider interim text as revisable unless the transport proves that a suffix is append-safe. Text already inserted into another application cannot always be rolled back safely.
- The app stores provider secrets in Keychain and non-secret provider settings in preferences. Probe CLIs use environment or `.env` values because unsigned command-line tools do not share the app's Keychain access.

Run `swift test` for package changes and `make build` when app-target code or shared source membership may be affected.

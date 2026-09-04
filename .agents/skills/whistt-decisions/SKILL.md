---
name: whistt-decisions
description: Consult Whistt's historical architectural decisions when a change affects a listed decision area. Do not use for routine implementation that does not touch those areas.
---

# Whistt decisions

Use this skill only to recover the reasoning behind an architectural or operational constraint. The current behavior is defined by code, tests, and `docs/specs/`; decision records explain how and why it was chosen.

Read only the reference whose area overlaps the task. Do not load every decision, and do not treat superseded decisions as current requirements.

## Decision index

| Order | Date | Status | Decision | Read when |
| ---: | --- | --- | --- | --- |
| 0001 | 2026-09-03 | Accepted | [Add continuous integration for pull requests](references/0001-add-ci-for-pull-requests.md) | Changing CI triggers, required checks, test/build jobs, or release verification |
| 0002 | 2026-09-04 | Accepted | [Keep platform UI and audio capture outside the package boundary](references/0002-keep-platform-code-outside-package-boundary.md) | Moving code between the app target and Swift package, or changing probe/test dependencies |
| 0003 | 2026-09-04 | Accepted | [Normalize provider transcripts before output](references/0003-normalize-provider-transcripts-before-output.md) | Changing provider event mapping, transcript revisions, typing, or clipboard output |
| 0004 | 2026-09-04 | Accepted | [Model dictation as manual push-to-talk with conservative output](references/0004-use-manual-push-to-talk-and-conservative-output.md) | Changing turn detection, commit timing, interim delivery, cancellation, or finalization |
| 0005 | 2026-09-04 | Accepted | [Separate provider secrets from non-secret settings](references/0005-separate-provider-secrets-from-settings.md) | Changing credential storage, provider settings, environment overrides, or CLI authentication |
| 0006 | 2026-09-04 | Accepted | [Extract release automation into testable scripts](references/0006-extract-release-automation-into-testable-scripts.md) | Changing release versioning, release-note generation, AI fallback behavior, or their tests |

When a decision changes, add a new numbered record instead of rewriting its rationale. Mark the earlier entry `Superseded` and link both records.

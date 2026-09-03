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

When a decision changes, add a new numbered record instead of rewriting its rationale. Mark the earlier entry `Superseded` and link both records.

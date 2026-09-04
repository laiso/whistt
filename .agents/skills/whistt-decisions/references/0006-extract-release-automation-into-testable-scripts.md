# ADR 0006: Extract Release Automation into Testable Scripts

- Status: Accepted
- Date: 2026-09-04

## Context

The release workflow calculates versions and assembles release notes in inline shell blocks. This couples business rules to GitHub Actions expressions and makes edge cases difficult to test locally. Release summaries may optionally come from Copilot, whose availability and output are nondeterministic.

## Decision

Keep GitHub Actions responsible for orchestration and external service invocation. Extract deterministic version calculation and release-body generation into repository scripts with explicit arguments and outputs.

Test the scripts without calling Copilot. Cover AI-summary presence, missing or empty summaries, commit-message fallback, and supported version-bump inputs. When no usable AI summary exists, list first-parent commit subjects since the previous release tag. A Copilot failure must not prevent a release.

## Consequences

### Positive

- Release rules can be tested locally and in pull-request CI.
- Copilot credentials and availability are not required for tests.
- Workflow YAML stays focused on orchestration.
- Fallback behavior remains deterministic.

### Negative

- The repository owns shell scripts and their test harness.
- GitHub Actions integration still requires validation on GitHub.
- AI prose quality cannot be covered by deterministic unit tests.

## Relationship to ADR 0001

ADR 0001 remains accepted. This decision extends its CI approach to release automation; it does not replace the existing package-test or application-build checks.

# ADR 0001: Add Continuous Integration for Pull Requests

- Status: Accepted
- Date: 2026-09-03

## Context

This repository does not currently run CI checks on pull requests.

PR #10 changes the shared audio-sending layer, buffering, framing, pacing, and end-of-stream handling. It also modifies the OpenAI, Gemini, and Meta transport paths. At approximately 1,300 changed lines, it is difficult to verify through review alone that a fix for one provider does not break another provider or the macOS application.

The following checks have been run locally on the PR #10 branch:

- `swift test`: 54 tests passed, 0 failures
- `make build`: macOS application Debug build succeeded

However, these are developer-reported local results and are not automatically verified on GitHub. The test count in a pull request description may also become outdated, and local results cannot be enforced as merge requirements.

## Decision

Use GitHub Actions to run the following checks on a macOS runner for pull requests targeting `main` and pushes to `main`.

### 1. Test the Swift package

```sh
swift test
```

This check detects regressions in `WhisttCore`, including:

- Audio framing and byte ordering
- Pre-ready buffering and buffer limits
- Real-time send pacing
- Send-completion gating and end-notification ordering
- State isolation between sessions
- OpenAI, Gemini, and Meta protocol handling
- Environment file loading

### 2. Build the macOS application in Debug configuration

```sh
make build
```

This check verifies that the complete application compiles, including code excluded from the Swift package test target, such as the UI, `AppDelegate`, API key settings, and audio-input handling.

## Implementation tasks

- [ ] Add `.github/workflows/ci.yml`
- [ ] Trigger the workflow for pull requests targeting `main` and pushes to `main`
- [ ] Check out the repository on a macOS runner
- [ ] Add a job that runs `swift test`
- [ ] Add a job that runs `make build`
- [ ] Keep tests and the application build in separate jobs so failures are easy to identify on the pull request
- [ ] Cancel obsolete runs when a newer commit is pushed to the same branch
- [ ] Confirm that both jobs pass in the pull request that introduces CI
- [ ] Make both checks required in the GitHub branch protection settings for `main`
- [ ] Update the test count in the PR #10 description to match the current result

## Acceptance criteria

- Creating or updating a pull request automatically starts the test and application-build checks
- When a check fails, the failed check and its logs are visible from the pull request
- A pull request cannot be merged into `main` unless both checks pass
- CI runs without registering API keys or other secrets
- CI does not connect to external speech-recognition APIs

## Consequences

### Positive

- Test and build results are verified independently of the pull request author's report
- Regressions in changes spanning multiple providers can be detected before merge
- Compilation errors in the macOS application are detected in addition to Swift package failures

### Negative

- The workflow consumes macOS runner time and the repository's GitHub Actions allowance
- Xcode or macOS runner updates may cause failures unrelated to application changes
- The initial configuration may be slower because it does not cache build artifacts

## Out of scope

This CI configuration will not automate:

- Recording from a physical microphone
- Live connections to OpenAI, Gemini, or Meta
- Live probe commands that require API keys
- Reproducing the Meta disconnection issue with utterances longer than 10 seconds
- Code signing, notarization, or distribution Release builds

For now, these remain manual smoke tests to run before a release or when changing the audio transport paths. If a stable mock or dedicated test environment becomes available, their automation should be considered in a separate ADR.

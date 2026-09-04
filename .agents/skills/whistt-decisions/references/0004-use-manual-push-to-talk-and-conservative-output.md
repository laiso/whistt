# ADR 0004: Model Dictation as Manual Push-to-Talk With Conservative Output

- Status: Accepted
- Date: 2026-09-04

## Context

Whistt uses a held shortcut to define one dictation turn. Provider-side voice activity detection can split speech at pauses, and provider interim hypotheses may revise text already inserted into the frontmost application. Cancellation makes rollback especially unsafe because Whistt does not own the destination editor.

## Decision

Treat shortcut press and release as the authoritative turn boundaries. Disable provider automatic turn detection where the API permits it, and explicitly end or commit input on release.

Only deliver interim text when it is known to be append-safe. Otherwise keep revisions internal and insert the finalized transcript once.

## Consequences

- Natural pauses do not create unintended turns.
- One shortcut gesture corresponds to one final transcript.
- Providers without append-safe deltas do not display live text.
- Each provider transport must translate the shared push-to-talk lifecycle into its own start, commit, end, and finalization messages.

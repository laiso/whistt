# ADR 0003: Normalize Provider Transcripts Before Output

- Status: Accepted
- Date: 2026-09-04

## Context

Speech providers report results with incompatible semantics. Some send append-only deltas, while others replace a cumulative interim hypothesis or emit final text only. Passing raw provider events to typing and clipboard code would spread protocol-specific behavior through the application.

## Decision

Each provider transport owns its connection lifecycle, wire protocol, and mapping into the provider-neutral `TranscriptRevision` model. `TranscriptRevisionBuffer` converts revisions into output operations when doing so is safe.

Output layers consume normalized revisions or final transcripts and must not branch on provider protocol events.

## Consequences

- A provider can be added or changed without teaching output code its event vocabulary.
- Tests can verify revision semantics independently from macOS cursor output.
- Provider adapters must classify partial, confirmed, and final results correctly.
- A mistaken append-safe classification can insert text that cannot be repaired reliably in another application.

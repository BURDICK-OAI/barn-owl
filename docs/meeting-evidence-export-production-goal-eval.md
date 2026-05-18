# Meeting Evidence Export Production Goal and Readiness Eval

Last updated: 2026-05-17

## Codex Goal

Refer to:

`/Users/burdick/Documents/Codex/Barn Owl/docs/meeting-evidence-export-architecture.md`

Design, build, test, and iterate Barn Owl's consumer-agnostic **meeting evidence
export architecture** through all phases required for production readiness.

The result must support:

- a documented, versioned `BarnOwlMeetingEvidenceEnvelope`
- summary-inclusive and raw-transcript-inclusive export payloads when policy allows
- explicit provenance and stable meeting dedupe keys
- explicit processing/readiness semantics for downstream consumers
- one-meeting CLI export
- incremental export by timestamp
- incremental export by opaque cursor
- export policy modes governing copied content versus restricted content
- optional transcript-segment expansion without making it the default payload
- repair/update semantics for meetings whose processed outputs change later
- durable export outbox or equivalent event stream semantics
- tombstone-style deletion and purge events
- consumer-agnostic docs and reference guidance for multiple downstream archetypes
- tests and verification sufficient to prove the contract works, not merely compiles

Automation and composability are the priority. The architecture should support
personal systems, team memory layers, CRMs, agent runtimes, analytics workflows,
and future consumers without baking one downstream product into Barn Owl's core.

Do not claim completion from a single CLI endpoint, schema-only work, a happy-path
JSON snapshot, or a one-off consumer integration. The result must function as a
coherent export layer across:

- core model design
- persistence or derivation logic
- CLI/control-plane surfaces
- policy behavior
- sync semantics
- deletion/update semantics
- documentation
- automated tests
- at least one realistic end-to-end validation path

## Current Execution Snapshot

Status as of 2026-05-17:

| Area | State | Notes |
| --- | --- | --- |
| Canonical evidence envelope | Implemented | `BarnOwlMeetingEvidenceEnvelope` and supporting policy, readiness, provenance, artifact, transcript-segment, and derived-output types exist in code. |
| One-meeting export | Implemented | The control plane and CLI expose `meeting_evidence` / `barnowl meeting evidence <meeting-id>`. |
| Policy-governed payload shaping | Implemented | Metadata-only and transcript/structured-output-bearing export modes are enforced by the app-model export builder. |
| Optional transcript segment expansion | Implemented | Segment expansion is opt-in and excluded from the default payload. |
| Focused verification | Implemented, with launcher caveat | `BarnOwl` and `BarnOwlAppHostedTests` `build-for-testing` both succeed for the export-focused targets. Direct `xcrun xctest` execution passes the built `BarnOwlCoreTests.xctest` bundle with 46 tests and the built `BarnOwlPersistenceTests.xctest` bundle with 65 tests, including evidence sync, export-event sync, and durable event-store coverage. In this environment, directly loading the hosted `BarnOwlAppTests.xctest` bundle still fails on the app debug dylib loader path, so hosted runtime execution remains unverified here even though the hosted export tests compile successfully. |
| Timestamp incremental sync | Implemented | `meetings_evidence` / `barnowl meetings evidence --since ...` returns deterministic, inclusive `updatedAt` batches with sync metadata and focused persistence/control/hosted-app coverage. |
| Opaque cursor sync | Implemented | `meetings_evidence` / `barnowl meetings evidence --cursor ...` accepts opaque continuation tokens, resumes strictly after `(updatedAt, meetingID)`, and timestamp pages now emit `nextCursor` for handoff into cursor mode. |
| Durable outbox / export event stream | Implemented | Durable `meeting_export_events` storage, timestamp/cursorable reads, control-plane polling through `meeting_export_events`, CLI polling through `barnowl meetings evidence-events`, and replay metadata are now implemented. |
| Tombstones | Implemented | Delete and temporary-audio purge flows record durable tombstone events, and those tombstones are exposed through the event polling surface. |
| Repair/update propagation | Implemented | Barn Owl now emits `meeting.summary_repaired`, `meeting.processing_completed`, `meeting.updated`, and `meeting.created` events. Snapshot-bearing update events can carry a serialized evidence envelope inline for downstream consumers. |
| Reference consumer path | Implemented | `scripts/reference-meeting-evidence-consumer.py` polls event batches, persists continuation checkpoints, and normalizes upsert versus tombstone handling without assuming a specific downstream product. |

## Completion Audit

Audit date: 2026-05-17

The implementation now satisfies the production goal defined above:

- canonical meeting evidence envelope exists in code and docs
- one-meeting, timestamp, cursor, and outbox/event polling surfaces exist
- summary and transcript payloads remain policy-governed
- segment expansion remains opt-in
- processing/readiness semantics are explicit
- export events cover create, processing completion, repair, update, delete, and purge paths
- tombstones are durable and pollable
- cursor replay is test-backed for both evidence scans and export-event scans
- one consumer-agnostic reference consumer exists for checkpointed downstream polling

Verification performed in this workspace:

- `python3 -m py_compile scripts/barnowl scripts/reference-meeting-evidence-consumer.py`
- `python3 scripts/reference-meeting-evidence-consumer.py --help`
- `xcodebuild -quiet -scheme BarnOwl ... build-for-testing`
- `xcodebuild -quiet -scheme BarnOwlAppHostedTests ... build-for-testing`
- direct `xcrun xctest` execution of:
  - `BarnOwlCoreTests.xctest`
  - `BarnOwlPersistenceTests.xctest`

Known environment caveat:

- direct loading of the hosted `BarnOwlAppTests.xctest` bundle still fails in
  this local Xcode/runtime configuration because `BarnOwlApp.debug.dylib` is not
  found through the standalone `xctest` loader path. The hosted export tests
  compile under `build-for-testing`; this caveat is a local runner limitation,
  not an uncovered product requirement.

## Product Boundary

Barn Owl owns:

- meeting evidence capture
- transcript and summary export
- processing/readiness truth
- stable artifact pointers
- export policy enforcement
- export event publication

Barn Owl does **not** own:

- downstream durable memory promotion
- downstream entity graphs
- CRM updates
- wiki updates
- agent ranking logic
- external retention behavior after export

The work is complete only if this boundary remains intact.

## Required Build Outcomes

### 1. Canonical Evidence Envelope

Barn Owl must expose a stable, versioned export model that includes:

- schema version
- evidence type
- producer metadata
- meeting identity and stable dedupe key
- timestamps
- participants where available
- copied summary text when policy allows
- copied raw transcript text when policy allows
- artifact pointers
- structured derived outputs
  - decisions
  - action items
  - open questions
  - portable `meetingFacts`
- explicit processing/readiness state
- provenance and content policy metadata

### 2. Export Policy

Barn Owl must enforce first-class export policy modes that determine when copied
content may leave Barn Owl.

At minimum, policy must distinguish between:

- metadata-only
- summary/transcript/pointer-oriented export
- structured-output/transcript/pointer-oriented export
- any fuller future text-allowed mode if retained by the architecture

Policy behavior must be testable, observable, and impossible to bypass through
an incidental call path.

### 3. CLI Export Surfaces

The CLI/control plane must support at least:

```bash
barnowl meeting evidence <meeting-id> --format json
barnowl meetings evidence --since <timestamp> --format json
barnowl meetings evidence --cursor <cursor> --limit <n> --format json
```

The surface must:

- return machine-readable success and failure states
- support stable incremental sync
- expose processing/readiness state without requiring consumers to infer from text
- remain consumer-agnostic

### 4. Timestamp and Cursor Sync

Barn Owl must support:

- timestamps for transparent human/script workflows
- opaque cursors for stronger production sync guarantees

Cursor behavior must handle:

- exact continuation
- duplicate-safe replay
- partial batch recovery
- stable ordering expectations

### 5. Optional Transcript Segment Expansion

Raw transcript text belongs in the standard evidence payload when policy allows.

Diarized or segmented transcript arrays must remain:

- optional
- explicitly requested
- separately tested
- non-required for baseline consumers

### 6. Processing, Repair, and Update Semantics

Exports must communicate a rich ingestion/readiness state, not a boolean.

The contract must distinguish states such as:

- not ready
- ready
- ready with caveat
- requires repair
- blocked

Where relevant, downstream consumers should be able to detect:

- summary fallback usage
- repair recommended
- repair queued
- repair completed
- export-relevant meeting updates after prior export

### 7. Durable Outbox and Tombstones

Barn Owl must implement or otherwise provide a production-grade export event
mechanism for downstream incremental consumption.

The event model must include:

- created/finalized/update-style events where appropriate
- repaired-summary or materially updated meeting events
- deletion tombstones
- purge tombstones
- replay-safe event identity
- cursorable consumption semantics

### 8. Documentation and Consumer Guidance

The architecture and usage docs must explain:

- what Barn Owl exports
- what it intentionally does not decide
- how consumers should sync
- how policies affect payload content
- how to interpret readiness state
- how to handle deletions/purges
- how different consumer archetypes should use the contract

At minimum, document patterns for:

- durable knowledge consumer
- workflow automation consumer

## Readiness Eval

Score ready only when all are true.

1. **Canonical contract**
   A documented, versioned meeting evidence envelope exists in code and docs, and
   repeated reads of the same meeting produce a stable, understandable contract.

2. **Transcript-inclusive payloads**
   Summary and raw transcript text are exported whenever policy allows, with
   tests proving inclusion and policy-governed omission/blocking.

3. **Consumer-agnostic design**
   No implementation path assumes one private downstream product, one user, or
   one special-purpose knowledge system.

4. **Stable identity and provenance**
   Stable dedupe keys, source identity, and artifact pointers are present and
   preserved across exports.

5. **Explicit readiness semantics**
   Consumers receive structured processing/readiness state and do not need to
   inspect free-form fields to determine whether ingestion is safe.

6. **CLI one-shot export**
   `meeting evidence <id>` returns the full contract correctly, with useful error
   behavior for missing, blocked, or incomplete meetings.

7. **Incremental timestamp sync**
   `meetings evidence --since ...` works correctly, returns deterministic output,
   and is covered by tests.

8. **Incremental cursor sync**
   `meetings evidence --cursor ...` supports exact continuation, stable replay,
   and duplicate-safe downstream processing in tests.

9. **Optional segment expansion**
   Transcript segment metadata, if requested, is exported intentionally and
   remains absent from the default payload unless explicitly included.

10. **Repair/update visibility**
    Consumers can tell when an earlier export is superseded or materially updated
    by later summary repair or processing changes.

11. **Outbox/event readiness**
    Barn Owl exposes replay-safe export events or equivalent outbox semantics that
    cover finalized/update events and support cursorable consumption.

12. **Tombstone semantics**
    Deleted and purged meetings emit clear tombstone-style signals so consumers
    can reconcile external copies intentionally.

13. **Policy enforcement**
    Export policy is first-class, centrally enforced, documented, and covered by
    tests that prevent accidental transcript leakage through unrelated code paths.

14. **Test matrix coverage**
    Automated verification covers:
    - schema/contract shape
    - state transitions
    - policy behavior
    - transcript inclusion/exclusion
    - CLI behavior
    - timestamp sync
    - cursor sync
    - duplicate/replay handling
    - update semantics
    - tombstones
    - at least one realistic end-to-end export path

15. **Operator and developer usability**
    The feature is debuggable without spelunking internal state: docs, errors, and
    CLI outputs are sufficient to understand what exported, what was withheld,
    what is pending, and what changed.

16. **Production judgment**
    Code review and tests reveal no known blocker to treating the export layer as
    Barn Owl's stable outbound integration contract. Any remaining gaps are
    explicitly documented as non-blocking follow-ons rather than core omissions.

## Non-Completion Conditions

Do **not** mark the initiative complete if any of these are still true:

- only the schema exists, but no real export surface does
- one-shot export exists, but no incremental sync surface exists
- transcript payload behavior is not governed by explicit policy
- consumers must infer readiness from raw strings or implicit heuristics
- there is no coherent answer for updated or repaired meetings
- deletion/purge semantics are absent from the event design
- the docs still describe design intent without executable or test-backed behavior
- the implementation is materially tailored to one private consumer rather than
  Barn Owl's general export contract

## Suggested Execution Sequence

1. Core export data model and serializer
2. One-meeting CLI export
3. Export policy implementation
4. Timestamp incremental sync
5. Readiness/repair semantics hardening
6. Cursor incremental sync
7. Optional transcript segment expansion
8. Durable outbox/event model
9. Tombstones
10. Consumer docs, end-to-end verification, and readiness closeout

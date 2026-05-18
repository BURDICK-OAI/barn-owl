# Enrichment Source Registry Goal and Readiness Eval

## Codex Goal

Refer to:
`/Users/burdick/Documents/Codex/Barn Owl/docs/enrichment-source-registry-architecture.md`

Design, implement, test, and iterate Barn Owl's user-scoped enrichment source
registry so autonomous knowledge enrichment can draw from Barn Owl memory,
user-private/internal systems, public internet/reference sources, and future
connectors without hardcoding any one user's source stack.

Barn Owl must add a durable per-user source registry, a clear Settings surface,
source health/status tracking, authority/best-used-for metadata, and a source
adapter foundation that supports future orchestrated enrichment. The design must
preserve Barn Owl's automation-first direction: high-confidence enrichment may
act automatically, but evidence, provenance, user scope, confidence, and failure
states must remain inspectable. Private sources should be representable as
owner-configured sources, not as universal defaults.

The work should include:

- source registry persistence and data model
- Settings UI for viewing/managing enrichment sources
- seeded built-in sources where appropriate
- support for user-specific/custom sources
- source health/auth/status representation
- authority profile and best-used-for metadata
- CLI/control-plane read/write support as needed
- tests that verify per-user behavior, Settings readiness, and extensibility
- iteration against this eval until all readiness conditions hold

Do not claim completion from partial UI-only or schema-only work. The result
must be coherent across persistence, app model, Settings, control plane, and
tests.

## Readiness Eval

Score ready only when all are true:

1. **Per-user registry**: enrichment sources are stored per user/owner scope;
   owner-private sources can exist without appearing for unrelated users.
2. **Source model**: entries support stable id, display name, source type,
   enabled state, scope, authority/best-used-for metadata, config payload, and
   timestamps.
3. **Health/status**: Barn Owl can represent source readiness such as ready,
   disabled, needs auth, stale, partial, or error, with last-check metadata.
4. **Settings UX**: Settings exposes an Enrichment Sources surface that lists
   configured sources clearly and supports at least safe enable/disable plus
   status inspection without misleading global assumptions.
5. **Extensibility**: the implementation introduces a reusable source-adapter or
   source-contract foundation rather than hardcoding one user's private system
   into Barn Owl's core enrichment logic.
6. **Control plane**: CLI/control APIs can inspect configured sources and make
   the core registry manageable without GUI-only dependence where practical.
7. **Privacy/provenance**: scope and source identity are preserved so private,
   workspace, organization, and public sources remain distinguishable.
8. **Verification**: tests cover registry persistence, per-user isolation,
   Settings/app-model behavior, source metadata/status, and at least one
   custom/private source case plus one general/default source case.
9. **Iteration loop**: any gaps found by tests or code review are fixed before
   completion is claimed.

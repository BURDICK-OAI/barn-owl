# Priority Enrichment Sources Goal and Readiness Eval

## Codex Goal

Refer to:
`/Users/burdick/Documents/Codex/Barn Owl/docs/priority-enrichment-sources-implementation-plan.md`

Design, implement, test, and iterate Barn Owl's next priority enrichment-source
expansion so meeting-adjacent private context can be registered, inspected, and
hydrated through the generic Codex-mediated connector flow without embedding any
one operator's local-only context into source code.

The work must add first-class product support for the following generic
connector-backed source families:

- Gmail
- Google Calendar
- Gong
- ChatGPT Meetings

The implementation must preserve Barn Owl's existing boundary:

- Codex performs authenticated retrieval and selective context hydration.
- Barn Owl owns the local durable registry, normalized configured payloads,
  source health/status, enrichment adjudication, and downstream reuse.

The work must also improve source readiness semantics so a source that is merely
registered or structurally configured is not presented as fully hydrated or
fully contributing evidence. Empty connector payloads should remain visible and
actionable rather than being treated as equivalent to a source with reusable
entries.

The work should include:

- preset/catalog updates for the four new generic source families
- source readiness behavior that distinguishes empty configured payloads from
  materially hydrated payloads
- README and Barn Owl skill guidance that describe ongoing per-meeting and
  per-enrichment-job hydration rather than one-time setup
- verification hardening that keeps local build scratch such as `DerivedData*`
  out of source handoff bundles
- tests that cover preset setup, readiness semantics, and the connector-mediated
  architecture without requiring live private connector calls

Do not claim completion from docs-only edits or preset-only edits. The result
must be coherent across control-plane defaults, readiness behavior,
operator-facing guidance, packaging verification, and focused tests.

## Readiness Eval

Score ready only when all are true:

1. **Preset coverage**: Barn Owl exposes presets for Gmail, Calendar, Gong, and
   ChatGPT Meetings alongside the existing generic source presets.
2. **Product boundary**: the implementation preserves Codex-mediated retrieval
   and does not imply Barn Owl directly signs into or mirrors private systems.
3. **Hydration semantics**: empty but structurally valid connector payloads do
   not report as fully ready/hydrated; source posture remains inspectable and
   meaningfully different from hydrated payloads.
4. **Setup correctness**: setup-from-preset persists the expected connector
   metadata, scope, authority profile, and privacy/query policies for the new
   source families.
5. **Operational guidance**: README and shipped Barn Owl skill guidance explain
   that hydration is recurring, meeting-aware, and selective rather than a
   one-time install/onboarding step.
6. **Local-only separation**: operator-specific systems and personal mappings
   remain local data/configuration, not product defaults.
7. **Packaging safety**: source-handoff verification rejects `DerivedData*`
   build scratch folders and continues to exclude local/generated material.
8. **Verification**: focused tests cover the new preset catalog and at least one
   configured-empty versus configured-hydrated readiness path.
9. **Iteration loop**: any failures found by tests or review are addressed before
   completion is claimed.


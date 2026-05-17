# Autonomous Enrichment Production Goal and Readiness Eval

## Codex Goal

Refer to:
`/Users/burdick/Documents/Codex/Barn Owl/docs/enrichment-source-registry-architecture.md`

Design, build, test, and iterate Barn Owl's autonomous enrichment system through
all remaining phases needed for internal-production readiness:

- real enrichment adapters for Barn Owl memory, user-private/internal sources
  such as Collin OS, and public/reference research
- normalized evidence contracts, persisted enrichment jobs, evidence trails,
  conflicts, and rationale
- orchestration that detects unresolved recurring concepts, selects sources by
  policy/health/authority, gathers evidence, adjudicates outcomes, and either
  persists or holds them explainably
- durable knowledge updates for people, companies, projects, events, aliases,
  and similar recurring entities, with historical backfill where warranted
- transcript/note improvement that reuses accepted durable knowledge and records
  whether that knowledge helped
- confidence reinforcement, negative evidence, conflict memory, and per-source
  usefulness metrics that improve routing and persistence policy over time
- connector-backed setup flows, reusable authority profiles, user/workspace
  policy packs, and onboarding defaults that generalize beyond Collin's setup
- CLI/control-plane and Settings surfaces sufficient to inspect, operate, and
  troubleshoot the system without relying on hidden magic

Automation should be the default when policy permits. Human review may remain
available, but production readiness requires autonomous operation that is
evidence-backed, reversible, observable, and user-scoped.

Do not claim completion from isolated adapters, schema-only work, or a single
happy-path demo. The result must function coherently across persistence,
orchestration, app flows, transcript/note enrichment, Settings, control plane,
onboarding, and tests.

## Readiness Eval

Score ready only when all are true:

1. **Evidence system**: adapters emit one normalized evidence model; enrichment
   jobs, evidence rows, conflicts, rationale, and outcomes persist durably.
2. **Adapter coverage**: Barn Owl memory, Collin OS-style private/internal
   source, and public/reference source are real, tested, and policy-aware.
3. **Orchestration**: recurring unresolved concepts trigger source selection,
   evidence gathering, adjudication, and persist/hold decisions automatically.
4. **Durable knowledge**: Barn Owl can create/update scoped entities, aliases,
   and meeting links for people, companies, projects, events, and analogous
   concepts without fabricating weak mappings.
5. **Downstream lift**: accepted knowledge improves later transcript suggestions,
   transcript correction or structuring, and note generation in tested flows.
6. **Learning loop**: source usefulness metrics, repeated corroboration,
   reversals, conflicts, and negative evidence measurably affect confidence or
   routing decisions.
7. **Automation policy**: auto-persist/hold/review behavior is explicit,
   reversible, provenance-preserving, and blocks weak public-only private truth.
8. **Broader-user extensibility**: onboarding, presets, policies, and connector
   setup work without assuming Collin OS or one user's internal stack.
9. **Operator surfaces**: Settings and CLI/control paths expose sources, health,
   recent enrichment activity, held/conflicted items, and useful diagnostics.
10. **Verification**: tests cover entity recurrence, multi-source agreement,
    disagreement, stale/auth-blocked sources, transcript/note improvement,
    user isolation, onboarding defaults, and at least one end-to-end automatic
    persistence path plus one held/conflicted path.
11. **Production judgment**: code review and tests find no known blocker to
    internal production use; remaining gaps are documented as non-blocking.

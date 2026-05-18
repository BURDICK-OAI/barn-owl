# Priority Enrichment Sources Implementation Plan

## Objective

Expand Barn Owl's generic enrichment-source support so the product can make
better use of high-signal private context without absorbing any one operator's
personal knowledge graph into source code.

The next product-level step is to add first-class support for:

- Gmail
- Google Calendar
- Gong
- ChatGPT Meetings

Barn Owl should continue to treat Codex as the authenticated retrieval and
selection layer for connector-backed sources. Barn Owl owns the durable local
registry, source metadata, persisted evidence, adjudication, and reuse policy.

## Current State

Barn Owl already supports:

- a per-user enrichment-source registry
- built-in source presets for Drive, Slack, Notion, and Salesforce
- custom/local sources through CLI upsert
- source health/status tracking
- enrichment source adapters that operate on normalized configured payloads
- an architecture where Codex retrieves private source evidence and hydrates
  Barn Owl with concise summary-or-pointer payloads

The current gap is not the existence of a registry. The gap is that the most
useful meeting-adjacent sources are either:

- only available through ad hoc local upsert, or
- represented as "ready" even when they are merely registered and have not yet
  been hydrated with any usable evidence.

## Design Principles

1. **Local personal context stays local**
   - User-specific aliases, recurring people, account-specific notes, and
     operator-specific systems such as Collin OS remain local-only data.
   - Source code may support a generic source mechanism, but it must not embed
     personal defaults or owner-specific mappings.

2. **Connector access remains Codex-mediated**
   - Barn Owl must not pretend to directly authenticate into Gmail, Calendar,
     Gong, ChatGPT Meetings, or similar private systems.
   - Codex retrieves and selects evidence, then Barn Owl stores normalized local
     enrichment payloads.

3. **Hydration is ongoing, not install-time**
   - Setup registers an enrichment lane.
   - Meeting-time and enrichment-time workflows hydrate or refresh that lane
     repeatedly when fresh context is needed.
   - Per-meeting hydration is the normal path, not a one-time onboarding step.

4. **Durable enrichment should stay selective**
   - Recurring people, accounts, products, projects, and high-value terminology
     can become durable Barn Owl knowledge.
   - One-off attendees, transient side threads, and broad connector dumps should
     stay just-in-time meeting context.

5. **Readiness should say what it means**
   - "Configured" means the source is registered and shaped correctly.
   - "Hydrated" means the source has usable evidence payloads.
   - "Ready for retrieval" and "ready to contribute evidence" should not be
     collapsed into one misleading status.

## Product Scope

### Add as source-code presets

#### `gmail_reference`

Best used for:

- recent meeting-relevant email threads
- written commitments and follow-ups
- customer/account context from inbox traffic

Connector reference:

- `gmail`

Recommended scope:

- `personal_private`

#### `calendar_reference`

Best used for:

- meeting titles and attendees
- recurring participant/account associations
- event metadata that improves meeting identification and routing

Connector reference:

- `google-calendar`

Recommended scope:

- `personal_private`

#### `gong_reference`

Best used for:

- prior customer/account conversation history
- repeated objections, commitments, and open issues
- participant disambiguation in commercial/customer settings

Connector reference:

- `gong`

Recommended scope:

- `organization_scoped`

#### `chatgpt_meetings_reference`

Best used for:

- prior meeting transcripts and summaries
- recurring names, concepts, and unresolved follow-ups
- internal and cross-context meeting memory not represented by Gong

Connector reference:

- `chatgpt-meetings`

Recommended scope:

- `workspace_private`

### Keep local-only rather than shipping as product presets

#### `collin_os_reference`

This is highly valuable for the owner workflow, but it is not a general Barn Owl
default. It should remain a local custom source unless the product later gains a
generic "operator memory system" connector family.

#### `active_google_docs_reference`

This is useful locally, but it is better modeled as a retrieval policy over the
existing Drive connector than as a product-level universal preset. Barn Owl can
still support it locally through custom source upsert.

## Architecture

### 1. Source Preset Layer

Extend the static preset catalog in the app model/control plane so Barn Owl can
surface the four new generic source options consistently through:

- CLI preset listing
- setup-from-preset flows
- Settings UI
- docs and skill guidance

The preset should encode:

- stable id
- display name
- source type
- scope
- authority profile
- connector reference
- best-used-for guidance
- default auth state
- default health posture
- privacy copy policy
- query budget policy

### 2. Source State Model

Introduce a clearer lifecycle for connector-backed sources.

Recommended posture:

- `needs_auth`
  - connector-backed source exists but retrieval setup is unavailable
- `configured`
  - source is registered and structurally valid, but no evidence payload has yet
    been hydrated
- `hydrated`
  - source contains at least one valid configured evidence entry or equivalent
    reusable payload
- `stale`
  - source has prior payloads but requires refresh before high-confidence reuse
- `partial`
  - some evidence is usable, but the source is incomplete or mixed-quality
- `error`
  - malformed payload, failed validation, or adapter/runtime failure

Implementation can use a new enum case, an additional detail field, or a
derived status calculation. The important part is that CLI and Settings no
longer tell operators that an empty source is fully "ready."

### 3. Hydration Lifecycle

Barn Owl should document and eventually make easy the following ongoing loop:

#### Setup-time

1. Register the source from preset.
2. Persist its source metadata locally.
3. Mark it configured but not hydrated until evidence exists.

#### Meeting-time

1. Codex inspects the current or upcoming meeting.
2. Codex chooses the minimum relevant source set.
3. Codex retrieves private context from connectors.
4. Codex attaches highly situational facts to the live meeting session.
5. If the evidence resolves a recurring concept or recurring account/person
   association, Codex refreshes the relevant Barn Owl enrichment payload.

#### Durable enrichment-time

1. Barn Owl identifies a recurring unresolved concept.
2. Codex queries the smallest useful source set.
3. Barn Owl receives normalized payloads through configured source upsert.
4. Barn Owl adjudicates whether to:
   - auto-persist
   - hold for more evidence
   - preserve conflict memory

### 4. Source Selection Policy

The implementation should make these routing heuristics easy to express in
docs, skill guidance, and future code:

#### Customer/account meeting

Prefer:

1. Calendar
2. Salesforce
3. Gong
4. Gmail
5. Slack
6. Drive/Docs
7. ChatGPT Meetings

#### Internal planning / strategy meeting

Prefer:

1. Calendar
2. Drive/Docs
3. Slack
4. Gmail
5. ChatGPT Meetings

#### Follow-up / execution meeting

Prefer:

1. Calendar
2. Gmail
3. Slack
4. Drive/Docs
5. Salesforce or Gong only when the meeting is account/customer related

These are prioritization heuristics, not mandates. The goal is to reduce noisy
retrieval and make the enrichment loop feel intentional rather than exhaustive.

### 5. Copy and Privacy Policy

All new connector-backed presets should use:

- `summary_or_pointer_only`

They should not encourage:

- raw inbox copying
- broad Slack transcript storage
- full Gong call mirroring
- full Drive/Docs body persistence
- private meeting transcript dumping

The durable payload should instead preserve:

- normalized summary
- source identity
- pointer/reference
- enough provenance to revisit or corroborate later

## Recommended Source-Code Changes

### Required

1. Add presets for:
   - `gmail_reference`
   - `calendar_reference`
   - `gong_reference`
   - `chatgpt_meetings_reference`

2. Update readiness semantics so empty configured connector-backed sources are
   visibly distinct from hydrated sources.

3. Update README and Barn Owl skill guidance so:
   - these four sources are mentioned in the setup flow
   - hydration is explicitly ongoing and per-meeting/per-enrichment-job
   - Codex-mediated retrieval remains the declared boundary

4. Harden source-handoff verification so any `DerivedData*` build scratch
   directories are forbidden from release source bundles, not only the exact
   `DerivedData/` path.

### Worth doing soon after

5. Consider exposing hydration posture in Settings with concise copy such as:
   - Configured, no evidence yet
   - Hydrated recently
   - Needs refresh

6. Consider a CLI inspection shape that answers:
   - is this source configured?
   - how many usable payload entries exist?
   - when was it last refreshed?
   - did it contribute to recent enrichment decisions?

7. Consider a future policy hook for meeting-type-based source prioritization if
   the current orchestration layer starts to accumulate ad hoc branching.

## Expected Files to Touch

Likely:

- `Apps/BarnOwlMac/BarnOwlAppModel.swift`
- `Sources/BarnOwlCore/BarnOwlControlCommand.swift`
- `Sources/BarnOwlPersistence/...` only if the readiness model needs persisted
  shape changes rather than derived posture
- `README.md`
- `scripts/verify-source-handoff.sh`
- Barn Owl Codex skill copy packaged with the app
- relevant control-plane / app-model / persistence tests

Potentially:

- Settings UI if hydration posture should become visible there immediately

## Testing Guidance

### 1. Preset coverage

Add tests that verify the preset catalog includes:

- Gmail
- Calendar
- Gong
- ChatGPT Meetings

Assert each preset has:

- stable id
- expected scope
- connector reference
- privacy copy policy
- query budget policy

### 2. Setup behavior

Verify setup-from-preset:

- creates the correct source record
- preserves user/owner scoping
- does not fabricate hydrated evidence
- surfaces the correct initial readiness posture

### 3. Hydration/readiness semantics

Add tests for at least:

- connector-backed source with no config payload
  - should remain auth/setup blocked where appropriate
- connector-backed source with structurally valid but empty payload
  - should read as configured but not hydrated
- connector-backed source with non-empty valid payload
  - should read as hydrated/ready-to-contribute
- stale or invalid payload case
  - should report stale/error/partial as appropriate

The critical regression to prevent is empty `{"entries":[]}` looking equivalent
to a source that can actually contribute evidence.

### 4. Meeting-time behavior

Tests do not need to call real Gmail, Calendar, Gong, or ChatGPT Meetings.
Instead:

- stub hydrated payloads
- run the existing source-selection/enrichment path
- assert that relevant evidence is preferred for the right meeting shape

Useful examples:

- customer meeting routes toward Calendar + Salesforce + Gong
- internal planning meeting routes toward Calendar + Drive/Docs + Slack
- follow-up meeting favors Calendar + Gmail

If source routing is not yet directly represented in code, capture this as
orchestrator-level integration guidance rather than forcing brittle tests too
early.

### 5. Durable enrichment behavior

Verify:

- strong multi-source support can promote a durable entity/alias
- weak or conflicting source combinations stay held
- public or generic sources do not override stronger private sources
- source usefulness metrics still record correctly for the new source ids

### 6. Privacy and packaging

Extend packaging/release checks so source bundles reject:

- `DerivedData*`
- local personal notes
- runtime databases
- local enrichment state
- generated artifacts

Keep the release verification strict enough that personal enrichment payloads
cannot drift into a handoff archive through an overlooked local directory.

### 7. Documentation verification

Update CLI/Codex QA checks if they assert specific enrichment-source guidance.
The docs should remain internally consistent across:

- README
- shipped Barn Owl skill
- setup examples
- privacy notes

## Rollout Order

Recommended order:

1. Add presets and docs for Gmail, Calendar, Gong, and ChatGPT Meetings.
2. Fix readiness semantics for configured-versus-hydrated sources.
3. Expose improved posture through CLI and Settings as needed.
4. Harden handoff verification for `DerivedData*`.
5. Add targeted regression tests and run the relevant suite.
6. Revisit source routing heuristics only after the status model is clear.

## Acceptance Criteria

The implementation is complete when:

1. The four new generic sources appear as first-class presets.
2. Empty configured sources are not presented as fully ready/hydrated.
3. Docs clearly state that hydration is recurring and occurs around meetings and
   enrichment jobs, not only during setup.
4. Codex-mediated retrieval remains the explicit private-source boundary.
5. Local-only personal/operator-specific sources remain outside product defaults.
6. Release/source-handoff checks protect against `DerivedData*` leakage.
7. Tests cover preset setup, readiness semantics, privacy expectations, and the
   intended reuse boundaries for the new source families.


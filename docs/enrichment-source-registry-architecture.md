# Barn Owl Enrichment Source Registry Architecture

Last updated: 2026-05-17

## Purpose

Barn Owl's autonomous enrichment system should become durable, extensible, and
portable across users. The current knowledge loop already lets Barn Owl detect
recurring concepts, build enrichment briefs, ask a structured resolver to make a
high-confidence durable judgment, and persist that judgment automatically when
the evidence is strong enough.

The next strategic step is to widen the evidence pool without turning Barn Owl
into a hardcoded collection of one-off integrations.

The core architectural decision is:

> Enrichment sources are user-scoped, policy-governed adapters that contribute
> normalized evidence into Barn Owl's durable knowledge loop.

This lets one user enrich from a private internal system like Private Reference Source while
another user may use Google Drive, Slack, Salesforce, Notion, or no internal
system at all. Barn Owl remains the same product because it relies on a common
source registry and evidence contract, not on bespoke assumptions about any one
person's tools.

## Product Thesis

Barn Owl should be able to:

- learn from its own meeting memory
- enrich ambiguous concepts from user-authorized internal systems
- use public internet/reference information when appropriate
- distinguish authoritative evidence from weak hints
- remember which sources are most useful for which kinds of concepts
- expose enabled enrichment sources in Settings
- store enrichment source configuration per user
- keep automatic learning inspectable, reversible, and explainable

Examples:

- `Rosalind` appears in fifteen meetings.
- Barn Owl decides it is highly salient but semantically unresolved.
- The enrichment orchestrator queries Barn Owl memory, Private Reference Source, and other
  permitted sources for the current user.
- Evidence is normalized, weighed by authority and freshness, and adjudicated.
- If the result is defensible, Barn Owl persists `Rosalind` as a project,
  backfills meeting links, and uses it in future transcription and note flows.
- If the evidence is still ambiguous, Barn Owl keeps the concept unresolved and
  records what it learned without fabricating a durable mapping.

## Design Principles

### 1. Sources are per-user, not global

Every user should have their own enrichment source registry.

- Private Reference Source may appear only for the owner.
- Another user may have Slack, Drive, Notion, or Salesforce.
- Another user may choose only Barn Owl memory plus public internet references.
- Source availability, credentials, scopes, and privacy rules should never be
  assumed globally.

### 2. Source adapters must converge on one evidence contract

Barn Owl should not need special-case persistence logic for Private Reference Source, Google
Drive, web search, or future connectors. Each adapter should return normalized
evidence records that the enrichment adjudicator can compare consistently.

### 3. Evidence outranks inference

A model may synthesize, adjudicate, and recommend. It should not become the sole
ground truth. Durable facts should be based on preserved evidence from explicit
sources, with the model acting as the reasoning layer over that evidence.

### 4. Authority and freshness matter

Not all evidence deserves equal weight.

- A user-confirmed durable entry outranks a casual web mention.
- A curated internal source can strongly classify an internal project.
- Public web can help confirm that Moderna is a biotechnology company, but not
  by itself prove that `Rosalind` is an internal Barn Owl user's project.
- Stale or auth-blocked sources should be visible as such.

### 5. Barn Owl should learn source usefulness over time

The system should not only ask "what did this source say?" It should eventually
learn:

- which sources resolve which entity kinds well
- which sources often conflict
- which sources become stale
- which sources produce accepted durable updates
- which sources repeatedly lead to reversals or corrections

This allows enrichment routing to become more selective and more accurate over
time.

## System Roles

### Barn Owl

Barn Owl owns:

- durable Context Library entities
- aliases
- meeting links
- evidence ledger
- enrichment job records
- user-scoped source registry
- source health and usefulness summaries
- review/audit/undo surfaces
- policy storage

### Codex

Codex owns:

- enrichment orchestration
- deciding which enabled sources to query
- cross-source comparison
- conflict explanation
- structured durable recommendations
- write-back through CLI/control APIs

### Source adapters

Source adapters own:

- fetching from one concrete source
- preserving source-specific metadata
- returning normalized evidence
- reporting auth, health, freshness, and limitations

Examples:

- Barn Owl memory adapter
- Private Reference Source adapter
- web/reference research adapter
- Google Drive adapter
- Slack adapter
- Calendar adapter
- Salesforce/CRM adapter
- Notion adapter
- future custom MCP/app adapter

## Per-User Enrichment Source Registry

Each Barn Owl user should have a private registry of enrichment sources.

Illustrative shape:

```json
{
  "userID": "local-owner",
  "sources": [
    {
      "id": "barnowl_memory",
      "displayName": "Barn Owl Memory",
      "sourceType": "local_memory",
      "enabled": true,
      "scope": "local_private",
      "authorityProfile": "meeting_memory",
      "bestUsedFor": [
        "recurrence",
        "transcript mentions",
        "meeting links"
      ],
      "healthStatus": "ready"
    },
    {
      "id": "owner_private_source",
      "displayName": "Private Reference Source",
      "sourceType": "internal_memory",
      "enabled": true,
      "scope": "personal_private",
      "authorityProfile": "private_internal_reference",
      "bestUsedFor": [
        "projects",
        "people",
        "customer/account context",
        "internal terminology"
      ],
      "healthStatus": "ready"
    },
    {
      "id": "public_web",
      "displayName": "Internet References",
      "sourceType": "public_reference",
      "enabled": true,
      "scope": "public",
      "authorityProfile": "public_reference",
      "bestUsedFor": [
        "public companies",
        "public products",
        "industry acronyms",
        "public events"
      ],
      "healthStatus": "ready"
    }
  ]
}
```

### Required registry fields

Each source entry should support:

- stable source id
- display name
- source type
- enabled / disabled
- user scope or tenant scope
- authority profile id
- best-used-for tags
- auth configuration state
- health state
- last successful check
- last failed check
- optional connector/app reference
- optional privacy copy policy
- optional query budget/rate limit policy

### Source scope taxonomy

Suggested scope values:

- `local_private`
- `personal_private`
- `workspace_private`
- `organization_scoped`
- `public`

This is separate from whether the source is "strong" or "weak." Scope answers
who the source belongs to and how cautiously it should be reused.

## Settings Experience

Barn Owl Settings should include an `Enrichment Sources` section.

Recommended row fields:

| Field | Purpose |
| --- | --- |
| Source | User-facing source name |
| Enabled | Whether enrichment jobs may use it |
| Scope | Local, personal, workspace, organization, public |
| Best For | Human-readable authority guidance |
| Status | Ready, needs auth, disabled, stale, error |
| Last Checked | Freshness / operational visibility |

Recommended controls:

- enable / disable toggle
- test source health
- open configure/auth flow
- inspect details
- edit best-used-for guidance when user-created/custom
- choose or inspect authority profile
- show "used recently" and "recently contributed" counts

### Example Settings rows

| Source | Scope | Best For | Status |
| --- | --- | --- | --- |
| Barn Owl Memory | Local private | Recurrence, transcripts, meeting links | Enabled |
| Private Reference Source | Personal private | Projects, people, account context | Enabled |
| Internet References | Public | Public org/product disambiguation | Enabled |
| Google Drive | Workspace private | Internal docs, project language | Disabled |

The Settings page should make it clear that Private Reference Source is not a universal Barn
Owl feature. It is one user's configured enrichment source.

## Source Adapter Contract

Each adapter should expose an operation conceptually similar to:

```swift
protocol EnrichmentSourceAdapter {
    func enrich(
        concept: KnowledgeConcept,
        brief: KnowledgeBrief,
        policy: EnrichmentPolicy
    ) async throws -> EnrichmentSourceResult
}
```

The exact production type can vary, but the contract should produce:

- source id
- source display name
- fetch status
- normalized evidence records
- citations or source pointers
- caveats
- health/freshness metadata

## Normalized Evidence Record

Illustrative evidence shape:

```json
{
  "subject": "Rosalind",
  "candidateKind": "project",
  "canonicalName": "Rosalind",
  "summary": "Recurring internal initiative referenced with launch and pricing decisions.",
  "confidence": 0.88,
  "source": "owner_private_source",
  "authority": "internal_curated",
  "freshness": "current",
  "scope": "personal_private",
  "citations": [
    "owner-private:object/project/rosalind",
    "meeting:2026-05-14:excerpt:3"
  ],
  "observedAt": "2026-05-17T12:00:00Z"
}
```

### Required evidence dimensions

- subject / observed value
- candidate kind
- candidate canonical name
- short explanatory summary
- confidence
- source id
- authority class
- freshness
- scope
- citations/pointers
- observation timestamp
- optional contradiction flag
- optional negative evidence marker

## Authority Profiles

Authority profiles define what a source is usually good for and how much weight
its evidence should receive.

Examples:

### `meeting_memory`

Good for:

- recurrence
- transcript co-occurrence
- concept salience
- meeting-link confidence

Weak for:

- canonical external descriptions
- distinguishing person vs product when transcripts are vague

### `private_internal_reference`

Good for:

- the owner-specific people
- internal project names
- customer/account shorthand
- internal events and workstreams

Weak for:

- public company facts when not explicitly grounded there

### `public_reference`

Good for:

- public company identity
- public product/entity disambiguation
- industry terms
- public events

Weak for:

- private internal project truth
- user-specific shorthand
- personal/team context

## Suggested Authority Classes

The adjudicator should reason over classes such as:

1. `user_confirmed`
2. `durable_internal`
3. `source_backed_internal`
4. `meeting_recurrence`
5. `calendar_or_metadata`
6. `public_reference`
7. `weak_inference`

These classes should inform thresholds, not replace stored source identity.

## Enrichment Orchestrator

The orchestrator should:

1. receive a concept and Barn Owl knowledge brief
2. inspect the current user's enabled source registry
3. select sources based on:
   - concept type uncertainty
   - registry availability
   - authority profile
   - current source health
   - privacy policy
   - query budget
4. run source adapters
5. normalize returned evidence
6. pass the complete packet to the adjudicator
7. persist if policy permits
8. hold if evidence is insufficient
9. record the enrichment job, evidence, and rationale

### Example enrichment path for `Rosalind`

1. Barn Owl sees `Rosalind` across many transcripts.
2. Salience rises.
3. Semantic meaning remains unresolved.
4. The orchestrator selects:
   - Barn Owl meeting memory
   - Private Reference Source for the current user
   - public web only if it may help disambiguate
5. The adapters produce normalized evidence.
6. The adjudicator concludes:
   - project is strongly supported
   - canonical name is `Rosalind`
   - alias list is limited and defensible
7. Barn Owl writes:
   - Context Library entity
   - aliases
   - evidence rows
   - backfilled meeting links
   - confidence and provenance

## Adjudication and Persistence Policy

Persistence should remain conservative.

Recommended initial automatic persistence rules:

- strong source-backed agreement, or
- strong internal source evidence plus strong Barn Owl recurrence evidence, or
- user-confirmed source evidence, or
- repeated durable corroboration over time

Automatic persistence should normally be blocked when:

- the result depends only on weak public web evidence
- multiple enabled sources materially disagree
- the source is stale or auth-blocked
- the candidate kind remains ambiguous
- the concept is user-private but the strongest evidence is public-only

### Example policy posture

| Situation | Action |
| --- | --- |
| Internal system + Barn Owl agree | Auto-persist |
| Public web + meeting recurrence agree on public company identity | Likely auto-persist |
| Public web alone suggests internal project meaning | Hold |
| Two internal sources disagree on kind | Hold and surface conflict |
| User explicitly confirms mapping | Persist |

## Confidence Model

Confidence should remain multidimensional:

- salience confidence
- semantic confidence
- alias confidence
- source confidence
- freshness confidence
- meeting-link confidence

### Reinforcement over time

Barn Owl should grow more confident when:

- an entity keeps recurring
- source-backed evidence repeats
- multiple source classes corroborate
- transcript correction succeeds repeatedly
- accepted durable knowledge improves downstream transcript/note quality

Confidence should weaken when:

- users undo or correct auto-persisted knowledge
- sources materially conflict
- stale evidence remains unrepaired
- aliases are repeatedly rejected
- a concept stops appearing or only appears in weak contexts

## Source Usefulness Learning

The system should record source performance over time.

Potential metrics per source:

- enrichment attempts
- successful contributions
- accepted durable resolutions
- held/blocked resolutions
- reversals or user corrections
- conflicts caused
- average freshness
- usefulness by entity kind

Examples:

- Private Reference Source resolves internal projects well.
- Web research helps public company disambiguation.
- Slack is useful for aliases and latest chatter, but weak for canonical truth.
- Drive is strong for project descriptions and acronym expansion.

The orchestrator should eventually use these metrics to route enrichment more
efficiently:

- query the best source first
- avoid low-yield sources for certain concept kinds
- escalate to wider retrieval only when needed

## Source Health

Each source should maintain health state:

- `ready`
- `disabled`
- `needs_auth`
- `stale`
- `partial`
- `error`

Health should influence:

- source selection
- confidence weighting
- whether a job may auto-persist
- what Settings displays

## Privacy and Portability

This design must work for both:

- a highly customized power user with private systems like Private Reference Source
- a new Barn Owl user with only local memory and public web references

### Portability requirements

- user-specific sources are optional
- connector availability is not assumed
- authority profiles are configurable
- source config is user-scoped
- policies are user-scoped or workspace-scoped
- no user's private source becomes another user's default

### Privacy requirements

- store pointers when copying raw content is inappropriate
- preserve source attribution
- allow sources to be disabled
- avoid public-web leakage into private durable truth without corroboration
- make external/internal evidence visibly distinguishable

## Proposed Data Model

Suggested durable tables or equivalents:

### `enrichment_sources`

- id
- user_id
- source_key
- display_name
- source_type
- enabled
- scope
- authority_profile_id
- config_json
- best_used_for_json
- created_at
- updated_at

### `enrichment_source_health`

- source_id
- status
- last_checked_at
- last_success_at
- last_failure_at
- message
- metadata_json

### `enrichment_authority_profiles`

- id
- name
- description
- strongest_entity_kinds_json
- weakest_entity_kinds_json
- default_weight
- auto_persist_policy_json

### `enrichment_jobs`

- id
- user_id
- concept_key
- requested_sources_json
- selected_sources_json
- status
- started_at
- finished_at
- summary
- failure_reason

### `enrichment_job_evidence`

- id
- job_id
- source_id
- normalized_evidence_json
- accepted_by_adjudicator
- created_at

### `enrichment_source_stats`

- source_id
- entity_kind
- attempts
- durable_accepts
- held_count
- conflict_count
- reversal_count
- last_updated_at

## CLI Direction

Recommended future commands:

```bash
barnowl knowledge enrich "Rosalind" --sources barnowl_memory,owner_private_source,public_web
barnowl knowledge explain "Rosalind"
barnowl knowledge jobs list
barnowl knowledge jobs get <job-id>
barnowl knowledge policy get
barnowl knowledge policy set ...

barnowl enrichment-sources list
barnowl enrichment-sources enable owner_private_source
barnowl enrichment-sources disable public_web
barnowl enrichment-sources test owner_private_source
barnowl enrichment-sources add ...
barnowl enrichment-sources update ...
```

The CLI should remain the authoritative programmable control plane. Settings is
the user-facing management layer over the same underlying model.

## Settings Roadmap

### Phase 1

- add `Enrichment Sources` Settings section
- show currently configured sources
- support enable/disable
- show health/auth state
- show source scope and best-used-for text

### Phase 2

- configure source-specific settings
- add/remove user-defined sources
- inspect authority profile
- show recent usage and last enrichment contribution

### Phase 3

- expose source usefulness analytics
- show recent conflicts and stale-source blockers
- allow advanced policy tuning
- support per-entity-kind source routing preferences

## Implementation Phases

### Phase 1: Registry and Settings Foundation

- add per-user source registry persistence
- add Settings surface
- seed default local sources:
  - Barn Owl Memory
  - Internet References, if enabled by policy
- support user-private custom source entries such as Private Reference Source

### Phase 2: Adapter Framework

- define adapter protocol
- implement Barn Owl Memory adapter
- implement Private Reference Source adapter for the owner's registry entry
- implement public web/reference adapter
- normalize outputs into shared evidence records

### Phase 3: Orchestrated Enrichment

- add source selection logic
- enrich unresolved concepts through chosen adapters
- adjudicate over multi-source evidence
- persist/hold with explainable rationale

### Phase 4: Confidence and Learning Loop

- source usefulness metrics
- confidence reinforcement over repeated jobs
- conflict memory
- negative evidence feedback

### Phase 5: Extensibility for Other Users

- connector-backed source setup flows
- reusable authority profile presets
- user/workspace policy packs
- onboarding defaults that do not assume private internal systems

## Non-Goals

- treating every connector as equally authoritative
- writing durable private truth from weak internet-only evidence
- hardcoding Private Reference Source as a universal Barn Owl dependency
- hiding failed enrichment or auth-blocked sources
- requiring review for every high-confidence durable update

## Success Criteria

This architecture is working when:

- Settings shows the current user's enrichment sources clearly
- Private Reference Source appears for the owner and not for users who never configured it
- Barn Owl can add more source types without rewriting the durable knowledge
  model
- enrichment jobs explain which sources contributed to a durable decision
- automatic persistence becomes more accurate as Barn Owl learns which sources
  are useful for which entity kinds
- another Barn Owl user can benefit from the same architecture with a different
  source stack

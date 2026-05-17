# Barn Owl Autonomous Knowledge Architecture

Last updated: 2026-05-17

## Purpose

Barn Owl should become an automation-first meeting intelligence system that
improves with use. It should not behave like a passive recorder plus a review
queue. It should continuously learn durable knowledge, use that knowledge to
improve future capture, and coordinate bidirectionally with Codex through the
CLI and the Barn Owl Codex skill.

The strategic direction is:

> Barn Owl is the local meeting memory and application layer. Codex is the
> reasoning and enrichment layer. The CLI is the complete programmable control
> plane. The Codex skill is the workflow glue that makes the system intelligent
> in practice.

## Product Thesis

Barn Owl should automatically:

- attach trusted structured meeting context before and during capture
- improve transcripts using durable knowledge and meeting-specific hints
- reconcile transcript mistakes after capture using durable knowledge
- discover recurring people, companies, accounts, projects, products, events,
  functions, and glossary terms
- enrich ambiguous terms through Codex using Barn Owl memory, user context,
  internal reference context, and external reference information when allowed
- write the resulting structured knowledge back into Barn Owl
- reuse that knowledge in future meetings without forcing the user through
  recurring approval chores

Human review remains available, but it is not the primary operating mode.
Automation should be the default. Inspection, correction, undo, and policy
controls should always remain available.

## Design Principles

### 1. Automation first, review optional

Barn Owl should act automatically when confidence is strong enough. Review
surfaces should summarize recent learning, conflicts, and reversible actions,
not block normal intelligence work.

### 2. Structured knowledge beats context blobs

High-confidence Codex and CLI imports should be attached as structured meeting
assignments, not shown as anonymous "imported suggestions." A structured import
may include:

- title
- meeting type
- participants
- organizations
- customer accounts
- products
- projects
- events
- glossary terms
- rationale
- confidence
- provenance

Freeform text can still exist, but it should be treated as note context, not as
an equivalent substitute for structured knowledge.

### 3. Recurrence proves salience, not meaning

If `Rosalind` appears in fifteen transcripts, Barn Owl should become highly
confident that `Rosalind` matters. It should not become equally confident that
`Rosalind` is a project, product, account, or person without corroboration.

The knowledge system must separate:

- existence confidence: this concept recurs and matters
- semantic confidence: what kind of thing it is
- meeting-link confidence: whether it belongs to this meeting

### 4. Every automatic mutation must be explainable and reversible

The system may act without review, but it should retain:

- actor/source attribution
- evidence
- confidence
- before/after history where relevant
- undo or restore path for user-visible meeting mutations

### 5. Codex should enrich Barn Owl; Barn Owl should brief Codex

Barn Owl should expose unresolved concepts, evidence, relevant meetings, and
existing Context Library entries. Codex should resolve, reconcile, and update
Barn Owl through the CLI. This must be a real two-way loop.

## Core System Roles

### Barn Owl

Barn Owl owns:

- meeting capture lifecycle
- transcript persistence
- generated notes and summaries
- meeting facts
- local durable Context Library
- review/audit presentation
- confidence-bearing knowledge storage
- history and rollback

### Codex

Codex owns:

- enrichment reasoning
- cross-meeting synthesis
- contextual classification
- external/internal reference lookups when permitted
- structured import generation
- ambiguous entity reconciliation
- periodic maintenance workflows over Barn Owl knowledge

### CLI

The CLI is the full control surface for:

- reading meeting state and knowledge state
- creating and updating durable knowledge
- assigning structured meeting context
- inspecting evidence and uncertainty
- reconciling entities
- driving automated enrichment jobs

### Barn Owl Codex Skill

The skill should codify best practices for:

- starting capture immediately when requested
- fetching relevant Barn Owl context before enrichment
- attaching structured meeting assignments rather than text blobs
- reconciling unresolved durable knowledge
- using the CLI for all authoritative Barn Owl writes
- preserving privacy and source attribution

## Durable Knowledge Model

The Context Library should support first-class entity types:

- person
- organization
- customer account
- internal function
- product
- project
- event
- glossary term

Possible future extension:

- team
- initiative, if `project` becomes overloaded

Each durable entity should support:

- canonical name
- aliases
- entity kind
- confidence
- confirmed/unconfirmed state
- first seen and last seen timestamps
- distinct meeting count
- evidence count
- positive evidence sources
- negative feedback count
- optional description or reference summary
- optional external identifiers when available and safe

## Evidence Model

Evidence should be stored separately from the entity itself. Useful evidence
examples:

- transcript mention
- meeting title mention
- calendar match
- structured Codex import
- structured CLI import
- Context Library reuse
- explicit user edit
- manual Settings edit
- external/internal reference confirmation

Each evidence record should preserve:

- entity id
- source
- observed value
- meeting id when applicable
- timestamp
- confidence contribution
- compact metadata

Negative feedback should remain first-class:

- rejected alias
- rejected entity-kind inference
- ignored candidate
- undone auto-update

Negative evidence should suppress repeated bad automation.

## Confidence Policy

The system should not rely on one flat confidence number. It should maintain or
derive several confidence dimensions.

### Salience confidence

How likely is it that this concept matters enough to remember?

Signals:

- appears in multiple distinct meetings
- appears in meeting titles
- appears in notes or summaries
- appears in structured imports

### Semantic confidence

How likely is it that this concept is correctly typed and canonicalized?

Signals:

- explicit structured Codex/CLI assignment
- calendar/title alignment
- nearby phrases such as launch, roadmap, account, candidate, interview
- repeated usage with the same semantic role
- user confirmation

### Alias confidence

How likely is one observed surface form to map to the canonical entity?

Signals:

- repeated co-occurrence
- near-match spelling
- calendar attendee alignment
- accepted correction history

### Meeting-link confidence

How likely is this entity relevant to a specific meeting?

Signals:

- local transcript frequency
- calendar event title or attendee overlap
- explicit imported assignment
- note/title generation references

## Automation Policy

### Auto-apply by default

The system should automatically:

- reuse confirmed entities and aliases
- attach high-confidence structured Codex/CLI imports
- attach high-confidence matched calendar context
- increase confidence when new corroborating evidence arrives
- add durable evidence records
- link entities to meetings
- improve transcript hints with confirmed and high-confidence knowledge
- use durable context in title generation, summary generation, and search

### Auto-apply with audit trail

The system may automatically:

- create a new durable entity when salience is high and semantic confidence is
  strong enough
- add an alias when the mapping is strongly supported
- classify a recurring concept when Codex corroborates it with strong reference
  information
- update meeting facts from trusted structured imports

These actions should appear in a passive "recent knowledge updates" audit area.

### Usually do not auto-apply

The system should avoid silent automation for:

- destructive deletes
- broad entity merges
- splitting previously merged entities
- highly ambiguous semantic reclassification
- weak internet-only claims without corroboration

These can still be generated automatically as optional review suggestions.

## Transcript Intelligence Flywheel

Durable knowledge should improve transcripts both before and after capture.

### Before and during transcription

Use durable knowledge to produce transcription hints for:

- participant names
- customer and company names
- product and project names
- recurring event names
- glossary terms
- common aliases

Hints should guide recognition without forcing hallucinated insertion.

### After transcription

Use Barn Owl + Codex reconciliation to correct likely transcription mistakes:

- `Roslyn` -> `Rosalind`
- `Colin` -> `Collin`
- misheard company names
- malformed product names
- acronym expansions

The correction path should update:

- meeting facts
- notes and summaries when warranted
- evidence history
- future hints

This creates a loop:

1. durable knowledge improves transcript quality
2. better transcripts create better evidence
3. Codex reconciles ambiguity
4. Barn Owl stores stronger durable knowledge
5. future transcripts improve again

## Bidirectional Barn Owl <-> Codex Loop

### Barn Owl should provide to Codex

- unresolved recurring concepts
- low-confidence or conflicting entity classifications
- entity evidence trails
- meetings and snippets associated with an entity
- current Context Library entries
- meeting-specific context gaps
- knowledge updates applied recently

### Codex should return to Barn Owl

- durable entity creates and updates
- aliases and canonicalizations
- entity-kind assignments
- structured meeting assignments
- rationale and evidence summaries
- confidence updates
- audit-friendly provenance

### Example: Rosalind

1. Barn Owl detects `Rosalind` in many meetings.
2. Barn Owl exposes the recurrence, relevant meetings, and current uncertainty.
3. Codex compares:
   - meeting snippets
   - titles
   - existing durable knowledge
   - user/internal reference context
   - internet/reference context when appropriate
4. Codex returns a structured update such as:
   - kind: project
   - canonical name: Rosalind
   - aliases: Project Rosalind
   - confidence: high
   - rationale: repeated launch/pricing/GTM references with matching internal
     context
5. Barn Owl stores the durable entity, links prior/future meetings, and uses
   Rosalind in transcription hints and title generation.

The same loop should work for people, companies, products, projects, events,
accounts, and internal functions.

## Structured Import Policy

High-confidence Codex/CLI imports should behave like strong matched context, not
like review-only suggestions.

### Structured import fields

A structured import may provide:

- title
- meeting type
- participants
- organizations
- accounts
- products
- projects
- events
- glossary entries
- evidence/rationale
- confidence
- source identity

### Apply behavior

When confidence is strong enough:

- assign into current meeting facts
- persist as accepted structured context
- use during note generation
- use during transcription hints when applicable
- link imported entities to durable knowledge where possible

If the import is weak or ambiguous:

- retain it as optional reviewable input
- do not downgrade the rest of the system into manual approval mode

## CLI Requirements

The CLI should completely manage the Context Library and automated enrichment
loop.

### Required Context Library commands

- list
- get
- search
- create
- update
- delete
- confirm
- unconfirm
- alias add
- alias remove
- evidence add
- evidence list
- meeting links list
- merge
- split or detach where feasible

### Required knowledge workflow commands

- unresolved concepts
- recurring concepts
- inspect entity
- suggest updates
- reconcile
- run enrichment
- audit recent changes
- policy get/set

### Required structured meeting commands

- assign title
- assign meeting type
- assign participants
- assign entities by kind
- attach imported evidence
- fetch applied structured context

The CLI should be safe to use directly by a human and predictable enough for
Codex automation.

## User-Facing Surfaces

### Default experience

The default UX should show better outcomes, not more queues:

- better titles
- better transcripts
- more accurate participants
- better summaries
- stronger continuity across meetings

### Optional oversight surfaces

Barn Owl should expose:

- recent knowledge updates
- unresolved concepts
- notable automatic changes
- confidence/evidence inspection
- undo or restore where applicable
- full Context Library management in Settings

These are for transparency and correction, not routine gating.

## Privacy and Trust

The automation system should:

- avoid secrets and credentials in meeting context
- prefer compact factual context over raw dumps
- preserve source labels
- make internet or connector-derived knowledge attributable
- keep local durable knowledge editable and deletable
- expose review history for consequential automated updates
- avoid silently treating weak external claims as durable truth

## Suggested Implementation Phases

### Phase 1: Architecture correction

- add `event` entity kind
- formalize structured imported meeting context
- separate freeform note context from structured assignments
- align high-confidence Codex/CLI imports with calendar-style accepted context

### Phase 2: CLI control plane completion

- expand Context Library CRUD into full lifecycle management
- add inspect/evidence/alias/confirm/merge capabilities
- expose unresolved and recurring knowledge queries

### Phase 3: Codex enrichment loop

- update the Barn Owl skill
- add workflows for recurring concept resolution
- teach Codex to read Barn Owl memory before writing updates
- write structured durable knowledge and meeting assignments back through CLI

### Phase 4: Transcript intelligence loop

- feed durable knowledge into realtime hint generation
- post-process likely entity transcription errors
- reinforce the Context Library from corrected outputs

### Phase 5: Automation and audit polish

- automation policy controls
- passive recent-updates audit
- conflict surfacing
- reversible changes and diagnostics

## Non-Goals

- Building a generic enterprise knowledge graph unrelated to meetings
- Treating every web mention as valid durable knowledge
- Requiring users to manually approve ordinary high-confidence learning
- Replacing Codex reasoning with brittle local heuristics where richer context is
  needed

## Definition of Success

The architecture is working when:

- Barn Owl and Codex exchange structured knowledge bidirectionally
- the CLI can fully manage durable knowledge without GUI dependency
- trusted structured imports are applied automatically
- transcripts measurably improve from durable knowledge reuse
- recurring concepts converge toward stable, reusable entities
- users can inspect and correct the system, but do not need to babysit it

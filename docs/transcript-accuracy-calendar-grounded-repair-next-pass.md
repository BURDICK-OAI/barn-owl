# Transcript Accuracy: Calendar-Grounded Repair Next Pass

Last updated: 2026-05-18

## Purpose

This document extends:

`/Users/burdick/Documents/Codex/Barn Owl/local-dev-notes/transcript-accuracy-durability-architecture.md`

It captures the next implementation pass required after the initial transcript
accuracy and durability work. The specific gap exposed on 2026-05-18 is:

> Barn Owl can improve regenerated summary text when Codex attaches calendar
> details as external context, but the durable facts layer still lacks a
> first-class, trustworthy calendar repair path and can therefore remain wrong.

The next pass should make Calendar evidence a structured part of Barn Owl's
durability loop without making Calendar the automatic truth in ambiguous or
ad hoc recordings.

## Current Findings From the Local Corpus

The 2026-05-18 investigation of the owner's local corpus found:

- `11` recorded meetings in Barn Owl
- `0` persisted `meeting_calendar_context` rows before manual inspection
- confident calendar matches for `10` of the `11` recordings
- no credible bounded calendar match for:
  - `Casimir Space: Quantum Vacuum Energy Harvesting Roadmap`

Calendar matching materially improved understanding of the corpus:

- `Moderna: Stephane CEO and CIOs meeting`
  - matched `OpenAI <> Moderna`
  - Tuesday, May 12, 2026, `11:00-11:30 AM PT`
  - invitees included Stephane Bancel, Adrian Stone, Suresh Nulu,
    Edward Miracco, Wade Davis, and Collin Burdick
- `Werner: Brief Check-In`
  - matched `OpenAI | SutroBio`
  - the event attendee `wrubas@sutrobio.com` aligned with the transcript's
    opening `Hey, Werner`
- `Terron:Collin 1:1`
  - matched `CB<>TB`
  - confirmed Terron Bruner and Collin Burdick

The first canary repair was the Moderna CEO meeting:

1. Codex attached a concise calendar-derived external context item.
2. `barnowl summaries retry --session ...` regenerated a materially better
   summary.
3. `barnowl repair-durability` recomputed facts and resynchronized artifacts.

The regenerated summary became accurate and useful. However, the repaired
Meeting Facts still degraded to:

```text
Organizations: Rosalind
```

instead of reflecting the stronger invite-backed Moderna context.

That is the implementation gap this document addresses.

## Product Conclusion

Calendar should be:

- **high-trust when accepted or uniquely matched**
- **candidate evidence when ambiguous**
- **absent when no plausible match exists**

Calendar should not be:

- blindly attached because time overlaps
- fabricated for ad hoc recordings
- allowed to silently override explicit user edits
- forced into Barn Owl as generic prose when structured data is available

The product rule is:

> User confirmation and accepted operational metadata outrank durable knowledge;
> durable knowledge outranks transcript inference; ambiguous metadata remains
> reviewable evidence, not silent truth.

## Required Product Behavior

### 1. Recordings With One Clear Calendar Match

When one event is clearly superior, Barn Owl may auto-accept it as meeting-level
operational context if policy allows.

Signals may include:

- recording start overlaps the event window
- overlap length is strong enough to matter
- event title resembles an existing or inferred meeting title
- event attendees appear in transcript, durable knowledge, or account context
- location or meeting provider lines up
- event includes a strong customer, company, or account cue
- event acceptance status suggests the user intended to attend

Accepted Calendar context may influence:

- summary generation
- title suggestion
- participant extraction
- customer / organization selection
- repair and regeneration

### 2. Recordings With Multiple Plausible Calendar Matches

If two or more events are plausible and no event is clearly ahead, Barn Owl must
not silently select one.

Examples:

- overlapping customer meeting and internal hold
- two accepted calendar events in the same window
- conference travel block plus a real customer event

Required behavior:

- persist or expose multiple `candidate` matches
- show the strongest candidates in a reviewable form
- use none of them as authoritative repair evidence until one is accepted
- preserve scoring reasons so the system is inspectable

### 3. Recordings With No Calendar Match

If no credible event exists, Barn Owl should continue normally.

Examples:

- hallway conversation
- ad hoc voice memo
- unscheduled customer side discussion
- casual internal conversation

Required behavior:

- no fake calendar event
- no degraded fallback title from absence of calendar
- no pressure to attach calendar context
- summary and facts fall back to:
  1. user-confirmed edits
  2. accepted external context
  3. curated durable knowledge
  4. transcript inference

### 4. Historical Repair

Historical repair must operate against the same trust rules as future recording
flows.

For each existing meeting:

1. search a bounded Calendar window around the recording time
2. score candidate events
3. persist accepted context only when the selection is uniquely defensible or
   already user-confirmed
4. keep ambiguous candidates out of canonical repair until reviewed
5. rerun summary generation and durability repair after accepted context is in
   place
6. verify synchronized output across database, Library artifact, Markdown note,
   and local Context mirror

## Architecture Direction

### A. Persist Calendar Repair State, Not Just Calendar Payload

Barn Owl already has `meeting_calendar_context`, but the next pass needs an
explicit repair-grade state model.

Recommended conceptual states:

```text
none
candidate
accepted
rejected
```

Recommended metadata to preserve:

- calendar event id
- event title
- start / end
- attendees
- organizer if available
- location
- description / notes pointer or bounded snippet if policy allows
- match confidence
- match reason
- selection state
- whether the match was automatic or user-confirmed
- created / updated timestamps

The exact storage shape can either:

- extend the existing `meeting_calendar_context` model, or
- add a candidate table plus one accepted canonical row

The important product requirement is not the table shape. It is that Barn Owl can
distinguish:

- "we found something"
- "we trust this enough to use it"
- "we found candidates but refuse to guess"

### B. Expose a Structured Calendar Attach / Repair Surface

The next pass needs a control-plane and Codex-operable path that persists Calendar
context as Calendar context, not as generic `external_context_items`.

Recommended capabilities:

- attach an accepted Calendar match to an existing meeting
- attach one or more Calendar candidates without accepting them
- reject a candidate
- inspect current Calendar match state for a meeting
- support historical/batch repair orchestration

Illustrative command shapes, not committed API:

```bash
barnowl calendar-context attach --session <uuid> --event-json <payload>
barnowl calendar-context candidates --session <uuid>
barnowl calendar-context accept --session <uuid> --candidate <id>
barnowl calendar-context reject --session <uuid> --candidate <id>
```

An implementation may choose different command names. The durable capability is
what matters.

### C. Feed Typed Trusted Evidence Into Fact Extraction

`MeetingFactsExtractor` should stop receiving all evidence as an undifferentiated
string blob.

The next pass should introduce a typed evidence input, or an equivalent internal
representation, that can distinguish:

- explicit user context
- accepted Calendar context
- curated Context Library knowledge
- high-confidence enrichment evidence
- transcript-derived candidates

Illustrative shape:

```swift
struct MeetingFactEvidence {
    var userContext: [FactEvidenceLine]
    var acceptedCalendarContext: CalendarMeetingContext?
    var durableKnowledge: [DurableEntityMatch]
    var enrichmentEvidence: [EnrichmentFactMatch]
    var transcript: String
}
```

The final implementation does not need to match this exact type, but it must
support precedence-aware extraction without reverse-parsing prose.

### D. Tighten Candidate Precedence

The current extractor merges organizations and customers from context and
transcript. That is insufficient when the two disagree.

Required precedence:

1. explicit user edits
2. accepted Calendar metadata
3. accepted external context
4. curated durable knowledge
5. high-confidence enrichment
6. final transcript inference
7. realtime preview inference

Concrete rules:

- if accepted Calendar context identifies `Moderna`, a weak transcript-only
  organization guess like `Rosalind` cannot become the sole organization
- if durable knowledge says `Rosalind` normalizes to project `GPT-Rosalind`, it
  must not be reclassified as an organization without stronger evidence
- transcript-only organizations should be supplemental, not substitutive, when
  stronger customer/account evidence exists
- customers should require explicit customer/account shape or direct stronger
  metadata, not merely a mentioned organization

### E. Make Durability Repair Consume Calendar Evidence

`durabilityRepairFacts(from:)` currently rebuilds from:

- transcript text
- accepted external context items
- stale existing facts as a repair seed

It must also consume accepted Calendar context for the same meeting.

This is non-negotiable for historical repair. Otherwise Barn Owl's repair path is
weaker than its forward-processing path, which is exactly the inconsistency we
just observed.

### F. Keep Summary Repair and Facts Repair Coherent

Today:

- `summaries retry` regenerates summary text
- `repair-durability` recomputes facts and resynchronizes artifacts

Those remain useful distinct mechanisms, but the product workflow needs a
coherent repair contract:

1. attach or accept trusted metadata first
2. regenerate summary text
3. recompute durable facts from the same trust inputs
4. rerender canonical Markdown
5. synchronize stored Library artifact and local Context mirror

This may be implemented as:

- a single orchestration command, or
- a documented and internally reusable composed repair flow

Do not make operators or Codex improvise the ordering.

## Match Scoring Direction

The Calendar matcher should be conservative and explainable.

Suggested evidence dimensions:

| Signal | Use |
| --- | --- |
| Start-time overlap | basic eligibility |
| Duration overlap | confidence boost |
| Accepted attendance | intent boost |
| Title similarity | relevance boost |
| Transcript attendee match | relevance boost |
| Durable company/project match | relevance boost |
| Location / meeting provider | mild confirmation |
| Broad all-day / travel / hotel block | strong demotion |
| Declined event | demotion |

Recommended policy:

- one strong winner above a margin: auto-accept if allowed
- multiple close candidates: candidate state only
- weak calendar-only proximity: do not accept
- all-day travel/hotel/admin blocks: do not beat a real meeting event

## Design Examples

### Example 1: Clear Customer Match

Recording:

```text
Moderna: Stephane CEO and CIOs meeting
Started: May 12, 2026 at 11:06 AM PT
```

Calendar:

```text
OpenAI <> Moderna
11:00-11:30 AM PT
Attendees: Stephane Bancel, Adrian Stone, Suresh Nulu, ...
```

Expected:

- accepted Calendar context
- `Moderna` available as strong organization / customer-account evidence
- invitees available as strong participant candidates
- `Rosalind` may survive as `GPT-Rosalind` project evidence, not organization

### Example 2: Ambiguous Overlap

Calendar:

```text
OpenAI <> Moderna
Admin Hold
```

Both overlap the recording start.

Expected:

- no automatic fact influence
- candidate list retained with scores and reasons
- user or high-confidence downstream signal must accept one

### Example 3: Random Conversation

Recording:

```text
unscheduled hallway discussion after a customer visit
```

Calendar:

```text
no credible event nearby
```

Expected:

- no Calendar match
- transcript/context/durable knowledge still work
- no fabricated operational metadata

## Build Direction

### Phase 1: Structured Calendar Persistence

Implement:

- calendar candidate / accepted / rejected state
- control-plane surface for historical repair and Codex-assisted attachment
- persistence round-trip tests
- non-duplication rules for repeated repair attempts

### Phase 2: Trust-Aware Fact Extraction

Implement:

- typed evidence handoff into `MeetingFactsExtractor`
- Calendar-aware participant and organization/customer extraction
- candidate suppression when stronger evidence conflicts
- `Rosalind -> GPT-Rosalind` project normalization kept out of organization slots

### Phase 3: Repair Orchestration

Implement:

- repair flow that uses accepted Calendar context
- summary regeneration and facts regeneration ordered consistently
- canonical synchronization across:
  - meeting record
  - meeting facts JSON
  - Markdown output
  - Library artifact
  - local Context mirror

### Phase 4: Corpus Backfill

After product code is fixed:

1. run bounded Calendar matching across all historical recordings
2. auto-accept only confident unique matches
3. flag ambiguous meetings for review rather than force them
4. rerun repair against accepted matches
5. verify the repaired corpus deterministically

## Required Test and Eval Plan

### Core Tests

- accepted Calendar context outranks transcript-only organization inference
- Moderna CEO regression:
  - accepted event `OpenAI <> Moderna`
  - facts must preserve `Moderna`
  - `Rosalind` must not become an organization
  - `GPT-Rosalind` may remain a project where supported
- BMS and Pfizer regressions preserve correct account/customer grounding
- no Calendar match leaves facts sparse instead of fabricated
- ambiguous overlapping Calendar candidates are not promoted to accepted truth

### Persistence Tests

- calendar candidate / accepted / rejected states round-trip
- repeat repair does not duplicate accepted Calendar context
- rejected candidates do not influence regenerated facts
- accepted Calendar metadata survives reload and historical repair

### Notes / Rendering Tests

- accepted Calendar repair updates rendered Markdown facts coherently
- title, facts metadata, rendered note, Library artifact, and local Context mirror
  remain synchronized
- accepted context does not duplicate itself in generated note output

### App / Control Tests

- control surface can attach accepted Calendar context to an existing meeting
- control surface can expose candidate choices without accepting them
- repair workflow consumes accepted Calendar context and regenerates coherently
- summary repair and durability repair compose correctly

### Corpus Eval

Run against the known local corpus after implementation.

At minimum verify:

- `Moderna: Stephane CEO and CIOs meeting`
- `Moderna: Partnership Meeting`
- `Takeda OpenAI Partnership`
- `Takeda: Rosalind Feedback`
- `BMS: GPT Rosalind Beta Feedback and Q&A`
- `Pfizer: OpenAI Findability and Ads Roadmap`
- `Pfizer: Marketing Tech Leadership`
- `Werner: Brief Check-In`
- `Terron:Collin 1:1`

For the `Casimir Space` recording:

- no Calendar context should be invented
- repair should leave Calendar state empty unless later evidence says otherwise

## Readiness Eval for the Next Pass

Score the next pass ready only when all are true:

1. Calendar evidence is persisted and queryable as structured meeting metadata,
   not only as freeform Codex context.
2. Multiple overlapping event scenarios preserve ambiguity instead of silently
   selecting an arbitrary event.
3. No-match recordings remain fully supported without invented Calendar truth.
4. Accepted Calendar context participates in both summary repair and durability
   facts repair.
5. Accepted Calendar organization / attendee evidence outranks weaker transcript
   inference in tested regressions.
6. The Moderna CEO repair no longer yields `Organizations: Rosalind` and instead
   preserves the correct meeting-level Moderna grounding.
7. Durable project normalization prevents `Rosalind` from leaking into the wrong
   fact category when `GPT-Rosalind` is the trusted canonical entity.
8. Repair orchestration keeps database state, rendered Markdown, Library artifact,
   and local Context mirror synchronized.
9. The repaired local corpus is rerun and verified after the code change, with
   ambiguous or unmatched cases documented rather than forced.
10. Focused automated tests cover core, persistence, notes, and app/control
    behavior for the real failure classes above.

## Non-Goals

- changing audio capture
- reworking diarization
- treating every Calendar overlap as truth
- requiring Calendar for ad hoc recording
- broad UI redesign
- replacing the existing summary architecture

## Recommendation

Treat this as the next product pass before any broad historical summary rerun is
declared accurate. The summary can already be made better; the durable knowledge
loop is not yet trustworthy enough to certify the corpus without the Calendar
repair architecture described here.

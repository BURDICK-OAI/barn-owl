---
name: barnowl
description: Control and query the local Barn Owl macOS app from Codex. Use when the user asks to record or stop a meeting, attach context, rename/type/update notes, wait for processing, retry jobs, retrieve notes/transcripts/actions/context, or ask questions over Barn Owl meeting memory.
metadata:
  short-description: Control Barn Owl meeting capture
---

# Barn Owl

Use Barn Owl through the bundled CLI as the primary interface. The macOS UI is only needed for first-run setup, permissions, OpenAI API key entry, bridge checks, and occasional manual review.

Run `scripts/barnowl` from this skill folder, or `barnowl` if it is on PATH. The wrapper resolves the CLI in this order: `BARNOWL_CLI`, `~/bin/barnowl`, `/Applications/Barn Owl.app/Contents/MacOS/barnowl`, then the local development repo.

## Codex-First Recording Workflow

When the user asks to record a meeting, start immediately. Do not wait for calendar, Slack, email, files, or clarification unless the user explicitly says not to start yet.

1. Start recording:

```bash
barnowl start --title "Meeting" --source codex
```

2. Capture `sessionID` or `meetingID` from the JSON response.
3. Prefer structured assignments when Codex knows the meeting shape:

```bash
barnowl meeting import-context <meeting-id> \
  --source codex \
  --confidence 0.95 \
  --title "Moderna: Rosalind Pricing" \
  --type "Customer Review" \
  --participant "Collin Burdick" \
  --customer "Moderna" \
  --project "Rosalind"
```

Trusted high-confidence structured imports are applied automatically to the meeting and remain inspectable in Barn Owl history/context surfaces. Use this path for participants, organizations, customer accounts, projects, glossary terms, titles, meeting types, goals, and concise imported context.

4. Use freeform context only when the input is not yet cleanly structured:

```bash
barnowl context add --session <uuid> --source codex --confidence 0.95 "Relevant context, summarized as facts."
```

Use `--confidence` for machine-supplied context. High-confidence Codex/Barn Owl context can be applied immediately; medium- and low-confidence context is queued for review.

5. Stop only when the user asks. Prefer the review-aware flow so Codex returns the same post-meeting transcript suggestions the app shows:

```bash
barnowl stop --wait-review --timeout 10m
```

If you used plain `barnowl stop`, wait for review explicitly:

```bash
barnowl wait --session <uuid> --until review --timeout 10m
```

Summarize the returned `contextReview` prompts and Context Library suggestions, then ask for a decision before applying edits. Use `barnowl meeting context-review accept-suggestion <meeting-id> <suggestion-id>` or `ignore-suggestion` when the user approves or rejects a reusable mapping. Use `barnowl meeting context-review apply <meeting-id> --context "..."` only when the user approves the reviewed suggestions, or `dismiss` when they say to leave them for later.

6. Wait for final processing before retrieving final notes:

```bash
barnowl wait --session <uuid> --until complete --timeout 10m
```

Use `--latest` only when you did not capture the session id:

```bash
barnowl wait --latest --until complete --timeout 10m
```

7. Fetch final notes as Markdown:

```bash
barnowl meeting notes <meeting-id> --format markdown
```

8. If processing failed, recover without opening the UI:

```bash
barnowl jobs list --session <uuid>
barnowl jobs retry --session <uuid>
barnowl wait --session <uuid> --until complete --timeout 10m
```

## Durable Knowledge Enrichment Workflow

When Barn Owl surfaces recurring or unresolved concepts, gather the enrichment packet before deciding what to persist:

```bash
barnowl knowledge unresolved --format json
barnowl knowledge brief "Rosalind" --format json
barnowl knowledge enrich "Rosalind" --format json
```

The brief includes recurrence confidence, semantic confidence, related meetings,
transcript excerpts, and matching Context Library entries. Use that packet as the
local Barn Owl evidence base, then add permitted user/internal/reference
research when it materially improves classification. Write durable structured
knowledge back through the CLI, not as prose:

```bash
barnowl context-library reconcile \
  --type project \
  --name "Rosalind" \
  --observed "Rosalind" \
  --source codex \
  --confidence 0.97 \
  --role project \
  --confirmed
```

Use `--confirmed` only when the evidence supports a durable canonical mapping.
The reconcile path backfills matching meeting links and evidence so one resolved
concept improves future transcription, notes, and retrieval work.

Barn Owl also auto-reconciles highly recurrent, semantically consistent concepts
after completed processing. Use the explicit maintenance command when you want
to force a pass from Codex:

```bash
barnowl knowledge auto-reconcile --limit 20
```

Use `barnowl knowledge enrich "<concept>" --format json` when the concept is
recurrent but its type or canonical meaning is not yet defensible from local
heuristics alone. Barn Owl sends the enrichment brief through its structured
resolver, persists the result only above the automatic confidence threshold, and
otherwise leaves the concept unresolved for later evidence instead of forcing a
bad durable mapping.

## Commands

- Status: `barnowl status`
- Status checklist: `barnowl status --format markdown`
- Permissions check: `barnowl permissions check`
- Permissions local capture test: `barnowl permissions test`
- Current meeting: `barnowl current`
- Start: `barnowl start --title "Meeting" --type "Team Meeting" --context "..."`
- Stop: `barnowl stop`
- Stop and return transcript suggestions: `barnowl stop --wait-review --timeout 10m`
- Wait: `barnowl wait --session <uuid> --until complete --timeout 10m`
- Wait for notes: `barnowl wait --latest --until notes --timeout 10m`
- Wait for transcript suggestions: `barnowl wait --session <uuid> --until review --timeout 10m`
- Wait for stopped: `barnowl wait --session <uuid> --until stopped --timeout 2m`
- Add context: `barnowl context add --session <uuid> --source codex --confidence 0.95 "..."`
- Replace context: `barnowl context set --session <uuid> --source codex --confidence 0.95 "..."`
- List incoming context items: `barnowl context list --session <uuid>`
- Accept context: `barnowl context accept <context-id>`
- Ignore context: `barnowl context ignore <context-id>`
- Delete context: `barnowl context delete <context-id>`
- List Context Library entries: `barnowl context-library list --type person --query "Collin"`
- Recurring concepts: `barnowl knowledge recurring --limit 20`
- Unresolved concepts: `barnowl knowledge unresolved --limit 20`
- Enrichment packet: `barnowl knowledge brief "Rosalind" --format json`
- Resolver-backed enrichment: `barnowl knowledge enrich "Rosalind" --format json`
- Auto-reconcile strong recurring concepts: `barnowl knowledge auto-reconcile --limit 20`
- Add Context Library entry: `barnowl context-library add --type person --name "Collin Burdick" --alias "Colin Burdick"`
- Update Context Library entry: `barnowl context-library update <entry-id> --name "Collin S. Burdick" --clear-aliases`
- Delete Context Library entry: `barnowl context-library delete <entry-id> --yes`
- Rename: `barnowl title set --session <uuid> "Better title"`
- Set type: `barnowl type set --session <uuid> "Customer Workshop"`
- Update notes: `barnowl notes update --session <uuid> "Draft the follow-up"`
- Jobs: `barnowl jobs list`, `barnowl jobs retry --session <uuid>`, `barnowl jobs dismiss --job <uuid>`
- Recent meetings: `barnowl meetings recent --limit 10`
- Search meetings: `barnowl meetings search "acme pricing"`
- Meeting details: `barnowl meeting get <meeting-id>`
- Meeting transcript: `barnowl meeting transcript <meeting-id>`
- Meeting notes: `barnowl meeting notes <meeting-id> --format markdown`
- Meeting summary: `barnowl meeting summary <meeting-id>`
- Meeting context: `barnowl meeting context <meeting-id>`
- Structured meeting import: `barnowl meeting import-context <meeting-id> --source codex --confidence 0.95 --participant "Collin Burdick" --customer "Moderna" --project "Rosalind"`
- Meeting transcript suggestions: `barnowl meeting context-review <meeting-id>`
- Save correction for future meetings: `barnowl meeting context-review accept-suggestion <meeting-id> <suggestion-id>`
- Ignore Context Library suggestion: `barnowl meeting context-review ignore-suggestion <meeting-id> <suggestion-id>`
- Apply transcript suggestions: `barnowl meeting context-review apply <meeting-id> --context "..."`
- Dismiss transcript suggestions for now: `barnowl meeting context-review dismiss <meeting-id>`
- Meeting actions: `barnowl meeting actions <meeting-id>`
- Ask notes locally: `barnowl ask-notes --session <uuid> "What did we decide?"`
- Chat over meetings: `barnowl chat "What did we decide about Acme?"`
- Delete meeting: `barnowl meeting delete <meeting-id> --yes`
- Purge temp audio: `barnowl meeting purge-temp-audio <meeting-id> --yes`
- Developer diagnostics: `barnowl diagnostics export --output /tmp/BarnOwl-diagnostics.md`
- Draft error feedback: `barnowl feedback slack`
- Post confirmed error feedback: `barnowl feedback slack --yes`

All commands return JSON by default. Prefer JSON while deciding what to do next. Use `--format markdown` for final notes, transcripts, summaries, status checklists, and job reports.

If a CLI response includes `feedbackSuggested: true`, tell the user Barn Owl can draft a redacted Slack feedback report. Run `barnowl feedback slack` to review the draft. Only run `barnowl feedback slack --yes` after the user explicitly confirms posting. The command uses `BARNOWL_SLACK_FEEDBACK_WEBHOOK_URL`; do not paste or request Slack tokens in chat.

## Context Rules

- Attach concise, source-labeled facts. Prefer useful summaries over raw dumps.
- Never attach secrets, API keys, credentials, tokens, private keys, or passwords as meeting context.
- If a connector is unavailable or unauthorized, say it was unavailable and continue.
- Late context can be added after stop; use `notes update` if final notes need revision.

## Query Workflow

When the user asks about meeting memory:

1. Use `barnowl meetings search "<query>"` for topical/person/company/project lookup.
2. Use `barnowl meetings recent --limit N` for recency-based requests.
3. Retrieve exact artifacts with `barnowl meeting notes|transcript|summary|context|actions <meeting-id>`.
4. Use `barnowl ask-notes --session <uuid> "<question>"` for one meeting.
5. Use `barnowl chat "<question>"` for synthesis across meetings.
6. Cite meeting titles and ids when using Barn Owl memory.

For prompts like "find my last meeting with Alex," search first, then fetch the most relevant meeting before answering.

## Examples

Record now:

```bash
barnowl start --title "Codex planning" --source codex --confidence 0.95 --context "User asked to discuss Barn Owl control layer."
```

Stop, return transcript suggestions, then retrieve notes:

```bash
barnowl stop --wait-review --timeout 10m
barnowl meeting context-review <meeting-id>
barnowl wait --latest --until complete --timeout 10m
barnowl meeting notes <meeting-id> --format markdown
```

Recover failed processing:

```bash
barnowl jobs list --session <uuid> --format markdown
barnowl jobs retry --session <uuid>
barnowl wait --session <uuid> --until complete --timeout 10m
```

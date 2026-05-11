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
3. Attach context after recording starts:

```bash
barnowl context add --session <uuid> --source codex "Relevant context, summarized as facts."
```

4. Stop only when the user asks:

```bash
barnowl stop
```

5. Wait for final processing before retrieving final notes:

```bash
barnowl wait --session <uuid> --until complete --timeout 10m
```

Use `--latest` only when you did not capture the session id:

```bash
barnowl wait --latest --until complete --timeout 10m
```

6. Fetch final notes as Markdown:

```bash
barnowl meeting notes <meeting-id> --format markdown
```

7. If processing failed, recover without opening the UI:

```bash
barnowl jobs list --session <uuid>
barnowl jobs retry --session <uuid>
barnowl wait --session <uuid> --until complete --timeout 10m
```

## Commands

- Status: `barnowl status`
- Status checklist: `barnowl status --format markdown`
- Current meeting: `barnowl current`
- Start: `barnowl start --title "Meeting" --type "Team Meeting" --context "..."`
- Stop: `barnowl stop`
- Wait: `barnowl wait --session <uuid> --until complete --timeout 10m`
- Wait for notes: `barnowl wait --latest --until notes --timeout 10m`
- Wait for stopped: `barnowl wait --session <uuid> --until stopped --timeout 2m`
- Add context: `barnowl context add --session <uuid> --source codex "..."`
- Replace context: `barnowl context set --session <uuid> --source codex "..."`
- List context inbox: `barnowl context list --session <uuid>`
- Accept context: `barnowl context accept <context-id>`
- Ignore context: `barnowl context ignore <context-id>`
- Delete context: `barnowl context delete <context-id>`
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
- Meeting actions: `barnowl meeting actions <meeting-id>`
- Ask notes locally: `barnowl ask-notes --session <uuid> "What did we decide?"`
- Chat over meetings: `barnowl chat "What did we decide about Acme?"`
- Delete meeting: `barnowl meeting delete <meeting-id> --yes`
- Purge temp audio: `barnowl meeting purge-temp-audio <meeting-id> --yes`
- Developer diagnostics: `barnowl diagnostics export --output /tmp/BarnOwl-diagnostics.md`

All commands return JSON by default. Prefer JSON while deciding what to do next. Use `--format markdown` for final notes, transcripts, summaries, status checklists, and job reports.

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
barnowl start --title "Codex planning" --source codex --context "User asked to discuss Barn Owl control layer."
```

Stop and retrieve notes:

```bash
barnowl stop
barnowl wait --latest --until complete --timeout 10m
barnowl meeting notes <meeting-id> --format markdown
```

Recover failed processing:

```bash
barnowl jobs list --session <uuid> --format markdown
barnowl jobs retry --session <uuid>
barnowl wait --session <uuid> --until complete --timeout 10m
```

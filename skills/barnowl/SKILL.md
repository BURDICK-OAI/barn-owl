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

## Codex-Assisted Enrichment Sources

Barn Owl owns the enrichment registry, evidence jobs, adjudication, and durable
knowledge. Codex owns retrieval from authenticated private connectors and the
judgment about what meeting-specific context is worth hydrating into Barn Owl.
Do not imply Barn Owl directly signs into Google Drive, Slack, Notion, or
Salesforce on its own.

Use this flow when the user asks to set up, improve, or rely on enrichment
sources:

1. Inspect the registry and presets:

```bash
barnowl enrichment-sources list
barnowl enrichment-sources presets
```

2. If a supported connector-backed source is missing, configure it from the
matching preset:

```bash
barnowl enrichment-sources setup google_drive_reference --source-id google_drive_reference
barnowl enrichment-sources setup slack_reference --source-id slack_reference
barnowl enrichment-sources setup notion_reference --source-id notion_reference
barnowl enrichment-sources setup salesforce_reference --source-id salesforce_reference
```

3. Check source health:

```bash
barnowl enrichment-sources check google_drive_reference
```

Connector-backed presets may report that authenticated retrieval or hydration
is still needed. That means Codex should use the available connector/app tools,
summarize the relevant evidence, and then update Barn Owl with concise
configured reference payloads. Keep copies summary-or-pointer only; do not dump
raw documents, threads, or CRM records into Barn Owl.

4. Hydrate or refresh the configured source payload through Barn Owl's
upsert command after Codex retrieves relevant evidence:

```bash
barnowl enrichment-sources upsert google_drive_reference \
  --name "Google Drive Reference" \
  --type private_reference \
  --scope personal_private \
  --authority private_internal_reference \
  --connector-reference google-drive \
  --auth-state configured \
  --health-status ready \
  --privacy-copy-policy summary_or_pointer_only \
  --query-budget-policy connector_policy_controlled \
  --config-json '{"entries":[...]}'
```

Use the analogous connector reference and scope for Slack, Notion, and
Salesforce. Preserve existing useful entries when refreshing a source rather
than replacing them blindly.

5. When a high-value recurring person, account, project, product, or internal
term is ambiguous or newly important, run targeted enrichment:

```bash
barnowl knowledge enrich "<concept>"
```

Barn Owl may auto-persist strong candidates, hold ambiguous concepts for more
evidence, or preserve conflict memory. Treat those holds as policy working as
designed, not as failures to work around.

6. At meeting start, prefer just-in-time context over permanent clutter:
attach relevant connector-derived facts to the live session with
`barnowl context add`, and only extend durable enrichment payloads for concepts
that recur or are strategically worth stabilizing.

## Commands

- Status: `barnowl status`
- Status checklist: `barnowl status --format markdown`
- Permissions check: `barnowl permissions check`
- Permissions local capture test: `barnowl permissions test`
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
- Enrichment source registry: `barnowl enrichment-sources list`
- Enrichment source presets: `barnowl enrichment-sources presets`
- Enrichment source setup: `barnowl enrichment-sources setup google_drive_reference --source-id google_drive_reference`
- Enrichment source health: `barnowl enrichment-sources check google_drive_reference`
- Targeted durable enrichment: `barnowl knowledge enrich "<concept>"`
- Draft error feedback: `barnowl feedback slack`
- Post confirmed error feedback: `barnowl feedback slack --yes`

All commands return JSON by default. Prefer JSON while deciding what to do next. Use `--format markdown` for final notes, transcripts, summaries, status checklists, and job reports.

If a CLI response includes `feedbackSuggested: true`, tell the user Barn Owl can draft a redacted Slack feedback report. Run `barnowl feedback slack` to review the draft. Only run `barnowl feedback slack --yes` after the user explicitly confirms posting. The command uses `BARNOWL_SLACK_FEEDBACK_WEBHOOK_URL`; do not paste or request Slack tokens in chat.

## Context Rules

- Attach concise, source-labeled facts. Prefer useful summaries over raw dumps.
- Never attach secrets, API keys, credentials, tokens, private keys, or passwords as meeting context.
- If a connector is unavailable or unauthorized, say it was unavailable and continue.
- For private connectors, keep Barn Owl source payloads concise, normalized, and pointer-heavy rather than copying raw source material.
- Use durable enrichment for recurring people/accounts/projects/products/terms; use live meeting context for situational attendees and one-off detail.
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

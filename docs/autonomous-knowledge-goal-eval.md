# Autonomous Knowledge Goal and Readiness Eval

## Codex Goal

Design and implement Barn Owl as an automation-first, bidirectional knowledge
system with Codex and the CLI. Barn Owl must maintain durable structured
knowledge for people, organizations, customer accounts, products, projects,
events, internal functions, and glossary terms; automatically apply trusted
structured Codex/CLI imports like strong calendar context; expose a complete CLI
control plane for Context Library lifecycle management; let Codex read Barn Owl
memory, enrich ambiguous concepts with available user/internal/reference
context, and write back structured updates; and use durable knowledge to improve
meeting assignment, realtime transcription hints, post-transcript correction,
note generation, search, and future captures. Human review must remain
available, but normal high-confidence learning and reuse should not depend on
manual approval.

## Readiness Eval

Score ready only when all are true:

1. **Knowledge model**: durable entities support all target kinds, canonical
   names, aliases, confidence, evidence, confirmation state, and meeting links.
2. **Automation path**: high-confidence structured Codex/CLI imports attach to
   meetings automatically and influence downstream processing without review.
3. **Bidirectional loop**: Barn Owl can expose unresolved/recurring concepts and
   evidence; Codex can resolve them and persist structured updates back through
   CLI commands.
4. **CLI completeness**: the CLI can list, get, search, create, update, delete,
   confirm, unconfirm, manage aliases, inspect/add evidence, inspect links, and
   reconcile knowledge without GUI-only gaps.
5. **Transcript flywheel**: durable knowledge affects realtime hints and at least
   one post-transcript correction/reconciliation path, with tests proving reuse.
6. **Automation safety**: automatic writes retain provenance, confidence, and
   reversible or inspectable history; destructive merges/deletes are not silent.
7. **User experience**: review surfaces are optional audit/correction tools, not
   routine blockers for normal high-confidence learning.
8. **Verification**: tests cover structured import application, Context Library
   lifecycle operations, Codex/CLI write-back, recurring-term resolution, and a
   transcript-quality improvement case driven by durable knowledge.

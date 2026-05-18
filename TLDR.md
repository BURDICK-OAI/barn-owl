# Barn Owl Repository Boundary TLDR

- Keep product docs, architecture, QA, and release guidance in `docs/`.
- Keep private development briefs, corpus investigations, rollout notes, and meeting-derived process writeups in ignored `local-dev-notes/`.
- Do not commit files under `local-dev-notes/`.
- Test fixtures should use synthetic names unless a real term is essential to the behavior under test and explicitly justified.
- Local Barn Owl state belongs in the app support directory, not in source control.

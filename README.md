# BarnOwl

BarnOwl is a native macOS app for capturing meetings, transcribing them, and turning the result into local Markdown notes with summaries, decisions, action items, open questions, and diarized transcript sections.

The day-to-day interface is CLI/Codex-first. When a user asks Codex to record a
meeting, Codex starts BarnOwl immediately through the local control bridge, then
uses the bundled BarnOwl Codex skill to gather useful context it can access -
calendar details, Slack threads, local project files, location/workspace clues,
prior BarnOwl notes, or user-provided chat context - and appends concise,
source-labeled facts to the active recording. BarnOwl stores that context
alongside the transcript so final notes and later meeting-memory questions are
better grounded. The macOS UI remains useful for setup, permissions, API key
entry, bridge status, manual review, and admin tasks.

![BarnOwl logo](docs/barn-owl-final-logo.png)

## Status

This repository is in active development. The current implementation focuses on the first local recording and transcription path:

- microphone and system-audio capture
- session state and recovery models
- OpenAI transcription and summary adapters
- local persistence for meeting artifacts and diagnostics
- Markdown rendering for meeting notes
- a small local control bridge and CLI wrapper for automation

## Repository Layout

- `Apps/BarnOwlMac/` - macOS app entry point, menu bar UI, settings, app composition, and control bridge
- `Sources/BarnOwlCore/` - shared recording, transcript, command, and health models
- `Sources/BarnOwlAudio/` - microphone, system audio, and chunk-writing components
- `Sources/BarnOwlOpenAI/` - OpenAI API configuration, transcription, realtime transcription, note editing, and summary clients
- `Sources/BarnOwlTranscription/` - transcription pipeline adapters
- `Sources/BarnOwlPersistence/` - local SQLite, library, diagnostics, temp audio, and recovery storage
- `Sources/BarnOwlNotes/` - Markdown meeting artifact rendering
- `Tests/` - unit coverage for core, audio, OpenAI, transcription, persistence, and rendering
- `docs/` - implementation notes, QA checklists, and roadmap documents
- `scripts/` - local verification, update, packaging, keychain, and CLI helper scripts
- `dist/` - generated distribution artifacts; ignored and safe to recreate

## Requirements

- macOS 26.0 or newer
- Xcode with Swift 6 support
- XcodeGen for regenerating `BarnOwl.xcodeproj` from `project.yml`
  - `scripts/verify.sh` first uses the bundled local copy under `.tools/` when present.
  - Source handoff recipients can install it with `brew install xcodegen` or `mint install yonaskolb/XcodeGen`.
  - If XcodeGen is unavailable but `BarnOwl.xcodeproj` is present, `scripts/verify.sh` falls back to the included generated project and prints a warning.
- An OpenAI API key for transcription and summary features

## Build and Test

The project is configured through `project.yml` and includes a generated Xcode project.

```sh
scripts/verify.sh
```

The verification script regenerates the Xcode project, cleans the build, and runs the BarnOwl test suite.

The final production-readiness gate for an internal/direct-download release is:

```sh
scripts/verify-production-readiness.sh --manual-qa-evidence PATH_TO_COMPLETED_QA_EVIDENCE
```

That command requires a verified `dist/` package and completed manual macOS
capture QA evidence for the exact app zip you plan to share.

To reset local Barn Owl test data before a clean onboarding pass:

```sh
scripts/reset-local-state.sh --yes
```

To install the current packaged app for a clean local onboarding pass:

```sh
scripts/package-all.sh
scripts/install-local-app.sh --yes --reset-state
```

The install script verifies `dist/BarnOwl.app.zip`, replaces
`/Applications/Barn Owl.app`, and preserves existing Barn Owl recordings, notes,
settings, and Keychain data by default. It clears Barn Owl local app data,
Keychain state, and macOS permission decisions only when `--reset-state` is
passed for fresh-onboarding QA. App-bundle backups are kept outside
`/Applications` so macOS Privacy settings continue to point at the real installed
app, not a stale backup bundle.

If a user hits an error, ask them to run
`barnowl diagnostics export --output /tmp/BarnOwl-diagnostics.md` or open Barn
Owl Settings and choose **Export Developer Diagnostics**. The exported Markdown
report is designed for Slack or issue feedback: it includes app/setup/update/
recent error metadata and redacts API keys, private paths, raw audio,
transcripts, and diagnostic details that may contain meeting content.

For internal feedback, non-owner CLI/Codex users will see a feedback suggestion
when Barn Owl reports an error. `barnowl feedback slack` prints a redacted Slack
draft without posting. `barnowl feedback slack --yes` posts only after explicit
confirmation and requires `BARNOWL_SLACK_FEEDBACK_WEBHOOK_URL` to be configured.
Use `BARNOWL_FEEDBACK_OWNER_USERNAME` to override the default owner username and
`BARNOWL_SLACK_FEEDBACK_CHANNEL` if the webhook supports channel overrides.

After installing a release candidate, the CLI/Codex part of manual QA can be
checked and recorded with:

```sh
scripts/verify-cli-codex-qa.sh --evidence PATH_TO_MANUAL_QA_EVIDENCE
```

## Distribution

Generate shareable artifacts from the current source with:

```sh
scripts/package-all.sh
```

BarnOwl is distributed through GitHub Releases as an internal/direct-download
macOS app package, not through the Mac App Store. GitHub Releases are the
canonical app download and update path; local manifests are only for development
and smoke testing.

This writes sanitized outputs under `dist/`:

- `BarnOwl-source-handoff.zip` for developers
- `BarnOwl.app.zip` for app users
- `BarnOwl-release-manifest.json` for version/build/source audit metadata
- `BarnOwl-update-manifest.json` for app update checks
- `SHA256SUMS` for verifying downloaded artifacts

`scripts/package-all.sh` runs `scripts/verify-dist.sh` before returning. You can
rerun that package-integrity gate directly with:

```sh
scripts/verify-dist.sh dist
```

For just the source handoff archive:

```sh
scripts/verify-source-handoff.sh dist/BarnOwl-source-handoff.zip
```

Send those files only. Do not send the raw working folder. See [docs/distribution.md](docs/distribution.md).

To refresh the shareable zips after making changes, rerun `scripts/package-all.sh`.
It replaces the files in `dist/` with packages built from the current source.

To publish the GitHub-backed update feed, run:

```sh
scripts/publish-git-update.sh
git add Updates/BarnOwl
git commit
git push origin main
gh release create v0.1.0-build.BUILD dist/BarnOwl.app.zip dist/BarnOwl-source-handoff.zip dist/BarnOwl-release-manifest.json dist/SHA256SUMS
```

Barn Owl defaults to this manifest URL for installed apps:

```text
https://raw.githubusercontent.com/BURDICK-OAI/barn-owl/main/Updates/BarnOwl/BarnOwl-update-manifest.json
```

The tracked manifest points at `BarnOwl.app.zip` attached to the matching
GitHub Release tag; binary zips are not committed to Git history. See
[docs/github-release.md](docs/github-release.md) for the exact release and
teammate install flow.

## OpenAI API Key

BarnOwl stores the OpenAI API key in a restricted local user config file for the
current macOS user. Older Keychain entries are treated as legacy migration
sources only. Do not commit local `.env` files or plaintext secrets.

For app users, open Barn Owl Settings, paste an OpenAI API key into OpenAI Connection, and choose Save & Test Key. See [docs/openai-api-key-setup.md](docs/openai-api-key-setup.md) for the short setup guide.

For local development, copy `.env.example` to `.env.local` and populate it as needed for scripts that read environment variables:

```sh
cp .env.example .env.local
```

## Local CLI

The `scripts/barnowl` helper talks to the running app over the local control bridge.
Codex uses the same bridge: start first, attach summarized context from available
connectors after recording begins, stop on request, wait for processing, then
retrieve Markdown notes or query meeting memory.

```sh
scripts/barnowl status
scripts/barnowl start --title "Design Review"
scripts/barnowl context add --session SESSION_ID --source codex "Relevant context from calendar, Slack, local files, or prior notes."
scripts/barnowl stop
scripts/barnowl wait --latest --until complete --timeout 10m
scripts/barnowl meetings recent --limit 5
scripts/barnowl diagnostics export --output /tmp/BarnOwl-diagnostics.md
scripts/barnowl feedback slack
scripts/barnowl feedback slack --yes
```

## Privacy Notes

BarnOwl is designed around local-first meeting artifacts. Raw audio chunks are treated as temporary processing inputs and should be cleaned up after successful transcription and artifact persistence.

Recording is local-first even when the network is unavailable: BarnOwl keeps
capturing microphone/system audio locally, saves final-processing jobs in its
local queue, and retries connectivity failures automatically. The CLI can still
inspect the queued work with `barnowl status` and retry failed non-connectivity
jobs with `barnowl jobs retry`.

# Barn Owl Production Readiness Audit

Last updated: 2026-05-17

## Objective

Make Barn Owl production ready across the full macOS app: architecture, UI/UX,
performance, reliability, privacy/security, diagnostics, build/test health,
persistence/state behavior, CLI/Codex bridge behavior, and release readiness.

This document maps that objective to concrete evidence in the repo. It is a
readiness checklist, not a marketing badge. A green build is evidence, but not
the same thing as production readiness.

## Current Verdict

Barn Owl is in good local developer-build shape. It builds, tests, packages, and
has stronger privacy, local API-key storage, local bridge, release-verification, and storage
guards than before this pass.

Barn Owl is not targeting the Mac App Store or a Developer ID notarized release.
The target is a lightweight internal app package shared by GitHub, Git-hosted
artifacts, or ad-hoc zip transfer. These are the remaining hard blockers:

- Clean-machine manual QA for microphone, system-audio, TCC permission prompts,
  failure/retry states, and raw-audio cleanup.
- Publishing or otherwise sharing the Git repository/update artifacts from a
  location the installed app can reach.

## Evidence Snapshot

Commands run successfully during this pass:

- `xcodebuild build -scheme BarnOwl -destination 'platform=macOS'
  -derivedDataPath DerivedData CODE_SIGN_IDENTITY=-`
  - Result: passed after the recorder context IA redesign:
    separate `Add Details` and `Review Auto Context` entry points, transcript/imported
    review content grouped under `Review Auto Context`, and Settings terminology aligned to
    `Context Library`.
- `xcodebuild build-for-testing -scheme BarnOwlAppHostedTests -destination
  'platform=macOS' -derivedDataPath DerivedDataHostedUnsigned
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=`
  - Result: passed after the hosted-test launch guard change in
    `BarnOwlAppDelegate`.
- `scripts/run-hosted-app-tests.sh`
  - Result: passed.
  - Replaces the flaky `xcodebuild test-without-building -scheme
    BarnOwlAppHostedTests ...` outer harness with a repo-owned deterministic
    hosted-app runner that launches the built Barn Owl app with the same XCTest
    injection libraries. The runner executed 125 app-hosted tests successfully
    on 2026-05-17, including the regression guard that expanded transcript
    utility panels must switch the workspace into scroll-safe mode.
- `scripts/verify.sh`
  - Result: passed on 2026-05-17 after switching hosted-app execution to
    `scripts/run-hosted-app-tests.sh`.
  - Verified the Barn Owl test suite after the local API-key storage,
    permission-readiness, realtime, installed-app smoke, and offline queued
    final-processing changes. Run again after any source change before release.
- `scripts/package-all.sh`
  - Result: created `dist/BarnOwl-source-handoff.zip` and
    `dist/BarnOwl.app.zip`, plus `dist/BarnOwl-release-manifest.json` and
    `dist/BarnOwl-update-manifest.json`, and `dist/SHA256SUMS`
  - The package flow now invokes `scripts/verify-release.sh` automatically.
  - Before sharing, confirm `dist/BarnOwl-release-manifest.json` reports the
    intended current commit with `git_status: clean`.
- `cd dist && shasum -a 256 -c SHA256SUMS`
  - Result: `BarnOwl-source-handoff.zip: OK`, `BarnOwl.app.zip: OK`, and
    `BarnOwl-release-manifest.json: OK`, and `BarnOwl-update-manifest.json: OK`
  - Current artifact SHA-256 values are intentionally kept in
    `dist/SHA256SUMS` and the release manifest instead of this tracked doc, so
    packaging from a clean commit does not create stale audit text.
- `scripts/verify-dist.sh dist`
  - Result: `dist_check=true`
  - Verified the expected `dist/` file set, source handoff archive,
    `SHA256SUMS`, release manifest artifact paths, release/update manifest
    SHA-256 values, and the app package release gate.
- `scripts/verify-source-handoff.sh dist/BarnOwl-source-handoff.zip`
  - Result: `source_handoff_check=true`
  - Verified the archive has one `BarnOwl/` root, includes required build/test
    and release-readiness files, and excludes local state, generated artifacts,
    secret files, and user Xcode state.
- Extracted `dist/BarnOwl-source-handoff.zip` to `/private/tmp` and ran its
  `scripts/verify.sh`
  - Result: `** TEST SUCCEEDED **`
  - Verified the source handoff can build and test from a clean extracted copy
    without the bundled `.tools/` XcodeGen; `scripts/verify.sh` fell back to the
    included generated `BarnOwl.xcodeproj` with a warning.
- `scripts/verify-release.sh .build/package/BarnOwl.app`
  - Result: `release_check=true`
  - Verified bundle id `com.barnowl.mac`, code signature validity, hardened
    runtime, required code-signing entitlements, required macOS privacy usage
    descriptions, bundled CLI, bundled Codex skill resources, and bundled Codex
    MCP app resources.
- `RUN_VERIFY=0 scripts/verify-production-readiness.sh`
  - Expected failure without manual QA evidence:
    `manual QA evidence is required; pass --manual-qa-evidence PATH`
- `scripts/collect-manual-qa-evidence.sh`
  - Result: generates `.build/manual-qa/manual-capture-qa-evidence-*.md` for
    the current `dist/BarnOwl.app.zip`.
  - The evidence file records the current `dist/BarnOwl.app.zip` SHA, installed
    bundle metadata, installed code-signature/hardened-runtime state, bundled
    CLI presence, bundled Codex skill presence, temp audio counts, and redacted
    diagnostics metadata. The production gate also requires the installed app
    version/build recorded in the file to match the packaged artifact
    version/build. The manual flow checkboxes are intentionally unchecked until
    a real capture/TCC pass is performed.
- `RUN_VERIFY=0 scripts/verify-production-readiness.sh --manual-qa-evidence .build/manual-qa/manual-capture-qa-evidence-*.md`
  - Current expected failure is limited to unchecked manual capture/TCC evidence
    after the installed CLI/Codex checks were completed. The current
    artifact-matched CLI recording smoke reaches the installed app, then blocks
    at the macOS microphone-permission interaction instead of proving a full
    `start -> stop -> wait complete -> meeting notes` pass:
    first-run grant, microphone denied, system-audio denied, previously denied
    retry, permission revoked while recording, source-unavailable case, final
    notes/transcript visibility, realtime preview producing text during
    recording, live-preview/final-transcript separation, scroll-safe transcript
    utility panels, `Add Details` / `Review Auto Context` / `Context Library`
    label clarity, Settings Context Library CRUD coverage, and privacy review
    of user-facing errors.
- Historical note: direct ad-hoc-signed `xcodebuild test-without-building
  -scheme BarnOwlAppHostedTests ...` attempts on 2026-05-16 repeatedly stalled
  before test execution while the launched app host sat in `dyld` dependency
  loading. The release gate now uses `scripts/run-hosted-app-tests.sh`, which
  drives the unsigned hosted lane through the same canonical XCTest path and
  passes.
- `scripts/install-local-app.sh --yes`
  - Result: installed verified package to `/Applications/Barn Owl.app`
  - Installed version/build recorded in the latest artifact-matched QA evidence:
    `0.1.0 (17)`
  - Current installed app metadata: bundle id `com.barnowl.mac`, ad-hoc
    signature, hardened runtime, bundled CLI executable, and bundled Codex skill
    present. The install preserves user data by default and backs up the
    previous app bundle.
- `/Applications/Barn Owl.app/Contents/MacOS/barnowl feedback slack --force --format json`
  - Result: generated a redacted Slack feedback draft and posted nothing.
  - `barnowl feedback slack --yes` requires
    `BARNOWL_SLACK_FEEDBACK_WEBHOOK_URL`; owner-user suggestions are suppressed
    by default unless `--force` is provided.
- `scripts/verify-cli-codex-qa.sh --evidence PATH_TO_MANUAL_QA_EVIDENCE`
  - Result: `cli_codex_qa=true`
  - Verified installed CLI status, redacted diagnostics export, draft-only Slack
    feedback behavior, missing-webhook post guard, bundled Codex skill guidance,
    bundled Codex MCP app resources, and local MCP app boot/initialize/tool/resource
    smoke against `/Applications/Barn Owl.app/Contents/MacOS/barnowl`.
- `scripts/verify-cli-recording-flow.sh --evidence PATH_TO_MANUAL_QA_EVIDENCE`
  - Current artifact-matched result on 2026-05-17:
    `cli_recording_flow=false`,
    `reason=CLI start is blocked on macOS permission interaction
    (captureStatus='Requesting microphone permission.', nextCommand='barnowl status --format json')`
  - Starts a short installed-app recording, stops it, waits until processing is
    complete, fetches meeting notes, marks the release-evidence checkbox, and
    appends a compact transcript-free proof section when macOS permissions are
    already resolved for the installed release candidate.
- `/Applications/Barn Owl.app/Contents/MacOS/barnowl permissions test --format json`
  - Current machine result: microphone and system-audio capture succeeded in
    the installed app after local API-key setup.
  - Verified the installed app proactively requests/checks microphone and
    system-audio access, reports setup as ready when prior capture evidence
    proves the path works, and no longer blocks recording on stale macOS
    preflight values.
- Installed runtime smoke through `/Applications/Barn Owl.app/Contents/MacOS/barnowl`
  - Created a disposable OpenAI API key named `Barn Owl Codex` through the
    secure connector and saved it to Barn Owl's restricted local user config.
  - Started a recording from the installed CLI, played disposable macOS system
    audio, observed `Realtime transcription streaming` and `Realtime
    transcription updated`, stopped the recording, waited for final processing,
    and retrieved final notes/transcript.
  - Final notes/transcript captured the system-audio smoke phrases as call
    speaker content, proving the real system-audio path works even though
    macOS screen-capture preflight can remain false on this local machine.
- Installed CLI recording-flow smoke on 2026-05-16
  - Started artifact-matched session `5948E163-D1E1-46B9-9AF9-76862FE38F71`
    from the installed CLI, stopped it, waited until `complete`, and retrieved
    meeting notes.
  - This closes the CLI control-path evidence item independently of the final
    manual TCC walkthrough.

The local package is intentionally lightweight:

- Signature: ad-hoc
- Hardened runtime: present
- Notarized: false
- Update trust: HTTPS/local manifest plus SHA-256 checksum and valid Barn Owl app
  bundle signature

## Prompt-to-Artifact Checklist

| Requirement | Evidence | Status |
| --- | --- | --- |
| Audit full UI surface area | UI files under `Apps/BarnOwlMac/`, especially `RecorderWindow`, `MenuBarView`, `SettingsView`, onboarding, lifecycle presentation, updater, and app model were inspected and changed during the UI pass. The recorder now separates `Add Details` for meeting-only input from `Review Auto Context` for transcript/imported suggestions; Settings exposes the durable layer as `Context Library`, keeps the main card compact, and opens a dedicated management surface for search, filtering, create, edit, and delete. Expanded transcript-top utility panels now force the selected-recording workspace into a scroll-safe layout so they do not strand the transcript/editor below the clipped viewport. | Partially verified by code inspection and tests; needs manual visual QA. |
| First launch/setup flow understandable | Readiness/onboarding state tests cover required checks, missing API key, permissions, storage warning, and completed checklist behavior. | Automated coverage present; clean-machine manual QA still required. |
| API key setup avoids repeated prompts | `BarnOwlAPIKeyStore` now stores saved keys in a restricted local user config file for lightweight ad-hoc builds, treats Keychain as legacy read-only migration, avoids passive Keychain decrypts, exposes a Settings migration action for older Keychain-saved keys, and has focused tests in `BarnOwlAPIKeyStoreTests`. Readiness now distinguishes saved-but-untested keys from verified keys. | Covered by tests. |
| Start recording state is obvious and safe | Recording state machine tests cover permission readiness, double-start rejection, double-stop handling, and lifecycle presentation. Start now explicitly requests microphone access before creating the recording session; denied/restricted states fail quickly with actionable macOS recovery text. | Covered by tests and installed CLI permission smoke; real TCC/manual capture still required. |
| Live recording UI responsive | Realtime controller tests cover buffering, tiny-buffer suppression, soft speech append, server-error degradation, stale transcript suppression, routine server-event suppression, UI presentation helpers, and the scroll-safe workspace policy used when transcript utility panels or post-recording review expand inline above the editor. Chat auto-scroll now defers scroll work to avoid layout during layout. | Covered by tests; needs real recording observation. |
| Expensive user-visible paths stay responsive | Performance smoke tests cover large notes rendering, deterministic overlap stitching across many chunk boundaries, and local library search across many saved meetings. These use generous budgets to catch accidental pathological work without turning unit tests into brittle microbenchmarks. Runtime metrics now include final diarization and summary model-request phase timings in addition to capture, realtime preview, final processing, temp audio, and cleanup durations. | Covered by tests and runtime instrumentation; real-device profiling still recommended before broader rollout. |
| Stop recording and final processing states are obvious | Lifecycle presentation, durable job timeline, processing recovery, and failure/retry tests cover completed, failed, and pending job states. | Covered by tests. |
| Offline recording/final processing is safe | Recording captures local chunks first. Durable jobs queue final processing in SQLite, launch recovery requeues interrupted work, raw audio is preserved until successful processing, and connectivity failures now remain pending with automatic retry instead of becoming terminal after the normal retry cap. | Covered by tests; full airplane-mode/manual network-loss QA still recommended. |
| Completed meeting view separates notes/transcript/history | Recorder workspace tests cover live preview versus final transcript separation; persistence tests cover history/search/state. | Covered by tests; manual UI review still useful. |
| Diagnostics/errors actionable and private | Error formatter and diagnostics log tests cover redaction of API keys, paths, and response bodies; diagnostics log files use restricted permissions; localized setup/capture errors are shown as friendly descriptions instead of internal enum text. Settings now includes **Export Developer Diagnostics**, which writes a redacted Markdown report with app/setup/update/recent error metadata while omitting API keys, private paths, raw audio, transcripts, and diagnostic details that may contain meeting content. | Covered by tests. |
| CLI/Codex bridge visible state is safe | Control bridge POST commands require bearer-token auth; token file has private permissions; CLI reads token; HTTP auth tests cover unauthorized and authorized POST behavior. The bridge now creates the token before listening so the first authorized POST after first launch does not fail due to lazy token creation. Control responses and the bundled CLI redact user-visible error fields so persisted job/status errors do not expose API keys or private local paths. | Covered by tests and installed CLI smoke. |
| CLI/Codex users can report failures safely | Control responses suggest `barnowl feedback slack` for reportable non-owner errors and expose `barnowl feedback slack --yes` only as the confirmed post command. The CLI defaults to a local redacted draft, requires explicit `--yes` before Slack posting, requires `BARNOWL_SLACK_FEEDBACK_WEBHOOK_URL`, suppresses owner-user nudges by default, and filters validation errors such as missing IDs or missing `--yes`. | Covered by tests, CLI compile, secret scan, and installed CLI smoke. |
| Privacy-forward local storage | SQLite DB, local library files, temp audio metadata/files, diagnostics logs, and local context files restrict permissions. Temp raw audio is finalized/deleted and metadata clears raw paths. | Covered by persistence tests. |
| Realtime preview works and stays separate from final transcript | UI/state tests assert live preview and final transcript separation. Realtime client tests cover the current Realtime transcription session payload; installed-app smoke confirmed realtime audio append/commit plus transcript delta/completed events after clear speech. Rolling transcription cache is deleted after completed final processing. Production readiness evidence now requires visible realtime preview text during recording, before final processing. | Covered by tests and installed smoke; clean-machine manual QA still required. |
| No secrets in source/packages | `scripts/scan-secrets.sh` is run by `scripts/verify.sh` and source handoff packaging. | Covered by scripts; scanner remains pattern-based. |
| App builds | `scripts/verify.sh` regenerates project when XcodeGen is available, cleans, and runs the Barn Owl test suite. It resolves XcodeGen from the bundled local copy or `PATH`; sanitized source handoffs can also fall back to the included generated `BarnOwl.xcodeproj` with a warning. | Passing. |
| Relevant tests pass | `scripts/verify.sh` passed on 2026-05-17 across core, audio, OpenAI, transcription, context, notes, persistence, the deterministic app-hosted runner (`scripts/run-hosted-app-tests.sh`, 125 app-hosted tests), and the MCP app verification already wired into the verifier. | Passing. |
| App packages correctly | `scripts/package-all.sh` builds source and app zips, writes `dist/BarnOwl-release-manifest.json`, `dist/BarnOwl-update-manifest.json`, and `dist/SHA256SUMS`, then runs `scripts/verify-dist.sh` to validate the expected dist file set, source handoff archive, checksums, release/update manifest SHA-256 values, and app release gate. `scripts/package-app.sh` uses `ditto -c -k --keepParent` to preserve signing metadata for bundled executables and signs lightweight internal packages ad hoc with hardened runtime. | Passing for lightweight internal artifacts. |
| Clean local install path exists | `scripts/install-local-app.sh --yes` verifies `dist/BarnOwl.app.zip`, extracts and validates the Barn Owl bundle id, backs up an existing destination app, installs to `/Applications/Barn Owl.app` by default, and verifies the installed signature. It preserves local user data by default. `--reset-state` is explicitly destructive and test-only for fresh onboarding QA. | Executed against `/Applications/Barn Owl.app`; installed app launches and bridge status responds. |
| Release gate exists | `scripts/verify-release.sh` validates local/internal artifacts, exact app archive shape, absence of bundled local/private state, required macOS privacy usage descriptions, required code-signing entitlements, bundled CLI, bundled Codex skill resources, bundled Codex MCP app resources, valid code signature, and hardened runtime. | Present and exercised. |
| Local and Git-style update artifacts are verified | `scripts/update-local.sh` and `scripts/publish-local-update.sh` sign local update apps with hardened runtime; `publish-local-update.sh` runs `scripts/verify-release.sh` on the generated update archive before writing the manifest. `scripts/package-all.sh` writes `BarnOwl-update-manifest.json`; `scripts/publish-git-update.sh` writes the tracked GitHub raw manifest in `Updates/BarnOwl/` and points it at the matching GitHub Release asset URL. Remote update installs require HTTPS, checksum, valid Barn Owl bundle identity, and a valid app signature; ad-hoc signatures are allowed for the lightweight internal path. The app defaults to the GitHub raw update manifest, checks on launch, periodically while idle, and when the user asks. | Verified by packaging gates; updater policy covered by focused tests and needs full app smoke after install. |
| Rollback path is explicit | `docs/local-updates.md` and `docs/github-release.md` now document the real rollback model: older manifests can stop further rollout, already-updated clients need either a manual reinstall of the preserved last-known-good `BarnOwl.app.zip` or a higher-build rollback release, and local app data remains preserved because installs replace only the app bundle. | Documented; rollback drill is procedural rather than automated. |
| Lightweight internal distribution ready | The app package is ad-hoc signed with hardened runtime, checksummed, and paired with an update manifest. Gatekeeper friction is expected on first launch because the app is intentionally not Developer ID notarized. A release candidate must pass `scripts/verify-dist.sh dist`, then complete clean-machine capture QA. | Packaging ready; clean-machine manual QA still blocks push readiness. |
| Manual QA documented | `docs/manual-capture-qa.md` documents permission, capture, denial, revocation, source-unavailable, chunk cleanup, privacy evidence steps, and the installed-app check that transcript-top utility panels keep the workspace scrollable/responsive. `scripts/collect-manual-qa-evidence.sh` creates a repeatable redacted evidence file for clean-machine QA passes under `.build/manual-qa/` and records the tested app artifact SHA-256. `scripts/verify-production-readiness.sh` requires completed manual QA evidence matching the current `dist/BarnOwl.app.zip`, zero raw audio files, and a verified internal package before reporting `production_ready=true`. | Documented and tooled, not executed in this pass. |
| Clean onboarding reset is available | `scripts/reset-local-state.sh --yes` removes Barn Owl local app data, caches, preferences, saved state, HTTP storage, CrashReporter plists, temp Barn Owl test/capture artifacts, saved OpenAI Keychain entries, and Barn Owl TCC permission decisions. | Executed locally to prepare a fresh onboarding pass. |
| Source handoff builds independently | The generated `dist/BarnOwl-source-handoff.zip` was extracted to `/private/tmp` and its own `scripts/verify.sh` passed from inside the extracted copy. | Passing. |

## Remaining Risks

### Lightweight Distribution Tradeoff

Current packages are ad-hoc signed. That is the intended lightweight internal
distribution path. Recipients should expect first-launch Gatekeeper friction.
The package still has a valid app signature, hardened runtime, SHA-256 checksums,
and a checksum-bearing update manifest. Developer ID/notarization remains an
optional future convenience, not a release blocker for this internal workflow.

### Manual macOS Capture QA

Automated tests cannot fully verify macOS TCC permission prompts, microphone
device behavior, ScreenCaptureKit/system-audio behavior, relaunch requirements,
or clean-machine recovery. Execute `docs/manual-capture-qa.md` before calling the
app production-ready.

Minimum manual evidence still needed:

- First-run grant path screenshots or screen recording.
- Microphone denied and retry evidence.
- System-audio denied and retry evidence.
- Permission revoked while recording evidence.
- Realtime preview text appearing during recording before stop/final processing.
- Active recording chunk files plus post-finalization proof that raw audio files
  are removed.
- Logs showing actionable errors without API keys, private paths, transcript
  excerpts, or raw audio payloads.
- A redacted Settings -> Export Developer Diagnostics file after at least one
  failure/retry run.
- Before/after `scripts/collect-manual-qa-evidence.sh` reports for the run. The
  collector intentionally omits diagnostic messages/details and records only
  category, level, timestamp, and count metadata.

### AppKit Layout Warning

Earlier verifier runs emitted intermittent AppKit warnings:

```text
It's not legal to call -layoutSubtreeIfNeeded on a view which is already being laid out.
```

The likely test-host cause was reduced by skipping menu-bar/runtime AppKit setup
when launched under XCTest, and chat auto-scroll now defers scroll work out of
the layout pass. The latest verifier passed without this warning in the visible
output. Keep watching for it during manual UI QA, but it is no longer treated as
a release-blocking automated-test finding.

### Release Update Trust

Remote update installation now requires HTTPS archives, checksums, valid Barn Owl
bundle identity, and valid signatures. Ad-hoc signatures are allowed for the
lightweight internal path. This is intentionally simpler than Developer ID or
Sparkle signing; a future public updater should still consider a dedicated
signed appcast/update framework.

## Hard Release Gates

1. Run clean-machine manual capture QA from `docs/manual-capture-qa.md`.
2. Confirm `scripts/verify.sh`.
3. Confirm `scripts/package-all.sh`.
4. Confirm `scripts/verify-dist.sh dist`.
5. Confirm `scripts/verify-production-readiness.sh --manual-qa-evidence PATH`.
6. Publish the Git repository or update artifacts to the location configured in
   Barn Owl Settings.

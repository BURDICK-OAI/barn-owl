# Manual Capture QA

Scope: first-run macOS validation for Barn Owl microphone and system-audio capture. This checklist is intentionally manual because macOS permission prompts, TCC state, and ScreenCaptureKit behavior are OS-controlled and love making automation look silly.

Bundle ID under test: `com.barnowl.mac`

## Test Environment

Record this before each pass:

- macOS version and build: Apple menu -> About This Mac, or `sw_vers`
- Mac model and CPU architecture
- Barn Owl build source: Xcode scheme, commit, branch, and build configuration
- Launch method: Xcode Run, Finder-launched app, or built `.app`
- Microphone device used
- System-audio source used, such as a browser tab, meeting app, or local media player
- Whether Barn Owl was already present in System Settings permission panes before reset

Create a structured evidence file before and after the pass:

```sh
scripts/collect-manual-qa-evidence.sh
```

The script writes a timestamped Markdown file under `.build/manual-qa/` with
system details, app artifact metadata, the app artifact SHA-256,
usage-description strings, manual flow checkboxes, CLI/Codex feedback
checkboxes, diagnostic category/level summaries, and temp audio counts. It intentionally omits
diagnostic messages and details so evidence files do not preserve meeting text.
It does not collect raw audio, transcripts, API keys, or full private paths. If
you are testing a different app artifact or chunk root, set
`BARNOWL_QA_APP_ARTIFACT` or `BARNOWL_QA_CHUNK_ROOT`.

After completing the pass, fill in the evidence file's `Manual Flow Results`
and `CLI Codex Feedback Results` checkboxes. Lightweight internal production
readiness requires a completed evidence file for the exact package you plan to
share:

```sh
scripts/verify-production-readiness.sh \
  --manual-qa-evidence .build/manual-qa/manual-capture-qa-evidence-YYYYMMDD-HHMMSS.md
```

The CLI/Codex feedback section can be checked automatically after installing the
release candidate:

```sh
scripts/verify-cli-codex-qa.sh \
  --evidence .build/manual-qa/manual-capture-qa-evidence-YYYYMMDD-HHMMSS.md
```

Use a real audio signal for both sources:

- Mic: speak for at least 15 seconds during capture.
- System audio: play non-sensitive audio for at least 15 seconds. Use throwaway test audio, not a real meeting. QA is not the place to accidentally archive the CFO.

Run manual QA against the exact `dist/BarnOwl.app.zip` release candidate you
intend to share. `scripts/verify-production-readiness.sh` rejects evidence whose
recorded app SHA-256 does not match the current `dist/BarnOwl.app.zip`.

## Permission Reset Commands

Quit Barn Owl before resetting permissions.

Reset microphone permission:

```sh
tccutil reset Microphone com.barnowl.mac
```

Reset screen/system capture permission:

```sh
tccutil reset ScreenCapture com.barnowl.mac
```

On macOS versions that expose a separate audio-capture TCC service, also try:

```sh
tccutil reset AudioCapture com.barnowl.mac
```

If that command reports an unknown service, note it in evidence and continue. The app declares both `NSAudioCaptureUsageDescription` and `NSScreenCaptureUsageDescription`; the OS version decides which prompt and Settings row are used.

Verify or change decisions in System Settings:

- Microphone: System Settings -> Privacy & Security -> Microphone -> Barn Owl
- Screen & System Audio Recording, or equivalent wording for the OS version: System Settings -> Privacy & Security -> Screen & System Audio Recording -> Barn Owl

After toggling system-audio or screen-capture permissions, fully quit and relaunch Barn Owl. macOS often requires relaunch for those changes to apply.

## Baseline First-Run Grant Path

Start with both permissions reset.

For a full local reset before this pass, run:

```sh
scripts/reset-local-state.sh --yes
```

That deletes Barn Owl local app data, preferences, caches, temp chunks/test
state, saved OpenAI Keychain entries, and Barn Owl TCC decisions. It does not
remove the app bundle itself. This reset is for this QA pass only. Normal app
installs and updates must not use it, because real user recordings and notes are
expected to persist across versions.

1. Launch Barn Owl.
2. Confirm the app starts in `idle`.
3. Confirm the primary action is `Start Recording`.
4. Click `Start Recording`.
5. Confirm the app transitions to `preparing`.
6. Confirm the primary action becomes `Preparing...` and cannot be spam-clicked into concurrent recordings.
7. When the microphone permission prompt appears, click `Allow`.
8. When the system-audio, screen-capture, or ScreenCaptureKit permission prompt appears, click `Allow`.
9. If macOS asks for relaunch after system-audio or screen-capture permission, quit Barn Owl, relaunch it, and click `Start Recording` again.
10. Generate mic and system audio for at least 15 seconds.
11. Confirm the app transitions to `recording`.
12. Confirm the primary action is `Stop Recording`.
13. Click `Stop Recording`.
14. Confirm the app transitions through `processing`.
15. Confirm the app returns to `idle`.
16. Confirm the primary action is again `Start Recording`.

Expected result:

- The app does not show `recording` until capture has actually started.
- A single `RecordingSession` is created for the attempt.
- Both microphone and system-audio sources are represented as active capture sources.
- Temporary audio chunk metadata exists for microphone and system audio with monotonic sequence numbers.
- Temporary audio chunk files exist while capture is active or before finalization.
- After finalization, chunk metadata is `finalized`, `deletedAudioAt` is set, `temporaryAudioPath` is `null`, and raw audio chunk files are gone.
- No raw audio samples, chunk payloads, transcript snippets from raw buffers, or sensitive file paths appear in logs.

Evidence to capture:

- Screenshot or screen recording of the permission prompts.
- A before/after evidence file from `scripts/collect-manual-qa-evidence.sh`.
- A redacted Settings -> Export Developer Diagnostics file after at least one
  failure/retry run.
- Screenshot of `preparing`, `recording`, `processing`, and returned `idle` states.
- Console or Xcode logs for the run.
- The temp chunk root path used by the build.
- Directory listing while recording showing mic and system-audio chunk files.
- Directory listing after finalize showing no raw audio chunk files remain.
- Metadata JSON for representative mic and system-audio chunks after finalize.
- Installed CLI smoke:
  - `barnowl status --format json`
  - `barnowl diagnostics export --output /tmp/BarnOwl-diagnostics.md --format json`
  - `barnowl feedback slack --force --format json`
  - `barnowl feedback slack --yes --force --format json` with no webhook set, confirming it refuses to post.

## Microphone Denied Path

Start with microphone permission reset. Leave system-audio permission either reset or granted; note which.

1. Launch Barn Owl.
2. Click `Start Recording`.
3. When the microphone prompt appears, click `Don't Allow`.
4. Confirm Barn Owl exits `preparing` and enters `failed`.
5. Confirm the user-visible error names missing permissions or says Barn Owl needs microphone and system-audio permissions before recording.
6. Confirm the primary action returns to a retryable `Start Recording` state.
7. Confirm no committed recording continues in the background.
8. Confirm no raw audio chunks are retained for the failed attempt.
9. Open System Settings and grant Microphone permission to Barn Owl.
10. Quit and relaunch Barn Owl if macOS requires it.
11. Click `Start Recording` again.
12. Confirm the app can retry without reinstalling or clearing app data.

Expected result:

- Denial produces a `failed` state, not a silent fallback.
- Retry is possible after the user grants permission.
- If a session ID was created before denial, any raw chunks from that attempt are deleted or never created.
- Logs contain an actionable failure reason, not raw audio data.

Evidence to capture:

- Screenshot of denied prompt.
- Screenshot of failed state and error text.
- Screenshot of System Settings after granting permission.
- Logs covering denial and retry.
- Temp chunk directory before and after retry.

## System-Audio Denied Path

Start with system-audio/screen-capture permission reset. Microphone may be granted; note current state.

1. Launch Barn Owl.
2. Click `Start Recording`.
3. Allow microphone permission if prompted.
4. Deny the system-audio, screen-capture, or ScreenCaptureKit prompt.
5. Confirm Barn Owl exits `preparing` and enters `failed`.
6. Confirm the user-visible error identifies that capture permissions or sources are missing.
7. Confirm the app stops any microphone capture that already started.
8. Confirm no mic-only recording is silently accepted unless the UI explicitly shows a downgraded mic-only configuration.
9. Confirm raw chunks from the failed attempt are deleted or never created.
10. Open System Settings and grant the relevant system-audio or screen-capture permission.
11. Quit and relaunch Barn Owl if prompted or if capture still fails.
12. Retry recording and confirm both sources can record.

Expected result:

- System-audio denial is explicit.
- The app does not silently record mic-only under the default meeting-capture configuration.
- Any source that started before denial is stopped.
- Retry works after permission is granted and the app is relaunched if required.

Evidence to capture:

- Screenshot of denied prompt or Settings denial state.
- Screenshot of failed state and error text.
- Logs showing source startup and cleanup.
- Temp chunk directory after failed attempt.
- Successful retry evidence if permission is later granted.

## Previously Denied Retry Path

Use this when permissions were denied in an earlier run and macOS no longer displays prompts.

1. In System Settings, set Microphone or Screen & System Audio Recording for Barn Owl to denied.
2. Quit and relaunch Barn Owl.
3. Click `Start Recording`.
4. Confirm the app enters `failed` with an actionable message.
5. Confirm the app does not wait forever in `preparing`.
6. Grant the permission in System Settings.
7. Quit and relaunch if needed.
8. Click `Start Recording` again.
9. Confirm capture can start.

Expected result:

- Previously denied permission is detected quickly.
- The app remains retryable.
- No raw audio is retained from denied attempts.

Evidence to capture:

- Screenshot of System Settings denied state.
- Screenshot of failed state.
- Logs from denied start and successful retry.

## Permission Revoked While Recording

Use a disposable run and non-sensitive audio.

1. Start a successful recording with both sources active.
2. While Barn Owl is recording, open System Settings.
3. Revoke Microphone or Screen & System Audio Recording permission for Barn Owl.
4. If macOS requests relaunch or immediately interrupts capture, follow the OS prompt and note the behavior.
5. Confirm Barn Owl stops capture or surfaces a retryable failure.
6. Confirm any valid derived metadata is finalized.
7. Confirm raw audio chunks are deleted.
8. Restore permission and verify a new recording can start.

Expected result:

- Revocation does not leave Barn Owl stuck in `recording`.
- Capture stops cleanly or fails cleanly.
- Raw chunks from the interrupted run are not retained after finalization or cleanup.

Evidence to capture:

- Screen recording of revocation behavior.
- Logs before, during, and after revocation.
- Chunk metadata after cleanup.
- Directory listing proving raw audio files were removed.

## Source Unavailable Cases

Run at least the applicable cases for the test machine.

Microphone unavailable:

1. Select no usable input device if the OS allows it, disconnect the input device, or use a device known to fail.
2. Start Barn Owl recording.
3. Confirm the app enters `failed` with a source-unavailable or capture-failed error.
4. Restore a valid microphone and retry.

System audio unavailable:

1. Test on an unsupported OS if available, or create a ScreenCaptureKit failure condition if the implementation exposes one.
2. Start Barn Owl recording.
3. Confirm the app enters `failed` unless a downgraded source configuration is explicitly shown and persisted.
4. Restore availability and retry.

Expected result:

- Permission failure and source-unavailable failure are distinguishable in logs and, where possible, user text.
- The app can retry after the source is restored.
- No raw audio is retained from failed attempts.

## Chunk and Privacy Verification

During active recording, verify:

- Microphone chunks are written with track kind equivalent to `microphone`.
- System-audio chunks are written with track kind equivalent to `systemAudio`.
- Sequence numbers are unique and monotonic per track.
- Chunk metadata includes the session ID, track kind, sequence number, lifecycle state, temporary audio path, and byte count after write.
- Raw audio files are stored only under the app-controlled temporary chunk location.

After finalize, verify:

- Every chunk for the session is `finalized`.
- `finalizedAt` and `deletedAudioAt` are set.
- `temporaryAudioPath` is cleared.
- The raw `.caf` or equivalent audio files no longer exist.
- Metadata retained after finalize does not contain raw audio data.
- Logs do not contain raw samples, large encoded payloads, private meeting titles, or source audio content.

Suggested shell evidence, replacing `CHUNK_ROOT` and `SESSION_ID` with the values from the run:

```sh
find CHUNK_ROOT/SESSION_ID -maxdepth 3 -type f -print
```

```sh
find CHUNK_ROOT/SESSION_ID -type f \( -name '*.caf' -o -name '*.wav' -o -name '*.m4a' \) -print
```

Expected after finalize: the second command prints nothing.

## Done Means

This pass is done only when all of the following are true:

- Mic capture writes chunks.
- System audio capture writes chunks.
- Chunks are deleted on finalize.
- No raw audio is retained after finalize, failed start cleanup, denied-permission cleanup, or revoked-permission cleanup.
- Denied mic permission is visible, retryable, and does not retain raw audio.
- Denied system-audio permission is visible, retryable, and does not silently downgrade default capture.
- Previously denied permissions fail quickly with actionable UI and can be retried after the user grants access.
- Evidence is attached for prompts, app states, logs, chunk metadata, and post-finalize file listings.
- Installed CLI status, diagnostics export, feedback draft, feedback confirmation guard, and bundled Codex skill guidance are checked against the same app package.

## Current Implementation Risks To Watch

- `ScreenCaptureKitSystemAudioSource` currently checks OS availability but does not visibly request or validate a specific system-audio permission path. Manual QA should confirm what macOS actually prompts for.
- `AVFoundationMicrophoneAudioSource.startMicrophoneCapture` touches the input node but does not by itself prove chunk writing. Treat `recording` state as insufficient evidence; verify files and metadata.
- The app model uses a generic permission-denied message for microphone and system audio. QA should record whether that is specific enough for a user to recover.
- The default configuration requires both microphone and system audio. Any mic-only or system-only success must be explicitly reflected in state and persisted; otherwise it is a bug, not a feature with a nice hat.

# Recording Vertical Slice Guardrails

Scope: the first native macOS path that records microphone plus system audio, creates a `RecordingSession`, writes enough local metadata to recover the session, and exits cleanly. Agents may implement core, audio, and persistence in parallel, so this document defines behavior and boundaries rather than internal ownership.

## Acceptance Criteria

- Starting from `idle` creates one `RecordingSession` with `AudioSourceConfiguration.defaultMeetingCapture` unless the user has explicitly disabled a source in UI already shipped.
- Start transitions are observable and stable: `idle -> preparing -> recording`, or `idle -> preparing -> failed` with a user-actionable error.
- Stop transitions are observable and stable: `recording -> processing -> idle`, with `endedAt` set exactly once.
- Microphone and system audio are captured as distinct tracks or chunks with deterministic session ID, track kind, and sequence ordering.
- Partial success is explicit. If one source is unavailable, recording either fails before capture starts or records with a clearly reflected downgraded `AudioSourceConfiguration`; do not silently drop a source.
- A crash or force quit during capture leaves recoverable session metadata and no unreferenced raw audio blobs.
- The UI never displays `recording` until capture has actually started.
- Repeated Start clicks cannot create concurrent sessions; repeated Stop clicks are idempotent.
- Failure leaves the app able to retry without relaunching after the user resolves the issue.

## Permission UX States

- `unknown`: Show Start as available, then request required permissions from the system during `preparing`.
- `requesting`: Keep controls disabled except Cancel if implemented; do not create a committed recording until permissions and sources are ready.
- `granted`: Continue into capture. The app may remember this state as a hint, but the OS remains source of truth.
- `denied`: Move to `failed`, explain which permission is missing, and offer the shortest path to macOS Settings.
- `restricted`: Treat as non-recoverable in-app. Explain that policy or device management blocks capture.
- `source unavailable`: Distinguish permission from no usable device, muted virtual source, unsupported system audio API, or ScreenCaptureKit failure.
- `revoked while recording`: Stop capture, finalize whatever derived metadata is valid, delete raw buffers, and surface a retryable failure.

The first slice should prefer one clear permission flow over custom onboarding. macOS dialogs are already plenty of ceremony; adding another wizard would be how software turns into paperwork.

## Failure Modes

- Microphone permission denied, restricted, revoked, or not present.
- System audio capture denied, restricted, unavailable on the OS version, or rejected by ScreenCaptureKit.
- Input device disappears, changes format, or reports silence/zero frames after start.
- System audio source disappears when display, app, or virtual device topology changes.
- Capture engine receives `alreadyRunning`; UI must not create a second session.
- Disk write fails, storage is full, target directory is unavailable, or metadata write succeeds while chunk write fails.
- App crashes, is force quit, sleeps, wakes, or loses audio session while recording.
- Stop is requested while `preparing`, `processing`, or after a previous stop.
- Clock changes during recording; duration should derive from monotonic capture timing where precision matters.
- Persistence replay finds an incomplete session, missing chunks, duplicate sequence numbers, or a session without `endedAt`.

## Test Matrix

| Area | Required coverage |
| --- | --- |
| Core state | Start/stop transitions, retry after failure, idempotent stop, no concurrent sessions. |
| Configuration | Default capture includes mic and system audio; downgraded capture is explicit and persisted. |
| Permissions | Unknown -> granted, unknown -> denied, previously denied retry, revoked while recording. |
| Audio ordering | Per-track sequence numbers are monotonic, unique, and tied to the session ID. |
| Partial failure | Mic-only, system-only, and neither-source-available behavior are deliberate and asserted. |
| Persistence | Session saved on start, finalized on stop, recoverable after crash, orphan cleanup behavior. |
| Privacy | Raw buffers are deleted after derived artifacts are produced; no raw audio enters logs. |
| UI | Buttons reflect `preparing`, `recording`, `processing`, and `failed`; errors name the failed source. |
| Platform | Supported macOS version, unsupported system-audio API path, device hot-swap, sleep/wake. |

Prefer unit tests for state and persistence contracts, plus focused integration tests around audio-source availability. Manual QA is acceptable for system permission dialogs, but record the exact macOS version and reset commands used.

## Privacy and No-Raw-Audio Constraints

- Raw audio is transient implementation detail. Do not persist it longer than needed to produce the next approved artifact.
- Do not log raw samples, file paths containing meeting titles, transcript snippets from live buffers, device names that may identify a person, or permission prompt contents.
- Persist metadata needed for recovery: session ID, start/end timestamps, selected source flags, chunk ordering, derived artifact references, and failure reason codes.
- If temporary audio chunks are required, store them under an app-controlled temporary location, associate them with the session ID, and delete them on successful processing, failed processing, cancellation, or recovery cleanup.
- Never upload raw audio in this vertical slice. Any future network transcription path needs a separate design review.
- User-visible failure text should be specific about app behavior without exposing private capture details.

## What Not To Build Yet

- No cloud transcription, summarization, speaker diarization, or account sync.
- No searchable recording library beyond the minimum metadata needed to recover or display the just-recorded session.
- No timeline editor, waveform UI, clip export, or raw audio playback.
- No custom permission onboarding, preference panes, device picker, or source mixer unless required to unblock capture.
- No background menu-bar automation beyond explicit Start and Stop.
- No retention policy UI; implement hardcoded deletion for temporary raw audio first.
- No clever silence detection, meeting-title inference, calendar linking, or participant detection.

## Parallel Implementation Contracts

- Core owns the session state machine and must reject invalid transitions before audio or persistence side effects run.
- Audio owns permission checks, source startup, per-track chunk ordering, and deterministic teardown.
- Persistence owns metadata durability, incomplete-session recovery, and raw-audio cleanup records.
- UI owns truthful state display and actionable errors, but should not infer capture success from optimistic state alone.

When contracts conflict, prefer failing before capture starts over creating ambiguous recordings. A short, honest failure is easier to fix than a meeting that looks recorded and is not.

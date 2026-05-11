# V1 Transcription Pass

Scope: the first end-to-end Barn Owl path that turns a completed local recording into a meeting artifact. V1 should prove the whole workflow with clear failure states and privacy-preserving cleanup before adding richer editing, search, sync, or automation.

## Desired End-to-End Path

1. Capture chunks
   - Start from a single `RecordingSession` created by the recording vertical slice.
   - Capture microphone and system audio into session-scoped temporary chunks.
   - Preserve deterministic chunk metadata: session ID, source kind, sequence number, start/end timing, file location, and write/finalization state.
   - Reject or explicitly mark partial capture. The default meeting path must not silently lose either source.

2. Diarized transcription
   - Read finalized chunks in deterministic order.
   - Submit audio for transcription with speaker diarization enabled or attach speaker labels from the best available V1 diarization pass.
   - Produce `TranscriptSegment` values with speaker label, text, start time, end time, and confidence when available.
   - Merge chunk-level transcript output into one monotonic transcript for the session.

3. Quality review
   - Validate that transcript segments are non-empty, ordered, and tied to the expected session.
   - Flag low-confidence segments, missing speaker labels, large timestamp gaps, overlapping segments, duplicate chunk sequence numbers, and transcription failures.
   - Decide whether the artifact is publishable, publishable-with-warnings, or failed.
   - Keep the review result available to the user or logs without storing raw audio or sensitive transcript excerpts in diagnostic logs.

4. Summary and actions
   - Generate a concise meeting summary from the reviewed transcript.
   - Extract decisions, action items, and open questions.
   - Preserve action wording well enough that a user can understand owner, task, and deadline when stated in the meeting.
   - If summary generation fails after a valid transcript exists, keep the transcript artifact and surface summary failure as a retryable processing error.

5. Local Markdown and library
   - Render one Markdown meeting artifact containing title, start time, summary, decisions, action items, open questions, and diarized transcript.
   - Save the artifact in the local library with stable metadata linking it to the recording session.
   - Make the saved artifact discoverable in the local library without requiring raw audio.
   - Preserve enough metadata for recovery and deduplication if the app crashes during artifact write.

6. Cleanup
   - Delete temporary raw audio chunks after transcription and artifact persistence succeed.
   - On failed transcription, cancellation, crash recovery, or partial artifact write, delete raw audio unless a deliberate retry queue owns the files with explicit retention limits.
   - Mark cleanup completion in metadata so recovery can distinguish "needs cleanup" from "already cleaned".

## V1 Acceptance Criteria

- A user can record a meeting, stop recording, and receive a local Markdown artifact without manually moving files between subsystems.
- The transcript includes diarized speaker labels for each segment, even if V1 labels are generic labels such as `Speaker 1`.
- Transcript segments are ordered by recording time across all processed chunks.
- The artifact includes summary overview, decisions, action items, open questions, and the full diarized transcript.
- Action items render in Markdown under an `Action Items` section when present.
- The local library stores the Markdown artifact and enough session metadata to find it again after relaunch.
- Temporary raw audio chunks are deleted after successful artifact persistence.
- Any failed API call leaves the app in a retryable or failed state with no ambiguous "complete" artifact.
- Permission or source failures before usable audio is captured do not create empty meeting artifacts.
- Processing failure after transcription preserves the highest valid derived artifact that is safe to retain.
- Logs and persisted diagnostics do not include raw audio samples or long transcript excerpts.
- Recovery can clean stale temporary chunks from interrupted processing without deleting completed Markdown artifacts.

## Risks

- Diarization accuracy: speaker labels may be wrong, unstable across chunks, or split one person into multiple labels. V1 needs visible generic labels and should avoid claiming identity unless explicitly known.
- Chunk ordering: parallel capture and async processing can reorder chunks. Sequence numbers and time ranges must be validated before transcription merge, because shuffled meetings are less useful than no meeting and more irritating.
- Raw audio retention: retries can accidentally become indefinite raw-audio storage. Any retry queue must have explicit ownership, retention limits, and cleanup on success, failure, cancellation, and recovery.
- Permissions: microphone and system-audio permissions can be denied, revoked, or require relaunch. The pipeline must distinguish permission failure from transcription failure and must not create empty artifacts from denied starts.
- API failure handling: transcription, diarization, quality review, and summary calls can fail independently. V1 should keep valid derived outputs, surface the failed stage, and avoid marking the full pass complete until the Markdown/library write and cleanup are done.

## Current Gaps To Close

- No documented contract yet for how chunk metadata is handed from capture/persistence into transcription.
- No explicit quality-review model or result state is defined.
- No documented retry policy for API failures or interrupted processing.
- No retention policy for raw audio that is waiting on retry.
- No end-to-end test currently proves capture chunks become a persisted Markdown library artifact and then trigger cleanup.
- Renderer coverage should include action items in addition to the existing summary and transcript assertions.

## Focused Test Strategy

- Unit test Markdown rendering for transcript, summary, and action sections.
- Unit test transcript merge ordering with out-of-order chunk inputs before connecting real API calls.
- Unit test quality-review classification for empty, overlapping, low-confidence, and missing-speaker segments.
- Integration test the processing coordinator with fake transcription, fake summary, local persistence, and temp chunk cleanup.
- Manual QA the real permission and audio-capture path on macOS, then use fake APIs for deterministic artifact validation.

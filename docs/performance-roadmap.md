# Performance Roadmap

Barn Owl now has lightweight performance instrumentation for the recording and
final-processing path. The core metric types are app-agnostic: they describe
milestones, phase boundaries, temp audio byte samples, and cleanup timing without
coupling to UI, persistence, or OpenAI clients.

| Item | Acceptance criteria | Target metric | Current status |
| --- | --- | --- | --- |
| 1. Capture start milestone | Every accepted recording session emits `captureStarted` before audio sources begin producing chunks. | Event present for 100% of successful starts. | Implemented in `BarnOwlAppModel.startRecording()`. |
| 2. First audio chunk latency | Every successful capture emits `firstAudioChunkCaptured`; summary reports `captureLatency`. | p95 under 750 ms from start to first chunk. | Implemented when the first persisted audio chunk is reported. |
| 3. Capture stop milestone | Stopping a recording emits `captureStopped` before transcription work begins. | Event present for 100% of completed recordings. | Implemented in `BarnOwlAppModel.stopRecording()`. |
| 4. Transcription start milestone | Transcription work emits `transcriptionStarted` when final transcription starts. | Gap from capture stop to transcription start p95 under 1.5 s. | Implemented from final-processing progress updates. |
| 5. First transcript latency | First partial or completed final transcript emits `firstTranscriptReceived`; summary reports `firstTranscriptLatency`. | p95 under 8 s from transcription start. | Implemented when final transcript preview first appears. |
| 6. Final transcript duration | Final transcript emits `finalTranscriptReceived`; summary reports `finalTranscriptDuration`. | p95 under 90 s for 30-minute recordings. | Implemented when final processing succeeds. |
| 7. Realtime preview timing | Realtime preview emits start, first transcript, and finished events. | First realtime transcript visible within a few seconds on healthy network/audio. | Implemented for live preview responsiveness tracking. |
| 8. Final processing duration | Final processing emits phase start/finish boundaries. | p95 should stay within expected transcription/model latency for meeting length. | Implemented and summarized as `finalProcessingDuration`. |
| 9. Temp audio bytes | Temp audio storage emits byte samples; summary reports max and final byte counts. | Final bytes return to 0 after successful cleanup; peak stays below available disk guardrail. | Implemented on chunk writes and successful temp audio finalization. |
| 10. Cleanup duration | Cleanup emits `cleanup` phase start/finish; summary reports `cleanupDuration`. | p95 under 3 s and completed for 100% of successful terminal sessions. | Implemented around temp audio finalization. |
| 11. Tokenization phase timing | Token/prompt preparation emits `tokenization` phase start/finish boundaries. | p95 under 2 s for summary prompt preparation. | Not wired yet; keep as a future targeted instrumentation pass. |
| 12. Model request phase timing | Final diarization chunks and summary generation emit `modelRequest` phase boundaries with model name. | p95 under 30 s for summary requests; p95 under 75 s for transcription requests. | Implemented for final diarization and summary generation; overlap repair remains covered by end-to-end final-processing timing. |

## Implementation Notes

- Keep emission at orchestration boundaries so `BarnOwlCore` remains a pure metrics vocabulary and aggregator.
- Persist raw events before reducing them if performance history becomes a product requirement; current builds keep a live per-session summary only.
- Treat missing durations as instrumentation gaps, not zeroes. Zero means the event pair was measured and effectively instant.
- Add dashboarding only after raw event coverage is complete; premature charts are just decorative ambiguity with axes.

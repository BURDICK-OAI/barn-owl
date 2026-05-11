import BarnOwlCore
import Testing

@Test
func aggregationComputesCoreDurationsFromMilestones() {
    let events: [PerformanceMetricEvent] = [
        .milestone(.finalTranscriptReceived, at: 12),
        .milestone(.captureStarted, at: 1),
        .milestone(.firstAudioChunkCaptured, at: 2.25),
        .milestone(.captureStopped, at: 3.5),
        .tempAudioBytes(1024, at: 3),
        .milestone(.transcriptionStarted, at: 4),
        .tempAudioBytes(4096, at: 5),
        .milestone(.firstTranscriptReceived, at: 6.5),
        .tempAudioBytes(2048, at: 11)
    ]

    let summary = PerformanceMetrics.aggregate(events)

    #expect(summary.eventCount == 9)
    #expect(summary.captureLatency == 1.25)
    #expect(summary.firstTranscriptLatency == 2.5)
    #expect(summary.finalTranscriptDuration == 8)
    #expect(summary.maxTempAudioBytes == 4096)
    #expect(summary.finalTempAudioBytes == 2048)
}

@Test
func aggregationComputesRealtimeAndFinalProcessingDurations() {
    let events: [PerformanceMetricEvent] = [
        .phase(.capture, .started, at: 1),
        .phase(.capture, .finished, at: 11),
        .phase(.realtimePreview, .started, at: 2, model: "gpt-realtime-whisper"),
        .milestone(.realtimePreviewStarted, at: 2),
        .milestone(.firstRealtimeTranscriptReceived, at: 4.5),
        .phase(.realtimePreview, .finished, at: 10, model: "gpt-realtime-whisper"),
        .phase(.finalProcessing, .started, at: 12),
        .phase(.finalProcessing, .finished, at: 22)
    ]

    let summary = PerformanceMetrics.aggregate(events)

    #expect(summary.captureDuration == 10)
    #expect(summary.realtimePreviewLatency == 2.5)
    #expect(summary.realtimePreviewDuration == 8)
    #expect(summary.finalProcessingDuration == 10)
}

@Test
func aggregationPairsPhaseBoundariesByPhaseAndModel() {
    let transcriptKey = PerformancePhaseKey(
        phase: .modelRequest,
        model: "gpt-4.1-transcribe"
    )
    let summaryKey = PerformancePhaseKey(
        phase: .modelRequest,
        model: "gpt-4.1-mini"
    )
    let events: [PerformanceMetricEvent] = [
        .phase(.modelRequest, .started, at: 1, model: "gpt-4.1-transcribe"),
        .phase(.modelRequest, .started, at: 2, model: "gpt-4.1-mini"),
        .phase(.modelRequest, .finished, at: 5, model: "gpt-4.1-transcribe"),
        .phase(.modelRequest, .finished, at: 7, model: "gpt-4.1-mini"),
        .phase(.modelRequest, .started, at: 10, model: "gpt-4.1-transcribe"),
        .phase(.modelRequest, .finished, at: 13, model: "gpt-4.1-transcribe")
    ]

    let summary = PerformanceMetrics.aggregate(events)

    #expect(summary.phaseDurations.count == 3)
    #expect(summary.totalDuration(for: transcriptKey) == 7)
    #expect(summary.totalDuration(for: summaryKey) == 5)
}

@Test
func cleanupDurationUsesCompletedCleanupPhasesOnly() {
    let events: [PerformanceMetricEvent] = [
        .phase(.cleanup, .started, at: 20),
        .phase(.cleanup, .finished, at: 23),
        .phase(.cleanup, .finished, at: 24),
        .phase(.cleanup, .started, at: 25)
    ]

    let summary = PerformanceMetrics.aggregate(events)

    #expect(summary.cleanupDuration == 3)
    #expect(summary.phaseDurations == [
        PerformancePhaseDuration(
            key: PerformancePhaseKey(phase: .cleanup),
            startedAt: 20,
            finishedAt: 23
        )
    ])
}

@Test
func accumulatorRecordsEventsAndSummarizesDeterministically() {
    var accumulator = PerformanceMetricAccumulator()

    accumulator.record(.milestone(.captureStarted, at: 10))
    accumulator.record(.milestone(.firstAudioChunkCaptured, at: 10.5))
    accumulator.record(.milestone(.transcriptionStarted, at: 12))
    accumulator.record(.milestone(.firstTranscriptReceived, at: 15))
    accumulator.record(.milestone(.finalTranscriptReceived, at: 18))

    let summary = accumulator.summary()

    #expect(accumulator.events.count == 5)
    #expect(summary.captureLatency == 0.5)
    #expect(summary.firstTranscriptLatency == 3)
    #expect(summary.finalTranscriptDuration == 6)
}

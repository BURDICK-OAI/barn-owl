import BarnOwlCore
import BarnOwlTranscription
import Foundation
import Testing

@Test
func pipelineMapsAudioFileTranscriptionSegments() async throws {
    let audioFile = RecordedAudioFile(
        url: URL(fileURLWithPath: "/tmp/microphone.wav"),
        trackLabel: "Microphone",
        startTimeOffset: 30
    )
    let pipeline = FinalTranscriptionPipeline(
        transcriptionClient: StubAudioFileTranscriptionClient(responses: [
            audioFile.url: AudioFileTranscriptionResponse(segments: [
                AudioFileTranscriptionSegment(
                    speakerLabel: " Speaker 1 ",
                    text: "  We should ship this.  ",
                    startTime: 1.5,
                    endTime: 3.25,
                    confidence: 0.91
                )
            ])
        ])
    )

    let result = try await pipeline.run(
        session: makeSession(),
        audioFiles: [audioFile]
    )

    #expect(result.segments.count == 1)
    #expect(result.segments.first?.speakerLabel == "Room Speaker A")
    #expect(result.segments.first?.text == "We should ship this.")
    #expect(result.segments.first?.startTime == 31.5)
    #expect(result.segments.first?.endTime == 33.25)
    #expect(result.segments.first?.confidence == 0.91)
}

@Test
func pipelineUsesSourceScopedProvisionalSpeakerLabels() async throws {
    let audioFile = RecordedAudioFile(
        url: URL(fileURLWithPath: "/tmp/system.wav"),
        trackLabel: "System Audio"
    )
    let pipeline = FinalTranscriptionPipeline(
        transcriptionClient: StubAudioFileTranscriptionClient(responses: [
            audioFile.url: AudioFileTranscriptionResponse(segments: [
                AudioFileTranscriptionSegment(speakerLabel: nil, text: "First", startTime: 0, endTime: 1),
                AudioFileTranscriptionSegment(speakerLabel: "  ", text: "Second", startTime: 1, endTime: 2),
                AudioFileTranscriptionSegment(speakerLabel: "Customer", text: "Third", startTime: 2, endTime: 3)
            ])
        ])
    )

    let result = try await pipeline.run(
        session: makeSession(),
        audioFiles: [audioFile]
    )

    #expect(result.segments.map(\.speakerLabel) == ["Call Speaker A", "Call Speaker A", "Call Speaker B"])
}

@Test
func pipelineLabelsRoomAndCallSpeakersWithoutAssumingMicrophoneIsYou() async throws {
    let microphone = RecordedAudioFile(
        url: URL(fileURLWithPath: "/tmp/microphone.wav"),
        trackLabel: "Microphone",
        trackID: "microphone"
    )
    let systemAudio = RecordedAudioFile(
        url: URL(fileURLWithPath: "/tmp/system.wav"),
        trackLabel: "System Audio",
        trackID: "systemAudio"
    )
    let pipeline = FinalTranscriptionPipeline(
        transcriptionClient: StubAudioFileTranscriptionClient(responses: [
            microphone.url: AudioFileTranscriptionResponse(segments: [
                AudioFileTranscriptionSegment(speakerLabel: "You", text: "Room first.", startTime: 0, endTime: 1),
                AudioFileTranscriptionSegment(speakerLabel: "speaker_1", text: "Room second.", startTime: 3, endTime: 4)
            ]),
            systemAudio.url: AudioFileTranscriptionResponse(segments: [
                AudioFileTranscriptionSegment(speakerLabel: "speaker_0", text: "Call first.", startTime: 1, endTime: 2)
            ])
        ])
    )

    let result = try await pipeline.run(
        session: makeSession(),
        audioFiles: [microphone, systemAudio]
    )

    #expect(result.segments.map(\.speakerLabel) == [
        "Room Speaker A",
        "Call Speaker A",
        "Room Speaker B"
    ])
    #expect(!result.segments.map(\.speakerLabel).contains("You"))
}

@Test
func pipelinePreservesRealCrossSourceCrosstalkAndInterjections() async throws {
    let microphone = RecordedAudioFile(
        url: URL(fileURLWithPath: "/tmp/microphone-crosstalk.wav"),
        trackLabel: "Microphone",
        trackID: "microphone"
    )
    let systemAudio = RecordedAudioFile(
        url: URL(fileURLWithPath: "/tmp/system-crosstalk.wav"),
        trackLabel: "System Audio",
        trackID: "systemAudio"
    )
    let pipeline = FinalTranscriptionPipeline(
        transcriptionClient: StubAudioFileTranscriptionClient(responses: [
            microphone.url: AudioFileTranscriptionResponse(segments: [
                AudioFileTranscriptionSegment(speakerLabel: "speaker_0", text: "Yes.", startTime: 10.1, endTime: 10.4)
            ]),
            systemAudio.url: AudioFileTranscriptionResponse(segments: [
                AudioFileTranscriptionSegment(
                    speakerLabel: "speaker_0",
                    text: "The launch window is still Friday.",
                    startTime: 10,
                    endTime: 12
                )
            ])
        ])
    )

    let result = try await pipeline.run(
        session: makeSession(),
        audioFiles: [microphone, systemAudio]
    )

    #expect(result.segments.map(\.speakerLabel) == ["Call Speaker A", "Room Speaker A"])
    #expect(result.segments.map(\.text) == ["The launch window is still Friday.", "Yes."])
}

@Test
func pipelineRemovesClearCrossTrackAudioBleedDuplicate() async throws {
    let microphone = RecordedAudioFile(
        url: URL(fileURLWithPath: "/tmp/microphone-bleed.wav"),
        trackLabel: "Microphone",
        trackID: "microphone"
    )
    let systemAudio = RecordedAudioFile(
        url: URL(fileURLWithPath: "/tmp/system-bleed.wav"),
        trackLabel: "System Audio",
        trackID: "systemAudio"
    )
    let duplicateText = "We should ship the rollout plan today."
    let pipeline = FinalTranscriptionPipeline(
        transcriptionClient: StubAudioFileTranscriptionClient(responses: [
            microphone.url: AudioFileTranscriptionResponse(segments: [
                AudioFileTranscriptionSegment(
                    speakerLabel: "speaker_0",
                    text: duplicateText,
                    startTime: 20.1,
                    endTime: 22.1,
                    confidence: 0.72
                )
            ]),
            systemAudio.url: AudioFileTranscriptionResponse(segments: [
                AudioFileTranscriptionSegment(
                    speakerLabel: "speaker_0",
                    text: duplicateText,
                    startTime: 20,
                    endTime: 22,
                    confidence: 0.96
                )
            ])
        ])
    )

    let result = try await pipeline.run(
        session: makeSession(),
        audioFiles: [microphone, systemAudio]
    )

    #expect(result.segments.count == 1)
    #expect(result.segments[0].speakerLabel == "Call Speaker A")
    #expect(result.segments[0].text == duplicateText)
}

@Test
func pipelineSortsSegmentsChronologicallyAcrossFiles() async throws {
    let lateFile = RecordedAudioFile(
        url: URL(fileURLWithPath: "/tmp/late.wav"),
        trackLabel: "Late",
        startTimeOffset: 20
    )
    let earlyFile = RecordedAudioFile(
        url: URL(fileURLWithPath: "/tmp/early.wav"),
        trackLabel: "Early",
        startTimeOffset: 0
    )
    let pipeline = FinalTranscriptionPipeline(
        transcriptionClient: StubAudioFileTranscriptionClient(responses: [
            lateFile.url: AudioFileTranscriptionResponse(segments: [
                AudioFileTranscriptionSegment(text: "Third", startTime: 1, endTime: 2),
                AudioFileTranscriptionSegment(text: "Second", startTime: 0, endTime: 1)
            ]),
            earlyFile.url: AudioFileTranscriptionResponse(segments: [
                AudioFileTranscriptionSegment(text: "First", startTime: 5, endTime: 6)
            ])
        ])
    )

    let result = try await pipeline.run(
        session: makeSession(),
        audioFiles: [lateFile, earlyFile]
    )

    #expect(result.segments.map(\.text) == ["First", "Second", "Third"])
    #expect(result.segments.map(\.startTime) == [5, 20, 21])
}

@Test
func noOpReviewerReturnsSegmentsUnchanged() async throws {
    let segments = [
        TranscriptSegment(
            speakerLabel: "Speaker 1",
            text: "No edits needed.",
            startTime: 0,
            endTime: 1,
            confidence: 0.8
        )
    ]
    let reviewer = NoOpTranscriptQualityReviewer()

    let reviewedSegments = try await reviewer.review(
        segments: segments,
        context: ["agenda"]
    )

    #expect(reviewedSegments == segments)
}

@Test
func sanitizingReviewerDropsEmptySegmentsAndMergesAdjacentSpeakerTurns() async throws {
    let reviewer = TranscriptSanitizingQualityReviewer()

    let reviewedSegments = try await reviewer.review(
        segments: [
            TranscriptSegment(
                speakerLabel: " Speaker 1 ",
                text: "  First thought. ",
                startTime: -1,
                endTime: 1,
                confidence: 0.8
            ),
            TranscriptSegment(
                speakerLabel: "Speaker 1",
                text: "Second thought.",
                startTime: 1.8,
                endTime: 3,
                confidence: 1.0
            ),
            TranscriptSegment(
                speakerLabel: "Speaker 1",
                text: "Third thought after a chunk boundary.",
                startTime: 8,
                endTime: 9,
                confidence: 0.6
            ),
            TranscriptSegment(
                speakerLabel: "Speaker 2",
                text: "   ",
                startTime: 4,
                endTime: 5
            )
        ],
        context: []
    )

    #expect(reviewedSegments.count == 1)
    #expect(reviewedSegments[0].speakerLabel == "Speaker 1")
    #expect(reviewedSegments[0].text == "First thought. Second thought. Third thought after a chunk boundary.")
    #expect(reviewedSegments[0].startTime == 0)
    #expect(reviewedSegments[0].endTime == 9)
    #expect(reviewedSegments[0].confidence == 0.75)
}

@Test
func pipelineCreatesMarkdownReadySummaryPlaceholder() async throws {
    let audioFile = RecordedAudioFile(
        url: URL(fileURLWithPath: "/tmp/microphone.wav"),
        trackLabel: "Microphone"
    )
    let session = makeSession(title: "Planning Review")
    let pipeline = FinalTranscriptionPipeline(
        transcriptionClient: StubAudioFileTranscriptionClient(responses: [
            audioFile.url: AudioFileTranscriptionResponse(segments: [
                AudioFileTranscriptionSegment(text: "Ship the pipeline.", startTime: 0, endTime: 2)
            ])
        ])
    )

    let result = try await pipeline.run(
        session: session,
        audioFiles: [audioFile]
    )

    #expect(result.summary.overview == "Summary generation pending for Planning Review. Transcript contains 1 segment(s).")
    #expect(result.summary.decisions.isEmpty)
    #expect(result.summary.actionItems.isEmpty)
    #expect(result.summary.openQuestions.isEmpty)
}

@Test
func pipelineUsesInjectedSummaryGenerator() async throws {
    let audioFile = RecordedAudioFile(
        url: URL(fileURLWithPath: "/tmp/microphone.wav"),
        trackLabel: "Microphone"
    )
    let pipeline = FinalTranscriptionPipeline(
        transcriptionClient: StubAudioFileTranscriptionClient(responses: [
            audioFile.url: AudioFileTranscriptionResponse(segments: [
                AudioFileTranscriptionSegment(text: "Ship the app.", startTime: 0, endTime: 1)
            ])
        ]),
        summaryGenerator: StubSummaryGenerator(
            summary: MeetingSummary(
                overview: "Real summary.",
                decisions: ["Ship it."],
                actionItems: ["Run QA."],
                openQuestions: ["What next?"]
            )
        )
    )

    let result = try await pipeline.run(
        session: makeSession(),
        audioFiles: [audioFile],
        context: ["roadmap"]
    )

    #expect(result.summary.overview == "Real summary.")
    #expect(result.summary.decisions == ["Ship it."])
    #expect(result.summary.actionItems == ["Run QA."])
    #expect(result.summary.openQuestions == ["What next?"])
}

@Test
func cachedTranscriptionClientUsesCompletedCacheWithoutCallingWrappedClient() async throws {
    let sessionID = UUID()
    let audioFile = RecordedAudioFile(
        url: URL(fileURLWithPath: "/tmp/cached.wav"),
        trackLabel: "Microphone",
        sequenceNumber: 0,
        trackID: "microphone"
    )
    let cachedResponse = AudioFileTranscriptionResponse(segments: [
        AudioFileTranscriptionSegment(text: "Already done.", startTime: 0, endTime: 1)
    ])
    let cache = InMemoryRollingCache(completed: [
        RollingFinalTranscriptionKey(sessionID: sessionID, trackID: "microphone", sequenceNumber: 0): cachedResponse
    ])
    let wrapped = CountingAudioFileTranscriptionClient(response: AudioFileTranscriptionResponse(segments: []))
    let client = CachedAudioFileTranscriptionClient(
        sessionID: sessionID,
        wrapped: wrapped,
        cacheStore: cache
    )

    let response = try await client.transcribe(audioFile: audioFile)

    #expect(response == cachedResponse)
    #expect(await wrapped.callCount == 0)
}

@Test
func cachedTranscriptionClientFallsBackAndStoresMissingCacheResult() async throws {
    let sessionID = UUID()
    let audioFile = RecordedAudioFile(
        url: URL(fileURLWithPath: "/tmp/missing.wav"),
        trackLabel: "Microphone",
        sequenceNumber: 1,
        trackID: "microphone"
    )
    let response = AudioFileTranscriptionResponse(segments: [
        AudioFileTranscriptionSegment(text: "Fresh result.", startTime: 0, endTime: 1)
    ])
    let cache = InMemoryRollingCache()
    let wrapped = CountingAudioFileTranscriptionClient(response: response)
    let client = CachedAudioFileTranscriptionClient(
        sessionID: sessionID,
        wrapped: wrapped,
        cacheStore: cache
    )

    let returned = try await client.transcribe(audioFile: audioFile)
    let key = RollingFinalTranscriptionKey(sessionID: sessionID, trackID: "microphone", sequenceNumber: 1)

    #expect(returned == response)
    #expect(await wrapped.callCount == 1)
    #expect(try await cache.completedResponse(for: key) == response)
}

@Test
func cachedTranscriptionClientIgnoresCompletedCacheFromDifferentModel() async throws {
    let sessionID = UUID()
    let key = RollingFinalTranscriptionKey(sessionID: sessionID, trackID: "microphone", sequenceNumber: 3)
    let audioFile = RecordedAudioFile(
        url: URL(fileURLWithPath: "/tmp/model-change.wav"),
        trackLabel: "Microphone",
        sequenceNumber: 3,
        trackID: "microphone"
    )
    let staleResponse = AudioFileTranscriptionResponse(segments: [
        AudioFileTranscriptionSegment(text: "Stale result.", startTime: 0, endTime: 1)
    ])
    let freshResponse = AudioFileTranscriptionResponse(segments: [
        AudioFileTranscriptionSegment(text: "Fresh model result.", startTime: 0, endTime: 1)
    ])
    let cache = InMemoryRollingCache(
        completed: [key: staleResponse],
        modelIdentifiers: [key: "old-model"]
    )
    let wrapped = CountingAudioFileTranscriptionClient(response: freshResponse)
    let client = CachedAudioFileTranscriptionClient(
        sessionID: sessionID,
        wrapped: wrapped,
        cacheStore: cache,
        modelIdentifier: "new-model"
    )

    let returned = try await client.transcribe(audioFile: audioFile)

    #expect(returned == freshResponse)
    #expect(await wrapped.callCount == 1)
    #expect(try await cache.completedResponse(for: key, modelIdentifier: "new-model") == freshResponse)
    #expect(try await cache.completedResponse(for: key, modelIdentifier: "old-model") == nil)
}

@Test
func cachedTranscriptionClientRetriesFailedCacheResult() async throws {
    let sessionID = UUID()
    let audioFile = RecordedAudioFile(
        url: URL(fileURLWithPath: "/tmp/failed.wav"),
        trackLabel: "Microphone",
        sequenceNumber: 2,
        trackID: "microphone"
    )
    let key = RollingFinalTranscriptionKey(sessionID: sessionID, trackID: "microphone", sequenceNumber: 2)
    let response = AudioFileTranscriptionResponse(segments: [
        AudioFileTranscriptionSegment(text: "Retried result.", startTime: 0, endTime: 1)
    ])
    let cache = InMemoryRollingCache(statuses: [key: .failed])
    let wrapped = CountingAudioFileTranscriptionClient(response: response)
    let client = CachedAudioFileTranscriptionClient(
        sessionID: sessionID,
        wrapped: wrapped,
        cacheStore: cache
    )

    let returned = try await client.transcribe(audioFile: audioFile)

    #expect(returned == response)
    #expect(await wrapped.callCount == 1)
    #expect(try await cache.completedResponse(for: key) == response)
}

@Test
func rollingCoordinatorEnqueueReturnsWithoutWaitingForSlowTranscription() async throws {
    let sessionID = UUID()
    let audioFile = RecordedAudioFile(
        url: URL(fileURLWithPath: "/tmp/slow.wav"),
        trackLabel: "Microphone",
        sequenceNumber: 0,
        trackID: "microphone"
    )
    let gate = SlowTranscriptionGate()
    let client = SlowAudioFileTranscriptionClient(gate: gate)
    let cache = InMemoryRollingCache()
    let coordinator = RollingFinalTranscriptionCoordinator(
        sessionID: sessionID,
        transcriptionClient: client,
        cacheStore: cache,
        maxConcurrentTranscriptions: 1
    )

    await coordinator.enqueue(audioFile)

    #expect(await gate.didStart)
    #expect(try await cache.completedResponse(for: RollingFinalTranscriptionKey(
        sessionID: sessionID,
        trackID: "microphone",
        sequenceNumber: 0
    )) == nil)

    await gate.release()
    await coordinator.finishAndDrain(timeout: .seconds(1))

    #expect(await client.callCount == 1)
}

@Test
func rollingCoordinatorIgnoresDuplicateChunkIdentity() async throws {
    let sessionID = UUID()
    let audioFile = RecordedAudioFile(
        url: URL(fileURLWithPath: "/tmp/duplicate.wav"),
        trackLabel: "Microphone",
        sequenceNumber: 0,
        trackID: "microphone"
    )
    let client = CountingAudioFileTranscriptionClient(response: AudioFileTranscriptionResponse(segments: [
        AudioFileTranscriptionSegment(text: "Once.", startTime: 0, endTime: 1)
    ]))
    let cache = InMemoryRollingCache()
    let coordinator = RollingFinalTranscriptionCoordinator(
        sessionID: sessionID,
        transcriptionClient: client,
        cacheStore: cache,
        maxConcurrentTranscriptions: 1
    )

    await coordinator.enqueue(audioFile)
    await coordinator.enqueue(audioFile)
    await coordinator.finishAndDrain(timeout: .seconds(1))

    #expect(await client.callCount == 1)
}

private func makeSession(title: String = "Pipeline Review") -> RecordingSession {
    RecordingSession(
        title: title,
        startedAt: Date(timeIntervalSince1970: 0),
        audioSources: .defaultMeetingCapture
    )
}

private struct StubAudioFileTranscriptionClient: AudioFileTranscriptionClient {
    var responses: [URL: AudioFileTranscriptionResponse]

    func transcribe(audioFile: RecordedAudioFile) async throws -> AudioFileTranscriptionResponse {
        guard let response = responses[audioFile.url] else {
            throw StubTranscriptionError.missingResponse(audioFile.url)
        }

        return response
    }
}

private enum StubTranscriptionError: Error, Equatable {
    case missingResponse(URL)
}

private struct StubSummaryGenerator: MeetingSummaryGenerator {
    var summary: MeetingSummary

    func generateSummary(
        session: RecordingSession,
        segments: [TranscriptSegment],
        context: [String]
    ) async throws -> MeetingSummary {
        _ = session
        _ = segments
        _ = context
        return summary
    }
}

private actor InMemoryRollingCache: RollingFinalTranscriptionCacheStore {
    private var completed: [RollingFinalTranscriptionKey: AudioFileTranscriptionResponse]
    private var modelIdentifiers: [RollingFinalTranscriptionKey: String]
    private var statuses: [RollingFinalTranscriptionKey: RollingFinalTranscriptionStatus]

    init(
        completed: [RollingFinalTranscriptionKey: AudioFileTranscriptionResponse] = [:],
        statuses: [RollingFinalTranscriptionKey: RollingFinalTranscriptionStatus] = [:],
        modelIdentifiers: [RollingFinalTranscriptionKey: String] = [:]
    ) {
        self.completed = completed
        self.modelIdentifiers = modelIdentifiers
        self.statuses = statuses
        for key in completed.keys {
            self.statuses[key] = .completed
        }
    }

    func completedResponse(
        for key: RollingFinalTranscriptionKey,
        modelIdentifier: String?
    ) async throws -> AudioFileTranscriptionResponse? {
        guard statuses[key] == .completed else { return nil }
        if let modelIdentifier, modelIdentifiers[key] != modelIdentifier {
            return nil
        }
        return completed[key]
    }

    func markRunning(
        key: RollingFinalTranscriptionKey,
        audioFile: RecordedAudioFile,
        modelIdentifier: String?
    ) async throws -> Bool {
        _ = audioFile
        if statuses[key] == .completed,
           modelIdentifier == nil || modelIdentifiers[key] == modelIdentifier {
            return false
        }
        statuses[key] = .running
        if let modelIdentifier {
            modelIdentifiers[key] = modelIdentifier
        }
        return true
    }

    func markCompleted(
        key: RollingFinalTranscriptionKey,
        audioFile: RecordedAudioFile,
        modelIdentifier: String?,
        response: AudioFileTranscriptionResponse
    ) async throws {
        _ = audioFile
        statuses[key] = .completed
        completed[key] = response
        if let modelIdentifier {
            modelIdentifiers[key] = modelIdentifier
        }
    }

    func markFailed(
        key: RollingFinalTranscriptionKey,
        audioFile: RecordedAudioFile,
        modelIdentifier: String?,
        errorMessage: String
    ) async throws {
        _ = audioFile
        _ = errorMessage
        statuses[key] = .failed
        if let modelIdentifier {
            modelIdentifiers[key] = modelIdentifier
        }
    }
}

private actor CountingAudioFileTranscriptionClient: AudioFileTranscriptionClient {
    private let response: AudioFileTranscriptionResponse
    private(set) var callCount = 0

    init(response: AudioFileTranscriptionResponse) {
        self.response = response
    }

    func transcribe(audioFile: RecordedAudioFile) async throws -> AudioFileTranscriptionResponse {
        _ = audioFile
        callCount += 1
        return response
    }
}

private actor SlowTranscriptionGate {
    private var started = false
    private var released = false
    private var startContinuations: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuations: [CheckedContinuation<Void, Never>] = []

    var didStart: Bool {
        get async {
            if started { return true }
            await withCheckedContinuation { continuation in
                startContinuations.append(continuation)
            }
            return true
        }
    }

    func waitUntilReleased() async {
        started = true
        let continuations = startContinuations
        startContinuations = []
        continuations.forEach { $0.resume() }
        guard !released else { return }
        await withCheckedContinuation { continuation in
            releaseContinuations.append(continuation)
        }
    }

    func release() {
        released = true
        let continuations = releaseContinuations
        releaseContinuations = []
        continuations.forEach { $0.resume() }
    }
}

private actor SlowAudioFileTranscriptionClient: AudioFileTranscriptionClient {
    private let gate: SlowTranscriptionGate
    private(set) var callCount = 0

    init(gate: SlowTranscriptionGate) {
        self.gate = gate
    }

    func transcribe(audioFile: RecordedAudioFile) async throws -> AudioFileTranscriptionResponse {
        _ = audioFile
        callCount += 1
        await gate.waitUntilReleased()
        return AudioFileTranscriptionResponse(segments: [
            AudioFileTranscriptionSegment(text: "Slow result.", startTime: 0, endTime: 1)
        ])
    }
}

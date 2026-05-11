import BarnOwlCore
import BarnOwlTranscription
import Foundation
import Testing

@Test
func overlapStitchingManyChunkBoundariesCompletesWithinSmokeBudget() async {
    let transcriptions = (0..<120).map { sequence in
        let chunkStart = Double(sequence) * 55
        var segments: [TranscriptSegment] = [
            segment(
                "Speaker \(sequence % 4 + 1)",
                "Chunk \(sequence) body marker",
                chunkStart + 10,
                chunkStart + 12
            ),
            segment(
                "Speaker \(sequence % 4 + 1)",
                "Shared boundary \(sequence)",
                chunkStart + 54,
                chunkStart + 56
            )
        ]

        if sequence > 0 {
            segments.insert(
                segment(
                    "Speaker \((sequence - 1) % 4 + 1)",
                    "shared boundary \(sequence - 1)",
                    chunkStart + 0.2,
                    chunkStart + 1.2,
                    confidence: 0.9
                ),
                at: 0
            )
        }

        return transcribed(sequence: sequence, start: chunkStart, segments: segments)
    }

    let startedAt = Date()
    let result = await TranscriptOverlapStitcher().stitch(transcriptions: transcriptions)
    let elapsed = Date().timeIntervalSince(startedAt)

    #expect(result.segments.contains { $0.text == "Chunk 119 body marker" })
    #expect(result.decisions.contains { $0.kind == .duplicateRemoved })
    #expect(elapsed < 5)
}

@Test
func pipelineHonorsExplicitOverlappedStartOffsets() async throws {
    let first = RecordedAudioFile(
        url: URL(fileURLWithPath: "/tmp/first.wav"),
        trackLabel: "Microphone",
        startTimeOffset: 0,
        sequenceNumber: 0,
        trackID: "microphone",
        duration: 60,
        overlapDuration: nil
    )
    let second = RecordedAudioFile(
        url: URL(fileURLWithPath: "/tmp/second.wav"),
        trackLabel: "Microphone",
        startTimeOffset: 55,
        sequenceNumber: 1,
        trackID: "microphone",
        duration: 60,
        overlapDuration: nil
    )
    let pipeline = FinalTranscriptionPipeline(
        transcriptionClient: StubAudioFileTranscriptionClient(responses: [
            first.url: AudioFileTranscriptionResponse(segments: [
                AudioFileTranscriptionSegment(text: "first", startTime: 58, endTime: 59)
            ]),
            second.url: AudioFileTranscriptionResponse(segments: [
                AudioFileTranscriptionSegment(text: "second", startTime: 1, endTime: 2)
            ])
        ])
    )

    let result = try await pipeline.run(
        session: makeSession(),
        audioFiles: [first, second]
    )

    #expect(result.segments.map(\.startTime) == [56, 58])
    #expect(result.segments.map(\.text) == ["second", "first"])
}

@Test
func exactDuplicateOverlapIsRemoved() async {
    let result = await TranscriptOverlapStitcher().stitch(transcriptions: [
        transcribed(sequence: 0, start: 0, segments: [
            segment("Speaker 1", "We should ship this.", 55.0, 57.0, confidence: 0.8)
        ]),
        transcribed(sequence: 1, start: 55, segments: [
            segment("Speaker 1", "we should ship this", 55.1, 57.1, confidence: 0.9)
        ])
    ])

    #expect(result.segments.count == 1)
    #expect(result.segments[0].text == "we should ship this")
    #expect(result.decisions.contains { $0.kind == .duplicateRemoved })
}

@Test
func clippedSentenceAcrossOverlapIsMerged() async {
    let result = await TranscriptOverlapStitcher().stitch(transcriptions: [
        transcribed(sequence: 0, start: 0, segments: [
            segment("Speaker 1", "We should ship the", 54.4, 56.0)
        ]),
        transcribed(sequence: 1, start: 55, segments: [
            segment("Speaker 1", "the app tomorrow.", 55.3, 58.2)
        ])
    ])

    #expect(result.segments.map(\.text) == ["We should ship the app tomorrow."])
    #expect(result.segments.first?.speakerLabel == "Speaker 1")
    #expect(result.decisions.contains { $0.kind == .continuationMerged })
}

@Test
func speakerLabelContinuityIsPreservedWhenMergingObviousContinuation() async {
    let result = await TranscriptOverlapStitcher().stitch(transcriptions: [
        transcribed(sequence: 0, start: 0, segments: [
            segment("Dana", "The renewal risk is", 54.8, 56.1)
        ]),
        transcribed(sequence: 1, start: 55, segments: [
            segment("Dana", "pricing.", 55.8, 57.0)
        ])
    ])

    #expect(result.segments.count == 1)
    #expect(result.segments[0].speakerLabel == "Dana")
    #expect(result.segments[0].text == "The renewal risk is pricing.")
}

@Test
func materialConflictKeepsDeterministicResultAndRecordsConflict() async {
    let repairClient = StubOverlapRepairClient(response: TranscriptOverlapRepairResponse(
        segments: [segment("Speaker 2", "conflicting replacement", 55, 57)],
        conflict: true,
        reason: "material disagreement"
    ))
    let result = await TranscriptOverlapStitcher(repairClient: repairClient).stitch(transcriptions: [
        transcribed(sequence: 0, start: 0, segments: [
            segment("Speaker 1", "Keep the deterministic text", 54.8, 56.1)
        ]),
        transcribed(sequence: 1, start: 55, segments: [
            segment("Speaker 1", "text", 55.8, 57.0)
        ])
    ])

    #expect(result.segments.map(\.text) == ["Keep the deterministic text"])
    #expect(result.decisions.contains { $0.kind == .uncertainConflict })
}

@Test
func gptRepairCanReplaceDeterministicProposal() async {
    let repairClient = StubOverlapRepairClient(response: TranscriptOverlapRepairResponse(
        segments: [segment("Speaker 1", "Repaired exact boundary text.", 54.8, 57.0, confidence: 0.95)],
        conflict: false,
        reason: "validated repair"
    ))
    let result = await TranscriptOverlapStitcher(repairClient: repairClient).stitch(transcriptions: [
        transcribed(sequence: 0, start: 0, segments: [
            segment("Speaker 1", "Repaired exact", 54.8, 56.1)
        ]),
        transcribed(sequence: 1, start: 55, segments: [
            segment("Speaker 1", "boundary text.", 55.8, 57.0)
        ])
    ])

    #expect(result.segments.map(\.text) == ["Repaired exact boundary text."])
    #expect(result.decisions.contains { $0.kind == .gptRepaired })
}

@Test
func failingGPTRepairFallsBackToDeterministicProposal() async {
    let repairClient = StubOverlapRepairClient(error: StubError.failed)
    let result = await TranscriptOverlapStitcher(repairClient: repairClient).stitch(transcriptions: [
        transcribed(sequence: 0, start: 0, segments: [
            segment("Speaker 1", "We should ship the", 54.8, 56.1)
        ]),
        transcribed(sequence: 1, start: 55, segments: [
            segment("Speaker 1", "the app.", 55.8, 57.0)
        ])
    ])

    #expect(result.segments.map(\.text) == ["We should ship the app."])
    #expect(result.decisions.contains { $0.kind == .gptFailedFallback })
}

@Test
func gptOverlapRepairRunsWithBoundedConcurrencyAndFallsBackPerBoundary() async {
    let repairClient = RecordingOverlapRepairClient(failingNextSequences: [2])
    let result = await TranscriptOverlapStitcher(repairClient: repairClient).stitch(transcriptions: [
        transcribed(sequence: 0, start: 0, segments: [
            segment("Speaker 1", "Left boundary 0.", 54.5, 54.9)
        ]),
        transcribed(sequence: 1, start: 55, segments: [
            segment("Speaker 1", "Right boundary 0.", 55.2, 55.8),
            segment("Speaker 1", "Left boundary 1.", 109.5, 109.9)
        ]),
        transcribed(sequence: 2, start: 110, segments: [
            segment("Speaker 1", "Right boundary 1.", 110.2, 110.8),
            segment("Speaker 1", "Left boundary 2.", 164.5, 164.9)
        ]),
        transcribed(sequence: 3, start: 165, segments: [
            segment("Speaker 1", "Right boundary 2.", 165.2, 165.8),
            segment("Speaker 1", "Left boundary 3.", 219.5, 219.9)
        ]),
        transcribed(sequence: 4, start: 220, segments: [
            segment("Speaker 1", "Right boundary 3.", 220.2, 220.8)
        ])
    ])

    #expect(await repairClient.repairCallCount() == 4)
    #expect(await repairClient.maximumInFlightCount() == 2)
    #expect(result.decisions.filter { $0.kind == .gptRepaired }.count == 3)
    #expect(result.decisions.filter { $0.kind == .gptFailedFallback }.count == 1)
    #expect(result.segments.map(\.text).contains("GPT repair for boundary 1"))
    #expect(result.segments.map(\.text).contains("GPT repair for boundary 3"))
    #expect(result.segments.map(\.text).contains("GPT repair for boundary 4"))
    #expect(result.segments.map(\.text).contains("Left boundary 1."))
    #expect(result.segments.map(\.text).contains("Right boundary 1."))
    #expect(!result.segments.map(\.text).contains("GPT repair for boundary 2"))
}

private func transcribed(
    sequence: Int,
    start: TimeInterval,
    segments: [TranscriptSegment]
) -> TranscribedAudioFile {
    TranscribedAudioFile(
        audioFile: audioFile("/tmp/\(sequence).wav", sequence: sequence, start: start),
        segments: segments
    )
}

private func audioFile(
    _ path: String,
    sequence: Int,
    start: TimeInterval
) -> RecordedAudioFile {
    RecordedAudioFile(
        url: URL(fileURLWithPath: path),
        trackLabel: "Microphone",
        startTimeOffset: start,
        sequenceNumber: sequence,
        trackID: "microphone",
        duration: 60,
        overlapDuration: 5
    )
}

private func segment(
    _ speaker: String,
    _ text: String,
    _ startTime: TimeInterval,
    _ endTime: TimeInterval,
    confidence: Double? = nil
) -> TranscriptSegment {
    TranscriptSegment(
        speakerLabel: speaker,
        text: text,
        startTime: startTime,
        endTime: endTime,
        confidence: confidence
    )
}

private func makeSession() -> RecordingSession {
    RecordingSession(
        title: "Overlap Test",
        startedAt: Date(timeIntervalSince1970: 0),
        audioSources: .defaultMeetingCapture
    )
}

private struct StubAudioFileTranscriptionClient: AudioFileTranscriptionClient {
    var responses: [URL: AudioFileTranscriptionResponse]

    func transcribe(audioFile: RecordedAudioFile) async throws -> AudioFileTranscriptionResponse {
        try #require(responses[audioFile.url])
    }
}

private struct StubOverlapRepairClient: TranscriptOverlapRepairClient {
    var response: TranscriptOverlapRepairResponse?
    var error: Error?

    init(response: TranscriptOverlapRepairResponse? = nil, error: Error? = nil) {
        self.response = response
        self.error = error
    }

    func repair(_ request: TranscriptOverlapRepairRequest) async throws -> TranscriptOverlapRepairResponse {
        _ = request
        if let error {
            throw error
        }
        return try #require(response)
    }
}

private actor RecordingOverlapRepairClient: TranscriptOverlapRepairClient {
    private let failingNextSequences: Set<Int>
    private var inFlightCount = 0
    private var maxInFlightCount = 0
    private var callCount = 0

    init(failingNextSequences: Set<Int>) {
        self.failingNextSequences = failingNextSequences
    }

    func repair(_ request: TranscriptOverlapRepairRequest) async throws -> TranscriptOverlapRepairResponse {
        inFlightCount += 1
        maxInFlightCount = max(maxInFlightCount, inFlightCount)
        callCount += 1
        defer {
            inFlightCount -= 1
        }

        try await Task.sleep(for: .milliseconds(50))

        let nextSequence = request.boundary.nextChunkSequence ?? -1
        if failingNextSequences.contains(nextSequence) {
            throw StubError.failed
        }

        return TranscriptOverlapRepairResponse(
            segments: [
                segment(
                    "Speaker 1",
                    "GPT repair for boundary \(nextSequence)",
                    request.boundary.boundaryTime,
                    request.boundary.boundaryTime + 0.5
                )
            ],
            conflict: false,
            reason: "validated repair"
        )
    }

    func repairCallCount() -> Int {
        callCount
    }

    func maximumInFlightCount() -> Int {
        maxInFlightCount
    }
}

private enum StubError: Error {
    case failed
}

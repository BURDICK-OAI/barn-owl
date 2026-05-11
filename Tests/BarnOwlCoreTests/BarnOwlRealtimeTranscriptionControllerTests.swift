@testable import BarnOwl
import BarnOwlCore
import BarnOwlOpenAI
import Foundation
import Testing

@Test
func realtimeControllerAppendsCommitsAndPublishesTranscriptEvents() async throws {
    let client = FakeRealtimeStreamingClient()
    let sink = RealtimeControllerTestSink()
    let controller = BarnOwlRealtimeTranscriptionController(
        client: client,
        manualCommitInterval: 0,
        updateHandler: { update in sink.updates.append(update) },
        healthHandler: { health in sink.healthStates.append(health) },
        diagnosticsHandler: { event in sink.diagnostics.append(event) }
    )

    await controller.start()
    await controller.append(AudioRealtimePCMChunk(
        trackKind: .microphone,
        pcm16Data: makePCM16Data(sample: 3_000, byteCount: OpenAIRealtimeTranscriptionClient.minimumCommitByteCount + 512),
        sampleRate: OpenAIRealtimeTranscriptionClient.defaultSampleRate,
        duration: 0.12
    ))
    await client.push(.transcriptDelta("hel"))
    await client.push(.transcriptCompleted("hello"))
    try await Task.sleep(nanoseconds: 80_000_000)
    await controller.stop()

    let appendCount = await client.appendCount
    let commitCount = await client.commitCount
    await MainActor.run {
        #expect(appendCount >= 1)
        #expect(commitCount >= 1)
        #expect(sink.healthStates.contains(.connected))
        #expect(sink.healthStates.contains(.receivingAudio))
        #expect(sink.healthStates.contains(.transcribing))
        #expect(sink.updates == [
            BarnOwlRealtimeTranscriptionUpdate(text: "hel", isFinal: false),
            BarnOwlRealtimeTranscriptionUpdate(text: "hello", isFinal: true)
        ])
        #expect(sink.diagnostics.contains { $0.kind == .audioAppend })
        #expect(sink.diagnostics.contains { $0.kind == .audioCommit })
        #expect(sink.diagnostics.contains { $0.kind == .eventReceived })
    }
}

@Test
func realtimeControllerDoesNotCommitTinyBuffers() async throws {
    let client = FakeRealtimeStreamingClient()
    let sink = RealtimeControllerTestSink()
    let controller = BarnOwlRealtimeTranscriptionController(
        client: client,
        manualCommitInterval: 0,
        updateHandler: { update in sink.updates.append(update) },
        healthHandler: { health in sink.healthStates.append(health) },
        diagnosticsHandler: { event in sink.diagnostics.append(event) }
    )

    await controller.start()
    await controller.append(AudioRealtimePCMChunk(
        trackKind: .microphone,
        pcm16Data: makePCM16Data(sample: 3_000, byteCount: 120),
        sampleRate: OpenAIRealtimeTranscriptionClient.defaultSampleRate,
        duration: 0.0025
    ))
    await controller.stop()

    let appendCount = await client.appendCount
    let commitCount = await client.commitCount
    await MainActor.run {
        #expect(appendCount >= 1)
        #expect(commitCount == 1)
        #expect(sink.diagnostics.contains { $0.kind == .trailingSilenceAppend })
        #expect(sink.diagnostics.contains { $0.kind == .audioCommit })
    }
}

@Test
func realtimeControllerAppendsSoftSpeech() async throws {
    let client = FakeRealtimeStreamingClient()
    let sink = RealtimeControllerTestSink()
    let controller = BarnOwlRealtimeTranscriptionController(
        client: client,
        manualCommitInterval: 0,
        updateHandler: { update in sink.updates.append(update) },
        healthHandler: { health in sink.healthStates.append(health) },
        diagnosticsHandler: { event in sink.diagnostics.append(event) }
    )

    await controller.start()
    await controller.append(AudioRealtimePCMChunk(
        trackKind: .microphone,
        pcm16Data: makePCM16Data(sample: 32, byteCount: OpenAIRealtimeTranscriptionClient.minimumCommitByteCount + 512),
        sampleRate: OpenAIRealtimeTranscriptionClient.defaultSampleRate,
        duration: 0.12
    ))
    await controller.stop()

    let appendCount = await client.appendCount
    await MainActor.run {
        #expect(appendCount >= 1)
        #expect(sink.healthStates.contains(.receivingAudio))
        #expect(!sink.diagnostics.contains { $0.kind == .audioSilenceSkipped })
    }
}

@Test
func realtimeControllerDoesNotWarnForRoutineServerEvents() async throws {
    let client = FakeRealtimeStreamingClient()
    let sink = RealtimeControllerTestSink()
    let controller = BarnOwlRealtimeTranscriptionController(
        client: client,
        manualCommitInterval: 0,
        updateHandler: { update in sink.updates.append(update) },
        healthHandler: { health in sink.healthStates.append(health) },
        diagnosticsHandler: { event in sink.diagnostics.append(event) }
    )

    await controller.start()
    await client.push(.unhandled("input_audio_buffer.committed"))
    await client.push(.unhandled("conversation.item.added"))
    await client.push(.unhandled("conversation.item.done"))
    await client.push(.unhandled("barnowl.unknown_event"))
    try await Task.sleep(nanoseconds: 80_000_000)
    await controller.stop()

    await MainActor.run {
        #expect(sink.diagnostics.contains {
            $0.kind == .eventUnhandled && $0.details == "barnowl.unknown_event"
        })
        #expect(!sink.diagnostics.contains {
            $0.kind == .eventUnhandled && $0.details == "input_audio_buffer.committed"
        })
        #expect(!sink.diagnostics.contains {
            $0.kind == .eventUnhandled && $0.details == "conversation.item.added"
        })
        #expect(!sink.diagnostics.contains {
            $0.kind == .eventUnhandled && $0.details == "conversation.item.done"
        })
    }
}

@Test
func realtimeControllerDegradesOnServerErrorEvent() async throws {
    let client = FakeRealtimeStreamingClient()
    let sink = RealtimeControllerTestSink()
    let controller = BarnOwlRealtimeTranscriptionController(
        client: client,
        manualCommitInterval: 0,
        updateHandler: { update in sink.updates.append(update) },
        healthHandler: { health in sink.healthStates.append(health) },
        diagnosticsHandler: { event in sink.diagnostics.append(event) }
    )

    await controller.start()
    await client.push(.error("Unknown parameter: session.audio"))
    try await Task.sleep(nanoseconds: 80_000_000)
    await controller.stop()

    await MainActor.run {
        #expect(sink.healthStates.contains(.fallbackActive))
        #expect(sink.diagnostics.contains {
            $0.kind == .eventError
                && ($0.details?.contains("fallback") ?? false)
                && ($0.details?.contains("session.audio") ?? false)
        })
    }
}

@Test
func realtimeControllerLogsReceiveClosureAsFallback() async throws {
    let client = FakeRealtimeStreamingClient()
    let sink = RealtimeControllerTestSink()
    let controller = BarnOwlRealtimeTranscriptionController(
        client: client,
        manualCommitInterval: 0,
        updateHandler: { update in sink.updates.append(update) },
        healthHandler: { health in sink.healthStates.append(health) },
        diagnosticsHandler: { event in sink.diagnostics.append(event) }
    )

    await controller.start()
    await client.push(nil)
    try await Task.sleep(nanoseconds: 80_000_000)
    await controller.stop()

    await MainActor.run {
        #expect(sink.healthStates.contains(.fallbackActive))
        #expect(sink.diagnostics.contains { $0.kind == .receiveClosed })
    }
}

@Test
func realtimeControllerLogsConnectFailureAndIgnoresLaterAudio() async throws {
    let client = FakeRealtimeStreamingClient(connectError: URLError(.cannotConnectToHost))
    let sink = RealtimeControllerTestSink()
    let controller = BarnOwlRealtimeTranscriptionController(
        client: client,
        manualCommitInterval: 0,
        updateHandler: { update in sink.updates.append(update) },
        healthHandler: { health in sink.healthStates.append(health) },
        diagnosticsHandler: { event in sink.diagnostics.append(event) }
    )

    await controller.start()
    await controller.append(AudioRealtimePCMChunk(
        trackKind: .microphone,
        pcm16Data: makePCM16Data(sample: 3_000, byteCount: OpenAIRealtimeTranscriptionClient.minimumCommitByteCount + 512),
        sampleRate: OpenAIRealtimeTranscriptionClient.defaultSampleRate,
        duration: 0.12
    ))

    await MainActor.run {
        #expect(sink.healthStates.contains(.fallbackActive))
        #expect(sink.diagnostics.contains { $0.kind == .connectFailed })
        #expect(sink.diagnostics.contains { $0.kind == .audioAppendIgnored })
    }
}

@Test
func realtimeControllerLogsAppendFailureAndActivatesFallback() async throws {
    let client = FakeRealtimeStreamingClient(appendError: URLError(.networkConnectionLost))
    let sink = RealtimeControllerTestSink()
    let controller = BarnOwlRealtimeTranscriptionController(
        client: client,
        manualCommitInterval: 0,
        updateHandler: { update in sink.updates.append(update) },
        healthHandler: { health in sink.healthStates.append(health) },
        diagnosticsHandler: { event in sink.diagnostics.append(event) }
    )

    await controller.start()
    await controller.append(AudioRealtimePCMChunk(
        trackKind: .systemAudio,
        pcm16Data: makePCM16Data(sample: 3_000, byteCount: OpenAIRealtimeTranscriptionClient.minimumCommitByteCount + 512),
        sampleRate: OpenAIRealtimeTranscriptionClient.defaultSampleRate,
        duration: 0.12
    ))

    await MainActor.run {
        #expect(sink.healthStates.contains(.fallbackActive))
        #expect(sink.diagnostics.contains { $0.kind == .audioAppendFailed })
    }
}

@Test
func realtimeControllerSkipsSilentAudioAndSuppressesStaleTranscriptEvents() async throws {
    let client = FakeRealtimeStreamingClient()
    let sink = RealtimeControllerTestSink()
    let controller = BarnOwlRealtimeTranscriptionController(
        client: client,
        manualCommitInterval: 0,
        updateHandler: { update in sink.updates.append(update) },
        healthHandler: { health in sink.healthStates.append(health) },
        diagnosticsHandler: { event in sink.diagnostics.append(event) }
    )

    await controller.start()
    await controller.append(AudioRealtimePCMChunk(
        trackKind: .microphone,
        pcm16Data: Data(repeating: 0, count: OpenAIRealtimeTranscriptionClient.minimumCommitByteCount + 512),
        sampleRate: OpenAIRealtimeTranscriptionClient.defaultSampleRate,
        duration: 0.12
    ))
    await client.push(.transcriptCompleted("Thank you for watching."))
    try await Task.sleep(nanoseconds: 80_000_000)
    await controller.stop()

    let appendCount = await client.appendCount
    let commitCount = await client.commitCount
    await MainActor.run {
        #expect(appendCount == 0)
        #expect(commitCount == 0)
        #expect(sink.updates.isEmpty)
        #expect(sink.diagnostics.contains { $0.kind == .audioSilenceSkipped })
        #expect(sink.diagnostics.contains { $0.kind == .eventSuppressed })
    }
}

@MainActor
private final class RealtimeControllerTestSink {
    var updates: [BarnOwlRealtimeTranscriptionUpdate] = []
    var healthStates: [BarnOwlRealtimeHealthState] = []
    var diagnostics: [BarnOwlRealtimeDiagnosticEvent] = []
}

private actor FakeRealtimeStreamingClient: BarnOwlRealtimeStreamingClient {
    private(set) var appendCount = 0
    private(set) var commitCount = 0
    private let connectError: (any Error)?
    private let appendError: (any Error)?
    private let commitError: (any Error)?
    private var pendingEvents: [OpenAIRealtimeTranscriptionEvent?] = []
    private var receiveContinuations: [CheckedContinuation<OpenAIRealtimeTranscriptionEvent?, any Error>] = []

    init(
        connectError: (any Error)? = nil,
        appendError: (any Error)? = nil,
        commitError: (any Error)? = nil
    ) {
        self.connectError = connectError
        self.appendError = appendError
        self.commitError = commitError
    }

    func connect() async throws {
        if let connectError {
            throw connectError
        }
    }

    func appendPCM16Audio(_ audio: Data) async throws {
        if let appendError {
            throw appendError
        }
        appendCount += 1
        #expect(!audio.isEmpty)
    }

    func commitAudio() async throws {
        if let commitError {
            throw commitError
        }
        commitCount += 1
    }

    func receiveEvent() async throws -> OpenAIRealtimeTranscriptionEvent? {
        if !pendingEvents.isEmpty {
            return pendingEvents.removeFirst()
        }

        return try await withCheckedThrowingContinuation { continuation in
            receiveContinuations.append(continuation)
        }
    }

    func close() async {
        while !receiveContinuations.isEmpty {
            receiveContinuations.removeFirst().resume(returning: nil)
        }
    }

    func push(_ event: OpenAIRealtimeTranscriptionEvent?) {
        if !receiveContinuations.isEmpty {
            receiveContinuations.removeFirst().resume(returning: event)
        } else {
            pendingEvents.append(event)
        }
    }
}

private func makePCM16Data(sample: Int16, byteCount: Int) -> Data {
    let evenByteCount = byteCount - (byteCount % MemoryLayout<Int16>.size)
    var data = Data()
    data.reserveCapacity(evenByteCount)
    let littleEndian = sample.littleEndian
    for _ in 0..<(evenByteCount / MemoryLayout<Int16>.size) {
        var value = littleEndian
        withUnsafeBytes(of: &value) { bytes in
            data.append(contentsOf: bytes)
        }
    }
    return data
}

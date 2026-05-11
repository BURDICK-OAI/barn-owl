import BarnOwlCore
import BarnOwlOpenAI
import Foundation

struct BarnOwlRealtimeTranscriptionUpdate: Equatable, Sendable {
    var text: String
    var isFinal: Bool
}

enum BarnOwlRealtimeDiagnosticKind: String, Equatable, Sendable {
    case connecting
    case connected
    case connectFailed
    case audioAppend
    case audioAppendIgnored
    case audioAppendFailed
    case audioDropped
    case audioCommit
    case audioCommitSkipped
    case audioCommitFailed
    case audioSilenceSkipped
    case trailingSilenceAppend
    case trailingSilenceFailed
    case eventReceived
    case eventSuppressed
    case eventUnhandled
    case eventError
    case receiveClosed
    case receiveFailed
    case stopped
}

struct BarnOwlRealtimeDiagnosticEvent: Equatable, Sendable {
    var kind: BarnOwlRealtimeDiagnosticKind
    var message: String
    var details: String?
}

enum BarnOwlRealtimeHealthState: String, Equatable, Sendable {
    case idle
    case connecting
    case connected
    case receivingAudio
    case transcribing
    case degraded
    case fallbackActive
    case stopped

    var displayText: String {
        switch self {
        case .idle:
            return "Realtime transcription idle."
        case .connecting:
            return "Realtime connecting..."
        case .connected:
            return "Realtime connected. Waiting for audio."
        case .receivingAudio:
            return "Realtime receiving audio."
        case .transcribing:
            return "Realtime transcribing live."
        case .degraded:
            return "Realtime degraded; final transcript fallback active."
        case .fallbackActive:
            return "Realtime fallback active; final transcript will run."
        case .stopped:
            return "Realtime transcription stopped."
        }
    }
}

protocol BarnOwlRealtimeStreamingClient: Sendable {
    func connect() async throws
    func appendPCM16Audio(_ audio: Data) async throws
    func commitAudio() async throws
    func receiveEvent() async throws -> OpenAIRealtimeTranscriptionEvent?
    func close() async
}

extension OpenAIRealtimeTranscriptionClient: BarnOwlRealtimeStreamingClient {}

actor BarnOwlRealtimeTranscriptionController {
    static let maxBufferedByteCount = 24_000 * 2 * 8
    static let droppedStatusInterval = 25
    static let skippedSilenceStatusInterval = 50
    static let stopSilenceDuration: TimeInterval = 0.65
    static let speechRMSFloor = 0.0005
    static let staleTranscriptGraceInterval: TimeInterval = 8
    static let routineServerEventTypes: Set<String> = [
        "conversation.item.added",
        "conversation.item.done",
        "input_audio_buffer.committed",
        "input_audio_buffer.speech_started",
        "input_audio_buffer.speech_stopped",
        "rate_limits.updated",
        "session.created",
        "session.updated"
    ]

    private let client: any BarnOwlRealtimeStreamingClient
    private let manualCommitInterval: TimeInterval
    private let updateHandler: @MainActor @Sendable (BarnOwlRealtimeTranscriptionUpdate) -> Void
    private let healthHandler: @MainActor @Sendable (BarnOwlRealtimeHealthState) -> Void
    private let diagnosticsHandler: @MainActor @Sendable (BarnOwlRealtimeDiagnosticEvent) -> Void
    private var receiveTask: Task<Void, Never>?
    private var isConnected = false
    private var isStopping = false
    private var isDegraded = false
    private var bufferedByteCount = 0
    private var sentByteCount = 0
    private var uncommittedByteCount = 0
    private var appendedChunkCount = 0
    private var committedBufferCount = 0
    private var lastCommitAt = Date.distantPast
    private var lastSpeechAudioAt: Date?
    private var droppedChunkCount = 0
    private var skippedSilentChunkCount = 0
    private var didReportFirstAudio = false

    init(
        configuration: OpenAIConfiguration,
        prompt: String? = BarnOwlRealtimeTranscriptionHintsStore.currentPrompt(),
        updateHandler: @escaping @MainActor @Sendable (BarnOwlRealtimeTranscriptionUpdate) -> Void,
        healthHandler: @escaping @MainActor @Sendable (BarnOwlRealtimeHealthState) -> Void,
        diagnosticsHandler: @escaping @MainActor @Sendable (BarnOwlRealtimeDiagnosticEvent) -> Void = { _ in }
    ) {
        self.init(
            client: OpenAIRealtimeTranscriptionClient(
                configuration: configuration,
                prompt: prompt,
                transport: URLSessionRealtimeWebSocketTransport()
            ),
            updateHandler: updateHandler,
            healthHandler: healthHandler,
            diagnosticsHandler: diagnosticsHandler
        )
    }

    init(
        client: any BarnOwlRealtimeStreamingClient,
        manualCommitInterval: TimeInterval = 1.2,
        updateHandler: @escaping @MainActor @Sendable (BarnOwlRealtimeTranscriptionUpdate) -> Void,
        healthHandler: @escaping @MainActor @Sendable (BarnOwlRealtimeHealthState) -> Void,
        diagnosticsHandler: @escaping @MainActor @Sendable (BarnOwlRealtimeDiagnosticEvent) -> Void = { _ in }
    ) {
        self.client = client
        self.manualCommitInterval = max(0, manualCommitInterval)
        self.updateHandler = updateHandler
        self.healthHandler = healthHandler
        self.diagnosticsHandler = diagnosticsHandler
    }

    func start() async {
        guard !isConnected else { return }
        await emit(.connecting, "Realtime connecting.", details: nil)
        await healthHandler(.connecting)

        do {
            try await client.connect()
            isConnected = true
            isStopping = false
            isDegraded = false
            uncommittedByteCount = 0
            appendedChunkCount = 0
            committedBufferCount = 0
            lastCommitAt = Date()
            lastSpeechAudioAt = nil
            skippedSilentChunkCount = 0
            await emit(.connected, "Realtime connected.", details: nil)
            await healthHandler(.connected)
            startReceiving()
        } catch {
            isDegraded = true
            await emit(.connectFailed, "Realtime connection failed.", details: BarnOwlErrorFormatter.message(for: error))
            await healthHandler(.fallbackActive)
        }
    }

    func append(_ chunk: AudioRealtimePCMChunk) async {
        guard isConnected, !isDegraded else {
            await emit(
                .audioAppendIgnored,
                "Realtime audio append ignored.",
                details: "connected=\(isConnected) degraded=\(isDegraded) bytes=\(chunk.pcm16Data.count)"
            )
            return
        }
        guard bufferedByteCount < Self.maxBufferedByteCount else {
            droppedChunkCount += 1
            if droppedChunkCount == 1 || droppedChunkCount.isMultiple(of: Self.droppedStatusInterval) {
                await emit(
                    .audioDropped,
                    "Realtime audio dropped because the buffer is full.",
                    details: "dropped=\(droppedChunkCount) bufferedBytes=\(bufferedByteCount) incomingBytes=\(chunk.pcm16Data.count)"
                )
                await healthHandler(.degraded)
            }
            return
        }
        let rms = RMSLevelMeter.rmsLevel(forPCM16Data: chunk.pcm16Data)
        guard rms >= Self.speechRMSFloor else {
            await handleSilentChunk(chunk, rms: rms)
            return
        }

        bufferedByteCount += chunk.pcm16Data.count
        do {
            lastSpeechAudioAt = Date()
            try await client.appendPCM16Audio(chunk.pcm16Data)
            appendedChunkCount += 1
            sentByteCount += chunk.pcm16Data.count
            uncommittedByteCount += chunk.pcm16Data.count
            bufferedByteCount = max(0, bufferedByteCount - chunk.pcm16Data.count)
            if appendedChunkCount <= 8 || appendedChunkCount.isMultiple(of: 20) {
                await emit(
                    .audioAppend,
                    "Realtime audio appended.",
                    details: [
                        "chunk=\(appendedChunkCount)",
                        "track=\(chunk.trackKind.rawValue)",
                        "bytes=\(chunk.pcm16Data.count)",
                        "duration=\(String(format: "%.3f", chunk.duration))",
                        "sampleRate=\(chunk.sampleRate)",
                        "uncommittedBytes=\(uncommittedByteCount)",
                        "totalSentBytes=\(sentByteCount)"
                    ].joined(separator: " ")
                )
            }
            if !didReportFirstAudio {
                didReportFirstAudio = true
                await healthHandler(.receivingAudio)
            }
            if droppedChunkCount > 0 {
                droppedChunkCount = 0
            }
            if skippedSilentChunkCount > 0 {
                skippedSilentChunkCount = 0
            }
            await commitAudioIfReady()
        } catch {
            bufferedByteCount = max(0, bufferedByteCount - chunk.pcm16Data.count)
            isDegraded = true
            await emit(
                .audioAppendFailed,
                "Realtime audio append failed.",
                details: "bytes=\(chunk.pcm16Data.count) error=\(BarnOwlErrorFormatter.message(for: error))"
            )
            await healthHandler(.fallbackActive)
        }
    }

    func stop() async {
        isStopping = true

        guard isConnected else {
            receiveTask?.cancel()
            receiveTask = nil
            await client.close()
            await healthHandler(.stopped)
            return
        }

        if didReportFirstAudio, !isDegraded {
            await appendTrailingSilence()
            await commitAudioIfNeeded(force: true)
            try? await Task.sleep(nanoseconds: 900_000_000)
        }

        isConnected = false
        receiveTask?.cancel()
        receiveTask = nil
        await client.close()
        await emit(.stopped, "Realtime transcription stopped.", details: nil)
        await healthHandler(.stopped)
    }

    private func startReceiving() {
        receiveTask?.cancel()
        receiveTask = Task { [weak self] in
            await self?.receiveLoop()
        }
    }

    private func receiveLoop() async {
        while !Task.isCancelled {
            do {
                guard let event = try await client.receiveEvent() else {
                    if !isStopping {
                        isDegraded = true
                        await emit(.receiveClosed, "Realtime receive loop closed.", details: "stopping=false")
                        await healthHandler(.fallbackActive)
                    }
                    return
                }

                switch event {
                case .transcriptDelta(let text):
                    guard await shouldPublishTranscript(text) else {
                        await emit(.eventSuppressed, "Realtime transcript suppressed during silence.", details: "characters=\(text.count)")
                        continue
                    }
                    await emit(.eventReceived, "Realtime transcript delta received.", details: "characters=\(text.count)")
                    await healthHandler(.transcribing)
                    await updateHandler(BarnOwlRealtimeTranscriptionUpdate(text: text, isFinal: false))
                case .transcriptCompleted(let text):
                    guard await shouldPublishTranscript(text) else {
                        await emit(.eventSuppressed, "Realtime transcript suppressed during silence.", details: "characters=\(text.count)")
                        continue
                    }
                    await emit(.eventReceived, "Realtime transcript completed.", details: "characters=\(text.count)")
                    await healthHandler(.transcribing)
                    await updateHandler(BarnOwlRealtimeTranscriptionUpdate(text: text, isFinal: true))
                case .error(let message):
                    isDegraded = true
                    let safeMessage = BarnOwlErrorFormatter.sanitizeForUserDisplay(message)
                    let fallbackDetails = "Realtime preview switched to fallback. Final transcription will still run after recording stops."
                    let details = safeMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        ? fallbackDetails
                        : "\(fallbackDetails) Server message: \(safeMessage)"
                    await emit(
                        .eventError,
                        "Realtime server returned an error.",
                        details: details
                    )
                    await healthHandler(.fallbackActive)
                    return
                case .unhandled(let eventType):
                    guard !Self.routineServerEventTypes.contains(eventType) else {
                        break
                    }
                    await emit(.eventUnhandled, "Realtime event ignored.", details: eventType)
                    break
                }
            } catch is CancellationError {
                return
            } catch {
                if !isStopping {
                    isDegraded = true
                    await emit(.receiveFailed, "Realtime receive loop failed.", details: BarnOwlErrorFormatter.message(for: error))
                    await healthHandler(.fallbackActive)
                }
                return
            }
        }
    }

    private func handleSilentChunk(_ chunk: AudioRealtimePCMChunk, rms: Double) async {
        skippedSilentChunkCount += 1
        if skippedSilentChunkCount == 1 || skippedSilentChunkCount.isMultiple(of: Self.skippedSilenceStatusInterval) {
            await emit(
                .audioSilenceSkipped,
                "Realtime silent audio skipped.",
                details: [
                    "skipped=\(skippedSilentChunkCount)",
                    "track=\(chunk.trackKind.rawValue)",
                    "bytes=\(chunk.pcm16Data.count)",
                    "duration=\(String(format: "%.3f", chunk.duration))",
                    "rms=\(String(format: "%.5f", rms))",
                    "threshold=\(String(format: "%.5f", Self.speechRMSFloor))",
                    "uncommittedBytes=\(uncommittedByteCount)"
                ].joined(separator: " ")
            )
        }
        await commitAudioIfReady()
    }

    private func shouldPublishTranscript(_ text: String) async -> Bool {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }
        guard let lastSpeechAudioAt else {
            return false
        }
        return Date().timeIntervalSince(lastSpeechAudioAt) <= Self.staleTranscriptGraceInterval
    }

    private func appendTrailingSilence() async {
        guard isConnected else { return }
        let byteCount = Int(Self.stopSilenceDuration * Double(OpenAIRealtimeTranscriptionClient.defaultSampleRate)) * MemoryLayout<Int16>.size
        guard byteCount > 0 else { return }

        do {
            try await client.appendPCM16Audio(Data(repeating: 0, count: byteCount))
            uncommittedByteCount += byteCount
            await emit(
                .trailingSilenceAppend,
                "Realtime trailing silence appended.",
                details: "bytes=\(byteCount) uncommittedBytes=\(uncommittedByteCount)"
            )
        } catch {
            if !isStopping {
                isDegraded = true
                await emit(.trailingSilenceFailed, "Realtime trailing silence append failed.", details: BarnOwlErrorFormatter.message(for: error))
                await healthHandler(.fallbackActive)
            }
        }
    }

    private func commitAudioIfReady() async {
        guard Date().timeIntervalSince(lastCommitAt) >= manualCommitInterval else {
            return
        }
        await commitAudioIfNeeded(force: false)
    }

    private func commitAudioIfNeeded(force: Bool) async {
        guard isConnected, !isDegraded else {
            return
        }
        guard uncommittedByteCount >= OpenAIRealtimeTranscriptionClient.minimumCommitByteCount else {
            if force {
                await emit(
                    .audioCommitSkipped,
                    "Realtime audio commit skipped.",
                    details: "reason=too_few_bytes uncommittedBytes=\(uncommittedByteCount) minimumBytes=\(OpenAIRealtimeTranscriptionClient.minimumCommitByteCount)"
                )
            }
            return
        }
        guard force || Date().timeIntervalSince(lastCommitAt) >= manualCommitInterval else {
            return
        }

        do {
            try await client.commitAudio()
            committedBufferCount += 1
            await emit(
                .audioCommit,
                "Realtime audio committed.",
                details: "commit=\(committedBufferCount) bytes=\(uncommittedByteCount) force=\(force)"
            )
            uncommittedByteCount = 0
            lastCommitAt = Date()
        } catch {
            isDegraded = true
            await emit(.audioCommitFailed, "Realtime audio commit failed.", details: BarnOwlErrorFormatter.message(for: error))
            await healthHandler(.fallbackActive)
        }
    }

    private func emit(
        _ kind: BarnOwlRealtimeDiagnosticKind,
        _ message: String,
        details: String?
    ) async {
        await diagnosticsHandler(BarnOwlRealtimeDiagnosticEvent(
            kind: kind,
            message: message,
            details: details
        ))
    }
}

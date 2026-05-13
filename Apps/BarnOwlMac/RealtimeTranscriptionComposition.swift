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
    case eventRecoverableError
    case receiveClosed
    case receiveFailed
    case reconnecting
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
    case reconnecting
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
        case .reconnecting:
            return "Realtime reconnecting..."
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
    static let speechStartRMSFloor = 0.0035
    static let speechContinueRMSFloor = 0.0015
    static let minimumVoicedDurationForTranscript: TimeInterval = 0.35
    static let minimumVoicedDurationForShortTranscript: TimeInterval = 0.65
    static let serverVADTrailingSilenceDuration: TimeInterval = 2.2
    static let serverVADFallbackCommitInterval: TimeInterval = 5
    static let serverVADFallbackMinimumVoicedDuration: TimeInterval = 0.75
    static let staleTranscriptGraceInterval: TimeInterval = 8
    static let reconnectMaximumDelay: TimeInterval = 30
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
    private let usesServerTurnDetection: Bool
    private let updateHandler: @MainActor @Sendable (BarnOwlRealtimeTranscriptionUpdate) -> Void
    private let healthHandler: @MainActor @Sendable (BarnOwlRealtimeHealthState) -> Void
    private let diagnosticsHandler: @MainActor @Sendable (BarnOwlRealtimeDiagnosticEvent) -> Void
    private var receiveTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var isConnected = false
    private var isStopping = false
    private var isDegraded = false
    private var reconnectAttempt = 0
    private var bufferedByteCount = 0
    private var sentByteCount = 0
    private var uncommittedByteCount = 0
    private var isCommitInFlight = false
    private var appendedChunkCount = 0
    private var committedBufferCount = 0
    private var lastCommitAt = Date.distantPast
    private var lastSpeechAudioAt: Date?
    private var droppedChunkCount = 0
    private var skippedSilentChunkCount = 0
    private var didReportFirstAudio = false
    private var isForwardingSpeechTurn = false
    private var trailingSilenceDuration: TimeInterval = 0
    private var currentTurnVoicedDuration: TimeInterval = 0
    private var lastSpeechTurnVoicedDuration: TimeInterval = 0
    private var didReceiveRealtimeTranscript = false
    private var lastTranscriptEventAt = Date.distantPast
    private var ignoredAppendCount = 0
    private var lastIgnoredAppendReportAt = Date.distantPast

    init(
        configuration: OpenAIConfiguration,
        prompt: String? = nil,
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
            usesServerTurnDetection: true,
            updateHandler: updateHandler,
            healthHandler: healthHandler,
            diagnosticsHandler: diagnosticsHandler
        )
    }

    init(
        client: any BarnOwlRealtimeStreamingClient,
        manualCommitInterval: TimeInterval = 1.2,
        usesServerTurnDetection: Bool = false,
        updateHandler: @escaping @MainActor @Sendable (BarnOwlRealtimeTranscriptionUpdate) -> Void,
        healthHandler: @escaping @MainActor @Sendable (BarnOwlRealtimeHealthState) -> Void,
        diagnosticsHandler: @escaping @MainActor @Sendable (BarnOwlRealtimeDiagnosticEvent) -> Void = { _ in }
    ) {
        self.client = client
        self.manualCommitInterval = max(0, manualCommitInterval)
        self.usesServerTurnDetection = usesServerTurnDetection
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
            isCommitInFlight = false
            appendedChunkCount = 0
            committedBufferCount = 0
            lastCommitAt = Date()
            lastSpeechAudioAt = nil
            skippedSilentChunkCount = 0
            isForwardingSpeechTurn = false
            trailingSilenceDuration = 0
            currentTurnVoicedDuration = 0
            lastSpeechTurnVoicedDuration = 0
            didReceiveRealtimeTranscript = false
            lastTranscriptEventAt = .distantPast
            ignoredAppendCount = 0
            lastIgnoredAppendReportAt = .distantPast
            await emit(.connected, "Realtime connected.", details: nil)
            await healthHandler(.connected)
            startReceiving()
        } catch {
            await emit(.connectFailed, "Realtime connection failed.", details: BarnOwlErrorFormatter.message(for: error))
            await markDisconnectedAndScheduleReconnect(reason: BarnOwlErrorFormatter.message(for: error))
        }
    }

    func append(_ chunk: AudioRealtimePCMChunk) async {
        guard isConnected, !isDegraded else {
            await reportIgnoredAppend(bytes: chunk.pcm16Data.count)
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
        guard shouldForward(chunk: chunk, rms: rms) else {
            await handleSilentChunk(chunk, rms: rms)
            return
        }

        bufferedByteCount += chunk.pcm16Data.count
        do {
            if isVoiced(rms: rms) {
                lastSpeechAudioAt = Date()
                currentTurnVoicedDuration += chunk.duration
                trailingSilenceDuration = 0
            }
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
            if !usesServerTurnDetection {
                await commitAudioIfReady()
            } else {
                await commitServerTurnDetectionFallbackIfReady()
            }
        } catch {
            bufferedByteCount = max(0, bufferedByteCount - chunk.pcm16Data.count)
            await emit(
                .audioAppendFailed,
                "Realtime audio append failed.",
                details: "bytes=\(chunk.pcm16Data.count) error=\(BarnOwlErrorFormatter.message(for: error))"
            )
            await markDisconnectedAndScheduleReconnect(reason: BarnOwlErrorFormatter.message(for: error))
        }
    }

    func stop() async {
        isStopping = true
        reconnectTask?.cancel()
        reconnectTask = nil

        guard isConnected else {
            receiveTask?.cancel()
            receiveTask = nil
            await client.close()
            await healthHandler(.stopped)
            return
        }

        if didReportFirstAudio, !isDegraded {
            await appendTrailingSilence()
            if usesServerTurnDetection {
                await commitServerTurnDetectionFallbackOnStop()
            } else {
                await commitAudioIfNeeded(force: true)
            }
            try? await Task.sleep(nanoseconds: usesServerTurnDetection ? 1_500_000_000 : 900_000_000)
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
                        await emit(.receiveClosed, "Realtime receive loop closed.", details: "stopping=false")
                        await markDisconnectedAndScheduleReconnect(reason: "receive loop closed")
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
                    markRealtimeTranscriptReceived()
                    await updateHandler(BarnOwlRealtimeTranscriptionUpdate(text: text, isFinal: false))
                case .transcriptCompleted(let text):
                    guard await shouldPublishTranscript(text) else {
                        await emit(.eventSuppressed, "Realtime transcript suppressed during silence.", details: "characters=\(text.count)")
                        continue
                    }
                    await emit(.eventReceived, "Realtime transcript completed.", details: "characters=\(text.count)")
                    await healthHandler(.transcribing)
                    markRealtimeTranscriptReceived()
                    await updateHandler(BarnOwlRealtimeTranscriptionUpdate(text: text, isFinal: true))
                    if usesServerTurnDetection, !isForwardingSpeechTurn {
                        currentTurnVoicedDuration = 0
                        lastSpeechTurnVoicedDuration = 0
                    }
                case .speechStarted:
                    await healthHandler(.receivingAudio)
                case .speechStopped:
                    lastSpeechTurnVoicedDuration = max(lastSpeechTurnVoicedDuration, currentTurnVoicedDuration)
                    isForwardingSpeechTurn = false
                    trailingSilenceDuration = 0
                case .error(let message):
                    if Self.isRecoverableEmptyCommitServerError(message) {
                        isCommitInFlight = false
                        uncommittedByteCount = 0
                        let safeMessage = BarnOwlErrorFormatter.sanitizeForUserDisplay(message)
                        await emit(
                            .eventRecoverableError,
                            "Realtime recovered from an empty audio commit.",
                            details: safeMessage
                        )
                        if didReportFirstAudio {
                            await healthHandler(.receivingAudio)
                        }
                        continue
                    }
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
                    await markDisconnectedAndScheduleReconnect(reason: safeMessage)
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
                    await emit(.receiveFailed, "Realtime receive loop failed.", details: BarnOwlErrorFormatter.message(for: error))
                    await markDisconnectedAndScheduleReconnect(reason: BarnOwlErrorFormatter.message(for: error))
                }
                return
            }
        }
    }

    private func commitServerTurnDetectionFallbackIfReady() async {
        guard usesServerTurnDetection,
              !didReceiveRealtimeTranscript,
              Date().timeIntervalSince(lastCommitAt) >= Self.serverVADFallbackCommitInterval,
              Date().timeIntervalSince(lastTranscriptEventAt) >= Self.serverVADFallbackCommitInterval,
              max(currentTurnVoicedDuration, lastSpeechTurnVoicedDuration) >= Self.serverVADFallbackMinimumVoicedDuration
        else {
            return
        }

        await emit(
            .audioCommit,
            "Realtime server turn detection had no transcript yet; committing voiced audio fallback.",
            details: "voicedDuration=\(String(format: "%.2f", max(currentTurnVoicedDuration, lastSpeechTurnVoicedDuration))) uncommittedBytes=\(uncommittedByteCount)"
        )
        await commitAudioIfNeeded(force: false)
    }

    private func commitServerTurnDetectionFallbackOnStop() async {
        guard usesServerTurnDetection,
              !didReceiveRealtimeTranscript,
              max(currentTurnVoicedDuration, lastSpeechTurnVoicedDuration) >= Self.minimumVoicedDurationForTranscript
        else {
            return
        }

        await emit(
            .audioCommit,
            "Realtime server turn detection produced no transcript before stop; committing voiced audio fallback.",
            details: "voicedDuration=\(String(format: "%.2f", max(currentTurnVoicedDuration, lastSpeechTurnVoicedDuration))) uncommittedBytes=\(uncommittedByteCount)"
        )
        await commitAudioIfNeeded(force: true)
    }

    private func markRealtimeTranscriptReceived() {
        didReceiveRealtimeTranscript = true
        lastTranscriptEventAt = Date()
    }

    private func shouldForward(chunk: AudioRealtimePCMChunk, rms: Double) -> Bool {
        if rms >= Self.speechStartRMSFloor || (isForwardingSpeechTurn && rms >= Self.speechContinueRMSFloor) {
            isForwardingSpeechTurn = true
            return true
        }

        guard usesServerTurnDetection,
              isForwardingSpeechTurn,
              currentTurnVoicedDuration > 0,
              trailingSilenceDuration < Self.serverVADTrailingSilenceDuration
        else {
            return false
        }

        trailingSilenceDuration += chunk.duration
        if trailingSilenceDuration >= Self.serverVADTrailingSilenceDuration {
            isForwardingSpeechTurn = false
            lastSpeechTurnVoicedDuration = max(lastSpeechTurnVoicedDuration, currentTurnVoicedDuration)
        }
        return true
    }

    private func isVoiced(rms: Double) -> Bool {
        rms >= Self.speechContinueRMSFloor
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
                    "startThreshold=\(String(format: "%.5f", Self.speechStartRMSFloor))",
                    "continueThreshold=\(String(format: "%.5f", Self.speechContinueRMSFloor))",
                    "uncommittedBytes=\(uncommittedByteCount)"
                ].joined(separator: " ")
            )
        }
        if !usesServerTurnDetection {
            await commitAudioIfReady()
        }
    }

    private func shouldPublishTranscript(_ text: String) async -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return false
        }
        guard let lastSpeechAudioAt else {
            return false
        }
        guard Date().timeIntervalSince(lastSpeechAudioAt) <= Self.staleTranscriptGraceInterval else {
            return false
        }

        let voicedDuration = max(currentTurnVoicedDuration, lastSpeechTurnVoicedDuration)
        let requiredDuration = trimmed.count <= 14
            ? Self.minimumVoicedDurationForShortTranscript
            : Self.minimumVoicedDurationForTranscript
        return voicedDuration >= requiredDuration
    }

    private func appendTrailingSilence() async {
        guard isConnected else { return }
        guard uncommittedByteCount > 0 || currentTurnVoicedDuration > 0 else { return }
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
                await emit(.trailingSilenceFailed, "Realtime trailing silence append failed.", details: BarnOwlErrorFormatter.message(for: error))
                await markDisconnectedAndScheduleReconnect(reason: BarnOwlErrorFormatter.message(for: error))
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
        guard !isCommitInFlight else {
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

        let bytesToCommit = uncommittedByteCount
        uncommittedByteCount = 0
        isCommitInFlight = true

        do {
            try await client.commitAudio()
            isCommitInFlight = false
            committedBufferCount += 1
            lastCommitAt = Date()
            await emit(
                .audioCommit,
                "Realtime audio committed.",
                details: "commit=\(committedBufferCount) bytes=\(bytesToCommit) force=\(force)"
            )
        } catch {
            isCommitInFlight = false
            uncommittedByteCount += bytesToCommit
            await emit(.audioCommitFailed, "Realtime audio commit failed.", details: BarnOwlErrorFormatter.message(for: error))
            await markDisconnectedAndScheduleReconnect(reason: BarnOwlErrorFormatter.message(for: error))
        }
    }

    private func markDisconnectedAndScheduleReconnect(reason: String) async {
        guard !isStopping else { return }
        isConnected = false
        isDegraded = true
        uncommittedByteCount = 0
        isCommitInFlight = false
        receiveTask?.cancel()
        receiveTask = nil
        await client.close()
        await healthHandler(.reconnecting)
        scheduleReconnect(reason: reason)
    }

    private func scheduleReconnect(reason: String) {
        guard reconnectTask == nil, !isStopping else { return }
        reconnectAttempt += 1
        let attempt = reconnectAttempt
        let delay = min(Self.reconnectMaximumDelay, pow(2.0, Double(min(attempt, 5))))
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            if Task.isCancelled { return }
            await self?.attemptReconnect(attempt: attempt, reason: reason)
        }
    }

    private func attemptReconnect(attempt: Int, reason: String) async {
        reconnectTask = nil
        guard !isStopping else { return }
        await emit(
            .reconnecting,
            "Realtime reconnecting.",
            details: "attempt=\(attempt) reason=\(reason)"
        )
        await healthHandler(.reconnecting)
        do {
            try await client.connect()
            reconnectAttempt = 0
            isConnected = true
            isDegraded = false
            bufferedByteCount = 0
            uncommittedByteCount = 0
            isCommitInFlight = false
            lastCommitAt = Date()
            ignoredAppendCount = 0
            lastIgnoredAppendReportAt = .distantPast
            await emit(.connected, "Realtime reconnected.", details: "attempt=\(attempt)")
            await healthHandler(.connected)
            startReceiving()
        } catch {
            await emit(.connectFailed, "Realtime reconnect failed.", details: BarnOwlErrorFormatter.message(for: error))
            await markDisconnectedAndScheduleReconnect(reason: BarnOwlErrorFormatter.message(for: error))
        }
    }

    private func reportIgnoredAppend(bytes: Int) async {
        ignoredAppendCount += 1
        let now = Date()
        guard ignoredAppendCount == 1 || now.timeIntervalSince(lastIgnoredAppendReportAt) >= 5 else {
            return
        }
        lastIgnoredAppendReportAt = now
        await emit(
            .audioAppendIgnored,
            "Realtime audio append ignored.",
            details: "connected=\(isConnected) degraded=\(isDegraded) bytes=\(bytes) ignored=\(ignoredAppendCount)"
        )
    }

    private static func isRecoverableEmptyCommitServerError(_ message: String) -> Bool {
        let normalized = message.lowercased()
        guard normalized.contains("buffer too small"),
              normalized.contains("input audio buffer")
        else {
            return false
        }
        return normalized.contains("0.00ms")
            || normalized.contains("0ms")
            || normalized.contains("0 ms")
            || normalized.contains("0.00 ms")
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

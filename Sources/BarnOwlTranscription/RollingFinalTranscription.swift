import Foundation

public enum RollingFinalTranscriptionStatus: String, Codable, Equatable, Sendable {
    case pending
    case running
    case completed
    case failed
}

public struct RollingFinalTranscriptionKey: Codable, Equatable, Hashable, Sendable {
    public var sessionID: UUID
    public var trackID: String
    public var sequenceNumber: Int

    public init(sessionID: UUID, trackID: String, sequenceNumber: Int) {
        self.sessionID = sessionID
        self.trackID = trackID
        self.sequenceNumber = sequenceNumber
    }
}

public struct RollingFinalTranscriptionRecord: Codable, Equatable, Sendable {
    public var key: RollingFinalTranscriptionKey
    public var trackLabel: String
    public var audioFilePath: String?
    public var startTimeOffset: TimeInterval
    public var duration: TimeInterval?
    public var overlapDuration: TimeInterval?
    public var modelIdentifier: String?
    public var status: RollingFinalTranscriptionStatus
    public var errorMessage: String?
    public var response: AudioFileTranscriptionResponse?
    public var createdAt: Date
    public var updatedAt: Date
    public var completedAt: Date?

    public init(
        key: RollingFinalTranscriptionKey,
        trackLabel: String,
        audioFilePath: String? = nil,
        startTimeOffset: TimeInterval,
        duration: TimeInterval? = nil,
        overlapDuration: TimeInterval? = nil,
        modelIdentifier: String? = nil,
        status: RollingFinalTranscriptionStatus,
        errorMessage: String? = nil,
        response: AudioFileTranscriptionResponse? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        completedAt: Date? = nil
    ) {
        self.key = key
        self.trackLabel = trackLabel
        self.audioFilePath = audioFilePath
        self.startTimeOffset = startTimeOffset
        self.duration = duration
        self.overlapDuration = overlapDuration
        self.modelIdentifier = modelIdentifier
        self.status = status
        self.errorMessage = errorMessage
        self.response = response
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.completedAt = completedAt
    }
}

public protocol RollingFinalTranscriptionCacheStore: Sendable {
    func completedResponse(
        for key: RollingFinalTranscriptionKey,
        modelIdentifier: String?
    ) async throws -> AudioFileTranscriptionResponse?
    func markRunning(
        key: RollingFinalTranscriptionKey,
        audioFile: RecordedAudioFile,
        modelIdentifier: String?
    ) async throws -> Bool
    func markCompleted(
        key: RollingFinalTranscriptionKey,
        audioFile: RecordedAudioFile,
        modelIdentifier: String?,
        response: AudioFileTranscriptionResponse
    ) async throws
    func markFailed(
        key: RollingFinalTranscriptionKey,
        audioFile: RecordedAudioFile,
        modelIdentifier: String?,
        errorMessage: String
    ) async throws
}

public extension RollingFinalTranscriptionCacheStore {
    func completedResponse(for key: RollingFinalTranscriptionKey) async throws -> AudioFileTranscriptionResponse? {
        try await completedResponse(for: key, modelIdentifier: nil)
    }
}

public enum RollingFinalTranscriptionCache {
    public static func key(
        sessionID: UUID,
        audioFile: RecordedAudioFile
    ) -> RollingFinalTranscriptionKey? {
        guard let sequenceNumber = audioFile.sequenceNumber else {
            return nil
        }
        return RollingFinalTranscriptionKey(
            sessionID: sessionID,
            trackID: audioFile.trackID,
            sequenceNumber: sequenceNumber
        )
    }
}

public struct CachedAudioFileTranscriptionClient: AudioFileTranscriptionClient {
    private let sessionID: UUID
    private let wrapped: any AudioFileTranscriptionClient
    private let cacheStore: any RollingFinalTranscriptionCacheStore
    private let modelIdentifier: String?
    private let existingRunningWaitTimeout: TimeInterval
    private let existingRunningPollInterval: TimeInterval

    public init(
        sessionID: UUID,
        wrapped: any AudioFileTranscriptionClient,
        cacheStore: any RollingFinalTranscriptionCacheStore,
        modelIdentifier: String? = nil,
        existingRunningWaitTimeout: TimeInterval = 15,
        existingRunningPollInterval: TimeInterval = 0.15
    ) {
        self.sessionID = sessionID
        self.wrapped = wrapped
        self.cacheStore = cacheStore
        self.modelIdentifier = modelIdentifier
        self.existingRunningWaitTimeout = max(0, existingRunningWaitTimeout)
        self.existingRunningPollInterval = max(0.01, existingRunningPollInterval)
    }

    public func transcribe(audioFile: RecordedAudioFile) async throws -> AudioFileTranscriptionResponse {
        guard let key = RollingFinalTranscriptionCache.key(sessionID: sessionID, audioFile: audioFile) else {
            return try await wrapped.transcribe(audioFile: audioFile)
        }

        if let cached = try? await cacheStore.completedResponse(for: key, modelIdentifier: modelIdentifier) {
            return cached
        }

        let shouldTranscribe = (try? await cacheStore.markRunning(
            key: key,
            audioFile: audioFile,
            modelIdentifier: modelIdentifier
        )) ?? true

        if !shouldTranscribe,
           let cached = try? await waitForCompletedResponse(for: key) {
            return cached
        }

        do {
            let response = try await wrapped.transcribe(audioFile: audioFile)
            try? await cacheStore.markCompleted(
                key: key,
                audioFile: audioFile,
                modelIdentifier: modelIdentifier,
                response: response
            )
            return response
        } catch {
            try? await cacheStore.markFailed(
                key: key,
                audioFile: audioFile,
                modelIdentifier: modelIdentifier,
                errorMessage: String(describing: error)
            )
            throw error
        }
    }

    private func waitForCompletedResponse(
        for key: RollingFinalTranscriptionKey
    ) async throws -> AudioFileTranscriptionResponse? {
        let deadline = Date().addingTimeInterval(existingRunningWaitTimeout)
        while Date() < deadline {
            if let cached = try await cacheStore.completedResponse(for: key, modelIdentifier: modelIdentifier) {
                return cached
            }
            let nanoseconds = UInt64(existingRunningPollInterval * 1_000_000_000)
            try? await Task.sleep(nanoseconds: nanoseconds)
        }
        return try await cacheStore.completedResponse(for: key, modelIdentifier: modelIdentifier)
    }
}

public actor RollingFinalTranscriptionCoordinator {
    private let sessionID: UUID
    private let transcriptionClient: any AudioFileTranscriptionClient
    private let cacheStore: any RollingFinalTranscriptionCacheStore
    private let modelIdentifier: String?
    private let maxConcurrentTranscriptions: Int

    private var pendingAudioFiles: [RecordedAudioFile] = []
    private var acceptedKeys: Set<RollingFinalTranscriptionKey> = []
    private var inFlightCount = 0
    private var isAcceptingWork = true
    private var drainedContinuations: [CheckedContinuation<Void, Never>] = []

    public init(
        sessionID: UUID,
        transcriptionClient: any AudioFileTranscriptionClient,
        cacheStore: any RollingFinalTranscriptionCacheStore,
        modelIdentifier: String? = nil,
        maxConcurrentTranscriptions: Int = 4
    ) {
        self.sessionID = sessionID
        self.transcriptionClient = transcriptionClient
        self.cacheStore = cacheStore
        self.modelIdentifier = modelIdentifier
        self.maxConcurrentTranscriptions = max(1, maxConcurrentTranscriptions)
    }

    public func enqueue(_ audioFile: RecordedAudioFile) {
        guard isAcceptingWork,
              let key = RollingFinalTranscriptionCache.key(sessionID: sessionID, audioFile: audioFile),
              !acceptedKeys.contains(key)
        else {
            return
        }

        acceptedKeys.insert(key)
        pendingAudioFiles.append(audioFile)
        scheduleAvailableWork()
    }

    public func finishAndDrain(timeout: Duration) async {
        isAcceptingWork = false
        scheduleAvailableWork()
        guard hasWorkToDrain else {
            return
        }

        enum DrainOutcome {
            case drained
            case timedOut
        }

        let outcome = await withTaskGroup(of: DrainOutcome.self) { group in
            group.addTask {
                await self.waitUntilDrained()
                return .drained
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return .timedOut
            }
            let outcome = await group.next() ?? .timedOut
            group.cancelAll()
            return outcome
        }

        if outcome == .timedOut {
            pendingAudioFiles.removeAll()
            let continuations = drainedContinuations
            drainedContinuations = []
            continuations.forEach { $0.resume() }
        }
    }

    private var hasWorkToDrain: Bool {
        inFlightCount > 0 || !pendingAudioFiles.isEmpty
    }

    private func waitUntilDrained() async {
        guard hasWorkToDrain else { return }
        await withCheckedContinuation { continuation in
            drainedContinuations.append(continuation)
        }
    }

    private func scheduleAvailableWork() {
        while inFlightCount < maxConcurrentTranscriptions,
              !pendingAudioFiles.isEmpty {
            let audioFile = pendingAudioFiles.removeFirst()
            inFlightCount += 1
            Task {
                await process(audioFile)
            }
        }
    }

    private func process(_ audioFile: RecordedAudioFile) async {
        guard let key = RollingFinalTranscriptionCache.key(sessionID: sessionID, audioFile: audioFile) else {
            markTaskFinished()
            return
        }

        do {
            if let cached = try await cacheStore.completedResponse(for: key, modelIdentifier: modelIdentifier) {
                _ = cached
                markTaskFinished()
                return
            }

            let shouldTranscribe = try await cacheStore.markRunning(
                key: key,
                audioFile: audioFile,
                modelIdentifier: modelIdentifier
            )
            guard shouldTranscribe else {
                markTaskFinished()
                return
            }

            let response = try await transcriptionClient.transcribe(audioFile: audioFile)
            try await cacheStore.markCompleted(
                key: key,
                audioFile: audioFile,
                modelIdentifier: modelIdentifier,
                response: response
            )
        } catch {
            try? await cacheStore.markFailed(
                key: key,
                audioFile: audioFile,
                modelIdentifier: modelIdentifier,
                errorMessage: String(describing: error)
            )
        }

        markTaskFinished()
    }

    private func markTaskFinished() {
        inFlightCount = max(0, inFlightCount - 1)
        scheduleAvailableWork()
        if !hasWorkToDrain {
            let continuations = drainedContinuations
            drainedContinuations = []
            continuations.forEach { $0.resume() }
        }
    }
}

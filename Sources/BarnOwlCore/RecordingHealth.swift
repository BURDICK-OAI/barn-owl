import Foundation

public enum RecordingHealthSourceKind: String, Codable, CaseIterable, Sendable {
    case microphone
    case systemAudio
}

public struct RMSLevelSample: Codable, Equatable, Sendable {
    public var occurredAt: TimeInterval
    public var rms: Double

    public init(occurredAt: TimeInterval, rms: Double) {
        self.occurredAt = occurredAt
        self.rms = Self.normalized(rms)
    }

    private static func normalized(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(1, max(0, value))
    }
}

public struct RMSLevelHistory: Codable, Equatable, Sendable {
    public private(set) var samples: [RMSLevelSample]
    public var capacity: Int

    public init(samples: [RMSLevelSample] = [], capacity: Int = 120) {
        let normalizedCapacity = max(1, capacity)
        self.capacity = normalizedCapacity
        self.samples = Self.trimmed(samples, capacity: normalizedCapacity)
    }

    public var latest: RMSLevelSample? {
        samples.last
    }

    public var latestRMS: Double? {
        latest?.rms
    }

    public var averageRMS: Double? {
        guard !samples.isEmpty else { return nil }
        return samples.reduce(0) { $0 + $1.rms } / Double(samples.count)
    }

    public var peakRMS: Double? {
        samples.map(\.rms).max()
    }

    public mutating func record(rms: Double, at occurredAt: TimeInterval) {
        samples.append(RMSLevelSample(occurredAt: occurredAt, rms: rms))
        samples = Self.trimmed(samples, capacity: capacity)
    }

    public func recording(rms: Double, at occurredAt: TimeInterval) -> RMSLevelHistory {
        var copy = self
        copy.record(rms: rms, at: occurredAt)
        return copy
    }

    public func samples(since lowerBound: TimeInterval) -> [RMSLevelSample] {
        samples.filter { $0.occurredAt >= lowerBound }
    }

    public func silentDuration(
        endingAt now: TimeInterval,
        silenceThreshold: Double
    ) -> TimeInterval? {
        let normalizedThreshold = RMSLevelSample(occurredAt: now, rms: silenceThreshold).rms
        guard let latest, latest.rms <= normalizedThreshold else {
            return nil
        }

        var silentStartedAt = latest.occurredAt
        for sample in samples.dropLast().reversed() {
            if sample.rms > normalizedThreshold {
                break
            }
            silentStartedAt = sample.occurredAt
        }

        return max(0, max(now, latest.occurredAt) - silentStartedAt)
    }

    private static func trimmed(_ samples: [RMSLevelSample], capacity: Int) -> [RMSLevelSample] {
        let ordered = samples.sorted { lhs, rhs in
            lhs.occurredAt < rhs.occurredAt
        }
        return Array(ordered.suffix(capacity))
    }
}

public enum RMSLevelMeter {
    public static func rmsLevel(forPCM16Samples samples: [Int16]) -> Double {
        guard !samples.isEmpty else { return 0 }

        let sumOfSquares = samples.reduce(0) { partialResult, sample in
            let normalized = Double(sample) / 32_768
            return partialResult + normalized * normalized
        }

        return min(1, sqrt(sumOfSquares / Double(samples.count)))
    }

    public static func rmsLevel(forPCM16Data data: Data) -> Double {
        let sampleCount = data.count / MemoryLayout<Int16>.size
        guard sampleCount > 0 else { return 0 }

        var sumOfSquares = 0.0
        data.withUnsafeBytes { rawBuffer in
            guard let bytes = rawBuffer.bindMemory(to: UInt8.self).baseAddress else {
                return
            }

            for index in 0..<sampleCount {
                let offset = index * MemoryLayout<Int16>.size
                let lowByte = UInt16(bytes[offset])
                let highByte = UInt16(bytes[offset + 1]) << 8
                let sample = Int16(bitPattern: highByte | lowByte)
                let normalized = Double(sample) / 32_768
                sumOfSquares += normalized * normalized
            }
        }

        return min(1, sqrt(sumOfSquares / Double(sampleCount)))
    }
}

public enum RecordingHealthErrorOrigin: String, Codable, Equatable, Sendable {
    case source
    case helper
}

public enum RecordingHealthErrorSeverity: String, Codable, Equatable, Sendable {
    case warning
    case recoverable
    case blocking
}

public struct RecordingHealthError: Codable, Equatable, Sendable {
    public var origin: RecordingHealthErrorOrigin
    public var severity: RecordingHealthErrorSeverity
    public var code: String
    public var message: String
    public var occurredAt: TimeInterval
    public var source: RecordingHealthSourceKind?

    public init(
        origin: RecordingHealthErrorOrigin,
        severity: RecordingHealthErrorSeverity,
        code: String,
        message: String,
        occurredAt: TimeInterval,
        source: RecordingHealthSourceKind? = nil
    ) {
        self.origin = origin
        self.severity = severity
        self.code = code
        self.message = message
        self.occurredAt = occurredAt
        self.source = source
    }

    public var isBlocking: Bool {
        severity == .blocking
    }
}

public struct RecordingHealthErrorHistory: Codable, Equatable, Sendable {
    public private(set) var errors: [RecordingHealthError]
    public var capacity: Int

    public init(errors: [RecordingHealthError] = [], capacity: Int = 20) {
        let normalizedCapacity = max(1, capacity)
        self.capacity = normalizedCapacity
        self.errors = Self.trimmed(errors, capacity: normalizedCapacity)
    }

    public var latest: RecordingHealthError? {
        errors.last
    }

    public var blockingErrors: [RecordingHealthError] {
        errors.filter(\.isBlocking)
    }

    public func latest(
        origin: RecordingHealthErrorOrigin? = nil,
        source: RecordingHealthSourceKind? = nil
    ) -> RecordingHealthError? {
        errors.last { error in
            let originMatches = origin == nil || error.origin == origin
            let sourceMatches = source == nil || error.source == source
            return originMatches && sourceMatches
        }
    }

    public mutating func record(_ error: RecordingHealthError) {
        errors.append(error)
        errors = Self.trimmed(errors, capacity: capacity)
    }

    public func recording(_ error: RecordingHealthError) -> RecordingHealthErrorHistory {
        var copy = self
        copy.record(error)
        return copy
    }

    private static func trimmed(
        _ errors: [RecordingHealthError],
        capacity: Int
    ) -> [RecordingHealthError] {
        let ordered = errors.sorted { lhs, rhs in
            lhs.occurredAt < rhs.occurredAt
        }
        return Array(ordered.suffix(capacity))
    }
}

public struct RecordingHealthPolicy: Codable, Equatable, Sendable {
    public var rmsSilenceThreshold: Double
    public var systemSilenceWarningThreshold: TimeInterval

    public init(
        rmsSilenceThreshold: Double = 0.01,
        systemSilenceWarningThreshold: TimeInterval = 10
    ) {
        self.rmsSilenceThreshold = RMSLevelSample(occurredAt: 0, rms: rmsSilenceThreshold).rms
        self.systemSilenceWarningThreshold = max(0, systemSilenceWarningThreshold)
    }

    public static let `default` = RecordingHealthPolicy()
}

public enum RecordingHealthWarningKind: String, Codable, Equatable, Sendable {
    case systemAudioSilent
}

public struct RecordingHealthWarning: Codable, Equatable, Sendable {
    public var kind: RecordingHealthWarningKind
    public var source: RecordingHealthSourceKind
    public var message: String
    public var duration: TimeInterval?
    public var threshold: TimeInterval?

    public init(
        kind: RecordingHealthWarningKind,
        source: RecordingHealthSourceKind,
        message: String,
        duration: TimeInterval? = nil,
        threshold: TimeInterval? = nil
    ) {
        self.kind = kind
        self.source = source
        self.message = message
        self.duration = duration
        self.threshold = threshold
    }
}

public struct RecordingSourceHealthSnapshot: Codable, Equatable, Sendable {
    public var source: RecordingHealthSourceKind
    public var isEnabled: Bool
    public var isCapturing: Bool
    public var levelHistory: RMSLevelHistory
    public var errorHistory: RecordingHealthErrorHistory

    public init(
        source: RecordingHealthSourceKind,
        isEnabled: Bool = false,
        isCapturing: Bool = false,
        levelHistory: RMSLevelHistory = RMSLevelHistory(),
        errorHistory: RecordingHealthErrorHistory = RecordingHealthErrorHistory()
    ) {
        self.source = source
        self.isEnabled = isEnabled
        self.isCapturing = isCapturing
        self.levelHistory = levelHistory
        self.errorHistory = errorHistory
    }

    public var latestRMS: Double? {
        levelHistory.latestRMS
    }

    public var blockingErrors: [RecordingHealthError] {
        errorHistory.blockingErrors
    }

    public mutating func recordRMSLevel(_ rms: Double, at occurredAt: TimeInterval) {
        levelHistory.record(rms: rms, at: occurredAt)
    }

    public func recordingRMSLevel(
        _ rms: Double,
        at occurredAt: TimeInterval
    ) -> RecordingSourceHealthSnapshot {
        var copy = self
        copy.recordRMSLevel(rms, at: occurredAt)
        return copy
    }

    public mutating func recordError(_ error: RecordingHealthError) {
        var sourceError = error
        sourceError.origin = .source
        sourceError.source = source
        errorHistory.record(sourceError)
    }

    public func recordingError(
        _ error: RecordingHealthError
    ) -> RecordingSourceHealthSnapshot {
        var copy = self
        copy.recordError(error)
        return copy
    }

    public func warnings(
        at now: TimeInterval,
        policy: RecordingHealthPolicy = .default
    ) -> [RecordingHealthWarning] {
        guard source == .systemAudio, isEnabled, isCapturing else {
            return []
        }

        guard let duration = levelHistory.silentDuration(
            endingAt: now,
            silenceThreshold: policy.rmsSilenceThreshold
        ), duration >= policy.systemSilenceWarningThreshold else {
            return []
        }

        return [
            RecordingHealthWarning(
                kind: .systemAudioSilent,
                source: source,
                message: "System audio has been silent for \(Self.secondsText(duration)).",
                duration: duration,
                threshold: policy.systemSilenceWarningThreshold
            )
        ]
    }

    private static func secondsText(_ value: TimeInterval) -> String {
        "\(Int(value.rounded()))s"
    }
}

public struct RecordingHealthSnapshot: Codable, Equatable, Sendable {
    public var microphone: RecordingSourceHealthSnapshot
    public var systemAudio: RecordingSourceHealthSnapshot
    public var helperErrors: RecordingHealthErrorHistory

    public init(
        microphone: RecordingSourceHealthSnapshot = RecordingSourceHealthSnapshot(source: .microphone),
        systemAudio: RecordingSourceHealthSnapshot = RecordingSourceHealthSnapshot(source: .systemAudio),
        helperErrors: RecordingHealthErrorHistory = RecordingHealthErrorHistory()
    ) {
        self.microphone = microphone
        self.systemAudio = systemAudio
        self.helperErrors = helperErrors
    }

    public static let idle = RecordingHealthSnapshot()

    public func sourceSnapshot(
        for source: RecordingHealthSourceKind
    ) -> RecordingSourceHealthSnapshot {
        switch source {
        case .microphone:
            microphone
        case .systemAudio:
            systemAudio
        }
    }

    public func sourceSnapshots(
        for configuration: AudioSourceConfiguration
    ) -> [RecordingSourceHealthSnapshot] {
        configuration.requiredRecordingHealthSources.map { sourceSnapshot(for: $0) }
    }

    public mutating func replaceSourceSnapshot(_ snapshot: RecordingSourceHealthSnapshot) {
        switch snapshot.source {
        case .microphone:
            microphone = snapshot
        case .systemAudio:
            systemAudio = snapshot
        }
    }

    public func replacingSourceSnapshot(
        _ snapshot: RecordingSourceHealthSnapshot
    ) -> RecordingHealthSnapshot {
        var copy = self
        copy.replaceSourceSnapshot(snapshot)
        return copy
    }

    public mutating func recordHelperError(_ error: RecordingHealthError) {
        var helperError = error
        helperError.origin = .helper
        helperError.source = nil
        helperErrors.record(helperError)
    }

    public func recordingHelperError(_ error: RecordingHealthError) -> RecordingHealthSnapshot {
        var copy = self
        copy.recordHelperError(error)
        return copy
    }

    public func readinessSummary(
        configuration: AudioSourceConfiguration,
        permissions: RecordingPermissionSet,
        now: TimeInterval,
        policy: RecordingHealthPolicy = .default
    ) -> RecordingReadinessSummary {
        RecordingHealthReadiness.summarize(
            configuration: configuration,
            permissions: permissions,
            health: self,
            now: now,
            policy: policy
        )
    }
}

public enum RecordingReadinessState: String, Codable, Equatable, Sendable {
    case ready
    case degraded
    case blocked
}

public struct RecordingReadinessSummary: Codable, Equatable, Sendable {
    public var state: RecordingReadinessState
    public var message: String
    public var requiredSources: [RecordingHealthSourceKind]
    public var missingPermissions: [CapturePermissionKind]
    public var warnings: [RecordingHealthWarning]
    public var blockingErrors: [RecordingHealthError]
    public var helperErrorCount: Int
    public var sourceErrorCount: Int

    public init(
        state: RecordingReadinessState,
        message: String,
        requiredSources: [RecordingHealthSourceKind],
        missingPermissions: [CapturePermissionKind] = [],
        warnings: [RecordingHealthWarning] = [],
        blockingErrors: [RecordingHealthError] = [],
        helperErrorCount: Int = 0,
        sourceErrorCount: Int = 0
    ) {
        self.state = state
        self.message = message
        self.requiredSources = requiredSources
        self.missingPermissions = missingPermissions
        self.warnings = warnings
        self.blockingErrors = blockingErrors
        self.helperErrorCount = helperErrorCount
        self.sourceErrorCount = sourceErrorCount
    }

    public var isReadyToRecord: Bool {
        state != .blocked
    }

    public var warningCount: Int {
        warnings.count
    }

    public var blockingErrorCount: Int {
        blockingErrors.count
    }
}

public enum RecordingHealthReadiness {
    public static func summarize(
        configuration: AudioSourceConfiguration,
        permissions: RecordingPermissionSet,
        health: RecordingHealthSnapshot,
        now: TimeInterval,
        policy: RecordingHealthPolicy = .default
    ) -> RecordingReadinessSummary {
        let requiredSources = configuration.requiredRecordingHealthSources
        let sourceSnapshots = health.sourceSnapshots(for: configuration)
        let missingPermissions = permissions.missingRequiredPermissions(for: configuration)
        let sourceErrors = sourceSnapshots.flatMap(\.errorHistory.errors)
        let helperErrors = health.helperErrors.errors
        let allErrors = sourceErrors + helperErrors
        let blockingErrors = allErrors.filter(\.isBlocking)
        let warnings = sourceSnapshots.flatMap { snapshot in
            snapshot.warnings(at: now, policy: policy)
        }

        if !missingPermissions.isEmpty {
            return RecordingReadinessSummary(
                state: .blocked,
                message: "Missing required recording permissions.",
                requiredSources: requiredSources,
                missingPermissions: missingPermissions,
                warnings: warnings,
                blockingErrors: blockingErrors,
                helperErrorCount: helperErrors.count,
                sourceErrorCount: sourceErrors.count
            )
        }

        if !blockingErrors.isEmpty {
            return RecordingReadinessSummary(
                state: .blocked,
                message: "Recording blocked by \(blockingErrors.count) health error(s).",
                requiredSources: requiredSources,
                warnings: warnings,
                blockingErrors: blockingErrors,
                helperErrorCount: helperErrors.count,
                sourceErrorCount: sourceErrors.count
            )
        }

        let onlyExpectedSystemSilence = !warnings.isEmpty
            && warnings.allSatisfy { $0.kind == .systemAudioSilent }
            && !allErrors.contains(where: { !$0.isBlocking })

        if onlyExpectedSystemSilence {
            return RecordingReadinessSummary(
                state: .ready,
                message: "Recording ready. System audio is quiet.",
                requiredSources: requiredSources,
                warnings: warnings,
                helperErrorCount: helperErrors.count,
                sourceErrorCount: sourceErrors.count
            )
        }

        if !warnings.isEmpty || allErrors.contains(where: { !$0.isBlocking }) {
            return RecordingReadinessSummary(
                state: .degraded,
                message: "Recording ready with health warnings.",
                requiredSources: requiredSources,
                warnings: warnings,
                helperErrorCount: helperErrors.count,
                sourceErrorCount: sourceErrors.count
            )
        }

        return RecordingReadinessSummary(
            state: .ready,
            message: "Recording ready.",
            requiredSources: requiredSources,
            helperErrorCount: helperErrors.count,
            sourceErrorCount: sourceErrors.count
        )
    }
}

public extension AudioSourceConfiguration {
    var requiredRecordingHealthSources: [RecordingHealthSourceKind] {
        var sources: [RecordingHealthSourceKind] = []

        if capturesMicrophone {
            sources.append(.microphone)
        }

        if capturesSystemAudio {
            sources.append(.systemAudio)
        }

        return sources
    }
}

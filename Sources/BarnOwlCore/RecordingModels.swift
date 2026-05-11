import Foundation

public enum RecordingStatus: String, Codable, Sendable {
    case idle
    case preparing
    case recording
    case processing
    case failed
}

public enum CapturePermissionKind: String, Codable, CaseIterable, Sendable {
    case microphone
    case systemAudioScreenCapture
}

public enum CapturePermissionDecision: String, Codable, Sendable {
    case unknown
    case notDetermined
    case checking
    case requesting
    case granted
    case denied
    case restricted
    case unavailable

    public var isReady: Bool {
        self == .granted
    }
}

public struct CapturePermissionState: Codable, Equatable, Sendable {
    public var kind: CapturePermissionKind
    public var decision: CapturePermissionDecision
    public var reason: String?

    public init(
        kind: CapturePermissionKind,
        decision: CapturePermissionDecision = .unknown,
        reason: String? = nil
    ) {
        self.kind = kind
        self.decision = decision
        self.reason = reason
    }

    public var isReady: Bool {
        decision.isReady
    }
}

public struct RecordingPermissionSet: Codable, Equatable, Sendable {
    public var microphone: CapturePermissionState
    public var systemAudio: CapturePermissionState

    public init(
        microphone: CapturePermissionState = .init(kind: .microphone),
        systemAudio: CapturePermissionState = .init(kind: .systemAudioScreenCapture)
    ) {
        self.microphone = microphone
        self.systemAudio = systemAudio
    }

    public static let unknown = RecordingPermissionSet()

    public static let grantedForDefaultMeetingCapture = RecordingPermissionSet(
        microphone: .init(kind: .microphone, decision: .granted),
        systemAudio: .init(kind: .systemAudioScreenCapture, decision: .granted)
    )

    public func permission(for kind: CapturePermissionKind) -> CapturePermissionState {
        switch kind {
        case .microphone:
            microphone
        case .systemAudioScreenCapture:
            systemAudio
        }
    }

    public func isReady(for configuration: AudioSourceConfiguration) -> Bool {
        missingRequiredPermissions(for: configuration).isEmpty
    }

    public func missingRequiredPermissions(
        for configuration: AudioSourceConfiguration
    ) -> [CapturePermissionKind] {
        var missing: [CapturePermissionKind] = []

        if configuration.capturesMicrophone && !microphone.isReady {
            missing.append(.microphone)
        }

        if configuration.capturesSystemAudio && !systemAudio.isReady {
            missing.append(.systemAudioScreenCapture)
        }

        return missing
    }
}

public struct AudioSourceConfiguration: Codable, Equatable, Sendable {
    public var capturesMicrophone: Bool
    public var capturesSystemAudio: Bool

    public init(capturesMicrophone: Bool, capturesSystemAudio: Bool) {
        self.capturesMicrophone = capturesMicrophone
        self.capturesSystemAudio = capturesSystemAudio
    }

    public static let defaultMeetingCapture = AudioSourceConfiguration(
        capturesMicrophone: true,
        capturesSystemAudio: true
    )
}

public struct RecordingSession: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var title: String
    public var startedAt: Date
    public var endedAt: Date?
    public var audioSources: AudioSourceConfiguration

    public init(
        id: UUID = UUID(),
        title: String,
        startedAt: Date,
        endedAt: Date? = nil,
        audioSources: AudioSourceConfiguration
    ) {
        self.id = id
        self.title = title
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.audioSources = audioSources
    }

    public func finished(at date: Date) -> RecordingSession {
        var copy = self
        copy.endedAt = date
        return copy
    }
}

public enum RecordingFailureReason: String, Codable, Sendable {
    case alreadyRecording
    case alreadyStopping
    case notRecording
    case permissionsNotReady
    case permissionDenied
    case captureUnavailable
    case captureFailed
    case missingAPIKey
    case processingFailed
    case unknown
}

public struct RecordingFailure: Codable, Equatable, Sendable {
    public var reason: RecordingFailureReason
    public var message: String
    public var sessionID: UUID?
    public var missingPermissions: [CapturePermissionKind]

    public init(
        reason: RecordingFailureReason,
        message: String,
        sessionID: UUID? = nil,
        missingPermissions: [CapturePermissionKind] = []
    ) {
        self.reason = reason
        self.message = message
        self.sessionID = sessionID
        self.missingPermissions = missingPermissions
    }
}

public enum RecordingLifecycleState: Codable, Equatable, Sendable {
    case idle
    case checkingPermissions(RecordingPermissionSet)
    case requestingPermissions(RecordingPermissionSet)
    case ready(RecordingPermissionSet)
    case preparing(RecordingSession)
    case recording(RecordingSession)
    case stopping(RecordingSession)
    case processing(RecordingSession)
    case completed(RecordingSession)
    case failed(RecordingFailure)

    public var status: RecordingStatus {
        switch self {
        case .idle, .ready, .completed:
            .idle
        case .checkingPermissions, .requestingPermissions, .preparing:
            .preparing
        case .recording:
            .recording
        case .stopping, .processing:
            .processing
        case .failed:
            .failed
        }
    }

    public var activeSession: RecordingSession? {
        switch self {
        case .preparing(let session),
             .recording(let session),
             .stopping(let session),
             .processing(let session),
             .completed(let session):
            session
        case .idle, .checkingPermissions, .requestingPermissions, .ready, .failed:
            nil
        }
    }

    public var canStartRecording: Bool {
        switch self {
        case .idle, .ready, .completed, .failed:
            true
        case .checkingPermissions,
             .requestingPermissions,
             .preparing,
             .recording,
             .stopping,
             .processing:
            false
        }
    }

    public var canStopRecording: Bool {
        if case .recording = self {
            return true
        }

        return false
    }
}

public enum RecordingTransitionResult: Codable, Equatable, Sendable {
    case accepted(RecordingLifecycleState)
    case rejected(RecordingFailure)
}

public struct RecordingStateMachine: Codable, Equatable, Sendable {
    public private(set) var state: RecordingLifecycleState

    public init(state: RecordingLifecycleState = .idle) {
        self.state = state
    }

    public var status: RecordingStatus {
        state.status
    }

    @discardableResult
    public mutating func checkPermissions(
        _ permissions: RecordingPermissionSet,
        for configuration: AudioSourceConfiguration = .defaultMeetingCapture
    ) -> RecordingTransitionResult {
        state = permissions.isReady(for: configuration)
            ? .ready(permissions)
            : .checkingPermissions(permissions)
        return .accepted(state)
    }

    @discardableResult
    public mutating func requestPermissions(
        _ permissions: RecordingPermissionSet,
        for configuration: AudioSourceConfiguration = .defaultMeetingCapture
    ) -> RecordingTransitionResult {
        state = permissions.isReady(for: configuration)
            ? .ready(permissions)
            : .requestingPermissions(permissions)
        return .accepted(state)
    }

    @discardableResult
    public mutating func beginStart(
        session: RecordingSession,
        permissions: RecordingPermissionSet
    ) -> RecordingTransitionResult {
        guard state.canStartRecording else {
            return reject(
                reason: .alreadyRecording,
                message: "Recording is already starting, active, stopping, or processing.",
                sessionID: state.activeSession?.id
            )
        }

        let missingPermissions = permissions.missingRequiredPermissions(for: session.audioSources)
        guard missingPermissions.isEmpty else {
            return reject(
                reason: .permissionsNotReady,
                message: "Required recording permissions are not ready.",
                sessionID: session.id,
                missingPermissions: missingPermissions
            )
        }

        state = .preparing(session)
        return .accepted(state)
    }

    @discardableResult
    public mutating func markRecording() -> RecordingTransitionResult {
        guard case .preparing(let session) = state else {
            return reject(
                reason: .notRecording,
                message: "Recording can only become active after preparation succeeds.",
                sessionID: state.activeSession?.id
            )
        }

        state = .recording(session)
        return .accepted(state)
    }

    @discardableResult
    public mutating func beginStop(at date: Date) -> RecordingTransitionResult {
        switch state {
        case .recording(let session):
            let finishedSession = session.finished(at: date)
            state = .stopping(finishedSession)
            return .accepted(state)
        case .stopping:
            return reject(
                reason: .alreadyStopping,
                message: "Recording is already stopping.",
                sessionID: state.activeSession?.id
            )
        default:
            return reject(
                reason: .notRecording,
                message: "There is no active recording to stop.",
                sessionID: state.activeSession?.id
            )
        }
    }

    @discardableResult
    public mutating func beginProcessing() -> RecordingTransitionResult {
        guard case .stopping(let session) = state else {
            return reject(
                reason: .notRecording,
                message: "Processing can only begin after stopping a recording.",
                sessionID: state.activeSession?.id
            )
        }

        state = .processing(session)
        return .accepted(state)
    }

    @discardableResult
    public mutating func complete() -> RecordingTransitionResult {
        guard case .processing(let session) = state else {
            return reject(
                reason: .processingFailed,
                message: "Recording can only complete from the processing state.",
                sessionID: state.activeSession?.id
            )
        }

        state = .completed(session)
        return .accepted(state)
    }

    @discardableResult
    public mutating func resetToIdle() -> RecordingTransitionResult {
        state = .idle
        return .accepted(state)
    }

    @discardableResult
    public mutating func fail(_ failure: RecordingFailure) -> RecordingTransitionResult {
        state = .failed(failure)
        return .accepted(state)
    }

    private func reject(
        reason: RecordingFailureReason,
        message: String,
        sessionID: UUID? = nil,
        missingPermissions: [CapturePermissionKind] = []
    ) -> RecordingTransitionResult {
        .rejected(
            .init(
                reason: reason,
                message: message,
                sessionID: sessionID,
                missingPermissions: missingPermissions
            )
        )
    }
}

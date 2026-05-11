import BarnOwlAudio
import BarnOwlCore
import Foundation
import Testing

@Test
func audioChunkIdentityPreservesSessionTrackAndOrder() {
    let sessionID = UUID(uuidString: "00000000-0000-0000-0000-000000000010")!
    let chunk = AudioChunk(
        sessionID: sessionID,
        trackKind: .systemAudio,
        sequenceNumber: 7,
        fileURL: URL(filePath: "/tmp/chunk.wav")
    )

    #expect(chunk.id == "00000000-0000-0000-0000-000000000010-systemAudio-7")
    #expect(chunk.trackKind == .systemAudio)
    #expect(chunk.sequenceNumber == 7)
}

private enum AudioCaptureEvent: Equatable, Sendable {
    case microphonePermission
    case microphoneStart
    case microphoneStop
    case systemAudioPermission
    case systemAudioStart
    case systemAudioStop
}

private enum FakeCaptureBehavior: Sendable {
    case succeeds
    case deniesPermission
    case failsStart
}

private actor AudioCaptureEventLog {
    private var events: [AudioCaptureEvent] = []

    func append(_ event: AudioCaptureEvent) {
        events.append(event)
    }

    func snapshot() -> [AudioCaptureEvent] {
        events
    }
}

private actor FakeMicrophoneAudioSource: MicrophoneAudioSource {
    private let behavior: FakeCaptureBehavior
    private let eventLog: AudioCaptureEventLog

    init(behavior: FakeCaptureBehavior = .succeeds, eventLog: AudioCaptureEventLog) {
        self.behavior = behavior
        self.eventLog = eventLog
    }

    func requestMicrophonePermission() async throws {
        await eventLog.append(.microphonePermission)
        if case .deniesPermission = behavior {
            throw AudioCaptureError.permissionDenied
        }
    }

    func startMicrophoneCapture(configuration: AudioSourceConfiguration) async throws {
        _ = configuration
        await eventLog.append(.microphoneStart)
        if case .failsStart = behavior {
            throw AudioCaptureError.sourceUnavailable
        }
    }

    func stopMicrophoneCapture() async {
        await eventLog.append(.microphoneStop)
    }
}

private actor FakeSystemAudioSource: SystemAudioSource {
    private let behavior: FakeCaptureBehavior
    private let eventLog: AudioCaptureEventLog

    init(behavior: FakeCaptureBehavior = .succeeds, eventLog: AudioCaptureEventLog) {
        self.behavior = behavior
        self.eventLog = eventLog
    }

    func requestSystemAudioPermission() async throws {
        await eventLog.append(.systemAudioPermission)
        if case .deniesPermission = behavior {
            throw AudioCaptureError.permissionDenied
        }
    }

    func startSystemAudioCapture(configuration: AudioSourceConfiguration) async throws {
        _ = configuration
        await eventLog.append(.systemAudioStart)
        if case .failsStart = behavior {
            throw AudioCaptureError.sourceUnavailable
        }
    }

    func stopSystemAudioCapture() async {
        await eventLog.append(.systemAudioStop)
    }
}

@Test
func audioSessionCoordinatorStartsMicrophoneBeforeSystemAudio() async throws {
    let eventLog = AudioCaptureEventLog()
    let coordinator = AudioSessionCoordinator(
        microphoneSource: FakeMicrophoneAudioSource(eventLog: eventLog),
        systemAudioSource: FakeSystemAudioSource(eventLog: eventLog)
    )

    try await coordinator.start(configuration: .defaultMeetingCapture)

    let events = await eventLog.snapshot()
    #expect(events == [
        .microphonePermission,
        .microphoneStart,
        .systemAudioPermission,
        .systemAudioStart
    ])

    await coordinator.stop()
}

@Test
func audioSessionCoordinatorKeepsMicrophoneAndSystemAudioAsSeparateTracks() async throws {
    let eventLog = AudioCaptureEventLog()
    let coordinator = AudioSessionCoordinator(
        microphoneSource: FakeMicrophoneAudioSource(eventLog: eventLog),
        systemAudioSource: FakeSystemAudioSource(eventLog: eventLog)
    )

    try await coordinator.start(configuration: .defaultMeetingCapture)

    let tracks = await coordinator.activeTrackKinds
    #expect(tracks == [.microphone, .systemAudio])
    #expect(!tracks.contains(.mixed))

    await coordinator.stop()
}

@Test
func audioSessionCoordinatorPropagatesPermissionDenialWithoutStartingSources() async {
    let eventLog = AudioCaptureEventLog()
    let coordinator = AudioSessionCoordinator(
        microphoneSource: FakeMicrophoneAudioSource(behavior: .deniesPermission, eventLog: eventLog),
        systemAudioSource: FakeSystemAudioSource(eventLog: eventLog)
    )

    var deniedPermission = false
    do {
        try await coordinator.start(configuration: .defaultMeetingCapture)
    } catch AudioCaptureError.permissionDenied {
        deniedPermission = true
    } catch {
        #expect(Bool(false), "Unexpected error: \(error)")
    }

    #expect(deniedPermission)
    #expect(await coordinator.activeTrackKinds == [])
    #expect(await eventLog.snapshot() == [.microphonePermission])
}

@Test
func audioSessionCoordinatorStopsAlreadyStartedSourceWhenLaterSourceFails() async {
    let eventLog = AudioCaptureEventLog()
    let coordinator = AudioSessionCoordinator(
        microphoneSource: FakeMicrophoneAudioSource(eventLog: eventLog),
        systemAudioSource: FakeSystemAudioSource(behavior: .failsStart, eventLog: eventLog)
    )

    var sourceUnavailable = false
    do {
        try await coordinator.start(configuration: .defaultMeetingCapture)
    } catch AudioCaptureError.sourceUnavailable {
        sourceUnavailable = true
    } catch {
        #expect(Bool(false), "Unexpected error: \(error)")
    }

    #expect(sourceUnavailable)
    #expect(await coordinator.activeTrackKinds == [])
    #expect(await eventLog.snapshot() == [
        .microphonePermission,
        .microphoneStart,
        .systemAudioPermission,
        .systemAudioStart,
        .microphoneStop
    ])
}

@Test
func audioSessionCoordinatorRejectsDoubleStartAndStopIsIdempotent() async throws {
    let eventLog = AudioCaptureEventLog()
    let coordinator = AudioSessionCoordinator(
        microphoneSource: FakeMicrophoneAudioSource(eventLog: eventLog),
        systemAudioSource: FakeSystemAudioSource(eventLog: eventLog)
    )

    try await coordinator.start(configuration: AudioSourceConfiguration(
        capturesMicrophone: true,
        capturesSystemAudio: false
    ))

    var alreadyRunning = false
    do {
        try await coordinator.start(configuration: .defaultMeetingCapture)
    } catch AudioCaptureError.alreadyRunning {
        alreadyRunning = true
    } catch {
        #expect(Bool(false), "Unexpected error: \(error)")
    }

    await coordinator.stop()
    await coordinator.stop()

    #expect(alreadyRunning)
    #expect(await coordinator.activeTrackKinds == [])
    #expect(await eventLog.snapshot() == [
        .microphonePermission,
        .microphoneStart,
        .microphoneStop
    ])
}

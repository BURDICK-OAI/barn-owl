import AVFoundation
import BarnOwlCore
import Foundation
import ScreenCaptureKit

public enum AudioCaptureError: Error, Equatable, Sendable {
    case permissionDenied
    case sourceUnavailable
    case alreadyRunning
}

public protocol MicrophonePermissionAuthorizing: Sendable {
    func requestMicrophonePermission() async throws
}

public protocol MicrophoneCapturing: Sendable {
    func startMicrophoneCapture(configuration: AudioSourceConfiguration) async throws
    func stopMicrophoneCapture() async
}

public protocol MicrophoneAudioSource: MicrophonePermissionAuthorizing, MicrophoneCapturing {}

public protocol SystemAudioPermissionAuthorizing: Sendable {
    func requestSystemAudioPermission() async throws
}

public protocol SystemAudioCapturing: Sendable {
    func startSystemAudioCapture(configuration: AudioSourceConfiguration) async throws
    func stopSystemAudioCapture() async
}

public protocol SystemAudioSource: SystemAudioPermissionAuthorizing, SystemAudioCapturing {}

public final class AVFoundationMicrophoneAudioSource: MicrophoneAudioSource, @unchecked Sendable {
    private let engine = AVAudioEngine()

    public init() {}

    public func requestMicrophonePermission() async throws {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return
        case .denied, .restricted:
            throw AudioCaptureError.permissionDenied
        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            if !granted {
                throw AudioCaptureError.permissionDenied
            }
        @unknown default:
            throw AudioCaptureError.permissionDenied
        }
    }

    public func startMicrophoneCapture(configuration: AudioSourceConfiguration) async throws {
        _ = configuration
        _ = engine.inputNode
    }

    public func stopMicrophoneCapture() async {
        engine.stop()
    }
}

public final class ScreenCaptureKitSystemAudioSource: SystemAudioSource, @unchecked Sendable {
    private var stream: SCStream?

    public init() {}

    public func requestSystemAudioPermission() async throws {
        guard #available(macOS 12.3, *) else {
            throw AudioCaptureError.sourceUnavailable
        }
    }

    public func startSystemAudioCapture(configuration: AudioSourceConfiguration) async throws {
        _ = configuration
        _ = stream
    }

    public func stopSystemAudioCapture() async {
        stream = nil
    }
}

public actor AudioSessionCoordinator {
    private var isRunning = false
    private var runningSources: [AudioTrackKind] = []
    private let microphoneSource: any MicrophoneAudioSource
    private let systemAudioSource: any SystemAudioSource
    private let flushOnStop: (@Sendable () async -> Void)?

    public var activeTrackKinds: [AudioTrackKind] {
        runningSources
    }

    public init(
        microphoneSource: any MicrophoneAudioSource = AVFoundationMicrophoneAudioSource(),
        systemAudioSource: any SystemAudioSource = ScreenCaptureKitSystemAudioSource(),
        flushOnStop: (@Sendable () async -> Void)? = nil
    ) {
        self.microphoneSource = microphoneSource
        self.systemAudioSource = systemAudioSource
        self.flushOnStop = flushOnStop
    }

    public func start(configuration: AudioSourceConfiguration) async throws {
        guard !isRunning else { throw AudioCaptureError.alreadyRunning }
        isRunning = true

        var startedSources: [AudioTrackKind] = []
        do {
            if configuration.capturesMicrophone {
                try await microphoneSource.requestMicrophonePermission()
                try await microphoneSource.startMicrophoneCapture(configuration: configuration)
                startedSources.append(.microphone)
                runningSources = startedSources
            }

            if configuration.capturesSystemAudio {
                try await systemAudioSource.requestSystemAudioPermission()
                try await systemAudioSource.startSystemAudioCapture(configuration: configuration)
                startedSources.append(.systemAudio)
                runningSources = startedSources
            }
        } catch {
            await stop(sources: startedSources)
            runningSources = []
            isRunning = false
            throw error
        }
    }

    public func stop() async {
        await stop(sources: runningSources)
        await flushOnStop?()
        runningSources = []
        isRunning = false
    }

    private func stop(sources: [AudioTrackKind]) async {
        for source in sources.reversed() {
            switch source {
            case .microphone:
                await microphoneSource.stopMicrophoneCapture()
            case .systemAudio:
                await systemAudioSource.stopSystemAudioCapture()
            case .mixed:
                break
            }
        }
    }
}

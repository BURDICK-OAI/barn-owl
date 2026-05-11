@preconcurrency import AVFoundation
import BarnOwlCore
import Foundation

public protocol MicrophoneCaptureBufferWriting: Sendable {
    func writeMicrophoneBuffer(_ buffer: AVAudioPCMBuffer, at time: AVAudioTime) throws
}

public typealias MicrophoneCaptureTapBlock = @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void

public protocol MicrophoneCaptureDriving: Sendable {
    var isRunning: Bool { get }

    func inputFormat() -> AVAudioFormat
    func installInputTap(
        bufferSize: AVAudioFrameCount,
        format: AVAudioFormat,
        block: @escaping MicrophoneCaptureTapBlock
    ) throws
    func removeInputTap()
    func prepare()
    func start() throws
    func stop()
}

public struct AVFoundationMicrophonePermissionAuthorizer: MicrophonePermissionAuthorizing, Sendable {
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
}

public final class AVAudioEngineMicrophoneCaptureDriver: MicrophoneCaptureDriving, @unchecked Sendable {
    private let engine: AVAudioEngine
    private let inputBus: AVAudioNodeBus

    public init(engine: AVAudioEngine = AVAudioEngine(), inputBus: AVAudioNodeBus = 0) {
        self.engine = engine
        self.inputBus = inputBus
    }

    public var isRunning: Bool {
        engine.isRunning
    }

    public func inputFormat() -> AVAudioFormat {
        engine.inputNode.outputFormat(forBus: inputBus)
    }

    public func installInputTap(
        bufferSize: AVAudioFrameCount,
        format: AVAudioFormat,
        block: @escaping MicrophoneCaptureTapBlock
    ) throws {
        engine.inputNode.installTap(onBus: inputBus, bufferSize: bufferSize, format: format) { buffer, time in
            block(buffer, time)
        }
    }

    public func removeInputTap() {
        engine.inputNode.removeTap(onBus: inputBus)
    }

    public func prepare() {
        engine.prepare()
    }

    public func start() throws {
        try engine.start()
    }

    public func stop() {
        engine.stop()
    }
}

public final class AVAudioEngineMicrophoneCaptureSource: MicrophoneAudioSource, @unchecked Sendable {
    public typealias CaptureErrorHandler = @Sendable (Error) -> Void

    private enum CaptureState {
        case idle
        case starting
        case running
        case stopping
    }

    private let driver: any MicrophoneCaptureDriving
    private let writer: any MicrophoneCaptureBufferWriting
    private let permissionAuthorizer: any MicrophonePermissionAuthorizing
    private let bufferSize: AVAudioFrameCount
    private let stateLock = NSLock()
    private let failureQueue = DispatchQueue(label: "com.barnowl.audio.microphone-capture.failure")
    private let onCaptureError: CaptureErrorHandler?
    private var state: CaptureState = .idle

    public init(
        writer: any MicrophoneCaptureBufferWriting,
        driver: any MicrophoneCaptureDriving = AVAudioEngineMicrophoneCaptureDriver(),
        permissionAuthorizer: any MicrophonePermissionAuthorizing = AVFoundationMicrophonePermissionAuthorizer(),
        bufferSize: AVAudioFrameCount = 4_096,
        onCaptureError: CaptureErrorHandler? = nil
    ) {
        self.writer = writer
        self.driver = driver
        self.permissionAuthorizer = permissionAuthorizer
        self.bufferSize = bufferSize
        self.onCaptureError = onCaptureError
    }

    public var isCapturing: Bool {
        stateLock.withLock {
            state == .running || state == .starting
        }
    }

    public func requestMicrophonePermission() async throws {
        try await permissionAuthorizer.requestMicrophonePermission()
    }

    public func startMicrophoneCapture(configuration: AudioSourceConfiguration) async throws {
        guard configuration.capturesMicrophone else { return }

        guard beginStartIfIdle() else { return }

        let format = driver.inputFormat()
        guard format.channelCount > 0 else {
            finishStartAfterFailure()
            throw AudioCaptureError.sourceUnavailable
        }

        do {
            try driver.installInputTap(bufferSize: bufferSize, format: format) { [weak self, writer] buffer, time in
                do {
                    try writer.writeMicrophoneBuffer(buffer, at: time)
                } catch {
                    self?.stopAfterCaptureFailure(error)
                }
            }
            driver.prepare()
            try driver.start()
            finishStartAfterSuccess()
        } catch {
            cleanupDriverAfterFailedStart()
            finishStartAfterFailure()
            throw error
        }
    }

    public func stopMicrophoneCapture() async {
        guard beginStopIfNeeded() else { return }
        driver.removeInputTap()
        driver.stop()
        finishStop()
    }

    private func beginStartIfIdle() -> Bool {
        stateLock.withLock {
            guard state == .idle else { return false }
            state = .starting
            return true
        }
    }

    private func finishStartAfterSuccess() {
        stateLock.withLock {
            state = .running
        }
    }

    private func finishStartAfterFailure() {
        stateLock.withLock {
            state = .idle
        }
    }

    private func beginStopIfNeeded() -> Bool {
        stateLock.withLock {
            guard state != .idle else { return false }
            state = .stopping
            return true
        }
    }

    private func finishStop() {
        stateLock.withLock {
            state = .idle
        }
    }

    private func cleanupDriverAfterFailedStart() {
        driver.removeInputTap()
        driver.stop()
    }

    private func stopAfterCaptureFailure(_ error: Error) {
        failureQueue.async { [weak self] in
            guard let self else { return }
            guard self.beginStopIfNeeded() else { return }
            self.driver.removeInputTap()
            self.driver.stop()
            self.finishStop()
            self.onCaptureError?(error)
        }
    }
}

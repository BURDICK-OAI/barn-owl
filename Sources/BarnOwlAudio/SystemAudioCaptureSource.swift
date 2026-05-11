import BarnOwlCore
import CoreGraphics
import CoreMedia
import Foundation
import ScreenCaptureKit

public protocol SystemAudioSampleBufferWriter: AnyObject {
    func writeSystemAudioSampleBuffer(_ sampleBuffer: CMSampleBuffer) throws
}

public struct SystemAudioCaptureDisplay: Equatable, Sendable {
    public var displayID: CGDirectDisplayID
    public var width: Int
    public var height: Int
    public var isMainDisplay: Bool

    public init(displayID: CGDirectDisplayID, width: Int, height: Int, isMainDisplay: Bool) {
        self.displayID = displayID
        self.width = width
        self.height = height
        self.isMainDisplay = isMainDisplay
    }

    public var pixelArea: Int {
        width * height
    }
}

public struct SystemAudioCaptureStreamSettings: Equatable, Sendable {
    public var sampleRate: Int
    public var channelCount: Int
    public var queueDepth: Int
    public var excludesCurrentProcessAudio: Bool

    public init(
        sampleRate: Int = 48_000,
        channelCount: Int = 2,
        queueDepth: Int = 1,
        excludesCurrentProcessAudio: Bool = true
    ) {
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.queueDepth = queueDepth
        self.excludesCurrentProcessAudio = excludesCurrentProcessAudio
    }

    public static let systemAudioOnly = SystemAudioCaptureStreamSettings()

    public func makeScreenCaptureKitConfiguration() -> SCStreamConfiguration {
        let configuration = SCStreamConfiguration()
        configuration.capturesAudio = true
        configuration.captureMicrophone = false
        configuration.excludesCurrentProcessAudio = excludesCurrentProcessAudio
        configuration.sampleRate = sampleRate
        configuration.channelCount = channelCount
        configuration.width = 1
        configuration.height = 1
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        configuration.queueDepth = queueDepth
        configuration.showsCursor = false
        return configuration
    }
}

public enum SystemAudioCaptureSourceSelection {
    public static func selectDisplay(from displays: [SystemAudioCaptureDisplay]) -> SystemAudioCaptureDisplay? {
        displays.first(where: \.isMainDisplay) ?? displays.max { lhs, rhs in
            lhs.pixelArea < rhs.pixelArea
        }
    }

    public static func audioCaptureError(for error: Error) -> AudioCaptureError {
        let nsError = error as NSError
        guard nsError.domain == SCStreamErrorDomain else {
            return .sourceUnavailable
        }

        switch SCStreamError.Code(rawValue: nsError.code) {
        case .userDeclined:
            return .permissionDenied
        case .noDisplayList, .noWindowList, .noCaptureSource:
            return .sourceUnavailable
        default:
            return .sourceUnavailable
        }
    }
}

public final class ScreenCaptureKitSystemAudioCaptureSource: NSObject, SystemAudioSource, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    public typealias RuntimeErrorHandler = @Sendable (AudioCaptureError) -> Void
    public typealias WriterErrorHandler = @Sendable (Error) -> Void

    private let writer: any SystemAudioSampleBufferWriter
    private let streamSettings: SystemAudioCaptureStreamSettings
    private let sampleQueue: DispatchQueue
    private let runtimeErrorHandler: RuntimeErrorHandler?
    private let writerErrorHandler: WriterErrorHandler?
    private let stateLock = NSLock()

    private var stream: SCStream?
    private var isStarting = false
    private var hasAudioOutput = false

    public init(
        writer: (any SystemAudioSampleBufferWriter)? = nil,
        streamSettings: SystemAudioCaptureStreamSettings = .systemAudioOnly,
        sampleQueue: DispatchQueue = DispatchQueue(label: "com.barnowl.system-audio.samples"),
        runtimeErrorHandler: RuntimeErrorHandler? = nil,
        writerErrorHandler: WriterErrorHandler? = nil
    ) {
        self.writer = writer ?? NoOpSystemAudioSampleBufferWriter()
        self.streamSettings = streamSettings
        self.sampleQueue = sampleQueue
        self.runtimeErrorHandler = runtimeErrorHandler
        self.writerErrorHandler = writerErrorHandler
    }

    public func requestSystemAudioPermission() async throws {
        do {
            let content = try await SCShareableContent.current
            guard !content.displays.isEmpty else {
                throw AudioCaptureError.sourceUnavailable
            }
        } catch let error as AudioCaptureError {
            throw error
        } catch {
            throw SystemAudioCaptureSourceSelection.audioCaptureError(for: error)
        }
    }

    public func startSystemAudioCapture(configuration: AudioSourceConfiguration) async throws {
        guard configuration.capturesSystemAudio else {
            return
        }

        try markStarting()
        var newStream: SCStream?
        var addedAudioOutput = false

        do {
            let content = try await SCShareableContent.current
            guard let display = Self.selectDisplay(from: content.displays) else {
                markStopped()
                throw AudioCaptureError.sourceUnavailable
            }

            let filter = SCContentFilter(display: display, excludingWindows: [])
            let streamConfiguration = streamSettings.makeScreenCaptureKitConfiguration()
            newStream = SCStream(filter: filter, configuration: streamConfiguration, delegate: self)

            guard let newStream else {
                markStopped()
                throw AudioCaptureError.sourceUnavailable
            }

            try newStream.addStreamOutput(self, type: .audio, sampleHandlerQueue: sampleQueue)
            addedAudioOutput = true
            try await newStream.startCapture()

            stateLock.withLock {
                stream = newStream
                isStarting = false
                hasAudioOutput = true
            }
        } catch let error as AudioCaptureError {
            await cleanUpFailedStart(stream: newStream, addedAudioOutput: addedAudioOutput)
            throw error
        } catch {
            await cleanUpFailedStart(stream: newStream, addedAudioOutput: addedAudioOutput)
            throw SystemAudioCaptureSourceSelection.audioCaptureError(for: error)
        }
    }

    public func stopSystemAudioCapture() async {
        let streamToStop: SCStream?
        let shouldRemoveAudioOutput: Bool

        (streamToStop, shouldRemoveAudioOutput) = stateLock.withLock {
            let currentStream = stream
            let currentHasAudioOutput = hasAudioOutput
            stream = nil
            isStarting = false
            hasAudioOutput = false
            return (currentStream, currentHasAudioOutput)
        }

        guard let streamToStop else {
            return
        }

        if shouldRemoveAudioOutput {
            try? streamToStop.removeStreamOutput(self, type: .audio)
        }

        try? await streamToStop.stopCapture()
    }

    public func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid else {
            return
        }

        do {
            try writer.writeSystemAudioSampleBuffer(sampleBuffer)
        } catch {
            writerErrorHandler?(error)
        }
    }

    public func stream(_ stream: SCStream, didStopWithError error: Error) {
        runtimeErrorHandler?(SystemAudioCaptureSourceSelection.audioCaptureError(for: error))
    }

    private func markStarting() throws {
        try stateLock.withLock {
            guard stream == nil, !isStarting else {
                throw AudioCaptureError.alreadyRunning
            }

            isStarting = true
            hasAudioOutput = false
        }
    }

    private func markStopped() {
        stateLock.withLock {
            stream = nil
            isStarting = false
            hasAudioOutput = false
        }
    }

    private func cleanUpFailedStart(stream failedStream: SCStream?, addedAudioOutput: Bool) async {
        markStopped()

        guard let failedStream else {
            return
        }

        if addedAudioOutput {
            try? failedStream.removeStreamOutput(self, type: .audio)
        }

        try? await failedStream.stopCapture()
    }

    private static func selectDisplay(from displays: [SCDisplay]) -> SCDisplay? {
        let displayDescriptions = displays.map { display in
            SystemAudioCaptureDisplay(
                displayID: display.displayID,
                width: display.width,
                height: display.height,
                isMainDisplay: display.displayID == CGMainDisplayID()
            )
        }

        guard let selected = SystemAudioCaptureSourceSelection.selectDisplay(from: displayDescriptions) else {
            return nil
        }

        return displays.first { $0.displayID == selected.displayID }
    }
}

private final class NoOpSystemAudioSampleBufferWriter: SystemAudioSampleBufferWriter {
    func writeSystemAudioSampleBuffer(_ sampleBuffer: CMSampleBuffer) throws {
        _ = sampleBuffer
    }
}

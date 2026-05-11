@preconcurrency import AVFoundation
import Foundation

public struct CapturedAudioChunkReservation: Equatable, Sendable {
    public var sessionID: UUID
    public var trackKind: AudioTrackKind
    public var sequenceNumber: Int
    public var fileURL: URL

    public init(sessionID: UUID, trackKind: AudioTrackKind, sequenceNumber: Int, fileURL: URL) {
        self.sessionID = sessionID
        self.trackKind = trackKind
        self.sequenceNumber = sequenceNumber
        self.fileURL = fileURL
    }
}

public struct CapturedAudioChunkTimingMetadata: Equatable, Sendable {
    public var startTimeOffset: TimeInterval
    public var duration: TimeInterval
    public var chunkDuration: TimeInterval
    public var overlapDuration: TimeInterval
    public var strideDuration: TimeInterval

    public init(
        startTimeOffset: TimeInterval,
        duration: TimeInterval,
        chunkDuration: TimeInterval,
        overlapDuration: TimeInterval,
        strideDuration: TimeInterval
    ) {
        self.startTimeOffset = startTimeOffset
        self.duration = duration
        self.chunkDuration = chunkDuration
        self.overlapDuration = overlapDuration
        self.strideDuration = strideDuration
    }
}

public protocol CapturedAudioChunkStore: Sendable {
    func reserveChunk(
        sessionID: UUID,
        trackKind: AudioTrackKind,
        sequenceNumber: Int,
        fileExtension: String
    ) async throws -> CapturedAudioChunkReservation

    func markChunkWritten(_ reservation: CapturedAudioChunkReservation) async throws
    func markChunkWritten(
        _ reservation: CapturedAudioChunkReservation,
        timingMetadata: CapturedAudioChunkTimingMetadata?
    ) async throws
}

public extension CapturedAudioChunkStore {
    func markChunkWritten(
        _ reservation: CapturedAudioChunkReservation,
        timingMetadata: CapturedAudioChunkTimingMetadata?
    ) async throws {
        _ = timingMetadata
        try await markChunkWritten(reservation)
    }
}

public protocol CapturedAudioChunkWriter: Sendable {
    func writeChunk(
        _ buffer: AVAudioPCMBuffer,
        sessionID: UUID,
        trackKind: AudioTrackKind
    ) async throws -> AudioChunk

    func writeChunk(
        _ buffers: [AVAudioPCMBuffer],
        sessionID: UUID,
        trackKind: AudioTrackKind
    ) async throws -> AudioChunk

    func writeChunk(
        _ buffers: [AVAudioPCMBuffer],
        sessionID: UUID,
        trackKind: AudioTrackKind,
        timingMetadata: CapturedAudioChunkTimingMetadata?
    ) async throws -> AudioChunk
}

public extension CapturedAudioChunkWriter {
    func writeChunk(
        _ buffers: [AVAudioPCMBuffer],
        sessionID: UUID,
        trackKind: AudioTrackKind,
        timingMetadata: CapturedAudioChunkTimingMetadata?
    ) async throws -> AudioChunk {
        _ = timingMetadata
        return try await writeChunk(buffers, sessionID: sessionID, trackKind: trackKind)
    }
}

public final class AudioFileChunkWriter: CapturedAudioChunkWriter, @unchecked Sendable {
    private let store: any CapturedAudioChunkStore
    private let sequenceNumbers = AudioChunkSequenceNumbers()

    public init(store: any CapturedAudioChunkStore) {
        self.store = store
    }

    public func writeChunk(
        _ buffer: AVAudioPCMBuffer,
        sessionID: UUID,
        trackKind: AudioTrackKind
    ) async throws -> AudioChunk {
        try await writeChunk([buffer], sessionID: sessionID, trackKind: trackKind)
    }

    public func writeChunk(
        _ buffers: [AVAudioPCMBuffer],
        sessionID: UUID,
        trackKind: AudioTrackKind
    ) async throws -> AudioChunk {
        try await writeChunk(
            buffers,
            sessionID: sessionID,
            trackKind: trackKind,
            timingMetadata: nil
        )
    }

    public func writeChunk(
        _ buffers: [AVAudioPCMBuffer],
        sessionID: UUID,
        trackKind: AudioTrackKind,
        timingMetadata: CapturedAudioChunkTimingMetadata?
    ) async throws -> AudioChunk {
        guard let firstBuffer = buffers.first else {
            throw AudioCaptureError.sourceUnavailable
        }

        let sequenceNumber = await sequenceNumbers.nextSequenceNumber(for: trackKind)
        let reservation = try await store.reserveChunk(
            sessionID: sessionID,
            trackKind: trackKind,
            sequenceNumber: sequenceNumber,
            fileExtension: "wav"
        )

        let fileFormat = try Self.normalizedWAVFormat(from: firstBuffer.format)
        let file = try AVAudioFile(forWriting: reservation.fileURL, settings: fileFormat.settings)
        for buffer in buffers {
            let writableBuffer = try Self.convert(buffer, to: fileFormat)
            try file.write(from: writableBuffer)
        }
        try await store.markChunkWritten(reservation, timingMetadata: timingMetadata)

        return AudioChunk(
            sessionID: sessionID,
            trackKind: trackKind,
            sequenceNumber: sequenceNumber,
            fileURL: reservation.fileURL
        )
    }

    private static func normalizedWAVFormat(from sourceFormat: AVAudioFormat) throws -> AVAudioFormat {
        guard sourceFormat.sampleRate > 0, sourceFormat.channelCount > 0 else {
            throw AudioCaptureError.sourceUnavailable
        }

        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sourceFormat.sampleRate,
            channels: sourceFormat.channelCount,
            interleaved: false
        ) else {
            throw AudioCaptureError.sourceUnavailable
        }

        return format
    }

    private static func convert(_ buffer: AVAudioPCMBuffer, to outputFormat: AVAudioFormat) throws -> AVAudioPCMBuffer {
        guard buffer.frameLength > 0 else {
            guard let emptyBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: 0) else {
                throw AudioCaptureError.sourceUnavailable
            }
            return emptyBuffer
        }

        if hasSamePCMLayout(buffer.format, as: outputFormat) {
            return buffer
        }

        guard let converter = AVAudioConverter(from: buffer.format, to: outputFormat) else {
            throw AudioCaptureError.sourceUnavailable
        }

        let frameRatio = outputFormat.sampleRate / buffer.format.sampleRate
        let outputCapacity = AVAudioFrameCount(ceil(Double(buffer.frameLength) * frameRatio)) + 1
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: outputCapacity) else {
            throw AudioCaptureError.sourceUnavailable
        }

        let inputState = AudioConverterInputState()
        var conversionError: NSError?
        let status = converter.convert(to: outputBuffer, error: &conversionError) { _, outputStatus in
            if inputState.didProvideInput {
                outputStatus.pointee = .noDataNow
                return nil
            }

            inputState.didProvideInput = true
            outputStatus.pointee = .haveData
            return buffer
        }

        if let conversionError {
            throw conversionError
        }

        switch status {
        case .haveData, .inputRanDry, .endOfStream:
            return outputBuffer
        case .error:
            throw AudioCaptureError.sourceUnavailable
        @unknown default:
            throw AudioCaptureError.sourceUnavailable
        }
    }

    private static func hasSamePCMLayout(_ lhs: AVAudioFormat, as rhs: AVAudioFormat) -> Bool {
        lhs.commonFormat == rhs.commonFormat
            && lhs.sampleRate == rhs.sampleRate
            && lhs.channelCount == rhs.channelCount
            && lhs.isInterleaved == rhs.isInterleaved
    }
}

private final class AudioConverterInputState: @unchecked Sendable {
    var didProvideInput = false
}

private actor AudioChunkSequenceNumbers {
    private var nextByTrackKind: [AudioTrackKind: Int] = [:]

    func nextSequenceNumber(for trackKind: AudioTrackKind) -> Int {
        let sequenceNumber = nextByTrackKind[trackKind, default: 0]
        nextByTrackKind[trackKind] = sequenceNumber + 1
        return sequenceNumber
    }
}

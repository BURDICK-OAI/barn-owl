@preconcurrency import AVFoundation
import BarnOwlAudio
import BarnOwlPersistence
import CoreMedia
import Foundation

enum BarnOwlAudioCaptureFactory {
    typealias AudioCaptureProgressHandler = @MainActor @Sendable (AudioCaptureProgress) -> Void
    typealias AudioRealtimePCMHandler = @Sendable (AudioRealtimePCMChunk) -> Void

    static let tempRoot = FileManager.default.temporaryDirectory
        .appending(path: "BarnOwl", directoryHint: .isDirectory)
        .appending(path: "AudioChunks", directoryHint: .isDirectory)

    static func makeCoordinator(
        sessionID: UUID,
        progressHandler: AudioCaptureProgressHandler? = nil,
        realtimePCMHandler: AudioRealtimePCMHandler? = nil
    ) -> AudioSessionCoordinator {
        let tempStore = FilesystemTempAudioChunkStore(rootDirectory: tempRoot)
        let captureStore = TempAudioCaptureStoreAdapter(store: tempStore)
        let chunkWriter = AudioFileChunkWriter(store: captureStore)
        let sink = SessionAudioChunkSink(
            sessionID: sessionID,
            chunkWriter: chunkWriter,
            progressHandler: progressHandler,
            realtimePCMHandler: realtimePCMHandler
        )

        return AudioSessionCoordinator(
            microphoneSource: AVAudioEngineMicrophoneCaptureSource(writer: sink),
            systemAudioSource: CoreAudioTapSystemAudioCaptureSource(writer: sink),
            flushOnStop: { await sink.flush() }
        )
    }

    static func cleanupTemporaryAudio() async {
        try? FileManager.default.removeItem(at: tempRoot)
    }

    static func deleteTemporaryAudio(for sessionID: UUID) async {
        let sessionDirectory = tempRoot.appending(path: sessionID.uuidString, directoryHint: .isDirectory)
        try? FileManager.default.removeItem(at: sessionDirectory)
    }

    static func finalizeTemporaryAudio(for sessionID: UUID) async throws -> TempAudioSessionFinalizationReport {
        let tempStore = FilesystemTempAudioChunkStore(rootDirectory: tempRoot)
        return try await tempStore.finalizeSessionChunks(for: sessionID)
    }
}

struct AudioCaptureProgress: Sendable {
    var trackKind: AudioTrackKind
    var sequenceNumber: Int?
    var fileURL: URL?
    var startTimeOffset: TimeInterval?
    var duration: TimeInterval
    var chunkDuration: TimeInterval?
    var overlapDuration: TimeInterval?
    var strideDuration: TimeInterval?
    var byteCount: Int?
    var errorMessage: String?
}

struct AudioRealtimePCMChunk: Sendable {
    var trackKind: AudioTrackKind
    var pcm16Data: Data
    var sampleRate: Int
    var duration: TimeInterval
}

private struct TempAudioCaptureStoreAdapter: CapturedAudioChunkStore {
    private let store: any TempAudioChunkStore

    init(store: any TempAudioChunkStore) {
        self.store = store
    }

    func reserveChunk(
        sessionID: UUID,
        trackKind: AudioTrackKind,
        sequenceNumber: Int,
        fileExtension: String
    ) async throws -> CapturedAudioChunkReservation {
        let reservation = try await store.reserveChunk(
            sessionID: sessionID,
            trackKind: trackKind.rawValue,
            sequenceNumber: sequenceNumber,
            fileExtension: fileExtension
        )

        return CapturedAudioChunkReservation(
            sessionID: reservation.key.sessionID,
            trackKind: trackKind,
            sequenceNumber: reservation.key.sequenceNumber,
            fileURL: reservation.audioFileURL
        )
    }

    func markChunkWritten(_ reservation: CapturedAudioChunkReservation) async throws {
        try await markChunkWritten(reservation, timingMetadata: nil)
    }

    func markChunkWritten(
        _ reservation: CapturedAudioChunkReservation,
        timingMetadata: CapturedAudioChunkTimingMetadata?
    ) async throws {
        let key = TempAudioChunkKey(
            sessionID: reservation.sessionID,
            trackKind: reservation.trackKind.rawValue,
            sequenceNumber: reservation.sequenceNumber
        )
        let tempReservation = TempAudioChunkReservation(
            key: key,
            audioFileURL: reservation.fileURL,
            metadataFileURL: reservation.fileURL
        )
        _ = try await store.markWritten(
            tempReservation,
            timingMetadata: timingMetadata.map {
                TempAudioChunkTimingMetadata(
                    startTimeOffset: $0.startTimeOffset,
                    duration: $0.duration,
                    chunkDuration: $0.chunkDuration,
                    overlapDuration: $0.overlapDuration,
                    strideDuration: $0.strideDuration
                )
            }
        )
    }
}

private final class SessionAudioChunkSink: MicrophoneCaptureBufferWriting, SystemAudioSampleBufferWriter, SystemAudioPCMBufferWriter, @unchecked Sendable {
    private let sessionID: UUID
    private let chunkWriter: any CapturedAudioChunkWriter
    private let progressHandler: BarnOwlAudioCaptureFactory.AudioCaptureProgressHandler?
    private let realtimePCMHandler: BarnOwlAudioCaptureFactory.AudioRealtimePCMHandler?
    private let ingestionSequenceNumbers = LockedAudioCaptureSequenceNumbers()
    private let ingestionTaskCounter = AudioCaptureIngestionTaskCounter()
    private let ingestionQueue: OrderedAudioBufferIngestionQueue

    init(
        sessionID: UUID,
        chunkWriter: any CapturedAudioChunkWriter,
        progressHandler: BarnOwlAudioCaptureFactory.AudioCaptureProgressHandler?,
        realtimePCMHandler: BarnOwlAudioCaptureFactory.AudioRealtimePCMHandler?
    ) {
        self.sessionID = sessionID
        self.chunkWriter = chunkWriter
        self.progressHandler = progressHandler
        self.realtimePCMHandler = realtimePCMHandler
        ingestionQueue = OrderedAudioBufferIngestionQueue(
            sessionID: sessionID,
            chunkWriter: chunkWriter,
            progressHandler: progressHandler,
            realtimePCMHandler: realtimePCMHandler
        )
    }

    func writeMicrophoneBuffer(_ buffer: AVAudioPCMBuffer, at time: AVAudioTime) throws {
        let copiedBuffer = try Self.copyPCMBuffer(buffer)
        enqueue(
            copiedBuffer,
            trackKind: .microphone,
            captureStartTime: Self.captureStartTime(for: copiedBuffer, audioTime: time)
        )
    }

    func writeSystemAudioSampleBuffer(_ sampleBuffer: CMSampleBuffer) throws {
        guard let buffer = try Self.makePCMBuffer(from: sampleBuffer) else {
            return
        }

        enqueue(
            buffer,
            trackKind: .systemAudio,
            captureStartTime: Self.captureStartTime(for: buffer, sampleBuffer: sampleBuffer)
        )
    }

    func writeSystemAudioBuffer(_ buffer: AVAudioPCMBuffer) throws {
        let copiedBuffer = try Self.copyPCMBuffer(buffer)
        enqueue(
            copiedBuffer,
            trackKind: .systemAudio,
            captureStartTime: Self.fallbackCaptureStartTime(for: copiedBuffer)
        )
    }

    private func enqueue(
        _ buffer: AVAudioPCMBuffer,
        trackKind: AudioTrackKind,
        captureStartTime: TimeInterval
    ) {
        let orderedBuffer = OrderedAudioCaptureBuffer(
            sequenceNumber: ingestionSequenceNumbers.nextSequenceNumber(for: trackKind),
            trackKind: trackKind,
            buffer: SendablePCMBuffer(buffer),
            captureStartTime: captureStartTime
        )

        ingestionTaskCounter.increment()
        Task.detached(priority: .utility) { [ingestionQueue, ingestionTaskCounter] in
            defer { ingestionTaskCounter.decrement() }
            await ingestionQueue.append(orderedBuffer)
        }
    }

    func flush() async {
        await ingestionTaskCounter.waitUntilZero()
        await ingestionQueue.flush()
    }

    private static func fallbackCaptureStartTime(for buffer: AVAudioPCMBuffer) -> TimeInterval {
        ProcessInfo.processInfo.systemUptime - duration(of: buffer)
    }

    private static func captureStartTime(
        for buffer: AVAudioPCMBuffer,
        audioTime: AVAudioTime
    ) -> TimeInterval {
        guard audioTime.isHostTimeValid else {
            return fallbackCaptureStartTime(for: buffer)
        }
        return AVAudioTime.seconds(forHostTime: audioTime.hostTime)
    }

    private static func captureStartTime(
        for buffer: AVAudioPCMBuffer,
        sampleBuffer: CMSampleBuffer
    ) -> TimeInterval {
        let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let seconds = CMTimeGetSeconds(presentationTime)
        let uptime = ProcessInfo.processInfo.systemUptime
        if seconds.isFinite,
           seconds > 0,
           abs(seconds - uptime) < 86_400 {
            return seconds
        }
        return fallbackCaptureStartTime(for: buffer)
    }

    private static func duration(of buffer: AVAudioPCMBuffer) -> TimeInterval {
        guard buffer.format.sampleRate > 0 else { return 0 }
        return TimeInterval(buffer.frameLength) / buffer.format.sampleRate
    }

    private static func copyPCMBuffer(_ buffer: AVAudioPCMBuffer) throws -> AVAudioPCMBuffer {
        guard let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) else {
            throw AudioCaptureError.sourceUnavailable
        }

        copy.frameLength = buffer.frameLength
        let status = AudioBufferListCopyData.copy(
            destination: copy.mutableAudioBufferList,
            source: buffer.audioBufferList,
            frameCount: buffer.frameLength
        )
        guard status else {
            throw AudioCaptureError.sourceUnavailable
        }

        return copy
    }

    private static func makePCMBuffer(from sampleBuffer: CMSampleBuffer) throws -> AVAudioPCMBuffer? {
        guard sampleBuffer.isValid,
              CMSampleBufferDataIsReady(sampleBuffer),
              let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let streamDescription = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription)
        else {
            return nil
        }

        let sampleCount = CMSampleBufferGetNumSamples(sampleBuffer)
        guard sampleCount > 0 else {
            return nil
        }

        var audioStreamDescription = streamDescription.pointee
        guard let format = AVAudioFormat(streamDescription: &audioStreamDescription),
              let buffer = AVAudioPCMBuffer(
                  pcmFormat: format,
                  frameCapacity: AVAudioFrameCount(sampleCount)
              )
        else {
            throw AudioCaptureError.sourceUnavailable
        }

        buffer.frameLength = AVAudioFrameCount(sampleCount)
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer,
            at: 0,
            frameCount: Int32(sampleCount),
            into: buffer.mutableAudioBufferList
        )
        guard status == noErr else {
            throw AudioCaptureError.sourceUnavailable
        }

        return buffer
    }
}

private struct OrderedAudioCaptureBuffer: Sendable {
    var sequenceNumber: Int64
    var trackKind: AudioTrackKind
    var buffer: SendablePCMBuffer
    var captureStartTime: TimeInterval
}

private final class LockedAudioCaptureSequenceNumbers: @unchecked Sendable {
    private let lock = NSLock()
    private var nextByTrack: [AudioTrackKind: Int64] = [:]

    func nextSequenceNumber(for trackKind: AudioTrackKind) -> Int64 {
        lock.lock()
        defer { lock.unlock() }

        let sequenceNumber = nextByTrack[trackKind, default: 0]
        nextByTrack[trackKind] = sequenceNumber + 1
        return sequenceNumber
    }
}

private final class AudioCaptureIngestionTaskCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }

    func decrement() {
        let continuations: [CheckedContinuation<Void, Never>]
        lock.lock()
        count -= 1
        if count == 0 {
            continuations = waiters
            waiters = []
        } else {
            continuations = []
        }
        lock.unlock()

        for continuation in continuations {
            continuation.resume()
        }
    }

    func waitUntilZero() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if count == 0 {
                lock.unlock()
                continuation.resume()
            } else {
                waiters.append(continuation)
                lock.unlock()
            }
        }
    }
}

private actor OrderedAudioBufferIngestionQueue {
    private let sessionID: UUID
    private let chunkWriter: any CapturedAudioChunkWriter
    private let progressHandler: BarnOwlAudioCaptureFactory.AudioCaptureProgressHandler?
    private let realtimePCMHandler: BarnOwlAudioCaptureFactory.AudioRealtimePCMHandler?
    private let writeQueue = BufferedAudioChunkWriteQueue(configuration: .barnOwlFinalTranscription)
    private let realtimeQueue = RealtimePCMForwardingQueue()
    private var pendingByTrack: [AudioTrackKind: [Int64: OrderedAudioCaptureBuffer]] = [:]
    private var nextSequenceByTrack: [AudioTrackKind: Int64] = [:]
    private var drainingTracks: Set<AudioTrackKind> = []
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []
    private var timelineAnchorTime: TimeInterval?

    init(
        sessionID: UUID,
        chunkWriter: any CapturedAudioChunkWriter,
        progressHandler: BarnOwlAudioCaptureFactory.AudioCaptureProgressHandler?,
        realtimePCMHandler: BarnOwlAudioCaptureFactory.AudioRealtimePCMHandler?
    ) {
        self.sessionID = sessionID
        self.chunkWriter = chunkWriter
        self.progressHandler = progressHandler
        self.realtimePCMHandler = realtimePCMHandler
    }

    func append(_ orderedBuffer: OrderedAudioCaptureBuffer) {
        var pending = pendingByTrack[orderedBuffer.trackKind, default: [:]]
        pending[orderedBuffer.sequenceNumber] = orderedBuffer
        pendingByTrack[orderedBuffer.trackKind] = pending
        startDrainIfNeeded(for: orderedBuffer.trackKind)
    }

    func flush() async {
        await waitUntilIdle()
        await realtimeQueue.flush(handler: realtimePCMHandler)
        await writeQueue.flushAll(
            sessionID: sessionID,
            chunkWriter: chunkWriter,
            progressHandler: progressHandler
        )
    }

    private func startDrainIfNeeded(for trackKind: AudioTrackKind) {
        guard !drainingTracks.contains(trackKind) else {
            return
        }

        drainingTracks.insert(trackKind)
        Task { await drain(trackKind: trackKind) }
    }

    private func drain(trackKind: AudioTrackKind) async {
        while let orderedBuffer = nextPendingBuffer(for: trackKind) {
            let sourceStartOffset = timelineOffset(for: orderedBuffer.captureStartTime)
            await realtimeQueue.forward(
                orderedBuffer.buffer,
                trackKind: trackKind,
                timelineStartOffset: sourceStartOffset,
                handler: realtimePCMHandler
            )
            await writeQueue.append(
                orderedBuffer.buffer,
                sourceStartOffset: sourceStartOffset,
                sessionID: sessionID,
                trackKind: trackKind,
                chunkWriter: chunkWriter,
                progressHandler: progressHandler
            )
        }

        drainingTracks.remove(trackKind)
        notifyIdleWaitersIfNeeded()
    }

    private func timelineOffset(for captureStartTime: TimeInterval) -> TimeInterval {
        if timelineAnchorTime == nil {
            timelineAnchorTime = captureStartTime
        }
        let anchorTime = timelineAnchorTime ?? captureStartTime
        return max(0, captureStartTime - anchorTime)
    }

    private func nextPendingBuffer(for trackKind: AudioTrackKind) -> OrderedAudioCaptureBuffer? {
        let nextSequenceNumber = nextSequenceByTrack[trackKind, default: 0]
        guard var pending = pendingByTrack[trackKind],
              let buffer = pending.removeValue(forKey: nextSequenceNumber)
        else {
            return nil
        }

        pendingByTrack[trackKind] = pending.isEmpty ? nil : pending
        nextSequenceByTrack[trackKind] = nextSequenceNumber + 1
        return buffer
    }

    private func waitUntilIdle() async {
        if isIdle {
            return
        }

        await withCheckedContinuation { continuation in
            idleWaiters.append(continuation)
        }
    }

    private var isIdle: Bool {
        drainingTracks.isEmpty && pendingByTrack.values.allSatisfy(\.isEmpty)
    }

    private func notifyIdleWaitersIfNeeded() {
        guard isIdle else {
            return
        }

        let waiters = idleWaiters
        idleWaiters = []
        for waiter in waiters {
            waiter.resume()
        }
    }
}

private actor RealtimePCMForwardingQueue {
    private static let outputSampleRate = 24_000
    private let converter = PCM16RealtimeConverter(sampleRate: outputSampleRate)
    private var mixer = RealtimeAudioMixer(configuration: .barnOwlRealtimeTranscription)

    func forward(
        _ buffer: SendablePCMBuffer,
        trackKind: AudioTrackKind,
        timelineStartOffset: TimeInterval,
        handler: BarnOwlAudioCaptureFactory.AudioRealtimePCMHandler?
    ) async {
        guard let handler,
              let chunk = try? converter.convert(buffer.value, trackKind: trackKind),
              chunk.pcm16Data.isEmpty == false
        else {
            return
        }

        let timelineStartFrame = max(
            0,
            Int64((timelineStartOffset * TimeInterval(Self.outputSampleRate)).rounded())
        )
        let mixedChunks = mixer.append(RealtimeAudioMixerInputChunk(
            trackKind: trackKind,
            pcm16Data: chunk.pcm16Data,
            sampleRate: chunk.sampleRate,
            timelineStartFrame: timelineStartFrame
        ))
        for mixedChunk in mixedChunks {
            handler(AudioRealtimePCMChunk(
                trackKind: .mixed,
                pcm16Data: mixedChunk.pcm16Data,
                sampleRate: mixedChunk.sampleRate,
                duration: mixedChunk.duration
            ))
        }
    }

    func flush(handler: BarnOwlAudioCaptureFactory.AudioRealtimePCMHandler?) async {
        guard let handler else { return }
        for mixedChunk in mixer.flush() where mixedChunk.pcm16Data.isEmpty == false {
            handler(AudioRealtimePCMChunk(
                trackKind: .mixed,
                pcm16Data: mixedChunk.pcm16Data,
                sampleRate: mixedChunk.sampleRate,
                duration: mixedChunk.duration
            ))
        }
    }
}

private final class PCM16RealtimeConverter: @unchecked Sendable {
    private let sampleRate: Double

    init(sampleRate: Int) {
        self.sampleRate = Double(sampleRate)
    }

    func convert(_ buffer: AVAudioPCMBuffer, trackKind: AudioTrackKind) throws -> AudioRealtimePCMChunk? {
        guard buffer.frameLength > 0,
              let outputFormat = AVAudioFormat(
                  commonFormat: .pcmFormatInt16,
                  sampleRate: sampleRate,
                  channels: 1,
                  interleaved: true
              ),
              let converter = AVAudioConverter(from: buffer.format, to: outputFormat)
        else {
            return nil
        }

        let outputCapacity = AVAudioFrameCount(
            max(1, ceil((Double(buffer.frameLength) / buffer.format.sampleRate) * sampleRate) + 512)
        )
        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: outputFormat,
            frameCapacity: outputCapacity
        ) else {
            return nil
        }

        let inputState = AudioConverterInputState()
        var conversionError: NSError?
        converter.convert(to: outputBuffer, error: &conversionError) { _, status in
            if inputState.didProvideInput {
                status.pointee = .noDataNow
                return nil
            }

            inputState.didProvideInput = true
            status.pointee = .haveData
            return buffer
        }

        if let conversionError {
            throw conversionError
        }

        guard let channelData = outputBuffer.int16ChannelData else {
            return nil
        }

        let byteCount = Int(outputBuffer.frameLength) * MemoryLayout<Int16>.size
        guard byteCount > 0 else {
            return nil
        }

        let data = Data(bytes: channelData[0], count: byteCount)
        return AudioRealtimePCMChunk(
            trackKind: trackKind,
            pcm16Data: data,
            sampleRate: Int(sampleRate),
            duration: Double(outputBuffer.frameLength) / sampleRate
        )
    }
}

private final class AudioConverterInputState: @unchecked Sendable {
    var didProvideInput = false
}

private actor BufferedAudioChunkWriteQueue {
    private let configuration: FinalAudioChunkingConfiguration
    private var pendingByTrack: [AudioTrackKind: PendingAudioChunk] = [:]

    init(configuration: FinalAudioChunkingConfiguration) {
        self.configuration = configuration
    }

    func append(
        _ buffer: SendablePCMBuffer,
        sourceStartOffset: TimeInterval,
        sessionID: UUID,
        trackKind: AudioTrackKind,
        chunkWriter: any CapturedAudioChunkWriter,
        progressHandler: BarnOwlAudioCaptureFactory.AudioCaptureProgressHandler?
    ) async {
        let signature = AudioFormatSignature(format: buffer.value.format)
        if let pending = pendingByTrack[trackKind],
           pending.signature != signature {
            await flush(
                trackKind: trackKind,
                sessionID: sessionID,
                chunkWriter: chunkWriter,
                progressHandler: progressHandler
            )
        }

        var pending = pendingByTrack[trackKind] ?? PendingAudioChunk(
            signature: signature,
            nextChunkStartOffset: sourceStartOffset
        )
        pending.append(buffer)
        pendingByTrack[trackKind] = pending

        await flushCompleteChunks(
            trackKind: trackKind,
            sessionID: sessionID,
            chunkWriter: chunkWriter,
            progressHandler: progressHandler
        )
    }

    private func flushCompleteChunks(
        trackKind: AudioTrackKind,
        sessionID: UUID,
        chunkWriter: any CapturedAudioChunkWriter,
        progressHandler: BarnOwlAudioCaptureFactory.AudioCaptureProgressHandler?
    ) async {
        while let pending = pendingByTrack[trackKind],
              pending.duration >= configuration.chunkDuration {
            await flushCompleteChunk(
                trackKind: trackKind,
                sessionID: sessionID,
                chunkWriter: chunkWriter,
                progressHandler: progressHandler
            )
        }
    }

    func flushAll(
        sessionID: UUID,
        chunkWriter: any CapturedAudioChunkWriter,
        progressHandler: BarnOwlAudioCaptureFactory.AudioCaptureProgressHandler?
    ) async {
        for trackKind in Array(pendingByTrack.keys) {
            await flush(
                trackKind: trackKind,
                sessionID: sessionID,
                chunkWriter: chunkWriter,
                progressHandler: progressHandler
            )
        }
    }

    private func flush(
        trackKind: AudioTrackKind,
        sessionID: UUID,
        chunkWriter: any CapturedAudioChunkWriter,
        progressHandler: BarnOwlAudioCaptureFactory.AudioCaptureProgressHandler?
    ) async {
        guard let pending = pendingByTrack[trackKind],
              pending.buffers.isEmpty == false
        else {
            return
        }
        if pending.hasOnlyCarriedOverlap(overlapDuration: configuration.overlapDuration) {
            pendingByTrack.removeValue(forKey: trackKind)
            return
        }

        pendingByTrack.removeValue(forKey: trackKind)

        do {
            let chunk = try await chunkWriter.writeChunk(
                pending.buffers.map(\.value),
                sessionID: sessionID,
                trackKind: trackKind,
                timingMetadata: CapturedAudioChunkTimingMetadata(
                    startTimeOffset: pending.nextChunkStartOffset,
                    duration: pending.duration,
                    chunkDuration: configuration.chunkDuration,
                    overlapDuration: configuration.overlapDuration,
                    strideDuration: configuration.strideDuration
                )
            )
            let byteCount = try? chunk.fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize
            await progressHandler?(AudioCaptureProgress(
                trackKind: trackKind,
                sequenceNumber: chunk.sequenceNumber,
                fileURL: chunk.fileURL,
                startTimeOffset: pending.nextChunkStartOffset,
                duration: pending.duration,
                chunkDuration: configuration.chunkDuration,
                overlapDuration: configuration.overlapDuration,
                strideDuration: configuration.strideDuration,
                byteCount: byteCount,
                errorMessage: nil
            ))
        } catch {
            await progressHandler?(AudioCaptureProgress(
                trackKind: trackKind,
                sequenceNumber: nil,
                fileURL: nil,
                startTimeOffset: pending.nextChunkStartOffset,
                duration: pending.duration,
                chunkDuration: configuration.chunkDuration,
                overlapDuration: configuration.overlapDuration,
                strideDuration: configuration.strideDuration,
                byteCount: nil,
                errorMessage: String(describing: error)
            ))
        }
    }

    private func flushCompleteChunk(
        trackKind: AudioTrackKind,
        sessionID: UUID,
        chunkWriter: any CapturedAudioChunkWriter,
        progressHandler: BarnOwlAudioCaptureFactory.AudioCaptureProgressHandler?
    ) async {
        guard var pending = pendingByTrack[trackKind],
              pending.buffers.isEmpty == false
        else {
            return
        }

        do {
            let chunkBuffers = try pending.prefixBuffers(duration: configuration.chunkDuration)
            let chunk = try await chunkWriter.writeChunk(
                chunkBuffers.map(\.value),
                sessionID: sessionID,
                trackKind: trackKind,
                timingMetadata: CapturedAudioChunkTimingMetadata(
                    startTimeOffset: pending.nextChunkStartOffset,
                    duration: configuration.chunkDuration,
                    chunkDuration: configuration.chunkDuration,
                    overlapDuration: configuration.overlapDuration,
                    strideDuration: configuration.strideDuration
                )
            )
            let byteCount = try? chunk.fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize
            await progressHandler?(AudioCaptureProgress(
                trackKind: trackKind,
                sequenceNumber: chunk.sequenceNumber,
                fileURL: chunk.fileURL,
                startTimeOffset: pending.nextChunkStartOffset,
                duration: configuration.chunkDuration,
                chunkDuration: configuration.chunkDuration,
                overlapDuration: configuration.overlapDuration,
                strideDuration: configuration.strideDuration,
                byteCount: byteCount,
                errorMessage: nil
            ))

            try pending.dropPrefix(duration: configuration.strideDuration)
            pending.nextChunkStartOffset += configuration.strideDuration
            pendingByTrack[trackKind] = pending
        } catch {
            pendingByTrack[trackKind] = pending
            await progressHandler?(AudioCaptureProgress(
                trackKind: trackKind,
                sequenceNumber: nil,
                fileURL: nil,
                startTimeOffset: pending.nextChunkStartOffset,
                duration: min(pending.duration, configuration.chunkDuration),
                chunkDuration: configuration.chunkDuration,
                overlapDuration: configuration.overlapDuration,
                strideDuration: configuration.strideDuration,
                byteCount: nil,
                errorMessage: String(describing: error)
            ))
            pendingByTrack.removeValue(forKey: trackKind)
        }
    }
}

private struct PendingAudioChunk {
    var signature: AudioFormatSignature
    var buffers: [SendablePCMBuffer] = []
    var frameCount: AVAudioFrameCount = 0
    var nextChunkStartOffset: TimeInterval = 0

    var duration: TimeInterval {
        guard signature.sampleRate > 0 else { return 0 }
        return TimeInterval(frameCount) / signature.sampleRate
    }

    mutating func append(_ buffer: SendablePCMBuffer) {
        buffers.append(buffer)
        frameCount += buffer.value.frameLength
    }

    func hasOnlyCarriedOverlap(overlapDuration: TimeInterval) -> Bool {
        nextChunkStartOffset > 0 && duration <= overlapDuration + 0.01
    }

    func prefixBuffers(duration: TimeInterval) throws -> [SendablePCMBuffer] {
        var framesRemaining = AVAudioFrameCount((duration * signature.sampleRate).rounded())
        var output: [SendablePCMBuffer] = []
        output.reserveCapacity(buffers.count)

        for buffer in buffers where framesRemaining > 0 {
            let framesToCopy = min(buffer.value.frameLength, framesRemaining)
            output.append(SendablePCMBuffer(try Self.slice(buffer.value, startFrame: 0, frameCount: framesToCopy)))
            framesRemaining -= framesToCopy
        }

        return output
    }

    mutating func dropPrefix(duration: TimeInterval) throws {
        var framesToDrop = AVAudioFrameCount((duration * signature.sampleRate).rounded())
        while framesToDrop > 0, !buffers.isEmpty {
            let first = buffers.removeFirst()
            if first.value.frameLength <= framesToDrop {
                framesToDrop -= first.value.frameLength
                frameCount -= first.value.frameLength
                continue
            }

            let remainingFrameCount = first.value.frameLength - framesToDrop
            let remaining = try Self.slice(
                first.value,
                startFrame: framesToDrop,
                frameCount: remainingFrameCount
            )
            buffers.insert(SendablePCMBuffer(remaining), at: 0)
            frameCount -= framesToDrop
            framesToDrop = 0
        }
    }

    private static func slice(
        _ buffer: AVAudioPCMBuffer,
        startFrame: AVAudioFrameCount,
        frameCount: AVAudioFrameCount
    ) throws -> AVAudioPCMBuffer {
        guard startFrame <= buffer.frameLength,
              frameCount <= buffer.frameLength - startFrame,
              let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: frameCount)
        else {
            throw AudioCaptureError.sourceUnavailable
        }

        copy.frameLength = frameCount
        guard frameCount > 0 else {
            return copy
        }

        let sourceBuffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: buffer.audioBufferList))
        let destinationBuffers = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        guard sourceBuffers.count == destinationBuffers.count else {
            throw AudioCaptureError.sourceUnavailable
        }

        for index in sourceBuffers.indices {
            let sourceBuffer = sourceBuffers[index]
            var destinationBuffer = destinationBuffers[index]
            guard let sourceData = sourceBuffer.mData,
                  let destinationData = destinationBuffer.mData,
                  buffer.frameLength > 0
            else {
                throw AudioCaptureError.sourceUnavailable
            }

            let bytesPerFrame = Int(sourceBuffer.mDataByteSize) / Int(buffer.frameLength)
            let byteOffset = Int(startFrame) * bytesPerFrame
            let bytesToCopy = Int(frameCount) * bytesPerFrame
            guard bytesPerFrame > 0,
                  byteOffset + bytesToCopy <= Int(sourceBuffer.mDataByteSize),
                  bytesToCopy <= Int(destinationBuffer.mDataByteSize)
            else {
                throw AudioCaptureError.sourceUnavailable
            }

            memcpy(destinationData, sourceData.advanced(by: byteOffset), bytesToCopy)
            destinationBuffer.mDataByteSize = UInt32(bytesToCopy)
            destinationBuffers[index] = destinationBuffer
        }

        return copy
    }
}

private struct AudioFormatSignature: Equatable {
    var commonFormat: AVAudioCommonFormat
    var sampleRate: Double
    var channelCount: AVAudioChannelCount
    var isInterleaved: Bool

    init(format: AVAudioFormat) {
        commonFormat = format.commonFormat
        sampleRate = format.sampleRate
        channelCount = format.channelCount
        isInterleaved = format.isInterleaved
    }
}

private struct SendablePCMBuffer: @unchecked Sendable {
    var value: AVAudioPCMBuffer

    init(_ value: AVAudioPCMBuffer) {
        self.value = value
    }
}

private enum AudioBufferListCopyData {
    static func copy(
        destination: UnsafeMutablePointer<AudioBufferList>,
        source: UnsafePointer<AudioBufferList>,
        frameCount: AVAudioFrameCount
    ) -> Bool {
        let sourceBuffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: source))
        let destinationBuffers = UnsafeMutableAudioBufferListPointer(destination)
        guard sourceBuffers.count == destinationBuffers.count else {
            return false
        }

        for index in sourceBuffers.indices {
            let sourceBuffer = sourceBuffers[index]
            var destinationBuffer = destinationBuffers[index]
            guard let sourceData = sourceBuffer.mData,
                  let destinationData = destinationBuffer.mData,
                  sourceBuffer.mDataByteSize <= destinationBuffer.mDataByteSize
            else {
                return false
            }

            memcpy(destinationData, sourceData, Int(sourceBuffer.mDataByteSize))
            destinationBuffer.mDataByteSize = sourceBuffer.mDataByteSize
            destinationBuffers[index] = destinationBuffer
        }

        _ = frameCount
        return true
    }
}

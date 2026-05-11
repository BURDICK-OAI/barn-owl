import AVFoundation
import BarnOwlAudio
import Foundation
import Testing

@Test
func audioFileChunkWriterAssignsDeterministicSequenceNumbersPerTrack() async throws {
    let rootDirectory = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: rootDirectory) }

    let sessionID = UUID(uuidString: "00000000-0000-0000-0000-000000000201")!
    let store = FakeCapturedAudioChunkStore(rootDirectory: rootDirectory)
    let writer = AudioFileChunkWriter(store: store)
    let buffer = try makePCMBuffer(frameCount: 2)

    let first = try await writer.writeChunk(buffer, sessionID: sessionID, trackKind: .microphone)
    let second = try await writer.writeChunk(buffer, sessionID: sessionID, trackKind: .microphone)
    let third = try await writer.writeChunk(buffer, sessionID: sessionID, trackKind: .microphone)

    let expectedSequenceNumbers = [0, 1, 2]
    #expect([first.sequenceNumber, second.sequenceNumber, third.sequenceNumber] == expectedSequenceNumbers)
    #expect(await store.reservedSequenceNumbers(for: .microphone) == expectedSequenceNumbers)
    #expect(await store.markedWrittenSequenceNumbers(for: .microphone) == expectedSequenceNumbers)
}

@Test
func audioFileChunkWriterKeepsTrackSequencesAndPathsSeparate() async throws {
    let rootDirectory = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: rootDirectory) }

    let sessionID = UUID(uuidString: "00000000-0000-0000-0000-000000000202")!
    let store = FakeCapturedAudioChunkStore(rootDirectory: rootDirectory)
    let writer = AudioFileChunkWriter(store: store)
    let buffer = try makePCMBuffer(frameCount: 2)

    let microphone0 = try await writer.writeChunk(buffer, sessionID: sessionID, trackKind: .microphone)
    let system0 = try await writer.writeChunk(buffer, sessionID: sessionID, trackKind: .systemAudio)
    let microphone1 = try await writer.writeChunk(buffer, sessionID: sessionID, trackKind: .microphone)

    #expect(microphone0.sequenceNumber == 0)
    #expect(system0.sequenceNumber == 0)
    #expect(microphone1.sequenceNumber == 1)
    #expect(microphone0.fileURL == rootDirectory
        .appending(path: sessionID.uuidString, directoryHint: .isDirectory)
        .appending(path: "microphone", directoryHint: .isDirectory)
        .appending(path: "000000.wav"))
    #expect(system0.fileURL == rootDirectory
        .appending(path: sessionID.uuidString, directoryHint: .isDirectory)
        .appending(path: "systemAudio", directoryHint: .isDirectory)
        .appending(path: "000000.wav"))
    #expect(microphone1.fileURL == rootDirectory
        .appending(path: sessionID.uuidString, directoryHint: .isDirectory)
        .appending(path: "microphone", directoryHint: .isDirectory)
        .appending(path: "000001.wav"))
}

@Test
func audioFileChunkWriterWritesSmallSyntheticPCMBufferAsWAV() async throws {
    let rootDirectory = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: rootDirectory) }

    let sessionID = UUID(uuidString: "00000000-0000-0000-0000-000000000203")!
    let store = FakeCapturedAudioChunkStore(rootDirectory: rootDirectory)
    let writer = AudioFileChunkWriter(store: store)
    let buffer = try makePCMBuffer(frameCount: 4)

    let chunk = try await writer.writeChunk(buffer, sessionID: sessionID, trackKind: .systemAudio)
    let writtenFile = try AVAudioFile(forReading: chunk.fileURL)

    #expect(chunk.trackKind == .systemAudio)
    #expect(chunk.sequenceNumber == 0)
    #expect(chunk.fileURL.pathExtension == "wav")
    #expect(FileManager.default.fileExists(atPath: chunk.fileURL.path(percentEncoded: false)))
    #expect(writtenFile.length == 4)
    #expect(writtenFile.processingFormat.channelCount == 1)
    let expectedSequenceNumbers = [0]
    #expect(await store.markedWrittenSequenceNumbers(for: .systemAudio) == expectedSequenceNumbers)
}

@Test
func audioFileChunkWriterNormalizesInterleavedSystemAudioAsReadableWAV() async throws {
    let rootDirectory = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: rootDirectory) }

    let sessionID = UUID(uuidString: "00000000-0000-0000-0000-000000000204")!
    let store = FakeCapturedAudioChunkStore(rootDirectory: rootDirectory)
    let writer = AudioFileChunkWriter(store: store)
    let buffer = try makeInterleavedPCMBuffer(frameCount: 8)

    let chunk = try await writer.writeChunk(buffer, sessionID: sessionID, trackKind: .systemAudio)
    let writtenFile = try AVAudioFile(forReading: chunk.fileURL)

    #expect(chunk.trackKind == .systemAudio)
    #expect(writtenFile.length == 8)
    #expect(writtenFile.processingFormat.channelCount == 2)
    #expect(writtenFile.processingFormat.isInterleaved == false)
    #expect(writtenFile.processingFormat.commonFormat == .pcmFormatFloat32)
}

private actor FakeCapturedAudioChunkStore: CapturedAudioChunkStore {
    private let rootDirectory: URL
    private var reservations: [CapturedAudioChunkReservation] = []
    private var markedWritten: [CapturedAudioChunkReservation] = []

    init(rootDirectory: URL) {
        self.rootDirectory = rootDirectory
    }

    func reserveChunk(
        sessionID: UUID,
        trackKind: AudioTrackKind,
        sequenceNumber: Int,
        fileExtension: String
    ) throws -> CapturedAudioChunkReservation {
        let fileURL = rootDirectory
            .appending(path: sessionID.uuidString, directoryHint: .isDirectory)
            .appending(path: trackKind.rawValue, directoryHint: .isDirectory)
            .appending(path: String(format: "%06d.%@", sequenceNumber, fileExtension))

        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let reservation = CapturedAudioChunkReservation(
            sessionID: sessionID,
            trackKind: trackKind,
            sequenceNumber: sequenceNumber,
            fileURL: fileURL
        )
        reservations.append(reservation)
        return reservation
    }

    func markChunkWritten(_ reservation: CapturedAudioChunkReservation) throws {
        #expect(FileManager.default.fileExists(atPath: reservation.fileURL.path(percentEncoded: false)))
        markedWritten.append(reservation)
    }

    func reservedSequenceNumbers(for trackKind: AudioTrackKind) -> [Int] {
        reservations
            .filter { $0.trackKind == trackKind }
            .map(\.sequenceNumber)
    }

    func markedWrittenSequenceNumbers(for trackKind: AudioTrackKind) -> [Int] {
        markedWritten
            .filter { $0.trackKind == trackKind }
            .map(\.sequenceNumber)
    }
}

private func makePCMBuffer(frameCount: AVAudioFrameCount) throws -> AVAudioPCMBuffer {
    let format = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 44_100,
        channels: 1,
        interleaved: false
    )!
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)!
    buffer.frameLength = frameCount

    let channelData = buffer.floatChannelData![0]
    for frame in 0..<Int(frameCount) {
        channelData[frame] = Float(frame) / Float(max(Int(frameCount), 1))
    }

    return buffer
}

private func makeInterleavedPCMBuffer(frameCount: AVAudioFrameCount) throws -> AVAudioPCMBuffer {
    let format = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 48_000,
        channels: 2,
        interleaved: true
    )!
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)!
    buffer.frameLength = frameCount

    return buffer
}

private func makeTempDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appending(path: "BarnOwlAudioTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

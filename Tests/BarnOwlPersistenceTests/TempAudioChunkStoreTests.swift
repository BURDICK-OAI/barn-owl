import BarnOwlPersistence
import Foundation
import Testing

@Test
func chunkReservationsUseDeterministicSessionScopedPaths() async throws {
    let rootDirectory = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: rootDirectory) }

    let sessionID = UUID(uuidString: "00000000-0000-0000-0000-000000000123")!
    let store = FilesystemTempAudioChunkStore(rootDirectory: rootDirectory)

    let reservation = try await store.reserveChunk(
        sessionID: sessionID,
        trackKind: "microphone",
        sequenceNumber: 7,
        fileExtension: "wav"
    )

    #expect(reservation.audioFileURL == rootDirectory
        .appending(path: "00000000-0000-0000-0000-000000000123", directoryHint: .isDirectory)
        .appending(path: "microphone", directoryHint: .isDirectory)
        .appending(path: "000007.wav"))
    #expect(reservation.metadataFileURL == rootDirectory
        .appending(path: "00000000-0000-0000-0000-000000000123", directoryHint: .isDirectory)
        .appending(path: "_metadata", directoryHint: .isDirectory)
        .appending(path: "microphone-000007.json"))
}

@Test
func tempAudioStoreRestrictsSessionAudioAndMetadataPermissions() async throws {
    let rootDirectory = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: rootDirectory) }

    let sessionID = UUID(uuidString: "00000000-0000-0000-0000-000000000129")!
    let store = FilesystemTempAudioChunkStore(rootDirectory: rootDirectory)

    let reservation = try await store.reserveChunk(
        sessionID: sessionID,
        trackKind: "microphone",
        sequenceNumber: 0,
        fileExtension: "wav"
    )
    _ = try await store.writeChunk(Data([1, 2, 3]), to: reservation)

    #expect(try posixPermissions(at: rootDirectory) == 0o700)
    #expect(try posixPermissions(at: rootDirectory.appending(path: sessionID.uuidString)) == 0o700)
    #expect(try posixPermissions(at: reservation.audioFileURL.deletingLastPathComponent()) == 0o700)
    #expect(try posixPermissions(at: reservation.metadataFileURL.deletingLastPathComponent()) == 0o700)
    #expect(try posixPermissions(at: reservation.audioFileURL) == 0o600)
    #expect(try posixPermissions(at: reservation.metadataFileURL) == 0o600)
}

@Test
func finalizingChunkDeletesTempAudioAndClearsStoredAudioPath() async throws {
    let rootDirectory = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: rootDirectory) }

    let sessionID = UUID(uuidString: "00000000-0000-0000-0000-000000000124")!
    let store = FilesystemTempAudioChunkStore(rootDirectory: rootDirectory)
    let reservation = try await store.reserveChunk(
        sessionID: sessionID,
        trackKind: "systemAudio",
        sequenceNumber: 1,
        fileExtension: "wav"
    )

    let written = try await store.writeChunk(Data([1, 2, 3, 4]), to: reservation)
    _ = try await store.markUploaded(reservation.key)
    _ = try await store.markTranscribed(reservation.key)
    let finalized = try await store.finalizeChunk(reservation.key)

    #expect(written.byteCount == 4)
    #expect(finalized.state == .finalized)
    #expect(finalized.temporaryAudioPath == nil)
    #expect(finalized.deletedAudioAt != nil)
    #expect(FileManager.default.fileExists(atPath: reservation.audioFileURL.path(percentEncoded: false)) == false)
    #expect(try await store.audioFileURL(for: reservation.key) == nil)
}

@Test
func finalizingChunkIsIdempotentAfterAudioCleanup() async throws {
    let rootDirectory = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: rootDirectory) }

    let sessionID = UUID(uuidString: "00000000-0000-0000-0000-000000000125")!
    let fixedDate = Date(timeIntervalSince1970: 100)
    let store = FilesystemTempAudioChunkStore(rootDirectory: rootDirectory, now: { fixedDate })
    let reservation = try await store.reserveChunk(
        sessionID: sessionID,
        trackKind: "mixed",
        sequenceNumber: 2,
        fileExtension: "wav"
    )

    _ = try await store.writeChunk(Data([9, 8, 7]), to: reservation)
    let firstFinalize = try await store.finalizeChunk(reservation.key)
    let secondFinalize = try await store.finalizeChunk(reservation.key)

    #expect(firstFinalize == secondFinalize)
    #expect(FileManager.default.fileExists(atPath: reservation.audioFileURL.path(percentEncoded: false)) == false)
}

@Test
func markWrittenPersistsExplicitChunkTimingMetadata() async throws {
    let rootDirectory = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: rootDirectory) }

    let sessionID = UUID(uuidString: "00000000-0000-0000-0000-000000000127")!
    let store = FilesystemTempAudioChunkStore(rootDirectory: rootDirectory)
    let reservation = try await store.reserveChunk(
        sessionID: sessionID,
        trackKind: "microphone",
        sequenceNumber: 2,
        fileExtension: "wav"
    )

    try Data([1, 2, 3]).write(to: reservation.audioFileURL)
    let metadata = try await store.markWritten(
        reservation,
        timingMetadata: TempAudioChunkTimingMetadata(
            startTimeOffset: 110,
            duration: 60,
            chunkDuration: 60,
            overlapDuration: 5,
            strideDuration: 55
        )
    )

    #expect(metadata.startTimeOffset == 110)
    #expect(metadata.duration == 60)
    #expect(metadata.chunkDuration == 60)
    #expect(metadata.overlapDuration == 5)
    #expect(metadata.strideDuration == 55)
}

@Test
func finalizedMetadataDoesNotRetainRawAudioLocation() async throws {
    let rootDirectory = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: rootDirectory) }

    let sessionID = UUID(uuidString: "00000000-0000-0000-0000-000000000126")!
    let store = FilesystemTempAudioChunkStore(rootDirectory: rootDirectory)
    let reservation = try await store.reserveChunk(
        sessionID: sessionID,
        trackKind: "microphone",
        sequenceNumber: 3,
        fileExtension: "wav"
    )

    _ = try await store.writeChunk(Data([1]), to: reservation)
    let finalized = try await store.finalizeChunk(reservation.key)
    let metadataData = try Data(contentsOf: reservation.metadataFileURL)
    let metadataJSON = String(decoding: metadataData, as: UTF8.self)

    #expect(finalized.temporaryAudioPath == nil)
    #expect(metadataJSON.contains(reservation.audioFileURL.path(percentEncoded: false)) == false)
    #expect(metadataJSON.contains("temporaryAudioPath") == false)
}

@Test
func finalizingSessionFinalizesAllChunkMetadataAndRemovesRawAudio() async throws {
    let rootDirectory = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: rootDirectory) }

    let sessionID = UUID(uuidString: "00000000-0000-0000-0000-000000000128")!
    let store = FilesystemTempAudioChunkStore(rootDirectory: rootDirectory)
    let microphone = try await store.reserveChunk(
        sessionID: sessionID,
        trackKind: "microphone",
        sequenceNumber: 0,
        fileExtension: "wav"
    )
    let systemAudio = try await store.reserveChunk(
        sessionID: sessionID,
        trackKind: "systemAudio",
        sequenceNumber: 0,
        fileExtension: "wav"
    )

    _ = try await store.writeChunk(Data([1, 2, 3]), to: microphone)
    _ = try await store.writeChunk(Data([4, 5, 6]), to: systemAudio)

    let report = try await store.finalizeSessionChunks(for: sessionID)
    let finalizedMicrophone = try #require(await store.metadata(for: microphone.key))
    let finalizedSystemAudio = try #require(await store.metadata(for: systemAudio.key))

    #expect(report.finalizedChunkCount == 2)
    #expect(finalizedMicrophone.state == .finalized)
    #expect(finalizedMicrophone.temporaryAudioPath == nil)
    #expect(finalizedMicrophone.deletedAudioAt != nil)
    #expect(finalizedSystemAudio.state == .finalized)
    #expect(finalizedSystemAudio.temporaryAudioPath == nil)
    #expect(finalizedSystemAudio.deletedAudioAt != nil)
    #expect(FileManager.default.fileExists(atPath: microphone.audioFileURL.path(percentEncoded: false)) == false)
    #expect(FileManager.default.fileExists(atPath: systemAudio.audioFileURL.path(percentEncoded: false)) == false)
    #expect(FileManager.default.fileExists(atPath: microphone.metadataFileURL.path(percentEncoded: false)))
    #expect(FileManager.default.fileExists(atPath: systemAudio.metadataFileURL.path(percentEncoded: false)))
}

private func makeTempDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appending(path: "BarnOwlPersistenceTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

private func posixPermissions(at url: URL) throws -> Int {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false))
    if let permissions = attributes[.posixPermissions] as? NSNumber {
        return permissions.intValue & 0o777
    }
    return (attributes[.posixPermissions] as? Int ?? 0) & 0o777
}

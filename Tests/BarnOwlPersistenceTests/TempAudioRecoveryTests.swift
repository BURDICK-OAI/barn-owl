import BarnOwlPersistence
import Foundation
import Testing

@Test
func recoveryScanFindsIncompleteChunks() async throws {
    let rootDirectory = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: rootDirectory) }

    let sessionID = UUID(uuidString: "00000000-0000-0000-0000-000000000201")!
    let store = FilesystemTempAudioChunkStore(rootDirectory: rootDirectory)
    let incomplete = try await store.reserveChunk(
        sessionID: sessionID,
        trackKind: "microphone",
        sequenceNumber: 1,
        fileExtension: "wav"
    )
    _ = try await store.writeChunk(Data([1, 2, 3]), to: incomplete)

    let finalized = try await store.reserveChunk(
        sessionID: sessionID,
        trackKind: "systemAudio",
        sequenceNumber: 2,
        fileExtension: "wav"
    )
    _ = try await store.writeChunk(Data([4, 5, 6]), to: finalized)
    _ = try await store.finalizeChunk(finalized.key)

    let recovery = FilesystemTempAudioRecovery(rootDirectory: rootDirectory)
    let report = try await recovery.scanIncompleteChunks()

    #expect(report.discoveredChunkCount == 2)
    #expect(report.finalizedChunkCount == 1)
    #expect(report.incompleteChunks == [
        TempAudioRecoveryChunk(
            key: incomplete.key,
            state: .written,
            byteCount: 3,
            hasTemporaryAudioReference: true,
            rawAudioExists: true
        )
    ])
}

@Test
func recoveryCleanupDeletesRawAudioAndPreservesMetadata() async throws {
    let rootDirectory = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: rootDirectory) }

    let sessionID = UUID(uuidString: "00000000-0000-0000-0000-000000000202")!
    let store = FilesystemTempAudioChunkStore(rootDirectory: rootDirectory)
    let reservation = try await store.reserveChunk(
        sessionID: sessionID,
        trackKind: "microphone",
        sequenceNumber: 1,
        fileExtension: "wav"
    )
    _ = try await store.writeChunk(Data([7, 8, 9]), to: reservation)

    let recovery = FilesystemTempAudioRecovery(rootDirectory: rootDirectory)
    let report = try await recovery.cleanupIncompleteChunks()
    let metadata = try #require(await store.metadata(for: reservation.key))

    #expect(report.scannedChunkCount == 1)
    #expect(report.finalizedChunkCount == 1)
    #expect(report.cleanedChunks == [
        TempAudioRecoveryCleanupChunk(
            key: reservation.key,
            previousState: .written,
            finalState: .finalized,
            rawAudioDeleted: true
        )
    ])
    #expect(FileManager.default.fileExists(atPath: reservation.audioFileURL.path(percentEncoded: false)) == false)
    #expect(FileManager.default.fileExists(atPath: reservation.metadataFileURL.path(percentEncoded: false)) == true)
    #expect(metadata.state == .finalized)
    #expect(metadata.temporaryAudioPath == nil)
    #expect(metadata.deletedAudioAt != nil)
    #expect(String(describing: report).contains(reservation.audioFileURL.path(percentEncoded: false)) == false)
}

@Test
func recoveryCleanupIsIdempotent() async throws {
    let rootDirectory = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: rootDirectory) }

    let sessionID = UUID(uuidString: "00000000-0000-0000-0000-000000000203")!
    let store = FilesystemTempAudioChunkStore(rootDirectory: rootDirectory)
    let reservation = try await store.reserveChunk(
        sessionID: sessionID,
        trackKind: "mixed",
        sequenceNumber: 1,
        fileExtension: "wav"
    )
    _ = try await store.writeChunk(Data([1]), to: reservation)

    let recovery = FilesystemTempAudioRecovery(
        rootDirectory: rootDirectory,
        now: { Date(timeIntervalSince1970: 200) }
    )
    let firstReport = try await recovery.cleanupIncompleteChunks()
    let firstMetadata = try #require(await store.metadata(for: reservation.key))
    let secondReport = try await recovery.cleanupIncompleteChunks()
    let secondMetadata = try #require(await store.metadata(for: reservation.key))

    #expect(firstReport.cleanedChunks.count == 1)
    #expect(secondReport.cleanedChunks.isEmpty)
    #expect(firstMetadata == secondMetadata)
    #expect(FileManager.default.fileExists(atPath: reservation.audioFileURL.path(percentEncoded: false)) == false)
}

@Test
func recoveryCleanupLeavesFinalizedChunksUnchanged() async throws {
    let rootDirectory = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: rootDirectory) }

    let sessionID = UUID(uuidString: "00000000-0000-0000-0000-000000000204")!
    let finalizedAt = Date(timeIntervalSince1970: 100)
    let cleanupDate = Date(timeIntervalSince1970: 300)
    let store = FilesystemTempAudioChunkStore(rootDirectory: rootDirectory, now: { finalizedAt })
    let reservation = try await store.reserveChunk(
        sessionID: sessionID,
        trackKind: "systemAudio",
        sequenceNumber: 1,
        fileExtension: "wav"
    )
    _ = try await store.writeChunk(Data([2]), to: reservation)
    let finalizedBeforeCleanup = try await store.finalizeChunk(reservation.key)

    let recovery = FilesystemTempAudioRecovery(rootDirectory: rootDirectory, now: { cleanupDate })
    let report = try await recovery.cleanupIncompleteChunks()
    let finalizedAfterCleanup = try #require(await store.metadata(for: reservation.key))

    #expect(report.scannedChunkCount == 1)
    #expect(report.finalizedChunkCount == 1)
    #expect(report.cleanedChunks.isEmpty)
    #expect(finalizedAfterCleanup == finalizedBeforeCleanup)
    #expect(finalizedAfterCleanup.finalizedAt == finalizedAt)
    #expect(finalizedAfterCleanup.deletedAudioAt == finalizedAt)
}

private func makeTempDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appending(path: "BarnOwlPersistenceTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

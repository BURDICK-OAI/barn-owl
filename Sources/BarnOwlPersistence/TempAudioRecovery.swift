import Foundation

public struct TempAudioRecoveryChunk: Equatable, Sendable {
    public var key: TempAudioChunkKey
    public var state: TempAudioChunkLifecycleState
    public var byteCount: Int?
    public var hasTemporaryAudioReference: Bool
    public var rawAudioExists: Bool

    public init(
        key: TempAudioChunkKey,
        state: TempAudioChunkLifecycleState,
        byteCount: Int?,
        hasTemporaryAudioReference: Bool,
        rawAudioExists: Bool
    ) {
        self.key = key
        self.state = state
        self.byteCount = byteCount
        self.hasTemporaryAudioReference = hasTemporaryAudioReference
        self.rawAudioExists = rawAudioExists
    }
}

public struct TempAudioRecoveryScanReport: Equatable, Sendable {
    public var discoveredChunkCount: Int
    public var finalizedChunkCount: Int
    public var incompleteChunks: [TempAudioRecoveryChunk]

    public init(
        discoveredChunkCount: Int,
        finalizedChunkCount: Int,
        incompleteChunks: [TempAudioRecoveryChunk]
    ) {
        self.discoveredChunkCount = discoveredChunkCount
        self.finalizedChunkCount = finalizedChunkCount
        self.incompleteChunks = incompleteChunks
    }
}

public struct TempAudioRecoveryCleanupChunk: Equatable, Sendable {
    public var key: TempAudioChunkKey
    public var previousState: TempAudioChunkLifecycleState
    public var finalState: TempAudioChunkLifecycleState
    public var rawAudioDeleted: Bool

    public init(
        key: TempAudioChunkKey,
        previousState: TempAudioChunkLifecycleState,
        finalState: TempAudioChunkLifecycleState,
        rawAudioDeleted: Bool
    ) {
        self.key = key
        self.previousState = previousState
        self.finalState = finalState
        self.rawAudioDeleted = rawAudioDeleted
    }
}

public struct TempAudioRecoveryCleanupReport: Equatable, Sendable {
    public var scannedChunkCount: Int
    public var finalizedChunkCount: Int
    public var cleanedChunks: [TempAudioRecoveryCleanupChunk]

    public init(
        scannedChunkCount: Int,
        finalizedChunkCount: Int,
        cleanedChunks: [TempAudioRecoveryCleanupChunk]
    ) {
        self.scannedChunkCount = scannedChunkCount
        self.finalizedChunkCount = finalizedChunkCount
        self.cleanedChunks = cleanedChunks
    }
}

public actor FilesystemTempAudioRecovery {
    private let rootDirectory: URL
    private let now: @Sendable () -> Date
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(rootDirectory: URL, now: @escaping @Sendable () -> Date = { Date() }) {
        self.rootDirectory = rootDirectory
        self.now = now

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    public func scanIncompleteChunks() throws -> TempAudioRecoveryScanReport {
        let chunks = try discoverChunks()
        let finalizedCount = chunks.filter { $0.metadata.state == .finalized }.count
        let incompleteChunks = chunks
            .filter { $0.metadata.state != .finalized }
            .map { chunk in
                TempAudioRecoveryChunk(
                    key: chunk.metadata.key,
                    state: chunk.metadata.state,
                    byteCount: chunk.metadata.byteCount,
                    hasTemporaryAudioReference: chunk.metadata.temporaryAudioPath != nil,
                    rawAudioExists: chunk.audioURL.map(fileExists(at:)) ?? false
                )
            }

        return TempAudioRecoveryScanReport(
            discoveredChunkCount: chunks.count,
            finalizedChunkCount: finalizedCount,
            incompleteChunks: incompleteChunks
        )
    }

    @discardableResult
    public func cleanupIncompleteChunks() throws -> TempAudioRecoveryCleanupReport {
        let chunks = try discoverChunks()
        var cleanedChunks: [TempAudioRecoveryCleanupChunk] = []

        for chunk in chunks where chunk.metadata.state != .finalized {
            var metadata = chunk.metadata
            let previousState = metadata.state
            var rawAudioDeleted = false

            if let audioURL = chunk.audioURL, fileExists(at: audioURL) {
                try FileManager.default.removeItem(at: audioURL)
                rawAudioDeleted = true
            }

            let date = now()
            metadata.state = .finalized
            metadata.finalizedAt = date
            metadata.deletedAudioAt = date
            metadata.temporaryAudioPath = nil
            try writeMetadata(metadata, to: chunk.metadataURL)

            cleanedChunks.append(
                TempAudioRecoveryCleanupChunk(
                    key: metadata.key,
                    previousState: previousState,
                    finalState: metadata.state,
                    rawAudioDeleted: rawAudioDeleted
                )
            )
        }

        return TempAudioRecoveryCleanupReport(
            scannedChunkCount: chunks.count,
            finalizedChunkCount: chunks.count,
            cleanedChunks: cleanedChunks
        )
    }

    private func discoverChunks() throws -> [DiscoveredTempAudioChunk] {
        guard fileExists(at: rootDirectory) else {
            return []
        }

        let sessionDirectories = try FileManager.default.contentsOfDirectory(
            at: rootDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        .filter { url in
            guard (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
                return false
            }
            return UUID(uuidString: url.lastPathComponent) != nil
        }

        var chunks: [DiscoveredTempAudioChunk] = []
        for sessionDirectory in sessionDirectories {
            let metadataDirectory = sessionDirectory.appending(path: "_metadata", directoryHint: .isDirectory)
            guard fileExists(at: metadataDirectory) else {
                continue
            }

            let metadataFiles = try FileManager.default.contentsOfDirectory(
                at: metadataDirectory,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            )
            .filter { url in
                url.pathExtension == "json"
                    && ((try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true)
            }

            for metadataURL in metadataFiles {
                let metadata = try readMetadata(at: metadataURL)
                chunks.append(
                    DiscoveredTempAudioChunk(
                        metadata: metadata,
                        metadataURL: metadataURL,
                        audioURL: audioURL(for: metadata)
                    )
                )
            }
        }

        return chunks.sorted { lhs, rhs in
            sortKey(for: lhs.metadata.key) < sortKey(for: rhs.metadata.key)
        }
    }

    private func readMetadata(at url: URL) throws -> TempAudioChunkMetadata {
        let data = try Data(contentsOf: url)
        return try decoder.decode(TempAudioChunkMetadata.self, from: data)
    }

    private func writeMetadata(_ metadata: TempAudioChunkMetadata, to url: URL) throws {
        let data = try encoder.encode(metadata)
        try data.write(to: url, options: .atomic)
    }

    private func audioURL(for metadata: TempAudioChunkMetadata) -> URL? {
        guard let temporaryAudioPath = metadata.temporaryAudioPath,
              isSafeRelativePath(temporaryAudioPath)
        else {
            return nil
        }

        return rootDirectory.appending(path: temporaryAudioPath)
    }

    private func isSafeRelativePath(_ path: String) -> Bool {
        guard path.hasPrefix("/") == false else {
            return false
        }

        let components = path.split(separator: "/", omittingEmptySubsequences: true)
        return components.contains("..") == false
    }

    private func fileExists(at url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path(percentEncoded: false))
    }

    private func sortKey(for key: TempAudioChunkKey) -> String {
        "\(key.sessionID.uuidString)/\(key.trackKind)/\(String(format: "%06d", key.sequenceNumber))"
    }
}

private struct DiscoveredTempAudioChunk {
    var metadata: TempAudioChunkMetadata
    var metadataURL: URL
    var audioURL: URL?
}

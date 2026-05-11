import Foundation

public enum TempAudioChunkLifecycleState: String, Codable, Equatable, Sendable {
    case reserved
    case written
    case uploaded
    case transcribed
    case finalized
}

public struct TempAudioChunkKey: Codable, Equatable, Hashable, Sendable {
    public var sessionID: UUID
    public var trackKind: String
    public var sequenceNumber: Int

    public init(sessionID: UUID, trackKind: String, sequenceNumber: Int) {
        self.sessionID = sessionID
        self.trackKind = trackKind
        self.sequenceNumber = sequenceNumber
    }
}

public struct TempAudioChunkReservation: Equatable, Sendable {
    public var key: TempAudioChunkKey
    public var audioFileURL: URL
    public var metadataFileURL: URL

    public init(key: TempAudioChunkKey, audioFileURL: URL, metadataFileURL: URL) {
        self.key = key
        self.audioFileURL = audioFileURL
        self.metadataFileURL = metadataFileURL
    }
}

public struct TempAudioChunkMetadata: Codable, Equatable, Sendable {
    public var key: TempAudioChunkKey
    public var state: TempAudioChunkLifecycleState
    public var temporaryAudioPath: String?
    public var byteCount: Int?
    public var reservedAt: Date
    public var writtenAt: Date?
    public var uploadedAt: Date?
    public var transcribedAt: Date?
    public var finalizedAt: Date?
    public var deletedAudioAt: Date?
    public var startTimeOffset: TimeInterval?
    public var duration: TimeInterval?
    public var chunkDuration: TimeInterval?
    public var overlapDuration: TimeInterval?
    public var strideDuration: TimeInterval?

    public init(
        key: TempAudioChunkKey,
        state: TempAudioChunkLifecycleState,
        temporaryAudioPath: String?,
        byteCount: Int? = nil,
        reservedAt: Date,
        writtenAt: Date? = nil,
        uploadedAt: Date? = nil,
        transcribedAt: Date? = nil,
        finalizedAt: Date? = nil,
        deletedAudioAt: Date? = nil,
        startTimeOffset: TimeInterval? = nil,
        duration: TimeInterval? = nil,
        chunkDuration: TimeInterval? = nil,
        overlapDuration: TimeInterval? = nil,
        strideDuration: TimeInterval? = nil
    ) {
        self.key = key
        self.state = state
        self.temporaryAudioPath = temporaryAudioPath
        self.byteCount = byteCount
        self.reservedAt = reservedAt
        self.writtenAt = writtenAt
        self.uploadedAt = uploadedAt
        self.transcribedAt = transcribedAt
        self.finalizedAt = finalizedAt
        self.deletedAudioAt = deletedAudioAt
        self.startTimeOffset = startTimeOffset
        self.duration = duration
        self.chunkDuration = chunkDuration
        self.overlapDuration = overlapDuration
        self.strideDuration = strideDuration
    }
}

public struct TempAudioChunkTimingMetadata: Codable, Equatable, Sendable {
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

public struct TempAudioSessionFinalizationReport: Equatable, Sendable {
    public var sessionID: UUID
    public var finalizedChunks: [TempAudioChunkMetadata]

    public init(sessionID: UUID, finalizedChunks: [TempAudioChunkMetadata]) {
        self.sessionID = sessionID
        self.finalizedChunks = finalizedChunks
    }

    public var finalizedChunkCount: Int {
        finalizedChunks.count
    }
}

public protocol TempAudioChunkStore: Sendable {
    func createSessionDirectory(for sessionID: UUID) async throws -> URL
    func reserveChunk(
        sessionID: UUID,
        trackKind: String,
        sequenceNumber: Int,
        fileExtension: String
    ) async throws -> TempAudioChunkReservation
    func writeChunk(_ data: Data, to reservation: TempAudioChunkReservation) async throws -> TempAudioChunkMetadata
    func markWritten(_ reservation: TempAudioChunkReservation) async throws -> TempAudioChunkMetadata
    func markWritten(
        _ reservation: TempAudioChunkReservation,
        timingMetadata: TempAudioChunkTimingMetadata?
    ) async throws -> TempAudioChunkMetadata
    func markUploaded(_ key: TempAudioChunkKey) async throws -> TempAudioChunkMetadata
    func markTranscribed(_ key: TempAudioChunkKey) async throws -> TempAudioChunkMetadata
    func finalizeChunk(_ key: TempAudioChunkKey) async throws -> TempAudioChunkMetadata
    func metadata(for key: TempAudioChunkKey) async throws -> TempAudioChunkMetadata?
    func audioFileURL(for key: TempAudioChunkKey) async throws -> URL?
}

public extension TempAudioChunkStore {
    func markWritten(
        _ reservation: TempAudioChunkReservation,
        timingMetadata: TempAudioChunkTimingMetadata?
    ) async throws -> TempAudioChunkMetadata {
        _ = timingMetadata
        return try await markWritten(reservation)
    }
}

public enum TempAudioChunkStoreError: Error, Equatable, Sendable {
    case missingMetadata(TempAudioChunkKey)
    case missingAudioFile(TempAudioChunkKey)
    case finalizedChunkCannotBeModified(TempAudioChunkKey)
}

public actor FilesystemTempAudioChunkStore: TempAudioChunkStore {
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

    public func createSessionDirectory(for sessionID: UUID) throws -> URL {
        let directory = sessionDirectory(for: sessionID)
        try createPrivateDirectory(at: rootDirectory)
        try createPrivateDirectory(at: directory)
        try createPrivateDirectory(at: metadataDirectory(for: sessionID))
        return directory
    }

    public func reserveChunk(
        sessionID: UUID,
        trackKind: String,
        sequenceNumber: Int,
        fileExtension: String = "wav"
    ) throws -> TempAudioChunkReservation {
        let key = TempAudioChunkKey(sessionID: sessionID, trackKind: trackKind, sequenceNumber: sequenceNumber)
        let metadataURL = metadataFileURL(for: key)
        if let metadata = try metadata(for: key) {
            guard metadata.state != .finalized else {
                throw TempAudioChunkStoreError.finalizedChunkCannotBeModified(key)
            }
            guard let temporaryAudioPath = metadata.temporaryAudioPath else {
                throw TempAudioChunkStoreError.missingAudioFile(key)
            }

            return TempAudioChunkReservation(
                key: key,
                audioFileURL: rootDirectory.appending(path: temporaryAudioPath),
                metadataFileURL: metadataURL
            )
        }

        let audioURL = audioFileURL(for: key, fileExtension: fileExtension)

        try createPrivateDirectory(at: rootDirectory)
        try createPrivateDirectory(at: sessionDirectory(for: sessionID))
        try createPrivateDirectory(at: audioURL.deletingLastPathComponent())
        try createPrivateDirectory(at: metadataURL.deletingLastPathComponent())

        let metadata = TempAudioChunkMetadata(
            key: key,
            state: .reserved,
            temporaryAudioPath: relativePath(for: audioURL),
            reservedAt: now()
        )
        try writeMetadata(metadata)

        return TempAudioChunkReservation(key: key, audioFileURL: audioURL, metadataFileURL: metadataURL)
    }

    public func writeChunk(_ data: Data, to reservation: TempAudioChunkReservation) async throws -> TempAudioChunkMetadata {
        let metadata = try requireMetadata(for: reservation.key)
        guard metadata.state != .finalized else {
            throw TempAudioChunkStoreError.finalizedChunkCannotBeModified(reservation.key)
        }

        try data.write(to: reservation.audioFileURL, options: .atomic)
        try protectPrivateFile(at: reservation.audioFileURL)
        return try await markWritten(reservation)
    }

    public func markWritten(_ reservation: TempAudioChunkReservation) async throws -> TempAudioChunkMetadata {
        try await markWritten(reservation, timingMetadata: nil)
    }

    public func markWritten(
        _ reservation: TempAudioChunkReservation,
        timingMetadata: TempAudioChunkTimingMetadata?
    ) async throws -> TempAudioChunkMetadata {
        guard var metadata = try metadata(for: reservation.key) else {
            throw TempAudioChunkStoreError.missingMetadata(reservation.key)
        }
        guard metadata.state != .finalized else {
            throw TempAudioChunkStoreError.finalizedChunkCannotBeModified(reservation.key)
        }
        guard FileManager.default.fileExists(atPath: reservation.audioFileURL.path(percentEncoded: false)) else {
            throw TempAudioChunkStoreError.missingAudioFile(reservation.key)
        }

        try protectPrivateFile(at: reservation.audioFileURL)
        metadata.state = .written
        metadata.temporaryAudioPath = relativePath(for: reservation.audioFileURL)
        metadata.byteCount = try byteCount(at: reservation.audioFileURL)
        metadata.writtenAt = now()
        if let timingMetadata {
            metadata.startTimeOffset = timingMetadata.startTimeOffset
            metadata.duration = timingMetadata.duration
            metadata.chunkDuration = timingMetadata.chunkDuration
            metadata.overlapDuration = timingMetadata.overlapDuration
            metadata.strideDuration = timingMetadata.strideDuration
        }
        try writeMetadata(metadata)
        return metadata
    }

    public func markUploaded(_ key: TempAudioChunkKey) throws -> TempAudioChunkMetadata {
        var metadata = try requireMetadata(for: key)
        guard metadata.state != .finalized else {
            return metadata
        }

        metadata.state = .uploaded
        metadata.uploadedAt = now()
        try writeMetadata(metadata)
        return metadata
    }

    public func markTranscribed(_ key: TempAudioChunkKey) throws -> TempAudioChunkMetadata {
        var metadata = try requireMetadata(for: key)
        guard metadata.state != .finalized else {
            return metadata
        }

        metadata.state = .transcribed
        metadata.transcribedAt = now()
        try writeMetadata(metadata)
        return metadata
    }

    public func finalizeChunk(_ key: TempAudioChunkKey) throws -> TempAudioChunkMetadata {
        var metadata = try requireMetadata(for: key)
        guard metadata.state != .finalized else {
            return metadata
        }

        if let temporaryAudioPath = metadata.temporaryAudioPath {
            let audioURL = rootDirectory.appending(path: temporaryAudioPath)
            if FileManager.default.fileExists(atPath: audioURL.path(percentEncoded: false)) {
                try FileManager.default.removeItem(at: audioURL)
            }
        }

        let date = now()
        metadata.state = .finalized
        metadata.finalizedAt = date
        metadata.deletedAudioAt = date
        metadata.temporaryAudioPath = nil
        try writeMetadata(metadata)
        return metadata
    }

    public func finalizeSessionChunks(for sessionID: UUID) throws -> TempAudioSessionFinalizationReport {
        let metadataDirectory = metadataDirectory(for: sessionID)
        guard FileManager.default.fileExists(atPath: metadataDirectory.path(percentEncoded: false)) else {
            return TempAudioSessionFinalizationReport(sessionID: sessionID, finalizedChunks: [])
        }

        let metadataURLs = try FileManager.default.contentsOfDirectory(
            at: metadataDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        var finalizedChunks: [TempAudioChunkMetadata] = []
        for metadataURL in metadataURLs {
            let data = try Data(contentsOf: metadataURL)
            let metadata = try decoder.decode(TempAudioChunkMetadata.self, from: data)
            finalizedChunks.append(try finalizeChunk(metadata.key))
        }

        try removeEmptyAudioDirectories(for: sessionID)

        return TempAudioSessionFinalizationReport(
            sessionID: sessionID,
            finalizedChunks: finalizedChunks
        )
    }

    public func metadata(for key: TempAudioChunkKey) throws -> TempAudioChunkMetadata? {
        let url = metadataFileURL(for: key)
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else {
            return nil
        }

        let data = try Data(contentsOf: url)
        return try decoder.decode(TempAudioChunkMetadata.self, from: data)
    }

    public func audioFileURL(for key: TempAudioChunkKey) throws -> URL? {
        guard let metadata = try metadata(for: key),
              let temporaryAudioPath = metadata.temporaryAudioPath
        else {
            return nil
        }

        return rootDirectory.appending(path: temporaryAudioPath)
    }

    private func requireMetadata(for key: TempAudioChunkKey) throws -> TempAudioChunkMetadata {
        guard let metadata = try metadata(for: key) else {
            throw TempAudioChunkStoreError.missingMetadata(key)
        }

        return metadata
    }

    private func writeMetadata(_ metadata: TempAudioChunkMetadata) throws {
        let url = metadataFileURL(for: metadata.key)
        try createPrivateDirectory(at: url.deletingLastPathComponent())
        let data = try encoder.encode(metadata)
        try data.write(to: url, options: .atomic)
        try protectPrivateFile(at: url)
    }

    private func byteCount(at url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false))
        return attributes[.size] as? Int ?? 0
    }

    private func sessionDirectory(for sessionID: UUID) -> URL {
        rootDirectory.appending(path: sessionID.uuidString, directoryHint: .isDirectory)
    }

    private func metadataDirectory(for sessionID: UUID) -> URL {
        sessionDirectory(for: sessionID).appending(path: "_metadata", directoryHint: .isDirectory)
    }

    private func removeEmptyAudioDirectories(for sessionID: UUID) throws {
        let directory = sessionDirectory(for: sessionID)
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return
        }

        var directories: [URL] = []
        for case let url as URL in enumerator {
            let resourceValues = try url.resourceValues(forKeys: [.isDirectoryKey])
            guard resourceValues.isDirectory == true,
                  url.lastPathComponent != "_metadata"
            else {
                continue
            }
            directories.append(url)
        }

        for directory in directories.sorted(by: { $0.path.count > $1.path.count }) {
            let contents = try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
            if contents.isEmpty {
                try FileManager.default.removeItem(at: directory)
            }
        }
    }

    private func audioFileURL(for key: TempAudioChunkKey, fileExtension: String) -> URL {
        sessionDirectory(for: key.sessionID)
            .appending(path: sanitizedPathComponent(key.trackKind), directoryHint: .isDirectory)
            .appending(path: "\(paddedSequenceNumber(key.sequenceNumber)).\(sanitizedFileExtension(fileExtension))")
    }

    private func metadataFileURL(for key: TempAudioChunkKey) -> URL {
        metadataDirectory(for: key.sessionID)
            .appending(path: "\(sanitizedPathComponent(key.trackKind))-\(paddedSequenceNumber(key.sequenceNumber)).json")
    }

    private func relativePath(for url: URL) -> String {
        let rootPath = rootDirectory.path(percentEncoded: false)
        let path = url.path(percentEncoded: false)
        guard path.hasPrefix(rootPath) else {
            return path
        }

        return String(path.dropFirst(rootPath.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private func paddedSequenceNumber(_ sequenceNumber: Int) -> String {
        String(format: "%06d", sequenceNumber)
    }

    private func sanitizedPathComponent(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let scalars = value.unicodeScalars.map { scalar in
            allowed.contains(scalar) ? Character(scalar) : "_"
        }
        let sanitized = String(scalars)
        return sanitized.isEmpty ? "unknown" : sanitized
    }

    private func sanitizedFileExtension(_ value: String) -> String {
        let sanitized = sanitizedPathComponent(value.trimmingCharacters(in: CharacterSet(charactersIn: ".")))
        return sanitized.isEmpty ? "wav" : sanitized
    }

    private func createPrivateDirectory(at url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: url.path(percentEncoded: false)
        )
    }

    private func protectPrivateFile(at url: URL) throws {
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path(percentEncoded: false)
        )
    }
}

import BarnOwlTranscription
import Foundation

public struct SQLiteRollingFinalTranscriptionCacheStore: RollingFinalTranscriptionCacheStore {
    private let database: BarnOwlDatabase
    private let now: @Sendable () -> Date

    public init(
        database: BarnOwlDatabase,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.database = database
        self.now = now
    }

    public func completedResponse(
        for key: RollingFinalTranscriptionKey,
        modelIdentifier: String?
    ) async throws -> AudioFileTranscriptionResponse? {
        guard let record = try await database.rollingTranscription(
            sessionID: key.sessionID,
            trackID: key.trackID,
            sequenceNumber: key.sequenceNumber
        ),
            record.status == .completed,
            modelIdentifier == nil || record.modelIdentifier == modelIdentifier,
            let responseJSON = record.responseJSON,
            let data = responseJSON.data(using: .utf8)
        else {
            return nil
        }

        return try JSONDecoder().decode(AudioFileTranscriptionResponse.self, from: data)
    }

    public func markRunning(
        key: RollingFinalTranscriptionKey,
        audioFile: RecordedAudioFile,
        modelIdentifier: String?
    ) async throws -> Bool {
        if let existing = try await database.rollingTranscription(
            sessionID: key.sessionID,
            trackID: key.trackID,
            sequenceNumber: key.sequenceNumber
        ),
            existing.status == .completed,
            modelIdentifier == nil || existing.modelIdentifier == modelIdentifier {
            return false
        }

        let timestamp = now()
        try await database.upsertRollingTranscription(BarnOwlRollingTranscriptionRecord(
            sessionID: key.sessionID,
            trackID: key.trackID,
            sequenceNumber: key.sequenceNumber,
            trackLabel: audioFile.trackLabel,
            audioFilePath: audioFile.url.path(percentEncoded: false),
            startTimeOffset: audioFile.startTimeOffset,
            duration: audioFile.duration,
            overlapDuration: audioFile.overlapDuration,
            modelIdentifier: modelIdentifier,
            status: .running,
            createdAt: timestamp,
            updatedAt: timestamp
        ))
        return true
    }

    public func markCompleted(
        key: RollingFinalTranscriptionKey,
        audioFile: RecordedAudioFile,
        modelIdentifier: String?,
        response: AudioFileTranscriptionResponse
    ) async throws {
        let timestamp = now()
        let responseData = try JSONEncoder().encode(response)
        try await database.upsertRollingTranscription(BarnOwlRollingTranscriptionRecord(
            sessionID: key.sessionID,
            trackID: key.trackID,
            sequenceNumber: key.sequenceNumber,
            trackLabel: audioFile.trackLabel,
            audioFilePath: audioFile.url.path(percentEncoded: false),
            startTimeOffset: audioFile.startTimeOffset,
            duration: audioFile.duration,
            overlapDuration: audioFile.overlapDuration,
            modelIdentifier: modelIdentifier,
            status: .completed,
            responseJSON: String(decoding: responseData, as: UTF8.self),
            createdAt: timestamp,
            updatedAt: timestamp,
            completedAt: timestamp
        ))
    }

    public func markFailed(
        key: RollingFinalTranscriptionKey,
        audioFile: RecordedAudioFile,
        modelIdentifier: String?,
        errorMessage: String
    ) async throws {
        let timestamp = now()
        try await database.upsertRollingTranscription(BarnOwlRollingTranscriptionRecord(
            sessionID: key.sessionID,
            trackID: key.trackID,
            sequenceNumber: key.sequenceNumber,
            trackLabel: audioFile.trackLabel,
            audioFilePath: audioFile.url.path(percentEncoded: false),
            startTimeOffset: audioFile.startTimeOffset,
            duration: audioFile.duration,
            overlapDuration: audioFile.overlapDuration,
            modelIdentifier: modelIdentifier,
            status: .failed,
            errorMessage: String(errorMessage.prefix(1_000)),
            createdAt: timestamp,
            updatedAt: timestamp
        ))
    }
}

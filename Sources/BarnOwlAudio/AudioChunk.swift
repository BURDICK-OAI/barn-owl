import Foundation

public enum AudioTrackKind: String, Codable, Equatable, Sendable {
    case microphone
    case systemAudio
    case mixed
}

public struct AudioChunk: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public var sessionID: UUID
    public var trackKind: AudioTrackKind
    public var sequenceNumber: Int
    public var fileURL: URL

    public init(sessionID: UUID, trackKind: AudioTrackKind, sequenceNumber: Int, fileURL: URL) {
        self.sessionID = sessionID
        self.trackKind = trackKind
        self.sequenceNumber = sequenceNumber
        self.fileURL = fileURL
        id = "\(sessionID.uuidString)-\(trackKind.rawValue)-\(sequenceNumber)"
    }
}

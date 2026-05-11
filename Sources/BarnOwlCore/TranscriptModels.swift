import Foundation

public struct TranscriptSegment: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var speakerLabel: String
    public var text: String
    public var startTime: TimeInterval
    public var endTime: TimeInterval
    public var confidence: Double?

    public init(
        id: UUID = UUID(),
        speakerLabel: String,
        text: String,
        startTime: TimeInterval,
        endTime: TimeInterval,
        confidence: Double? = nil
    ) {
        self.id = id
        self.speakerLabel = speakerLabel
        self.text = text
        self.startTime = startTime
        self.endTime = endTime
        self.confidence = confidence
    }
}

public struct MeetingSummary: Codable, Equatable, Sendable {
    public var suggestedTitle: String?
    public var overview: String
    public var decisions: [String]
    public var actionItems: [String]
    public var openQuestions: [String]

    public init(
        suggestedTitle: String? = nil,
        overview: String,
        decisions: [String] = [],
        actionItems: [String] = [],
        openQuestions: [String] = []
    ) {
        self.suggestedTitle = suggestedTitle
        self.overview = overview
        self.decisions = decisions
        self.actionItems = actionItems
        self.openQuestions = openQuestions
    }
}

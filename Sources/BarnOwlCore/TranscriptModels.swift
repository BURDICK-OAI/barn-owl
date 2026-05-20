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

public enum TranscriptPersistenceGuard {
    private static let blockedPrefixes = [
        "conservative learned spelling hints:",
        "use these local barn owl vocabulary hints learned from prior final transcripts.",
        "keep transcription literal; do not add words that were not spoken.",
        "realtime transcription idle.",
        "realtime connecting",
        "realtime reconnecting",
        "realtime connected.",
        "realtime receiving audio.",
        "realtime transcribing live.",
        "realtime degraded;",
        "realtime fallback active;",
        "realtime transcription stopped.",
        "starting realtime transcription."
    ]

    public static func sanitizedText(_ text: String) -> String? {
        let cleaned = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        guard !cleaned.isEmpty else {
            return nil
        }

        let normalized = cleaned
            .folding(
                options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )
            .lowercased()

        guard !blockedPrefixes.contains(where: normalized.hasPrefix) else {
            return nil
        }

        return cleaned
    }

    public static func blocks(_ text: String) -> Bool {
        sanitizedText(text) == nil
    }
}

public struct MeetingSummary: Codable, Equatable, Sendable {
    public static let fallbackOverview = "Transcript saved. Summary generation failed, so Barn Owl kept the diarized transcript and logged the summary error."

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

    public var usedFallbackSummary: Bool {
        overview.trimmingCharacters(in: .whitespacesAndNewlines) == Self.fallbackOverview
    }
}

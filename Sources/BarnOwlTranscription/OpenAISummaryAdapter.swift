import BarnOwlCore
import BarnOwlOpenAI
import Foundation

public struct OpenAIMeetingSummaryGeneratorAdapter: MeetingSummaryGenerator {
    private let client: any MeetingSummaryClient

    public init(client: any MeetingSummaryClient) {
        self.client = client
    }

    public func generateSummary(
        session: RecordingSession,
        segments: [TranscriptSegment],
        context: [String]
    ) async throws -> MeetingSummary {
        try await client.createSummary(
            session: session,
            segments: segments,
            context: context
        )
    }
}

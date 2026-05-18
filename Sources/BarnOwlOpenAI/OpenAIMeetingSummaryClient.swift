import BarnOwlCore
import Foundation

public protocol MeetingSummaryClient: Sendable {
    func createSummary(
        session: RecordingSession,
        segments: [TranscriptSegment],
        context: [String]
    ) async throws -> MeetingSummary
}

public enum OpenAIResponsesClientError: Error, Sendable {
    case invalidHTTPResponse
    case unsuccessfulStatusCode(Int, Data)
    case responseDecodingFailed(String, Data)
    case summaryPayloadDecodingFailed(String, String)
    case missingOutputText
    case refused(String)
}

public struct OpenAIMeetingSummaryClient: MeetingSummaryClient {
    private let configuration: OpenAIConfiguration
    private let baseURL: URL
    private let model: String
    private let transport: any OpenAIHTTPTransport

    public init(
        configuration: OpenAIConfiguration,
        baseURL: URL = URL(string: "https://api.openai.com")!,
        model: String = OpenAIModelCatalog.summaryAndActions,
        transport: any OpenAIHTTPTransport = URLSession.shared
    ) {
        self.configuration = configuration
        self.baseURL = baseURL
        self.model = model
        self.transport = transport
    }

    public func createSummary(
        session: RecordingSession,
        segments: [TranscriptSegment],
        context: [String] = []
    ) async throws -> MeetingSummary {
        let request = try makeSummaryRequest(
            session: session,
            segments: segments,
            context: context
        )
        let (data, response) = try await transport.data(for: request)

        guard (200..<300).contains(response.statusCode) else {
            throw OpenAIResponsesClientError.unsuccessfulStatusCode(response.statusCode, data)
        }

        let apiResponse: OpenAIResponsesAPIResponse
        do {
            apiResponse = try JSONDecoder().decode(OpenAIResponsesAPIResponse.self, from: data)
        } catch {
            throw OpenAIResponsesClientError.responseDecodingFailed(String(describing: error), data)
        }
        if let refusal = apiResponse.firstRefusal {
            throw OpenAIResponsesClientError.refused(refusal)
        }

        guard let outputText = apiResponse.firstOutputText else {
            throw OpenAIResponsesClientError.missingOutputText
        }

        let payload: OpenAIMeetingSummaryPayload
        do {
            payload = try JSONDecoder().decode(
                OpenAIMeetingSummaryPayload.self,
                from: Data(outputText.utf8)
            )
        } catch {
            throw OpenAIResponsesClientError.summaryPayloadDecodingFailed(String(describing: error), outputText)
        }
        return MeetingSummary(
            suggestedTitle: payload.suggestedTitle,
            overview: payload.overview,
            decisions: payload.decisions,
            actionItems: payload.actionItems,
            openQuestions: payload.openQuestions
        )
    }

    private func makeSummaryRequest(
        session: RecordingSession,
        segments: [TranscriptSegment],
        context: [String]
    ) throws -> URLRequest {
        let input = OpenAIMeetingSummaryInput(
            title: session.title,
            startedAt: ISO8601DateFormatter().string(from: session.startedAt),
            endedAt: session.endedAt.map { ISO8601DateFormatter().string(from: $0) },
            context: context,
            transcript: segments.map { segment in
                OpenAIMeetingSummaryInput.Segment(
                    speaker: segment.speakerLabel,
                    text: segment.text,
                    startTime: segment.startTime,
                    endTime: segment.endTime,
                    confidence: segment.confidence
                )
            }
        )
        let inputData = try JSONEncoder().encode(input)
        let inputText = String(decoding: inputData, as: UTF8.self)

        let body: [String: Any] = [
            "model": model,
            "reasoning": [
                "effort": "high"
            ],
            "input": [
                [
                    "role": "system",
                    "content": """
                    You create accurate Barn Owl meeting notes from diarized transcripts. Preserve uncertainty, do not invent facts, and return empty arrays when the transcript does not support a section.

                    For suggestedTitle, create a contextual meeting title from both context and transcript. Choose the title shape that matches the meeting: use "Customer: Topic" only for customer/account/external meetings; use forms like "Name / Name 1:1", "Team: Topic", "Project: Planning", "Candidate: Interview", "Roadmap Review", or "Incident Review" for internal, 1:1, recruiting, planning, review, or operational meetings. Treat calendar event title, attendees, and user-provided context as strong signals; use the transcript to refine the topic. Do not use jokes, metaphors, quoted phrases, or internal names mentioned in the transcript as the title unless context explicitly says that is the meeting title.
                    """
                ],
                [
                    "role": "user",
                    "content": inputText
                ]
            ],
            "text": [
                "verbosity": "medium",
                "format": [
                    "type": "json_schema",
                    "name": "barn_owl_meeting_summary",
                    "strict": true,
                    "schema": Self.summarySchema
                ]
            ]
        ]

        var request = URLRequest(url: baseURL.appending(path: "v1/responses"))
        request.httpMethod = "POST"
        request.timeoutInterval = 240
        request.setValue("Bearer \(configuration.apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        return request
    }

    private static var summarySchema: [String: Any] {
        [
            "type": "object",
            "additionalProperties": false,
            "required": ["suggestedTitle", "overview", "decisions", "actionItems", "openQuestions"],
            "properties": [
                "suggestedTitle": [
                    "type": "string",
                    "description": "A concise contextual title using the right shape for the meeting type: Customer: Topic for external account meetings, Name / Name 1:1 for one-on-ones, Team: Topic or Project: Topic for internal meetings, and similarly specific forms for recruiting, reviews, planning, and incidents. Avoid generic titles and transcript jokes/asides."
                ],
                "overview": [
                    "type": "string"
                ],
                "decisions": [
                    "type": "array",
                    "items": ["type": "string"]
                ],
                "actionItems": [
                    "type": "array",
                    "items": ["type": "string"]
                ],
                "openQuestions": [
                    "type": "array",
                    "items": ["type": "string"]
                ]
            ]
        ]
    }
}

private struct OpenAIMeetingSummaryInput: Encodable {
    var title: String
    var startedAt: String
    var endedAt: String?
    var context: [String]
    var transcript: [Segment]

    struct Segment: Encodable {
        var speaker: String
        var text: String
        var startTime: TimeInterval
        var endTime: TimeInterval
        var confidence: Double?
    }
}

private struct OpenAIMeetingSummaryPayload: Decodable {
    var suggestedTitle: String?
    var overview: String
    var decisions: [String]
    var actionItems: [String]
    var openQuestions: [String]
}

private struct OpenAIResponsesAPIResponse: Decodable {
    var output: [OutputItem]

    var firstOutputText: String? {
        output.lazy
            .flatMap(\.content)
            .first { $0.text != nil }?
            .text
    }

    var firstRefusal: String? {
        output.lazy
            .flatMap(\.content)
            .first { $0.refusal != nil }?
            .refusal
    }

    struct OutputItem: Decodable {
        var content: [ContentItem]

        enum CodingKeys: String, CodingKey {
            case content
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            content = try container.decodeIfPresent([ContentItem].self, forKey: .content) ?? []
        }
    }

    struct ContentItem: Decodable {
        var type: String
        var text: String?
        var refusal: String?
    }
}

import BarnOwlCore
import BarnOwlOpenAI
import Foundation

public struct OpenAITranscriptOverlapRepairClient: TranscriptOverlapRepairClient {
    private let configuration: OpenAIConfiguration
    private let baseURL: URL
    private let model: String
    private let transport: any OpenAIHTTPTransport

    public init(
        configuration: OpenAIConfiguration,
        baseURL: URL = URL(string: "https://api.openai.com")!,
        model: String = OpenAIModelCatalog.transcriptQA,
        transport: any OpenAIHTTPTransport = URLSession.shared
    ) {
        self.configuration = configuration
        self.baseURL = baseURL
        self.model = model
        self.transport = transport
    }

    public func repair(_ request: TranscriptOverlapRepairRequest) async throws -> TranscriptOverlapRepairResponse {
        let urlRequest = try makeRequest(request)
        let (data, response) = try await transport.data(for: urlRequest)
        guard (200..<300).contains(response.statusCode) else {
            throw OpenAIResponsesClientError.unsuccessfulStatusCode(response.statusCode, data)
        }

        let apiResponse = try JSONDecoder().decode(OverlapRepairResponsesAPIResponse.self, from: data)
        if let refusal = apiResponse.firstRefusal {
            throw OpenAIResponsesClientError.refused(refusal)
        }
        guard let outputText = apiResponse.firstOutputText?.trimmingCharacters(in: .whitespacesAndNewlines),
              !outputText.isEmpty
        else {
            throw OpenAIResponsesClientError.missingOutputText
        }

        do {
            let payload = try JSONDecoder().decode(OverlapRepairPayload.self, from: Data(outputText.utf8))
            return TranscriptOverlapRepairResponse(
                segments: payload.segments.map {
                    TranscriptSegment(
                        speakerLabel: $0.speakerLabel,
                        text: $0.text,
                        startTime: $0.startTime,
                        endTime: $0.endTime,
                        confidence: $0.confidence
                    )
                },
                conflict: payload.conflict,
                reason: payload.reason
            )
        } catch {
            throw OpenAIResponsesClientError.summaryPayloadDecodingFailed(String(describing: error), outputText)
        }
    }

    public func makeRequest(_ request: TranscriptOverlapRepairRequest) throws -> URLRequest {
        let input = OverlapRepairInput(
            boundary: request.boundary,
            contextBefore: request.contextBefore,
            previousChunkOverlapSegments: request.previousChunkOverlapSegments,
            nextChunkOverlapSegments: request.nextChunkOverlapSegments,
            deterministicProposal: request.deterministicProposal,
            contextAfter: request.contextAfter
        )
        let inputData = try JSONEncoder().encode(input)
        let inputText = String(decoding: inputData, as: UTF8.self)
        let body: [String: Any] = [
            "model": model,
            "reasoning": [
                "effort": "low"
            ],
            "input": [
                [
                    "role": "system",
                    "content": """
                    You repair transcript overlap between adjacent audio chunks. You must preserve spoken wording. Do not summarize, paraphrase, polish, or invent content. Only remove duplicated overlap, join clipped boundary text, and preserve speaker/timestamps unless the overlap clearly proves a better boundary. If wording conflicts materially, mark conflict=true and keep the safer deterministic proposal.
                    """
                ],
                [
                    "role": "user",
                    "content": inputText
                ]
            ],
            "text": [
                "verbosity": "low",
                "format": [
                    "type": "json_schema",
                    "name": "barn_owl_overlap_repair",
                    "strict": true,
                    "schema": Self.responseSchema
                ]
            ]
        ]

        var urlRequest = URLRequest(url: baseURL.appending(path: "v1/responses"))
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = 20
        urlRequest.setValue("Bearer \(configuration.apiKey)", forHTTPHeaderField: "Authorization")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        return urlRequest
    }

    private static var responseSchema: [String: Any] {
        [
            "type": "object",
            "additionalProperties": false,
            "required": ["segments", "conflict", "reason"],
            "properties": [
                "segments": [
                    "type": "array",
                    "items": [
                        "type": "object",
                        "additionalProperties": false,
                        "required": ["speakerLabel", "text", "startTime", "endTime", "confidence"],
                        "properties": [
                            "speakerLabel": ["type": "string"],
                            "text": ["type": "string"],
                            "startTime": ["type": "number"],
                            "endTime": ["type": "number"],
                            "confidence": ["type": ["number", "null"]]
                        ]
                    ]
                ],
                "conflict": ["type": "boolean"],
                "reason": ["type": "string"]
            ]
        ]
    }
}

private struct OverlapRepairInput: Encodable {
    var instructions = Instructions()
    var boundary: Boundary
    var contextBefore: [Segment]
    var previousChunkOverlapSegments: [Segment]
    var nextChunkOverlapSegments: [Segment]
    var deterministicProposal: [Segment]
    var contextAfter: [Segment]

    init(
        boundary: TranscriptOverlapBoundary,
        contextBefore: [TranscriptSegment],
        previousChunkOverlapSegments: [TranscriptSegment],
        nextChunkOverlapSegments: [TranscriptSegment],
        deterministicProposal: [TranscriptSegment],
        contextAfter: [TranscriptSegment]
    ) {
        self.boundary = Boundary(boundary)
        self.contextBefore = contextBefore.map(Segment.init)
        self.previousChunkOverlapSegments = previousChunkOverlapSegments.map(Segment.init)
        self.nextChunkOverlapSegments = nextChunkOverlapSegments.map(Segment.init)
        self.deterministicProposal = deterministicProposal.map(Segment.init)
        self.contextAfter = contextAfter.map(Segment.init)
    }

    struct Instructions: Encodable {
        var preserveWording = true
        var allowedChanges = [
            "remove duplicate words caused by overlap",
            "join clipped sentence fragments across the boundary",
            "choose the more complete duplicate segment",
            "normalize speaker labels only when overlap clearly proves continuity"
        ]
        var forbiddenChanges = [
            "summarization",
            "paraphrasing",
            "style improvement",
            "inventing missing words",
            "changing meaning"
        ]

        enum CodingKeys: String, CodingKey {
            case preserveWording = "preserve_wording"
            case allowedChanges = "allowed_changes"
            case forbiddenChanges = "forbidden_changes"
        }
    }

    struct Boundary: Encodable {
        var track: String
        var previousChunkSequence: Int?
        var nextChunkSequence: Int?
        var boundaryTime: TimeInterval
        var overlapSeconds: TimeInterval

        init(_ boundary: TranscriptOverlapBoundary) {
            track = boundary.trackID
            previousChunkSequence = boundary.previousChunkSequence
            nextChunkSequence = boundary.nextChunkSequence
            boundaryTime = boundary.boundaryTime
            overlapSeconds = boundary.overlapSeconds
        }

        enum CodingKeys: String, CodingKey {
            case track
            case previousChunkSequence = "previous_chunk_sequence"
            case nextChunkSequence = "next_chunk_sequence"
            case boundaryTime = "boundary_time"
            case overlapSeconds = "overlap_seconds"
        }
    }

    struct Segment: Encodable {
        var speakerLabel: String
        var text: String
        var startTime: TimeInterval
        var endTime: TimeInterval
        var confidence: Double?

        init(_ segment: TranscriptSegment) {
            speakerLabel = segment.speakerLabel
            text = segment.text
            startTime = segment.startTime
            endTime = segment.endTime
            confidence = segment.confidence
        }
    }

    enum CodingKeys: String, CodingKey {
        case instructions
        case boundary
        case contextBefore = "context_before"
        case previousChunkOverlapSegments = "previous_chunk_overlap_segments"
        case nextChunkOverlapSegments = "next_chunk_overlap_segments"
        case deterministicProposal = "deterministic_proposal"
        case contextAfter = "context_after"
    }
}

private struct OverlapRepairPayload: Decodable {
    var segments: [Segment]
    var conflict: Bool
    var reason: String

    struct Segment: Decodable {
        var speakerLabel: String
        var text: String
        var startTime: TimeInterval
        var endTime: TimeInterval
        var confidence: Double?
    }
}

private struct OverlapRepairResponsesAPIResponse: Decodable {
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
        var text: String?
        var refusal: String?
    }
}

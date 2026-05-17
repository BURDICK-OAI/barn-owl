import BarnOwlCore
import Foundation

public struct BarnOwlKnowledgeResolutionRequest: Codable, Equatable, Sendable {
    public var concept: BarnOwlControlKnowledgeConcept
    public var relatedMeetings: [BarnOwlControlMeeting]
    public var transcriptExcerpts: [BarnOwlControlKnowledgeExcerpt]
    public var matchingContextLibraryEntries: [BarnOwlControlContextLibraryEntry]

    public init(
        concept: BarnOwlControlKnowledgeConcept,
        relatedMeetings: [BarnOwlControlMeeting],
        transcriptExcerpts: [BarnOwlControlKnowledgeExcerpt],
        matchingContextLibraryEntries: [BarnOwlControlContextLibraryEntry]
    ) {
        self.concept = concept
        self.relatedMeetings = relatedMeetings
        self.transcriptExcerpts = transcriptExcerpts
        self.matchingContextLibraryEntries = matchingContextLibraryEntries
    }
}

public struct BarnOwlKnowledgeResolution: Codable, Equatable, Sendable {
    public var shouldPersist: Bool
    public var kind: ContextEntityKind?
    public var canonicalName: String?
    public var aliases: [String]
    public var confidence: Double
    public var rationale: String

    public init(
        shouldPersist: Bool,
        kind: ContextEntityKind? = nil,
        canonicalName: String? = nil,
        aliases: [String] = [],
        confidence: Double,
        rationale: String
    ) {
        self.shouldPersist = shouldPersist
        self.kind = kind
        self.canonicalName = canonicalName
        self.aliases = aliases
        self.confidence = min(max(confidence, 0), 1)
        self.rationale = rationale
    }
}

public protocol BarnOwlKnowledgeResolving: Sendable {
    func resolve(request: BarnOwlKnowledgeResolutionRequest) async throws -> BarnOwlKnowledgeResolution
}

public struct OpenAIKnowledgeResolutionClient: BarnOwlKnowledgeResolving {
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

    public func resolve(request: BarnOwlKnowledgeResolutionRequest) async throws -> BarnOwlKnowledgeResolution {
        let request = try makeRequest(input: request)
        let (data, response) = try await transport.data(for: request)
        guard (200..<300).contains(response.statusCode) else {
            throw OpenAIResponsesClientError.unsuccessfulStatusCode(response.statusCode, data)
        }

        let apiResponse: KnowledgeResolutionResponsesAPIResponse
        do {
            apiResponse = try JSONDecoder().decode(KnowledgeResolutionResponsesAPIResponse.self, from: data)
        } catch {
            throw OpenAIResponsesClientError.responseDecodingFailed(String(describing: error), data)
        }
        if let refusal = apiResponse.firstRefusal {
            throw OpenAIResponsesClientError.refused(refusal)
        }
        guard let outputText = apiResponse.firstOutputText else {
            throw OpenAIResponsesClientError.missingOutputText
        }
        do {
            return try JSONDecoder().decode(BarnOwlKnowledgeResolution.self, from: Data(outputText.utf8))
        } catch {
            throw OpenAIResponsesClientError.summaryPayloadDecodingFailed(String(describing: error), outputText)
        }
    }

    public func makeRequest(input: BarnOwlKnowledgeResolutionRequest) throws -> URLRequest {
        let inputData = try JSONEncoder().encode(input)
        let body: [String: Any] = [
            "model": model,
            "reasoning": [
                "effort": "high"
            ],
            "input": [
                [
                    "role": "system",
                    "content": """
                    You resolve durable Barn Owl knowledge concepts using only the supplied local evidence. Decide whether the evidence is strong enough to persist a structured durable mapping automatically. Distinguish salience from meaning: repeated mentions alone are not enough to assign a type. Persist only when the kind and canonical name are defensible from the packet. Prefer the most specific valid kind among person, organization, customer_account, internal_function, product, project, event, glossary_term. If confidence is below 0.90 or the type is ambiguous, set shouldPersist=false.
                    """
                ],
                [
                    "role": "user",
                    "content": String(decoding: inputData, as: UTF8.self)
                ]
            ],
            "text": [
                "verbosity": "medium",
                "format": [
                    "type": "json_schema",
                    "name": "barn_owl_knowledge_resolution",
                    "strict": true,
                    "schema": Self.schema
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

    private static var schema: [String: Any] {
        [
            "type": "object",
            "additionalProperties": false,
            "required": ["shouldPersist", "kind", "canonicalName", "aliases", "confidence", "rationale"],
            "properties": [
                "shouldPersist": ["type": "boolean"],
                "kind": [
                    "type": ["string", "null"],
                    "enum": [
                        "person", "organization", "customer_account", "internal_function",
                        "product", "project", "event", "glossary_term", NSNull()
                    ]
                ],
                "canonicalName": ["type": ["string", "null"]],
                "aliases": [
                    "type": "array",
                    "items": ["type": "string"]
                ],
                "confidence": ["type": "number", "minimum": 0, "maximum": 1],
                "rationale": ["type": "string"]
            ]
        ]
    }
}

private struct KnowledgeResolutionResponsesAPIResponse: Decodable {
    var output: [OutputItem]

    var firstOutputText: String? {
        output.lazy.flatMap(\.content).first { $0.text != nil }?.text
    }

    var firstRefusal: String? {
        output.lazy.flatMap(\.content).first { $0.refusal != nil }?.refusal
    }

    struct OutputItem: Decodable {
        var content: [ContentItem]
    }

    struct ContentItem: Decodable {
        var type: String
        var text: String?
        var refusal: String?
    }
}

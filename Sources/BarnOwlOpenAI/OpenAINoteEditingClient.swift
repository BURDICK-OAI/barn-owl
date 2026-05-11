import Foundation

public protocol NoteEditingClient: Sendable {
    func updateNote(markdown: String, prompt: String, context: String) async throws -> String
}

public struct NoteEditingResult: Equatable, Sendable {
    public var markdown: String
    public var title: String?

    public init(markdown: String, title: String? = nil) {
        self.markdown = markdown
        self.title = title
    }
}

public struct BarnOwlChatContextSnippet: Codable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var source: String
    public var text: String

    public init(id: String, title: String, source: String, text: String) {
        self.id = id
        self.title = title
        self.source = source
        self.text = text
    }
}

public struct BarnOwlChatAnswer: Equatable, Sendable {
    public var answer: String
    public var citations: [String]

    public init(answer: String, citations: [String] = []) {
        self.answer = answer
        self.citations = citations
    }
}

public protocol BarnOwlChatAnswering: Sendable {
    func answer(question: String, snippets: [BarnOwlChatContextSnippet]) async throws -> BarnOwlChatAnswer
}

public struct OpenAINoteEditingClient: NoteEditingClient {
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

    public func updateNote(markdown: String, prompt: String, context: String = "") async throws -> String {
        let request = try makeRequest(markdown: markdown, prompt: prompt, context: context, responseFormat: .markdown)
        let outputText = try await perform(request: request)
        return outputText
    }

    public func updateNoteDraft(markdown: String, prompt: String, context: String = "") async throws -> NoteEditingResult {
        let request = try makeRequest(markdown: markdown, prompt: prompt, context: context, responseFormat: .structured)
        let outputText = try await perform(request: request)
        let payload: NoteEditingPayload
        do {
            payload = try JSONDecoder().decode(NoteEditingPayload.self, from: Data(outputText.utf8))
        } catch {
            throw OpenAIResponsesClientError.summaryPayloadDecodingFailed(String(describing: error), outputText)
        }

        return NoteEditingResult(
            markdown: payload.markdown.trimmingCharacters(in: .whitespacesAndNewlines),
            title: payload.title?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        )
    }

    private func perform(request: URLRequest) async throws -> String {
        let (data, response) = try await transport.data(for: request)

        guard (200..<300).contains(response.statusCode) else {
            throw OpenAIResponsesClientError.unsuccessfulStatusCode(response.statusCode, data)
        }

        let apiResponse: NoteEditingResponsesAPIResponse
        do {
            apiResponse = try JSONDecoder().decode(NoteEditingResponsesAPIResponse.self, from: data)
        } catch {
            throw OpenAIResponsesClientError.responseDecodingFailed(String(describing: error), data)
        }

        if let refusal = apiResponse.firstRefusal {
            throw OpenAIResponsesClientError.refused(refusal)
        }

        guard let outputText = apiResponse.firstOutputText?.trimmingCharacters(in: .whitespacesAndNewlines),
              !outputText.isEmpty
        else {
            throw OpenAIResponsesClientError.missingOutputText
        }

        return outputText
    }

    private func makeRequest(
        markdown: String,
        prompt: String,
        context: String,
        responseFormat: NoteEditingResponseFormat
    ) throws -> URLRequest {
        let input = NoteEditingInput(markdown: markdown, prompt: prompt, context: context)
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
                    "content": responseFormat.systemPrompt
                ],
                [
                    "role": "user",
                    "content": inputText
                ]
            ],
            "text": responseFormat.textOptions
        ]

        var request = URLRequest(url: baseURL.appending(path: "v1/responses"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(configuration.apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        return request
    }
}

public struct OpenAIBarnOwlChatClient: BarnOwlChatAnswering {
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

    public func answer(question: String, snippets: [BarnOwlChatContextSnippet]) async throws -> BarnOwlChatAnswer {
        let request = try makeRequest(question: question, snippets: snippets)
        let (data, response) = try await transport.data(for: request)

        guard (200..<300).contains(response.statusCode) else {
            throw OpenAIResponsesClientError.unsuccessfulStatusCode(response.statusCode, data)
        }

        let apiResponse: NoteEditingResponsesAPIResponse
        do {
            apiResponse = try JSONDecoder().decode(NoteEditingResponsesAPIResponse.self, from: data)
        } catch {
            throw OpenAIResponsesClientError.responseDecodingFailed(String(describing: error), data)
        }

        if let refusal = apiResponse.firstRefusal {
            throw OpenAIResponsesClientError.refused(refusal)
        }

        guard let outputText = apiResponse.firstOutputText?.trimmingCharacters(in: .whitespacesAndNewlines),
              !outputText.isEmpty
        else {
            throw OpenAIResponsesClientError.missingOutputText
        }

        let citations = snippets
            .filter { outputText.localizedCaseInsensitiveContains("[\($0.id)]") }
            .map(\.id)
        return BarnOwlChatAnswer(answer: outputText, citations: citations)
    }

    public func makeRequest(question: String, snippets: [BarnOwlChatContextSnippet]) throws -> URLRequest {
        let input = BarnOwlChatInput(question: question, snippets: snippets)
        let data = try JSONEncoder().encode(input)
        let inputText = String(decoding: data, as: UTF8.self)
        let body: [String: Any] = [
            "model": model,
            "reasoning": [
                "effort": "high"
            ],
            "input": [
                [
                    "role": "system",
                    "content": """
                    You are Barn Owl Chat. Answer only from the supplied meeting transcripts, notes, summaries, saved context snippets, and local context. If the snippets do not contain enough evidence, say what is missing. Cite evidence inline with snippet ids like [S1]. Prefer concrete decisions, action items, owners, dates, open questions, and follow-up drafts.
                    """
                ],
                [
                    "role": "user",
                    "content": inputText
                ]
            ],
            "text": [
                "verbosity": "medium"
            ]
        ]

        var request = URLRequest(url: baseURL.appending(path: "v1/responses"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(configuration.apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        return request
    }
}

private enum NoteEditingResponseFormat {
    case markdown
    case structured

    var systemPrompt: String {
        switch self {
        case .markdown:
            """
            You update Barn Owl meeting notes. Return the complete updated Markdown note only. Preserve transcript evidence, avoid inventing facts, keep useful headings, and clearly mark uncertainty when the supplied note or context is insufficient. If the prompt or context implies a better meeting name, update the top-level "# ..." Markdown title too. Keep or add a "Meeting Type" line when the note clearly fits one-on-one, team meeting, customer workshop, customer pitch, interview, hallway/random capture, incident review, planning/review, or general discussion.
            """
        case .structured:
            """
            You update Barn Owl meeting notes. Preserve transcript evidence, avoid inventing facts, keep useful headings, and clearly mark uncertainty when the supplied note or context is insufficient. Return JSON with the complete updated Markdown and the best meeting title. If the prompt or context implies a better meeting name, update both the top-level "# ..." Markdown title and the title field. Keep or add a "Meeting Type" line when the note clearly fits one-on-one, team meeting, customer workshop, customer pitch, interview, hallway/random capture, incident review, planning/review, or general discussion.
            """
        }
    }

    var textOptions: [String: Any] {
        switch self {
        case .markdown:
            [
                "verbosity": "medium"
            ]
        case .structured:
            [
                "verbosity": "medium",
                "format": [
                    "type": "json_schema",
                    "name": "barn_owl_note_edit",
                    "strict": true,
                    "schema": Self.schema
                ]
            ]
        }
    }

    private static var schema: [String: Any] {
        [
            "type": "object",
            "additionalProperties": false,
            "required": ["markdown", "title"],
            "properties": [
                "markdown": [
                    "type": "string"
                ],
                "title": [
                    "type": ["string", "null"]
                ]
            ]
        ]
    }
}

private struct NoteEditingInput: Encodable {
    var markdown: String
    var prompt: String
    var context: String
}

private struct BarnOwlChatInput: Encodable {
    var question: String
    var snippets: [BarnOwlChatContextSnippet]
}

private struct NoteEditingPayload: Decodable {
    var markdown: String
    var title: String?
}

private struct NoteEditingResponsesAPIResponse: Decodable {
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

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}

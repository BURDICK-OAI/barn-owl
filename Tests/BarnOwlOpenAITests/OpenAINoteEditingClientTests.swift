import BarnOwlOpenAI
import Foundation
import Testing

@Test
func noteEditingRequestUsesGPT55ResponsesAPI() async throws {
    let transport = CapturingNoteEditingTransport(responseData: noteEditingResponseData())
    let client = OpenAINoteEditingClient(
        configuration: OpenAIConfiguration(apiKey: "test-key"),
        baseURL: URL(string: "https://api.test")!,
        transport: transport
    )

    _ = try await client.updateNote(
        markdown: "# Notes\n\nOriginal",
        prompt: "Add the customer context.",
        context: "Customer: Acme"
    )

    let request = try #require(await transport.lastRequest)
    #expect(request.httpMethod == "POST")
    #expect(request.url?.path == "/v1/responses")
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-key")
    #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")

    let body = try #require(request.httpBody)
    let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
    #expect(json["model"] as? String == "gpt-5.5")

    let reasoning = try #require(json["reasoning"] as? [String: Any])
    #expect(reasoning["effort"] as? String == "high")

    let input = try #require(json["input"] as? [[String: String]])
    #expect(input[1]["content"]?.contains("Add the customer context") == true)
    #expect(input[1]["content"]?.contains("Customer: Acme") == true)
}

@Test
func noteEditingClientReturnsUpdatedMarkdown() async throws {
    let client = OpenAINoteEditingClient(
        configuration: OpenAIConfiguration(apiKey: "test-key"),
        baseURL: URL(string: "https://api.test")!,
        transport: CapturingNoteEditingTransport(responseData: noteEditingResponseData())
    )

    let markdown = try await client.updateNote(
        markdown: "# Notes",
        prompt: "Make it better.",
        context: ""
    )

    #expect(markdown == "# Updated Notes\n\n- Added customer context.")
}

@Test
func barnOwlChatRequestUsesResponsesAPIAndSuppliedSnippets() throws {
    let client = OpenAIBarnOwlChatClient(
        configuration: OpenAIConfiguration(apiKey: "test-key"),
        baseURL: URL(string: "https://api.test")!
    )

    let request = try client.makeRequest(
        question: "What did we decide?",
        snippets: [
            BarnOwlChatContextSnippet(
                id: "S1",
                title: "Acme Workshop",
                source: "transcript",
                text: "Dana: We decided to send the implementation plan."
            )
        ]
    )

    #expect(request.httpMethod == "POST")
    #expect(request.url?.path == "/v1/responses")
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-key")

    let body = try #require(request.httpBody)
    let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
    #expect(json["model"] as? String == "gpt-5.5")

    let input = try #require(json["input"] as? [[String: String]])
    #expect(input[0]["content"]?.contains("Cite evidence inline") == true)
    #expect(input[1]["content"]?.contains("What did we decide?") == true)
    #expect(input[1]["content"]?.contains("implementation plan") == true)
}

@Test
func barnOwlChatClientReturnsAnswerAndDetectedCitations() async throws {
    let client = OpenAIBarnOwlChatClient(
        configuration: OpenAIConfiguration(apiKey: "test-key"),
        baseURL: URL(string: "https://api.test")!,
        transport: CapturingNoteEditingTransport(responseData: chatResponseData())
    )

    let answer = try await client.answer(
        question: "What did we decide?",
        snippets: [
            BarnOwlChatContextSnippet(
                id: "S1",
                title: "Acme Workshop",
                source: "transcript",
                text: "Dana: We decided to send the implementation plan."
            )
        ]
    )

    #expect(answer.answer.contains("[S1]"))
    #expect(answer.citations == ["S1"])
}

private actor CapturingNoteEditingTransport: OpenAIHTTPTransport {
    private let responseData: Data
    private var requests: [URLRequest] = []

    init(responseData: Data) {
        self.responseData = responseData
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        )!
        return (responseData, response)
    }

    var lastRequest: URLRequest? {
        requests.last
    }
}

private func noteEditingResponseData() -> Data {
    Data(
        """
        {
          "output": [
            {
              "content": [
                {
                  "type": "output_text",
                  "text": "# Updated Notes\\n\\n- Added customer context."
                }
              ]
            }
          ]
        }
        """.utf8
    )
}

private func chatResponseData() -> Data {
    Data(
        """
        {
          "output": [
            {
              "content": [
                {
                  "type": "output_text",
                  "text": "You decided to send the implementation plan. [S1]"
                }
              ]
            }
          ]
        }
        """.utf8
    )
}

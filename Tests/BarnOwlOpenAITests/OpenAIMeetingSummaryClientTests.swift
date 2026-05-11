import BarnOwlCore
import BarnOwlOpenAI
import Foundation
import Testing

@Test
func meetingSummaryRequestUsesResponsesAPIWithStructuredOutput() async throws {
    let transport = CapturingResponsesTransport(responseData: summaryResponseData())
    let client = OpenAIMeetingSummaryClient(
        configuration: OpenAIConfiguration(apiKey: "test-key"),
        baseURL: URL(string: "https://api.test")!,
        transport: transport
    )

    _ = try await client.createSummary(
        session: makeSession(),
        segments: [
            TranscriptSegment(
                speakerLabel: "speaker_0",
                text: "We decided to ship the menu bar build.",
                startTime: 0,
                endTime: 3
            )
        ],
        context: ["Existing plan: prioritize V1 quality."]
    )

    let request = try #require(await transport.lastRequest)
    #expect(request.httpMethod == "POST")
    #expect(request.url?.path == "/v1/responses")
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-key")
    #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
    #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")

    let body = try #require(request.httpBody)
    let json = try #require(
        JSONSerialization.jsonObject(with: body) as? [String: Any]
    )
    #expect(json["model"] as? String == "gpt-5.5")

    let reasoning = try #require(json["reasoning"] as? [String: Any])
    #expect(reasoning["effort"] as? String == "high")

    let text = try #require(json["text"] as? [String: Any])
    #expect(text["verbosity"] as? String == "medium")
    let format = try #require(text["format"] as? [String: Any])
    #expect(format["type"] as? String == "json_schema")
    #expect(format["strict"] as? Bool == true)

    let input = try #require(json["input"] as? [[String: String]])
    #expect(input.count == 2)
    #expect(input[1]["content"]?.contains("We decided to ship") == true)
    #expect(input[1]["content"]?.contains("Existing plan") == true)
}

@Test
func meetingSummaryClientParsesStructuredOutputText() async throws {
    let client = OpenAIMeetingSummaryClient(
        configuration: OpenAIConfiguration(apiKey: "test-key"),
        baseURL: URL(string: "https://api.test")!,
        transport: CapturingResponsesTransport(responseData: summaryResponseData())
    )

    let summary = try await client.createSummary(
        session: makeSession(),
        segments: [
            TranscriptSegment(
                speakerLabel: "speaker_0",
                text: "Ship it.",
                startTime: 0,
                endTime: 1
            )
        ]
    )

    #expect(summary.overview == "The team agreed to ship the menu bar build.")
    #expect(summary.suggestedTitle == "Menu Bar Build Ship Review")
    #expect(summary.decisions == ["Ship the menu bar build."])
    #expect(summary.actionItems == ["Run a live recording smoke test."])
    #expect(summary.openQuestions == ["How should context write-back be routed?"])
}

@Test
func meetingSummaryClientReportsMalformedStructuredOutputText() async throws {
    let responseData = Data(
        """
        {
          "output": [
            {
              "content": [
                {
                  "type": "output_text",
                  "text": "{\\"overview\\":\\"Missing required arrays\\"}"
                }
              ]
            }
          ]
        }
        """.utf8
    )
    let client = OpenAIMeetingSummaryClient(
        configuration: OpenAIConfiguration(apiKey: "test-key"),
        baseURL: URL(string: "https://api.test")!,
        transport: CapturingResponsesTransport(responseData: responseData)
    )

    do {
        _ = try await client.createSummary(session: makeSession(), segments: [])
        Issue.record("Expected summary payload decoding to fail.")
    } catch OpenAIResponsesClientError.summaryPayloadDecodingFailed(let reason, let text) {
        #expect(reason.contains("keyNotFound"))
        #expect(text.contains("Missing required arrays"))
    }
}

private actor CapturingResponsesTransport: OpenAIHTTPTransport {
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

private func makeSession() -> RecordingSession {
    RecordingSession(
        title: "Barn Owl Review",
        startedAt: Date(timeIntervalSince1970: 0),
        endedAt: Date(timeIntervalSince1970: 60),
        audioSources: .defaultMeetingCapture
    )
}

private func summaryResponseData() -> Data {
    Data(
        """
        {
          "id": "resp_test",
          "object": "response",
          "status": "completed",
          "output": [
            {
              "type": "message",
              "role": "assistant",
              "content": [
                {
                  "type": "output_text",
                  "text": "{\\"suggestedTitle\\":\\"Menu Bar Build Ship Review\\",\\"overview\\":\\"The team agreed to ship the menu bar build.\\",\\"decisions\\":[\\"Ship the menu bar build.\\"],\\"actionItems\\":[\\"Run a live recording smoke test.\\"],\\"openQuestions\\":[\\"How should context write-back be routed?\\"]}"
                }
              ]
            }
          ]
        }
        """.utf8
    )
}

import BarnOwlOpenAI
import Foundation
import Testing

@Test
func keyValidationUsesModelsEndpointAndBearerToken() async throws {
    let transport = CapturingKeyValidationTransport(statusCode: 200)
    let client = OpenAIKeyValidationClient(
        apiKey: "test-key",
        baseURL: URL(string: "https://api.test")!,
        transport: transport
    )

    try await client.validate()

    let request = try #require(await transport.lastRequest)
    #expect(request.httpMethod == "GET")
    #expect(request.url?.path == "/v1/models")
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-key")
    #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
}

@Test
func keyValidationMapsCommonSetupFailures() async throws {
    await #expect(throws: OpenAIKeyValidationError.invalidAPIKey) {
        try await OpenAIKeyValidationClient(
            apiKey: "bad-key",
            baseURL: URL(string: "https://api.test")!,
            transport: CapturingKeyValidationTransport(statusCode: 401)
        ).validate()
    }

    await #expect(throws: OpenAIKeyValidationError.insufficientPermissions) {
        try await OpenAIKeyValidationClient(
            apiKey: "restricted-key",
            baseURL: URL(string: "https://api.test")!,
            transport: CapturingKeyValidationTransport(statusCode: 403)
        ).validate()
    }

    await #expect(throws: OpenAIKeyValidationError.quotaOrRateLimited) {
        try await OpenAIKeyValidationClient(
            apiKey: "quota-key",
            baseURL: URL(string: "https://api.test")!,
            transport: CapturingKeyValidationTransport(statusCode: 429)
        ).validate()
    }
}

private actor CapturingKeyValidationTransport: OpenAIHTTPTransport {
    private let statusCode: Int
    private var requests: [URLRequest] = []

    init(statusCode: Int) {
        self.statusCode = statusCode
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: nil
        )!
        return (Data(#"{"object":"list","data":[]}"#.utf8), response)
    }

    var lastRequest: URLRequest? {
        requests.last
    }
}

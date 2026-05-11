import Foundation

public enum OpenAIKeyValidationError: Error, Equatable, Sendable {
    case invalidAPIKey
    case insufficientPermissions
    case quotaOrRateLimited
    case unsuccessfulStatusCode(Int, Data)
}

public struct OpenAIKeyValidationClient: Sendable {
    private let apiKey: String
    private let baseURL: URL
    private let transport: any OpenAIHTTPTransport

    public init(
        apiKey: String,
        baseURL: URL = URL(string: "https://api.openai.com")!,
        transport: any OpenAIHTTPTransport = URLSession.shared
    ) {
        self.apiKey = apiKey
        self.baseURL = baseURL
        self.transport = transport
    }

    public func validate() async throws {
        var request = URLRequest(url: baseURL.appending(path: "v1/models"))
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await transport.data(for: request)
        switch response.statusCode {
        case 200..<300:
            return
        case 401:
            throw OpenAIKeyValidationError.invalidAPIKey
        case 403:
            throw OpenAIKeyValidationError.insufficientPermissions
        case 429:
            throw OpenAIKeyValidationError.quotaOrRateLimited
        default:
            throw OpenAIKeyValidationError.unsuccessfulStatusCode(response.statusCode, data)
        }
    }
}

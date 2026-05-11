import Foundation

public enum OpenAIConfigurationError: Error, Equatable, Sendable {
    case missingAPIKey
}

public struct OpenAIConfiguration: Equatable, Sendable {
    public var apiKey: String

    public init(apiKey: String) {
        self.apiKey = apiKey
    }

    public static func fromEnvironment(
        _ environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> OpenAIConfiguration {
        guard let apiKey = environment["OPENAI_API_KEY"], !apiKey.isEmpty else {
            throw OpenAIConfigurationError.missingAPIKey
        }
        return OpenAIConfiguration(apiKey: apiKey)
    }
}

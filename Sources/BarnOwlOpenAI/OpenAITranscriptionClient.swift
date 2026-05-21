import Foundation

public protocol AudioTranscriptionClient: Sendable {
    func transcribeAudioFile(at fileURL: URL) async throws -> AudioTranscriptionResponse
}

public struct AudioTranscriptionResponse: Decodable, Equatable, Sendable {
    public var text: String
    public var duration: TimeInterval
    public var segments: [AudioTranscriptionSegment]

    public init(
        text: String,
        duration: TimeInterval,
        segments: [AudioTranscriptionSegment]
    ) {
        self.text = text
        self.duration = duration
        self.segments = segments
    }

    fileprivate enum CodingKeys: String, CodingKey {
        case text
        case duration
        case segments
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        text = try container.decodeIfPresent(String.self, forKey: .text) ?? ""
        segments = try container.decodeIfPresent([AudioTranscriptionSegment].self, forKey: .segments) ?? []
        duration = try container.decodeIfPresent(TimeInterval.self, forKey: .duration)
            ?? segments.map(\.end).max()
            ?? 0
    }
}

public struct AudioTranscriptionSegment: Decodable, Equatable, Sendable {
    public var speaker: String
    public var start: TimeInterval
    public var end: TimeInterval
    public var text: String

    public init(
        speaker: String,
        start: TimeInterval,
        end: TimeInterval,
        text: String
    ) {
        self.speaker = speaker
        self.start = start
        self.end = end
        self.text = text
    }

    fileprivate enum CodingKeys: String, CodingKey {
        case speaker
        case speakerLabel
        case speaker_label
        case start
        case startTime
        case start_time
        case end
        case endTime
        case end_time
        case text
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        speaker = try container.decodeFirstString(
            forKeys: [.speaker, .speakerLabel, .speaker_label],
            defaultValue: "Speaker"
        )
        start = try container.decodeFirstTimeInterval(
            forKeys: [.start, .startTime, .start_time],
            defaultValue: 0
        )
        end = try container.decodeFirstTimeInterval(
            forKeys: [.end, .endTime, .end_time],
            defaultValue: start
        )
        text = try container.decodeIfPresent(String.self, forKey: .text) ?? ""
    }
}

public enum OpenAITranscriptionClientError: Error, Sendable {
    case invalidHTTPResponse
    case unsuccessfulStatusCode(Int, Data)
    case responseDecodingFailed(String, Data)
}

public protocol OpenAIHTTPTransport: Sendable {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

extension URLSession: OpenAIHTTPTransport {
    public func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await data(for: request, delegate: nil)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw OpenAITranscriptionClientError.invalidHTTPResponse
        }
        return (data, httpResponse)
    }
}

public struct OpenAITranscriptionClient: AudioTranscriptionClient {
    private let configuration: OpenAIConfiguration
    private let baseURL: URL
    private let model: String
    private let responseFormat: String
    private let chunkingStrategy: String?
    private let prompt: String?
    private let transport: any OpenAIHTTPTransport
    private let jsonDecoder: JSONDecoder

    public init(
        configuration: OpenAIConfiguration,
        baseURL: URL = URL(string: "https://api.openai.com")!,
        model: String = OpenAIModelCatalog.finalDiarization,
        responseFormat: String = "diarized_json",
        chunkingStrategy: String? = "auto",
        prompt: String? = nil,
        transport: any OpenAIHTTPTransport = URLSession.shared,
        jsonDecoder: JSONDecoder = JSONDecoder()
    ) {
        self.configuration = configuration
        self.baseURL = baseURL
        self.model = model
        self.responseFormat = responseFormat
        self.chunkingStrategy = chunkingStrategy
        let trimmedPrompt = prompt?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.prompt = trimmedPrompt?.isEmpty == false ? trimmedPrompt : nil
        self.transport = transport
        self.jsonDecoder = jsonDecoder
    }

    public func transcribeAudioFile(at fileURL: URL) async throws -> AudioTranscriptionResponse {
        let request = try makeTranscriptionRequest(audioFileURL: fileURL)
        let (data, response) = try await transport.data(for: request)

        guard (200..<300).contains(response.statusCode) else {
            throw OpenAITranscriptionClientError.unsuccessfulStatusCode(response.statusCode, data)
        }

        do {
            return try jsonDecoder.decode(AudioTranscriptionResponse.self, from: data)
        } catch {
            throw OpenAITranscriptionClientError.responseDecodingFailed(String(describing: error), data)
        }
    }

    private func makeTranscriptionRequest(audioFileURL: URL) throws -> URLRequest {
        let boundary = "BarnOwlBoundary-\(UUID().uuidString)"
        var multipart = MultipartFormData(boundary: boundary)
        multipart.appendField(name: "model", value: model)
        multipart.appendField(name: "response_format", value: responseFormat)
        if let chunkingStrategy {
            multipart.appendField(name: "chunking_strategy", value: chunkingStrategy)
        }
        if let prompt {
            multipart.appendField(name: "prompt", value: prompt)
        }
        try multipart.appendFile(
            name: "file",
            fileURL: audioFileURL,
            contentType: Self.contentType(for: audioFileURL)
        )
        multipart.finish()

        var request = URLRequest(url: baseURL.appending(path: "v1/audio/transcriptions"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(configuration.apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(
            "multipart/form-data; boundary=\(boundary)",
            forHTTPHeaderField: "Content-Type"
        )
        request.httpBody = multipart.body
        return request
    }

    private static func contentType(for fileURL: URL) -> String {
        switch fileURL.pathExtension.lowercased() {
        case "wav":
            "audio/wav"
        case "mp3", "mpeg", "mpga":
            "audio/mpeg"
        case "m4a", "mp4":
            "audio/mp4"
        case "flac":
            "audio/flac"
        case "ogg":
            "audio/ogg"
        case "webm":
            "audio/webm"
        default:
            "application/octet-stream"
        }
    }
}

private struct MultipartFormData {
    let boundary: String
    private(set) var body = Data()

    mutating func appendField(name: String, value: String) {
        appendBoundary()
        body.appendUTF8("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
        body.appendUTF8(value)
        body.appendUTF8("\r\n")
    }

    mutating func appendFile(
        name: String,
        fileURL: URL,
        contentType: String
    ) throws {
        appendBoundary()
        body.appendUTF8(
            "Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(fileURL.lastPathComponent)\"\r\n"
        )
        body.appendUTF8("Content-Type: \(contentType)\r\n\r\n")
        body.append(try Data(contentsOf: fileURL, options: .mappedIfSafe))
        body.appendUTF8("\r\n")
    }

    mutating func finish() {
        body.appendUTF8("--\(boundary)--\r\n")
    }

    private mutating func appendBoundary() {
        body.appendUTF8("--\(boundary)\r\n")
    }
}

private extension Data {
    mutating func appendUTF8(_ string: String) {
        append(contentsOf: string.utf8)
    }
}

private extension KeyedDecodingContainer where Key == AudioTranscriptionSegment.CodingKeys {
    func decodeFirstString(forKeys keys: [Key], defaultValue: String) throws -> String {
        for key in keys {
            if let value = try decodeIfPresent(String.self, forKey: key),
               value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
                return value
            }
        }

        return defaultValue
    }

    func decodeFirstTimeInterval(forKeys keys: [Key], defaultValue: TimeInterval) throws -> TimeInterval {
        for key in keys {
            if let value = try decodeIfPresent(TimeInterval.self, forKey: key) {
                return value
            }
        }

        return defaultValue
    }
}

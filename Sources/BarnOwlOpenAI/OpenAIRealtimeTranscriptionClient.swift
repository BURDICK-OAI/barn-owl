import Foundation

public enum OpenAIRealtimeTranscriptionEvent: Equatable, Sendable {
    case transcriptDelta(String)
    case transcriptCompleted(String)
    case error(String)
    case unhandled(String)
}

public enum OpenAIRealtimeTranscriptionClientError: Error, Equatable, Sendable {
    case unsupportedBinaryMessage
    case invalidEventPayload
    case emptyAudioBuffer
}

public protocol RealtimeWebSocketTransport: Sendable {
    func connect(request: URLRequest) async throws
    func sendString(_ string: String) async throws
    func receiveString() async throws -> String?
    func close() async
}

public struct OpenAIRealtimeTranscriptionClient: Sendable {
    public static let defaultSampleRate = 24_000
    public static let minimumCommitByteCount = 24_000 * MemoryLayout<Int16>.size / 10

    private let configuration: OpenAIConfiguration
    private let endpointURL: URL
    private let model: String
    private let sampleRate: Int
    private let transport: any RealtimeWebSocketTransport

    public init(
        configuration: OpenAIConfiguration,
        endpointURL: URL? = nil,
        model: String = OpenAIModelCatalog.liveTranscription,
        sampleRate: Int = Self.defaultSampleRate,
        transport: any RealtimeWebSocketTransport = URLSessionRealtimeWebSocketTransport()
    ) {
        self.configuration = configuration
        self.model = model
        self.endpointURL = endpointURL ?? URL(string: "wss://api.openai.com/v1/realtime/transcription_sessions?model=\(model)")!
        self.sampleRate = sampleRate
        self.transport = transport
    }

    public func connect() async throws {
        try await transport.connect(request: makeConnectionRequest())
        try await sendSessionUpdate()
    }

    public func sendSessionUpdate() async throws {
        try await transport.sendString(try makeSessionUpdateMessage())
    }

    public func appendPCM16Audio(_ audio: Data) async throws {
        try await transport.sendString(try makeInputAudioBufferAppendMessage(audio))
    }

    public func commitAudio() async throws {
        try await transport.sendString(try makeInputAudioBufferCommitMessage())
    }

    public func receiveEvent() async throws -> OpenAIRealtimeTranscriptionEvent? {
        guard let string = try await transport.receiveString() else {
            return nil
        }

        return try Self.parseEvent(from: Data(string.utf8))
    }

    public func close() async {
        await transport.close()
    }

    public func makeConnectionRequest() -> URLRequest {
        var request = URLRequest(url: endpointURL)
        request.setValue("Bearer \(configuration.apiKey)", forHTTPHeaderField: "Authorization")
        return request
    }

    public func makeSessionUpdateMessage() throws -> String {
        try Self.encodeJSON(
            RealtimeClientMessage.sessionUpdate(
                model: model,
                sampleRate: sampleRate
            )
        )
    }

    public func makeInputAudioBufferAppendMessage(_ audio: Data) throws -> String {
        guard !audio.isEmpty else {
            throw OpenAIRealtimeTranscriptionClientError.emptyAudioBuffer
        }
        return try Self.encodeJSON(RealtimeClientMessage.inputAudioBufferAppend(audio: audio.base64EncodedString()))
    }

    public func makeInputAudioBufferCommitMessage() throws -> String {
        try Self.encodeJSON(RealtimeClientMessage.inputAudioBufferCommit)
    }

    public static func parseEvent(from data: Data) throws -> OpenAIRealtimeTranscriptionEvent {
        let event = try JSONDecoder().decode(RealtimeServerEvent.self, from: data)

        switch event.type {
        case "error":
            return .error(event.error?.message ?? event.message ?? "Realtime transcription returned an error.")

        case "conversation.item.input_audio_transcription.delta",
             "input_audio_transcription.delta",
             "response.audio_transcript.delta":
            guard let delta = event.delta ?? event.transcript ?? event.text,
                  !delta.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return .unhandled(event.type)
            }
            return .transcriptDelta(delta)

        case "conversation.item.input_audio_transcription.completed",
             "conversation.item.input_audio_transcription.done",
             "input_audio_transcription.completed",
             "response.audio_transcript.done":
            guard let transcript = event.transcript ?? event.text ?? event.delta,
                  !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return .unhandled(event.type)
            }
            return .transcriptCompleted(transcript)

        default:
            return .unhandled(event.type)
        }
    }

    private static func encodeJSON<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(value)
        return String(decoding: data, as: UTF8.self)
    }
}

public actor URLSessionRealtimeWebSocketTransport: RealtimeWebSocketTransport {
    private let urlSession: URLSession
    private var task: URLSessionWebSocketTask?

    public init(urlSession: URLSession = .shared) {
        self.urlSession = urlSession
    }

    public func connect(request: URLRequest) async throws {
        let task = urlSession.webSocketTask(with: request)
        self.task = task
        task.resume()
    }

    public func sendString(_ string: String) async throws {
        guard let task else {
            throw URLError(.notConnectedToInternet)
        }

        try await task.send(.string(string))
    }

    public func receiveString() async throws -> String? {
        guard let task else {
            throw URLError(.notConnectedToInternet)
        }

        let message = try await task.receive()
        switch message {
        case let .string(string):
            return string
        case .data:
            throw OpenAIRealtimeTranscriptionClientError.unsupportedBinaryMessage
        @unknown default:
            throw OpenAIRealtimeTranscriptionClientError.unsupportedBinaryMessage
        }
    }

    public func close() async {
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
    }
}

private enum RealtimeClientMessage: Encodable {
    case sessionUpdate(model: String, sampleRate: Int)
    case inputAudioBufferAppend(audio: String)
    case inputAudioBufferCommit

    private enum CodingKeys: String, CodingKey {
        case type
        case session
        case audio
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        switch self {
        case let .sessionUpdate(model, sampleRate):
            try container.encode("session.update", forKey: .type)
            try container.encode(
                RealtimeTranscriptionSession(model: model, sampleRate: sampleRate),
                forKey: .session
            )

        case let .inputAudioBufferAppend(audio):
            try container.encode("input_audio_buffer.append", forKey: .type)
            try container.encode(audio, forKey: .audio)

        case .inputAudioBufferCommit:
            try container.encode("input_audio_buffer.commit", forKey: .type)
        }
    }
}

private struct RealtimeTranscriptionSession: Encodable {
    var type = "transcription"
    var audio: RealtimeTranscriptionAudio
    var include: [String] = ["item.input_audio_transcription.logprobs"]

    private enum CodingKeys: String, CodingKey {
        case type
        case audio
        case include
    }

    init(model: String, sampleRate: Int) {
        audio = RealtimeTranscriptionAudio(model: model, sampleRate: sampleRate)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(type, forKey: .type)
        try container.encode(audio, forKey: .audio)
        try container.encode(include, forKey: .include)
    }
}

private struct RealtimeTranscriptionAudio: Encodable {
    var input: RealtimeTranscriptionAudioInput

    init(model: String, sampleRate: Int) {
        input = RealtimeTranscriptionAudioInput(model: model, sampleRate: sampleRate)
    }
}

private struct RealtimeTranscriptionAudioInput: Encodable {
    var format: RealtimeTranscriptionAudioFormat
    var transcription: RealtimeInputAudioTranscription

    private enum CodingKeys: String, CodingKey {
        case format
        case transcription
        case turnDetection = "turn_detection"
    }

    init(model: String, sampleRate: Int) {
        format = RealtimeTranscriptionAudioFormat(rate: sampleRate)
        transcription = RealtimeInputAudioTranscription(model: model)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(format, forKey: .format)
        try container.encode(transcription, forKey: .transcription)
        try container.encodeNil(forKey: .turnDetection)
    }
}

private struct RealtimeTranscriptionAudioFormat: Encodable {
    var type = "audio/pcm"
    var rate: Int
}

private struct RealtimeInputAudioTranscription: Encodable {
    var model: String
    var language = "en"
}

private struct RealtimeServerEvent: Decodable {
    var type: String
    var delta: String?
    var transcript: String?
    var text: String?
    var message: String?
    var error: RealtimeServerError?
}

private struct RealtimeServerError: Decodable {
    var message: String?
    var type: String?
    var code: String?
}

import BarnOwlOpenAI
import Foundation
import Testing

@Test
func realtimeConnectionRequestUsesExpectedEndpointAndHeaders() {
    let client = OpenAIRealtimeTranscriptionClient(
        configuration: OpenAIConfiguration(apiKey: "test-key"),
        endpointURL: URL(string: "wss://api.test/v1/realtime/transcription_sessions?model=gpt-realtime-whisper")!,
        transport: FakeRealtimeWebSocketTransport()
    )

    let request = client.makeConnectionRequest()

    #expect(request.url?.absoluteString == "wss://api.test/v1/realtime/transcription_sessions?model=gpt-realtime-whisper")
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-key")
    #expect(request.value(forHTTPHeaderField: "OpenAI-Beta") == nil)
}

@Test
func realtimeConnectionRequestDefaultsToGAEndpointWithModel() {
    let client = OpenAIRealtimeTranscriptionClient(
        configuration: OpenAIConfiguration(apiKey: "test-key"),
        transport: FakeRealtimeWebSocketTransport()
    )

    let request = client.makeConnectionRequest()

    #expect(request.url?.absoluteString == "wss://api.openai.com/v1/realtime/transcription_sessions?model=\(OpenAIModelCatalog.liveTranscription)")
}

@Test
func sessionUpdateMessageConfiguresRealtimeTranscriptionPCM16() throws {
    let client = OpenAIRealtimeTranscriptionClient(
        configuration: OpenAIConfiguration(apiKey: "test-key"),
        transport: FakeRealtimeWebSocketTransport()
    )

    let payload = try jsonObject(from: client.makeSessionUpdateMessage())

    #expect(payload["type"] as? String == "session.update")

    let session = try #require(payload["session"] as? [String: Any])
    #expect(session["type"] as? String == "transcription")
    #expect(session["input_audio_format"] == nil)
    #expect(session["input_audio_transcription"] == nil)

    let audio = try #require(session["audio"] as? [String: Any])
    let input = try #require(audio["input"] as? [String: Any])
    let format = try #require(input["format"] as? [String: Any])
    #expect(format["type"] as? String == "audio/pcm")
    #expect(format["rate"] as? Int == OpenAIRealtimeTranscriptionClient.defaultSampleRate)

    let transcription = try #require(input["transcription"] as? [String: Any])
    #expect(transcription["model"] as? String == OpenAIModelCatalog.liveTranscription)
    #expect(transcription["language"] as? String == "en")

    #expect(input["turn_detection"] is NSNull)
    #expect(input["noise_reduction"] == nil)
    #expect(session["include"] as? [String] == ["item.input_audio_transcription.logprobs"])
}

@Test
func sessionUpdateMessagePreservesCustomModel() throws {
    let client = OpenAIRealtimeTranscriptionClient(
        configuration: OpenAIConfiguration(apiKey: "test-key"),
        model: "gpt-realtime-transcribe-test",
        transport: FakeRealtimeWebSocketTransport()
    )

    let payload = try jsonObject(from: client.makeSessionUpdateMessage())
    let session = try #require(payload["session"] as? [String: Any])
    let audio = try #require(session["audio"] as? [String: Any])
    let input = try #require(audio["input"] as? [String: Any])
    let transcription = try #require(input["transcription"] as? [String: Any])

    #expect(transcription["model"] as? String == "gpt-realtime-transcribe-test")
}

@Test
func appendMessageRejectsEmptyAudioPayloads() throws {
    let client = OpenAIRealtimeTranscriptionClient(
        configuration: OpenAIConfiguration(apiKey: "test-key"),
        transport: FakeRealtimeWebSocketTransport()
    )

    #expect(throws: OpenAIRealtimeTranscriptionClientError.emptyAudioBuffer) {
        _ = try client.makeInputAudioBufferAppendMessage(Data())
    }
}

@Test
func audioAppendAndCommitMessagesUseRealtimeInputAudioBufferTypes() throws {
    let client = OpenAIRealtimeTranscriptionClient(
        configuration: OpenAIConfiguration(apiKey: "test-key"),
        transport: FakeRealtimeWebSocketTransport()
    )

    let appendPayload = try jsonObject(from: client.makeInputAudioBufferAppendMessage(Data([0, 1, 2, 255])))
    #expect(appendPayload["type"] as? String == "input_audio_buffer.append")
    #expect(appendPayload["audio"] as? String == Data([0, 1, 2, 255]).base64EncodedString())

    let commitPayload = try jsonObject(from: client.makeInputAudioBufferCommitMessage())
    #expect(commitPayload["type"] as? String == "input_audio_buffer.commit")
    #expect(commitPayload["audio"] == nil)
}

@Test
func connectSendsSessionUpdateBeforeAudioMessages() async throws {
    let transport = FakeRealtimeWebSocketTransport()
    let client = OpenAIRealtimeTranscriptionClient(
        configuration: OpenAIConfiguration(apiKey: "test-key"),
        endpointURL: URL(string: "wss://api.test/v1/realtime/transcription_sessions?model=gpt-realtime-whisper")!,
        transport: transport
    )

    try await client.connect()
    try await client.appendPCM16Audio(Data([10, 20]))
    try await client.commitAudio()

    let request = try #require(await transport.connectedRequest)
    #expect(request.url?.host == "api.test")

    let sentTypes = try await transport.sentStrings.asyncMap { string in
        try jsonObject(from: string)["type"] as? String
    }
    #expect(sentTypes == [
        "session.update",
        "input_audio_buffer.append",
        "input_audio_buffer.commit"
    ])
}

@Test
func parsesRealtimeTranscriptDeltaAndCompletedEvents() throws {
    let delta = try OpenAIRealtimeTranscriptionClient.parseEvent(from: Data(
        """
        {
          "type": "conversation.item.input_audio_transcription.delta",
          "delta": "hel"
        }
        """.utf8
    ))
    #expect(delta == .transcriptDelta("hel"))

    let completed = try OpenAIRealtimeTranscriptionClient.parseEvent(from: Data(
        """
        {
          "type": "conversation.item.input_audio_transcription.completed",
          "transcript": "hello"
        }
        """.utf8
    ))
    #expect(completed == .transcriptCompleted("hello"))
}

@Test
func missingRealtimeTranscriptTextDoesNotStopReceiveLoop() throws {
    let missingDelta = try OpenAIRealtimeTranscriptionClient.parseEvent(from: Data(
        """
        {
          "type": "conversation.item.input_audio_transcription.delta",
          "item_id": "item_123"
        }
        """.utf8
    ))
    #expect(missingDelta == .unhandled("conversation.item.input_audio_transcription.delta"))

    let missingCompleted = try OpenAIRealtimeTranscriptionClient.parseEvent(from: Data(
        """
        {
          "type": "conversation.item.input_audio_transcription.completed",
          "item_id": "item_123"
        }
        """.utf8
    ))
    #expect(missingCompleted == .unhandled("conversation.item.input_audio_transcription.completed"))
}

@Test
func parsesRealtimeTranscriptTextFallbackFields() throws {
    let delta = try OpenAIRealtimeTranscriptionClient.parseEvent(from: Data(
        """
        {
          "type": "conversation.item.input_audio_transcription.delta",
          "text": "fallback delta"
        }
        """.utf8
    ))
    #expect(delta == .transcriptDelta("fallback delta"))

    let completed = try OpenAIRealtimeTranscriptionClient.parseEvent(from: Data(
        """
        {
          "type": "conversation.item.input_audio_transcription.completed",
          "text": "fallback completed"
        }
        """.utf8
    ))
    #expect(completed == .transcriptCompleted("fallback completed"))
}

@Test
func parsesRealtimeErrorEvents() throws {
    let event = try OpenAIRealtimeTranscriptionClient.parseEvent(from: Data(
        """
        {
          "type": "error",
          "error": {
            "message": "Unsupported model"
          }
        }
        """.utf8
    ))

    #expect(event == .error("Unsupported model"))
}

@Test
func receiveEventReadsFromTransportWithoutLiveNetwork() async throws {
    let transport = FakeRealtimeWebSocketTransport(receiveStrings: [
        """
        {"type":"conversation.item.input_audio_transcription.delta","delta":"a"}
        """,
        """
        {"type":"conversation.item.input_audio_transcription.completed","transcript":"ab"}
        """
    ])
    let client = OpenAIRealtimeTranscriptionClient(
        configuration: OpenAIConfiguration(apiKey: "test-key"),
        transport: transport
    )

    #expect(try await client.receiveEvent() == .transcriptDelta("a"))
    #expect(try await client.receiveEvent() == .transcriptCompleted("ab"))
    #expect(try await client.receiveEvent() == nil)
}

private actor FakeRealtimeWebSocketTransport: RealtimeWebSocketTransport {
    private(set) var connectedRequest: URLRequest?
    private(set) var sentStrings: [String] = []
    private var receiveStrings: [String]

    init(receiveStrings: [String] = []) {
        self.receiveStrings = receiveStrings
    }

    func connect(request: URLRequest) async throws {
        connectedRequest = request
    }

    func sendString(_ string: String) async throws {
        sentStrings.append(string)
    }

    func receiveString() async throws -> String? {
        guard receiveStrings.isEmpty == false else {
            return nil
        }

        return receiveStrings.removeFirst()
    }

    func close() async {}
}

private func jsonObject(from string: String) throws -> [String: Any] {
    let data = Data(string.utf8)
    let object = try JSONSerialization.jsonObject(with: data)
    return try #require(object as? [String: Any])
}

private extension Array {
    func asyncMap<T>(_ transform: (Element) async throws -> T) async rethrows -> [T] {
        var values: [T] = []
        values.reserveCapacity(count)

        for element in self {
            try await values.append(transform(element))
        }

        return values
    }
}

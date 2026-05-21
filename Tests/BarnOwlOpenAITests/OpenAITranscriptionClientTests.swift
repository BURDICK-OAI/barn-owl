import BarnOwlOpenAI
import Foundation
import Testing

@Test
func transcriptionRequestUsesExpectedEndpointHeadersAndMultipartFields() async throws {
    let audioFileURL = try makeTempAudioFile(data: Data("RAW-AUDIO-DATA".utf8))
    defer { try? FileManager.default.removeItem(at: audioFileURL.deletingLastPathComponent()) }

    let transport = CapturingTransport(responseData: minimalTranscriptionResponseData())
    let client = OpenAITranscriptionClient(
        configuration: OpenAIConfiguration(apiKey: "test-key"),
        baseURL: URL(string: "https://api.test")!,
        transport: transport
    )

    _ = try await client.transcribeAudioFile(at: audioFileURL)

    let request = try #require(await transport.lastRequest)
    #expect(request.httpMethod == "POST")
    #expect(request.url?.path == "/v1/audio/transcriptions")
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-key")
    #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")

    let contentType = try #require(request.value(forHTTPHeaderField: "Content-Type"))
    #expect(contentType.hasPrefix("multipart/form-data; boundary=BarnOwlBoundary-"))

    let body = try #require(request.httpBody)
    let bodyString = String(decoding: body, as: UTF8.self)
    let boundary = try #require(contentType.split(separator: "boundary=").last)

    #expect(bodyString.contains("--\(boundary)\r\n"))
    #expect(bodyString.contains(multipartField(name: "model", value: "gpt-4o-transcribe-diarize")))
    #expect(bodyString.contains(multipartField(name: "response_format", value: "diarized_json")))
    #expect(bodyString.contains(multipartField(name: "chunking_strategy", value: "auto")))
    #expect(!bodyString.contains("name=\"prompt\""))
    #expect(bodyString.contains(
        """
        Content-Disposition: form-data; name="file"; filename="sample.wav"\r
        Content-Type: audio/wav\r
        \r
        RAW-AUDIO-DATA
        """
    ))
    #expect(bodyString.hasSuffix("--\(boundary)--\r\n"))
    #expect(bodyString.components(separatedBy: "RAW-AUDIO-DATA").count == 2)
}

@Test
func transcriptionRequestCanUseTranscriptOnlyResponseWithoutDiarizationChunking() async throws {
    let audioFileURL = try makeTempAudioFile(data: Data("RAW-AUDIO-DATA".utf8))
    defer { try? FileManager.default.removeItem(at: audioFileURL.deletingLastPathComponent()) }

    let transport = CapturingTransport(responseData: minimalTranscriptionResponseData())
    let client = OpenAITranscriptionClient(
        configuration: OpenAIConfiguration(apiKey: "test-key"),
        baseURL: URL(string: "https://api.test")!,
        model: OpenAIModelCatalog.finalTranscription,
        responseFormat: "json",
        chunkingStrategy: nil,
        prompt: "Prefer the spelling Barn Owl.",
        transport: transport
    )

    _ = try await client.transcribeAudioFile(at: audioFileURL)

    let request = try #require(await transport.lastRequest)
    let body = try #require(request.httpBody)
    let bodyString = String(decoding: body, as: UTF8.self)

    #expect(bodyString.contains(multipartField(name: "model", value: "gpt-4o-transcribe")))
    #expect(bodyString.contains(multipartField(name: "response_format", value: "json")))
    #expect(bodyString.contains(multipartField(name: "prompt", value: "Prefer the spelling Barn Owl.")))
    #expect(!bodyString.contains("chunking_strategy"))
}

@Test
func transcriptionRequestOmitsBlankPrompt() async throws {
    let audioFileURL = try makeTempAudioFile(data: Data("RAW-AUDIO-DATA".utf8))
    defer { try? FileManager.default.removeItem(at: audioFileURL.deletingLastPathComponent()) }

    let transport = CapturingTransport(responseData: minimalTranscriptionResponseData())
    let client = OpenAITranscriptionClient(
        configuration: OpenAIConfiguration(apiKey: "test-key"),
        baseURL: URL(string: "https://api.test")!,
        model: OpenAIModelCatalog.finalTranscription,
        responseFormat: "json",
        chunkingStrategy: nil,
        prompt: " \n ",
        transport: transport
    )

    _ = try await client.transcribeAudioFile(at: audioFileURL)

    let request = try #require(await transport.lastRequest)
    let body = try #require(request.httpBody)
    let bodyString = String(decoding: body, as: UTF8.self)

    #expect(!bodyString.contains("name=\"prompt\""))
}

@Test
func transcriptionClientParsesDiarizedJSONResponse() async throws {
    let audioFileURL = try makeTempAudioFile(data: Data([0, 1, 2]))
    defer { try? FileManager.default.removeItem(at: audioFileURL.deletingLastPathComponent()) }

    let responseData = Data(
        """
        {
          "text": "Hello there. General Kenobi.",
          "duration": 3.5,
          "segments": [
            {
              "speaker": "speaker_0",
              "start": 0.0,
              "end": 1.2,
              "text": "Hello there."
            },
            {
              "speaker": "speaker_1",
              "start": 1.4,
              "end": 3.5,
              "text": "General Kenobi."
            }
          ]
        }
        """.utf8
    )
    let client = OpenAITranscriptionClient(
        configuration: OpenAIConfiguration(apiKey: "test-key"),
        baseURL: URL(string: "https://api.test")!,
        transport: CapturingTransport(responseData: responseData)
    )

    let response = try await client.transcribeAudioFile(at: audioFileURL)

    #expect(response.text == "Hello there. General Kenobi.")
    #expect(response.duration == 3.5)
    #expect(response.segments == [
        AudioTranscriptionSegment(
            speaker: "speaker_0",
            start: 0.0,
            end: 1.2,
            text: "Hello there."
        ),
        AudioTranscriptionSegment(
            speaker: "speaker_1",
            start: 1.4,
            end: 3.5,
            text: "General Kenobi."
        )
    ])
}

@Test
func transcriptionClientAcceptsDiarizedResponseWithoutTopLevelDuration() async throws {
    let audioFileURL = try makeTempAudioFile(data: Data([0, 1, 2]))
    defer { try? FileManager.default.removeItem(at: audioFileURL.deletingLastPathComponent()) }

    let responseData = Data(
        """
        {
          "text": "Hello",
          "segments": [{"speaker": "speaker_0", "text": "Hello", "start": 1.0, "end": 2.5}]
        }
        """.utf8
    )
    let client = OpenAITranscriptionClient(
        configuration: OpenAIConfiguration(apiKey: "test-key"),
        baseURL: URL(string: "https://api.test")!,
        transport: CapturingTransport(responseData: responseData)
    )

    let response = try await client.transcribeAudioFile(at: audioFileURL)

    #expect(response.text == "Hello")
    #expect(response.duration == 2.5)
    #expect(response.segments == [
        AudioTranscriptionSegment(speaker: "speaker_0", start: 1.0, end: 2.5, text: "Hello")
    ])
}

@Test
func transcriptionClientDefaultsMissingSegmentTimingInsteadOfDroppingTranscript() async throws {
    let audioFileURL = try makeTempAudioFile(data: Data([0, 1, 2]))
    defer { try? FileManager.default.removeItem(at: audioFileURL.deletingLastPathComponent()) }

    let responseData = Data(
        """
        {
          "text": "Hello",
          "segments": [{"type": "transcript.text.segment", "text": "Hello"}]
        }
        """.utf8
    )
    let client = OpenAITranscriptionClient(
        configuration: OpenAIConfiguration(apiKey: "test-key"),
        baseURL: URL(string: "https://api.test")!,
        transport: CapturingTransport(responseData: responseData)
    )

    let response = try await client.transcribeAudioFile(at: audioFileURL)

    #expect(response.duration == 0)
    #expect(response.segments == [
        AudioTranscriptionSegment(speaker: "Speaker", start: 0, end: 0, text: "Hello")
    ])
}

private actor CapturingTransport: OpenAIHTTPTransport {
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

private func makeTempAudioFile(data: Data) throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appending(path: "BarnOwlOpenAITests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

    let fileURL = directory.appending(path: "sample.wav")
    try data.write(to: fileURL)
    return fileURL
}

private func multipartField(name: String, value: String) -> String {
    "Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n"
}

private func minimalTranscriptionResponseData() -> Data {
    Data(
        """
        {
          "text": "",
          "duration": 0,
          "segments": []
        }
        """.utf8
    )
}

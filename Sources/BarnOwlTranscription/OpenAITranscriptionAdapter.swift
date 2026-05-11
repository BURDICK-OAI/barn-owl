import BarnOwlOpenAI
import Foundation

public struct OpenAIAudioFileTranscriptionClientAdapter: AudioFileTranscriptionClient {
    private let client: any AudioTranscriptionClient

    public init(client: any AudioTranscriptionClient) {
        self.client = client
    }

    public func transcribe(audioFile: RecordedAudioFile) async throws -> AudioFileTranscriptionResponse {
        let response = try await client.transcribeAudioFile(at: audioFile.url)
        return AudioFileTranscriptionResponse(
            segments: response.segments.map { segment in
                AudioFileTranscriptionSegment(
                    speakerLabel: segment.speaker,
                    text: segment.text,
                    startTime: segment.start,
                    endTime: segment.end
                )
            }
        )
    }
}

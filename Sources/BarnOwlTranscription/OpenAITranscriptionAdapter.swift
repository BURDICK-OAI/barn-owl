import BarnOwlOpenAI
import Foundation

public struct OpenAIAudioFileTranscriptionClientAdapter: AudioFileTranscriptionClient {
    private let client: any AudioTranscriptionClient

    public init(client: any AudioTranscriptionClient) {
        self.client = client
    }

    public func transcribe(audioFile: RecordedAudioFile) async throws -> AudioFileTranscriptionResponse {
        let response = try await client.transcribeAudioFile(at: audioFile.url)
        let mappedSegments = response.segments.map { segment in
            AudioFileTranscriptionSegment(
                speakerLabel: segment.speaker,
                text: segment.text,
                startTime: segment.start,
                endTime: segment.end
            )
        }
        if !mappedSegments.isEmpty {
            return AudioFileTranscriptionResponse(segments: mappedSegments)
        }

        let transcript = response.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !transcript.isEmpty else {
            return AudioFileTranscriptionResponse(segments: [])
        }

        let duration = max(response.duration, audioFile.duration ?? 0)
        return AudioFileTranscriptionResponse(
            segments: [
                AudioFileTranscriptionSegment(
                    text: transcript,
                    startTime: 0,
                    endTime: duration
                )
            ]
        )
    }
}

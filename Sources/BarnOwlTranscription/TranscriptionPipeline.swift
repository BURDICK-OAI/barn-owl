import BarnOwlCore
import Foundation

public protocol LiveTranscriber: Sendable {
    func start(session: RecordingSession) async throws
    func stop() async throws
}

public protocol FinalDiarizer: Sendable {
    func diarize(session: RecordingSession) async throws -> [TranscriptSegment]
}

public protocol TranscriptQualityReviewer: Sendable {
    func review(segments: [TranscriptSegment], context: [String]) async throws -> [TranscriptSegment]
}

public protocol MeetingSummaryGenerator: Sendable {
    func generateSummary(
        session: RecordingSession,
        segments: [TranscriptSegment],
        context: [String]
    ) async throws -> MeetingSummary
}

public struct RecordedAudioFile: Equatable, Sendable {
    public var url: URL
    public var trackLabel: String
    public var startTimeOffset: TimeInterval
    public var sequenceNumber: Int?
    public var trackID: String
    public var duration: TimeInterval?
    public var overlapDuration: TimeInterval?

    public init(
        url: URL,
        trackLabel: String,
        startTimeOffset: TimeInterval = 0,
        sequenceNumber: Int? = nil,
        trackID: String? = nil,
        duration: TimeInterval? = nil,
        overlapDuration: TimeInterval? = nil
    ) {
        self.url = url
        self.trackLabel = trackLabel
        self.startTimeOffset = startTimeOffset
        self.sequenceNumber = sequenceNumber
        self.trackID = trackID ?? trackLabel
        self.duration = duration
        self.overlapDuration = overlapDuration
    }
}

public struct AudioFileTranscriptionResponse: Codable, Equatable, Sendable {
    public var segments: [AudioFileTranscriptionSegment]

    public init(segments: [AudioFileTranscriptionSegment]) {
        self.segments = segments
    }
}

public struct AudioFileTranscriptionSegment: Codable, Equatable, Sendable {
    public var speakerLabel: String?
    public var text: String
    public var startTime: TimeInterval
    public var endTime: TimeInterval
    public var confidence: Double?

    public init(
        speakerLabel: String? = nil,
        text: String,
        startTime: TimeInterval,
        endTime: TimeInterval,
        confidence: Double? = nil
    ) {
        self.speakerLabel = speakerLabel
        self.text = text
        self.startTime = startTime
        self.endTime = endTime
        self.confidence = confidence
    }
}

public protocol AudioFileTranscriptionClient: Sendable {
    func transcribe(audioFile: RecordedAudioFile) async throws -> AudioFileTranscriptionResponse
}

public protocol RecordedAudioFileProviding: Sendable {
    func audioFiles(for session: RecordingSession) async throws -> [RecordedAudioFile]
}

public struct FinalTranscriptionResult: Equatable, Sendable {
    public var segments: [TranscriptSegment]
    public var summary: MeetingSummary

    public init(segments: [TranscriptSegment], summary: MeetingSummary) {
        self.segments = segments
        self.summary = summary
    }
}

public enum FinalTranscriptionPipelineError: Error, Equatable, Sendable {
    case missingAudioFileProvider
}

public struct NoOpTranscriptQualityReviewer: TranscriptQualityReviewer {
    public init() {}

    public func review(
        segments: [TranscriptSegment],
        context: [String]
    ) async throws -> [TranscriptSegment] {
        segments
    }
}

public struct TranscriptSanitizingQualityReviewer: TranscriptQualityReviewer {
    public init() {}

    public func review(
        segments: [TranscriptSegment],
        context: [String]
    ) async throws -> [TranscriptSegment] {
        _ = context

        var sanitized: [TranscriptSegment] = []
        for segment in segments {
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }

            let speakerLabel = segment.speakerLabel
                .trimmingCharacters(in: .whitespacesAndNewlines)
            sanitized.append(
                TranscriptSegment(
                    id: segment.id,
                    speakerLabel: speakerLabel.isEmpty ? "Unknown Speaker" : speakerLabel,
                    text: text,
                    startTime: max(0, segment.startTime),
                    endTime: max(segment.startTime, segment.endTime),
                    confidence: segment.confidence
                )
            )
        }

        return mergeAdjacentSegments(sanitized)
    }

    private func mergeAdjacentSegments(_ segments: [TranscriptSegment]) -> [TranscriptSegment] {
        let sortedSegments = segments.sorted {
            if $0.startTime != $1.startTime {
                return $0.startTime < $1.startTime
            }

            return $0.endTime < $1.endTime
        }

        var merged: [TranscriptSegment] = []
        for segment in sortedSegments {
            guard var previous = merged.popLast() else {
                merged.append(segment)
                continue
            }

            let gap = segment.startTime - previous.endTime
            if previous.speakerLabel == segment.speakerLabel, gap >= -0.5, gap <= 6 {
                previous.text = "\(previous.text) \(segment.text)"
                previous.endTime = max(previous.endTime, segment.endTime)
                previous.confidence = averagedConfidence(previous.confidence, segment.confidence)
                merged.append(previous)
            } else {
                merged.append(previous)
                merged.append(segment)
            }
        }

        return merged
    }

    private func averagedConfidence(_ lhs: Double?, _ rhs: Double?) -> Double? {
        switch (lhs, rhs) {
        case (.some(let lhs), .some(let rhs)):
            (lhs + rhs) / 2
        case (.some(let value), .none), (.none, .some(let value)):
            value
        case (.none, .none):
            nil
        }
    }
}

public struct PlaceholderMeetingSummaryGenerator: MeetingSummaryGenerator {
    public init() {}

    public func generateSummary(
        session: RecordingSession,
        segments: [TranscriptSegment],
        context: [String]
    ) async throws -> MeetingSummary {
        _ = context
        return MeetingSummary(
            overview: "Summary generation pending for \(session.title). Transcript contains \(segments.count) segment(s)."
        )
    }
}

public struct FinalTranscriptionPipeline: FinalDiarizer {
    private let transcriptionClient: any AudioFileTranscriptionClient
    private let audioFileProvider: (any RecordedAudioFileProviding)?
    private let qualityReviewer: any TranscriptQualityReviewer
    private let summaryGenerator: any MeetingSummaryGenerator
    private let overlapRepairClient: (any TranscriptOverlapRepairClient)?
    private let maxConcurrentTranscriptions: Int

    public init(
        transcriptionClient: any AudioFileTranscriptionClient,
        audioFileProvider: (any RecordedAudioFileProviding)? = nil,
        qualityReviewer: any TranscriptQualityReviewer = NoOpTranscriptQualityReviewer(),
        summaryGenerator: any MeetingSummaryGenerator = PlaceholderMeetingSummaryGenerator(),
        overlapRepairClient: (any TranscriptOverlapRepairClient)? = nil,
        maxConcurrentTranscriptions: Int = 4
    ) {
        self.transcriptionClient = transcriptionClient
        self.audioFileProvider = audioFileProvider
        self.qualityReviewer = qualityReviewer
        self.summaryGenerator = summaryGenerator
        self.overlapRepairClient = overlapRepairClient
        self.maxConcurrentTranscriptions = max(1, maxConcurrentTranscriptions)
    }

    public func run(
        session: RecordingSession,
        audioFiles: [RecordedAudioFile],
        context: [String] = []
    ) async throws -> FinalTranscriptionResult {
        let transcribedAudioFiles = try await ingest(audioFiles: audioFiles)
        let sourceLabeledAudioFiles = SourceAwareFinalTranscriptAssembler.labelSpeakers(
            transcribedAudioFiles
        )
        let stitchResult = await TranscriptOverlapStitcher(
            repairClient: overlapRepairClient
        ).stitch(transcriptions: sourceLabeledAudioFiles)
        let assembledSegments = SourceAwareFinalTranscriptAssembler.assemble(
            segments: stitchResult.segments
        )
        let reviewedSegments = try await qualityReviewer.review(
            segments: assembledSegments,
            context: context
        )

        let sortedSegments = Self.sortChronologically(reviewedSegments)
        let summary = try await summaryGenerator.generateSummary(
            session: session,
            segments: sortedSegments,
            context: context
        )

        return FinalTranscriptionResult(segments: sortedSegments, summary: summary)
    }

    public func diarize(session: RecordingSession) async throws -> [TranscriptSegment] {
        guard let audioFileProvider else {
            throw FinalTranscriptionPipelineError.missingAudioFileProvider
        }

        let audioFiles = try await audioFileProvider.audioFiles(for: session)
        return try await run(
            session: session,
            audioFiles: audioFiles
        ).segments
    }

    private func ingest(audioFiles: [RecordedAudioFile]) async throws -> [TranscribedAudioFile] {
        let transcriptionClient = transcriptionClient
        let maxConcurrentTranscriptions = min(maxConcurrentTranscriptions, audioFiles.count)

        return try await withThrowingTaskGroup(of: TranscribedAudioFile.self) { group in
            var nextAudioFileIndex = 0

            func enqueue(_ audioFile: RecordedAudioFile) {
                group.addTask {
                    let response = try await transcriptionClient.transcribe(audioFile: audioFile)
                    return TranscribedAudioFile(
                        audioFile: audioFile,
                        segments: Self.map(response: response, from: audioFile)
                    )
                }
            }

            while nextAudioFileIndex < maxConcurrentTranscriptions {
                enqueue(audioFiles[nextAudioFileIndex])
                nextAudioFileIndex += 1
            }

            var transcribedAudioFiles: [TranscribedAudioFile] = []
            for try await transcribedAudioFile in group {
                transcribedAudioFiles.append(transcribedAudioFile)
                if nextAudioFileIndex < audioFiles.count {
                    enqueue(audioFiles[nextAudioFileIndex])
                    nextAudioFileIndex += 1
                }
            }

            return transcribedAudioFiles.sorted {
                if $0.audioFile.startTimeOffset != $1.audioFile.startTimeOffset {
                    return $0.audioFile.startTimeOffset < $1.audioFile.startTimeOffset
                }

                if $0.audioFile.trackID != $1.audioFile.trackID {
                    return $0.audioFile.trackID < $1.audioFile.trackID
                }

                return ($0.audioFile.sequenceNumber ?? 0) < ($1.audioFile.sequenceNumber ?? 0)
            }
        }
    }

    private static func map(
        response: AudioFileTranscriptionResponse,
        from audioFile: RecordedAudioFile
    ) -> [TranscriptSegment] {
        response.segments.map { segment in
            TranscriptSegment(
                speakerLabel: Self.normalizedSpeakerLabel(
                    segment.speakerLabel,
                    fallback: audioFile.trackLabel
                ),
                text: segment.text.trimmingCharacters(in: .whitespacesAndNewlines),
                startTime: audioFile.startTimeOffset + segment.startTime,
                endTime: audioFile.startTimeOffset + segment.endTime,
                confidence: segment.confidence
            )
        }
    }

    private static func sortChronologically(
        _ segments: [TranscriptSegment]
    ) -> [TranscriptSegment] {
        segments.sorted {
            if $0.startTime != $1.startTime {
                return $0.startTime < $1.startTime
            }

            if $0.endTime != $1.endTime {
                return $0.endTime < $1.endTime
            }

            return $0.text < $1.text
        }
    }

    private static func normalizedSpeakerLabel(
        _ speakerLabel: String?,
        fallback: String
    ) -> String {
        let trimmedLabel = speakerLabel?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let trimmedLabel, !trimmedLabel.isEmpty else {
            return fallback
        }

        return trimmedLabel
    }

}

private enum SourceAwareFinalTranscriptAssembler {
    private enum SourceKind: Hashable {
        case room
        case call
        case other(String)

        init(audioFile: RecordedAudioFile) {
            let combined = "\(audioFile.trackID) \(audioFile.trackLabel)".lowercased()
            if combined.contains("system") || combined.contains("call") {
                self = .call
            } else if combined.contains("microphone") || combined.contains("mic") || combined.contains("room") {
                self = .room
            } else {
                let fallback = audioFile.trackLabel
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                self = .other(fallback.isEmpty ? "Source" : fallback)
            }
        }

        var labelPrefix: String {
            switch self {
            case .room:
                return "Room Speaker"
            case .call:
                return "Call Speaker"
            case .other(let label):
                return "\(label) Speaker"
            }
        }
    }

    static func labelSpeakers(
        _ transcriptions: [TranscribedAudioFile]
    ) -> [TranscribedAudioFile] {
        var labeler = SourceSpeakerLabeler()
        return transcriptions
            .sorted(by: sortTranscriptionsByAbsoluteTime)
            .map { transcription in
                let source = SourceKind(audioFile: transcription.audioFile)
                return TranscribedAudioFile(
                    audioFile: transcription.audioFile,
                    segments: transcription.segments.map { segment in
                        var copy = segment
                        copy.speakerLabel = labeler.label(
                            forRawSpeakerLabel: segment.speakerLabel,
                            source: source
                        )
                        return copy
                    }
                )
            }
    }

    static func assemble(segments: [TranscriptSegment]) -> [TranscriptSegment] {
        var kept: [TranscriptSegment] = []
        for segment in segments.sorted(by: sortSegments) {
            guard let duplicateIndex = kept.firstIndex(where: {
                isClearCrossSourceDuplicate($0, segment)
            }) else {
                kept.append(segment)
                continue
            }

            if duplicateScore(segment) > duplicateScore(kept[duplicateIndex]) {
                kept[duplicateIndex] = segment
            }
        }

        return kept.sorted(by: sortSegments)
    }

    private struct SourceSpeakerLabeler {
        private var labelsBySource: [SourceKind: [String: String]] = [:]
        private var nextLabelIndexBySource: [SourceKind: Int] = [:]

        mutating func label(
            forRawSpeakerLabel rawSpeakerLabel: String,
            source: SourceKind
        ) -> String {
            let rawKey = normalizedRawSpeakerKey(rawSpeakerLabel)
            if let existing = labelsBySource[source]?[rawKey] {
                return existing
            }

            let nextIndex = nextLabelIndexBySource[source, default: 0]
            let label = "\(source.labelPrefix) \(speakerSuffix(for: nextIndex))"
            labelsBySource[source, default: [:]][rawKey] = label
            nextLabelIndexBySource[source] = nextIndex + 1
            return label
        }

        private func normalizedRawSpeakerKey(_ label: String) -> String {
            let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "__unknown__" : trimmed.lowercased()
        }

        private func speakerSuffix(for index: Int) -> String {
            let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ")
            guard index < alphabet.count else {
                return String(index + 1)
            }
            return String(alphabet[index])
        }
    }

    private static func isClearCrossSourceDuplicate(
        _ lhs: TranscriptSegment,
        _ rhs: TranscriptSegment
    ) -> Bool {
        guard sourcePrefix(lhs.speakerLabel) != sourcePrefix(rhs.speakerLabel) else {
            return false
        }

        let lhsTokens = normalizedTokens(lhs.text)
        let rhsTokens = normalizedTokens(rhs.text)
        guard lhsTokens.count >= 4, rhsTokens.count >= 4 else {
            return false
        }

        let overlap = min(lhs.endTime, rhs.endTime) - max(lhs.startTime, rhs.startTime)
        let shortestDuration = max(0.1, min(lhs.endTime - lhs.startTime, rhs.endTime - rhs.startTime))
        guard overlap >= 0.5 || overlap / shortestDuration >= 0.5 else {
            return false
        }

        if lhsTokens == rhsTokens {
            return true
        }

        let lhsSet = Set(lhsTokens)
        let rhsSet = Set(rhsTokens)
        let intersection = lhsSet.intersection(rhsSet).count
        let union = lhsSet.union(rhsSet).count
        let jaccard = union == 0 ? 0 : Double(intersection) / Double(union)
        let containment = Double(intersection) / Double(min(lhsSet.count, rhsSet.count))
        return jaccard >= 0.92 && containment >= 0.9
    }

    private static func sourcePrefix(_ speakerLabel: String) -> String {
        if speakerLabel.hasPrefix("Room Speaker") {
            return "room"
        }
        if speakerLabel.hasPrefix("Call Speaker") {
            return "call"
        }
        return speakerLabel
    }

    private static func duplicateScore(_ segment: TranscriptSegment) -> Double {
        Double(normalizedTokens(segment.text).count)
            + (segment.confidence ?? 0)
            + max(0, segment.endTime - segment.startTime) * 0.05
    }

    private static func normalizedTokens(_ text: String) -> [String] {
        let allowed = CharacterSet.alphanumerics.union(.whitespacesAndNewlines)
        let scalars = text.lowercased().unicodeScalars.map { scalar in
            allowed.contains(scalar) ? Character(scalar) : " "
        }
        return String(scalars)
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
    }

    private static func sortTranscriptionsByAbsoluteTime(
        _ lhs: TranscribedAudioFile,
        _ rhs: TranscribedAudioFile
    ) -> Bool {
        if lhs.audioFile.startTimeOffset != rhs.audioFile.startTimeOffset {
            return lhs.audioFile.startTimeOffset < rhs.audioFile.startTimeOffset
        }
        if lhs.audioFile.trackID != rhs.audioFile.trackID {
            return lhs.audioFile.trackID < rhs.audioFile.trackID
        }
        return (lhs.audioFile.sequenceNumber ?? 0) < (rhs.audioFile.sequenceNumber ?? 0)
    }

    private static func sortSegments(_ lhs: TranscriptSegment, _ rhs: TranscriptSegment) -> Bool {
        if lhs.startTime != rhs.startTime {
            return lhs.startTime < rhs.startTime
        }
        if lhs.endTime != rhs.endTime {
            return lhs.endTime < rhs.endTime
        }
        if lhs.speakerLabel != rhs.speakerLabel {
            return lhs.speakerLabel < rhs.speakerLabel
        }
        return lhs.text < rhs.text
    }
}

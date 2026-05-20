import BarnOwlCore
import Foundation

private extension JSONEncoder {
    static var barnOwlVersionEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}

private extension JSONDecoder {
    static var barnOwlVersionDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }
}

public struct BarnOwlMeetingState: Equatable, Identifiable, Sendable {
    public var id: UUID { meeting.id }
    public var meeting: BarnOwlMeetingRecord
    public var recordingSessions: [BarnOwlRecordingSessionRecord]
    public var status: BarnOwlRecordingSessionStatus?
    public var transcriptSegments: [BarnOwlTranscriptSegmentRecord]
    public var realtimePreview: String
    public var realtimeStatus: String
    public var meetingFacts: MeetingFacts?
    public var speakerMappings: [String: String]
    public var calendarContext: BarnOwlMeetingCalendarContextRecord?
    public var externalContextItems: [BarnOwlExternalContextItemRecord]
    public var generatedNotes: String
    public var summary: MeetingSummary?
    public var actionItems: [String]
    public var decisions: [String]
    public var openQuestions: [String]
    public var jobs: [BarnOwlJobRecord]
    public var artifacts: [BarnOwlMeetingStateArtifact]
    public var version: Int
    public var updatedAt: Date

    public init(
        meeting: BarnOwlMeetingRecord,
        recordingSessions: [BarnOwlRecordingSessionRecord] = [],
        status: BarnOwlRecordingSessionStatus? = nil,
        transcriptSegments: [BarnOwlTranscriptSegmentRecord] = [],
        realtimePreview: String = "",
        realtimeStatus: String = "",
        meetingFacts: MeetingFacts? = nil,
        speakerMappings: [String: String] = [:],
        calendarContext: BarnOwlMeetingCalendarContextRecord? = nil,
        externalContextItems: [BarnOwlExternalContextItemRecord] = [],
        generatedNotes: String = "",
        summary: MeetingSummary? = nil,
        actionItems: [String] = [],
        decisions: [String] = [],
        openQuestions: [String] = [],
        jobs: [BarnOwlJobRecord] = [],
        artifacts: [BarnOwlMeetingStateArtifact] = [],
        version: Int = 1,
        updatedAt: Date? = nil
    ) {
        self.meeting = meeting
        self.recordingSessions = recordingSessions
        self.status = status
        self.transcriptSegments = transcriptSegments
        self.realtimePreview = realtimePreview
        self.realtimeStatus = realtimeStatus
        self.meetingFacts = meetingFacts
        self.speakerMappings = speakerMappings
        self.calendarContext = calendarContext
        self.externalContextItems = externalContextItems
        self.generatedNotes = generatedNotes
        self.summary = summary
        self.actionItems = actionItems
        self.decisions = decisions
        self.openQuestions = openQuestions
        self.jobs = jobs
        self.artifacts = artifacts
        self.version = version
        self.updatedAt = updatedAt ?? Self.maxUpdatedAt(
            meeting: meeting,
            sessions: recordingSessions,
            segments: transcriptSegments,
            context: externalContextItems,
            jobs: jobs,
            artifacts: artifacts
        )
    }

    public var title: String {
        MeetingFacts.clean(meetingFacts?.title) ?? meeting.title
    }

    public var startedAt: Date {
        meeting.startedAt ?? recordingSessions.first?.startedAt ?? meeting.createdAt
    }

    public var endedAt: Date? {
        meeting.endedAt ?? recordingSessions.compactMap(\.endedAt).max()
    }

    public var transcriptText: String {
        transcriptSegments
            .map { "\($0.speakerLabel ?? "Speaker"): \($0.text)" }
            .joined(separator: "\n")
    }

    public var searchableText: String {
        [
            title,
            summary?.overview,
            decisions.joined(separator: "\n"),
            actionItems.joined(separator: "\n"),
            openQuestions.joined(separator: "\n"),
            meetingFacts?.contextLines.joined(separator: "\n"),
            externalContextItems.map(\.body).joined(separator: "\n"),
            transcriptSegments.map(\.text).joined(separator: "\n"),
            generatedNotes
        ]
        .compactMap { $0 }
        .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        .joined(separator: "\n\n")
    }

    public func output(kind: String) -> BarnOwlMeetingStateArtifact? {
        artifacts.first { $0.kind == kind }
    }

    public var processingTimeline: [BarnOwlProcessingTimelineItem] {
        BarnOwlProcessingTimeline.derive(from: self)
    }

    private static func maxUpdatedAt(
        meeting: BarnOwlMeetingRecord,
        sessions: [BarnOwlRecordingSessionRecord],
        segments: [BarnOwlTranscriptSegmentRecord],
        context: [BarnOwlExternalContextItemRecord],
        jobs: [BarnOwlJobRecord],
        artifacts: [BarnOwlMeetingStateArtifact]
    ) -> Date {
        ([meeting.updatedAt]
            + sessions.map(\.updatedAt)
            + segments.map(\.updatedAt)
            + context.map(\.updatedAt)
            + jobs.map(\.updatedAt)
            + artifacts.map(\.updatedAt))
            .max() ?? meeting.updatedAt
    }
}

public enum BarnOwlMeetingCalendarMatchState: String, Codable, Equatable, Sendable {
    case candidate
    case accepted
    case rejected
}

public enum BarnOwlProcessingTimelineStep: String, Codable, CaseIterable, Equatable, Sendable {
    case recorded
    case transcribing
    case cleaningTranscript = "cleaning_transcript"
    case extractingFactsContext = "extracting_facts_context"
    case writingNotes = "writing_notes"
    case exportingMarkdown = "exporting_markdown"
    case indexingSearchable = "indexing_searchable"
    case complete

    public var label: String {
        switch self {
        case .recorded:
            "Recorded"
        case .transcribing:
            "Transcribing"
        case .cleaningTranscript:
            "Cleaning transcript"
        case .extractingFactsContext:
            "Extracting facts/context"
        case .writingNotes:
            "Writing notes"
        case .exportingMarkdown:
            "Exporting Markdown"
        case .indexingSearchable:
            "Indexing/searchable"
        case .complete:
            "Complete"
        }
    }
}

public enum BarnOwlProcessingTimelineStatus: String, Codable, Equatable, Sendable {
    case pending
    case running
    case complete
    case failed
}

public struct BarnOwlProcessingTimelineItem: Equatable, Identifiable, Sendable {
    public var id: String { step.rawValue }
    public var step: BarnOwlProcessingTimelineStep
    public var status: BarnOwlProcessingTimelineStatus
    public var startedAt: Date?
    public var completedAt: Date?
    public var errorMessage: String?

    public init(
        step: BarnOwlProcessingTimelineStep,
        status: BarnOwlProcessingTimelineStatus,
        startedAt: Date? = nil,
        completedAt: Date? = nil,
        errorMessage: String? = nil
    ) {
        self.step = step
        self.status = status
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.errorMessage = errorMessage
    }

    public var isTerminal: Bool {
        status == .complete || status == .failed
    }
}

public enum BarnOwlProcessingTimeline {
    public static func derive(from state: BarnOwlMeetingState) -> [BarnOwlProcessingTimelineItem] {
        let finalJob = state.jobs
            .filter { $0.type == "final_processing" }
            .sorted { $0.updatedAt > $1.updatedAt }
            .first
        let summaryRepairJob = state.jobs
            .filter { $0.type == "summary_processing" }
            .sorted { $0.updatedAt > $1.updatedAt }
            .first
        var jobStatus = finalJob?.status
        let jobStartedAt = finalJob?.startedAt ?? finalJob?.scheduledAt ?? finalJob?.createdAt
        let jobCompletedAt = finalJob?.completedAt
        let hasEndedRecording = state.recordingSessions.contains { $0.endedAt != nil || $0.status != .recording }
            || state.status == .processing
            || state.status == .completed
            || state.status == .failed
        let hasTranscript = !state.transcriptSegments.isEmpty
        let hasFacts = state.artifacts.contains { $0.kind == "meeting_facts" }
            || state.meetingFacts?.sources.isEmpty == false
        let hasNotes = !state.generatedNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasMarkdown = state.artifacts.contains { $0.kind == "markdown" } || hasNotes
        let finalOutputExists = hasNotes && hasMarkdown
        let transcriptStepComplete = hasTranscript || (state.status == .completed && finalOutputExists) || finalJob?.status == .succeeded
        let factsStepComplete = hasFacts || finalOutputExists
        let isSearchable = hasTranscript || hasNotes || state.meetingFacts?.contextLines.isEmpty == false
        if state.status == .completed && finalOutputExists {
            jobStatus = .succeeded
        }
        let runningStage = state.artifacts
            .filter { $0.kind == "processing_stage" }
            .sorted { $0.updatedAt > $1.updatedAt }
            .first
            .flatMap { step(forProcessingStage: $0.content) }

        var items: [BarnOwlProcessingTimelineItem] = [
            .init(
                step: .recorded,
                status: hasEndedRecording ? .complete : .pending,
                startedAt: state.recordingSessions.first?.startedAt ?? state.meeting.startedAt,
                completedAt: state.endedAt
            ),
            .init(step: .transcribing, status: transcriptStepComplete ? .complete : .pending),
            .init(step: .cleaningTranscript, status: transcriptStepComplete ? .complete : .pending),
            .init(step: .extractingFactsContext, status: factsStepComplete ? .complete : .pending),
            .init(step: .writingNotes, status: hasNotes ? .complete : .pending),
            .init(step: .exportingMarkdown, status: hasMarkdown ? .complete : .pending),
            .init(step: .indexingSearchable, status: isSearchable && hasMarkdown ? .complete : .pending),
            .init(step: .complete, status: transcriptStepComplete && factsStepComplete && hasNotes && hasMarkdown ? .complete : .pending)
        ]

        if jobStatus == .running,
           let runningStage,
           let stageIndex = items.firstIndex(where: { $0.step == runningStage }) {
            for index in items.indices where index < stageIndex && items[index].status == .pending {
                items[index].status = .complete
            }
            items[stageIndex].status = .running
            items[stageIndex].startedAt = jobStartedAt
        } else if let index = items.firstIndex(where: { $0.status == .pending }) {
            switch jobStatus {
            case .running:
                items[index].status = .running
                items[index].startedAt = jobStartedAt
            case .pending:
                items[index].status = .pending
                items[index].startedAt = finalJob?.scheduledAt
            case .failed:
                items[index].status = .failed
                items[index].startedAt = jobStartedAt
                items[index].completedAt = jobCompletedAt ?? finalJob?.updatedAt
                items[index].errorMessage = finalJob?.errorMessage
            case .succeeded:
                if items[index].step != .complete {
                    items[index].status = .failed
                    items[index].startedAt = jobStartedAt
                    items[index].completedAt = jobCompletedAt ?? finalJob?.updatedAt
                    items[index].errorMessage = "Processing job finished but this output is missing."
                }
            case .canceled:
                items[index].status = .failed
                items[index].startedAt = jobStartedAt
                items[index].completedAt = jobCompletedAt ?? finalJob?.updatedAt
                items[index].errorMessage = "Processing job was canceled."
            case .none:
                if state.status == .processing {
                    items[index].status = .running
                    items[index].startedAt = state.updatedAt
                }
            }
        }

        if items.dropLast().allSatisfy({ $0.status == .complete }) {
            items[items.count - 1].status = .complete
            items[items.count - 1].completedAt = jobCompletedAt ?? state.updatedAt
        }
        applySummaryRepairJob(summaryRepairJob, to: &items)
        return items
    }

    private static func applySummaryRepairJob(
        _ job: BarnOwlJobRecord?,
        to items: inout [BarnOwlProcessingTimelineItem]
    ) {
        guard let job,
              let writingNotesIndex = items.firstIndex(where: { $0.step == .writingNotes }),
              let completeIndex = items.firstIndex(where: { $0.step == .complete })
        else {
            return
        }

        let repairStatus: BarnOwlProcessingTimelineStatus?
        switch job.status {
        case .pending:
            repairStatus = .pending
        case .running:
            repairStatus = .running
        case .failed:
            repairStatus = .failed
        case .succeeded, .canceled:
            repairStatus = nil
        }
        guard let repairStatus else { return }

        items[writingNotesIndex].status = repairStatus
        items[writingNotesIndex].startedAt = job.startedAt ?? job.scheduledAt ?? job.createdAt
        items[writingNotesIndex].completedAt = repairStatus == .failed ? job.completedAt ?? job.updatedAt : nil
        items[writingNotesIndex].errorMessage = repairStatus == .failed ? job.errorMessage : nil

        for index in items.indices where index > writingNotesIndex && index <= completeIndex {
            items[index].status = .pending
            items[index].completedAt = nil
            items[index].errorMessage = nil
        }
    }

    private static func step(forProcessingStage value: String) -> BarnOwlProcessingTimelineStep? {
        switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "recorded":
            return .recorded
        case "transcribing":
            return .transcribing
        case "cleaning_transcript", "cleaning transcript":
            return .cleaningTranscript
        case "extracting_facts_context", "extracting facts/context", "extracting context":
            return .extractingFactsContext
        case "writing_notes", "writing notes":
            return .writingNotes
        case "exporting_markdown", "exporting markdown":
            return .exportingMarkdown
        case "indexing_searchable", "indexing/searchable", "indexing":
            return .indexingSearchable
        case "complete":
            return .complete
        default:
            return nil
        }
    }

    public static func shouldCollapse(_ items: [BarnOwlProcessingTimelineItem]) -> Bool {
        !items.isEmpty && items.allSatisfy { $0.status == .complete }
    }
}

public struct BarnOwlMeetingStateArtifact: Equatable, Identifiable, Sendable {
    public var id: UUID
    public var meetingID: UUID
    public var kind: String
    public var content: String
    public var contentType: String
    public var url: URL?
    public var createdAt: Date
    public var updatedAt: Date
    public var metadataJSON: String?

    public init(
        id: UUID = UUID(),
        meetingID: UUID,
        kind: String,
        content: String = "",
        contentType: String = "text/plain",
        url: URL? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        metadataJSON: String? = nil
    ) {
        self.id = id
        self.meetingID = meetingID
        self.kind = kind
        self.content = content
        self.contentType = contentType
        self.url = url
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.metadataJSON = metadataJSON
    }
}

public struct BarnOwlMeetingRecord: Equatable, Identifiable, Sendable {
    public var id: UUID
    public var externalID: String?
    public var title: String
    public var startedAt: Date?
    public var endedAt: Date?
    public var createdAt: Date
    public var updatedAt: Date
    public var metadataJSON: String?

    public init(
        id: UUID = UUID(),
        externalID: String? = nil,
        title: String,
        startedAt: Date? = nil,
        endedAt: Date? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        metadataJSON: String? = nil
    ) {
        self.id = id
        self.externalID = externalID
        self.title = title
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.metadataJSON = metadataJSON
    }
}

public enum BarnOwlMeetingExportEventType: String, Codable, CaseIterable, Equatable, Sendable {
    case created = "meeting.created"
    case processingCompleted = "meeting.processing_completed"
    case summaryRepaired = "meeting.summary_repaired"
    case updated = "meeting.updated"
    case deleted = "meeting.deleted"
    case purged = "meeting.purged"
}

public struct BarnOwlMeetingExportEventRecord: Equatable, Identifiable, Sendable {
    public var id: UUID
    public var type: BarnOwlMeetingExportEventType
    public var meetingID: UUID
    public var meetingStableKey: String
    public var occurredAt: Date
    public var schemaVersion: String
    public var envelopeJSON: String?
    public var tombstoneReason: String?

    public init(
        id: UUID = UUID(),
        type: BarnOwlMeetingExportEventType,
        meetingID: UUID,
        meetingStableKey: String,
        occurredAt: Date = Date(),
        schemaVersion: String = "1.0",
        envelopeJSON: String? = nil,
        tombstoneReason: String? = nil
    ) {
        self.id = id
        self.type = type
        self.meetingID = meetingID
        self.meetingStableKey = meetingStableKey
        self.occurredAt = occurredAt
        self.schemaVersion = schemaVersion
        self.envelopeJSON = envelopeJSON
        self.tombstoneReason = tombstoneReason
    }
}

public enum BarnOwlRecordingSessionStatus: String, Codable, Equatable, Sendable {
    case pending
    case recording
    case processing
    case completed
    case failed
    case canceled
}

public struct BarnOwlRecordingSessionRecord: Equatable, Identifiable, Sendable {
    public var id: UUID
    public var meetingID: UUID
    public var status: BarnOwlRecordingSessionStatus
    public var startedAt: Date
    public var endedAt: Date?
    public var audioSourcesJSON: String?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        meetingID: UUID,
        status: BarnOwlRecordingSessionStatus,
        startedAt: Date,
        endedAt: Date? = nil,
        audioSourcesJSON: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.meetingID = meetingID
        self.status = status
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.audioSourcesJSON = audioSourcesJSON
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct BarnOwlTranscriptSegmentRecord: Equatable, Identifiable, Sendable {
    public var id: UUID
    public var meetingID: UUID
    public var sessionID: UUID?
    public var variant: BarnOwlTranscriptVariant
    public var sequence: Int
    public var speakerLabel: String?
    public var text: String
    public var startTime: TimeInterval
    public var endTime: TimeInterval
    public var confidence: Double?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        meetingID: UUID,
        sessionID: UUID? = nil,
        variant: BarnOwlTranscriptVariant = .final,
        sequence: Int,
        speakerLabel: String? = nil,
        text: String,
        startTime: TimeInterval,
        endTime: TimeInterval,
        confidence: Double? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.meetingID = meetingID
        self.sessionID = sessionID
        self.variant = variant
        self.sequence = sequence
        self.speakerLabel = speakerLabel
        self.text = text
        self.startTime = startTime
        self.endTime = endTime
        self.confidence = confidence
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public enum BarnOwlTranscriptVariant: String, Codable, CaseIterable, Equatable, Sendable {
    case live
    case raw
    case reviewed
    case final
}

public enum BarnOwlJobStatus: String, Codable, Equatable, Sendable {
    case pending
    case running
    case succeeded
    case failed
    case canceled
}

public struct BarnOwlJobRecord: Equatable, Identifiable, Sendable {
    public var id: UUID
    public var meetingID: UUID?
    public var type: String
    public var status: BarnOwlJobStatus
    public var priority: Int
    public var attemptCount: Int
    public var payloadJSON: String?
    public var errorMessage: String?
    public var createdAt: Date
    public var updatedAt: Date
    public var scheduledAt: Date?
    public var startedAt: Date?
    public var completedAt: Date?

    public init(
        id: UUID = UUID(),
        meetingID: UUID? = nil,
        type: String,
        status: BarnOwlJobStatus = .pending,
        priority: Int = 0,
        attemptCount: Int = 0,
        payloadJSON: String? = nil,
        errorMessage: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        scheduledAt: Date? = nil,
        startedAt: Date? = nil,
        completedAt: Date? = nil
    ) {
        self.id = id
        self.meetingID = meetingID
        self.type = type
        self.status = status
        self.priority = priority
        self.attemptCount = attemptCount
        self.payloadJSON = payloadJSON
        self.errorMessage = errorMessage
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.scheduledAt = scheduledAt
        self.startedAt = startedAt
        self.completedAt = completedAt
    }
}

public struct BarnOwlJobChunkRecord: Equatable, Identifiable, Sendable {
    public var id: UUID
    public var jobID: UUID
    public var sequence: Int
    public var status: BarnOwlJobStatus
    public var payloadJSON: String?
    public var resultJSON: String?
    public var errorMessage: String?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        jobID: UUID,
        sequence: Int,
        status: BarnOwlJobStatus = .pending,
        payloadJSON: String? = nil,
        resultJSON: String? = nil,
        errorMessage: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.jobID = jobID
        self.sequence = sequence
        self.status = status
        self.payloadJSON = payloadJSON
        self.resultJSON = resultJSON
        self.errorMessage = errorMessage
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public enum BarnOwlRollingTranscriptionStatus: String, Codable, Equatable, Sendable {
    case pending
    case running
    case completed
    case failed
}

public struct BarnOwlRollingTranscriptionRecord: Equatable, Identifiable, Sendable {
    public var id: UUID
    public var sessionID: UUID
    public var trackID: String
    public var sequenceNumber: Int
    public var trackLabel: String
    public var audioFilePath: String?
    public var startTimeOffset: TimeInterval
    public var duration: TimeInterval?
    public var overlapDuration: TimeInterval?
    public var modelIdentifier: String?
    public var status: BarnOwlRollingTranscriptionStatus
    public var errorMessage: String?
    public var responseJSON: String?
    public var createdAt: Date
    public var updatedAt: Date
    public var completedAt: Date?

    public init(
        id: UUID = UUID(),
        sessionID: UUID,
        trackID: String,
        sequenceNumber: Int,
        trackLabel: String,
        audioFilePath: String? = nil,
        startTimeOffset: TimeInterval,
        duration: TimeInterval? = nil,
        overlapDuration: TimeInterval? = nil,
        modelIdentifier: String? = nil,
        status: BarnOwlRollingTranscriptionStatus,
        errorMessage: String? = nil,
        responseJSON: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        completedAt: Date? = nil
    ) {
        self.id = id
        self.sessionID = sessionID
        self.trackID = trackID
        self.sequenceNumber = sequenceNumber
        self.trackLabel = trackLabel
        self.audioFilePath = audioFilePath
        self.startTimeOffset = startTimeOffset
        self.duration = duration
        self.overlapDuration = overlapDuration
        self.modelIdentifier = modelIdentifier
        self.status = status
        self.errorMessage = errorMessage
        self.responseJSON = responseJSON
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.completedAt = completedAt
    }
}

public struct BarnOwlMeetingOutputRecord: Equatable, Identifiable, Sendable {
    public var id: UUID
    public var meetingID: UUID
    public var kind: String
    public var content: String
    public var contentType: String
    public var createdAt: Date
    public var updatedAt: Date
    public var metadataJSON: String?

    public init(
        id: UUID = UUID(),
        meetingID: UUID,
        kind: String,
        content: String,
        contentType: String = "text/markdown",
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        metadataJSON: String? = nil
    ) {
        self.id = id
        self.meetingID = meetingID
        self.kind = kind
        self.content = content
        self.contentType = contentType
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.metadataJSON = metadataJSON
    }
}

public struct BarnOwlMeetingCalendarContextRecord: Equatable, Identifiable, Sendable {
    public var id: UUID
    public var meetingID: UUID
    public var calendarEventID: String?
    public var title: String?
    public var startsAt: Date?
    public var endsAt: Date?
    public var attendeesJSON: String?
    public var rawContextJSON: String?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        meetingID: UUID,
        calendarEventID: String? = nil,
        title: String? = nil,
        startsAt: Date? = nil,
        endsAt: Date? = nil,
        attendeesJSON: String? = nil,
        rawContextJSON: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.meetingID = meetingID
        self.calendarEventID = calendarEventID
        self.title = title
        self.startsAt = startsAt
        self.endsAt = endsAt
        self.attendeesJSON = attendeesJSON
        self.rawContextJSON = rawContextJSON
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct BarnOwlMeetingCalendarMatchRecord: Equatable, Identifiable, Sendable {
    public var id: UUID
    public var meetingID: UUID
    public var calendarEventID: String?
    public var title: String?
    public var startsAt: Date?
    public var endsAt: Date?
    public var attendeesJSON: String?
    public var rawContextJSON: String?
    public var state: BarnOwlMeetingCalendarMatchState
    public var selectedAutomatically: Bool
    public var matchReason: String?
    public var confidence: Double?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        meetingID: UUID,
        calendarEventID: String? = nil,
        title: String? = nil,
        startsAt: Date? = nil,
        endsAt: Date? = nil,
        attendeesJSON: String? = nil,
        rawContextJSON: String? = nil,
        state: BarnOwlMeetingCalendarMatchState = .candidate,
        selectedAutomatically: Bool = false,
        matchReason: String? = nil,
        confidence: Double? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.meetingID = meetingID
        self.calendarEventID = calendarEventID
        self.title = title
        self.startsAt = startsAt
        self.endsAt = endsAt
        self.attendeesJSON = attendeesJSON
        self.rawContextJSON = rawContextJSON
        self.state = state
        self.selectedAutomatically = selectedAutomatically
        self.matchReason = matchReason
        self.confidence = confidence
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public enum BarnOwlExternalContextState: String, Codable, Equatable, Sendable {
    case pending
    case accepted
    case ignored
}

public struct BarnOwlExternalContextItemRecord: Equatable, Identifiable, Sendable {
    public var id: UUID
    public var meetingID: UUID?
    public var source: String
    public var body: String
    public var state: BarnOwlExternalContextState
    public var createdAt: Date
    public var updatedAt: Date
    public var usedInNoteGeneration: Bool
    public var metadataJSON: String?

    public init(
        id: UUID = UUID(),
        meetingID: UUID? = nil,
        source: String,
        body: String,
        state: BarnOwlExternalContextState = .pending,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        usedInNoteGeneration: Bool = false,
        metadataJSON: String? = nil
    ) {
        self.id = id
        self.meetingID = meetingID
        self.source = source
        self.body = body
        self.state = state
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.usedInNoteGeneration = usedInNoteGeneration
        self.metadataJSON = metadataJSON
    }
}

public struct BarnOwlEnrichmentSourceRecord: Equatable, Identifiable, Sendable {
    public var id: String
    public var ownerID: String
    public var displayName: String
    public var sourceType: String
    public var enabled: Bool
    public var scope: BarnOwlEnrichmentSourceScope
    public var authorityProfile: String
    public var bestUsedFor: [String]
    public var configJSON: String?
    public var authState: BarnOwlEnrichmentSourceAuthState
    public var healthStatus: BarnOwlEnrichmentSourceHealthStatus
    public var healthDetail: String?
    public var lastCheckedAt: Date?
    public var lastSuccessfulCheckAt: Date?
    public var lastFailedCheckAt: Date?
    public var connectorReference: String?
    public var privacyCopyPolicy: String?
    public var queryBudgetPolicy: String?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: String,
        ownerID: String,
        displayName: String,
        sourceType: String,
        enabled: Bool = true,
        scope: BarnOwlEnrichmentSourceScope,
        authorityProfile: String,
        bestUsedFor: [String] = [],
        configJSON: String? = nil,
        authState: BarnOwlEnrichmentSourceAuthState = .notRequired,
        healthStatus: BarnOwlEnrichmentSourceHealthStatus = .ready,
        healthDetail: String? = nil,
        lastCheckedAt: Date? = nil,
        lastSuccessfulCheckAt: Date? = nil,
        lastFailedCheckAt: Date? = nil,
        connectorReference: String? = nil,
        privacyCopyPolicy: String? = nil,
        queryBudgetPolicy: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.ownerID = ownerID
        self.displayName = displayName
        self.sourceType = sourceType
        self.enabled = enabled
        self.scope = scope
        self.authorityProfile = authorityProfile
        self.bestUsedFor = bestUsedFor
        self.configJSON = configJSON
        self.authState = authState
        self.healthStatus = healthStatus
        self.healthDetail = healthDetail
        self.lastCheckedAt = lastCheckedAt
        self.lastSuccessfulCheckAt = lastSuccessfulCheckAt
        self.lastFailedCheckAt = lastFailedCheckAt
        self.connectorReference = connectorReference
        self.privacyCopyPolicy = privacyCopyPolicy
        self.queryBudgetPolicy = queryBudgetPolicy
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public var descriptor: BarnOwlEnrichmentSourceDescriptor {
        BarnOwlEnrichmentSourceDescriptor(
            id: id,
            displayName: displayName,
            sourceType: sourceType,
            scope: scope,
            authorityProfile: authorityProfile,
            bestUsedFor: bestUsedFor,
            configJSON: configJSON
        )
    }

    public static func encodeBestUsedFor(_ values: [String]) -> String? {
        guard !values.isEmpty,
              let data = try? JSONEncoder().encode(values),
              let json = String(data: data, encoding: .utf8)
        else {
            return nil
        }
        return json
    }

    public static func decodeBestUsedFor(_ json: String?) -> [String] {
        guard let json,
              let data = json.data(using: .utf8),
              let values = try? JSONDecoder().decode([String].self, from: data)
        else {
            return []
        }
        return values
    }
}

public struct BarnOwlEnrichmentAuthorityProfileRecord: Equatable, Identifiable, Sendable {
    public var id: String
    public var ownerID: String
    public var displayName: String
    public var description: String
    public var strongestEntityKinds: [String]
    public var weakestEntityKinds: [String]
    public var defaultWeight: Double
    public var autoPersistPolicyJSON: String?
    public var builtIn: Bool
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: String,
        ownerID: String,
        displayName: String,
        description: String,
        strongestEntityKinds: [String] = [],
        weakestEntityKinds: [String] = [],
        defaultWeight: Double,
        autoPersistPolicyJSON: String? = nil,
        builtIn: Bool = false,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.ownerID = ownerID
        self.displayName = displayName
        self.description = description
        self.strongestEntityKinds = strongestEntityKinds
        self.weakestEntityKinds = weakestEntityKinds
        self.defaultWeight = defaultWeight
        self.autoPersistPolicyJSON = autoPersistPolicyJSON
        self.builtIn = builtIn
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public static func encodeEntityKinds(_ values: [String]) -> String? {
        guard !values.isEmpty,
              let data = try? JSONEncoder().encode(values),
              let json = String(data: data, encoding: .utf8)
        else {
            return nil
        }
        return json
    }

    public static func decodeEntityKinds(_ json: String?) -> [String] {
        guard let json,
              let data = json.data(using: .utf8),
              let values = try? JSONDecoder().decode([String].self, from: data)
        else {
            return []
        }
        return values
    }
}

public struct BarnOwlEnrichmentPolicyPackRecord: Equatable, Identifiable, Sendable {
    public var id: String
    public var ownerID: String
    public var displayName: String
    public var description: String
    public var minimumSupportingEvidenceCount: Int
    public var minimumIndependentSourceCountAfterConflictMemory: Int
    public var active: Bool
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: String,
        ownerID: String,
        displayName: String,
        description: String,
        minimumSupportingEvidenceCount: Int,
        minimumIndependentSourceCountAfterConflictMemory: Int,
        active: Bool,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.ownerID = ownerID
        self.displayName = displayName
        self.description = description
        self.minimumSupportingEvidenceCount = max(1, minimumSupportingEvidenceCount)
        self.minimumIndependentSourceCountAfterConflictMemory = max(1, minimumIndependentSourceCountAfterConflictMemory)
        self.active = active
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct BarnOwlEnrichmentJobRecord: Equatable, Identifiable, Sendable {
    public var id: UUID
    public var ownerID: String
    public var conceptKey: String
    public var requestedSources: [String]
    public var selectedSources: [String]
    public var status: BarnOwlEnrichmentJobStatus
    public var summary: String
    public var rationale: String?
    public var failureReason: String?
    public var createdAt: Date
    public var updatedAt: Date
    public var startedAt: Date
    public var finishedAt: Date?

    public init(
        id: UUID = UUID(),
        ownerID: String,
        conceptKey: String,
        requestedSources: [String] = [],
        selectedSources: [String] = [],
        status: BarnOwlEnrichmentJobStatus,
        summary: String,
        rationale: String? = nil,
        failureReason: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        startedAt: Date = Date(),
        finishedAt: Date? = nil
    ) {
        self.id = id
        self.ownerID = ownerID
        self.conceptKey = conceptKey
        self.requestedSources = requestedSources
        self.selectedSources = selectedSources
        self.status = status
        self.summary = summary
        self.rationale = rationale
        self.failureReason = failureReason
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.startedAt = startedAt
        self.finishedAt = finishedAt
    }

    public static func encodeSourceIDs(_ values: [String]) -> String? {
        guard !values.isEmpty,
              let data = try? JSONEncoder().encode(values),
              let json = String(data: data, encoding: .utf8)
        else {
            return nil
        }
        return json
    }

    public static func decodeSourceIDs(_ json: String?) -> [String] {
        guard let json,
              let data = json.data(using: .utf8),
              let values = try? JSONDecoder().decode([String].self, from: data)
        else {
            return []
        }
        return values
    }
}

public struct BarnOwlEnrichmentJobEvidenceRecord: Equatable, Identifiable, Sendable {
    public var id: UUID
    public var jobID: UUID
    public var sourceID: String
    public var evidenceJSON: String
    public var acceptedByAdjudicator: Bool
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        jobID: UUID,
        sourceID: String,
        evidenceJSON: String,
        acceptedByAdjudicator: Bool,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.jobID = jobID
        self.sourceID = sourceID
        self.evidenceJSON = evidenceJSON
        self.acceptedByAdjudicator = acceptedByAdjudicator
        self.createdAt = createdAt
    }

    public var evidence: BarnOwlEnrichmentEvidenceRecord? {
        Self.decodeEvidence(evidenceJSON)
    }

    public static func encodeEvidence(_ evidence: BarnOwlEnrichmentEvidenceRecord) -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        let data = try? encoder.encode(evidence)
        return data.map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }

    public static func decodeEvidence(_ json: String) -> BarnOwlEnrichmentEvidenceRecord? {
        guard let data = json.data(using: .utf8) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try? decoder.decode(BarnOwlEnrichmentEvidenceRecord.self, from: data)
    }
}

public struct BarnOwlEnrichmentConflictRecord: Equatable, Identifiable, Sendable {
    public var id: UUID
    public var jobID: UUID
    public var ownerID: String
    public var conceptKey: String
    public var summary: String
    public var conflictingSourceIDs: [String]
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        jobID: UUID,
        ownerID: String,
        conceptKey: String,
        summary: String,
        conflictingSourceIDs: [String],
        createdAt: Date = Date()
    ) {
        self.id = id
        self.jobID = jobID
        self.ownerID = ownerID
        self.conceptKey = conceptKey
        self.summary = summary
        self.conflictingSourceIDs = conflictingSourceIDs
        self.createdAt = createdAt
    }

    public static func encodeSourceIDs(_ values: [String]) -> String? {
        guard !values.isEmpty,
              let data = try? JSONEncoder().encode(values),
              let json = String(data: data, encoding: .utf8)
        else {
            return nil
        }
        return json
    }

    public static func decodeSourceIDs(_ json: String?) -> [String] {
        guard let json,
              let data = json.data(using: .utf8),
              let values = try? JSONDecoder().decode([String].self, from: data)
        else {
            return []
        }
        return values
    }
}

public struct BarnOwlEnrichmentSourceUsefulnessRecord: Equatable, Identifiable, Sendable {
    public var id: String { "\(ownerID):\(sourceID)" }
    public var ownerID: String
    public var sourceID: String
    public var attempts: Int
    public var evidenceItems: Int
    public var acceptedEvidenceItems: Int
    public var supportedJobs: Int
    public var heldJobs: Int
    public var conflictingJobs: Int
    public var failedJobs: Int
    public var lastOutcomeStatus: BarnOwlEnrichmentJobStatus?
    public var lastContributedAt: Date?
    public var updatedAt: Date

    public init(
        ownerID: String,
        sourceID: String,
        attempts: Int = 0,
        evidenceItems: Int = 0,
        acceptedEvidenceItems: Int = 0,
        supportedJobs: Int = 0,
        heldJobs: Int = 0,
        conflictingJobs: Int = 0,
        failedJobs: Int = 0,
        lastOutcomeStatus: BarnOwlEnrichmentJobStatus? = nil,
        lastContributedAt: Date? = nil,
        updatedAt: Date = Date()
    ) {
        self.ownerID = ownerID
        self.sourceID = sourceID
        self.attempts = max(0, attempts)
        self.evidenceItems = max(0, evidenceItems)
        self.acceptedEvidenceItems = max(0, acceptedEvidenceItems)
        self.supportedJobs = max(0, supportedJobs)
        self.heldJobs = max(0, heldJobs)
        self.conflictingJobs = max(0, conflictingJobs)
        self.failedJobs = max(0, failedJobs)
        self.lastOutcomeStatus = lastOutcomeStatus
        self.lastContributedAt = lastContributedAt
        self.updatedAt = updatedAt
    }
}

public struct BarnOwlKnowledgeApplicationRecord: Equatable, Identifiable, Sendable {
    public var id: UUID
    public var ownerID: String
    public var entityID: UUID
    public var meetingID: UUID
    public var surface: String
    public var usedInSummaryGeneration: Bool
    public var usedInNoteGeneration: Bool
    public var influencedMeetingFacts: Bool
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        ownerID: String,
        entityID: UUID,
        meetingID: UUID,
        surface: String,
        usedInSummaryGeneration: Bool = false,
        usedInNoteGeneration: Bool = false,
        influencedMeetingFacts: Bool,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.ownerID = ownerID
        self.entityID = entityID
        self.meetingID = meetingID
        self.surface = surface
        self.usedInSummaryGeneration = usedInSummaryGeneration
        self.usedInNoteGeneration = usedInNoteGeneration
        self.influencedMeetingFacts = influencedMeetingFacts
        self.createdAt = createdAt
    }
}

public enum BarnOwlMeetingVersionActor: String, Codable, Equatable, Sendable {
    case user
    case ai
    case job
    case codexAPI = "codex_api"
    case system
}

public enum BarnOwlMeetingVersionChangeType: String, Codable, Equatable, Sendable {
    case noteRewrite = "note_rewrite"
    case promptUpdate = "prompt_update"
    case contextUpdate = "context_update"
    case titleRename = "title_rename"
    case participantCorrection = "participant_correction"
    case meetingFactsUpdate = "meeting_facts_update"
    case summaryRegenerated = "summary_regenerated"
    case actionsRegenerated = "actions_regenerated"
    case restore
}

public struct BarnOwlMeetingVersionSnapshot: Codable, Equatable, Sendable {
    public var title: String
    public var generatedNotes: String
    public var meetingFacts: MeetingFacts?
    public var summary: MeetingSummary?
    public var actionItems: [String]
    public var decisions: [String]
    public var openQuestions: [String]
    public var updatedAt: Date

    public init(
        title: String,
        generatedNotes: String,
        meetingFacts: MeetingFacts? = nil,
        summary: MeetingSummary? = nil,
        actionItems: [String] = [],
        decisions: [String] = [],
        openQuestions: [String] = [],
        updatedAt: Date = Date()
    ) {
        self.title = title
        self.generatedNotes = generatedNotes
        self.meetingFacts = meetingFacts
        self.summary = summary
        self.actionItems = actionItems
        self.decisions = decisions
        self.openQuestions = openQuestions
        self.updatedAt = updatedAt
    }

    public init(state: BarnOwlMeetingState) {
        self.init(
            title: state.title,
            generatedNotes: state.generatedNotes,
            meetingFacts: state.meetingFacts,
            summary: state.summary,
            actionItems: state.actionItems,
            decisions: state.decisions,
            openQuestions: state.openQuestions,
            updatedAt: state.updatedAt
        )
    }
}

public struct BarnOwlMeetingVersionRecord: Equatable, Identifiable, Sendable {
    public var id: UUID
    public var meetingID: UUID
    public var createdAt: Date
    public var actor: BarnOwlMeetingVersionActor
    public var changeType: BarnOwlMeetingVersionChangeType
    public var summary: String
    public var beforeJSON: String?
    public var afterJSON: String?

    public init(
        id: UUID = UUID(),
        meetingID: UUID,
        createdAt: Date = Date(),
        actor: BarnOwlMeetingVersionActor,
        changeType: BarnOwlMeetingVersionChangeType,
        summary: String,
        beforeJSON: String? = nil,
        afterJSON: String? = nil
    ) {
        self.id = id
        self.meetingID = meetingID
        self.createdAt = createdAt
        self.actor = actor
        self.changeType = changeType
        self.summary = summary
        self.beforeJSON = beforeJSON
        self.afterJSON = afterJSON
    }

    public var beforeSnapshot: BarnOwlMeetingVersionSnapshot? {
        Self.decodeSnapshot(beforeJSON)
    }

    public var afterSnapshot: BarnOwlMeetingVersionSnapshot? {
        Self.decodeSnapshot(afterJSON)
    }

    public static func encodeSnapshot(_ snapshot: BarnOwlMeetingVersionSnapshot?) -> String? {
        guard let snapshot,
              let data = try? JSONEncoder.barnOwlVersionEncoder.encode(snapshot)
        else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    public static func decodeSnapshot(_ json: String?) -> BarnOwlMeetingVersionSnapshot? {
        guard let json,
              let data = json.data(using: .utf8)
        else { return nil }
        return try? JSONDecoder.barnOwlVersionDecoder.decode(BarnOwlMeetingVersionSnapshot.self, from: data)
    }
}

public struct BarnOwlDatabaseSearchQuery: Equatable, Sendable {
    public var text: String
    public var meetingType: String?
    public var participant: String?
    public var status: BarnOwlRecordingSessionStatus?
    public var startedAfter: Date?
    public var startedBefore: Date?
    public var limit: Int

    public init(
        text: String,
        meetingType: String? = nil,
        participant: String? = nil,
        status: BarnOwlRecordingSessionStatus? = nil,
        startedAfter: Date? = nil,
        startedBefore: Date? = nil,
        limit: Int = 50
    ) {
        self.text = text
        self.meetingType = meetingType
        self.participant = participant
        self.status = status
        self.startedAfter = startedAfter
        self.startedBefore = startedBefore
        self.limit = limit
    }
}

public struct BarnOwlDatabaseSearchResult: Equatable, Identifiable, Sendable {
    public var id: UUID { meeting.id }
    public var meeting: BarnOwlMeetingRecord
    public var snippet: String
    public var matchedFields: [String]
    public var score: Double
    public var meetingType: String?
    public var status: BarnOwlRecordingSessionStatus?

    public init(
        meeting: BarnOwlMeetingRecord,
        snippet: String,
        matchedFields: [String],
        score: Double,
        meetingType: String? = nil,
        status: BarnOwlRecordingSessionStatus? = nil
    ) {
        self.meeting = meeting
        self.snippet = snippet
        self.matchedFields = matchedFields
        self.score = score
        self.meetingType = meetingType
        self.status = status
    }
}

public enum BarnOwlKnowledgeEntityLifecycleStatus: String, Codable, CaseIterable, Equatable, Sendable {
    case active
    case suppressed
}

public struct BarnOwlKnowledgeEntityRecord: Equatable, Identifiable, Sendable {
    public var id: UUID
    public var ownerID: String
    public var kind: String
    public var canonicalName: String
    public var normalizedCanonicalName: String
    public var summary: String?
    public var confidence: Double
    public var sourceJobID: UUID?
    public var lifecycleStatus: BarnOwlKnowledgeEntityLifecycleStatus
    public var lifecycleReason: String?
    public var lifecycleUpdatedAt: Date?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        ownerID: String,
        kind: String,
        canonicalName: String,
        normalizedCanonicalName: String? = nil,
        summary: String? = nil,
        confidence: Double,
        sourceJobID: UUID? = nil,
        lifecycleStatus: BarnOwlKnowledgeEntityLifecycleStatus = .active,
        lifecycleReason: String? = nil,
        lifecycleUpdatedAt: Date? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.ownerID = ownerID
        self.kind = kind
        self.canonicalName = canonicalName
        self.normalizedCanonicalName = normalizedCanonicalName ?? Self.normalized(canonicalName)
        self.summary = summary
        self.confidence = min(max(confidence, 0), 1)
        self.sourceJobID = sourceJobID
        self.lifecycleStatus = lifecycleStatus
        self.lifecycleReason = lifecycleReason
        self.lifecycleUpdatedAt = lifecycleUpdatedAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public static func normalized(_ value: String) -> String {
        value
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }
}

public struct BarnOwlKnowledgeAliasRecord: Equatable, Identifiable, Sendable {
    public var id: UUID
    public var ownerID: String
    public var entityID: UUID
    public var alias: String
    public var normalizedAlias: String
    public var confidence: Double
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        ownerID: String,
        entityID: UUID,
        alias: String,
        normalizedAlias: String? = nil,
        confidence: Double,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.ownerID = ownerID
        self.entityID = entityID
        self.alias = alias
        self.normalizedAlias = normalizedAlias ?? BarnOwlKnowledgeEntityRecord.normalized(alias)
        self.confidence = min(max(confidence, 0), 1)
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct BarnOwlKnowledgeMeetingLinkRecord: Equatable, Identifiable, Sendable {
    public var id: UUID
    public var ownerID: String
    public var entityID: UUID
    public var meetingID: UUID
    public var evidenceJobID: UUID?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        ownerID: String,
        entityID: UUID,
        meetingID: UUID,
        evidenceJobID: UUID? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.ownerID = ownerID
        self.entityID = entityID
        self.meetingID = meetingID
        self.evidenceJobID = evidenceJobID
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

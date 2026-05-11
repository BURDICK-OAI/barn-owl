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
        return items
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

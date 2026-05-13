import Foundation

public enum BarnOwlControlCommandName: String, Codable, CaseIterable, Sendable {
    case getStatus = "get_status"
    case startRecording = "start_recording"
    case stopRecording = "stop_recording"
    case addContext = "add_context"
    case appendContext = "append_context"
    case setContext = "set_context"
    case setTitle = "set_title"
    case renameMeeting = "rename_meeting"
    case setMeetingType = "set_meeting_type"
    case updateNotes = "update_notes"
    case askNotes = "ask_notes"
    case openCurrentMeeting = "open_current_meeting"
    case openLatestMeeting = "open_latest_meeting"
    case getCurrent = "get_current"
    case current = "current"
    case meetingsRecent = "meetings_recent"
    case meetingsSearch = "meetings_search"
    case meetingGet = "meeting_get"
    case meetingTranscript = "meeting_transcript"
    case meetingNotes = "meeting_notes"
    case meetingSummary = "meeting_summary"
    case meetingContext = "meeting_context"
    case meetingActions = "meeting_actions"
    case meetingDelete = "meeting_delete"
    case meetingPurgeTempAudio = "meeting_purge_temp_audio"
    case wait
    case jobsList = "jobs_list"
    case jobsRetry = "jobs_retry"
    case jobsDismiss = "jobs_dismiss"
    case summariesRetry = "summaries_retry"
    case contextList = "context_list"
    case contextAccept = "context_accept"
    case contextIgnore = "context_ignore"
    case contextDelete = "context_delete"
    case chat = "chat"
    case diagnosticsExport = "diagnostics_export"
    case permissionsCheck = "permissions_check"
    case permissionsTest = "permissions_test"
}

public struct BarnOwlControlCommand: Codable, Equatable, Sendable {
    public var command: BarnOwlControlCommandName
    public var sessionID: UUID?
    public var title: String?
    public var meetingType: String?
    public var context: String?
    public var prompt: String?
    public var source: String?
    public var meetingID: UUID?
    public var query: String?
    public var limit: Int?
    public var format: String?
    public var humanReadable: Bool?
    public var until: String?
    public var latest: Bool?
    public var jobID: UUID?
    public var contextItemID: UUID?
    public var confirmed: Bool?
    public var outputPath: String?
    public var all: Bool?
    public var capturesSystemAudio: Bool?

    public init(
        command: BarnOwlControlCommandName,
        sessionID: UUID? = nil,
        title: String? = nil,
        meetingType: String? = nil,
        context: String? = nil,
        prompt: String? = nil,
        source: String? = nil,
        meetingID: UUID? = nil,
        query: String? = nil,
        limit: Int? = nil,
        format: String? = nil,
        humanReadable: Bool? = nil,
        until: String? = nil,
        latest: Bool? = nil,
        jobID: UUID? = nil,
        contextItemID: UUID? = nil,
        confirmed: Bool? = nil,
        outputPath: String? = nil,
        all: Bool? = nil,
        capturesSystemAudio: Bool? = nil
    ) {
        self.command = command
        self.sessionID = sessionID
        self.title = title
        self.meetingType = meetingType
        self.context = context
        self.prompt = prompt
        self.source = source
        self.meetingID = meetingID
        self.query = query
        self.limit = limit
        self.format = format
        self.humanReadable = humanReadable
        self.until = until
        self.latest = latest
        self.jobID = jobID
        self.contextItemID = contextItemID
        self.confirmed = confirmed
        self.outputPath = outputPath
        self.all = all
        self.capturesSystemAudio = capturesSystemAudio
    }
}

public enum BarnOwlQuickCommandName: String, Codable, CaseIterable, Sendable {
    case startRecording = "start_recording"
    case stopRecording = "stop_recording"
    case addContext = "add_context"
    case renameMeeting = "rename_meeting"
    case askNotes = "ask_notes"
    case openLatestMeeting = "open_latest_meeting"
}

public struct BarnOwlQuickCommand: Codable, Equatable, Sendable {
    public var name: BarnOwlQuickCommandName
    public var meetingID: UUID?
    public var title: String?
    public var meetingType: String?
    public var context: String?
    public var question: String?
    public var source: String?
    public var capturesSystemAudio: Bool?

    public init(
        name: BarnOwlQuickCommandName,
        meetingID: UUID? = nil,
        title: String? = nil,
        meetingType: String? = nil,
        context: String? = nil,
        question: String? = nil,
        source: String? = nil,
        capturesSystemAudio: Bool? = nil
    ) {
        self.name = name
        self.meetingID = meetingID
        self.title = title
        self.meetingType = meetingType
        self.context = context
        self.question = question
        self.source = source
        self.capturesSystemAudio = capturesSystemAudio
    }
}

public struct BarnOwlQuickCommandResult: Codable, Equatable, Sendable {
    public var ok: Bool
    public var message: String
    public var activeMeetingID: UUID?
    public var jobState: String?
    public var errorCode: String?

    public init(
        ok: Bool,
        message: String,
        activeMeetingID: UUID? = nil,
        jobState: String? = nil,
        errorCode: String? = nil
    ) {
        self.ok = ok
        self.message = message
        self.activeMeetingID = activeMeetingID
        self.jobState = jobState
        self.errorCode = errorCode
    }
}

public extension BarnOwlControlCommand {
    var quickCommand: BarnOwlQuickCommand? {
        switch command {
        case .startRecording:
            BarnOwlQuickCommand(
                name: .startRecording,
                meetingID: meetingID ?? sessionID,
                title: title,
                meetingType: meetingType,
                context: context,
                source: source,
                capturesSystemAudio: capturesSystemAudio
            )
        case .stopRecording:
            BarnOwlQuickCommand(name: .stopRecording, meetingID: meetingID ?? sessionID)
        case .addContext, .appendContext:
            BarnOwlQuickCommand(
                name: .addContext,
                meetingID: meetingID ?? sessionID,
                context: context,
                source: source
            )
        case .setTitle, .renameMeeting:
            BarnOwlQuickCommand(
                name: .renameMeeting,
                meetingID: meetingID ?? sessionID,
                title: title,
                source: source
            )
        case .askNotes:
            BarnOwlQuickCommand(
                name: .askNotes,
                meetingID: meetingID ?? sessionID,
                question: query ?? prompt
            )
        case .openLatestMeeting:
            BarnOwlQuickCommand(name: .openLatestMeeting)
        default:
            nil
        }
    }
}

public struct BarnOwlControlMeeting: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var title: String
    public var startedAt: Date?
    public var endedAt: Date?
    public var overview: String?
    public var meetingType: String?
    public var status: String?

    public init(
        id: UUID,
        title: String,
        startedAt: Date? = nil,
        endedAt: Date? = nil,
        overview: String? = nil,
        meetingType: String? = nil,
        status: String? = nil
    ) {
        self.id = id
        self.title = title
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.overview = overview
        self.meetingType = meetingType
        self.status = status
    }
}

public struct BarnOwlControlContextItem: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var meetingID: UUID?
    public var source: String
    public var body: String
    public var bodyPreview: String?
    public var state: String
    public var createdAt: Date
    public var usedInNoteGeneration: Bool

    public init(
        id: UUID,
        meetingID: UUID?,
        source: String,
        body: String,
        bodyPreview: String? = nil,
        state: String,
        createdAt: Date,
        usedInNoteGeneration: Bool = false
    ) {
        self.id = id
        self.meetingID = meetingID
        self.source = source
        self.body = body
        self.bodyPreview = bodyPreview ?? Self.preview(for: body)
        self.state = state
        self.createdAt = createdAt
        self.usedInNoteGeneration = usedInNoteGeneration
    }

    private static func preview(for body: String) -> String {
        let collapsed = body
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        guard collapsed.count > 160 else { return collapsed }
        return String(collapsed.prefix(157)) + "..."
    }
}

public struct BarnOwlControlJob: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var meetingID: UUID?
    public var type: String
    public var status: String
    public var attemptCount: Int
    public var errorMessage: String?
    public var updatedAt: Date

    public init(
        id: UUID,
        meetingID: UUID?,
        type: String,
        status: String,
        attemptCount: Int,
        errorMessage: String? = nil,
        updatedAt: Date
    ) {
        self.id = id
        self.meetingID = meetingID
        self.type = type
        self.status = status
        self.attemptCount = attemptCount
        self.errorMessage = errorMessage
        self.updatedAt = updatedAt
    }
}

public struct BarnOwlControlCitation: Codable, Equatable, Sendable {
    public var id: String
    public var title: String?

    public init(id: String, title: String? = nil) {
        self.id = id
        self.title = title
    }
}

public struct BarnOwlControlResponse: Codable, Equatable, Sendable {
    public var ok: Bool
    public var message: String
    public var status: String?
    public var appStatus: String?
    public var bridgeStatus: String?
    public var recordingStatus: String?
    public var sessionID: UUID?
    public var meetingID: UUID?
    public var activeMeetingID: UUID?
    public var title: String?
    public var meetingType: String?
    public var realtimeStatus: String?
    public var finalTranscriptionStatus: String?
    public var captureStatus: String?
    public var liveTranscriptPreview: String?
    public var contextItemID: UUID?
    public var current: BarnOwlControlMeeting?
    public var meeting: BarnOwlControlMeeting?
    public var meetings: [BarnOwlControlMeeting]?
    public var jobs: [BarnOwlControlJob]?
    public var transcript: String?
    public var notes: String?
    public var summary: String?
    public var contextItems: [BarnOwlControlContextItem]?
    public var actions: [String]?
    public var decisions: [String]?
    public var participants: [String]?
    public var answer: String?
    public var citations: [BarnOwlControlCitation]?
    public var jobState: String?
    public var readinessState: String?
    public var setupReady: Bool?
    public var apiKeyConfigured: Bool?
    public var apiKeyVerified: Bool?
    public var notesReady: Bool?
    public var transcriptReady: Bool?
    public var summaryReady: Bool?
    public var markdownPath: String?
    public var diagnosticsPath: String?
    public var lastError: String?
    public var nextCommand: String?
    public var feedbackSuggested: Bool?
    public var feedbackCommand: String?
    public var feedbackPostCommand: String?
    public var feedbackReason: String?
    public var errorCode: String?
    public var error: String?

    public init(
        ok: Bool,
        message: String,
        status: String? = nil,
        appStatus: String? = nil,
        bridgeStatus: String? = nil,
        recordingStatus: String? = nil,
        sessionID: UUID? = nil,
        meetingID: UUID? = nil,
        activeMeetingID: UUID? = nil,
        title: String? = nil,
        meetingType: String? = nil,
        realtimeStatus: String? = nil,
        finalTranscriptionStatus: String? = nil,
        captureStatus: String? = nil,
        liveTranscriptPreview: String? = nil,
        contextItemID: UUID? = nil,
        current: BarnOwlControlMeeting? = nil,
        meeting: BarnOwlControlMeeting? = nil,
        meetings: [BarnOwlControlMeeting]? = nil,
        jobs: [BarnOwlControlJob]? = nil,
        transcript: String? = nil,
        notes: String? = nil,
        summary: String? = nil,
        contextItems: [BarnOwlControlContextItem]? = nil,
        actions: [String]? = nil,
        decisions: [String]? = nil,
        participants: [String]? = nil,
        answer: String? = nil,
        citations: [BarnOwlControlCitation]? = nil,
        jobState: String? = nil,
        readinessState: String? = nil,
        setupReady: Bool? = nil,
        apiKeyConfigured: Bool? = nil,
        apiKeyVerified: Bool? = nil,
        notesReady: Bool? = nil,
        transcriptReady: Bool? = nil,
        summaryReady: Bool? = nil,
        markdownPath: String? = nil,
        diagnosticsPath: String? = nil,
        lastError: String? = nil,
        nextCommand: String? = nil,
        feedbackSuggested: Bool? = nil,
        feedbackCommand: String? = nil,
        feedbackPostCommand: String? = nil,
        feedbackReason: String? = nil,
        errorCode: String? = nil,
        error: String? = nil
    ) {
        self.ok = ok
        self.message = message
        self.status = status
        self.appStatus = appStatus
        self.bridgeStatus = bridgeStatus
        self.recordingStatus = recordingStatus
        self.sessionID = sessionID
        self.meetingID = meetingID
        self.activeMeetingID = activeMeetingID
        self.title = title
        self.meetingType = meetingType
        self.realtimeStatus = realtimeStatus
        self.finalTranscriptionStatus = finalTranscriptionStatus
        self.captureStatus = captureStatus
        self.liveTranscriptPreview = liveTranscriptPreview
        self.contextItemID = contextItemID
        self.current = current
        self.meeting = meeting
        self.meetings = meetings
        self.jobs = jobs
        self.transcript = transcript
        self.notes = notes
        self.summary = summary
        self.contextItems = contextItems
        self.actions = actions
        self.decisions = decisions
        self.participants = participants
        self.answer = answer
        self.citations = citations
        self.jobState = jobState
        self.readinessState = readinessState
        self.setupReady = setupReady
        self.apiKeyConfigured = apiKeyConfigured
        self.apiKeyVerified = apiKeyVerified
        self.notesReady = notesReady
        self.transcriptReady = transcriptReady
        self.summaryReady = summaryReady
        self.markdownPath = markdownPath
        self.diagnosticsPath = diagnosticsPath
        self.lastError = lastError
        self.nextCommand = nextCommand
        self.feedbackSuggested = feedbackSuggested
        self.feedbackCommand = feedbackCommand
        self.feedbackPostCommand = feedbackPostCommand
        self.feedbackReason = feedbackReason
        self.errorCode = errorCode
        self.error = error
    }
}

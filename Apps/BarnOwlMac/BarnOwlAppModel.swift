import AppKit
import BarnOwlAudio
import BarnOwlContext
import BarnOwlCore
import BarnOwlNotes
import BarnOwlOpenAI
import BarnOwlPersistence
import BarnOwlTranscription
import Combine
import Foundation

struct BarnOwlRecentSession: Identifiable, Equatable {
    var id: UUID
    var title: String
    var startedAt: Date
    var endedAt: Date?
    var markdownURL: URL
    var overview: String
    var processingTimeline: [BarnOwlProcessingTimelineItem] = []

    var isProcessing: Bool {
        processingTimeline.contains { $0.status == .pending || $0.status == .running || $0.status == .failed }
            && !BarnOwlProcessingTimeline.shouldCollapse(processingTimeline)
    }

    var processingSummary: String {
        if BarnOwlProcessingTimeline.shouldCollapse(processingTimeline) {
            return "Processed"
        }
        if let failed = processingTimeline.first(where: { $0.status == .failed }) {
            return "\(failed.step.label) failed"
        }
        if let running = processingTimeline.first(where: { $0.status == .running }) {
            return "\(running.step.label) in background"
        }
        if let pending = processingTimeline.first(where: { $0.status == .pending }) {
            return "\(pending.step.label) pending"
        }
        return "Processed"
    }
}

struct BarnOwlDisplayedNote: Identifiable, Equatable {
    var id: UUID
    var title: String
    var startedAt: Date
    var markdown: String
    var meetingFacts: MeetingFacts?
}

struct BarnOwlNoteSearchResult: Identifiable, Equatable {
    var id: UUID
    var title: String
    var startedAt: Date
    var snippet: String
    var meetingType: String?
    var status: BarnOwlRecordingSessionStatus?
}

struct BarnOwlJobSummary: Identifiable, Equatable {
    var id: UUID
    var meetingID: UUID?
    var title: String
    var type: String
    var status: BarnOwlJobStatus
    var attemptCount: Int
    var errorMessage: String?
    var updatedAt: Date

    var displayText: String {
        let readableType = type
            .replacingOccurrences(of: "_", with: " ")
            .capitalized
        switch status {
        case .pending:
            return "\(readableType) queued"
        case .running:
            return "\(readableType) running"
        case .succeeded:
            return "\(readableType) complete"
        case .failed:
            return "\(readableType) failed"
        case .canceled:
            return "\(readableType) canceled"
        }
    }
}

struct BarnOwlRecoveryAttentionItem: Identifiable, Equatable {
    var id: UUID
    var meetingID: UUID?
    var jobID: UUID?
    var title: String
    var message: String
    var details: String?
    var updatedAt: Date

    var canRetry: Bool {
        jobID != nil
    }
}

struct BarnOwlMeetingHistoryItem: Identifiable, Equatable {
    var id: UUID
    var meetingID: UUID
    var createdAt: Date
    var actor: BarnOwlMeetingVersionActor
    var changeType: BarnOwlMeetingVersionChangeType
    var summary: String
    var beforeTitle: String?
    var afterTitle: String?
    var beforeMarkdown: String
    var afterMarkdown: String

    init(record: BarnOwlMeetingVersionRecord) {
        self.id = record.id
        self.meetingID = record.meetingID
        self.createdAt = record.createdAt
        self.actor = record.actor
        self.changeType = record.changeType
        self.summary = record.summary
        self.beforeTitle = record.beforeSnapshot?.title
        self.afterTitle = record.afterSnapshot?.title
        self.beforeMarkdown = record.beforeSnapshot?.generatedNotes ?? ""
        self.afterMarkdown = record.afterSnapshot?.generatedNotes ?? ""
    }

    var displayActor: String {
        switch actor {
        case .user: "User"
        case .ai: "AI"
        case .job: "Job"
        case .codexAPI: "Codex/API"
        case .system: "System"
        }
    }

    var displayChangeType: String {
        changeType.rawValue
            .replacingOccurrences(of: "_", with: " ")
            .capitalized
    }
}

struct BarnOwlChatMessage: Identifiable, Equatable {
    enum Role: String, Equatable {
        case user = "You"
        case assistant = "Barn Owl"
    }

    var id = UUID()
    var role: Role
    var text: String
    var timestamp = Date()
}

enum BarnOwlActionUX {
    static func notePromptDisabledReason(
        hasOpenNote: Bool,
        isUpdating: Bool,
        prompt: String
    ) -> String? {
        if !hasOpenNote {
            return "Open a note before updating."
        }
        if isUpdating {
            return "Updating notes..."
        }
        if prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Type a prompt to update this note."
        }
        return nil
    }

    static func chatDisabledReason(isSending: Bool, draft: String) -> String? {
        if isSending {
            return "Barn Owl is thinking..."
        }
        if draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Type a question to chat."
        }
        return nil
    }

    static func contextDisabledReason(
        hasTarget: Bool,
        isUpdating: Bool,
        context: String
    ) -> String? {
        if !hasTarget {
            return "Open or record a meeting before adding context."
        }
        if isUpdating {
            return "Reading context..."
        }
        if context.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Add context before attaching it."
        }
        return nil
    }

    static func jobStatusLabel(_ status: BarnOwlJobStatus) -> String {
        switch status {
        case .pending:
            return "queued"
        case .running:
            return "running"
        case .failed:
            return "failed"
        case .succeeded:
            return "complete"
        case .canceled:
            return "canceled"
        }
    }
}

struct BarnOwlActivityItem: Identifiable, Equatable {
    var id = UUID()
    var timestamp: Date
    var level: DiagnosticsLogLevel
    var message: String
    var details: String?
}

struct BarnOwlContextInboxItem: Identifiable, Equatable {
    var id: UUID
    var meetingID: UUID?
    var source: String
    var body: String
    var state: BarnOwlExternalContextState
    var createdAt: Date

    var stateLabel: String {
        switch state {
        case .pending:
            return "Pending"
        case .accepted:
            return "Accepted"
        case .ignored:
            return "Ignored"
        }
    }
}

struct BarnOwlPostRecordingContextReview: Identifiable, Equatable {
    var id: UUID { session.id }
    var session: RecordingSession
    var transcriptPreview: String
    var facts: MeetingFacts
    var freeformContextDraft: String
    var prompts: [ContextReviewPrompt]

    var suggestedSummary: String {
        facts.displaySummary
    }

    var contextLines: [String] {
        var lines = facts.contextLines
        let context = freeformContextDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if !context.isEmpty {
            lines.append(context)
        }
        return lines
    }
}

struct BarnOwlLaunchRecoveryReport: Equatable {
    var recoveredRunningJobCount = 0
    var recoveredInterruptedRecordingCount = 0
    var incompleteRecordingCount = 0
    var pendingJobCount = 0

    var needsAttention: Bool {
        incompleteRecordingCount > 0
    }

    var recoveredWork: Bool {
        recoveredRunningJobCount > 0 || recoveredInterruptedRecordingCount > 0 || pendingJobCount > 0
    }
}

private struct BarnOwlMemoryEnrichmentSourceAdapter: BarnOwlEnrichmentSourceAdapter {
    let database: BarnOwlDatabase

    var sourceID: String { "barnowl_memory" }

    func healthSnapshot(
        for source: BarnOwlEnrichmentSourceDescriptor
    ) async -> BarnOwlEnrichmentSourceHealthSnapshot {
        BarnOwlEnrichmentSourceHealthSnapshot(
            status: .ready,
            authState: .notRequired,
            detail: "\(source.displayName) is backed by the local Barn Owl meeting index."
        )
    }

    func enrich(
        request: BarnOwlEnrichmentSourceRequest,
        source: BarnOwlEnrichmentSourceDescriptor
    ) async throws -> BarnOwlEnrichmentSourceResult {
        let searchResults = try await database.searchLibrary(BarnOwlDatabaseSearchQuery(
            text: request.conceptKey,
            limit: max(1, min(request.limit, 24))
        ))
        let evidence = searchResults.prefix(8).map { result in
            let confidence = min(0.95, max(0.55, 0.55 + (result.score / 20)))
            return BarnOwlEnrichmentEvidenceRecord(
                subject: request.conceptKey,
                candidateKind: "unresolved_concept",
                canonicalName: request.conceptKey,
                summary: "\(result.meeting.title): \(result.snippet)",
                confidence: confidence,
                sourceID: source.id,
                sourceDisplayName: source.displayName,
                authorityProfile: source.authorityProfile,
                freshness: .recent,
                scope: source.scope,
                citations: ["meeting:\(result.meeting.id.uuidString.lowercased())"],
                observedAt: result.meeting.updatedAt
            )
        }

        return BarnOwlEnrichmentSourceResult(
            sourceID: source.id,
            evidence: evidence,
            summary: "Barn Owl Memory returned \(evidence.count) normalized evidence item\(evidence.count == 1 ? "" : "s")."
        )
    }
}

struct BarnOwlCommandResult: Sendable {
    var standardOutput: Data
    var standardError: Data
    var terminationStatus: Int32
}

protocol BarnOwlCommandRunning: Sendable {
    func run(
        executableURL: URL,
        arguments: [String],
        environment: [String: String]?
    ) async throws -> BarnOwlCommandResult
}

struct BarnOwlSystemCommandRunner: BarnOwlCommandRunning {
    func run(
        executableURL: URL,
        arguments: [String],
        environment: [String: String]? = nil
    ) async throws -> BarnOwlCommandResult {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.environment = environment

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()

        return BarnOwlCommandResult(
            standardOutput: stdout.fileHandleForReading.readDataToEndOfFile(),
            standardError: stderr.fileHandleForReading.readDataToEndOfFile(),
            terminationStatus: process.terminationStatus
        )
    }
}

struct BarnOwlPublicReferenceResearchAdapter: BarnOwlEnrichmentSourceAdapter {
    struct SearchResponse: Decodable {
        var search: [SearchItem]
    }

    struct SearchItem: Decodable {
        var id: String
        var label: String
        var description: String?
        var concepturi: String?
    }

    let sourceID: String
    let transport: any OpenAIHTTPTransport
    let baseURL: URL

    init(
        sourceID: String,
        transport: any OpenAIHTTPTransport = URLSession.shared,
        baseURL: URL = URL(string: "https://www.wikidata.org/w/api.php")!
    ) {
        self.sourceID = sourceID
        self.transport = transport
        self.baseURL = baseURL
    }

    func healthSnapshot(
        for source: BarnOwlEnrichmentSourceDescriptor
    ) async -> BarnOwlEnrichmentSourceHealthSnapshot {
        BarnOwlEnrichmentSourceHealthSnapshot(
            status: .ready,
            authState: .notRequired,
            detail: "\(source.displayName) can issue public Wikidata reference lookups."
        )
    }

    func enrich(
        request: BarnOwlEnrichmentSourceRequest,
        source: BarnOwlEnrichmentSourceDescriptor
    ) async throws -> BarnOwlEnrichmentSourceResult {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "action", value: "wbsearchentities"),
            URLQueryItem(name: "search", value: request.conceptKey),
            URLQueryItem(name: "language", value: "en"),
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "limit", value: String(max(1, min(request.limit, 8))))
        ]
        guard let url = components?.url else {
            return BarnOwlEnrichmentSourceResult(
                sourceID: source.id,
                evidence: [],
                caveats: ["\(source.id) could not build a public-reference lookup URL."]
            )
        }

        let (data, response) = try await transport.data(for: URLRequest(url: url))
        guard (200..<300).contains(response.statusCode) else {
            throw OpenAITranscriptionClientError.unsuccessfulStatusCode(response.statusCode, data)
        }
        let payload = try JSONDecoder().decode(SearchResponse.self, from: data)
        let evidence = payload.search.prefix(max(1, min(request.limit, 8))).compactMap { item -> BarnOwlEnrichmentEvidenceRecord? in
            let candidateKind = Self.candidateKind(label: item.label, description: item.description)
            guard candidateKind != "unresolved_concept" else {
                return nil
            }
            return BarnOwlEnrichmentEvidenceRecord(
                subject: request.conceptKey,
                candidateKind: candidateKind,
                canonicalName: item.label,
                summary: Self.nonEmpty(item.description)
                    ?? "Public Wikidata reference for \(item.label).",
                confidence: candidateKind == "public_reference" ? 0.68 : 0.82,
                sourceID: source.id,
                sourceDisplayName: source.displayName,
                authorityProfile: source.authorityProfile,
                freshness: .recent,
                scope: .publicReference,
                citations: [item.concepturi ?? "https://www.wikidata.org/wiki/\(item.id)"],
                observedAt: request.requestedAt
            )
        }

        return BarnOwlEnrichmentSourceResult(
            sourceID: source.id,
            evidence: Array(evidence),
            summary: "\(source.displayName) returned \(payload.search.count) public reference candidate\(payload.search.count == 1 ? "" : "s")."
        )
    }

    private static func candidateKind(label: String, description: String?) -> String {
        let haystack = "\(label) \(description ?? "")".lowercased()
        if haystack.contains(" company")
            || haystack.contains(" corporation")
            || haystack.contains("business")
            || haystack.contains("biotechnology company")
        {
            return "company"
        }
        if haystack.contains("scientist")
            || haystack.contains("researcher")
            || haystack.contains("person")
            || haystack.contains("executive")
            || haystack.contains("author")
        {
            return "person"
        }
        if haystack.contains(" conference")
            || haystack.contains(" event")
            || haystack.contains("summit")
            || haystack.contains("festival")
        {
            return "event"
        }
        if haystack.contains(" project")
            || haystack.contains(" initiative")
            || haystack.contains(" program")
        {
            return "project"
        }
        return "unresolved_concept"
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty
        else {
            return nil
        }
        return value
    }
}

private struct BarnOwlConfiguredInternalReferenceAdapter: BarnOwlEnrichmentSourceAdapter {
    struct Configuration: Decodable {
        var entries: [Entry]
    }

    struct Entry: Decodable {
        var matchTerms: [String]?
        var candidateKind: String
        var canonicalName: String
        var summary: String
        var confidence: Double?
        var citations: [String]?
        var freshness: BarnOwlEnrichmentEvidenceFreshness?
        var contradiction: Bool?
        var negativeEvidence: Bool?
    }

    let sourceID: String

    func healthSnapshot(
        for source: BarnOwlEnrichmentSourceDescriptor
    ) async -> BarnOwlEnrichmentSourceHealthSnapshot {
        BarnOwlEnrichmentSourceHealthSnapshot(
            status: source.configJSON == nil ? .partial : .ready,
            authState: .configured,
            detail: source.configJSON == nil
                ? "\(source.displayName) has no configured internal reference payload."
                : "\(source.displayName) can emit normalized private/internal evidence from its configured reference payload."
        )
    }

    func enrich(
        request: BarnOwlEnrichmentSourceRequest,
        source: BarnOwlEnrichmentSourceDescriptor
    ) async throws -> BarnOwlEnrichmentSourceResult {
        guard let configJSON = source.configJSON,
              let data = configJSON.data(using: .utf8),
              let configuration = try? JSONDecoder().decode(Configuration.self, from: data)
        else {
            return BarnOwlEnrichmentSourceResult(
                sourceID: source.id,
                evidence: [],
                caveats: ["\(source.id) has no readable internal reference configuration."]
            )
        }

        let normalizedConcept = Self.normalized(request.conceptKey)
        let matchingEntries = configuration.entries.filter { entry in
            let terms = (entry.matchTerms ?? []) + [entry.canonicalName]
            return terms.contains { Self.normalized($0) == normalizedConcept }
        }

        let evidence = matchingEntries.prefix(max(1, request.limit)).map { entry in
            BarnOwlEnrichmentEvidenceRecord(
                subject: request.conceptKey,
                candidateKind: entry.candidateKind,
                canonicalName: entry.canonicalName,
                summary: entry.summary,
                confidence: entry.confidence ?? 0.92,
                sourceID: source.id,
                sourceDisplayName: source.displayName,
                authorityProfile: source.authorityProfile,
                freshness: entry.freshness ?? .current,
                scope: source.scope,
                citations: entry.citations ?? ["source:\(source.id):\(Self.normalized(entry.canonicalName))"],
                observedAt: request.requestedAt,
                contradiction: entry.contradiction ?? false,
                negativeEvidence: entry.negativeEvidence ?? false
            )
        }

        return BarnOwlEnrichmentSourceResult(
            sourceID: source.id,
            evidence: evidence,
            summary: "\(source.displayName) returned \(evidence.count) normalized internal evidence item\(evidence.count == 1 ? "" : "s")."
        )
    }

    private static func normalized(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }
}

private struct BarnOwlConfiguredPublicReferenceAdapter: BarnOwlEnrichmentSourceAdapter {
    struct Configuration: Decodable {
        var entries: [Entry]
    }

    struct Entry: Decodable {
        var matchTerms: [String]?
        var candidateKind: String
        var canonicalName: String
        var summary: String
        var confidence: Double?
        var citations: [String]?
        var freshness: BarnOwlEnrichmentEvidenceFreshness?
        var contradiction: Bool?
        var negativeEvidence: Bool?
    }

    let sourceID: String

    func healthSnapshot(
        for source: BarnOwlEnrichmentSourceDescriptor
    ) async -> BarnOwlEnrichmentSourceHealthSnapshot {
        BarnOwlEnrichmentSourceHealthSnapshot(
            status: source.configJSON == nil ? .partial : .ready,
            authState: .notRequired,
            detail: source.configJSON == nil
                ? "\(source.displayName) is enabled, but no public/reference evidence payload is configured yet."
                : "\(source.displayName) can emit normalized public/reference evidence from its configured retrieval payload."
        )
    }

    func enrich(
        request: BarnOwlEnrichmentSourceRequest,
        source: BarnOwlEnrichmentSourceDescriptor
    ) async throws -> BarnOwlEnrichmentSourceResult {
        guard let configJSON = source.configJSON,
              let data = configJSON.data(using: .utf8),
              let configuration = try? JSONDecoder().decode(Configuration.self, from: data)
        else {
            return BarnOwlEnrichmentSourceResult(
                sourceID: source.id,
                evidence: [],
                caveats: ["\(source.id) has no readable public/reference retrieval payload."]
            )
        }

        let normalizedConcept = Self.normalized(request.conceptKey)
        let matchingEntries = configuration.entries.filter { entry in
            let terms = (entry.matchTerms ?? []) + [entry.canonicalName]
            return terms.contains { Self.normalized($0) == normalizedConcept }
        }

        let evidence = matchingEntries.prefix(max(1, request.limit)).map { entry in
            BarnOwlEnrichmentEvidenceRecord(
                subject: request.conceptKey,
                candidateKind: entry.candidateKind,
                canonicalName: entry.canonicalName,
                summary: entry.summary,
                confidence: entry.confidence ?? 0.8,
                sourceID: source.id,
                sourceDisplayName: source.displayName,
                authorityProfile: source.authorityProfile,
                freshness: entry.freshness ?? .recent,
                scope: .publicReference,
                citations: entry.citations ?? ["public:\(Self.normalized(entry.canonicalName))"],
                observedAt: request.requestedAt,
                contradiction: entry.contradiction ?? false,
                negativeEvidence: entry.negativeEvidence ?? false
            )
        }

        return BarnOwlEnrichmentSourceResult(
            sourceID: source.id,
            evidence: evidence,
            summary: "\(source.displayName) returned \(evidence.count) normalized public/reference evidence item\(evidence.count == 1 ? "" : "s")."
        )
    }

    private static func normalized(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }
}

enum BarnOwlRecoveryCoordinator {
    static func recoverInterruptedWork(
        database: BarnOwlDatabase,
        jobRunner: BarnOwlJobRunner,
        tempRoot: URL = BarnOwlAudioCaptureFactory.tempRoot,
        now: Date = Date()
    ) async throws -> BarnOwlLaunchRecoveryReport {
        var report = BarnOwlLaunchRecoveryReport()
        let audioProvider = TempAudioRecordedFileProvider(tempRoot: tempRoot)

        let runningJobs = try await database.jobs(status: .running, limit: 100)
        for var job in runningJobs {
            job.status = .pending
            job.attemptCount = max(0, job.attemptCount - 1)
            job.errorMessage = "Interrupted when Barn Owl last quit. Retrying now."
            job.scheduledAt = now
            job.startedAt = nil
            job.completedAt = nil
            job.updatedAt = now
            try await database.upsertJob(job)
            report.recoveredRunningJobCount += 1
        }

        let states = try await database.meetingStates(limit: 500)
        for state in states {
            guard let sessionRecord = state.recordingSessions
                .sorted(by: { $0.updatedAt > $1.updatedAt })
                .first
            else {
                continue
            }

            let activeJob = state.jobs.contains { job in
                job.type == BarnOwlJobType.finalProcessing
                    && (job.status == .pending || job.status == .running || job.status == .succeeded)
            }
            let needsRecordingRecovery = sessionRecord.status == .pending || sessionRecord.status == .recording
            let needsProcessingRecovery = sessionRecord.status == .processing
                && !activeJob
                && state.generatedNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            guard needsRecordingRecovery || needsProcessingRecovery else {
                continue
            }

            let recoveredSession = recordingSession(from: state, sessionRecord: sessionRecord, endedAt: now)
            let audioFiles = (try? await audioProvider.audioFiles(for: recoveredSession)) ?? []

            if !audioFiles.isEmpty {
                try await markSession(recoveredSession, state: state, status: .processing, database: database, now: now)
                _ = try await jobRunner.enqueueFinalProcessing(session: recoveredSession, priority: 110)
                report.recoveredInterruptedRecordingCount += 1
            } else {
                try await markSession(recoveredSession, state: state, status: .failed, database: database, now: now)
                try await createFailedRecoveryJobIfNeeded(
                    meetingID: recoveredSession.id,
                    existingJobs: state.jobs,
                    message: "Recording was interrupted and no recoverable audio chunks were found.",
                    database: database,
                    now: now
                )
                report.incompleteRecordingCount += 1
            }
        }

        report.pendingJobCount = try await database.jobs(status: .pending, limit: 100).count
        return report
    }

    @discardableResult
    static func retryFailedJobs(
        database: BarnOwlDatabase,
        ids: Set<UUID>? = nil,
        now: Date = Date()
    ) async throws -> Int {
        let failedJobs = try await database.jobs(status: .failed, limit: 100)
            .filter { ids == nil || ids?.contains($0.id) == true }
        for var job in failedJobs {
            job.status = .pending
            job.errorMessage = nil
            job.scheduledAt = now
            job.completedAt = nil
            job.updatedAt = now
            try await database.upsertJob(job)
        }
        return failedJobs.count
    }

    static func dismissFailedJob(
        id: UUID,
        database: BarnOwlDatabase,
        now: Date = Date()
    ) async throws {
        guard var job = try await database.job(id: id) else { return }
        job.status = .canceled
        job.errorMessage = nil
        job.completedAt = now
        job.updatedAt = now
        try await database.upsertJob(job)
    }

    private static func recordingSession(
        from state: BarnOwlMeetingState,
        sessionRecord: BarnOwlRecordingSessionRecord,
        endedAt: Date
    ) -> RecordingSession {
        RecordingSession(
            id: sessionRecord.id,
            title: state.title,
            startedAt: sessionRecord.startedAt,
            endedAt: sessionRecord.endedAt ?? endedAt,
            audioSources: audioSources(from: sessionRecord.audioSourcesJSON)
        )
    }

    private static func audioSources(from json: String?) -> AudioSourceConfiguration {
        guard let data = json?.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return .defaultMeetingCapture
        }
        return AudioSourceConfiguration(
            capturesMicrophone: object["microphone"] as? Bool ?? true,
            capturesSystemAudio: object["systemAudio"] as? Bool ?? object["system"] as? Bool ?? true
        )
    }

    private static func markSession(
        _ session: RecordingSession,
        state: BarnOwlMeetingState,
        status: BarnOwlRecordingSessionStatus,
        database: BarnOwlDatabase,
        now: Date
    ) async throws {
        var meeting = state.meeting
        meeting.endedAt = meeting.endedAt ?? session.endedAt ?? now
        meeting.updatedAt = now
        try await database.upsertMeeting(meeting)
        try await database.upsertRecordingSession(BarnOwlRecordingSessionRecord(
            id: session.id,
            meetingID: session.id,
            status: status,
            startedAt: session.startedAt,
            endedAt: session.endedAt ?? now,
            audioSourcesJSON: state.recordingSessions.first(where: { $0.id == session.id })?.audioSourcesJSON,
            createdAt: session.startedAt,
            updatedAt: now
        ))
    }

    private static func createFailedRecoveryJobIfNeeded(
        meetingID: UUID,
        existingJobs: [BarnOwlJobRecord],
        message: String,
        database: BarnOwlDatabase,
        now: Date
    ) async throws {
        guard !existingJobs.contains(where: { $0.type == BarnOwlJobType.finalProcessing && $0.status == .failed }) else {
            return
        }
        let job = BarnOwlJobRecord(
            meetingID: meetingID,
            type: BarnOwlJobType.finalProcessing,
            status: .failed,
            priority: 100,
            errorMessage: message,
            createdAt: now,
            updatedAt: now,
            completedAt: now
        )
        try await database.upsertJob(job)
    }
}

@MainActor
final class BarnOwlAppModel: ObservableObject {
    private static let quickAccessSessionWindow: TimeInterval = 2 * 60 * 60
    private static let quickAccessSessionLimit = 2
    static let activityVisibilityWindow: TimeInterval = 3 * 60

    @Published var status: RecordingStatus = .idle
    @Published var activeSession: RecordingSession?
    @Published var liveTranscriptPreview = "Ready."
    @Published var lastError: String?
    @Published var recentSessions: [BarnOwlRecentSession] = []
    @Published var activityItems: [BarnOwlActivityItem] = []
    @Published var captureStatus = "Idle."
    @Published var finalTranscriptionStatus = "Idle."
    @Published var progressFraction: Double?
    @Published var displayedNote: BarnOwlDisplayedNote?
    @Published var noteDraft = ""
    @Published var noteSearchQuery = ""
    @Published var noteSearchResults: [BarnOwlNoteSearchResult] = []
    @Published var searchMeetingTypeFilter = ""
    @Published var searchParticipantFilter = ""
    @Published var searchStatusFilter: BarnOwlRecordingSessionStatus?
    @Published var searchStatus = ""
    @Published var isSearchInFlight = false
    @Published var contextDraft = ""
    @Published var isContextUpdateInFlight = false
    @Published var contextReviewStatus = ""
    @Published var calendarContext: CalendarMeetingContext?
    @Published var calendarContextAccepted = false
    @Published var calendarContextStatus = "Calendar context idle."
    @Published var notePrompt = ""
    @Published var noteActionStatus = "Ready."
    @Published var noteTitleDraft = ""
    @Published var isNoteUpdateInFlight = false
    @Published var realtimeStatus = "Realtime transcription idle."
    @Published var realtimeHealthState: BarnOwlRealtimeHealthState = .idle
    @Published var updateStatus = "Updater idle."
    @Published var updateAvailability: BarnOwlUpdateAvailability = .unknown
    @Published var isUpdateInFlight = false
    @Published var performanceSummaryText = ""
    @Published var recordingElapsedText = "00:00"
    @Published var waveformLevels: [Double] = Array(repeating: 0.18, count: 24)
    @Published var audioActivityLevel: Double = 0
    @Published var selectedAudioSources = AudioSourceConfiguration.defaultMeetingCapture
    @Published var chatDraft = ""
    @Published var chatMessages: [BarnOwlChatMessage] = [
        BarnOwlChatMessage(role: .assistant, text: "Ask about this meeting, recent meetings, decisions, follow-ups, or local context.")
    ]
    @Published var isChatInFlight = false
    @Published var chatStatus = ""
    @Published var lastFailedChatQuestion: String?
    @Published var jobSummaries: [BarnOwlJobSummary] = []
    @Published var recoveryAttentionItems: [BarnOwlRecoveryAttentionItem] = []
    @Published var processingTimelineItems: [BarnOwlProcessingTimelineItem] = []
    @Published var meetingHistoryItems: [BarnOwlMeetingHistoryItem] = []
    @Published var historyStatus = ""
    @Published var isHistoryRestoreInFlight = false
    @Published var postRecordingContextReview: BarnOwlPostRecordingContextReview?
    @Published var contextInboxItems: [BarnOwlContextInboxItem] = []
    @Published var recordingReadinessSummary = RecordingHealthSnapshot.idle.readinessSummary(
        configuration: .defaultMeetingCapture,
        permissions: .unknown,
        now: 0
    )

    private var stateMachine = RecordingStateMachine()
    private var audioCoordinator: AudioSessionCoordinator?
    private var rollingFinalTranscriptionCoordinator: RollingFinalTranscriptionCoordinator?
    private var rollingFinalTranscriptionEnqueueTasks: [Task<Void, Never>] = []
    private let makeAudioCoordinator: @Sendable (
        UUID,
        BarnOwlAudioCaptureFactory.AudioCaptureProgressHandler?,
        BarnOwlAudioCaptureFactory.AudioRealtimePCMHandler?
    ) -> AudioSessionCoordinator
    private let meetingProcessor: any MeetingProcessing
    private let makeLibraryStore: @Sendable () throws -> FilesystemLocalLibraryStore
    private let makeDatabase: @Sendable () throws -> BarnOwlDatabase
    private let makeCalendarContextProvider: @Sendable () -> any CalendarMeetingContextProvider
    private let currentEnrichmentOwnerID: @Sendable () -> String
    private let diagnosticsStore: DiagnosticsLogStore
    private let jobRunner: BarnOwlJobRunner
    private var realtimeTranscriptionController: BarnOwlRealtimeTranscriptionController?
    private var realtimeDraft = ""
    private var performanceMetrics = PerformanceMetricAccumulator()
    private var didRecordFirstAudioChunk = false
    private var didRecordFirstRealtimeTranscript = false
    private var didRecordFirstFinalTranscript = false
    private var didRecordFinalProcessingStart = false
    private var didRecordTranscriptionStart = false
    private var tempAudioByteCount: Int64 = 0
    private var elapsedTimer: AnyCancellable?
    private var pendingAudioActivityLevels: [Double] = []
    private var lastWaveformPublishAt = Date.distantPast
    private var lastRealtimePreviewPublishAt = Date.distantPast
    private var lastRealtimePersistenceAt = Date.distantPast
    private var realtimeLiveSegmentSequence = 0
    private var recordingHealth = RecordingHealthSnapshot.idle
    private var recordingHealthStartedAt: Date?
    private var didWarnRealtimeNoTranscript = false
    private var didWarnRealtimeFallback = false
    private var rollingFinalTranscriptionQueuedChunkCount = 0
    private var jobRunnerTask: Task<Void, Never>?
    private var jobRunnerWakeTask: Task<Void, Never>?
    private var completionReadyResetTask: Task<Void, Never>?
    private var updateAvailabilityTimer: AnyCancellable?
    private var lastAudibleAudioAt: Date?
    private var lastCapturedChunkAtByTrack: [AudioTrackKind: Date] = [:]
    private var lastCaptureRestartAt = Date.distantPast
    private var sleepWakeObservers: [NSObjectProtocol] = []
    private var didAutoStopForSilence = false
    private static let waveformPublishInterval: TimeInterval = 0.10
    private static let realtimePreviewPublishInterval: TimeInterval = 0.85
    private static let realtimePersistenceInterval: TimeInterval = 5
    private static let realtimePreviewCharacterLimit = 1_200
    static let finalTranscriptionIdleStatus = "Idle."
    private static let completionReadyResetDelayNanoseconds: UInt64 = 2_000_000_000
    private static let autoStopSilenceInterval: TimeInterval = 15 * 60
    private static let autoStopSilenceRMSThreshold: Double = 0.01
    private static let captureWatchdogGraceInterval: TimeInterval = 95
    private static let captureRestartCooldown: TimeInterval = 45
    private static let periodicUpdateCheckInterval: TimeInterval = 6 * 60 * 60
    private static let summaryFallbackMarker = "Summary generation failed"

    init(
        makeAudioCoordinator: @escaping @Sendable (
            UUID,
            BarnOwlAudioCaptureFactory.AudioCaptureProgressHandler?,
            BarnOwlAudioCaptureFactory.AudioRealtimePCMHandler?
        ) -> AudioSessionCoordinator = BarnOwlAudioCaptureFactory.makeCoordinator,
        meetingProcessor: any MeetingProcessing = BarnOwlMeetingProcessor(),
        makeLibraryStore: @escaping @Sendable () throws -> FilesystemLocalLibraryStore = {
            FilesystemLocalLibraryStore(rootDirectory: try BarnOwlMeetingProcessor.defaultLibraryRoot())
        },
        makeDatabase: @escaping @Sendable () throws -> BarnOwlDatabase = {
            try BarnOwlDatabase(url: try BarnOwlAppModel.defaultDatabaseURL())
        },
        makeCalendarContextProvider: @escaping @Sendable () -> any CalendarMeetingContextProvider = {
            EmptyCalendarMeetingContextProvider()
        },
        currentEnrichmentOwnerID: @escaping @Sendable () -> String = {
            BarnOwlEnrichmentSourceOwner.localUserID()
        },
        diagnosticsStore: DiagnosticsLogStore = DiagnosticsLogStore(rootDirectory: BarnOwlAppModel.defaultDiagnosticsRoot())
    ) {
        self.makeAudioCoordinator = makeAudioCoordinator
        self.meetingProcessor = meetingProcessor
        self.makeLibraryStore = makeLibraryStore
        self.makeDatabase = makeDatabase
        self.makeCalendarContextProvider = makeCalendarContextProvider
        self.currentEnrichmentOwnerID = currentEnrichmentOwnerID
        self.diagnosticsStore = diagnosticsStore
        self.jobRunner = BarnOwlJobRunner(makeDatabase: makeDatabase, meetingProcessor: meetingProcessor)
        configurePeriodicUpdateChecks()
        installSleepWakeObservers()
        Task.detached(priority: .utility) {
            await self.seedDefaultEnrichmentSources()
            await self.performLaunchRecovery()
            await self.refreshRecentSessions()
            await self.refreshJobSummaries()
            await self.refreshRecoveryAttentionItems()
            await self.refreshContextInbox()
            await self.refreshUpdateAvailability()
            await self.startJobRunner()
        }
    }

    var canStartRecording: Bool {
        stateMachine.state.canStartRecording
    }

    var canUsePrimaryAction: Bool {
        stateMachine.state.canStartRecording || stateMachine.state.canStopRecording
    }

    var primaryActionTitle: String {
        BarnOwlLifecyclePresentation.primaryActionTitle(for: stateMachine.state)
    }

    var lifecyclePresentation: BarnOwlLifecyclePresentation {
        BarnOwlLifecyclePresentation.make(
            state: stateMachine.state,
            hasActiveProcessing: progressFraction != nil || Self.hasActiveProcessing(processingTimelineItems),
            hasFailedProcessing: Self.hasFailedProcessing(processingTimelineItems),
            hasDisplayedNote: displayedNote != nil
        )
    }

    nonisolated static func hasActiveProcessing(_ timeline: [BarnOwlProcessingTimelineItem]) -> Bool {
        !BarnOwlProcessingTimeline.shouldCollapse(timeline)
            && timeline.contains { $0.status == .pending || $0.status == .running }
    }

    nonisolated static func hasFailedProcessing(_ timeline: [BarnOwlProcessingTimelineItem]) -> Bool {
        !BarnOwlProcessingTimeline.shouldCollapse(timeline)
            && timeline.contains { $0.status == .failed }
    }

    var quickAccessSessions: [BarnOwlRecentSession] {
        Self.quickAccessSessions(recentSessions, now: Date())
    }

    static func quickAccessSessions(
        _ sessions: [BarnOwlRecentSession],
        now: Date
    ) -> [BarnOwlRecentSession] {
        let cutoff = now.addingTimeInterval(-quickAccessSessionWindow)
        let sortedSessions = sessions.sorted {
            let lhsDate = $0.endedAt ?? $0.startedAt
            let rhsDate = $1.endedAt ?? $1.startedAt
            if lhsDate == rhsDate {
                return $0.title.localizedStandardCompare($1.title) == .orderedAscending
            }
            return lhsDate > rhsDate
        }
        let recent = sortedSessions.filter { ($0.endedAt ?? $0.startedAt) >= cutoff }
        return Array((recent.isEmpty ? sortedSessions : recent).prefix(quickAccessSessionLimit))
    }

    var visibleActivityItems: [BarnOwlActivityItem] {
        Self.visibleActivityItems(activityItems, now: Date())
    }

    func visibleActivityItems(now: Date = Date()) -> [BarnOwlActivityItem] {
        Self.visibleActivityItems(activityItems, now: now)
    }

    static func visibleActivityItems(_ items: [BarnOwlActivityItem], now: Date) -> [BarnOwlActivityItem] {
        let cutoff = now.addingTimeInterval(-activityVisibilityWindow)
        return Array(items.filter { $0.timestamp >= cutoff }.prefix(4))
    }

    func toggleRecording() async {
        guard canUsePrimaryAction else { return }

        if stateMachine.state.canStopRecording {
            await stopRecording()
        } else {
            await startRecording()
        }
    }

    func setSystemAudioCaptureEnabled(_ enabled: Bool) {
        guard status != .recording else {
            captureStatus = "System audio can be changed before the next recording."
            return
        }
        selectedAudioSources.capturesSystemAudio = enabled
        publishRecordingReadinessSummary()
    }

    func setMicrophoneCaptureEnabled(_ enabled: Bool) {
        guard status != .recording else {
            captureStatus = "Microphone can be changed before the next recording."
            return
        }
        selectedAudioSources.capturesMicrophone = enabled
        publishRecordingReadinessSummary()
    }

    func checkForUpdatesAndInstallLatest() async {
        guard !isUpdateInFlight else { return }
        if case .unknown = updateAvailability {
            await refreshUpdateAvailability()
        }
        guard updateAvailability.hasInstallableUpdate else {
            updateStatus = updateAvailability.statusText
            return
        }

        isUpdateInFlight = true
        let channel = BarnOwlUpdaterSettings.updateChannelLabel
        updateStatus = "Checking \(channel.lowercased())..."
        defer { isUpdateInFlight = false }

        do {
            let result = try await BarnOwlUpdater.checkAndInstallLatest()
            switch result {
            case .upToDate(let version, let build):
                updateAvailability = .upToDate(version: version, build: build)
                updateStatus = "Barn Owl is up to date. Version \(version) (\(build))."
            case .installing(let version, let build):
                updateStatus = "Installing Barn Owl \(version) (\(build)) and restarting..."
            }
        } catch {
            updateAvailability = .unavailable(BarnOwlErrorFormatter.message(for: error))
            updateStatus = BarnOwlErrorFormatter.message(for: error)
            recordActivity(
                level: .warning,
                category: "updater",
                message: "Update failed.",
                details: updateStatus,
                updatePreview: false
            )
        }
    }

    func refreshUpdateAvailability() async {
        guard !isUpdateInFlight else { return }
        updateAvailability = .checking
        updateAvailability = await BarnOwlUpdater.checkLatestAvailability()
    }

    private func configurePeriodicUpdateChecks() {
        updateAvailabilityTimer = Timer.publish(
            every: Self.periodicUpdateCheckInterval,
            on: .main,
            in: .common
        )
        .autoconnect()
        .sink { [weak self] _ in
            Task { @MainActor in
                guard let self,
                      self.status == .idle,
                      !self.isUpdateInFlight
                else { return }
                await self.refreshUpdateAvailability()
            }
        }
    }

    private func installSleepWakeObservers() {
        let center = NSWorkspace.shared.notificationCenter
        let sleepObserver = center.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.handleSystemWillSleep()
            }
        }
        let wakeObserver = center.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                await self?.handleSystemDidWake()
            }
        }
        sleepWakeObservers = [sleepObserver, wakeObserver]
    }

    func startRecording(audioSources: AudioSourceConfiguration? = nil) async {
        guard canStartRecording else { return }
        let requestedAudioSources = audioSources ?? selectedAudioSources
        resetSessionSurface()
        recordPerformance(.phase(.capture, .started, at: Self.performanceNow()))
        recordPerformance(.milestone(.captureStarted, at: Self.performanceNow()))
        lastError = nil
        captureStatus = "Checking setup."
        recordActivity(
            category: "capture",
            message: "Start recording requested.",
            updatePreview: false
        )

        guard requestedAudioSources.capturesMicrophone || requestedAudioSources.capturesSystemAudio else {
            fail(
                reason: .captureUnavailable,
                message: "Select at least one audio source before recording.",
                sessionID: nil,
                preview: "Recording could not start."
            )
            return
        }

        let openAIConfiguration: OpenAIConfiguration
        do {
            openAIConfiguration = try BarnOwlAPIKeyStore.makeConfiguration()
        } catch {
            fail(
                reason: .missingAPIKey,
                message: "Add an OpenAI API key in Barn Owl Settings before recording.",
                sessionID: nil,
                preview: "Open Settings to add an API key."
            )
            return
        }
        let startedAt = Date()
        if requestedAudioSources.capturesMicrophone {
            captureStatus = "Requesting microphone permission."
            let microphoneDecision = await BarnOwlFirstRunReadiness.requestMicrophoneDecision()
            guard microphoneDecision == .granted else {
                BarnOwlFirstRunReadiness.clearLocalCaptureReadiness()
                publishRecordingReadinessSummary()
                let message = BarnOwlFirstRunReadiness.microphonePermissionBlockedMessage(for: microphoneDecision)
                fail(
                    reason: .permissionDenied,
                    message: message,
                    sessionID: nil,
                    preview: "Recording could not start."
                )
                return
            }
        } else {
            captureStatus = "Microphone disabled for this recording."
        }

        if requestedAudioSources.capturesSystemAudio {
            let hasSystemAudioEvidence = BarnOwlFirstRunReadiness.hasSystemAudioCaptureEvidence()
            captureStatus = hasSystemAudioEvidence
                ? "Checking system audio readiness."
                : "Requesting system audio permission."
            let systemAudioDecision = BarnOwlFirstRunReadiness.requestSystemAudioDecisionIfNeeded()
            if systemAudioDecision != .granted {
                recordActivity(
                    level: .warning,
                    category: "capture",
                    message: "System audio permission is not confirmed yet.",
                    details: hasSystemAudioEvidence
                        ? "Barn Owl has prior system-audio capture evidence and will verify capture during recording."
                        : "Barn Owl will attempt capture so macOS can show the required permission prompt if needed.",
                    updatePreview: false
                )
            }
        } else {
            captureStatus = "System audio disabled for this recording."
        }

        let matchedCalendarContext = await resolveCalendarContext(around: startedAt)
        let sessionTitle = matchedCalendarContext?.isHighConfidence == true
            ? matchedCalendarContext?.title ?? "Untitled Meeting"
            : "Untitled Meeting"
        let session = RecordingSession(
            title: sessionTitle,
            startedAt: startedAt,
            audioSources: requestedAudioSources
        )
        lastAudibleAudioAt = startedAt
        didAutoStopForSilence = false
        if let matchedCalendarContext,
           matchedCalendarContext.isHighConfidence {
            calendarContextAccepted = true
            await persistCalendarContext(matchedCalendarContext, meetingID: session.id)
        }
        resetRecordingHealth(for: session.audioSources, startedAt: session.startedAt)

        let startResult = stateMachine.beginStart(
            session: session,
            permissions: .grantedForDefaultMeetingCapture
        )
        apply(startResult)
        guard case .accepted = startResult else { return }
        await persistSessionState(session, status: .pending)
        liveTranscriptPreview = Self.audioReadinessPreview(for: requestedAudioSources)
        captureStatus = "Starting \(Self.audioSourceDescription(requestedAudioSources))."
        realtimeStatus = "Starting realtime transcription."

        let realtimeHintContext = matchedCalendarContext?.contextLines ?? []
        let realtimeCuratedHints: [String]
        if let database = try? makeDatabase() {
            realtimeCuratedHints = (try? await BarnOwlRealtimeTranscriptionHintsStore.curatedHintTerms(
                database: database,
                ownerID: BarnOwlEnrichmentSourceOwner.localUserID(),
                attachedContext: realtimeHintContext
            )) ?? []
        } else {
            realtimeCuratedHints = []
        }
        let realtimePrompt = BarnOwlRealtimeTranscriptionHintsStore.currentPrompt(
            attachedContext: realtimeHintContext,
            curatedTerms: realtimeCuratedHints
        )

        let realtimeController: BarnOwlRealtimeTranscriptionController
        realtimeController = BarnOwlRealtimeTranscriptionController(
            configuration: openAIConfiguration,
            prompt: realtimePrompt,
            updateHandler: { [weak self] update in
                self?.handleRealtimeTranscriptionUpdate(update, sessionID: session.id)
            },
            healthHandler: { [weak self] healthState in
                self?.handleRealtimeHealthState(healthState, sessionID: session.id)
            },
            diagnosticsHandler: { [weak self] event in
                self?.handleRealtimeDiagnosticEvent(event, sessionID: session.id)
            }
        )
        realtimeTranscriptionController = realtimeController
        recordPerformance(.phase(.realtimePreview, .started, at: Self.performanceNow(), model: OpenAIModelCatalog.liveTranscription))
        recordPerformance(.milestone(.realtimePreviewStarted, at: Self.performanceNow()))
        await realtimeController.start()

        do {
            let rollingCache = SQLiteRollingFinalTranscriptionCacheStore(database: try makeDatabase())
            rollingFinalTranscriptionCoordinator = RollingFinalTranscriptionCoordinator(
                sessionID: session.id,
                transcriptionClient: OpenAIAudioFileTranscriptionClientAdapter(
                    client: OpenAITranscriptionClient(configuration: openAIConfiguration)
                ),
                cacheStore: rollingCache,
                modelIdentifier: OpenAIModelCatalog.finalDiarization
            )
            finalTranscriptionStatus = "Processing saved chunks while you record."
        } catch {
            rollingFinalTranscriptionCoordinator = nil
            finalTranscriptionStatus = "Will run after recording stops."
            recordActivity(
                level: .warning,
                category: "transcription",
                message: "Rolling final transcription cache is unavailable.",
                details: BarnOwlErrorFormatter.message(for: error),
                sessionID: session.id,
                updatePreview: false
            )
        }

        let audioCoordinator = makeAudioCoordinator(
            session.id,
            { [weak self] progress in
                self?.handleAudioCaptureProgress(progress, sessionID: session.id)
            },
            { [weak self] chunk in
                Task.detached(priority: .userInitiated) {
                    let level = Self.audioActivityLevel(forPCM16Data: chunk.pcm16Data)
                    let rmsLevel = RMSLevelMeter.rmsLevel(forPCM16Data: chunk.pcm16Data)
                    await MainActor.run {
                        self?.handleRealtimeAudioActivity(
                            level: level,
                            rmsLevel: rmsLevel,
                            trackKind: chunk.trackKind,
                            sessionID: session.id
                        )
                    }
                    await realtimeController.append(chunk)
                }
            }
        )
        self.audioCoordinator = audioCoordinator

        do {
            try await audioCoordinator.start(configuration: session.audioSources)
            apply(stateMachine.markRecording())
            await persistSessionState(session, status: .recording)
            startElapsedTimer(for: session)
            progressFraction = nil
            captureStatus = "Recording \(Self.audioSourceDescription(session.audioSources)). Temporary WAV chunks are being saved for processing."
            if let matchedCalendarContext {
                let contextMessage = matchedCalendarContext.isHighConfidence
                    ? "Using calendar context: \(matchedCalendarContext.title)."
                    : "Possible calendar context found: \(matchedCalendarContext.title)."
                recordActivity(
                    level: matchedCalendarContext.isHighConfidence ? .info : .warning,
                    category: "calendar",
                    message: contextMessage,
                    details: "\(matchedCalendarContext.contextLines.count) calendar context line(s) attached.",
                    sessionID: session.id,
                    updatePreview: false
                )
            }
            recordActivity(
                category: "capture",
                message: "Recording started.",
                details: "Capturing \(Self.audioSourceDescription(session.audioSources)).",
                sessionID: session.id
            )
            if Self.isLiveTranscriptPlaceholder(liveTranscriptPreview) {
                liveTranscriptPreview = "Listening. Barn Owl will add transcript text here as chunks are transcribed."
            }
        } catch {
            BarnOwlFirstRunReadiness.clearSystemAudioCaptureReadiness()
            publishRecordingReadinessSummary()
            await audioCoordinator.stop()
            self.audioCoordinator = nil
            await drainRollingFinalTranscriptionEnqueues()
            await rollingFinalTranscriptionCoordinator?.finishAndDrain(timeout: .seconds(1))
            rollingFinalTranscriptionCoordinator = nil
            await stopLiveTranscription()
            await BarnOwlAudioCaptureFactory.deleteTemporaryAudio(for: session.id)
            await persistSessionState(session, status: .failed, endedAt: Date())
            fail(
                reason: captureFailureReason(for: error),
                message: captureFailureMessage(for: error),
                sessionID: session.id,
                preview: "Recording could not start."
            )
        }
    }

    func stopRecording() async {
        guard stateMachine.state.canStopRecording else { return }

        apply(stateMachine.beginStop(at: Date()))
        liveTranscriptPreview = "Finalizing transcript..."
        captureStatus = "Stopping capture and flushing audio chunks."
        progressFraction = 0
        guard let session = activeSession else { return }
        persistRealtimeState(sessionID: session.id, force: true)
        recordPerformance(.milestone(.captureStopped, at: Self.performanceNow()))
        recordPerformance(.phase(.capture, .finished, at: Self.performanceNow()))
        recordActivity(
            category: "capture",
            message: "Stop recording requested.",
            sessionID: session.id
        )

        await audioCoordinator?.stop()
        audioCoordinator = nil
        stopElapsedTimer(reset: false)
        await stopLiveTranscription()
        await drainRollingFinalTranscriptionEnqueues()
        finalTranscriptionStatus = "Finishing saved chunks."
        await rollingFinalTranscriptionCoordinator?.finishAndDrain(timeout: .seconds(2))
        rollingFinalTranscriptionCoordinator = nil
        recordPerformance(.phase(.realtimePreview, .finished, at: Self.performanceNow(), model: OpenAIModelCatalog.liveTranscription))
        apply(stateMachine.beginProcessing())
        let stoppedSession = session.finished(at: Date())
        await persistSessionState(stoppedSession, status: .processing)
        await refreshProcessingTimeline(meetingID: stoppedSession.id)
        await queueFinalProcessing(for: stoppedSession)
    }

    func approvePostRecordingContextReview() async {
        await applyPostRecordingContextReview()
    }

    func processPostRecordingContextWithoutEdits() async {
        postRecordingContextReview = nil
        contextReviewStatus = "Kept generated notes unchanged."
        noteActionStatus = "Kept generated notes unchanged."
    }

    func dismissPostRecordingContextReviewForNow() {
        noteActionStatus = "Context review is still available when you want to improve the note."
    }

    func addPostRecordingContext() async {
        await applyPostRecordingContextReview(statusMessage: "Added context and updated meeting facts.")
    }

    func regenerateNotesFromPostRecordingContext() async {
        await applyPostRecordingContextReview(statusMessage: "Regenerated notes from updated context.")
    }

    private func preparePostRecordingContextReview(for session: RecordingSession) {
        let transcript = Self.reviewTranscriptPreview(from: liveTranscriptPreview)
        let suggestion = Self.suggestPostRecordingContext(
            session: session,
            transcriptPreview: transcript
        )
        postRecordingContextReview = suggestion
        noteTitleDraft = suggestion.facts.title ?? session.title
        contextDraft = suggestion.contextLines.joined(separator: "\n")
        progressFraction = nil
        liveTranscriptPreview = transcript.isEmpty
            ? "Add optional context when ready."
            : transcript
        captureStatus = "Final processing continues. Add context if Barn Owl missed anything."
        contextReviewStatus = "Context review is ready."
        noteActionStatus = "Context review is ready."
        recordActivity(
            category: "context",
            message: "Post-recording context review is ready.",
            details: "Final processing is immediate; context review can update the finished notes afterward.",
            sessionID: session.id,
            updatePreview: false
        )
    }

    private func queueFinalProcessing(for session: RecordingSession) async {
        do {
            _ = try await jobRunner.enqueueFinalProcessing(session: session)
            activeSession = nil
            await refreshJobSummaries()
            await refreshProcessingTimeline(meetingID: session.id)
            apply(stateMachine.complete())
            progressFraction = nil
            liveTranscriptPreview = "Final processing queued in the background."
            captureStatus = "Final processing queued. You can keep using Barn Owl."
            finalTranscriptionStatus = "Final transcript, notes, and meeting artifacts are running in the background."
            noteActionStatus = "Final processing queued."
            recordActivity(
                category: "jobs",
                message: "Final processing job queued.",
                details: "Barn Owl will transcribe, clean up, title, summarize, index, and export this meeting in the background.",
                sessionID: session.id
            )
            startJobRunner()
            resetMenuCaptureStatusAfterCompletion()
        } catch {
            progressFraction = nil
            fail(
                reason: processingFailureReason(for: error),
                message: "Barn Owl could not queue final processing: \(BarnOwlErrorFormatter.message(for: error))",
                sessionID: session.id,
                preview: "Transcript job could not be queued."
            )
            await persistSessionState(session, status: .failed, endedAt: session.endedAt ?? Date())
            await refreshProcessingTimeline(meetingID: session.id)
            captureStatus = "Processing job could not be queued."
        }
    }

    private func applyPostRecordingContextReview(statusMessage: String = "Updated note context from transcript review.") async {
        guard !isContextUpdateInFlight else {
            contextReviewStatus = "Reading context..."
            return
        }
        guard let review = postRecordingContextReview else {
            contextReviewStatus = "No context review is waiting."
            noteActionStatus = "No context review is waiting."
            return
        }
        isContextUpdateInFlight = true
        contextReviewStatus = "Reading context..."
        defer { isContextUpdateInFlight = false }

        let updatedFacts = MeetingFactsExtractor().extract(
            transcript: review.transcriptPreview,
            freeformContext: review.freeformContextDraft,
            existingFacts: review.facts,
            currentTitle: review.session.title
        )
        contextReviewStatus = Self.contextReviewChangeSummary(from: review.facts, to: updatedFacts)
        var reviewedSession = review.session
        reviewedSession.title = MeetingFacts.clean(updatedFacts.title) ?? reviewedSession.title

        do {
            var updatedReview = review
            updatedReview.facts = updatedFacts
            try await persistPostRecordingContextReview(updatedReview, session: reviewedSession, contextLines: updatedReview.contextLines)
            try await applyPostRecordingReviewToDisplayedNote(updatedReview, session: reviewedSession)
            postRecordingContextReview = nil
            await refreshRecentSessions()
            contextReviewStatus = statusMessage
            noteActionStatus = statusMessage
        } catch {
            contextReviewStatus = "Context review update failed."
            noteActionStatus = "Context review update failed: \(BarnOwlErrorFormatter.message(for: error))"
        }
    }

    static func contextReviewChangeSummary(from oldFacts: MeetingFacts, to newFacts: MeetingFacts) -> String {
        var changes: [String] = []
        if MeetingFacts.clean(oldFacts.title) != MeetingFacts.clean(newFacts.title),
           let title = MeetingFacts.clean(newFacts.title) {
            changes.append("title -> \(title)")
        }
        if MeetingFacts.clean(oldFacts.meetingType) != MeetingFacts.clean(newFacts.meetingType),
           let type = MeetingFacts.clean(newFacts.meetingType) {
            changes.append("type -> \(type)")
        }
        if oldFacts.participants != newFacts.participants, !newFacts.participants.isEmpty {
            changes.append("participants -> \(newFacts.participants.joined(separator: ", "))")
        }
        let oldContext = oldFacts.customers + oldFacts.organizations + oldFacts.projects
        let newContext = newFacts.customers + newFacts.organizations + newFacts.projects
        if oldContext != newContext, !newContext.isEmpty {
            changes.append("context -> \(newContext.joined(separator: ", "))")
        }
        if changes.isEmpty {
            return "No fact changes found. Regenerating note with current context..."
        }
        return "Updated \(changes.joined(separator: "; ")). Regenerating note..."
    }

    private func persistPostRecordingContextReview(
        _ review: BarnOwlPostRecordingContextReview,
        session: RecordingSession,
        contextLines: [String]
    ) async throws {
        let database = try makeDatabase()
        let now = Date()
        let beforeState = try? await database.meetingState(id: session.id)
        try await database.upsertMeeting(BarnOwlMeetingRecord(
            id: session.id,
            title: session.title,
            startedAt: session.startedAt,
            endedAt: session.endedAt,
            createdAt: session.startedAt,
            updatedAt: now,
            metadataJSON: Self.reviewMetadataJSON(
                audioSources: session.audioSources,
                meetingFacts: review.facts
            )
        ))
        try await database.upsertMeetingOutput(BarnOwlMeetingOutputRecord(
            meetingID: session.id,
            kind: "manual_context",
            content: contextLines.joined(separator: "\n"),
            contentType: "text/plain",
            createdAt: now,
            updatedAt: now,
            metadataJSON: #"{"source":"post-recording-review"}"#
        ))
        if let factsJSON = review.facts.encodedJSONString() {
            try await database.replaceMeetingOutput(BarnOwlMeetingOutputRecord(
                meetingID: session.id,
                kind: "meeting_facts",
                content: factsJSON,
                contentType: "application/json",
                createdAt: now,
                updatedAt: now,
                metadataJSON: #"{"source":"post-recording-review"}"#
            ))
        }
        if let beforeState,
           let afterState = try? await database.meetingState(id: session.id) {
            try? await database.recordMeetingVersion(
                meetingID: session.id,
                actor: .user,
                changeType: .meetingFactsUpdate,
                summary: "Updated meeting facts from context review.",
                before: BarnOwlMeetingVersionSnapshot(state: beforeState),
                after: BarnOwlMeetingVersionSnapshot(state: afterState)
            )
        }
    }

    private func applyPostRecordingReviewToDisplayedNote(
        _ review: BarnOwlPostRecordingContextReview,
        session: RecordingSession
    ) async throws {
        let store = try makeLibraryStore()
        let currentArtifact = try await store.artifact(id: session.id)
        let contextSection = Self.meetingFactsMarkdownSection(review.facts, session: session)

        if var artifact = currentArtifact {
            if artifact.session.title != session.title {
                if let renamed = try await store.updateSessionTitle(sessionID: session.id, title: session.title) {
                    artifact = renamed
                }
            }
            let updatedMarkdown = Self.markdownReplacingMeetingFacts(
                in: artifact.markdown,
                with: contextSection
            )
            guard let updated = try await store.updateMarkdown(sessionID: session.id, markdown: updatedMarkdown) else {
                return
            }
            displayedNote = BarnOwlDisplayedNote(
                id: updated.session.id,
                title: updated.session.title,
                startedAt: updated.session.startedAt,
                markdown: updated.markdown,
                meetingFacts: review.facts
            )
            noteDraft = updated.markdown
            noteTitleDraft = updated.session.title
            contextDraft = ""
            await writeArtifactToLocalContext(updated)
            await persistProcessedArtifact(sessionID: session.id)
        } else {
            await openRecentSession(session.id)
        }
    }

    func refreshRecentSessions() async {
        do {
            let database = try makeDatabase()
            let store = try makeLibraryStore()
            let states = try await database.meetingStates(limit: 100)
            var sessions: [BarnOwlRecentSession] = []
            for state in states {
                let artifact = try? await store.artifact(id: state.id)
                let markdownURL = if let artifact {
                    await store.markdownFileURL(for: artifact.session)
                } else {
                    store.rootDirectoryURL.appending(path: state.id.uuidString)
                }
                sessions.append(BarnOwlRecentSession(
                    id: state.id,
                    title: state.title,
                    startedAt: state.startedAt,
                    endedAt: state.endedAt,
                    markdownURL: markdownURL,
                    overview: Self.searchSnippet(
                        in: state.summary?.overview ?? (state.generatedNotes.isEmpty ? "Processing or waiting for notes." : state.generatedNotes),
                        query: ""
                    ),
                    processingTimeline: state.processingTimeline
                ))
            }
            recentSessions = sessions.sorted { ($0.endedAt ?? $0.startedAt) > ($1.endedAt ?? $1.startedAt) }
        } catch {
            do {
                let store = try makeLibraryStore()
                let artifacts = try await store.artifacts(limit: 100)
                var sessions: [BarnOwlRecentSession] = []
                for artifact in artifacts {
                    let markdownURL = await store.markdownFileURL(for: artifact.session)
                sessions.append(BarnOwlRecentSession(
                    id: artifact.session.id,
                    title: artifact.session.title,
                    startedAt: artifact.session.startedAt,
                    endedAt: artifact.session.endedAt,
                    markdownURL: markdownURL,
                    overview: artifact.summary.overview,
                    processingTimeline: [
                        .init(step: .recorded, status: .complete, startedAt: artifact.session.startedAt, completedAt: artifact.session.endedAt),
                        .init(step: .transcribing, status: .complete),
                        .init(step: .cleaningTranscript, status: .complete),
                        .init(step: .extractingFactsContext, status: .complete),
                        .init(step: .writingNotes, status: .complete),
                        .init(step: .exportingMarkdown, status: .complete),
                        .init(step: .indexingSearchable, status: .complete),
                        .init(step: .complete, status: .complete, completedAt: artifact.session.endedAt)
                    ]
                ))
                }
                recentSessions = sessions.sorted { ($0.endedAt ?? $0.startedAt) > ($1.endedAt ?? $1.startedAt) }
            } catch {
                recentSessions = []
            }
        }
    }

    func openRecentSession(_ id: UUID) async {
        do {
            let database = try makeDatabase()
            if let state = try await database.meetingState(id: id) {
                let markdown = state.generatedNotes.isEmpty
                    ? "No Markdown export has been generated yet."
                    : state.generatedNotes
                displayedNote = BarnOwlDisplayedNote(
                    id: state.id,
                    title: state.title,
                    startedAt: state.startedAt,
                    markdown: markdown,
                    meetingFacts: state.meetingFacts
                )
                noteDraft = markdown
                noteTitleDraft = state.title
                processingTimelineItems = state.processingTimeline
                await loadCalendarContext(for: state.id)
                await refreshContextInbox()
                await refreshMeetingHistory()
                noteActionStatus = "Opened \(state.title)."
                return
            }

            let store = try makeLibraryStore()
            if let artifact = try await store.artifact(id: id) {
                await persistProcessedArtifact(sessionID: id)
                displayedNote = BarnOwlDisplayedNote(
                    id: artifact.session.id,
                    title: artifact.session.title,
                    startedAt: artifact.session.startedAt,
                    markdown: artifact.markdown,
                    meetingFacts: Self.meetingFactsFromMarkdown(artifact.markdown)
                )
                noteDraft = artifact.markdown
                noteTitleDraft = artifact.session.title
                await refreshProcessingTimeline(meetingID: artifact.session.id)
                await loadCalendarContext(for: artifact.session.id)
                await refreshContextInbox()
                await refreshMeetingHistory()
                noteActionStatus = "Opened \(artifact.session.title)."
                return
            }
        } catch {
            recordActivity(
                level: .error,
                category: "library",
                message: "Could not open Barn Owl note.",
                details: BarnOwlErrorFormatter.message(for: error),
                sessionID: id,
                updatePreview: false
            )
        }
    }

    func searchNotes() async {
        let query = noteSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let meetingType = searchMeetingTypeFilter.trimmingCharacters(in: .whitespacesAndNewlines)
        let participant = searchParticipantFilter.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty || !meetingType.isEmpty || !participant.isEmpty || searchStatusFilter != nil else {
            noteSearchResults = []
            searchStatus = "Type to search notes."
            return
        }

        isSearchInFlight = true
        searchStatus = "Searching..."
        defer { isSearchInFlight = false }

        do {
            let database = try makeDatabase()
            let results = try await database.searchLibrary(BarnOwlDatabaseSearchQuery(
                text: query,
                meetingType: meetingType.isEmpty ? nil : meetingType,
                participant: participant.isEmpty ? nil : participant,
                status: searchStatusFilter,
                limit: 50
            ))
            noteSearchResults = results.map { result in
                return BarnOwlNoteSearchResult(
                    id: result.meeting.id,
                    title: result.meeting.title,
                    startedAt: result.meeting.startedAt ?? result.meeting.createdAt,
                    snippet: result.snippet,
                    meetingType: result.meetingType,
                    status: result.status
                )
            }
            searchStatus = noteSearchResults.isEmpty
                ? "No matches."
                : "\(noteSearchResults.count) result\(noteSearchResults.count == 1 ? "" : "s")."
            noteActionStatus = "Found \(noteSearchResults.count) matching note(s)."
        } catch {
            do {
                let store = try makeLibraryStore()
                let results = try await store.search(LocalLibrarySearchQuery(text: query, limit: 50))
                noteSearchResults = results.map { result in
                    BarnOwlNoteSearchResult(
                        id: result.session.id,
                        title: result.session.title,
                        startedAt: result.session.startedAt,
                        snippet: Self.searchSnippet(
                            in: result.artifact?.markdown ?? result.session.title,
                            query: query.lowercased()
                        ),
                        meetingType: nil,
                        status: nil
                    )
                }
                searchStatus = noteSearchResults.isEmpty
                    ? "No matches in Markdown fallback."
                    : "\(noteSearchResults.count) result\(noteSearchResults.count == 1 ? "" : "s") from Markdown fallback."
                noteActionStatus = "Found \(noteSearchResults.count) matching note(s) from Markdown fallback."
            } catch {
                noteSearchResults = []
                searchStatus = "Search failed."
                noteActionStatus = "Search failed: \(BarnOwlErrorFormatter.message(for: error))"
            }
        }
    }

    func saveDisplayedNoteDraft(
        actor: BarnOwlMeetingVersionActor = .user,
        changeType: BarnOwlMeetingVersionChangeType = .noteRewrite,
        summary: String = "Saved note edits."
    ) async {
        guard let displayedNote else {
            noteActionStatus = "Open a note before saving edits."
            return
        }

        do {
            let store = try makeLibraryStore()
            guard let artifact = try await store.updateMarkdown(sessionID: displayedNote.id, markdown: noteDraft) else {
                noteActionStatus = "Could not find the current note in the Barn Owl Library."
                return
            }
            self.displayedNote = BarnOwlDisplayedNote(
                id: artifact.session.id,
                title: artifact.session.title,
                startedAt: artifact.session.startedAt,
                markdown: noteDraft,
                meetingFacts: displayedNote.meetingFacts
            )
            if let database = try? makeDatabase() {
                _ = try? await database.updateMeetingStateNotes(
                    meetingID: displayedNote.id,
                    markdown: noteDraft,
                    actor: actor,
                    changeType: changeType,
                    summary: summary
                )
            }
            await recordMeetingExportSnapshotEvent(
                meetingID: displayedNote.id,
                type: .updated
            )
            await writeArtifactToLocalContext(artifact)
            await refreshMeetingHistory()
            noteActionStatus = "Saved note edits."
            await refreshRecentSessions()
        } catch {
            noteActionStatus = "Save failed: \(BarnOwlErrorFormatter.message(for: error))"
        }
    }

    func saveDisplayedMeetingTitle() async {
        guard let displayedNote else {
            noteActionStatus = "Open a note before renaming it."
            return
        }

        let title = noteTitleDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else {
            noteActionStatus = "Meeting title cannot be blank."
            return
        }

        do {
            let database = try makeDatabase()
            let updatedState = try await database.updateMeetingStateTitle(
                meetingID: displayedNote.id,
                title: title,
                actor: .user,
                summary: "Renamed meeting to \(title)."
            )
            let store = try makeLibraryStore()
            guard var artifact = try await store.updateSessionTitle(sessionID: displayedNote.id, title: title) else {
                noteActionStatus = "Could not find the current note in the Barn Owl Library."
                return
            }
            if let facts = updatedState?.meetingFacts {
                let synchronizedMarkdown = Self.markdownReplacingMeetingFacts(
                    in: artifact.markdown,
                    with: Self.meetingFactsMarkdownSection(facts, session: artifact.session)
                )
                artifact = try await store.updateMarkdown(sessionID: displayedNote.id, markdown: synchronizedMarkdown) ?? artifact
            }

            self.displayedNote = BarnOwlDisplayedNote(
                id: artifact.session.id,
                title: artifact.session.title,
                startedAt: artifact.session.startedAt,
                markdown: artifact.markdown,
                meetingFacts: updatedState?.meetingFacts ?? displayedNote.meetingFacts
            )
            noteTitleDraft = artifact.session.title
            noteDraft = artifact.markdown
            _ = try? await database.updateMeetingStateNotes(meetingID: displayedNote.id, markdown: artifact.markdown)
            await recordMeetingExportSnapshotEvent(
                meetingID: displayedNote.id,
                type: .updated
            )
            await writeArtifactToLocalContext(artifact, replacingTitle: displayedNote.title)
            await refreshMeetingHistory()
            noteActionStatus = "Renamed meeting to \(artifact.session.title)."
            await refreshRecentSessions()
        } catch {
            noteActionStatus = "Rename failed: \(BarnOwlErrorFormatter.message(for: error))"
        }
    }

    func deleteRecentSession(_ id: UUID) async {
        do {
            let store = try makeLibraryStore()
            try await store.deleteSession(id: id)

            if displayedNote?.id == id {
                displayedNote = nil
                noteDraft = ""
                noteTitleDraft = ""
                notePrompt = ""
                contextDraft = ""
                calendarContext = nil
                calendarContextAccepted = false
                calendarContextStatus = "Calendar context idle."
                contextInboxItems = []
                meetingHistoryItems = []
                historyStatus = ""
            }

            noteSearchResults.removeAll { $0.id == id }
            await deletePersistedMeeting(id)
            await BarnOwlAudioCaptureFactory.deleteTemporaryAudio(for: id)
            await refreshRecentSessions()
            await refreshContextInbox()
            noteActionStatus = "Deleted recording."
        } catch {
            noteActionStatus = "Delete failed: \(BarnOwlErrorFormatter.message(for: error))"
            recordActivity(
                level: .error,
                category: "library",
                message: "Could not delete Barn Owl recording.",
                details: BarnOwlErrorFormatter.message(for: error),
                sessionID: id,
                updatePreview: false
            )
        }
    }

    func deleteRecentSessions(_ ids: Set<UUID>) async {
        guard !ids.isEmpty else { return }
        var deletedCount = 0
        var lastFailure: String?

        for id in ids {
            do {
                let store = try makeLibraryStore()
                try await store.deleteSession(id: id)

                if displayedNote?.id == id {
                    displayedNote = nil
                    noteDraft = ""
                    noteTitleDraft = ""
                    notePrompt = ""
                    contextDraft = ""
                    calendarContext = nil
                    calendarContextAccepted = false
                    calendarContextStatus = "Calendar context idle."
                    contextInboxItems = []
                    meetingHistoryItems = []
                    historyStatus = ""
                }

                noteSearchResults.removeAll { $0.id == id }
                await deletePersistedMeeting(id)
                await BarnOwlAudioCaptureFactory.deleteTemporaryAudio(for: id)
                deletedCount += 1
            } catch {
                lastFailure = BarnOwlErrorFormatter.message(for: error)
                recordActivity(
                    level: .error,
                    category: "library",
                    message: "Could not delete selected Barn Owl recording.",
                    details: lastFailure,
                    sessionID: id,
                    updatePreview: false
                )
            }
        }

        await refreshRecentSessions()
        await refreshContextInbox()

        if let lastFailure, deletedCount == 0 {
            noteActionStatus = "Delete failed: \(lastFailure)"
        } else if let lastFailure {
            noteActionStatus = "Deleted \(deletedCount) recording\(deletedCount == 1 ? "" : "s"). Some deletes failed: \(lastFailure)"
        } else {
            noteActionStatus = "Deleted \(deletedCount) recording\(deletedCount == 1 ? "" : "s")."
        }
    }

    func exportRecentSessions(_ ids: Set<UUID>) async {
        guard !ids.isEmpty else { return }

        do {
            let store = try makeLibraryStore()
            let selected = recentSessions.filter { ids.contains($0.id) }
            guard !selected.isEmpty else {
                noteActionStatus = "No selected recordings were found."
                return
            }

            let destinationRoot = Self.bulkExportDirectoryURL()
            try FileManager.default.createDirectory(
                at: destinationRoot,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )

            var exportedURLs: [URL] = []
            for session in selected {
                let markdown: String
                if let artifact = try await store.artifact(id: session.id) {
                    markdown = artifact.markdown
                } else if FileManager.default.fileExists(atPath: session.markdownURL.path) {
                    markdown = try String(contentsOf: session.markdownURL, encoding: .utf8)
                } else {
                    continue
                }

                let filename = Self.safeExportFilename(title: session.title, id: session.id)
                let url = Self.uniqueExportURL(base: destinationRoot.appending(path: filename))
                try markdown.write(to: url, atomically: true, encoding: .utf8)
                exportedURLs.append(url)
            }

            if exportedURLs.isEmpty {
                noteActionStatus = "No Markdown notes were available to export."
                return
            }

            NSWorkspace.shared.activateFileViewerSelecting([destinationRoot])
            noteActionStatus = "Exported \(exportedURLs.count) note\(exportedURLs.count == 1 ? "" : "s")."
        } catch {
            noteActionStatus = "Export failed: \(BarnOwlErrorFormatter.message(for: error))"
        }
    }

    func appendContextToDisplayedNote() async {
        guard !isContextUpdateInFlight else {
            noteActionStatus = "Reading context..."
            return
        }
        let context = contextDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !context.isEmpty else {
            noteActionStatus = "Add context text before attaching it to the note."
            return
        }
        guard displayedNote != nil || activeSession != nil else {
            noteActionStatus = "Open or record a meeting before adding context."
            return
        }

        isContextUpdateInFlight = true
        contextReviewStatus = "Reading context..."
        defer { isContextUpdateInFlight = false }

        if let meetingID = displayedNote?.id ?? activeSession?.id {
            _ = await addExternalContext(
                context,
                source: "manual",
                meetingID: meetingID,
                state: .accepted,
                triggerNoteUpdate: displayedNote != nil
            )
        }

        contextDraft = ""
        contextReviewStatus = displayedNote == nil
            ? "Added context to the active recording."
            : "Added context and updated meeting facts."
        noteActionStatus = contextReviewStatus
    }

    @discardableResult
    func addExternalContext(
        _ body: String,
        source: String,
        meetingID requestedMeetingID: UUID? = nil,
        state: BarnOwlExternalContextState = .accepted,
        triggerNoteUpdate: Bool = true
    ) async -> BarnOwlExternalContextItemRecord? {
        let cleanedBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanedBody.isEmpty else {
            noteActionStatus = "Context was empty."
            return nil
        }

        let meetingID = requestedMeetingID ?? activeSession?.id ?? displayedNote?.id
        let now = Date()
        let item = BarnOwlExternalContextItemRecord(
            meetingID: meetingID,
            source: source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "cli" : source,
            body: cleanedBody,
            state: state,
            createdAt: now,
            updatedAt: now,
            metadataJSON: #"{"surface":"control-bridge"}"#
        )

        do {
            let database = try makeDatabase()
            let beforeState = if let meetingID {
                try? await database.meetingState(id: meetingID)
            } else {
                nil as BarnOwlMeetingState?
            }
            try await database.upsertExternalContextItem(item)
            if let meetingID,
               let beforeState,
               let afterState = try? await database.meetingState(id: meetingID) {
                try? await database.recordMeetingVersion(
                    meetingID: meetingID,
                    actor: source == "cli" || source == "codex" ? .codexAPI : .user,
                    changeType: .contextUpdate,
                    summary: "Attached context from \(item.source).",
                    before: BarnOwlMeetingVersionSnapshot(state: beforeState),
                    after: BarnOwlMeetingVersionSnapshot(state: afterState)
                )
            }
            recordActivity(
                category: "context",
                message: "External context attached.",
                details: "Source: \(item.source). Context saved without previewing private text in diagnostics.",
                sessionID: meetingID,
                updatePreview: false
            )
            await refreshContextInbox()
            await refreshMeetingHistory()
            if triggerNoteUpdate, let meetingID, state == .accepted {
                await applyAcceptedExternalContextToNote(meetingID: meetingID)
            }
            noteActionStatus = "Attached context from \(item.source)."
            return item
        } catch {
            noteActionStatus = "Could not attach context: \(BarnOwlErrorFormatter.message(for: error))"
            recordActivity(
                level: .warning,
                category: "context",
                message: "Could not save external context.",
                details: BarnOwlErrorFormatter.message(for: error),
                sessionID: meetingID,
                updatePreview: false
            )
            return nil
        }
    }

    func refreshContextInbox() async {
        do {
            let database = try makeDatabase()
            let scopeID = displayedNote?.id ?? activeSession?.id
            let items = if let scopeID {
                try await database.externalContextItems(meetingID: scopeID, limit: 60)
            } else {
                try await database.externalContextItems(limit: 60)
            }
            contextInboxItems = items.map {
                BarnOwlContextInboxItem(
                    id: $0.id,
                    meetingID: $0.meetingID,
                    source: $0.source,
                    body: $0.body,
                    state: $0.state,
                    createdAt: $0.createdAt
                )
            }
        } catch {
            contextInboxItems = []
        }
    }

    func refreshMeetingHistory() async {
        guard let meetingID = displayedNote?.id ?? activeSession?.id else {
            meetingHistoryItems = []
            historyStatus = "Open a meeting to see history."
            return
        }
        do {
            let database = try makeDatabase()
            meetingHistoryItems = try await database.meetingVersions(meetingID: meetingID, limit: 80)
                .map(BarnOwlMeetingHistoryItem.init(record:))
            historyStatus = meetingHistoryItems.isEmpty ? "No changes recorded yet." : "\(meetingHistoryItems.count) recorded change\(meetingHistoryItems.count == 1 ? "" : "s")."
        } catch {
            meetingHistoryItems = []
            historyStatus = "Could not load history: \(BarnOwlErrorFormatter.message(for: error))"
        }
    }

    func restoreMeetingHistoryItem(_ id: UUID) async {
        guard !isHistoryRestoreInFlight else {
            historyStatus = "Restoring version..."
            return
        }
        isHistoryRestoreInFlight = true
        historyStatus = "Restoring version..."
        defer { isHistoryRestoreInFlight = false }

        do {
            let database = try makeDatabase()
            guard let restored = try await database.restoreMeetingVersion(id: id, actor: .user) else {
                historyStatus = "Could not restore that version."
                await refreshMeetingHistory()
                return
            }

            if let store = try? makeLibraryStore() {
                _ = try? await store.updateSessionTitle(sessionID: restored.id, title: restored.title)
                if !restored.generatedNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                   let updated = try? await store.updateMarkdown(sessionID: restored.id, markdown: restored.generatedNotes) {
                    await writeArtifactToLocalContext(updated)
                    displayedNote = BarnOwlDisplayedNote(
                        id: updated.session.id,
                        title: updated.session.title,
                        startedAt: updated.session.startedAt,
                        markdown: updated.markdown,
                        meetingFacts: restored.meetingFacts
                    )
                } else if let artifact = try? await store.updateMarkdown(sessionID: restored.id, markdown: restored.generatedNotes) {
                    await writeArtifactToLocalContext(artifact)
                    displayedNote = BarnOwlDisplayedNote(
                        id: artifact.session.id,
                        title: artifact.session.title,
                        startedAt: artifact.session.startedAt,
                        markdown: artifact.markdown,
                        meetingFacts: restored.meetingFacts
                    )
                } else {
                    displayedNote = BarnOwlDisplayedNote(
                        id: restored.id,
                        title: restored.title,
                        startedAt: restored.startedAt,
                        markdown: restored.generatedNotes,
                        meetingFacts: restored.meetingFacts
                    )
                }
            } else {
                displayedNote = BarnOwlDisplayedNote(
                    id: restored.id,
                    title: restored.title,
                    startedAt: restored.startedAt,
                    markdown: restored.generatedNotes,
                    meetingFacts: restored.meetingFacts
                )
            }
            noteDraft = restored.generatedNotes
            noteTitleDraft = restored.title
            await refreshRecentSessions()
            await refreshMeetingHistory()
            historyStatus = "Restored previous version."
            noteActionStatus = "Restored previous version."
        } catch {
            historyStatus = "Restore failed: \(BarnOwlErrorFormatter.message(for: error))"
            noteActionStatus = historyStatus
        }
    }

    func setContextInboxItemState(_ id: UUID, state: BarnOwlExternalContextState) async {
        do {
            let database = try makeDatabase()
            guard var item = try await database.externalContextItem(id: id) else {
                noteActionStatus = "Context item no longer exists."
                await refreshContextInbox()
                return
            }
            let beforeState = if let meetingID = item.meetingID {
                try? await database.meetingState(id: meetingID)
            } else {
                nil as BarnOwlMeetingState?
            }
            item.state = state
            item.updatedAt = Date()
            try await database.upsertExternalContextItem(item)
            if let meetingID = item.meetingID,
               let beforeState,
               let afterState = try? await database.meetingState(id: meetingID) {
                try? await database.recordMeetingVersion(
                    meetingID: meetingID,
                    actor: .user,
                    changeType: .contextUpdate,
                    summary: "\(state == .accepted ? "Accepted" : "Ignored") context from \(item.source).",
                    before: BarnOwlMeetingVersionSnapshot(state: beforeState),
                    after: BarnOwlMeetingVersionSnapshot(state: afterState)
                )
            }
            await refreshContextInbox()
            await refreshMeetingHistory()
            if state == .accepted, let meetingID = item.meetingID {
                await applyAcceptedExternalContextToNote(meetingID: meetingID)
            }
            noteActionStatus = "\(state == .accepted ? "Accepted" : "Ignored") context."
        } catch {
            noteActionStatus = "Could not update context: \(BarnOwlErrorFormatter.message(for: error))"
        }
    }

    @discardableResult
    func setExternalContext(
        _ body: String,
        source: String,
        meetingID requestedMeetingID: UUID? = nil
    ) async -> BarnOwlExternalContextItemRecord? {
        let meetingID = requestedMeetingID ?? activeSession?.id ?? displayedNote?.id
        if let meetingID,
           let database = try? makeDatabase(),
           let existingItems = try? await database.externalContextItems(meetingID: meetingID, limit: 100) {
            for var item in existingItems where item.state == .accepted || item.state == .pending {
                item.state = .ignored
                item.updatedAt = Date()
                try? await database.upsertExternalContextItem(item)
            }
        }
        return await addExternalContext(body, source: source, meetingID: meetingID, state: .accepted)
    }

    func deleteContextInboxItem(_ id: UUID) async {
        do {
            let database = try makeDatabase()
            try await database.deleteExternalContextItem(id: id)
            await refreshContextInbox()
            noteActionStatus = "Deleted context item."
        } catch {
            noteActionStatus = "Could not delete context: \(BarnOwlErrorFormatter.message(for: error))"
        }
    }

    func setMeetingTitle(_ title: String, meetingID requestedMeetingID: UUID? = nil) async -> Bool {
        let cleanedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanedTitle.isEmpty else {
            noteActionStatus = "Meeting title cannot be blank."
            return false
        }
        let meetingID = requestedMeetingID ?? activeSession?.id ?? displayedNote?.id

        if let activeSession, meetingID == nil || activeSession.id == meetingID {
            var updated = activeSession
            updated.title = cleanedTitle
            self.activeSession = updated
            await persistSessionState(updated, status: .recording)
            await recordMeetingExportSnapshotEvent(
                meetingID: updated.id,
                type: .updated
            )
            noteTitleDraft = cleanedTitle
            noteActionStatus = "Set active meeting title to \(cleanedTitle)."
            return true
        }

        if displayedNote?.id == meetingID {
            noteTitleDraft = cleanedTitle
            await saveDisplayedMeetingTitle()
            return displayedNote?.title == cleanedTitle
        }

        guard let meetingID else {
            noteActionStatus = "No active or open meeting to rename."
            return false
        }

        do {
            let database = try makeDatabase()
            let previousTitle = try await database.meetingState(id: meetingID)?.title
            guard let updatedState = try await database.updateMeetingStateTitle(
                meetingID: meetingID,
                title: cleanedTitle,
                actor: .codexAPI,
                summary: "Renamed meeting to \(cleanedTitle)."
            ) else {
                noteActionStatus = "Could not find meeting to rename."
                return false
            }
            if let store = try? makeLibraryStore(),
               var artifact = try? await store.updateSessionTitle(sessionID: meetingID, title: cleanedTitle) {
                if let facts = updatedState.meetingFacts {
                    let synchronizedMarkdown = Self.markdownReplacingMeetingFacts(
                        in: artifact.markdown,
                        with: Self.meetingFactsMarkdownSection(facts, session: artifact.session)
                    )
                    artifact = try await store.updateMarkdown(sessionID: meetingID, markdown: synchronizedMarkdown) ?? artifact
                }
                _ = try? await database.updateMeetingStateNotes(meetingID: meetingID, markdown: artifact.markdown)
                await writeArtifactToLocalContext(artifact, replacingTitle: previousTitle)
            }
            await recordMeetingExportSnapshotEvent(
                meetingID: meetingID,
                type: .updated
            )
            await refreshRecentSessions()
            await refreshMeetingHistory()
            noteActionStatus = "Renamed meeting to \(cleanedTitle)."
            return true
        } catch {
            noteActionStatus = "Rename failed: \(BarnOwlErrorFormatter.message(for: error))"
            return false
        }
    }

    func setMeetingType(_ meetingType: String, meetingID: UUID? = nil) async -> Bool {
        let cleanedType = meetingType.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanedType.isEmpty else {
            noteActionStatus = "Meeting type cannot be blank."
            return false
        }
        _ = await addExternalContext(
            "Meeting type: \(cleanedType)",
            source: "cli",
            meetingID: meetingID,
            state: .accepted
        )
        return true
    }

    func updateDisplayedNoteWithPrompt(_ prompt: String, meetingID: UUID? = nil) async -> Bool {
        if let meetingID, displayedNote?.id != meetingID {
            await openRecentSession(meetingID)
        }
        notePrompt = prompt
        await applyPromptToDisplayedNote()
        return !notePrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !noteActionStatus.lowercased().contains("failed")
    }

    func acceptCalendarContext() async {
        guard let context = calendarContext else {
            calendarContextStatus = "No calendar match to accept."
            return
        }

        calendarContextAccepted = true
        calendarContextStatus = "Using calendar context: \(context.title)."

        if let meetingID = activeSession?.id ?? displayedNote?.id {
            await persistCalendarContext(context, meetingID: meetingID)
        }

        let lines = context.contextLines.joined(separator: "\n")
        if !contextDraft.contains(lines) {
            contextDraft = [contextDraft, lines]
                .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                .joined(separator: "\n")
        }
        noteActionStatus = "Accepted calendar context."
    }

    func ignoreCalendarContext() async {
        let meetingID = activeSession?.id ?? displayedNote?.id
        calendarContext = nil
        calendarContextAccepted = false
        calendarContextStatus = "Calendar context ignored."
        if let meetingID {
            await deletePersistedCalendarContext(meetingID: meetingID)
        }
    }

    func addCalendarContextToDisplayedNote() async {
        guard let context = calendarContext else {
            noteActionStatus = "No calendar context is available."
            return
        }
        guard displayedNote != nil else {
            noteActionStatus = "Open a note before adding calendar context."
            return
        }

        contextDraft = context.contextLines.joined(separator: "\n")
        await appendContextToDisplayedNote()
        if !calendarContextAccepted {
            await acceptCalendarContext()
        }
    }

    func purgeTemporaryAudioForDisplayedRecording() async {
        guard let id = activeSession?.id ?? displayedNote?.id else {
            noteActionStatus = "Open a recording before purging temporary audio."
            return
        }

        await BarnOwlAudioCaptureFactory.deleteTemporaryAudio(for: id)
        tempAudioByteCount = 0
        noteActionStatus = "Purged temporary audio for this recording."
        recordActivity(
            category: "retention",
            message: "Purged temporary audio.",
            sessionID: id,
            updatePreview: false
        )
        await recordMeetingExportTombstone(
            meetingID: id,
            type: .purged,
            reason: "temporary_audio_purged"
        )
    }

    func performLaunchRecovery() async {
        do {
            let database = try makeDatabase()
            let report = try await BarnOwlRecoveryCoordinator.recoverInterruptedWork(
                database: database,
                jobRunner: jobRunner
            )
            if report.recoveredWork {
                recordActivity(
                    level: report.needsAttention ? .warning : .info,
                    category: "recovery",
                    message: "Recovered interrupted Barn Owl work.",
                    details: [
                        report.recoveredRunningJobCount > 0 ? "\(report.recoveredRunningJobCount) interrupted job(s) made retryable" : nil,
                        report.recoveredInterruptedRecordingCount > 0 ? "\(report.recoveredInterruptedRecordingCount) interrupted recording(s) queued for processing" : nil,
                        report.pendingJobCount > 0 ? "\(report.pendingJobCount) job(s) ready to run" : nil,
                        report.incompleteRecordingCount > 0 ? "\(report.incompleteRecordingCount) recording(s) need attention" : nil
                    ]
                    .compactMap { $0 }
                    .joined(separator: "\n"),
                    updatePreview: false
                )
                noteActionStatus = report.needsAttention
                    ? "Recovered work. Some recordings need attention."
                    : "Recovered interrupted work and resumed processing."
                captureStatus = report.pendingJobCount > 0 ? "Recovered background work. Processing will resume." : captureStatus
            }
            await refreshRecoveryAttentionItems()
        } catch {
            recordActivity(
                level: .warning,
                category: "recovery",
                message: "Could not complete launch recovery.",
                details: BarnOwlErrorFormatter.message(for: error),
                updatePreview: false
            )
        }
    }

    func refreshJobSummaries() async {
        do {
            let database = try makeDatabase()
            let jobs = try await database.jobs(limit: 40)
            var summaries: [BarnOwlJobSummary] = []
            for job in jobs {
                let title: String
                if let meetingID = job.meetingID,
                   let meeting = try await database.meeting(id: meetingID) {
                    title = meeting.title
                } else {
                    title = "Barn Owl Job"
                }
                summaries.append(BarnOwlJobSummary(
                    id: job.id,
                    meetingID: job.meetingID,
                    title: title,
                    type: job.type,
                    status: job.status,
                    attemptCount: job.attemptCount,
                    errorMessage: job.errorMessage,
                    updatedAt: job.updatedAt
                ))
            }
            jobSummaries = summaries
            await refreshRecoveryAttentionItems()
            await refreshProcessingTimeline()
        } catch {
            jobSummaries = []
            recoveryAttentionItems = []
        }
    }

    func refreshProcessingTimeline(meetingID requestedMeetingID: UUID? = nil) async {
        let meetingID = requestedMeetingID ?? activeSession?.id ?? displayedNote?.id
        guard let meetingID else {
            processingTimelineItems = []
            return
        }
        do {
            let database = try makeDatabase()
            processingTimelineItems = try await database.meetingState(id: meetingID)?.processingTimeline ?? []
        } catch {
            processingTimelineItems = []
        }
    }

    func refreshRecoveryAttentionItems() async {
        do {
            let database = try makeDatabase()
            let failedJobs = try await database.jobs(status: .failed, limit: 50)
            var items: [BarnOwlRecoveryAttentionItem] = []
            var jobMeetingIDs = Set<UUID>()

            for job in failedJobs {
                let title: String
                if let meetingID = job.meetingID,
                   let meeting = try await database.meeting(id: meetingID) {
                    title = meeting.title
                    jobMeetingIDs.insert(meetingID)
                } else {
                    title = job.type.replacingOccurrences(of: "_", with: " ").capitalized
                }

                items.append(BarnOwlRecoveryAttentionItem(
                    id: job.id,
                    meetingID: job.meetingID,
                    jobID: job.id,
                    title: title,
                    message: Self.conciseRecoveryMessage(for: job),
                    details: job.errorMessage,
                    updatedAt: job.updatedAt
                ))
            }

            let states = try await database.meetingStates(limit: 100)
            for state in states where state.status == .failed
                && !jobMeetingIDs.contains(state.id)
                && !state.jobs.contains(where: { $0.type == BarnOwlJobType.finalProcessing && $0.status == .canceled }) {
                items.append(BarnOwlRecoveryAttentionItem(
                    id: state.id,
                    meetingID: state.id,
                    jobID: nil,
                    title: state.title,
                    message: "Recording is incomplete and needs review.",
                    details: "Barn Owl could not find a retryable background job for this recording.",
                    updatedAt: state.updatedAt
                ))
            }

            recoveryAttentionItems = items.sorted { $0.updatedAt > $1.updatedAt }
        } catch {
            recoveryAttentionItems = []
        }
    }

    func retryFailedJobs() async {
        do {
            let database = try makeDatabase()
            let retriedCount = try await BarnOwlRecoveryCoordinator.retryFailedJobs(database: database)
            await refreshJobSummaries()
            await refreshProcessingTimeline()
            startJobRunner()
            noteActionStatus = "Retrying \(retriedCount) failed job(s)."
        } catch {
            noteActionStatus = "Could not retry jobs: \(BarnOwlErrorFormatter.message(for: error))"
        }
    }

    func retryFailedJobs(ids: Set<UUID>) async {
        do {
            let database = try makeDatabase()
            let retriedCount = try await BarnOwlRecoveryCoordinator.retryFailedJobs(database: database, ids: ids)
            await refreshJobSummaries()
            await refreshProcessingTimeline()
            startJobRunner()
            noteActionStatus = retriedCount == 0 ? "No failed jobs were available to retry." : "Retrying \(retriedCount) failed job(s)."
        } catch {
            noteActionStatus = "Could not retry jobs: \(BarnOwlErrorFormatter.message(for: error))"
        }
    }

    func retryRecoveryAttentionItem(_ item: BarnOwlRecoveryAttentionItem) async {
        guard let jobID = item.jobID else {
            noteActionStatus = "This item cannot be retried automatically."
            return
        }
        do {
            let database = try makeDatabase()
            let retriedCount = try await BarnOwlRecoveryCoordinator.retryFailedJobs(database: database, ids: [jobID])
            await refreshJobSummaries()
            await refreshProcessingTimeline(meetingID: item.meetingID)
            startJobRunner()
            noteActionStatus = retriedCount == 0 ? "No failed job was available to retry." : "Retrying \(item.title)."
        } catch {
            noteActionStatus = "Could not retry \(item.title): \(BarnOwlErrorFormatter.message(for: error))"
        }
    }

    func dismissRecoveryAttentionItem(_ item: BarnOwlRecoveryAttentionItem) async {
        do {
            let database = try makeDatabase()
            if let jobID = item.jobID {
                try await BarnOwlRecoveryCoordinator.dismissFailedJob(id: jobID, database: database)
            } else if let meetingID = item.meetingID {
                let now = Date()
                try await database.upsertJob(BarnOwlJobRecord(
                    meetingID: meetingID,
                    type: BarnOwlJobType.finalProcessing,
                    status: .canceled,
                    errorMessage: "Recovery notice dismissed.",
                    createdAt: now,
                    updatedAt: now,
                    completedAt: now
                ))
            }
            await refreshJobSummaries()
            await refreshProcessingTimeline(meetingID: item.meetingID)
            noteActionStatus = "Dismissed \(item.title)."
        } catch {
            noteActionStatus = "Could not dismiss \(item.title): \(BarnOwlErrorFormatter.message(for: error))"
        }
    }

    func sendChatMessage() async {
        guard !isChatInFlight else {
            chatStatus = "Barn Owl is already thinking..."
            return
        }
        let question = chatDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else {
            chatStatus = "Type a question before sending."
            return
        }
        let configuration: OpenAIConfiguration
        do {
            configuration = try BarnOwlAPIKeyStore.makeConfiguration()
        } catch {
            chatStatus = "Add API key in Settings."
            return
        }

        chatDraft = ""
        lastFailedChatQuestion = nil
        chatStatus = "Thinking..."
        chatMessages.append(BarnOwlChatMessage(role: .user, text: question))
        let thinkingMessage = BarnOwlChatMessage(role: .assistant, text: "Thinking...")
        chatMessages.append(thinkingMessage)
        isChatInFlight = true
        defer { isChatInFlight = false }

        do {
            let startedAt = Date()
            let snippets = try await chatContextSnippets(for: question)
            let queryDuration = Date().timeIntervalSince(startedAt)
            recordActivity(
                category: "performance",
                message: "SQLite chat retrieval completed.",
                details: Self.formatDuration(queryDuration),
                sessionID: displayedNote?.id,
                updatePreview: false
            )
            guard !snippets.isEmpty else {
                replaceChatMessage(
                    id: thinkingMessage.id,
                    text: "I could not find relevant meeting notes, transcripts, or local context for that yet."
                )
                chatStatus = "No matching local context."
                return
            }

            let answer = try await OpenAIBarnOwlChatClient(configuration: configuration)
                .answer(question: question, snippets: snippets)
            replaceChatMessage(id: thinkingMessage.id, text: answer.answer)
            chatStatus = "Answered."
        } catch {
            chatDraft = question
            lastFailedChatQuestion = question
            replaceChatMessage(
                id: thinkingMessage.id,
                text: "Chat failed: \(BarnOwlErrorFormatter.message(for: error))"
            )
            chatStatus = "Chat failed. Retry is available."
        }
    }

    private func replaceChatMessage(id: UUID, text: String) {
        guard let index = chatMessages.firstIndex(where: { $0.id == id }) else {
            chatMessages.append(BarnOwlChatMessage(role: .assistant, text: text))
            return
        }
        chatMessages[index].text = text
        chatMessages[index].timestamp = Date()
    }

    func startJobRunner() {
        guard jobRunnerTask == nil else { return }
        jobRunnerTask = Task { [weak self] in
            guard let self else { return }
            await self.jobRunner.runAvailableJobs(
                progress: { [weak self] progress in
                    guard let self else { return }
                    if let sessionID = progress.sessionID ?? self.activeSession?.id ?? self.displayedNote?.id {
                        self.handleMeetingProcessingProgress(progress, sessionID: sessionID)
                    } else {
                        self.recordActivity(
                            level: progress.level,
                            category: progress.category,
                            message: progress.message,
                            details: progress.details,
                            updatePreview: false
                        )
                    }
                },
                onJobChanged: { [weak self] in
                    await self?.refreshJobSummaries()
                },
                onFinalProcessingSucceeded: { [weak self] session, markdownURL in
                    await self?.handleFinalProcessingSucceeded(session: session, markdownURL: markdownURL)
                },
                onFinalProcessingFailed: { [weak self] session, error, willRetry in
                    await self?.handleFinalProcessingFailed(session: session, error: error, willRetry: willRetry)
                }
            )
            self.jobRunnerTask = nil
            await self.refreshJobSummaries()
            await self.scheduleNextPendingJobWake()
        }
    }

    private func scheduleNextPendingJobWake() async {
        let nextScheduledAt: Date?
        do {
            let database = try makeDatabase()
            let pendingJobs = try await database.jobs(status: .pending, limit: 100)
            nextScheduledAt = pendingJobs.compactMap(\.scheduledAt).min()
        } catch {
            return
        }

        guard let nextScheduledAt else {
            jobRunnerWakeTask?.cancel()
            jobRunnerWakeTask = nil
            return
        }

        let delay = max(0.1, min(nextScheduledAt.timeIntervalSinceNow, 300))
        jobRunnerWakeTask?.cancel()
        jobRunnerWakeTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            if Task.isCancelled { return }
            await MainActor.run {
                self?.startJobRunner()
            }
        }
    }

    func applyPromptToDisplayedNote() async {
        guard !isNoteUpdateInFlight else {
            noteActionStatus = "Updating notes..."
            return
        }
        let prompt = notePrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else {
            noteActionStatus = "Add a prompt before asking Barn Owl to update the note."
            return
        }
        guard displayedNote != nil,
              !noteDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            noteActionStatus = "Open a note before updating."
            return
        }
        let configuration: OpenAIConfiguration
        do {
            configuration = try BarnOwlAPIKeyStore.makeConfiguration()
        } catch {
            noteActionStatus = "Add API key in Settings before updating notes."
            return
        }

        isNoteUpdateInFlight = true
        noteActionStatus = "Updating notes..."
        defer { isNoteUpdateInFlight = false }

        do {
            let client = OpenAINoteEditingClient(configuration: configuration)
            let result = try await client.updateNoteDraft(
                markdown: noteDraft,
                prompt: prompt,
                context: contextDraft
            )
            let updatedMarkdown = result.markdown
            let updatedTitle = result.title ?? Self.topLevelMarkdownTitle(in: updatedMarkdown)

            noteDraft = updatedMarkdown
            notePrompt = ""
            noteActionStatus = "Updated note draft. Saving..."
            await saveDisplayedNoteDraft(
                actor: .ai,
                changeType: .promptUpdate,
                summary: "Updated notes from prompt: \(String(prompt.prefix(120)))"
            )

            if let updatedTitle,
               updatedTitle.caseInsensitiveCompare(noteTitleDraft) != .orderedSame {
                noteTitleDraft = updatedTitle
                await saveDisplayedMeetingTitle()
                noteActionStatus = "Updated notes and renamed meeting to \(updatedTitle)."
            } else {
                noteActionStatus = "Updated notes."
            }
        } catch {
            noteActionStatus = "Prompt failed: \(BarnOwlErrorFormatter.message(for: error))"
        }
    }

    func openDisplayedMarkdownInFinder() async {
        guard let displayedNote else {
            openLibraryInFinder()
            return
        }

        do {
            let store = try makeLibraryStore()
            if let markdownURL = try await store.markdownFileURL(forSessionID: displayedNote.id) {
                NSWorkspace.shared.activateFileViewerSelecting([markdownURL])
                noteActionStatus = "Revealed Markdown file in Finder."
            } else {
                openLibraryInFinder()
            }
        } catch {
            noteActionStatus = "Could not reveal Markdown file: \(BarnOwlErrorFormatter.message(for: error))"
        }
    }

    func openLibraryInFinder() {
        do {
            let store = try makeLibraryStore()
            let libraryURL = store.rootDirectoryURL
            NSWorkspace.shared.open(libraryURL)
            noteActionStatus = "Opened Barn Owl Library in Finder."
        } catch {
            noteActionStatus = "Could not open Barn Owl Library: \(BarnOwlErrorFormatter.message(for: error))"
        }
    }

    func controlStatusResponse(
        ok: Bool = true,
        message: String,
        contextItemID: UUID? = nil,
        current: BarnOwlControlMeeting? = nil,
        meeting: BarnOwlControlMeeting? = nil,
        meetings: [BarnOwlControlMeeting]? = nil,
        jobs: [BarnOwlControlJob]? = nil,
        enrichmentSources: [BarnOwlControlEnrichmentSource]? = nil,
        enrichmentSourcePresets: [BarnOwlControlEnrichmentSourcePreset]? = nil,
        enrichmentAuthorityProfiles: [BarnOwlControlEnrichmentAuthorityProfile]? = nil,
        enrichmentPolicyPacks: [BarnOwlControlEnrichmentPolicyPack]? = nil,
        enrichmentJobs: [BarnOwlControlEnrichmentJob]? = nil,
        enrichmentEvidence: [BarnOwlEnrichmentEvidenceRecord]? = nil,
        enrichmentConflicts: [BarnOwlControlEnrichmentConflict]? = nil,
        enrichmentConceptHistories: [BarnOwlControlEnrichmentConceptHistory]? = nil,
        knowledgeEntities: [BarnOwlControlKnowledgeEntity]? = nil,
        meetingEvidence: BarnOwlMeetingEvidenceEnvelope? = nil,
        meetingEvidenceBatch: BarnOwlMeetingEvidenceBatch? = nil,
        meetingExportEventBatch: BarnOwlMeetingExportEventBatch? = nil,
        transcript: String? = nil,
        notes: String? = nil,
        summary: String? = nil,
        contextItems: [BarnOwlControlContextItem]? = nil,
        actions: [String]? = nil,
        decisions: [String]? = nil,
        participants: [String]? = nil,
        answer: String? = nil,
        citations: [BarnOwlControlCitation]? = nil,
        activeMeetingID: UUID? = nil,
        liveTranscriptPreview: String? = nil,
        jobState: String? = nil,
        notesReady: Bool? = nil,
        transcriptReady: Bool? = nil,
        summaryReady: Bool? = nil,
        markdownPath: String? = nil,
        diagnosticsPath: String? = nil,
        nextCommand: String? = nil,
        errorCode: String? = nil,
        error: String? = nil
    ) -> BarnOwlControlResponse {
        publishRecordingReadinessSummary()
        let resolvedActiveMeetingID = activeMeetingID ?? activeSession?.id ?? displayedNote?.id
        let apiKeyConfigured = BarnOwlAPIKeyStore.hasConfiguredAPIKey()
        let apiKeyVerified = BarnOwlAPIKeyStore.hasVerifiedAPIKey()
        let firstRunReadiness = BarnOwlFirstRunReadiness.currentSnapshot(
            hasConfiguredAPIKey: apiKeyConfigured,
            hasVerifiedAPIKey: apiKeyVerified
        )
        let readinessState = status == .idle
            ? firstRunReadiness.overallState.rawValue
            : String(describing: recordingReadinessSummary.state)
        let sanitizedLastError = Self.sanitizedControlString(lastError)
        let sanitizedError = Self.sanitizedControlString(error)
        let resolvedErrorCode = errorCode ?? sanitizedError
        let shouldSuggestFeedback = Self.shouldSuggestSlackFeedback(
            ok: ok,
            errorCode: resolvedErrorCode,
            error: sanitizedError,
            lastError: sanitizedLastError,
            jobState: jobState
        )
        return BarnOwlControlResponse(
            ok: ok,
            message: message,
            status: lifecyclePresentation.title,
            appStatus: "running",
            bridgeStatus: "running",
            recordingStatus: status.rawValue,
            sessionID: activeSession?.id,
            meetingID: resolvedActiveMeetingID,
            activeMeetingID: resolvedActiveMeetingID,
            title: activeSession?.title ?? displayedNote?.title,
            meetingType: Self.markdownMeetingType(in: noteDraft),
            realtimeStatus: Self.sanitizedControlString(realtimeStatus),
            finalTranscriptionStatus: Self.sanitizedControlString(finalTranscriptionStatus),
            captureStatus: Self.sanitizedControlString(captureStatus),
            liveTranscriptPreview: liveTranscriptPreview,
            contextItemID: contextItemID,
            current: current,
            meeting: meeting,
            meetings: meetings,
            jobs: jobs,
            enrichmentSources: enrichmentSources,
            enrichmentSourcePresets: enrichmentSourcePresets,
            enrichmentAuthorityProfiles: enrichmentAuthorityProfiles,
            enrichmentPolicyPacks: enrichmentPolicyPacks,
            enrichmentJobs: enrichmentJobs,
            enrichmentEvidence: enrichmentEvidence,
            enrichmentConflicts: enrichmentConflicts,
            enrichmentConceptHistories: enrichmentConceptHistories,
            knowledgeEntities: knowledgeEntities,
            meetingEvidence: meetingEvidence,
            meetingEvidenceBatch: meetingEvidenceBatch,
            meetingExportEventBatch: meetingExportEventBatch,
            transcript: transcript,
            notes: notes,
            summary: summary,
            contextItems: contextItems,
            actions: actions,
            decisions: decisions,
            participants: participants,
            answer: answer,
            citations: citations,
            jobState: jobState,
            readinessState: readinessState,
            setupReady: !firstRunReadiness.menuBarSetupNeeded,
            apiKeyConfigured: apiKeyConfigured,
            apiKeyVerified: apiKeyVerified,
            notesReady: notesReady ?? notes.map { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty },
            transcriptReady: transcriptReady ?? transcript.map { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty },
            summaryReady: summaryReady ?? summary.map { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty },
            markdownPath: markdownPath,
            diagnosticsPath: diagnosticsPath,
            lastError: sanitizedLastError,
            nextCommand: nextCommand,
            feedbackSuggested: shouldSuggestFeedback ? true : nil,
            feedbackCommand: shouldSuggestFeedback ? Self.slackFeedbackDraftCommand : nil,
            feedbackPostCommand: shouldSuggestFeedback ? Self.slackFeedbackPostCommand : nil,
            feedbackReason: shouldSuggestFeedback ? "This Barn Owl command hit a reportable error. Draft a redacted Slack report, review it, then post only after explicit confirmation." : nil,
            errorCode: resolvedErrorCode,
            error: sanitizedError
        )
    }

    nonisolated static let defaultFeedbackOwnerUsername = "burdick"
    nonisolated static let slackFeedbackDraftCommand = "barnowl feedback slack"
    nonisolated static let slackFeedbackPostCommand = "barnowl feedback slack --yes"
    nonisolated static let nonReportableFeedbackErrorCodes: Set<String> = [
        "confirmation_required",
        "context_item_not_found",
        "meeting_not_found",
        "missing_context",
        "missing_context_item_id",
        "missing_authority_profile_id",
        "missing_description",
        "missing_display_name",
        "missing_job_id",
        "missing_knowledge_entity_id",
        "missing_meeting_id",
        "missing_meeting_type",
        "missing_policy_pack_id",
        "missing_preset_id",
        "missing_prompt",
        "missing_query",
        "missing_question",
        "missing_source_display_name",
        "missing_source_id",
        "missing_source_type",
        "knowledge_source_unavailable",
        "missing_title",
        "no_active_recording",
        "no_context",
        "invalid_source_scope",
        "enrichment_source_not_found",
        "enrichment_policy_pack_not_found",
        "enrichment_source_preset_not_found",
        "knowledge_entity_not_found",
        "unsupported_quick_command"
    ]

    nonisolated static let enrichmentSourcePresets: [BarnOwlControlEnrichmentSourcePreset] = [
        BarnOwlControlEnrichmentSourcePreset(
            id: "google_drive_reference",
            displayName: "Google Drive Reference",
            sourceType: "private_reference",
            scope: BarnOwlEnrichmentSourceScope.personalPrivate.rawValue,
            scopeLabel: BarnOwlEnrichmentSourceScope.personalPrivate.displayName,
            authorityProfile: "private_internal_reference",
            connectorReference: "google-drive",
            bestUsedFor: ["project briefs", "glossaries", "people context", "internal terminology"],
            defaultAuthState: BarnOwlEnrichmentSourceAuthState.needsAuthentication.rawValue,
            defaultHealthStatus: BarnOwlEnrichmentSourceHealthStatus.needsAuth.rawValue,
            privacyCopyPolicy: "summary_or_pointer_only",
            queryBudgetPolicy: "connector_policy_controlled"
        ),
        BarnOwlControlEnrichmentSourcePreset(
            id: "slack_reference",
            displayName: "Slack Reference",
            sourceType: "private_reference",
            scope: BarnOwlEnrichmentSourceScope.workspacePrivate.rawValue,
            scopeLabel: BarnOwlEnrichmentSourceScope.workspacePrivate.displayName,
            authorityProfile: "private_internal_reference",
            connectorReference: "slack",
            bestUsedFor: ["project aliases", "recent coordination", "team terminology"],
            defaultAuthState: BarnOwlEnrichmentSourceAuthState.needsAuthentication.rawValue,
            defaultHealthStatus: BarnOwlEnrichmentSourceHealthStatus.needsAuth.rawValue,
            privacyCopyPolicy: "summary_or_pointer_only",
            queryBudgetPolicy: "connector_policy_controlled"
        ),
        BarnOwlControlEnrichmentSourcePreset(
            id: "notion_reference",
            displayName: "Notion Reference",
            sourceType: "private_reference",
            scope: BarnOwlEnrichmentSourceScope.workspacePrivate.rawValue,
            scopeLabel: BarnOwlEnrichmentSourceScope.workspacePrivate.displayName,
            authorityProfile: "private_internal_reference",
            connectorReference: "notion",
            bestUsedFor: ["project records", "customer/account context", "internal playbooks"],
            defaultAuthState: BarnOwlEnrichmentSourceAuthState.needsAuthentication.rawValue,
            defaultHealthStatus: BarnOwlEnrichmentSourceHealthStatus.needsAuth.rawValue,
            privacyCopyPolicy: "summary_or_pointer_only",
            queryBudgetPolicy: "connector_policy_controlled"
        ),
        BarnOwlControlEnrichmentSourcePreset(
            id: "salesforce_reference",
            displayName: "Salesforce Reference",
            sourceType: "private_reference",
            scope: BarnOwlEnrichmentSourceScope.organizationScoped.rawValue,
            scopeLabel: BarnOwlEnrichmentSourceScope.organizationScoped.displayName,
            authorityProfile: "private_internal_reference",
            connectorReference: "salesforce",
            bestUsedFor: ["accounts", "customers", "opportunities", "company context"],
            defaultAuthState: BarnOwlEnrichmentSourceAuthState.needsAuthentication.rawValue,
            defaultHealthStatus: BarnOwlEnrichmentSourceHealthStatus.needsAuth.rawValue,
            privacyCopyPolicy: "summary_or_pointer_only",
            queryBudgetPolicy: "connector_policy_controlled"
        )
    ]

    nonisolated static func shouldSuggestSlackFeedback(
        ok: Bool,
        errorCode: String?,
        error: String?,
        lastError: String?,
        jobState: String?,
        currentUsername: String = NSUserName(),
        ownerUsername: String = ProcessInfo.processInfo.environment["BARNOWL_FEEDBACK_OWNER_USERNAME"] ?? defaultFeedbackOwnerUsername
    ) -> Bool {
        let current = currentUsername.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let owner = ownerUsername.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !owner.isEmpty, current == owner {
            return false
        }

        let hasFailureState = jobState == "failed"
        let normalizedErrorCode = errorCode?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let hasErrorCode = !(normalizedErrorCode?.isEmpty ?? true)
        let hasReportableErrorCode = normalizedErrorCode.map { !nonReportableFeedbackErrorCodes.contains($0) } ?? false
        let hasError = !(error?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        let hasLastError = !(lastError?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        return hasFailureState || hasLastError || ((hasError || hasErrorCode) && hasReportableErrorCode) || (ok == false && !hasErrorCode)
    }

    private static func sanitizedControlString(_ value: String?) -> String? {
        guard let value else { return nil }
        return BarnOwlErrorFormatter.sanitizeForUserDisplay(value)
    }

    private static func bulkExportDirectoryURL(now: Date = Date()) -> URL {
        let base = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return base.appending(path: "Barn Owl Export \(formatter.string(from: now))", directoryHint: .isDirectory)
    }

    private static func safeExportFilename(title: String, id: UUID) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " -_"))
        let scalars = title.unicodeScalars.map { scalar -> Character in
            allowed.contains(scalar) ? Character(scalar) : "-"
        }
        let collapsed = String(scalars)
            .replacingOccurrences(of: #"-{2,}"#, with: "-", options: .regularExpression)
            .replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: " -_"))
        let basename = collapsed.isEmpty ? "untitled-meeting" : String(collapsed.prefix(80))
        return "\(basename)-\(id.uuidString.prefix(8)).md"
    }

    private static func uniqueExportURL(base: URL) -> URL {
        guard FileManager.default.fileExists(atPath: base.path) else { return base }
        let directory = base.deletingLastPathComponent()
        let basename = base.deletingPathExtension().lastPathComponent
        let pathExtension = base.pathExtension
        var index = 2
        while true {
            let candidate = directory.appending(path: "\(basename)-\(index).\(pathExtension)")
            if !FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
            index += 1
        }
    }

    func recordExternalCommand(_ message: String) {
        recordActivity(
            category: "control-bridge",
            message: message,
            sessionID: activeSession?.id ?? displayedNote?.id,
            updatePreview: false
        )
    }

    @discardableResult
    func handleQuickCommand(_ command: BarnOwlQuickCommand) async -> BarnOwlControlResponse {
        switch command.name {
        case .startRecording:
            let wasAlreadyRecording = status == .recording
            if canStartRecording {
                let audioSources = command.capturesSystemAudio.map {
                    AudioSourceConfiguration(capturesMicrophone: true, capturesSystemAudio: $0)
                }
                await startRecording(audioSources: audioSources)
            }
            let meetingID = activeSession?.id ?? command.meetingID
            if let title = command.title?.trimmingCharacters(in: .whitespacesAndNewlines),
               !title.isEmpty {
                _ = await setMeetingTitle(title, meetingID: meetingID)
            }
            if let meetingType = command.meetingType?.trimmingCharacters(in: .whitespacesAndNewlines),
               !meetingType.isEmpty {
                _ = await setMeetingType(meetingType, meetingID: meetingID)
            }
            if let context = command.context?.trimmingCharacters(in: .whitespacesAndNewlines),
               !context.isEmpty {
                let source = command.source ?? "quick-command"
                let contextMeetingID = activeSession?.id ?? meetingID
                Task { [weak self] in
                    _ = await self?.addExternalContext(
                        context,
                        source: source,
                        meetingID: contextMeetingID,
                        state: .accepted,
                        triggerNoteUpdate: false
                    )
                }
            }
            let activeMeetingID = activeSession?.id ?? meetingID
            let message = if status == .recording {
                wasAlreadyRecording ? "Recording is already running." : "Recording started."
            } else {
                captureStatus
            }
            return controlStatusResponse(
                ok: status == .recording,
                message: message,
                activeMeetingID: activeMeetingID,
                jobState: await controlJobState(for: activeMeetingID),
                errorCode: status == .recording ? nil : "recording_not_started"
            )

        case .stopRecording:
            let meetingID = activeSession?.id ?? command.meetingID
            guard status == .recording || activeSession != nil else {
                return controlStatusResponse(
                    ok: false,
                    message: "No active recording to stop.",
                    activeMeetingID: meetingID,
                    errorCode: "no_active_recording"
                )
            }
            await stopRecording()
            return controlStatusResponse(
                message: "Stop recording requested.",
                activeMeetingID: meetingID,
                jobState: await controlJobState(for: meetingID)
            )

        case .addContext:
            guard let context = command.context?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !context.isEmpty else {
                return controlStatusResponse(ok: false, message: "add_context requires context.", error: "missing_context")
            }
            guard let meetingID = await resolveQuickCommandMeetingID(command.meetingID) else {
                return controlStatusResponse(ok: false, message: "No meeting found for context.", error: "meeting_not_found")
            }
            let item = await addExternalContext(
                context,
                source: command.source ?? "quick-command",
                meetingID: meetingID,
                state: .accepted
            )
            return controlStatusResponse(
                ok: item != nil,
                message: item == nil ? "Context was not attached." : "Context attached.",
                contextItemID: item?.id,
                activeMeetingID: meetingID,
                jobState: await controlJobState(for: meetingID),
                errorCode: item == nil ? "context_not_attached" : nil
            )

        case .renameMeeting:
            guard let title = command.title?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !title.isEmpty else {
                return controlStatusResponse(ok: false, message: "rename_meeting requires title.", error: "missing_title")
            }
            guard let meetingID = await resolveQuickCommandMeetingID(command.meetingID) else {
                return controlStatusResponse(ok: false, message: "No meeting found to rename.", error: "meeting_not_found")
            }
            let ok = await setMeetingTitle(title, meetingID: meetingID)
            return controlStatusResponse(
                ok: ok,
                message: ok ? "Meeting renamed." : noteActionStatus,
                activeMeetingID: meetingID,
                jobState: await controlJobState(for: meetingID),
                errorCode: ok ? nil : "rename_failed"
            )

        case .askNotes:
            guard let question = command.question?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !question.isEmpty else {
                return controlStatusResponse(ok: false, message: "ask_notes requires a question.", error: "missing_question")
            }
            return await controlAskNotesResponse(question: question, meetingID: command.meetingID)

        case .openLatestMeeting:
            guard let meetingID = await resolveQuickCommandMeetingID(command.meetingID, includeDisplayedNote: true) else {
                return controlStatusResponse(ok: false, message: "No Barn Owl meetings found.", error: "meeting_not_found")
            }
            await openRecentSession(meetingID)
            return controlStatusResponse(
                message: "Opened latest Barn Owl meeting.",
                activeMeetingID: meetingID,
                jobState: await controlJobState(for: meetingID)
            )
        }
    }

    func openLatestMeetingFromQuickAction() async {
        _ = await handleQuickCommand(BarnOwlQuickCommand(name: .openLatestMeeting))
    }

    private func resolveQuickCommandMeetingID(
        _ requestedMeetingID: UUID?,
        includeDisplayedNote: Bool = true
    ) async -> UUID? {
        if let requestedMeetingID {
            if activeSession?.id == requestedMeetingID || displayedNote?.id == requestedMeetingID {
                return requestedMeetingID
            }
            if let database = try? makeDatabase(),
               (try? await database.meeting(id: requestedMeetingID)) != nil {
                return requestedMeetingID
            }
            return nil
        }

        if let activeSession {
            return activeSession.id
        }

        if includeDisplayedNote, let displayedNote {
            return displayedNote.id
        }

        guard let database = try? makeDatabase() else {
            return nil
        }
        let states = (try? await database.meetingStates(limit: 50)) ?? []
        return states.first { $0.status == .completed }?.id ?? states.first?.id
    }

    private func controlJobState(for meetingID: UUID?) async -> String? {
        guard let meetingID,
              let database = try? makeDatabase(),
              let state = try? await database.meetingState(id: meetingID) else {
            return nil
        }
        let jobs = state.jobs.sorted { $0.updatedAt > $1.updatedAt }
        if jobs.contains(where: { $0.status == .failed }) {
            return "failed"
        }
        if jobs.contains(where: { $0.status == .running }) {
            return "running"
        }
        if jobs.contains(where: { $0.status == .pending }) {
            return "queued"
        }
        if jobs.contains(where: { $0.status == .succeeded }) || state.status == .completed {
            return "complete"
        }
        return state.status?.rawValue
    }

    private func controlLatestMeetingID(database: BarnOwlDatabase) async -> UUID? {
        if let activeSession {
            return activeSession.id
        }
        if let displayedNote {
            return displayedNote.id
        }
        return try? await database.meetingStates(limit: 1).first?.id
    }

    private func seedDefaultEnrichmentSources() async {
        guard let database = try? makeDatabase() else { return }
        try? await database.seedDefaultEnrichmentSources(ownerID: currentEnrichmentOwnerID())
    }

    private func controlState(
        meetingID requestedMeetingID: UUID?,
        latest: Bool = false
    ) async -> BarnOwlMeetingState? {
        guard let database = try? makeDatabase() else { return nil }
        let meetingID: UUID?
        if latest {
            meetingID = await controlLatestMeetingID(database: database)
        } else {
            meetingID = requestedMeetingID ?? activeSession?.id ?? displayedNote?.id
        }
        guard let meetingID else { return nil }
        return try? await database.meetingState(id: meetingID)
    }

    private func controlArtifactReadiness(for state: BarnOwlMeetingState?) -> (
        notesReady: Bool,
        transcriptReady: Bool,
        summaryReady: Bool
    ) {
        guard let state else {
            return (false, false, false)
        }
        let notesReady = !state.generatedNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let transcriptReady = !state.transcriptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let summaryReady = state.summary?.overview.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        return (notesReady, transcriptReady, summaryReady)
    }

    private func controlNextCommand(
        meetingID: UUID?,
        jobState: String?,
        readiness: (notesReady: Bool, transcriptReady: Bool, summaryReady: Bool)
    ) -> String {
        if !BarnOwlAPIKeyStore.hasConfiguredAPIKey() {
            return "Open Barn Owl Settings and add an OpenAI API key."
        }
        if status == .recording {
            return "barnowl stop"
        }
        if let meetingID, jobState == "failed" {
            return "barnowl jobs retry --session \(meetingID.uuidString)"
        }
        if let meetingID, jobState == "running" || jobState == "queued" {
            return "barnowl wait --session \(meetingID.uuidString) --until complete --timeout 10m"
        }
        if let meetingID, readiness.notesReady {
            return "barnowl meeting notes \(meetingID.uuidString) --format markdown"
        }
        return "barnowl start"
    }

    func controlCodexStatusResponse() async -> BarnOwlControlResponse {
        let state = await controlState(meetingID: nil, latest: true)
        let meetingID = activeSession?.id ?? displayedNote?.id ?? state?.id
        let readiness = controlArtifactReadiness(for: state)
        let jobState = await controlJobState(for: meetingID)
        return controlStatusResponse(
            message: "Barn Owl status.",
            activeMeetingID: activeSession?.id ?? meetingID,
            jobState: jobState,
            notesReady: readiness.notesReady,
            transcriptReady: readiness.transcriptReady,
            summaryReady: readiness.summaryReady,
            nextCommand: controlNextCommand(meetingID: meetingID, jobState: jobState, readiness: readiness)
        )
    }

    func controlWaitSnapshotResponse(
        meetingID requestedMeetingID: UUID?,
        latest: Bool,
        until: String
    ) async -> BarnOwlControlResponse {
        let state = await controlState(meetingID: requestedMeetingID, latest: latest)
        let meetingID = state?.id ?? requestedMeetingID ?? activeSession?.id
        let readiness = controlArtifactReadiness(for: state)
        let jobState = await controlJobState(for: meetingID)
        let normalizedUntil = until.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let stopped = activeSession?.id != meetingID || status != .recording
        let complete = jobState == "complete" && readiness.notesReady
        let satisfied = switch normalizedUntil {
        case "stopped":
            stopped
        case "notes":
            readiness.notesReady
        case "complete":
            complete
        default:
            false
        }

        let terminalFailure = jobState == "failed" || state?.status == .failed || status == .failed
        let message: String
        if satisfied {
            message = "Wait condition satisfied: \(normalizedUntil)."
        } else if terminalFailure {
            message = "Wait stopped because Barn Owl reached a failed state."
        } else {
            message = "Waiting for Barn Owl: \(normalizedUntil)."
        }

        return controlStatusResponse(
            ok: !terminalFailure && (state != nil || activeSession != nil),
            message: message,
            activeMeetingID: meetingID,
            jobState: jobState,
            notesReady: readiness.notesReady,
            transcriptReady: readiness.transcriptReady,
            summaryReady: readiness.summaryReady,
            nextCommand: controlNextCommand(meetingID: meetingID, jobState: jobState, readiness: readiness),
            errorCode: terminalFailure ? "terminal_failure" : (state == nil && activeSession == nil ? "meeting_not_found" : nil),
            error: terminalFailure ? lastError : nil
        )
    }

    func controlJobsListResponse(meetingID: UUID? = nil) async -> BarnOwlControlResponse {
        do {
            let database = try makeDatabase()
            let jobs = try await database.jobs(meetingID: meetingID, limit: 100).map(controlJob(from:))
            return controlStatusResponse(
                message: jobs.isEmpty ? "No Barn Owl jobs found." : "Barn Owl jobs.",
                jobs: jobs,
                activeMeetingID: meetingID,
                jobState: await controlJobState(for: meetingID)
            )
        } catch {
            return controlStatusResponse(ok: false, message: "Could not load jobs.", error: BarnOwlErrorFormatter.message(for: error))
        }
    }

    func controlJobsRetryResponse(meetingID: UUID? = nil, jobID: UUID? = nil) async -> BarnOwlControlResponse {
        do {
            let database = try makeDatabase()
            let retryIDs: Set<UUID>? = if let jobID {
                Set([jobID])
            } else if let meetingID {
                Set(try await database.jobs(status: .failed, meetingID: meetingID, limit: 100).map(\.id))
            } else {
                nil
            }
            let retriedCount = try await BarnOwlRecoveryCoordinator.retryFailedJobs(database: database, ids: retryIDs)
            await refreshJobSummaries()
            await refreshProcessingTimeline(meetingID: meetingID)
            startJobRunner()
            let jobs = try await database.jobs(meetingID: meetingID, limit: 100).map(controlJob(from:))
            return controlStatusResponse(
                message: retriedCount == 0 ? "No failed jobs were available to retry." : "Retrying \(retriedCount) failed job(s).",
                jobs: jobs,
                activeMeetingID: meetingID,
                jobState: await controlJobState(for: meetingID),
                nextCommand: meetingID.map { "barnowl wait --session \($0.uuidString) --until complete --timeout 10m" }
            )
        } catch {
            return controlStatusResponse(ok: false, message: "Could not retry jobs.", error: BarnOwlErrorFormatter.message(for: error))
        }
    }

    func controlSummariesRetryResponse(meetingID: UUID? = nil, all: Bool = false) async -> BarnOwlControlResponse {
        do {
            let database = try makeDatabase()
            let targetMeetingIDs: [UUID]
            if let meetingID {
                targetMeetingIDs = [meetingID]
            } else if all {
                let states = try await database.meetingStates(limit: 500)
                targetMeetingIDs = states
                    .filter { state in
                        state.summary?.overview.contains(Self.summaryFallbackMarker) == true
                            || state.generatedNotes.contains(Self.summaryFallbackMarker)
                    }
                    .map(\.id)
            } else {
                return controlStatusResponse(
                    ok: false,
                    message: "summaries_retry requires a meeting ID or --all.",
                    error: "missing_meeting_id"
                )
            }

            var queuedCount = 0
            for targetMeetingID in targetMeetingIDs {
                _ = try await jobRunner.enqueueSummaryProcessing(meetingID: targetMeetingID)
                queuedCount += 1
            }
            await refreshJobSummaries()
            if let meetingID {
                await refreshProcessingTimeline(meetingID: meetingID)
            }
            startJobRunner()
            let jobs = try await database.jobs(meetingID: meetingID, limit: 100).map(controlJob(from:))
            return controlStatusResponse(
                message: queuedCount == 0 ? "No fallback summaries found to retry." : "Queued \(queuedCount) summary repair job(s).",
                jobs: jobs,
                activeMeetingID: meetingID,
                jobState: await controlJobState(for: meetingID),
                nextCommand: meetingID.map { "barnowl wait --session \($0.uuidString) --until complete --timeout 10m" }
            )
        } catch {
            return controlStatusResponse(ok: false, message: "Could not queue summary repair.", error: BarnOwlErrorFormatter.message(for: error))
        }
    }

    func controlDurabilityRepairResponse() async -> BarnOwlControlResponse {
        do {
            let database = try makeDatabase()
            let removedTranscriptSegments = try await database.deleteUnsafeTranscriptSegments()
            let states = try await database.meetingStates(limit: 2_000)
            let libraryStore = try? makeLibraryStore()
            let contextProvider = try? LocalMarkdownContextProvider(rootDirectory: BarnOwlMeetingProcessor.defaultContextRoot())
            var synchronizedMeetings = 0
            var refreshedFactPayloads = 0

            for state in states {
                guard !state.generatedNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    continue
                }

                let repairedFacts = Self.durabilityRepairFacts(from: state)
                let factsChanged = repairedFacts != state.meetingFacts
                let refreshedState: BarnOwlMeetingState
                if factsChanged,
                   let updated = try await database.updateMeetingStateFacts(
                    meetingID: state.id,
                    facts: repairedFacts,
                    actor: .job,
                    changeType: .meetingFactsUpdate,
                    summary: "Recomputed durable meeting facts during transcript accuracy repair."
                   ) {
                    refreshedState = updated
                    refreshedFactPayloads += 1
                } else {
                    refreshedState = state
                }

                let repairedMarkdown = Self.durabilityRepairMarkdown(from: refreshedState)
                let markdownChanged = repairedMarkdown != refreshedState.generatedNotes
                if markdownChanged {
                    _ = try await database.updateMeetingStateNotes(
                        meetingID: refreshedState.id,
                        markdown: repairedMarkdown,
                        actor: .job,
                        changeType: .summaryRegenerated,
                        summary: "Repaired canonical meeting title/facts markdown synchronization."
                    )
                }

                guard let libraryStore,
                      var artifact = try await libraryStore.artifact(id: refreshedState.id)
                else {
                    if factsChanged || markdownChanged {
                        synchronizedMeetings += 1
                    }
                    continue
                }

                let previousLibraryTitle = artifact.session.title
                let canonicalTitle = MeetingFacts.clean(refreshedState.meeting.title) ?? refreshedState.title
                if previousLibraryTitle.caseInsensitiveCompare(canonicalTitle) != .orderedSame,
                   let renamed = try await libraryStore.updateSessionTitle(sessionID: refreshedState.id, title: canonicalTitle) {
                    artifact = renamed
                }
                if artifact.markdown != repairedMarkdown,
                   let updated = try await libraryStore.updateMarkdown(sessionID: refreshedState.id, markdown: repairedMarkdown) {
                    artifact = updated
                }
                if let contextProvider {
                    if previousLibraryTitle.caseInsensitiveCompare(artifact.session.title) != .orderedSame {
                        try? await contextProvider.remove(title: previousLibraryTitle)
                    }
                    try? await contextProvider.write(ContextArtifact(
                        title: artifact.session.title,
                        markdown: artifact.markdown
                    ))
                }
                if factsChanged
                    || markdownChanged
                    || previousLibraryTitle.caseInsensitiveCompare(canonicalTitle) != .orderedSame {
                    synchronizedMeetings += 1
                }
            }

            let removedContextDebris: Int
            if let contextProvider {
                removedContextDebris = try await contextProvider.removeFiles(named: [
                    "no-transcript-content-provided-meeting-so-no.md",
                    "no-transcript-content-captured-meeting-so-no.md",
                    "transcript-only-contains-brief-incomplete-fragment-she.md",
                    "the-new-jersey-mafia.md",
                    "the-context-layer.md",
                    "inferred-from-user-request-moderna-meeting-with-ed-and-suresh.md"
                ])
            } else {
                removedContextDebris = 0
            }

            await refreshRecentSessions()
            await refreshMeetingHistory()
            return controlStatusResponse(
                message: "Durability repair completed. Removed \(removedTranscriptSegments) unsafe transcript segment(s), refreshed \(refreshedFactPayloads) meeting fact payload(s), synchronized \(synchronizedMeetings) meeting artifact(s), and pruned \(removedContextDebris) stale Context mirror file(s)."
            )
        } catch {
            return controlStatusResponse(
                ok: false,
                message: "Durability repair failed.",
                error: BarnOwlErrorFormatter.message(for: error)
            )
        }
    }

    func controlJobsDismissResponse(jobID: UUID) async -> BarnOwlControlResponse {
        do {
            let database = try makeDatabase()
            let meetingID = try await database.job(id: jobID)?.meetingID
            try await BarnOwlRecoveryCoordinator.dismissFailedJob(id: jobID, database: database)
            await refreshJobSummaries()
            await refreshProcessingTimeline(meetingID: meetingID)
            return controlStatusResponse(
                message: "Dismissed Barn Owl job.",
                jobs: try await database.jobs(meetingID: meetingID, limit: 100).map(controlJob(from:)),
                activeMeetingID: meetingID,
                jobState: await controlJobState(for: meetingID)
            )
        } catch {
            return controlStatusResponse(ok: false, message: "Could not dismiss job.", error: BarnOwlErrorFormatter.message(for: error))
        }
    }

    func controlContextListResponse(meetingID: UUID? = nil) async -> BarnOwlControlResponse {
        do {
            let database = try makeDatabase()
            let items = try await database.externalContextItems(meetingID: meetingID, limit: 100)
                .map(controlContextItem(from:))
            return controlStatusResponse(
                message: items.isEmpty ? "No Barn Owl context items found." : "Barn Owl context inbox.",
                contextItems: items,
                activeMeetingID: meetingID,
                jobState: await controlJobState(for: meetingID)
            )
        } catch {
            return controlStatusResponse(ok: false, message: "Could not load context inbox.", error: BarnOwlErrorFormatter.message(for: error))
        }
    }

    func controlContextStateResponse(itemID: UUID, state: BarnOwlExternalContextState) async -> BarnOwlControlResponse {
        do {
            let database = try makeDatabase()
            guard var item = try await database.externalContextItem(id: itemID) else {
                return controlStatusResponse(ok: false, message: "Context item not found.", error: "context_item_not_found")
            }
            let beforeState = if let meetingID = item.meetingID {
                try? await database.meetingState(id: meetingID)
            } else {
                nil as BarnOwlMeetingState?
            }
            item.state = state
            item.updatedAt = Date()
            try await database.upsertExternalContextItem(item)
            if let meetingID = item.meetingID,
               let beforeState,
               let afterState = try? await database.meetingState(id: meetingID) {
                try? await database.recordMeetingVersion(
                    meetingID: meetingID,
                    actor: .codexAPI,
                    changeType: .contextUpdate,
                    summary: "\(state == .accepted ? "Accepted" : "Ignored") context from \(item.source).",
                    before: BarnOwlMeetingVersionSnapshot(state: beforeState),
                    after: BarnOwlMeetingVersionSnapshot(state: afterState)
                )
            }
            await refreshContextInbox()
            await refreshMeetingHistory()
            if state == .accepted, let meetingID = item.meetingID {
                await applyAcceptedExternalContextToNote(meetingID: meetingID)
            }
            return controlStatusResponse(
                message: state == .accepted ? "Accepted context item." : "Ignored context item.",
                contextItems: [controlContextItem(from: item)],
                activeMeetingID: item.meetingID,
                jobState: await controlJobState(for: item.meetingID)
            )
        } catch {
            return controlStatusResponse(ok: false, message: "Could not update context item.", error: BarnOwlErrorFormatter.message(for: error))
        }
    }

    func controlContextDeleteResponse(itemID: UUID) async -> BarnOwlControlResponse {
        do {
            let database = try makeDatabase()
            let meetingID = try await database.externalContextItem(id: itemID)?.meetingID
            try await database.deleteExternalContextItem(id: itemID)
            await refreshContextInbox()
            await refreshMeetingHistory()
            return controlStatusResponse(
                message: "Deleted context item.",
                activeMeetingID: meetingID,
                jobState: await controlJobState(for: meetingID)
            )
        } catch {
            return controlStatusResponse(ok: false, message: "Could not delete context item.", error: BarnOwlErrorFormatter.message(for: error))
        }
    }

    func controlEnrichmentSourcesListResponse() async -> BarnOwlControlResponse {
        do {
            let database = try makeDatabase()
            let ownerID = currentEnrichmentOwnerID()
            try await database.seedDefaultEnrichmentSources(ownerID: ownerID)
            let usefulnessBySourceID = Dictionary(
                uniqueKeysWithValues: try await database.enrichmentSourceUsefulness(ownerID: ownerID)
                    .map { ($0.sourceID, $0) }
            )
            let sources = try await database.enrichmentSources(ownerID: ownerID)
                .map { controlEnrichmentSource(from: $0, usefulness: usefulnessBySourceID[$0.id]) }
            let authorityProfiles = try await database.enrichmentAuthorityProfiles(ownerID: ownerID)
                .map(controlEnrichmentAuthorityProfile(from:))
            let policyPacks = try await database.enrichmentPolicyPacks(ownerID: ownerID)
                .map(controlEnrichmentPolicyPack(from:))
            return controlStatusResponse(
                message: sources.isEmpty ? "No enrichment sources configured." : "Barn Owl enrichment sources.",
                enrichmentSources: sources,
                enrichmentAuthorityProfiles: authorityProfiles,
                enrichmentPolicyPacks: policyPacks
            )
        } catch {
            return controlStatusResponse(
                ok: false,
                message: "Could not load enrichment sources.",
                error: BarnOwlErrorFormatter.message(for: error)
            )
        }
    }

    func controlEnrichmentSourcePresetsListResponse() -> BarnOwlControlResponse {
        controlStatusResponse(
            message: "Barn Owl enrichment source presets.",
            enrichmentSourcePresets: Self.enrichmentSourcePresets
        )
    }

    func controlEnrichmentSourceSetupPresetResponse(_ command: BarnOwlControlCommand) async -> BarnOwlControlResponse {
        let presetID = command.presetID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !presetID.isEmpty else {
            return controlStatusResponse(ok: false, message: "enrichment_source_setup_preset requires presetID.", error: "missing_preset_id")
        }
        guard let preset = Self.enrichmentSourcePresets.first(where: { $0.id == presetID }) else {
            return controlStatusResponse(ok: false, message: "Enrichment source preset not found.", error: "enrichment_source_preset_not_found")
        }
        let sourceID = command.sourceID?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedSourceID = sourceID?.isEmpty == false ? sourceID! : preset.id
        do {
            let database = try makeDatabase()
            let ownerID = currentEnrichmentOwnerID()
            let existing = try await database.enrichmentSource(ownerID: ownerID, id: resolvedSourceID)
            let now = Date()
            let requestedDisplayName = command.sourceDisplayName?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let requestedAuthorityProfile = command.authorityProfile?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let source = BarnOwlEnrichmentSourceRecord(
                id: resolvedSourceID,
                ownerID: ownerID,
                displayName: (requestedDisplayName?.isEmpty == false ? requestedDisplayName! : nil)
                    ?? existing?.displayName
                    ?? preset.displayName,
                sourceType: preset.sourceType,
                enabled: command.enabled ?? existing?.enabled ?? true,
                scope: BarnOwlEnrichmentSourceScope(rawValue: preset.scope) ?? .workspacePrivate,
                authorityProfile: (requestedAuthorityProfile?.isEmpty == false ? requestedAuthorityProfile! : nil)
                    ?? existing?.authorityProfile
                    ?? preset.authorityProfile,
                bestUsedFor: command.bestUsedFor ?? existing?.bestUsedFor ?? preset.bestUsedFor,
                configJSON: command.configJSON ?? existing?.configJSON,
                authState: BarnOwlEnrichmentSourceAuthState(rawValue: command.authState ?? "")
                    ?? existing?.authState
                    ?? BarnOwlEnrichmentSourceAuthState(rawValue: preset.defaultAuthState)
                    ?? .needsAuthentication,
                healthStatus: BarnOwlEnrichmentSourceHealthStatus(rawValue: command.healthStatus ?? "")
                    ?? existing?.healthStatus
                    ?? BarnOwlEnrichmentSourceHealthStatus(rawValue: preset.defaultHealthStatus)
                    ?? .needsAuth,
                healthDetail: existing?.healthDetail,
                lastCheckedAt: existing?.lastCheckedAt,
                lastSuccessfulCheckAt: existing?.lastSuccessfulCheckAt,
                lastFailedCheckAt: existing?.lastFailedCheckAt,
                connectorReference: command.connectorReference ?? existing?.connectorReference ?? preset.connectorReference,
                privacyCopyPolicy: command.privacyCopyPolicy ?? existing?.privacyCopyPolicy ?? preset.privacyCopyPolicy,
                queryBudgetPolicy: command.queryBudgetPolicy ?? existing?.queryBudgetPolicy ?? preset.queryBudgetPolicy,
                createdAt: existing?.createdAt ?? now,
                updatedAt: now
            )
            try await database.upsertEnrichmentSource(source)
            return controlStatusResponse(
                message: existing == nil ? "Configured enrichment source from preset." : "Updated enrichment source from preset.",
                enrichmentSources: [controlEnrichmentSource(from: source, usefulness: try await database.enrichmentSourceUsefulness(ownerID: ownerID, sourceID: source.id))],
                enrichmentSourcePresets: [preset]
            )
        } catch {
            return controlStatusResponse(
                ok: false,
                message: "Could not configure enrichment source from preset.",
                error: BarnOwlErrorFormatter.message(for: error)
            )
        }
    }

    func controlEnrichmentSourceHealthCheckResponse(sourceID: String) async -> BarnOwlControlResponse {
        let sourceID = sourceID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sourceID.isEmpty else {
            return controlStatusResponse(ok: false, message: "enrichment_source_health_check requires sourceID.", error: "missing_source_id")
        }

        do {
            let database = try makeDatabase()
            let ownerID = currentEnrichmentOwnerID()
            guard var source = try await database.enrichmentSource(ownerID: ownerID, id: sourceID) else {
                return controlStatusResponse(ok: false, message: "Enrichment source not found.", error: "enrichment_source_not_found")
            }
            let now = Date()
            let snapshot: BarnOwlEnrichmentSourceHealthSnapshot
            let connectorNeedsSetup = source.connectorReference != nil
                && source.configJSON?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false
            if connectorNeedsSetup {
                snapshot = BarnOwlEnrichmentSourceHealthSnapshot(
                    status: .needsAuth,
                    authState: .needsAuthentication,
                    checkedAt: now,
                    detail: "\(source.displayName) is connector-backed. Authorize the connector and hydrate this source with retrieved reference configuration before automatic enrichment."
                )
            } else if let adapter = enrichmentAdapter(for: source, database: database) {
                snapshot = await adapter.healthSnapshot(for: source.descriptor)
            } else {
                snapshot = BarnOwlEnrichmentSourceHealthSnapshot(
                    status: source.connectorReference == nil ? .partial : .needsAuth,
                    authState: source.connectorReference == nil ? source.authState : .needsAuthentication,
                    checkedAt: now,
                    detail: source.connectorReference == nil
                        ? "\(source.displayName) has no installed adapter or connector setup."
                        : "\(source.displayName) is registered as connector-backed, but Barn Owl still needs authenticated connector retrieval setup before it can auto-enrich."
                )
            }
            source.authState = snapshot.authState
            source.healthStatus = source.enabled ? snapshot.status : .disabled
            source.healthDetail = snapshot.detail
            source.lastCheckedAt = snapshot.checkedAt
            if snapshot.status == .ready || snapshot.status == .partial {
                source.lastSuccessfulCheckAt = snapshot.checkedAt
            } else {
                source.lastFailedCheckAt = snapshot.checkedAt
            }
            source.updatedAt = now
            try await database.upsertEnrichmentSource(source)
            return controlStatusResponse(
                message: "Checked enrichment source health.",
                enrichmentSources: [controlEnrichmentSource(from: source, usefulness: try await database.enrichmentSourceUsefulness(ownerID: ownerID, sourceID: source.id))]
            )
        } catch {
            return controlStatusResponse(
                ok: false,
                message: "Could not check enrichment source health.",
                error: BarnOwlErrorFormatter.message(for: error)
            )
        }
    }

    func controlEnrichmentSourceUpsertResponse(_ command: BarnOwlControlCommand) async -> BarnOwlControlResponse {
        let sourceID = command.sourceID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let displayName = command.sourceDisplayName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let sourceType = command.sourceType?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let authorityProfile = command.authorityProfile?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !sourceID.isEmpty else {
            return controlStatusResponse(ok: false, message: "enrichment_source_upsert requires sourceID.", error: "missing_source_id")
        }
        guard !displayName.isEmpty else {
            return controlStatusResponse(ok: false, message: "enrichment_source_upsert requires sourceDisplayName.", error: "missing_source_display_name")
        }
        guard !sourceType.isEmpty else {
            return controlStatusResponse(ok: false, message: "enrichment_source_upsert requires sourceType.", error: "missing_source_type")
        }
        guard !authorityProfile.isEmpty else {
            return controlStatusResponse(ok: false, message: "enrichment_source_upsert requires authorityProfile.", error: "missing_authority_profile")
        }
        guard let scope = BarnOwlEnrichmentSourceScope(rawValue: command.scope ?? "") else {
            return controlStatusResponse(ok: false, message: "enrichment_source_upsert requires a valid scope.", error: "invalid_source_scope")
        }

        do {
            let database = try makeDatabase()
            let ownerID = currentEnrichmentOwnerID()
            let now = Date()
            let existing = try await database.enrichmentSource(ownerID: ownerID, id: sourceID)
            let authState = BarnOwlEnrichmentSourceAuthState(rawValue: command.authState ?? "")
                ?? existing?.authState
                ?? .notRequired
            let healthStatus = BarnOwlEnrichmentSourceHealthStatus(rawValue: command.healthStatus ?? "")
                ?? existing?.healthStatus
                ?? (command.enabled == false ? .disabled : .ready)
            let source = BarnOwlEnrichmentSourceRecord(
                id: sourceID,
                ownerID: ownerID,
                displayName: displayName,
                sourceType: sourceType,
                enabled: command.enabled ?? existing?.enabled ?? true,
                scope: scope,
                authorityProfile: authorityProfile,
                bestUsedFor: command.bestUsedFor ?? existing?.bestUsedFor ?? [],
                configJSON: command.configJSON ?? existing?.configJSON,
                authState: authState,
                healthStatus: command.enabled == false ? .disabled : healthStatus,
                healthDetail: existing?.healthDetail,
                lastCheckedAt: existing?.lastCheckedAt,
                lastSuccessfulCheckAt: existing?.lastSuccessfulCheckAt,
                lastFailedCheckAt: existing?.lastFailedCheckAt,
                connectorReference: command.connectorReference ?? existing?.connectorReference,
                privacyCopyPolicy: command.privacyCopyPolicy ?? existing?.privacyCopyPolicy,
                queryBudgetPolicy: command.queryBudgetPolicy ?? existing?.queryBudgetPolicy,
                createdAt: existing?.createdAt ?? now,
                updatedAt: now
            )
            try await database.upsertEnrichmentSource(source)
            return controlStatusResponse(
                message: existing == nil ? "Created enrichment source." : "Updated enrichment source.",
                enrichmentSources: [controlEnrichmentSource(from: source, usefulness: try await database.enrichmentSourceUsefulness(ownerID: ownerID, sourceID: source.id))]
            )
        } catch {
            return controlStatusResponse(
                ok: false,
                message: "Could not save enrichment source.",
                error: BarnOwlErrorFormatter.message(for: error)
            )
        }
    }

    func controlEnrichmentSourceEnabledResponse(sourceID: String, enabled: Bool) async -> BarnOwlControlResponse {
        let sourceID = sourceID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sourceID.isEmpty else {
            return controlStatusResponse(ok: false, message: "Enrichment source id is required.", error: "missing_source_id")
        }

        do {
            let database = try makeDatabase()
            let ownerID = currentEnrichmentOwnerID()
            guard let source = try await database.setEnrichmentSourceEnabled(ownerID: ownerID, id: sourceID, enabled: enabled) else {
                return controlStatusResponse(ok: false, message: "Enrichment source not found.", error: "enrichment_source_not_found")
            }
            return controlStatusResponse(
                message: enabled ? "Enabled enrichment source." : "Disabled enrichment source.",
                enrichmentSources: [controlEnrichmentSource(from: source, usefulness: try await database.enrichmentSourceUsefulness(ownerID: ownerID, sourceID: source.id))]
            )
        } catch {
            return controlStatusResponse(
                ok: false,
                message: "Could not update enrichment source.",
                error: BarnOwlErrorFormatter.message(for: error)
            )
        }
    }

    func controlEnrichmentAuthorityProfilesListResponse() async -> BarnOwlControlResponse {
        do {
            let database = try makeDatabase()
            let ownerID = currentEnrichmentOwnerID()
            try await database.seedDefaultEnrichmentAuthorityProfiles(ownerID: ownerID)
            let profiles = try await database.enrichmentAuthorityProfiles(ownerID: ownerID)
                .map(controlEnrichmentAuthorityProfile(from:))
            return controlStatusResponse(
                message: profiles.isEmpty ? "No enrichment authority profiles configured." : "Barn Owl enrichment authority profiles.",
                enrichmentAuthorityProfiles: profiles
            )
        } catch {
            return controlStatusResponse(
                ok: false,
                message: "Could not load enrichment authority profiles.",
                error: BarnOwlErrorFormatter.message(for: error)
            )
        }
    }

    func controlEnrichmentAuthorityProfileUpsertResponse(_ command: BarnOwlControlCommand) async -> BarnOwlControlResponse {
        let id = command.authorityProfileID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let displayName = command.displayName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let description = command.description?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !id.isEmpty else {
            return controlStatusResponse(ok: false, message: "enrichment_authority_profile_upsert requires authorityProfileID.", error: "missing_authority_profile_id")
        }
        guard !displayName.isEmpty else {
            return controlStatusResponse(ok: false, message: "enrichment_authority_profile_upsert requires displayName.", error: "missing_display_name")
        }
        guard !description.isEmpty else {
            return controlStatusResponse(ok: false, message: "enrichment_authority_profile_upsert requires description.", error: "missing_description")
        }

        do {
            let database = try makeDatabase()
            let ownerID = currentEnrichmentOwnerID()
            let existing = try await database.enrichmentAuthorityProfile(ownerID: ownerID, id: id)
            let now = Date()
            let profile = BarnOwlEnrichmentAuthorityProfileRecord(
                id: id,
                ownerID: ownerID,
                displayName: displayName,
                description: description,
                strongestEntityKinds: command.strongestEntityKinds ?? existing?.strongestEntityKinds ?? [],
                weakestEntityKinds: command.weakestEntityKinds ?? existing?.weakestEntityKinds ?? [],
                defaultWeight: command.defaultWeight ?? existing?.defaultWeight ?? 0.75,
                autoPersistPolicyJSON: command.autoPersistPolicyJSON ?? existing?.autoPersistPolicyJSON,
                builtIn: existing?.builtIn ?? false,
                createdAt: existing?.createdAt ?? now,
                updatedAt: now
            )
            try await database.upsertEnrichmentAuthorityProfile(profile)
            return controlStatusResponse(
                message: existing == nil ? "Created enrichment authority profile." : "Updated enrichment authority profile.",
                enrichmentAuthorityProfiles: [controlEnrichmentAuthorityProfile(from: profile)]
            )
        } catch {
            return controlStatusResponse(
                ok: false,
                message: "Could not save enrichment authority profile.",
                error: BarnOwlErrorFormatter.message(for: error)
            )
        }
    }

    func controlEnrichmentPolicyPacksListResponse() async -> BarnOwlControlResponse {
        do {
            let database = try makeDatabase()
            let ownerID = currentEnrichmentOwnerID()
            try await database.seedDefaultEnrichmentPolicyPacks(ownerID: ownerID)
            let packs = try await database.enrichmentPolicyPacks(ownerID: ownerID)
                .map(controlEnrichmentPolicyPack(from:))
            return controlStatusResponse(
                message: packs.isEmpty ? "No enrichment policy packs configured." : "Barn Owl enrichment policy packs.",
                enrichmentPolicyPacks: packs
            )
        } catch {
            return controlStatusResponse(
                ok: false,
                message: "Could not load enrichment policy packs.",
                error: BarnOwlErrorFormatter.message(for: error)
            )
        }
    }

    func controlEnrichmentPolicyPackUpsertResponse(_ command: BarnOwlControlCommand) async -> BarnOwlControlResponse {
        let id = command.policyPackID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let displayName = command.displayName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let description = command.description?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !id.isEmpty else {
            return controlStatusResponse(ok: false, message: "enrichment_policy_pack_upsert requires policyPackID.", error: "missing_policy_pack_id")
        }
        guard !displayName.isEmpty else {
            return controlStatusResponse(ok: false, message: "enrichment_policy_pack_upsert requires displayName.", error: "missing_display_name")
        }
        guard !description.isEmpty else {
            return controlStatusResponse(ok: false, message: "enrichment_policy_pack_upsert requires description.", error: "missing_description")
        }

        do {
            let database = try makeDatabase()
            let ownerID = currentEnrichmentOwnerID()
            let existing = try await database.enrichmentPolicyPack(ownerID: ownerID, id: id)
            let now = Date()
            let pack = BarnOwlEnrichmentPolicyPackRecord(
                id: id,
                ownerID: ownerID,
                displayName: displayName,
                description: description,
                minimumSupportingEvidenceCount: command.minimumSupportingEvidenceCount ?? existing?.minimumSupportingEvidenceCount ?? 2,
                minimumIndependentSourceCountAfterConflictMemory: command.minimumIndependentSourceCountAfterConflictMemory ?? existing?.minimumIndependentSourceCountAfterConflictMemory ?? 2,
                active: command.enabled ?? existing?.active ?? false,
                createdAt: existing?.createdAt ?? now,
                updatedAt: now
            )
            try await database.upsertEnrichmentPolicyPack(pack)
            return controlStatusResponse(
                message: existing == nil ? "Created enrichment policy pack." : "Updated enrichment policy pack.",
                enrichmentPolicyPacks: [controlEnrichmentPolicyPack(from: pack)]
            )
        } catch {
            return controlStatusResponse(
                ok: false,
                message: "Could not save enrichment policy pack.",
                error: BarnOwlErrorFormatter.message(for: error)
            )
        }
    }

    func controlEnrichmentPolicyPackActivateResponse(policyPackID: String) async -> BarnOwlControlResponse {
        let policyPackID = policyPackID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !policyPackID.isEmpty else {
            return controlStatusResponse(ok: false, message: "enrichment_policy_pack_activate requires policyPackID.", error: "missing_policy_pack_id")
        }
        do {
            let database = try makeDatabase()
            let ownerID = currentEnrichmentOwnerID()
            guard var pack = try await database.enrichmentPolicyPack(ownerID: ownerID, id: policyPackID) else {
                return controlStatusResponse(ok: false, message: "Enrichment policy pack not found.", error: "enrichment_policy_pack_not_found")
            }
            pack.active = true
            pack.updatedAt = Date()
            try await database.upsertEnrichmentPolicyPack(pack)
            return controlStatusResponse(
                message: "Activated enrichment policy pack.",
                enrichmentPolicyPacks: try await database.enrichmentPolicyPacks(ownerID: ownerID).map(controlEnrichmentPolicyPack(from:))
            )
        } catch {
            return controlStatusResponse(
                ok: false,
                message: "Could not activate enrichment policy pack.",
                error: BarnOwlErrorFormatter.message(for: error)
            )
        }
    }

    func controlKnowledgeEnrichResponse(concept: String, limit: Int? = nil) async -> BarnOwlControlResponse {
        let concept = concept.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !concept.isEmpty else {
            return controlStatusResponse(ok: false, message: "knowledge_enrich requires a concept query.", error: "missing_query")
        }

        do {
            let database = try makeDatabase()
            let ownerID = currentEnrichmentOwnerID()
            let now = Date()
            let execution = try await executeKnowledgeEnrichment(
                concept: concept,
                limit: max(1, min(limit ?? 8, 24)),
                ownerID: ownerID,
                database: database,
                now: now
            )

            return controlStatusResponse(
                message: execution.run.status == .supportedCandidate
                    ? execution.persistedKnowledge == nil
                        ? "Recorded supported enrichment candidate."
                        : "Recorded supported enrichment candidate and updated durable knowledge."
                    : "Recorded held enrichment result.",
                enrichmentJobs: [controlEnrichmentJob(from: execution.job, evidenceCount: execution.run.evidence.count)],
                enrichmentEvidence: execution.run.evidence,
                enrichmentConflicts: execution.run.status == .heldConflictingEvidence
                    ? try await database.enrichmentConflicts(ownerID: ownerID, limit: 1).map(controlEnrichmentConflict(from:))
                    : nil,
                enrichmentConceptHistories: [
                    controlConceptHistory(
                        conceptKey: concept,
                        history: try await enrichmentConceptHistory(
                            concept: concept,
                            ownerID: ownerID,
                            database: database
                        )
                    )
                ]
            )
        } catch {
            return controlStatusResponse(
                ok: false,
                message: "Could not run knowledge enrichment.",
                error: BarnOwlErrorFormatter.message(for: error)
            )
        }
    }

    private struct BarnOwlKnowledgeEnrichmentExecution {
        var run: BarnOwlEnrichmentRunResult
        var job: BarnOwlEnrichmentJobRecord
        var persistedKnowledge: BarnOwlKnowledgeEntityRecord?
    }

    private func executeKnowledgeEnrichment(
        concept: String,
        limit: Int,
        ownerID: String,
        database: BarnOwlDatabase,
        now: Date
    ) async throws -> BarnOwlKnowledgeEnrichmentExecution {
        try await database.seedDefaultEnrichmentSources(ownerID: ownerID, now: now)
        let configuredSources = try await database.enrichmentSources(ownerID: ownerID)
        let usefulnessBySourceID = Dictionary(
            uniqueKeysWithValues: try await database.enrichmentSourceUsefulness(ownerID: ownerID)
                .map { ($0.sourceID, $0) }
        )
        let configuredAdapters: [any BarnOwlEnrichmentSourceAdapter] = configuredSources.compactMap {
            enrichmentAdapter(for: $0, database: database)
        }
        let conceptHistory = try await enrichmentConceptHistory(
            concept: concept,
            ownerID: ownerID,
            database: database
        )
        let policyPack = try await database.activeEnrichmentPolicyPack(ownerID: ownerID)
        let executionPolicy = BarnOwlEnrichmentExecutionPolicy(
            minimumSupportingEvidenceCount: policyPack?.minimumSupportingEvidenceCount ?? 2,
            minimumIndependentSourceCountAfterConflictMemory: policyPack?.minimumIndependentSourceCountAfterConflictMemory ?? 2
        )
        let run = await BarnOwlEnrichmentOrchestrator(
            adapters: configuredAdapters,
            policy: executionPolicy
        ).run(
            request: BarnOwlEnrichmentSourceRequest(
                conceptKey: concept,
                limit: limit,
                requestedAt: now
            ),
            sources: configuredSources.map {
                BarnOwlEnrichmentConfiguredSource(
                    descriptor: $0.descriptor,
                    enabled: $0.enabled,
                    authState: $0.authState,
                    healthStatus: $0.healthStatus,
                    routingPriority: Self.routingPriority(
                        source: $0,
                        usefulness: usefulnessBySourceID[$0.id]
                    )
                )
            },
            conceptHistory: conceptHistory
        )

        let job = BarnOwlEnrichmentJobRecord(
            ownerID: ownerID,
            conceptKey: concept,
            requestedSources: run.requestedSources,
            selectedSources: run.selectedSources,
            status: run.status,
            summary: run.summary,
            rationale: run.rationale,
            createdAt: now,
            updatedAt: now,
            startedAt: now,
            finishedAt: now
        )
        try await database.upsertEnrichmentJob(job)
        for item in run.evidence {
            try await database.upsertEnrichmentJobEvidence(BarnOwlEnrichmentJobEvidenceRecord(
                jobID: job.id,
                sourceID: item.sourceID,
                evidenceJSON: BarnOwlEnrichmentJobEvidenceRecord.encodeEvidence(item),
                acceptedByAdjudicator: run.status == .supportedCandidate,
                createdAt: now
            ))
        }
        if run.status == .heldConflictingEvidence {
            try await database.upsertEnrichmentConflict(BarnOwlEnrichmentConflictRecord(
                jobID: job.id,
                ownerID: ownerID,
                conceptKey: concept,
                summary: run.rationale,
                conflictingSourceIDs: Array(Set(run.evidence.map(\.sourceID))).sorted(),
                createdAt: now
            ))
        }
        for sourceID in run.selectedSources {
            let sourceEvidence = run.evidence.filter { $0.sourceID == sourceID }
            try await database.recordEnrichmentSourceUsefulness(
                ownerID: ownerID,
                sourceID: sourceID,
                status: run.status,
                evidenceItemCount: sourceEvidence.count,
                acceptedEvidenceItemCount: run.status == .supportedCandidate ? sourceEvidence.count : 0,
                contributedAt: sourceEvidence.isEmpty ? nil : now,
                updatedAt: now
            )
        }
        try await applyAutomaticKnowledgeReversalIfNeeded(
            run: run,
            job: job,
            ownerID: ownerID,
            database: database,
            now: now
        )
        let persistedKnowledge = run.status == .supportedCandidate
            ? try await persistSupportedKnowledge(
                run: run,
                job: job,
                ownerID: ownerID,
                database: database,
                now: now
            )
            : nil
        return BarnOwlKnowledgeEnrichmentExecution(
            run: run,
            job: job,
            persistedKnowledge: persistedKnowledge
        )
    }

    private func applyAutomaticKnowledgeReversalIfNeeded(
        run: BarnOwlEnrichmentRunResult,
        job: BarnOwlEnrichmentJobRecord,
        ownerID: String,
        database: BarnOwlDatabase,
        now: Date
    ) async throws {
        guard run.status == .heldConflictingEvidence else {
            return
        }

        let matchingEntities = try await database.knowledgeEntitiesMatchingConcept(
            ownerID: ownerID,
            concept: job.conceptKey
        )
        guard !matchingEntities.isEmpty else {
            return
        }

        let nonPublicEvidence = run.evidence.filter { $0.scope != .publicReference }
        guard !nonPublicEvidence.isEmpty else {
            return
        }

        let hasExplicitPrivateContradiction = nonPublicEvidence.contains {
            $0.contradiction || $0.negativeEvidence
        }
        if hasExplicitPrivateContradiction {
            for entity in matchingEntities {
                _ = try await database.setKnowledgeEntityLifecycleStatus(
                    id: entity.id,
                    ownerID: ownerID,
                    status: .suppressed,
                    reason: "Automatically suppressed after explicit private or internal contradictory enrichment evidence for \(job.conceptKey).",
                    updatedAt: now
                )
            }
            return
        }

        let privateSemanticCandidates = Set(
            nonPublicEvidence
                .filter {
                    !$0.contradiction
                        && !$0.negativeEvidence
                        && $0.candidateKind != "unresolved_concept"
                }
                .map {
                    "\($0.candidateKind.lowercased())|\($0.canonicalName.lowercased())"
                }
        )
        guard privateSemanticCandidates.count > 1 else {
            return
        }

        for entity in matchingEntities {
            _ = try await database.setKnowledgeEntityConfidence(
                id: entity.id,
                ownerID: ownerID,
                confidence: max(0.05, entity.confidence - 0.15),
                updatedAt: now
            )
        }
    }

    private func enrichmentAdapter(
        for source: BarnOwlEnrichmentSourceRecord,
        database: BarnOwlDatabase
    ) -> (any BarnOwlEnrichmentSourceAdapter)? {
        if source.id == "barnowl_memory" || source.sourceType == "local_memory" {
            return BarnOwlMemoryEnrichmentSourceAdapter(database: database)
        }
        if source.sourceType == "internal_memory" || source.sourceType == "private_reference" {
            return BarnOwlConfiguredInternalReferenceAdapter(sourceID: source.id)
        }
        if source.sourceType == "public_reference" {
            if source.configJSON?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
                return BarnOwlConfiguredPublicReferenceAdapter(sourceID: source.id)
            }
            return BarnOwlPublicReferenceResearchAdapter(sourceID: source.id)
        }
        return nil
    }

    private func enrichmentConceptHistory(
        concept: String,
        ownerID: String,
        database: BarnOwlDatabase
    ) async throws -> BarnOwlEnrichmentConceptHistory {
        let recentJobs = try await database.enrichmentJobs(
            ownerID: ownerID,
            conceptKey: concept,
            limit: 50
        )
        var negativeEvidenceItems = 0
        for job in recentJobs {
            let jobEvidence = try await database.enrichmentJobEvidence(jobID: job.id)
            negativeEvidenceItems += jobEvidence.compactMap(\.evidence).filter(\.negativeEvidence).count
        }
        return BarnOwlEnrichmentConceptHistory(
            supportedCandidateJobs: recentJobs.filter { $0.status == .supportedCandidate }.count,
            conflictingJobs: recentJobs.filter { $0.status == .heldConflictingEvidence }.count,
            negativeEvidenceItems: negativeEvidenceItems
        )
    }

    private nonisolated static func routingPriority(
        source: BarnOwlEnrichmentSourceRecord,
        usefulness: BarnOwlEnrichmentSourceUsefulnessRecord?
    ) -> Double {
        let scopeBias: Double = switch source.scope {
        case .localPrivate, .personalPrivate, .workspacePrivate:
            0.4
        case .organizationScoped:
            0.2
        case .publicReference:
            0
        }
        guard let usefulness else {
            return scopeBias
        }

        return scopeBias
            + (Double(usefulness.supportedJobs) * 2.0)
            + (Double(usefulness.acceptedEvidenceItems) * 0.25)
            - (Double(usefulness.conflictingJobs) * 1.5)
            - Double(usefulness.failedJobs)
    }

    private func persistSupportedKnowledge(
        run: BarnOwlEnrichmentRunResult,
        job: BarnOwlEnrichmentJobRecord,
        ownerID: String,
        database: BarnOwlDatabase,
        now: Date
    ) async throws -> BarnOwlKnowledgeEntityRecord? {
        let semanticEvidence = run.evidence.filter {
            !$0.negativeEvidence
                && !$0.contradiction
                && $0.candidateKind != "unresolved_concept"
        }
        guard let strongest = semanticEvidence.max(by: { $0.confidence < $1.confidence }) else {
            return nil
        }

        let conceptHistory = try await enrichmentConceptHistory(
            concept: job.conceptKey,
            ownerID: ownerID,
            database: database
        )
        let repeatedSupportBoost = min(
            0.08,
            Double(max(0, conceptHistory.supportedCandidateJobs - 1)) * 0.02
        )
        let entity = BarnOwlKnowledgeEntityRecord(
            ownerID: ownerID,
            kind: strongest.candidateKind,
            canonicalName: strongest.canonicalName,
            summary: strongest.summary,
            confidence: min(0.99, strongest.confidence + repeatedSupportBoost),
            sourceJobID: job.id,
            createdAt: now,
            updatedAt: now
        )
        try await database.upsertKnowledgeEntity(entity)
        guard let persistedEntity = try await database.knowledgeEntity(
            ownerID: ownerID,
            kind: strongest.candidateKind,
            canonicalName: strongest.canonicalName
        ) else {
            return nil
        }

        let aliases = MeetingFacts.normalizedList([job.conceptKey, strongest.canonicalName])
        for alias in aliases {
            try await database.upsertKnowledgeAlias(BarnOwlKnowledgeAliasRecord(
                ownerID: ownerID,
                entityID: persistedEntity.id,
                alias: alias,
                confidence: strongest.confidence,
                createdAt: now,
                updatedAt: now
            ))
        }

        let meetingIDs = Set(run.evidence.flatMap { evidence in
            evidence.citations.compactMap(Self.meetingIDCitation)
        })
        for meetingID in meetingIDs {
            try await database.upsertKnowledgeMeetingLink(BarnOwlKnowledgeMeetingLinkRecord(
                ownerID: ownerID,
                entityID: persistedEntity.id,
                meetingID: meetingID,
                evidenceJobID: job.id,
                createdAt: now,
                updatedAt: now
            ))
        }

        return persistedEntity
    }

    private static func meetingIDCitation(_ citation: String) -> UUID? {
        let prefix = "meeting:"
        guard citation.lowercased().hasPrefix(prefix) else {
            return nil
        }
        return UUID(uuidString: String(citation.dropFirst(prefix.count)))
    }

    func controlKnowledgeJobsListResponse(limit: Int? = nil) async -> BarnOwlControlResponse {
        do {
            let database = try makeDatabase()
            let ownerID = currentEnrichmentOwnerID()
            let jobs = try await database.enrichmentJobs(ownerID: ownerID, limit: max(1, min(limit ?? 25, 100)))
            var controlJobs: [BarnOwlControlEnrichmentJob] = []
            var conceptHistories: [BarnOwlControlEnrichmentConceptHistory] = []
            var seenConcepts: Set<String> = []
            for job in jobs {
                let evidenceCount = try await database.enrichmentJobEvidence(jobID: job.id)
                    .count
                controlJobs.append(controlEnrichmentJob(from: job, evidenceCount: evidenceCount))
                let normalizedConcept = job.conceptKey.lowercased()
                if !seenConcepts.contains(normalizedConcept) {
                    seenConcepts.insert(normalizedConcept)
                    conceptHistories.append(controlConceptHistory(
                        conceptKey: job.conceptKey,
                        history: try await enrichmentConceptHistory(
                            concept: job.conceptKey,
                            ownerID: ownerID,
                            database: database
                        )
                    ))
                }
            }
            return controlStatusResponse(
                message: controlJobs.isEmpty ? "No enrichment jobs recorded." : "Barn Owl enrichment jobs.",
                enrichmentJobs: controlJobs,
                enrichmentConflicts: try await database.enrichmentConflicts(ownerID: ownerID, limit: max(1, min(limit ?? 25, 100)))
                    .map(controlEnrichmentConflict(from:)),
                enrichmentConceptHistories: conceptHistories
            )
        } catch {
            return controlStatusResponse(
                ok: false,
                message: "Could not load enrichment jobs.",
                error: BarnOwlErrorFormatter.message(for: error)
            )
        }
    }

    func controlKnowledgeEntitiesListResponse(limit: Int? = nil) async -> BarnOwlControlResponse {
        do {
            let database = try makeDatabase()
            let ownerID = currentEnrichmentOwnerID()
            let entities = try await database.knowledgeEntitiesIncludingSuppressed(
                ownerID: ownerID,
                limit: max(1, min(limit ?? 100, 500))
            ).map(controlKnowledgeEntity(from:))
            return controlStatusResponse(
                message: entities.isEmpty ? "No durable knowledge entities recorded." : "Barn Owl durable knowledge entities.",
                knowledgeEntities: entities
            )
        } catch {
            return controlStatusResponse(
                ok: false,
                message: "Could not load durable knowledge entities.",
                error: BarnOwlErrorFormatter.message(for: error)
            )
        }
    }

    func controlKnowledgeEntityLifecycleResponse(
        entityID: UUID,
        status: BarnOwlKnowledgeEntityLifecycleStatus,
        reason: String?
    ) async -> BarnOwlControlResponse {
        do {
            let database = try makeDatabase()
            let ownerID = currentEnrichmentOwnerID()
            let normalizedReason = reason?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let persistedReason = normalizedReason?.isEmpty == false ? normalizedReason : nil
            guard let entity = try await database.setKnowledgeEntityLifecycleStatus(
                id: entityID,
                ownerID: ownerID,
                status: status,
                reason: persistedReason
            ) else {
                return controlStatusResponse(ok: false, message: "Durable knowledge entity not found.", error: "knowledge_entity_not_found")
            }
            return controlStatusResponse(
                message: status == .suppressed ? "Suppressed durable knowledge entity." : "Reactivated durable knowledge entity.",
                knowledgeEntities: [controlKnowledgeEntity(from: entity)]
            )
        } catch {
            return controlStatusResponse(
                ok: false,
                message: "Could not update durable knowledge entity.",
                error: BarnOwlErrorFormatter.message(for: error)
            )
        }
    }

    func controlDeleteMeetingResponse(meetingID: UUID) async -> BarnOwlControlResponse {
        guard activeSession?.id != meetingID else {
            return controlStatusResponse(ok: false, message: "Stop the active recording before deleting it.", error: "active_recording")
        }
        let existed = if let database = try? makeDatabase() {
            (try? await database.meeting(id: meetingID)) != nil
        } else {
            false
        }
        guard existed || displayedNote?.id == meetingID else {
            return controlStatusResponse(ok: false, message: "Meeting not found.", error: "meeting_not_found")
        }
        await deleteRecentSession(meetingID)
        return controlStatusResponse(
            message: "Deleted meeting.",
            activeMeetingID: nil,
            nextCommand: "barnowl meetings recent --limit 3"
        )
    }

    func controlPurgeTemporaryAudioResponse(meetingID: UUID) async -> BarnOwlControlResponse {
        guard activeSession?.id != meetingID else {
            return controlStatusResponse(ok: false, message: "Stop the active recording before purging its temporary audio.", error: "active_recording")
        }
        await BarnOwlAudioCaptureFactory.deleteTemporaryAudio(for: meetingID)
        recordActivity(
            category: "retention",
            message: "Purged temporary audio.",
            sessionID: meetingID,
            updatePreview: false
        )
        await recordMeetingExportTombstone(
            meetingID: meetingID,
            type: .purged,
            reason: "temporary_audio_purged"
        )
        return controlStatusResponse(
            message: "Purged temporary audio for meeting.",
            activeMeetingID: meetingID,
            jobState: await controlJobState(for: meetingID)
        )
    }

    func controlCurrentResponse() async -> BarnOwlControlResponse {
        if let activeSession {
            let current = BarnOwlControlMeeting(
                id: activeSession.id,
                title: activeSession.title,
                startedAt: activeSession.startedAt,
                endedAt: activeSession.endedAt,
                overview: lifecyclePresentation.detail,
                meetingType: nil,
                status: lifecyclePresentation.title
            )
            return controlStatusResponse(message: "Current Barn Owl recording.", current: current)
        }

        if let displayedNote {
            let meetingType = if let database = try? makeDatabase(),
                                 let state = try? await database.meetingState(id: displayedNote.id) {
                state.meetingFacts?.meetingType
            } else {
                Self.markdownMeetingType(in: displayedNote.markdown)
            }
            let current = BarnOwlControlMeeting(
                id: displayedNote.id,
                title: displayedNote.title,
                startedAt: displayedNote.startedAt,
                overview: Self.searchSnippet(in: displayedNote.markdown, query: ""),
                meetingType: meetingType,
                status: "Open"
            )
            return controlStatusResponse(message: "Current Barn Owl note.", current: current)
        }

        return controlStatusResponse(message: "No active or open Barn Owl meeting.")
    }

    func controlRecentMeetingsResponse(limit: Int) async -> BarnOwlControlResponse {
        do {
            let database = try makeDatabase()
            let states = try await database.meetingStates(limit: max(1, min(limit, 100)))
            let controlMeetings = states.map(controlMeeting(from:))
            return controlStatusResponse(
                message: "Recent Barn Owl meetings.",
                meetings: controlMeetings
            )
        } catch {
            return controlStatusResponse(
                ok: false,
                message: "Could not load recent meetings.",
                error: BarnOwlErrorFormatter.message(for: error)
            )
        }
    }

    func controlSearchMeetingsResponse(query: String, limit: Int) async -> BarnOwlControlResponse {
        let cleanedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanedQuery.isEmpty else {
            return controlStatusResponse(ok: false, message: "Search requires a query.", error: "missing_query")
        }

        do {
            let database = try makeDatabase()
            let results = try await database.searchLibrary(BarnOwlDatabaseSearchQuery(text: cleanedQuery, limit: max(1, min(limit, 100))))
            let meetings = results.map {
                BarnOwlControlMeeting(
                    id: $0.meeting.id,
                    title: $0.meeting.title,
                    startedAt: $0.meeting.startedAt,
                    endedAt: $0.meeting.endedAt,
                    overview: $0.snippet,
                    meetingType: $0.meetingType,
                    status: $0.status?.rawValue
                )
            }
            return controlStatusResponse(message: "Barn Owl meeting search results.", meetings: meetings)
        } catch {
            return controlStatusResponse(
                ok: false,
                message: "Meeting search failed.",
                error: BarnOwlErrorFormatter.message(for: error)
            )
        }
    }

    func controlMeetingResponse(meetingID: UUID) async -> BarnOwlControlResponse {
        do {
            let database = try makeDatabase()
            guard let state = try await database.meetingState(id: meetingID) else {
                return controlStatusResponse(ok: false, message: "Meeting not found.", error: "meeting_not_found")
            }
            return controlStatusResponse(
                message: "Barn Owl meeting.",
                meeting: controlMeeting(from: state),
                transcript: state.transcriptText,
                notes: state.generatedNotes,
                summary: state.summary?.overview,
                contextItems: controlContextItems(from: state),
                actions: state.actionItems,
                decisions: state.decisions,
                participants: state.meetingFacts?.participants ?? []
            )
        } catch {
            return controlStatusResponse(
                ok: false,
                message: "Could not load meeting.",
                error: BarnOwlErrorFormatter.message(for: error)
            )
        }
    }

    func controlMeetingTranscriptResponse(meetingID: UUID) async -> BarnOwlControlResponse {
        do {
            let database = try makeDatabase()
            let state = try await database.meetingState(id: meetingID)
            return controlStatusResponse(
                message: "Barn Owl meeting transcript.",
                transcript: state?.transcriptText ?? ""
            )
        } catch {
            return controlStatusResponse(ok: false, message: "Could not load transcript.", error: BarnOwlErrorFormatter.message(for: error))
        }
    }

    func controlMeetingNotesResponse(meetingID: UUID) async -> BarnOwlControlResponse {
        do {
            let database = try makeDatabase()
            let state = try await database.meetingState(id: meetingID)
            return controlStatusResponse(
                message: "Barn Owl meeting notes.",
                notes: state?.generatedNotes ?? ""
            )
        } catch {
            return controlStatusResponse(ok: false, message: "Could not load notes.", error: BarnOwlErrorFormatter.message(for: error))
        }
    }

    func controlMeetingSummaryResponse(meetingID: UUID) async -> BarnOwlControlResponse {
        do {
            let database = try makeDatabase()
            let state = try await database.meetingState(id: meetingID)
            return controlStatusResponse(
                message: "Barn Owl meeting summary.",
                summary: state?.summary?.overview ?? ""
            )
        } catch {
            return controlStatusResponse(ok: false, message: "Could not load summary.", error: BarnOwlErrorFormatter.message(for: error))
        }
    }

    func controlMeetingContextResponse(meetingID: UUID) async -> BarnOwlControlResponse {
        do {
            let database = try makeDatabase()
            let state = try await database.meetingState(id: meetingID)
            return controlStatusResponse(
                message: "Barn Owl meeting context.",
                contextItems: state.map(controlContextItems(from:)) ?? []
            )
        } catch {
            return controlStatusResponse(ok: false, message: "Could not load context.", error: BarnOwlErrorFormatter.message(for: error))
        }
    }

    func controlMeetingActionsResponse(meetingID: UUID) async -> BarnOwlControlResponse {
        do {
            let database = try makeDatabase()
            let state = try await database.meetingState(id: meetingID)
            return controlStatusResponse(
                message: "Barn Owl meeting actions.",
                actions: state?.actionItems ?? [],
                decisions: state?.decisions ?? [],
                participants: state?.meetingFacts?.participants ?? []
            )
        } catch {
            return controlStatusResponse(ok: false, message: "Could not load actions.", error: BarnOwlErrorFormatter.message(for: error))
        }
    }

    func controlMeetingEvidenceResponse(
        meetingID: UUID,
        exportPolicy rawPolicy: String? = nil,
        includeTranscriptSegments: Bool = false
    ) async -> BarnOwlControlResponse {
        let policy: BarnOwlMeetingEvidenceContentPolicy
        if let rawPolicy {
            guard let resolved = BarnOwlMeetingEvidenceContentPolicy(rawValue: rawPolicy) else {
                return controlStatusResponse(
                    ok: false,
                    message: "meeting_evidence received an unsupported export policy.",
                    errorCode: "invalid_export_policy",
                    error: rawPolicy
                )
            }
            policy = resolved
        } else {
            policy = .structuredOutputsTranscriptAndPointers
        }

        do {
            let database = try makeDatabase()
            guard let state = try await database.meetingState(id: meetingID) else {
                return controlStatusResponse(ok: false, message: "Meeting not found.", error: "meeting_not_found")
            }
            let evidence = meetingEvidenceEnvelope(
                from: state,
                policy: policy,
                includeTranscriptSegments: includeTranscriptSegments
            )
            return controlStatusResponse(
                message: "Barn Owl meeting evidence.",
                meetingEvidence: evidence,
                activeMeetingID: meetingID,
                notesReady: evidence.processing.notesReady,
                transcriptReady: evidence.processing.transcriptReady,
                summaryReady: evidence.processing.summaryReady
            )
        } catch {
            return controlStatusResponse(
                ok: false,
                message: "Could not export meeting evidence.",
                error: BarnOwlErrorFormatter.message(for: error)
            )
        }
    }

    func controlMeetingEvidenceBatchResponse(
        since rawSince: String?,
        cursor rawCursor: String? = nil,
        limit: Int,
        exportPolicy rawPolicy: String? = nil,
        includeTranscriptSegments: Bool = false
    ) async -> BarnOwlControlResponse {
        let trimmedSince = rawSince?.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedCursor = rawCursor?.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasSince = !(trimmedSince?.isEmpty ?? true)
        let hasCursor = !(trimmedCursor?.isEmpty ?? true)

        guard hasSince || hasCursor else {
            return controlStatusResponse(
                ok: false,
                message: "meetings_evidence requires --since or --cursor.",
                errorCode: "missing_sync_anchor",
                error: "Provide an ISO-8601 timestamp or an opaque cursor."
            )
        }
        guard !(hasSince && hasCursor) else {
            return controlStatusResponse(
                ok: false,
                message: "meetings_evidence accepts either --since or --cursor, not both.",
                errorCode: "conflicting_sync_anchor",
                error: "Choose one incremental sync mode."
            )
        }

        let policy: BarnOwlMeetingEvidenceContentPolicy
        if let rawPolicy {
            guard let resolved = BarnOwlMeetingEvidenceContentPolicy(rawValue: rawPolicy) else {
                return controlStatusResponse(
                    ok: false,
                    message: "meetings_evidence received an unsupported export policy.",
                    errorCode: "invalid_export_policy",
                    error: rawPolicy
                )
            }
            policy = resolved
        } else {
            policy = .structuredOutputsTranscriptAndPointers
        }

        do {
            let boundedLimit = max(1, min(limit, 100))
            let database = try makeDatabase()
            let syncRequest: BarnOwlMeetingEvidenceSyncRequest
            let states: [BarnOwlMeetingState]

            if let rawCursor = trimmedCursor, hasCursor {
                guard let cursor = Self.meetingEvidenceCursor(from: rawCursor) else {
                    return controlStatusResponse(
                        ok: false,
                        message: "meetings_evidence received an invalid --cursor token.",
                        errorCode: "invalid_cursor",
                        error: rawCursor
                    )
                }
                syncRequest = .cursor(rawValue: rawCursor, position: cursor)
                states = try await database.meetingStatesUpdated(
                    after: cursor.updatedAt,
                    meetingID: cursor.meetingID,
                    limit: boundedLimit + 1
                )
            } else if let rawSince = trimmedSince,
                      let since = Self.meetingEvidenceSyncDate(from: rawSince) {
                syncRequest = .timestamp(since)
                states = try await database.meetingStatesUpdated(
                    since: since,
                    limit: boundedLimit + 1
                )
            } else {
                return controlStatusResponse(
                    ok: false,
                    message: "meetings_evidence received an invalid --since timestamp.",
                    errorCode: "invalid_since",
                    error: trimmedSince
                )
            }
            let pageStates = Array(states.prefix(boundedLimit))
            let evidenceItems = pageStates.map {
                meetingEvidenceEnvelope(
                    from: $0,
                    policy: policy,
                    includeTranscriptSegments: includeTranscriptSegments
                )
            }
            let lastCursor = pageStates.last.flatMap(Self.meetingEvidenceCursorToken(from:))
            let syncPage: BarnOwlMeetingEvidenceSyncPage
            switch syncRequest {
            case .timestamp(let since):
                syncPage = BarnOwlMeetingEvidenceSyncPage(
                    mode: .timestamp,
                    requestedSince: since,
                    nextSince: evidenceItems.last?.meeting.updatedAt,
                    nextCursor: lastCursor,
                    limit: boundedLimit,
                    returnedCount: evidenceItems.count,
                    hasMore: states.count > boundedLimit
                )
            case .cursor(let rawValue, _):
                syncPage = BarnOwlMeetingEvidenceSyncPage(
                    mode: .cursor,
                    requestedCursor: rawValue,
                    nextSince: evidenceItems.last?.meeting.updatedAt,
                    nextCursor: lastCursor,
                    limit: boundedLimit,
                    returnedCount: evidenceItems.count,
                    hasMore: states.count > boundedLimit
                )
            }
            let batch = BarnOwlMeetingEvidenceBatch(
                items: evidenceItems,
                sync: syncPage
            )
            return controlStatusResponse(
                message: "Barn Owl meeting evidence batch.",
                meetingEvidenceBatch: batch
            )
        } catch {
            return controlStatusResponse(
                ok: false,
                message: "Could not export meeting evidence batch.",
                error: BarnOwlErrorFormatter.message(for: error)
            )
        }
    }

    func controlMeetingExportEventBatchResponse(
        since rawSince: String?,
        cursor rawCursor: String? = nil,
        limit: Int
    ) async -> BarnOwlControlResponse {
        let trimmedSince = rawSince?.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedCursor = rawCursor?.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasSince = !(trimmedSince?.isEmpty ?? true)
        let hasCursor = !(trimmedCursor?.isEmpty ?? true)

        guard hasSince || hasCursor else {
            return controlStatusResponse(
                ok: false,
                message: "meeting_export_events requires --since or --cursor.",
                errorCode: "missing_sync_anchor",
                error: "Provide an ISO-8601 timestamp or an opaque cursor."
            )
        }
        guard !(hasSince && hasCursor) else {
            return controlStatusResponse(
                ok: false,
                message: "meeting_export_events accepts either --since or --cursor, not both.",
                errorCode: "conflicting_sync_anchor",
                error: "Choose one incremental sync mode."
            )
        }

        do {
            let boundedLimit = max(1, min(limit, 100))
            let database = try makeDatabase()
            let syncRequest: BarnOwlMeetingExportEventSyncRequest
            let events: [BarnOwlMeetingExportEventRecord]

            if let rawCursor = trimmedCursor, hasCursor {
                guard let cursor = Self.meetingExportEventCursor(from: rawCursor) else {
                    return controlStatusResponse(
                        ok: false,
                        message: "meeting_export_events received an invalid --cursor token.",
                        errorCode: "invalid_cursor",
                        error: rawCursor
                    )
                }
                syncRequest = .cursor(rawValue: rawCursor, position: cursor)
                events = try await database.meetingExportEvents(
                    after: cursor.occurredAt,
                    eventID: cursor.eventID,
                    limit: boundedLimit + 1
                )
            } else if let rawSince = trimmedSince,
                      let since = Self.meetingEvidenceSyncDate(from: rawSince) {
                syncRequest = .timestamp(since)
                events = try await database.meetingExportEvents(
                    since: since,
                    limit: boundedLimit + 1
                )
            } else {
                return controlStatusResponse(
                    ok: false,
                    message: "meeting_export_events received an invalid --since timestamp.",
                    errorCode: "invalid_since",
                    error: trimmedSince
                )
            }

            let pageEvents = Array(events.prefix(boundedLimit))
            let items = pageEvents.compactMap(Self.meetingExportEvent(from:))
            let lastCursor = pageEvents.last.flatMap(Self.meetingExportEventCursorToken(from:))
            let syncPage: BarnOwlMeetingExportEventSyncPage
            switch syncRequest {
            case .timestamp(let since):
                syncPage = BarnOwlMeetingExportEventSyncPage(
                    mode: .timestamp,
                    requestedSince: since,
                    nextSince: pageEvents.last?.occurredAt,
                    nextCursor: lastCursor,
                    limit: boundedLimit,
                    returnedCount: items.count,
                    hasMore: events.count > boundedLimit
                )
            case .cursor(let rawValue, _):
                syncPage = BarnOwlMeetingExportEventSyncPage(
                    mode: .cursor,
                    requestedCursor: rawValue,
                    nextSince: pageEvents.last?.occurredAt,
                    nextCursor: lastCursor,
                    limit: boundedLimit,
                    returnedCount: items.count,
                    hasMore: events.count > boundedLimit
                )
            }
            return controlStatusResponse(
                message: "Barn Owl meeting export event batch.",
                meetingExportEventBatch: BarnOwlMeetingExportEventBatch(
                    items: items,
                    sync: syncPage
                )
            )
        } catch {
            return controlStatusResponse(
                ok: false,
                message: "Could not export meeting event batch.",
                error: BarnOwlErrorFormatter.message(for: error)
            )
        }
    }

    private nonisolated static func meetingEvidenceSyncDate(from rawValue: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: rawValue) {
            return date
        }

        let standard = ISO8601DateFormatter()
        standard.formatOptions = [.withInternetDateTime]
        return standard.date(from: rawValue)
    }

    private enum BarnOwlMeetingEvidenceSyncRequest {
        case timestamp(Date)
        case cursor(rawValue: String, position: BarnOwlMeetingEvidenceCursor)
    }

    private enum BarnOwlMeetingExportEventSyncRequest {
        case timestamp(Date)
        case cursor(rawValue: String, position: BarnOwlMeetingExportEventCursor)
    }

    private struct BarnOwlMeetingEvidenceCursor: Codable {
        var updatedAt: Date
        var meetingID: UUID
    }

    private struct BarnOwlMeetingExportEventCursor: Codable {
        var occurredAt: Date
        var eventID: UUID
    }

    private nonisolated static func meetingEvidenceCursorToken(
        from state: BarnOwlMeetingState
    ) -> String? {
        let cursor = BarnOwlMeetingEvidenceCursor(
            updatedAt: state.updatedAt,
            meetingID: state.id
        )
        guard let data = try? JSONEncoder().encode(cursor) else {
            return nil
        }
        return data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private nonisolated static func meetingEvidenceCursor(
        from rawValue: String
    ) -> BarnOwlMeetingEvidenceCursor? {
        let normalized = rawValue
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let padding = String(repeating: "=", count: (4 - normalized.count % 4) % 4)
        guard let data = Data(base64Encoded: normalized + padding),
              let cursor = try? JSONDecoder().decode(BarnOwlMeetingEvidenceCursor.self, from: data) else {
            return nil
        }
        return cursor
    }

    private nonisolated static func meetingExportEventCursorToken(
        from event: BarnOwlMeetingExportEventRecord
    ) -> String? {
        let cursor = BarnOwlMeetingExportEventCursor(
            occurredAt: event.occurredAt,
            eventID: event.id
        )
        guard let data = try? JSONEncoder().encode(cursor) else {
            return nil
        }
        return data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private nonisolated static func meetingExportEventCursor(
        from rawValue: String
    ) -> BarnOwlMeetingExportEventCursor? {
        let normalized = rawValue
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let padding = String(repeating: "=", count: (4 - normalized.count % 4) % 4)
        guard let data = Data(base64Encoded: normalized + padding),
              let cursor = try? JSONDecoder().decode(BarnOwlMeetingExportEventCursor.self, from: data) else {
            return nil
        }
        return cursor
    }

    private nonisolated static func meetingExportEvent(
        from record: BarnOwlMeetingExportEventRecord
    ) -> BarnOwlMeetingExportEvent? {
        guard let kind = BarnOwlMeetingExportEventKind(rawValue: record.type.rawValue) else {
            return nil
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let meetingEvidence = record.envelopeJSON
            .flatMap { $0.data(using: .utf8) }
            .flatMap { try? decoder.decode(BarnOwlMeetingEvidenceEnvelope.self, from: $0) }
        return BarnOwlMeetingExportEvent(
            id: record.id,
            type: kind,
            meetingID: record.meetingID,
            meetingStableKey: record.meetingStableKey,
            occurredAt: record.occurredAt,
            schemaVersion: record.schemaVersion,
            meetingEvidence: meetingEvidence,
            tombstoneReason: record.tombstoneReason
        )
    }

    private func meetingEvidenceEnvelope(
        from state: BarnOwlMeetingState,
        policy: BarnOwlMeetingEvidenceContentPolicy,
        includeTranscriptSegments: Bool
    ) -> BarnOwlMeetingEvidenceEnvelope {
        let meetingKey = "barnowl:meeting:\(state.id.uuidString)"
        let transcriptReady = !state.transcriptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let notesReady = !state.generatedNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let summaryOverview = state.summary?.overview.trimmingCharacters(in: .whitespacesAndNewlines)
        let summaryReady = summaryOverview?.isEmpty == false
        let usedFallbackSummary = state.summary?.overview.contains(Self.summaryFallbackMarker) == true
            || state.generatedNotes.contains(Self.summaryFallbackMarker)
        let repairRecommended = usedFallbackSummary
        let ingestReadiness = meetingEvidenceReadiness(
            state: state,
            transcriptReady: transcriptReady,
            notesReady: notesReady,
            summaryReady: summaryReady,
            repairRecommended: repairRecommended
        )
        let lastSuccessfulProcessingAt = state.jobs
            .filter { $0.status == .succeeded }
            .compactMap(\.completedAt)
            .max() ?? (state.status == .completed ? state.updatedAt : nil)
        let participants = (state.meetingFacts?.participants ?? []).map {
            BarnOwlMeetingEvidenceParticipant(displayName: $0, roleHint: "participant")
        }
        let portableFacts = state.meetingFacts.map {
            BarnOwlMeetingEvidenceMeetingFacts(
                title: $0.title,
                meetingType: $0.meetingType,
                participants: $0.participants,
                customers: $0.customers,
                organizations: $0.organizations,
                projects: $0.projects,
                goals: $0.goals,
                extensions: $0.glossary
            )
        }
        let derivedSummary = policy.allowsSummaryText
            ? summaryOverview.flatMap { $0.isEmpty ? nil : BarnOwlMeetingEvidenceSummary(overview: $0) }
            : nil
        let derived = BarnOwlMeetingEvidenceDerived(
            summary: derivedSummary,
            decisions: policy.allowsStructuredOutputs ? state.decisions : [],
            actionItems: policy.allowsStructuredOutputs ? state.actionItems : [],
            openQuestions: policy.allowsStructuredOutputs ? state.openQuestions : [],
            meetingFacts: policy.allowsStructuredOutputs ? portableFacts : nil
        )
        let transcriptSegments = includeTranscriptSegments && policy.allowsTranscriptText
            ? state.transcriptSegments
                .sorted { $0.sequence < $1.sequence }
                .map {
                    BarnOwlMeetingEvidenceTranscriptSegment(
                        sequence: $0.sequence,
                        speakerLabel: $0.speakerLabel,
                        text: $0.text,
                        startTime: $0.startTime,
                        endTime: $0.endTime,
                        confidence: $0.confidence
                    )
                }
            : nil
        let producerVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development"
        return BarnOwlMeetingEvidenceEnvelope(
            source: BarnOwlMeetingEvidenceSource(
                producer: "barnowl",
                producerVersion: producerVersion,
                tenantScope: "local_user"
            ),
            meeting: BarnOwlMeetingEvidenceMeeting(
                id: state.id,
                stableKey: meetingKey,
                externalID: state.meeting.externalID,
                title: state.title,
                meetingType: state.meetingFacts?.meetingType,
                startedAt: state.startedAt,
                endedAt: state.endedAt,
                updatedAt: state.updatedAt
            ),
            participants: participants,
            artifacts: BarnOwlMeetingEvidenceArtifacts(
                transcript: BarnOwlMeetingEvidenceArtifact(
                    pointer: "\(meetingKey)#transcript",
                    ready: transcriptReady,
                    text: policy.allowsTranscriptText ? state.transcriptText : nil
                ),
                notes: BarnOwlMeetingEvidenceArtifact(
                    pointer: "\(meetingKey)#notes",
                    ready: notesReady
                ),
                summary: BarnOwlMeetingEvidenceArtifact(
                    pointer: "\(meetingKey)#summary",
                    ready: summaryReady
                ),
                actions: BarnOwlMeetingEvidenceArtifact(
                    pointer: "\(meetingKey)#actions",
                    ready: !state.actionItems.isEmpty || !state.decisions.isEmpty
                )
            ),
            derived: derived,
            transcriptSegments: transcriptSegments,
            processing: BarnOwlMeetingEvidenceProcessing(
                state: state.status?.rawValue ?? "unknown",
                ingestReadiness: ingestReadiness,
                transcriptReady: transcriptReady,
                notesReady: notesReady,
                summaryReady: summaryReady,
                usedFallbackSummary: usedFallbackSummary,
                repairRecommended: repairRecommended,
                lastSuccessfulProcessingAt: lastSuccessfulProcessingAt
            ),
            provenance: BarnOwlMeetingEvidenceProvenance(
                sourceOfTruth: "barnowl",
                contentPolicy: policy,
                generatedAt: Date()
            )
        )
    }

    private func meetingEvidenceReadiness(
        state: BarnOwlMeetingState,
        transcriptReady: Bool,
        notesReady: Bool,
        summaryReady: Bool,
        repairRecommended: Bool
    ) -> BarnOwlMeetingEvidenceIngestReadiness {
        if repairRecommended {
            return .requiresRepair
        }
        if state.status == .failed, !transcriptReady, !notesReady, !summaryReady {
            return .blocked
        }
        if state.status == .completed, transcriptReady, notesReady, summaryReady {
            return .ready
        }
        if transcriptReady, summaryReady {
            return .readyWithCaveat
        }
        return .notReady
    }

    func controlChatResponse(question: String) async -> BarnOwlControlResponse {
        let cleanedQuestion = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanedQuestion.isEmpty else {
            return controlStatusResponse(ok: false, message: "Chat requires a question.", error: "missing_query")
        }
        do {
            let configuration = try BarnOwlAPIKeyStore.makeConfiguration(allowKeychainPrompt: false)
            let snippets = try await chatContextSnippets(for: cleanedQuestion)
            guard !snippets.isEmpty else {
                return controlStatusResponse(
                    ok: false,
                    message: "No relevant Barn Owl context found.",
                    error: "no_context"
                )
            }
            let answer = try await OpenAIBarnOwlChatClient(configuration: configuration)
                .answer(question: cleanedQuestion, snippets: snippets)
            return controlStatusResponse(
                message: "Barn Owl chat answer.",
                answer: answer.answer,
                citations: answer.citations.map { BarnOwlControlCitation(id: $0) }
            )
        } catch {
            return controlStatusResponse(ok: false, message: "Barn Owl chat failed.", error: BarnOwlErrorFormatter.message(for: error))
        }
    }

    func controlExportDeveloperDiagnosticsResponse(outputPath: String?) async -> BarnOwlControlResponse {
        do {
            let outputURL = Self.developerDiagnosticsExportURL(outputPath: outputPath)
            let entries = try await diagnosticsStore.recentEntries(limit: 80)
            let snapshot = BarnOwlDeveloperDiagnosticsExporter.makeSnapshot(
                readinessLines: BarnOwlSettingsReadinessChecks.lines(),
                diagnosticsEntries: entries
            )
            let report = BarnOwlDeveloperDiagnosticsExporter.makeReport(snapshot)
            try BarnOwlDeveloperDiagnosticsExporter.export(report, to: outputURL)
            return controlStatusResponse(
                message: "Exported redacted developer diagnostics.",
                diagnosticsPath: outputURL.path(percentEncoded: false),
                nextCommand: "Share the diagnostics file with the Barn Owl maintainer."
            )
        } catch {
            return controlStatusResponse(
                ok: false,
                message: "Could not export developer diagnostics.",
                error: BarnOwlErrorFormatter.message(for: error)
            )
        }
    }

    func controlPermissionsCheckResponse() -> BarnOwlControlResponse {
        publishRecordingReadinessSummary()
        let snapshot = BarnOwlFirstRunReadiness.currentSnapshot()
        let lines = BarnOwlSettingsReadinessChecks.lines()
        let nextCommand = snapshot.menuBarSetupNeeded
            ? "barnowl permissions test"
            : "barnowl start"
        return controlStatusResponse(
            message: snapshot.summary,
            summary: lines.joined(separator: "\n"),
            nextCommand: nextCommand
        )
    }

    func controlPermissionsTestResponse() async -> BarnOwlControlResponse {
        guard !stateMachine.state.canStopRecording else {
            return controlStatusResponse(
                ok: false,
                message: "Stop the active recording before running the local capture test.",
                nextCommand: "barnowl stop",
                error: "active_recording"
            )
        }

        captureStatus = "Requesting microphone permission."
        let microphoneDecision = await BarnOwlFirstRunReadiness.requestMicrophoneDecision()
        guard microphoneDecision == .granted else {
            BarnOwlFirstRunReadiness.clearLocalCaptureReadiness()
            publishRecordingReadinessSummary()
            let message = BarnOwlFirstRunReadiness.microphonePermissionBlockedMessage(for: microphoneDecision)
            captureStatus = message
            lastError = message
            return controlStatusResponse(
                ok: false,
                message: message,
                summary: BarnOwlSettingsReadinessChecks.lines().joined(separator: "\n"),
                nextCommand: BarnOwlFirstRunReadiness.microphonePermissionRecoveryCommand(for: microphoneDecision),
                error: "microphone_permission_blocked"
            )
        }

        let hasSystemAudioEvidence = BarnOwlFirstRunReadiness.hasSystemAudioCaptureEvidence()
        captureStatus = hasSystemAudioEvidence
            ? "Checking system audio readiness."
            : "Requesting system audio permission."
        let systemAudioDecision = BarnOwlFirstRunReadiness.requestSystemAudioDecisionIfNeeded()
        if systemAudioDecision != .granted {
            recordActivity(
                level: .warning,
                category: "capture",
                message: "System audio permission is not confirmed yet.",
                details: hasSystemAudioEvidence
                    ? "Barn Owl has prior system-audio capture evidence and will verify capture during the local test."
                    : "Barn Owl will run the local capture test so macOS can show the required permission prompt if needed.",
                updatePreview: false
            )
        }

        captureStatus = "Running local mic/system-audio capture test."
        do {
            let result = try await BarnOwlLocalCaptureReadinessTest.run()
            result.applyReadinessMarkers()
            publishRecordingReadinessSummary()
            captureStatus = result.summary
            return controlStatusResponse(
                message: result.summary,
                summary: BarnOwlSettingsReadinessChecks.lines().joined(separator: "\n"),
                nextCommand: result.capturedAllRequiredTracks ? "barnowl start" : "Play audio from another app, then rerun `barnowl permissions test`."
            )
        } catch {
            BarnOwlFirstRunReadiness.clearSystemAudioCaptureReadiness()
            publishRecordingReadinessSummary()
            let message = "Local capture test failed: \(BarnOwlErrorFormatter.message(for: error))"
            captureStatus = message
            lastError = message
            return controlStatusResponse(
                ok: false,
                message: message,
                summary: BarnOwlSettingsReadinessChecks.lines().joined(separator: "\n"),
                nextCommand: "Open Barn Owl Settings, grant Microphone and Screen/System Audio Recording, then rerun `barnowl permissions test`.",
                error: "permissions_test_failed"
            )
        }
    }

    func controlAskNotesResponse(question: String, meetingID requestedMeetingID: UUID? = nil) async -> BarnOwlControlResponse {
        let cleanedQuestion = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanedQuestion.isEmpty else {
            return controlStatusResponse(ok: false, message: "ask_notes requires a question.", error: "missing_question")
        }

        do {
            let database = try makeDatabase()
            if let meetingID = await resolveQuickCommandMeetingID(requestedMeetingID),
               let state = try await database.meetingState(id: meetingID) {
                return controlStatusResponse(
                    message: "Barn Owl notes answer.",
                    meeting: controlMeeting(from: state),
                    answer: Self.localNotesAnswer(question: cleanedQuestion, state: state),
                    citations: [BarnOwlControlCitation(id: meetingID.uuidString, title: state.title)],
                    activeMeetingID: meetingID,
                    jobState: await controlJobState(for: meetingID)
                )
            }

            let results = try await database.searchLibrary(BarnOwlDatabaseSearchQuery(text: cleanedQuestion, limit: 5))
            guard !results.isEmpty else {
                return controlStatusResponse(ok: false, message: "No relevant Barn Owl notes found.", error: "no_context")
            }
            let meetings = results.map {
                BarnOwlControlMeeting(
                    id: $0.meeting.id,
                    title: $0.meeting.title,
                    startedAt: $0.meeting.startedAt,
                    endedAt: $0.meeting.endedAt,
                    overview: $0.snippet,
                    meetingType: $0.meetingType,
                    status: $0.status?.rawValue
                )
            }
            return controlStatusResponse(
                message: "Barn Owl notes answer.",
                meetings: meetings,
                answer: results.prefix(3).map { "\($0.meeting.title): \($0.snippet)" }.joined(separator: "\n\n"),
                citations: results.map { BarnOwlControlCitation(id: $0.meeting.id.uuidString, title: $0.meeting.title) },
                activeMeetingID: meetings.first?.id,
                jobState: await controlJobState(for: meetings.first?.id)
            )
        } catch {
            return controlStatusResponse(
                ok: false,
                message: "Could not answer from Barn Owl notes.",
                error: BarnOwlErrorFormatter.message(for: error)
            )
        }
    }

    private func controlMeeting(from state: BarnOwlMeetingState) -> BarnOwlControlMeeting {
        return BarnOwlControlMeeting(
            id: state.id,
            title: state.title,
            startedAt: state.startedAt,
            endedAt: state.endedAt,
            overview: state.summary?.overview ?? Self.searchSnippet(in: state.generatedNotes, query: ""),
            meetingType: state.meetingFacts?.meetingType,
            status: state.status?.rawValue
        )
    }

    private func controlJob(from job: BarnOwlJobRecord) -> BarnOwlControlJob {
        BarnOwlControlJob(
            id: job.id,
            meetingID: job.meetingID,
            type: job.type,
            status: job.status.rawValue,
            attemptCount: job.attemptCount,
            errorMessage: Self.sanitizedControlString(job.errorMessage),
            updatedAt: job.updatedAt
        )
    }

    private func controlEnrichmentSource(
        from source: BarnOwlEnrichmentSourceRecord,
        usefulness: BarnOwlEnrichmentSourceUsefulnessRecord? = nil
    ) -> BarnOwlControlEnrichmentSource {
        BarnOwlControlEnrichmentSource(
            id: source.id,
            displayName: source.displayName,
            sourceType: source.sourceType,
            enabled: source.enabled,
            scope: source.scope.rawValue,
            scopeLabel: source.scope.displayName,
            authorityProfile: source.authorityProfile,
            bestUsedFor: source.bestUsedFor,
            authState: source.authState.rawValue,
            healthStatus: source.healthStatus.rawValue,
            healthLabel: source.healthStatus.displayName,
            lastCheckedAt: source.lastCheckedAt,
            lastSuccessfulCheckAt: source.lastSuccessfulCheckAt,
            lastFailedCheckAt: source.lastFailedCheckAt,
            connectorReference: source.connectorReference,
            privacyCopyPolicy: source.privacyCopyPolicy,
            queryBudgetPolicy: source.queryBudgetPolicy,
            attempts: usefulness?.attempts ?? 0,
            evidenceItems: usefulness?.evidenceItems ?? 0,
            acceptedEvidenceItems: usefulness?.acceptedEvidenceItems ?? 0,
            supportedJobs: usefulness?.supportedJobs ?? 0,
            heldJobs: usefulness?.heldJobs ?? 0,
            conflictingJobs: usefulness?.conflictingJobs ?? 0,
            failedJobs: usefulness?.failedJobs ?? 0,
            lastOutcomeStatus: usefulness?.lastOutcomeStatus?.rawValue
        )
    }

    private func controlEnrichmentConflict(
        from conflict: BarnOwlEnrichmentConflictRecord
    ) -> BarnOwlControlEnrichmentConflict {
        BarnOwlControlEnrichmentConflict(
            id: conflict.id,
            jobID: conflict.jobID,
            ownerID: conflict.ownerID,
            conceptKey: conflict.conceptKey,
            summary: conflict.summary,
            conflictingSourceIDs: conflict.conflictingSourceIDs,
            createdAt: conflict.createdAt
        )
    }

    private nonisolated func controlConceptHistory(
        conceptKey: String,
        history: BarnOwlEnrichmentConceptHistory
    ) -> BarnOwlControlEnrichmentConceptHistory {
        BarnOwlControlEnrichmentConceptHistory(
            conceptKey: conceptKey,
            supportedCandidateJobs: history.supportedCandidateJobs,
            conflictingJobs: history.conflictingJobs,
            negativeEvidenceItems: history.negativeEvidenceItems,
            requiresConflictMemoryHold: history.requiresConflictMemoryHold
        )
    }

    private nonisolated func controlEnrichmentAuthorityProfile(
        from profile: BarnOwlEnrichmentAuthorityProfileRecord
    ) -> BarnOwlControlEnrichmentAuthorityProfile {
        BarnOwlControlEnrichmentAuthorityProfile(
            id: profile.id,
            displayName: profile.displayName,
            description: profile.description,
            strongestEntityKinds: profile.strongestEntityKinds,
            weakestEntityKinds: profile.weakestEntityKinds,
            defaultWeight: profile.defaultWeight,
            builtIn: profile.builtIn
        )
    }

    private nonisolated func controlEnrichmentPolicyPack(
        from pack: BarnOwlEnrichmentPolicyPackRecord
    ) -> BarnOwlControlEnrichmentPolicyPack {
        BarnOwlControlEnrichmentPolicyPack(
            id: pack.id,
            displayName: pack.displayName,
            description: pack.description,
            minimumSupportingEvidenceCount: pack.minimumSupportingEvidenceCount,
            minimumIndependentSourceCountAfterConflictMemory: pack.minimumIndependentSourceCountAfterConflictMemory,
            active: pack.active
        )
    }

    private nonisolated func controlKnowledgeEntity(
        from entity: BarnOwlKnowledgeEntityRecord
    ) -> BarnOwlControlKnowledgeEntity {
        BarnOwlControlKnowledgeEntity(
            id: entity.id,
            kind: entity.kind,
            canonicalName: entity.canonicalName,
            summary: entity.summary,
            confidence: entity.confidence,
            sourceJobID: entity.sourceJobID,
            lifecycleStatus: entity.lifecycleStatus.rawValue,
            lifecycleReason: entity.lifecycleReason,
            lifecycleUpdatedAt: entity.lifecycleUpdatedAt,
            createdAt: entity.createdAt,
            updatedAt: entity.updatedAt
        )
    }

    private func controlEnrichmentJob(
        from job: BarnOwlEnrichmentJobRecord,
        evidenceCount: Int
    ) -> BarnOwlControlEnrichmentJob {
        BarnOwlControlEnrichmentJob(
            id: job.id,
            ownerID: job.ownerID,
            conceptKey: job.conceptKey,
            requestedSources: job.requestedSources,
            selectedSources: job.selectedSources,
            status: job.status.rawValue,
            statusLabel: job.status.displayName,
            summary: job.summary,
            rationale: job.rationale,
            evidenceCount: evidenceCount,
            createdAt: job.createdAt,
            updatedAt: job.updatedAt,
            finishedAt: job.finishedAt
        )
    }

    private func controlContextItem(from item: BarnOwlExternalContextItemRecord) -> BarnOwlControlContextItem {
        BarnOwlControlContextItem(
            id: item.id,
            meetingID: item.meetingID,
            source: item.source,
            body: item.body,
            state: item.state.rawValue,
            createdAt: item.createdAt,
            usedInNoteGeneration: item.usedInNoteGeneration
        )
    }

    private func controlContextItems(from state: BarnOwlMeetingState) -> [BarnOwlControlContextItem] {
        var items = state.externalContextItems.map {
            controlContextItem(from: $0)
        }
        if let contextUsed = state.output(kind: "context_used"),
           !contextUsed.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            items.append(BarnOwlControlContextItem(
                id: contextUsed.id,
                meetingID: contextUsed.meetingID,
                source: "note-renderer",
                body: contextUsed.content,
                state: "accepted",
                createdAt: contextUsed.createdAt,
                usedInNoteGeneration: true
            ))
        }
        return items.sorted { $0.createdAt < $1.createdAt }
    }

    private static func localNotesAnswer(question: String, state: BarnOwlMeetingState) -> String {
        let lowercasedQuestion = question.lowercased()
        if lowercasedQuestion.contains("action") && !state.actionItems.isEmpty {
            return "Action items from \(state.title):\n" + state.actionItems.map { "- \($0)" }.joined(separator: "\n")
        }
        if lowercasedQuestion.contains("decid") && !state.decisions.isEmpty {
            return "Decisions from \(state.title):\n" + state.decisions.map { "- \($0)" }.joined(separator: "\n")
        }
        if lowercasedQuestion.contains("participant") || lowercasedQuestion.contains("who") {
            let participants = state.meetingFacts?.participants ?? []
            if !participants.isEmpty {
                return "Participants from \(state.title): \(participants.joined(separator: ", "))."
            }
        }
        if let overview = state.summary?.overview,
           !overview.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "\(state.title): \(overview)"
        }
        let searchable = state.generatedNotes.isEmpty ? state.transcriptText : state.generatedNotes
        let snippet = searchSnippet(in: searchable, query: question)
        return snippet.isEmpty
            ? "I found \(state.title), but it does not have enough notes yet to answer that directly."
            : "\(state.title): \(snippet)"
    }

    private static func developerDiagnosticsExportURL(outputPath: String?) -> URL {
        if let outputPath = outputPath?.trimmingCharacters(in: .whitespacesAndNewlines),
           !outputPath.isEmpty {
            return URL(fileURLWithPath: outputPath).standardizedFileURL
        }
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        return downloads.appending(path: BarnOwlDeveloperDiagnosticsExporter.defaultFileName())
    }

    private func controlMarkdown(for meetingID: UUID, database: BarnOwlDatabase) async -> String {
        if let markdown = try? await database.meetingOutputs(meetingID: meetingID, kind: "markdown").first?.content {
            return markdown
        }
        if let artifact = try? await makeLibraryStore().artifact(id: meetingID) {
            return artifact.markdown
        }
        return ""
    }

    private func controlSummary(for meetingID: UUID, database: BarnOwlDatabase) async -> String {
        if let summary = try? await database.meetingOutputs(meetingID: meetingID, kind: "summary").first?.content {
            return summary
        }
        let markdown = await controlMarkdown(for: meetingID, database: database)
        return Self.markdownSection(namedAnyOf: ["Summary"], in: markdown)
    }

    private func controlTranscript(for meetingID: UUID, database: BarnOwlDatabase) async -> String {
        if let segments = try? await database.transcriptSegments(meetingID: meetingID, variant: .final),
           !segments.isEmpty {
            return segments
                .map { "\($0.speakerLabel ?? "Speaker"): \($0.text)" }
                .joined(separator: "\n")
        }
        let markdown = await controlMarkdown(for: meetingID, database: database)
        return Self.markdownSection(namedAnyOf: ["Transcript"], in: markdown)
    }

    private func controlContextItems(for meetingID: UUID, database: BarnOwlDatabase) async -> [BarnOwlControlContextItem] {
        let externalItems = (try? await database.externalContextItems(meetingID: meetingID, limit: 100)) ?? []
        var items = externalItems.map {
            BarnOwlControlContextItem(
                id: $0.id,
                meetingID: $0.meetingID,
                source: $0.source,
                body: $0.body,
                state: $0.state.rawValue,
                createdAt: $0.createdAt,
                usedInNoteGeneration: $0.usedInNoteGeneration
            )
        }

        if let contextUsed = try? await database.meetingOutputs(meetingID: meetingID, kind: "context_used").first,
           !contextUsed.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            items.append(BarnOwlControlContextItem(
                id: contextUsed.id,
                meetingID: contextUsed.meetingID,
                source: "note-renderer",
                body: contextUsed.content,
                state: "accepted",
                createdAt: contextUsed.createdAt,
                usedInNoteGeneration: true
            ))
        }
        return items.sorted { $0.createdAt < $1.createdAt }
    }

    private func apply(_ result: RecordingTransitionResult) {
        switch result {
        case .accepted(let state):
            status = state.status
            activeSession = state.activeSession
            if case .failed(let failure) = state {
                lastError = failure.message
            }
        case .rejected(let failure):
            lastError = failure.message
            status = .failed
        }
    }

    private func fail(
        reason: RecordingFailureReason,
        message: String,
        sessionID: UUID?,
        preview: String
    ) {
        apply(stateMachine.fail(
            RecordingFailure(
                reason: reason,
                message: message,
                sessionID: sessionID
            )
        ))
        liveTranscriptPreview = preview
        captureStatus = message
        recordActivity(
            level: .error,
            category: "failure",
            message: message,
            sessionID: sessionID,
            updatePreview: false
        )
    }

    private func captureFailureReason(for error: Error) -> RecordingFailureReason {
        switch error {
        case AudioCaptureError.permissionDenied:
            .permissionDenied
        case AudioCaptureError.sourceUnavailable:
            .captureUnavailable
        case AudioCaptureError.alreadyRunning:
            .alreadyRecording
        default:
            .captureFailed
        }
    }

    private func captureFailureMessage(for error: Error) -> String {
        switch error {
        case AudioCaptureError.permissionDenied:
            Self.microphoneAndSystemAudioPermissionMessage
        case AudioCaptureError.sourceUnavailable:
            "Barn Owl could not find an available microphone or system audio source."
        case AudioCaptureError.alreadyRunning:
            "A recording is already running."
        default:
            "Barn Owl could not start recording."
        }
    }

    nonisolated private static let microphoneAndSystemAudioPermissionMessage =
        "Barn Owl needs Microphone and Screen/System Audio Recording permissions before recording."

    private func processingFailureMessage(for error: Error) -> String {
        switch error {
        case OpenAIConfigurationError.missingAPIKey:
            "Add an OpenAI API key in Barn Owl Settings before generating transcripts."
        case BarnOwlMeetingProcessingError.noRecordedAudioFiles:
            "Barn Owl stopped recording but did not find any temporary audio chunks to transcribe."
        case OpenAITranscriptionClientError.unsuccessfulStatusCode:
            BarnOwlErrorFormatter.message(for: error)
        case OpenAITranscriptionClientError.responseDecodingFailed:
            BarnOwlErrorFormatter.message(for: error)
        case OpenAIResponsesClientError.unsuccessfulStatusCode:
            BarnOwlErrorFormatter.message(for: error)
        case OpenAIResponsesClientError.responseDecodingFailed,
             OpenAIResponsesClientError.summaryPayloadDecodingFailed,
             OpenAIResponsesClientError.missingOutputText,
             OpenAIResponsesClientError.refused:
            BarnOwlErrorFormatter.message(for: error)
        default:
            "Barn Owl could not generate the final transcript."
        }
    }

    private static func conciseRecoveryMessage(for job: BarnOwlJobRecord) -> String {
        let type = job.type.replacingOccurrences(of: "_", with: " ").lowercased()
        if let error = job.errorMessage?.lowercased() {
            if error.contains("no recoverable audio") || error.contains("no recorded audio") {
                return "No recoverable audio chunks were found."
            }
            if error.contains("interrupted") {
                return "Processing was interrupted and can be retried."
            }
            if error.contains("transcrib") {
                return "Transcript generation failed and can be retried."
            }
            if error.contains("summary") || error.contains("note") {
                return "Note generation failed and can be retried."
            }
        }
        return "\(type.capitalized) failed and can be retried."
    }

    private func processingFailureReason(for error: Error) -> RecordingFailureReason {
        switch error {
        case OpenAIConfigurationError.missingAPIKey:
            .missingAPIKey
        default:
            .processingFailed
        }
    }

    private func handleAudioCaptureProgress(_ progress: AudioCaptureProgress, sessionID: UUID) {
        let trackName = progress.trackKind.displayName
        if let errorMessage = progress.errorMessage {
            recordRecordingHealthError(
                trackKind: progress.trackKind,
                message: errorMessage,
                sessionID: sessionID
            )
            recordActivity(
                level: .error,
                category: "capture",
                message: "Could not save \(trackName) audio chunk.",
                details: errorMessage,
                sessionID: sessionID
            )
            captureStatus = "Recording, but \(trackName) chunk saving reported an error."
            return
        }

        let sequenceDescription = progress.sequenceNumber.map { " #\($0 + 1)" } ?? ""
        if !didRecordFirstAudioChunk {
            didRecordFirstAudioChunk = true
            recordPerformance(.milestone(.firstAudioChunkCaptured, at: Self.performanceNow()))
        }
        BarnOwlFirstRunReadiness.markCaptureSucceeded(trackKind: progress.trackKind)
        if let byteCount = progress.byteCount {
            tempAudioByteCount += Int64(byteCount)
            recordPerformance(.tempAudioBytes(tempAudioByteCount, at: Self.performanceNow()))
        }
        if progress.sequenceNumber != nil {
            lastCapturedChunkAtByTrack[progress.trackKind] = Date()
        }
        let details = [
            String(format: "%.1f seconds", progress.duration),
            progress.byteCount.map { "\($0) bytes" }
        ]
            .compactMap { $0 }
            .joined(separator: " • ")
        recordActivity(
            category: "capture",
            message: "Saved \(trackName) chunk\(sequenceDescription).",
            details: details,
            sessionID: sessionID,
            updatePreview: false
        )
        enqueueRollingFinalTranscription(progress, sessionID: sessionID)
        captureStatus = "Recording. Last saved: \(trackName) chunk\(sequenceDescription)."
    }

    private func enqueueRollingFinalTranscription(_ progress: AudioCaptureProgress, sessionID: UUID) {
        guard let coordinator = rollingFinalTranscriptionCoordinator,
              let audioFile = Self.recordedAudioFile(from: progress, sessionID: sessionID)
        else {
            return
        }

        let enqueueTask = Task {
            await coordinator.enqueue(audioFile)
        }
        rollingFinalTranscriptionEnqueueTasks.append(enqueueTask)
        rollingFinalTranscriptionQueuedChunkCount += 1
        finalTranscriptionStatus = "Processing saved audio chunks (\(rollingFinalTranscriptionQueuedChunkCount) queued)."
    }

    private func drainRollingFinalTranscriptionEnqueues() async {
        let tasks = rollingFinalTranscriptionEnqueueTasks
        rollingFinalTranscriptionEnqueueTasks = []
        for task in tasks {
            await task.value
        }
    }

    static func recordedAudioFile(from progress: AudioCaptureProgress, sessionID: UUID) -> RecordedAudioFile? {
        _ = sessionID
        guard progress.errorMessage == nil,
              let sequenceNumber = progress.sequenceNumber,
              let fileURL = progress.fileURL
        else {
            return nil
        }

        return RecordedAudioFile(
            url: fileURL,
            trackLabel: progress.trackKind.displayName.capitalized,
            startTimeOffset: progress.startTimeOffset ?? 0,
            sequenceNumber: sequenceNumber,
            trackID: progress.trackKind.rawValue,
            duration: progress.duration,
            overlapDuration: progress.overlapDuration
        )
    }

    private func handleMeetingProcessingProgress(
        _ progress: MeetingProcessingProgress,
        sessionID: UUID
    ) {
        if !didRecordFinalProcessingStart {
            didRecordFinalProcessingStart = true
            recordPerformance(.phase(.finalProcessing, .started, at: Self.performanceNow()))
        }
        if !didRecordTranscriptionStart,
           progress.message.localizedCaseInsensitiveContains("Transcribing ") {
            didRecordTranscriptionStart = true
            recordPerformance(.milestone(.transcriptionStarted, at: Self.performanceNow()))
        }
        for event in progress.performanceEvents {
            recordPerformance(event)
        }
        recordActivity(
            level: progress.level,
            category: progress.category,
            message: progress.message,
            details: progress.details,
            sessionID: sessionID
        )
        persistProcessingStage(message: progress.message, sessionID: sessionID)
        progressFraction = progress.progressFraction
        captureStatus = progress.message
        finalTranscriptionStatus = progress.message
        if let transcriptPreview = progress.transcriptPreview,
           transcriptPreview.isEmpty == false {
            if !didRecordFirstFinalTranscript {
                didRecordFirstFinalTranscript = true
                recordPerformance(.milestone(.firstTranscriptReceived, at: Self.performanceNow()))
            }
            appendLiveTranscript(transcriptPreview)
        }
    }

    private func chatContextSnippets(for question: String) async throws -> [BarnOwlChatContextSnippet] {
        let database = try makeDatabase()
        var snippets: [BarnOwlChatContextSnippet] = []
        var nextIndex = 1

        func appendSnippet(title: String, source: String, text: String) {
            let cleaned = text
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "\n\n\n", with: "\n\n")
            guard !cleaned.isEmpty else { return }
            snippets.append(BarnOwlChatContextSnippet(
                id: "S\(nextIndex)",
                title: title,
                source: source,
                text: String(cleaned.prefix(1_800))
            ))
            nextIndex += 1
        }

        if let displayedNote {
            if let state = try await database.meetingState(id: displayedNote.id) {
                appendSnippet(title: state.title, source: "current-note", text: state.generatedNotes)
                appendSnippet(
                    title: "\(state.title) canonical facts",
                    source: "meeting-state",
                    text: [
                        state.meetingFacts?.contextLines.joined(separator: "\n"),
                        state.summary?.overview,
                        state.decisions.isEmpty ? nil : "Decisions:\n\(state.decisions.joined(separator: "\n"))",
                        state.actionItems.isEmpty ? nil : "Action Items:\n\(state.actionItems.joined(separator: "\n"))",
                        state.openQuestions.isEmpty ? nil : "Open Questions:\n\(state.openQuestions.joined(separator: "\n"))"
                    ]
                    .compactMap { $0 }
                    .joined(separator: "\n\n")
                )
                appendSnippet(
                    title: "\(state.title) external context",
                    source: "external-context",
                    text: state.externalContextItems.map { "[\($0.source)] \($0.body)" }.joined(separator: "\n\n")
                )
                appendSnippet(title: "\(state.title) transcript", source: "current-transcript", text: state.transcriptText)
            } else {
                appendSnippet(title: displayedNote.title, source: "current-note", text: displayedNote.markdown)
            }
        }

        let searchResults = try await database.searchLibrary(BarnOwlDatabaseSearchQuery(text: question, limit: 6))
        for result in searchResults where !snippets.contains(where: { $0.title == result.meeting.title && $0.source == "current-note" }) {
            if let state = try await database.meetingState(id: result.meeting.id) {
                appendSnippet(title: state.title, source: "meeting-note", text: state.generatedNotes)
                appendSnippet(
                    title: "\(state.title) canonical facts",
                    source: "meeting-state",
                    text: [
                        state.meetingFacts?.contextLines.joined(separator: "\n"),
                        state.summary?.overview,
                        state.decisions.isEmpty ? nil : "Decisions:\n\(state.decisions.joined(separator: "\n"))",
                        state.actionItems.isEmpty ? nil : "Action Items:\n\(state.actionItems.joined(separator: "\n"))"
                    ]
                    .compactMap { $0 }
                    .joined(separator: "\n\n")
                )
                appendSnippet(
                    title: "\(state.title) external context",
                    source: "external-context",
                    text: state.externalContextItems.map { "[\($0.source)] \($0.body)" }.joined(separator: "\n\n")
                )
            } else {
                appendSnippet(title: result.meeting.title, source: "meeting-search", text: result.snippet)
            }
        }

        let wantsRecentContext = question.localizedCaseInsensitiveContains("recent")
            || question.localizedCaseInsensitiveContains("last meeting")
            || question.localizedCaseInsensitiveContains("what changed")
            || question.localizedCaseInsensitiveContains("decide")
            || question.localizedCaseInsensitiveContains("action")
        if searchResults.isEmpty || wantsRecentContext {
            let recentStates = try await database.meetingStates(limit: 6)
            for state in recentStates where !snippets.contains(where: { $0.title == state.title }) {
                appendSnippet(
                    title: state.title,
                    source: state.generatedNotes.isEmpty ? "recent-meeting" : "recent-meeting-note",
                    text: state.generatedNotes.isEmpty
                        ? [state.title, state.summary?.overview].compactMap { $0 }.joined(separator: "\n")
                        : state.generatedNotes
                )
            }
        }

        if let contextRoot = try? BarnOwlMeetingProcessor.defaultContextRoot() {
            let contextItems = try? await LocalMarkdownContextProvider(rootDirectory: contextRoot)
                .search(ContextQuery(text: question, limit: 4))
            for item in contextItems ?? [] {
                appendSnippet(title: item.title, source: item.source, text: item.body)
            }
        }

        return Array(snippets.prefix(12))
    }

    private func handleFinalProcessingSucceeded(session: RecordingSession, markdownURL: URL) async {
        recordPerformance(.milestone(.finalTranscriptReceived, at: Self.performanceNow()))
        recordPerformance(.milestone(.finalProcessingFinished, at: Self.performanceNow()))
        recordPerformance(.phase(.finalProcessing, .finished, at: Self.performanceNow()))
        recordPerformance(.phase(.cleanup, .started, at: Self.performanceNow()))
        do {
            let cleanupReport = try await BarnOwlAudioCaptureFactory.finalizeTemporaryAudio(for: session.id)
            tempAudioByteCount = 0
            recordPerformance(.tempAudioBytes(0, at: Self.performanceNow()))
            recordActivity(
                category: "capture",
                message: "Temporary audio finalized.",
                details: "\(cleanupReport.finalizedChunkCount) chunk metadata record(s) finalized.",
                sessionID: session.id,
                updatePreview: false
            )
        } catch {
            recordActivity(
                level: .error,
                category: "capture",
                message: "Temporary audio cleanup needs attention.",
                details: BarnOwlErrorFormatter.message(for: error),
                sessionID: session.id,
                updatePreview: false
            )
            captureStatus = "Saved transcript and notes, but temporary audio cleanup needs attention."
            finalTranscriptionStatus = "Final transcript saved; cleanup needs attention."
            progressFraction = 1
            await refreshRecoveryAttentionItems()
            return
        }
        recordPerformance(.phase(.cleanup, .finished, at: Self.performanceNow()))
        await persistSessionState(session, status: .completed, endedAt: session.endedAt ?? Date())
        await persistProcessedArtifact(sessionID: session.id)
        await recordMeetingExportSnapshotEvent(
            meetingID: session.id,
            type: .processingCompleted
        )
        progressFraction = 1
        liveTranscriptPreview = "Saved notes to \(markdownURL.lastPathComponent)."
        captureStatus = "Saved transcript and notes. Temporary audio deleted."
        finalTranscriptionStatus = "Final transcript and notes saved."
        recordActivity(
            category: "jobs",
            message: "Final processing job complete.",
            details: markdownURL.lastPathComponent,
            sessionID: session.id
        )
        recordPerformanceActivity(sessionID: session.id)
        await refreshRecentSessions()
        await openRecentSession(session.id)
        await preparePostProcessingContextReview(for: session.id)
        await refreshContextInbox()
        await refreshRecoveryAttentionItems()
        await refreshProcessingTimeline(meetingID: session.id)
        resetMenuCaptureStatusAfterCompletion()
        scheduleReadyResetAfterCompletion()
    }

    private func handleFinalProcessingFailed(session: RecordingSession?, error: Error, willRetry: Bool) async {
        if Self.isOpenAIAuthenticationFailure(error) {
            BarnOwlAPIKeyStore.invalidateCachedAPIKeyAfterAuthenticationFailure()
        }
        let sessionID = session?.id
        let message = if session == nil && willRetry {
            "Summary repair will retry. Last attempt did not complete."
        } else if willRetry && BarnOwlProcessingRetryPolicy.shouldKeepQueuedForConnectivity(error) {
            "Saved locally. Final processing will retry when network is available."
        } else {
            willRetry ? "Final processing job will retry." : "Final processing job failed."
        }
        recordActivity(
            level: .warning,
            category: "jobs",
            message: message,
            details: BarnOwlErrorFormatter.message(for: error),
            sessionID: sessionID,
            updatePreview: false
        )
        if let session, !willRetry {
            await persistSessionState(session, status: .failed, endedAt: session.endedAt ?? Date())
            recordActivity(
                level: .warning,
                category: "retention",
                message: "Temporary audio preserved for retry.",
                details: "Barn Owl will delete it after final processing succeeds or when you delete/purge the recording.",
                sessionID: session.id,
                updatePreview: false
            )
        }
        captureStatus = message
        finalTranscriptionStatus = message
        await refreshJobSummaries()
        await refreshRecoveryAttentionItems()
        if let sessionID {
            await refreshProcessingTimeline(meetingID: sessionID)
        }
    }

    private static func isOpenAIAuthenticationFailure(_ error: Error) -> Bool {
        switch error {
        case OpenAITranscriptionClientError.unsuccessfulStatusCode(let statusCode, _):
            return statusCode == 401
        case OpenAIResponsesClientError.unsuccessfulStatusCode(let statusCode, _):
            return statusCode == 401
        case OpenAIKeyValidationError.invalidAPIKey:
            return true
        default:
            return false
        }
    }

    private func writeArtifactToLocalContext(
        _ artifact: LocalMeetingArtifact,
        replacingTitle previousTitle: String? = nil
    ) async {
        do {
            let provider = LocalMarkdownContextProvider(rootDirectory: try BarnOwlMeetingProcessor.defaultContextRoot())
            if let previousTitle,
               previousTitle.caseInsensitiveCompare(artifact.session.title) != .orderedSame {
                try await provider.remove(title: previousTitle)
            }
            try await provider.write(ContextArtifact(title: artifact.session.title, markdown: artifact.markdown))
        } catch {
            recordActivity(
                level: .warning,
                category: "context",
                message: "Could not update local context copy.",
                details: BarnOwlErrorFormatter.message(for: error),
                sessionID: artifact.session.id,
                updatePreview: false
            )
        }
    }

    private func applyAcceptedExternalContextToNote(meetingID: UUID) async {
        do {
            let database = try makeDatabase()
            let acceptedItems = try await database.externalContextItems(meetingID: meetingID, state: .accepted, limit: 50)
                .sorted { $0.createdAt < $1.createdAt }
            guard !acceptedItems.isEmpty else { return }
            guard let state = try await database.meetingState(id: meetingID) else { return }

            let transcript = state.transcriptSegments
                .map { "\($0.speakerLabel ?? "Speaker"): \($0.text)" }
                .joined(separator: "\n")
            let freeformContext = acceptedItems.map(\.body).joined(separator: "\n")
            let updatedFacts = MeetingFactsExtractor().extract(
                transcript: transcript,
                freeformContext: freeformContext,
                existingFacts: state.meetingFacts ?? MeetingFacts(title: state.title),
                currentTitle: state.title
            )
            let updatedState = try await database.updateMeetingStateFacts(
                meetingID: meetingID,
                facts: updatedFacts,
                actor: .user,
                changeType: .contextUpdate,
                summary: "Updated meeting facts from accepted context."
            ) ?? state
            let stateForRendering = try await database.meetingState(id: updatedState.id) ?? updatedState
            let renderedMarkdown = Self.renderMarkdown(from: stateForRendering)
            _ = try await database.updateMeetingStateNotes(
                meetingID: meetingID,
                markdown: renderedMarkdown,
                actor: .user,
                changeType: .contextUpdate,
                summary: "Regenerated notes from accepted context."
            )

            if let store = try? makeLibraryStore() {
                var synchronizedArtifact: LocalMeetingArtifact?
                if stateForRendering.title != state.title {
                    synchronizedArtifact = try? await store.updateSessionTitle(
                        sessionID: meetingID,
                        title: stateForRendering.title
                    )
                }
                if let updatedArtifact = try? await store.updateMarkdown(sessionID: meetingID, markdown: renderedMarkdown) {
                    synchronizedArtifact = updatedArtifact
                }
                if let synchronizedArtifact {
                    await writeArtifactToLocalContext(synchronizedArtifact, replacingTitle: state.title)
                }
            }

            if displayedNote?.id == meetingID {
                displayedNote = BarnOwlDisplayedNote(
                    id: meetingID,
                    title: stateForRendering.title,
                    startedAt: stateForRendering.startedAt,
                    markdown: renderedMarkdown,
                    meetingFacts: stateForRendering.meetingFacts
                )
                noteDraft = renderedMarkdown
                noteTitleDraft = stateForRendering.title
            }
            for var item in acceptedItems where !item.usedInNoteGeneration {
                item.usedInNoteGeneration = true
                item.updatedAt = Date()
                try? await database.upsertExternalContextItem(item)
            }
            await refreshRecentSessions()
            await refreshMeetingHistory()
            recordActivity(
                category: "context",
                message: "Updated canonical meeting context.",
                details: "\(acceptedItems.count) accepted item(s)",
                sessionID: meetingID,
                updatePreview: false
            )
        } catch {
            recordActivity(
                level: .warning,
                category: "context",
                message: "Could not update note with external context.",
                details: BarnOwlErrorFormatter.message(for: error),
                sessionID: meetingID,
                updatePreview: false
            )
        }
    }

    private static func renderMarkdown(from state: BarnOwlMeetingState) -> String {
        let startedAt = state.startedAt
        let session = RecordingSession(
            id: state.id,
            title: state.title,
            startedAt: startedAt,
            endedAt: state.endedAt,
            audioSources: .defaultMeetingCapture
        )
        let segments = state.transcriptSegments.map {
            TranscriptSegment(
                id: $0.id,
                speakerLabel: $0.speakerLabel ?? "Speaker",
                text: $0.text,
                startTime: $0.startTime,
                endTime: $0.endTime,
                confidence: $0.confidence
            )
        }
        let summary = state.summary ?? MeetingSummary(
            suggestedTitle: state.title,
            overview: "No generated summary is available yet.",
            decisions: state.decisions,
            actionItems: state.actionItems,
            openQuestions: state.openQuestions
        )
        let context = state.externalContextItems
            .filter { $0.state == .accepted }
            .sorted { $0.createdAt < $1.createdAt }
            .map { "External context (\($0.source)): \($0.body)" }
        return MarkdownMeetingRenderer().render(
            session: session,
            segments: segments,
            summary: summary,
            context: context,
            meetingFacts: state.meetingFacts
        )
    }

    private func preparePostProcessingContextReview(for sessionID: UUID) async {
        do {
            let store = try makeLibraryStore()
            guard let artifact = try await store.artifact(id: sessionID) else { return }
            let transcript = artifact.transcriptSegments
                .map { "\($0.speakerLabel): \($0.text)" }
                .joined(separator: "\n")
            var review = Self.suggestPostRecordingContext(
                session: artifact.session,
                transcriptPreview: transcript
            )
            review.facts.title = artifact.session.title
            postRecordingContextReview = review
            contextDraft = review.contextLines.joined(separator: "\n")
            noteActionStatus = "Add optional context to improve the generated note."
        } catch {
            recordActivity(
                level: .warning,
                category: "context",
                message: "Could not prepare post-recording context review.",
                details: BarnOwlErrorFormatter.message(for: error),
                sessionID: sessionID,
                updatePreview: false
            )
        }
    }

    private func resolveCalendarContext(around date: Date) async -> CalendarMeetingContext? {
        do {
            let provider = makeCalendarContextProvider()
            guard let context = try await provider.bestContext(around: date) else {
                calendarContext = nil
                calendarContextAccepted = false
                calendarContextStatus = "No nearby calendar event found."
                return nil
            }

            calendarContext = context
            calendarContextAccepted = context.isHighConfidence
            calendarContextStatus = context.isHighConfidence
                ? "Using calendar context: \(context.title)."
                : "Possible calendar match: \(context.title)."
            contextDraft = context.isHighConfidence ? context.contextLines.joined(separator: "\n") : ""
            return context
        } catch {
            calendarContext = nil
            calendarContextAccepted = false
            calendarContextStatus = "Calendar context unavailable."
            recordActivity(
                level: .warning,
                category: "calendar",
                message: "Could not read calendar context.",
                details: BarnOwlErrorFormatter.message(for: error),
                sessionID: nil,
                updatePreview: false
            )
            return nil
        }
    }

    private func loadCalendarContext(for meetingID: UUID) async {
        do {
            let database = try makeDatabase()
            guard let record = try await database.meetingCalendarContext(meetingID: meetingID) else {
                calendarContext = nil
                calendarContextAccepted = false
                calendarContextStatus = "No calendar context attached."
                return
            }

            calendarContext = Self.calendarContext(from: record)
            calendarContextAccepted = true
            calendarContextStatus = calendarContext.map { "Using calendar context: \($0.title)." }
                ?? "Calendar context attached."
        } catch {
            calendarContext = nil
            calendarContextAccepted = false
            calendarContextStatus = "Calendar context could not be loaded."
        }
    }

    private func resetSessionSurface() {
        completionReadyResetTask?.cancel()
        completionReadyResetTask = nil
        cancelLiveTranscriptionTasks()
        rollingFinalTranscriptionCoordinator = nil
        rollingFinalTranscriptionEnqueueTasks.removeAll()
        performanceMetrics = PerformanceMetricAccumulator()
        performanceSummaryText = ""
        didRecordFirstAudioChunk = false
        didRecordFirstRealtimeTranscript = false
        didRecordFirstFinalTranscript = false
        didRecordFinalProcessingStart = false
        didRecordTranscriptionStart = false
        didWarnRealtimeNoTranscript = false
        didWarnRealtimeFallback = false
        rollingFinalTranscriptionQueuedChunkCount = 0
        realtimeLiveSegmentSequence = 0
        lastRealtimePersistenceAt = .distantPast
        tempAudioByteCount = 0
        lastAudibleAudioAt = nil
        lastCapturedChunkAtByTrack.removeAll()
        lastCaptureRestartAt = .distantPast
        didAutoStopForSilence = false
        recordingHealth = .idle
        recordingHealthStartedAt = nil
        publishRecordingReadinessSummary()
        pendingAudioActivityLevels = []
        lastWaveformPublishAt = .distantPast
        lastRealtimePreviewPublishAt = .distantPast
        stopElapsedTimer(reset: true)
        waveformLevels = Array(repeating: 0.18, count: 24)
        audioActivityLevel = 0
        activityItems = []
        displayedNote = nil
        noteDraft = ""
        noteTitleDraft = ""
        notePrompt = ""
        contextDraft = ""
        postRecordingContextReview = nil
        calendarContext = nil
        calendarContextAccepted = false
        calendarContextStatus = "Checking calendar context."
        noteActionStatus = "Ready."
        isNoteUpdateInFlight = false
        progressFraction = nil
        realtimeDraft = ""
        realtimeStatus = "Realtime transcription idle."
        finalTranscriptionStatus = Self.finalTranscriptionIdleStatus
        realtimeHealthState = .idle
        liveTranscriptPreview = "Starting a fresh recording..."
        captureStatus = "Starting."
    }

    private func resetMenuCaptureStatusAfterCompletion() {
        liveTranscriptPreview = "Ready."
        captureStatus = "Idle."
        finalTranscriptionStatus = Self.finalTranscriptionIdleStatus
        progressFraction = nil
        lastError = nil
        realtimeStatus = "Realtime transcription idle."
        realtimeHealthState = .idle
        pendingAudioActivityLevels = []
        audioActivityLevel = 0
        lastAudibleAudioAt = nil
        lastCapturedChunkAtByTrack.removeAll()
        lastCaptureRestartAt = .distantPast
        didAutoStopForSilence = false
        recordingHealth = .idle
        recordingHealthStartedAt = nil
        publishRecordingReadinessSummary()
    }

    private func scheduleReadyResetAfterCompletion() {
        completionReadyResetTask?.cancel()
        guard case .completed = stateMachine.state else { return }

        completionReadyResetTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.completionReadyResetDelayNanoseconds)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self,
                      case .completed = self.stateMachine.state,
                      self.progressFraction == nil,
                      !Self.hasActiveProcessing(self.processingTimelineItems),
                      !Self.hasFailedProcessing(self.processingTimelineItems)
                else {
                    return
                }

                self.apply(self.stateMachine.resetToIdle())
                self.resetMenuCaptureStatusAfterCompletion()
                self.completionReadyResetTask = nil
            }
        }
    }

    private func handleRealtimeTranscriptionUpdate(
        _ update: BarnOwlRealtimeTranscriptionUpdate,
        sessionID: UUID
    ) {
        guard activeSession?.id == sessionID,
              status == .recording
        else {
            return
        }
        guard let safeText = TranscriptPersistenceGuard.sanitizedText(update.text) else {
            recordActivity(
                level: .warning,
                category: "realtime",
                message: "Suppressed non-transcript realtime text.",
                details: "Barn Owl rejected control or status text before transcript preview/persistence.",
                sessionID: sessionID,
                updatePreview: false
            )
            return
        }

        if update.isFinal {
            if !didRecordFirstRealtimeTranscript {
                didRecordFirstRealtimeTranscript = true
                recordPerformance(.milestone(.firstRealtimeTranscriptReceived, at: Self.performanceNow()))
            }
            realtimeDraft = ""
            appendRealtimeTranscript(safeText)
            persistRealtimeTranscriptSegment(safeText, sessionID: sessionID)
            persistRealtimeState(sessionID: sessionID, force: true)
            updateRealtimeStatusIfNeeded("Realtime transcription updated.")
            lastRealtimePreviewPublishAt = Date()
        } else {
            if !didRecordFirstRealtimeTranscript,
               !safeText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                didRecordFirstRealtimeTranscript = true
                recordPerformance(.milestone(.firstRealtimeTranscriptReceived, at: Self.performanceNow()))
            }
            realtimeDraft = safeText
            realtimeDraft = String(realtimeDraft.suffix(Self.realtimePreviewCharacterLimit))
            updateRealtimeStatusIfNeeded("Realtime transcription streaming.")
            publishRealtimeDraftIfNeeded()
            persistRealtimeState(sessionID: sessionID)
        }
    }

    private func handleRealtimeHealthState(_ healthState: BarnOwlRealtimeHealthState, sessionID: UUID) {
        guard activeSession?.id == sessionID else { return }
        realtimeHealthState = healthState
        updateRealtimeStatusIfNeeded(healthState.displayText)
        persistRealtimeState(
            sessionID: sessionID,
            force: healthState == .fallbackActive || healthState == .degraded || healthState == .reconnecting || healthState == .stopped
        )
        if (healthState == .fallbackActive || healthState == .degraded) && !didWarnRealtimeFallback {
            didWarnRealtimeFallback = true
            recordActivity(
                level: .warning,
                category: "realtime",
                message: "Realtime fallback active.",
                details: "Final diarized transcription will still run when recording stops.",
                sessionID: sessionID,
                updatePreview: false
            )
        }
    }

    private func handleRealtimeDiagnosticEvent(
        _ event: BarnOwlRealtimeDiagnosticEvent,
        sessionID: UUID
    ) {
        guard activeSession?.id == sessionID else { return }

        let level: DiagnosticsLogLevel
        switch event.kind {
        case .connectFailed, .audioAppendFailed, .audioCommitFailed, .trailingSilenceFailed, .eventError, .receiveFailed:
            level = .error
        case .audioAppendIgnored, .audioDropped, .audioCommitSkipped, .audioSilenceSkipped, .eventSuppressed, .eventUnhandled, .eventRecoverableError, .receiveClosed:
            level = .warning
        case .connecting, .connected, .reconnecting, .audioAppend, .audioCommit, .trailingSilenceAppend, .eventReceived, .stopped:
            level = .info
        }

        let shouldSurfaceInActivity: Bool
        switch event.kind {
        case .connectFailed, .audioAppendFailed, .audioCommitFailed, .eventError, .receiveFailed, .receiveClosed:
            shouldSurfaceInActivity = true
        case .connected, .audioCommit, .eventReceived:
            shouldSurfaceInActivity = true
        case .connecting, .reconnecting, .audioAppend, .audioAppendIgnored, .audioDropped, .audioCommitSkipped, .audioSilenceSkipped, .eventSuppressed, .trailingSilenceAppend, .trailingSilenceFailed, .eventUnhandled, .eventRecoverableError, .stopped:
            shouldSurfaceInActivity = false
        }

        if shouldSurfaceInActivity {
            recordActivity(
                level: level,
                category: "realtime.\(event.kind.rawValue)",
                message: event.message,
                details: event.details,
                sessionID: sessionID,
                updatePreview: false
            )
        } else {
            Task {
                try? await diagnosticsStore.append(
                    level: level,
                    sessionID: sessionID,
                    category: "realtime.\(event.kind.rawValue)",
                    message: event.message,
                    details: event.details
                )
            }
        }

        if shouldSurfaceInActivity {
            updateRealtimeStatusIfNeeded(event.message)
        }
    }

    private func handleRealtimeAudioActivity(
        level: Double,
        rmsLevel: Double,
        trackKind: AudioTrackKind,
        sessionID: UUID
    ) {
        guard activeSession?.id == sessionID,
              status == .recording
        else {
            return
        }

        updateRecordingHealth(trackKind: trackKind, rmsLevel: rmsLevel)
        if rmsLevel > Self.autoStopSilenceRMSThreshold {
            lastAudibleAudioAt = Date()
        } else {
            checkSilenceAutoStop(sessionID: sessionID)
        }

        let clampedLevel = min(max(level, 0.04), 1)
        pendingAudioActivityLevels.append(clampedLevel)

        let now = Date()
        guard now.timeIntervalSince(lastWaveformPublishAt) >= Self.waveformPublishInterval else {
            return
        }

        let publishedLevel = pendingAudioActivityLevels.max() ?? clampedLevel
        pendingAudioActivityLevels = []
        lastWaveformPublishAt = now

        if abs(audioActivityLevel - publishedLevel) > 0.005 {
            audioActivityLevel = publishedLevel
        }

        let nextLevels = Array((waveformLevels + [publishedLevel]).suffix(24))
        if nextLevels != waveformLevels {
            waveformLevels = nextLevels
        }
    }

    private func resetRecordingHealth(for configuration: AudioSourceConfiguration, startedAt: Date) {
        recordingHealthStartedAt = startedAt
        var health = RecordingHealthSnapshot.idle
        for source in configuration.requiredRecordingHealthSources {
            health.replaceSourceSnapshot(RecordingSourceHealthSnapshot(
                source: source,
                isEnabled: true,
                isCapturing: true
            ))
        }
        recordingHealth = health
        publishRecordingReadinessSummary()
    }

    private func updateRecordingHealth(trackKind: AudioTrackKind, rmsLevel: Double) {
        guard let source = RecordingHealthSourceKind(trackKind: trackKind),
              let startedAt = recordingHealthStartedAt
        else {
            return
        }

        var snapshot = recordingHealth.sourceSnapshot(for: source)
        snapshot.isEnabled = true
        snapshot.isCapturing = true
        snapshot.recordRMSLevel(
            rmsLevel,
            at: Date().timeIntervalSince(startedAt)
        )
        recordingHealth.replaceSourceSnapshot(snapshot)
        publishRecordingReadinessSummary()
    }

    private func recordRecordingHealthError(
        trackKind: AudioTrackKind,
        message: String,
        sessionID: UUID
    ) {
        guard let source = RecordingHealthSourceKind(trackKind: trackKind),
              let startedAt = recordingHealthStartedAt
        else {
            return
        }

        var snapshot = recordingHealth.sourceSnapshot(for: source)
        snapshot.recordError(RecordingHealthError(
            origin: .source,
            severity: .recoverable,
            code: "chunk-write-failed",
            message: message,
            occurredAt: Date().timeIntervalSince(startedAt),
            source: source
        ))
        recordingHealth.replaceSourceSnapshot(snapshot)
        publishRecordingReadinessSummary()
        recordActivity(
            level: .warning,
            category: "health",
            message: "\(trackKind.displayName.capitalized) health degraded.",
            details: recordingReadinessSummary.message,
            sessionID: sessionID,
            updatePreview: false
        )
    }

    private func publishRecordingReadinessSummary() {
        let now = recordingHealthStartedAt.map { Date().timeIntervalSince($0) } ?? 0
        let permissions: RecordingPermissionSet = status == .recording
            ? .grantedForDefaultMeetingCapture
            : BarnOwlFirstRunReadiness.currentRecordingPermissionSet()
        let configuration = activeSession?.audioSources ?? selectedAudioSources
        let summary = recordingHealth.readinessSummary(
            configuration: configuration,
            permissions: permissions,
            now: now
        )
        if summary != recordingReadinessSummary {
            recordingReadinessSummary = summary
        }
    }

    private func publishRealtimeDraftIfNeeded(force: Bool = false) {
        let now = Date()
        guard force || now.timeIntervalSince(lastRealtimePreviewPublishAt) >= Self.realtimePreviewPublishInterval else {
            return
        }

        lastRealtimePreviewPublishAt = now
        let existing = Self.isLiveTranscriptPlaceholder(liveTranscriptPreview) ? "" : liveTranscriptPreview
        let nextPreview = String(([existing, realtimeDraft]
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .joined(separator: "\n\n"))
            .suffix(Self.realtimePreviewCharacterLimit))
        if nextPreview != liveTranscriptPreview {
            liveTranscriptPreview = nextPreview
        }
    }

    private func persistRealtimeTranscriptSegment(_ text: String, sessionID: UUID) {
        guard let cleaned = TranscriptPersistenceGuard.sanitizedText(text) else { return }

        let now = Date()
        let startedAt = activeSession?.startedAt ?? now
        let endTime = max(0, now.timeIntervalSince(startedAt))
        let sequence = realtimeLiveSegmentSequence
        realtimeLiveSegmentSequence += 1

        Task { [weak self] in
            guard let self else { return }
            do {
                let database = try self.makeDatabase()
                try await database.upsertTranscriptSegment(BarnOwlTranscriptSegmentRecord(
                    meetingID: sessionID,
                    sessionID: sessionID,
                    variant: .live,
                    sequence: sequence,
                    speakerLabel: "Realtime",
                    text: cleaned,
                    startTime: max(0, endTime - 3),
                    endTime: endTime,
                    confidence: nil,
                    createdAt: now,
                    updatedAt: now
                ))
            } catch {
                self.recordActivity(
                    level: .warning,
                    category: "database",
                    message: "Could not persist realtime transcript.",
                    details: BarnOwlErrorFormatter.message(for: error),
                    sessionID: sessionID,
                    updatePreview: false
                )
            }
        }
    }

    private func persistRealtimeState(sessionID: UUID, force: Bool = false) {
        let now = Date()
        guard force || now.timeIntervalSince(lastRealtimePersistenceAt) >= Self.realtimePersistenceInterval else {
            return
        }
        lastRealtimePersistenceAt = now

        let preview = liveTranscriptPreview.trimmingCharacters(in: .whitespacesAndNewlines)
        let status = realtimeStatus.trimmingCharacters(in: .whitespacesAndNewlines)
        Task { [weak self] in
            guard let self else { return }
            do {
                let database = try self.makeDatabase()
                if !preview.isEmpty {
                    try await database.replaceMeetingOutput(BarnOwlMeetingOutputRecord(
                        meetingID: sessionID,
                        kind: "realtime_preview",
                        content: preview,
                        contentType: "text/plain",
                        createdAt: now,
                        updatedAt: now,
                        metadataJSON: #"{"source":"realtime"}"#
                    ))
                }
                if !status.isEmpty {
                    try await database.replaceMeetingOutput(BarnOwlMeetingOutputRecord(
                        meetingID: sessionID,
                        kind: "realtime_status",
                        content: status,
                        contentType: "text/plain",
                        createdAt: now,
                        updatedAt: now,
                        metadataJSON: #"{"source":"realtime"}"#
                    ))
                }
            } catch {
                self.recordActivity(
                    level: .warning,
                    category: "database",
                    message: "Could not persist realtime status.",
                    details: BarnOwlErrorFormatter.message(for: error),
                    sessionID: sessionID,
                    updatePreview: false
                )
            }
        }
    }

    private func persistProcessingStage(message: String, sessionID: UUID) {
        guard let stage = Self.processingStage(forProgressMessage: message) else {
            return
        }
        let now = Date()
        Task { [weak self] in
            guard let self else { return }
            do {
                let database = try self.makeDatabase()
                try await database.replaceMeetingOutput(BarnOwlMeetingOutputRecord(
                    meetingID: sessionID,
                    kind: "processing_stage",
                    content: stage,
                    contentType: "text/plain",
                    createdAt: now,
                    updatedAt: now,
                    metadataJSON: #"{"source":"job-progress"}"#
                ))
                await self.refreshProcessingTimeline(meetingID: sessionID)
            } catch {
                self.recordActivity(
                    level: .warning,
                    category: "database",
                    message: "Could not persist processing stage.",
                    details: BarnOwlErrorFormatter.message(for: error),
                    sessionID: sessionID,
                    updatePreview: false
                )
            }
        }
    }

    private static func processingStage(forProgressMessage message: String) -> String? {
        let normalized = message
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .lowercased()
        if normalized.contains("transcribing") || normalized.contains("preparing openai") {
            return "transcribing"
        }
        if normalized.contains("cleanup") || normalized.contains("quality") {
            return "cleaning_transcript"
        }
        if normalized.contains("labeled") || normalized.contains("context") || normalized.contains("facts") {
            return "extracting_facts_context"
        }
        if normalized.contains("rendering") || normalized.contains("notes") {
            return "writing_notes"
        }
        if normalized.contains("saved final") {
            return "indexing_searchable"
        }
        if normalized.contains("saving") || normalized.contains("library") || normalized.contains("markdown") {
            return "exporting_markdown"
        }
        return nil
    }

    private func updateRealtimeStatusIfNeeded(_ message: String) {
        if realtimeStatus != message {
            realtimeStatus = message
        }
    }

    private func updateCaptureStatusIfNeeded(_ message: String) {
        if captureStatus != message {
            captureStatus = message
        }
    }

    private func startElapsedTimer(for session: RecordingSession) {
        stopElapsedTimer(reset: true)
        updateElapsedText(startedAt: session.startedAt)
        elapsedTimer = Timer.publish(every: 1, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.updateElapsedText(startedAt: session.startedAt)
                self?.checkRealtimeHealth(sessionID: session.id, startedAt: session.startedAt)
                self?.checkSilenceAutoStop(sessionID: session.id)
                self?.checkCaptureWatchdog(sessionID: session.id)
            }
    }

    private func stopElapsedTimer(reset: Bool) {
        elapsedTimer?.cancel()
        elapsedTimer = nil
        if reset {
            recordingElapsedText = "00:00"
        }
    }

    private func updateElapsedText(startedAt: Date) {
        recordingElapsedText = Self.formatElapsedDuration(max(0, Date().timeIntervalSince(startedAt)))
    }

    private func checkRealtimeHealth(sessionID: UUID, startedAt: Date) {
        guard activeSession?.id == sessionID,
              status == .recording,
              didRecordFirstAudioChunk,
              !didRecordFirstRealtimeTranscript,
              !didWarnRealtimeNoTranscript,
              Date().timeIntervalSince(startedAt) >= 30
        else {
            return
        }

        didWarnRealtimeNoTranscript = true
        realtimeHealthState = .degraded
        realtimeStatus = BarnOwlRealtimeHealthState.degraded.displayText
        recordActivity(
            level: .warning,
            category: "realtime",
            message: "Realtime transcription has not produced text yet.",
            details: "Audio chunks are being captured. Barn Owl will continue recording and use final diarized processing as the fallback.",
            sessionID: sessionID,
            updatePreview: false
        )
    }

    private func checkSilenceAutoStop(sessionID: UUID, now: Date = Date()) {
        guard activeSession?.id == sessionID,
              status == .recording,
              !didAutoStopForSilence,
              let lastAudibleAudioAt,
              Self.shouldAutoStopForSilence(lastAudibleAt: lastAudibleAudioAt, now: now)
        else {
            return
        }

        didAutoStopForSilence = true
        captureStatus = "Stopping after 15 minutes of silence."
        recordActivity(
            level: .warning,
            category: "capture",
            message: "Auto-stopping after 15 minutes of silence.",
            details: "Barn Owl did not detect microphone or system audio above the silence threshold.",
            sessionID: sessionID,
            updatePreview: false
        )
        Task { await self.stopRecording() }
    }

    private func checkCaptureWatchdog(sessionID: UUID, now: Date = Date()) {
        guard activeSession?.id == sessionID,
              status == .recording,
              didRecordFirstAudioChunk,
              now.timeIntervalSince(lastCaptureRestartAt) >= Self.captureRestartCooldown
        else {
            return
        }

        let expectedTracks = activeSession?.audioSources.expectedCaptureTracks ?? []
        let staleTracks = expectedTracks.filter { track in
            guard let lastCapturedAt = lastCapturedChunkAtByTrack[track] else { return false }
            return now.timeIntervalSince(lastCapturedAt) >= Self.captureWatchdogGraceInterval
        }
        guard !staleTracks.isEmpty else { return }

        lastCaptureRestartAt = now
        let names = staleTracks.map(\.displayName).joined(separator: ", ")
        captureStatus = "Restarting capture after stalled \(names) audio."
        recordActivity(
            level: .warning,
            category: "capture",
            message: "Capture watchdog restarting audio capture.",
            details: "No saved chunk for \(names) in \(Int(Self.captureWatchdogGraceInterval)) seconds.",
            sessionID: sessionID,
            updatePreview: false
        )
        Task { await self.restartActiveAudioCapture(reason: "capture watchdog") }
    }

    private func handleSystemWillSleep() {
        guard status == .recording,
              let session = activeSession
        else { return }
        captureStatus = "Mac is sleeping; recording will resume capture on wake."
        recordActivity(
            level: .warning,
            category: "capture",
            message: "System sleep detected during recording.",
            details: "Barn Owl will restart audio capture when macOS wakes.",
            sessionID: session.id,
            updatePreview: false
        )
    }

    private func handleSystemDidWake() async {
        guard status == .recording,
              let session = activeSession
        else {
            startJobRunner()
            return
        }
        captureStatus = "Mac woke; restarting audio capture."
        recordActivity(
            level: .warning,
            category: "capture",
            message: "System wake detected during recording.",
            details: "Restarting existing capture pipeline and waking pending jobs.",
            sessionID: session.id,
            updatePreview: false
        )
        await restartActiveAudioCapture(reason: "system wake")
        startJobRunner()
    }

    private func restartActiveAudioCapture(reason: String) async {
        guard status == .recording,
              let session = activeSession,
              let audioCoordinator
        else { return }

        lastCaptureRestartAt = Date()
        await audioCoordinator.stop()
        do {
            try await audioCoordinator.start(configuration: session.audioSources)
            lastCapturedChunkAtByTrack.removeAll()
            captureStatus = "Recording \(Self.audioSourceDescription(session.audioSources)). Capture resumed after \(reason)."
            recordActivity(
                category: "capture",
                message: "Audio capture restarted.",
                details: "Reason: \(reason).",
                sessionID: session.id,
                updatePreview: false
            )
        } catch {
            recordRecordingHealthError(
                trackKind: .mixed,
                message: BarnOwlErrorFormatter.message(for: error),
                sessionID: session.id
            )
            captureStatus = "Recording, but audio capture restart failed."
        }
    }

    nonisolated static func shouldAutoStopForSilence(
        lastAudibleAt: Date,
        now: Date,
        threshold: TimeInterval = 15 * 60
    ) -> Bool {
        now.timeIntervalSince(lastAudibleAt) >= threshold
    }

    private func cancelLiveTranscriptionTasks() {
        realtimeTranscriptionController = nil
        realtimeDraft = ""
    }

    private func stopLiveTranscription() async {
        realtimeDraft = ""
        let controller = realtimeTranscriptionController
        realtimeTranscriptionController = nil
        await controller?.stop()
    }

    private func recordPerformance(_ event: PerformanceMetricEvent) {
        performanceMetrics.record(event)
        performanceSummaryText = Self.performanceSummaryText(for: performanceMetrics.summary())
    }

    private func recordPerformanceActivity(sessionID: UUID) {
        let summaryText = Self.performanceSummaryText(for: performanceMetrics.summary())
        guard !summaryText.isEmpty else { return }
        recordActivity(
            category: "performance",
            message: "Performance metrics recorded.",
            details: summaryText,
            sessionID: sessionID,
            updatePreview: false
        )
    }

    private static func performanceSummaryText(for summary: PerformanceMetricSummary) -> String {
        guard summary.eventCount > 0 else { return "" }

        var parts: [String] = []
        if let captureLatency = summary.captureLatency {
            parts.append("first chunk \(formatDuration(captureLatency))")
        }
        if let captureDuration = summary.captureDuration {
            parts.append("capture \(formatDuration(captureDuration))")
        }
        if let realtimePreviewLatency = summary.realtimePreviewLatency {
            parts.append("realtime \(formatDuration(realtimePreviewLatency))")
        }
        if let firstTranscriptLatency = summary.firstTranscriptLatency {
            parts.append("first final text \(formatDuration(firstTranscriptLatency))")
        }
        if let finalProcessingDuration = summary.finalProcessingDuration {
            parts.append("final \(formatDuration(finalProcessingDuration))")
        }
        if let cleanupDuration = summary.cleanupDuration {
            parts.append("cleanup \(formatDuration(cleanupDuration))")
        }
        if let finalTempAudioBytes = summary.finalTempAudioBytes {
            parts.append("temp audio \(formatBytes(finalTempAudioBytes))")
        }

        return parts.isEmpty ? "\(summary.eventCount) performance event(s)" : parts.joined(separator: " • ")
    }

    private static func formatDuration(_ duration: TimeInterval) -> String {
        duration < 10 ? String(format: "%.1fs", duration) : String(format: "%.0fs", duration)
    }

    nonisolated static func formatElapsedDuration(_ duration: TimeInterval) -> String {
        let totalSeconds = max(0, Int(duration.rounded(.down)))
        let hours = totalSeconds / 3_600
        let minutes = (totalSeconds % 3_600) / 60
        let seconds = totalSeconds % 60

        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%02d:%02d", minutes, seconds)
    }

    nonisolated static func audioActivityLevel(forPCM16Data data: Data) -> Double {
        guard data.count >= MemoryLayout<Int16>.size else { return 0.04 }

        let sampleCount = data.count / MemoryLayout<Int16>.size
        var sumSquares = 0.0
        data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.bindMemory(to: Int16.self).baseAddress else {
                return
            }

            for index in 0..<sampleCount {
                let sample = Double(Int16(littleEndian: baseAddress[index])) / Double(Int16.max)
                sumSquares += sample * sample
            }
        }

        let rms = sqrt(sumSquares / Double(sampleCount))
        return min(max(rms * 8, 0.04), 1)
    }

    private static func formatBytes(_ byteCount: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: byteCount)
    }

    private static func performanceNow() -> TimeInterval {
        Date().timeIntervalSince1970
    }

    private func appendLiveTranscript(_ text: String) {
        let cleaned = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: " ")
        guard !cleaned.isEmpty else { return }

        let existing = Self.isLiveTranscriptPlaceholder(liveTranscriptPreview) ? "" : liveTranscriptPreview
        let combined = [existing, cleaned]
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .joined(separator: "\n\n")
        liveTranscriptPreview = String(combined.suffix(1_200))
    }

    private func appendRealtimeTranscript(_ text: String) {
        let nextPreview = Self.realtimePreviewAppending(
            text,
            to: liveTranscriptPreview,
            characterLimit: Self.realtimePreviewCharacterLimit
        )
        if nextPreview != liveTranscriptPreview {
            liveTranscriptPreview = nextPreview
        }
    }

    static func realtimePreviewAppending(
        _ text: String,
        to existingPreview: String,
        characterLimit: Int
    ) -> String {
        let cleaned = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        guard !cleaned.isEmpty else {
            return existingPreview
        }

        var lines = isLiveTranscriptPlaceholder(existingPreview)
            ? []
            : existingPreview
                .split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }

        let newNormalized = normalizedRealtimePreviewText(cleaned)
        if let lastIndex = lines.indices.last {
            let lastNormalized = normalizedRealtimePreviewText(lines[lastIndex])
            if lastNormalized == newNormalized || lastNormalized.hasPrefix(newNormalized) {
                return existingPreview
            }
            if newNormalized.hasPrefix(lastNormalized),
               cleaned.count > lines[lastIndex].count {
                lines[lastIndex] = cleaned
                return String(lines.joined(separator: "\n\n").suffix(characterLimit))
            }
        }

        if lines.contains(where: { normalizedRealtimePreviewText($0) == newNormalized }) {
            return existingPreview
        }

        lines.append(cleaned)
        return String(lines.joined(separator: "\n\n").suffix(characterLimit))
    }

    private static func normalizedRealtimePreviewText(_ text: String) -> String {
        text
            .replacingOccurrences(of: #"^\[Realtime\]\s*"#, with: "", options: [.regularExpression, .caseInsensitive])
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .replacingOccurrences(of: #"[^a-z0-9]+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func isLiveTranscriptPlaceholder(_ text: String) -> Bool {
        text == "Ready."
            || text == "Starting a fresh recording..."
            || text == "Finalizing transcript..."
            || text == "Review meeting context before final processing."
            || text.hasPrefix("Checking mic and system audio")
            || text.hasPrefix("Listening.")
            || text.hasPrefix("Captured ")
            || text.hasPrefix("Recording mic + system audio")
    }

    static func reviewTranscriptPreview(from text: String) -> String {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return isLiveTranscriptPlaceholder(cleaned) ? "" : cleaned
    }

    static func durabilityRepairMarkdown(from state: BarnOwlMeetingState) -> String {
        let canonicalTitle = MeetingFacts.clean(state.meeting.title) ?? state.title
        let canonicalFacts: MeetingFacts = {
            var facts = state.meetingFacts
                ?? meetingFactsFromMarkdown(state.generatedNotes)
                ?? MeetingFacts(title: canonicalTitle)
            facts.title = canonicalTitle
            return facts
        }()
        let session = RecordingSession(
            id: state.id,
            title: canonicalTitle,
            startedAt: state.startedAt,
            endedAt: state.endedAt,
            audioSources: .defaultMeetingCapture
        )
        let titleSynchronized = markdownReplacingTopLevelTitle(
            in: state.generatedNotes,
            title: canonicalTitle
        )
        return markdownReplacingMeetingFacts(
            in: titleSynchronized,
            with: meetingFactsMarkdownSection(canonicalFacts, session: session)
        )
    }

    static func durabilityRepairFacts(from state: BarnOwlMeetingState) -> MeetingFacts {
        let canonicalTitle = MeetingFacts.clean(state.meeting.title) ?? state.title
        let transcript = state.transcriptSegments
            .map { "\($0.speakerLabel ?? "Speaker"): \($0.text)" }
            .joined(separator: "\n")
        let freeformContext = state.externalContextItems
            .map(\.body)
            .joined(separator: "\n")
        var repairSeed = state.meetingFacts ?? MeetingFacts(title: canonicalTitle)
        repairSeed.title = canonicalTitle
        repairSeed.customers = []
        repairSeed.organizations = []
        repairSeed.projects = []
        repairSeed.goals = []
        var facts = MeetingFactsExtractor().extract(
            transcript: transcript,
            freeformContext: freeformContext,
            existingFacts: repairSeed,
            currentTitle: canonicalTitle
        )
        facts.title = canonicalTitle
        return facts
    }

    static func markdownReplacingTopLevelTitle(in markdown: String, title: String) -> String {
        let normalizedTitle = MeetingFacts.clean(title) ?? "Untitled Meeting"
        var lines = markdown.components(separatedBy: "\n")
        if let firstIndex = lines.firstIndex(where: { $0.hasPrefix("# ") }) {
            lines[firstIndex] = "# \(normalizedTitle)"
            return lines.joined(separator: "\n")
        }
        return "# \(normalizedTitle)\n\n\(markdown)"
    }

    static func suggestPostRecordingContext(
        session: RecordingSession,
        transcriptPreview: String
    ) -> BarnOwlPostRecordingContextReview {
        let facts = MeetingFactsExtractor().extract(
            transcript: transcriptPreview,
            currentTitle: session.title
        )
        let prompts = ContextPromptGenerator().prompts(for: facts, transcript: transcriptPreview)
        return BarnOwlPostRecordingContextReview(
            session: session,
            transcriptPreview: transcriptPreview,
            facts: facts,
            freeformContextDraft: "",
            prompts: prompts
        )
    }

    static func meetingFactsMarkdownSection(
        _ facts: MeetingFacts,
        session: RecordingSession
    ) -> String {
        var lines = ["## Meeting Facts", ""]
        let type = MeetingFacts.clean(facts.meetingType) ?? "General Discussion"
        lines.append("- Meeting type: \(type)")
        lines.append("- Title: \(MeetingFacts.clean(facts.title) ?? session.title)")
        if !facts.participants.isEmpty {
            lines.append("- Participants: \(facts.participants.joined(separator: ", "))")
        }
        if !facts.customers.isEmpty {
            lines.append("- Customers: \(facts.customers.joined(separator: ", "))")
        } else if !facts.organizations.isEmpty {
            lines.append("- Organizations: \(facts.organizations.joined(separator: ", "))")
        }
        if !facts.projects.isEmpty {
            lines.append("- Projects: \(facts.projects.joined(separator: ", "))")
        }
        if !facts.goals.isEmpty {
            lines.append("- Goals: \(facts.goals.joined(separator: "; "))")
        }
        if !facts.glossary.isEmpty {
            for key in facts.glossary.keys.sorted() {
                if let value = facts.glossary[key] {
                    lines.append("- \(key): \(value)")
                }
            }
        }
        if !facts.additionalContext.isEmpty {
            lines.append("")
            lines.append(contentsOf: facts.additionalContext)
        }
        return lines.joined(separator: "\n")
    }

    static func markdownReplacingMeetingFacts(in markdown: String, with section: String) -> String {
        let lines = markdown.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let start = lines.firstIndex(where: {
            let trimmed = $0.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed == "## Meeting Facts" || trimmed == "## Reviewed Context"
        }) else {
            return [markdown.trimmingCharacters(in: .whitespacesAndNewlines), section]
                .filter { !$0.isEmpty }
                .joined(separator: "\n\n") + "\n"
        }

        var end = lines.endIndex
        for index in lines.index(after: start)..<lines.endIndex {
            if lines[index].hasPrefix("## ") {
                end = index
                break
            }
        }
        var updated = Array(lines[..<start])
        updated.append(contentsOf: section.split(separator: "\n", omittingEmptySubsequences: false).map(String.init))
        updated.append(contentsOf: lines[end...])
        return updated.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
    }

    static func externalContextMarkdownSection(_ items: [BarnOwlExternalContextItemRecord]) -> String {
        var lines = ["## External Context", ""]
        for item in items {
            lines.append("- Source: \(item.source)")
            lines.append("  Added: \(item.createdAt.formatted(date: .abbreviated, time: .shortened))")
            for bodyLine in item.body.split(separator: "\n", omittingEmptySubsequences: false) {
                lines.append("  \(bodyLine)")
            }
        }
        return lines.joined(separator: "\n")
    }

    static func markdownReplacingExternalContext(in markdown: String, with section: String) -> String {
        let lines = markdown.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let start = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines) == "## External Context" }) else {
            return [markdown.trimmingCharacters(in: .whitespacesAndNewlines), section]
                .filter { !$0.isEmpty }
                .joined(separator: "\n\n") + "\n"
        }

        var end = lines.endIndex
        for index in lines.index(after: start)..<lines.endIndex {
            if lines[index].hasPrefix("## ") {
                end = index
                break
            }
        }
        var updated = Array(lines[..<start])
        updated.append(contentsOf: section.split(separator: "\n", omittingEmptySubsequences: false).map(String.init))
        updated.append(contentsOf: lines[end...])
        return updated.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
    }

    private static func suggestedReviewTitle(
        currentTitle: String,
        transcriptPreview: String,
        meetingType: MeetingNoteFormat
    ) -> String {
        let current = currentTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if !current.isEmpty,
           !["untitled meeting", "meeting notes"].contains(current.lowercased()) {
            return current
        }

        let cleaned = transcriptPreview
            .replacingOccurrences(of: #"\[[^\]]+\]"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: "\n", with: " ")
        let words = cleaned
            .split { !$0.isLetter && !$0.isNumber && $0 != "-" }
            .map(String.init)
            .filter { word in
                let lowercased = word.lowercased()
                return word.count > 2 && !reviewTitleStopWords.contains(lowercased)
            }
            .prefix(6)
        let title = words
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !title.isEmpty {
            return title
        }

        return "\(meetingType.displayName) Notes"
    }

    private static func suggestedParticipants(from transcriptPreview: String) -> [String] {
        var participants: Set<String> = []
        for line in transcriptPreview.split(separator: "\n", omittingEmptySubsequences: true) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let colonIndex = trimmed.firstIndex(of: ":") else { continue }
            let candidate = trimmed[..<colonIndex].trimmingCharacters(in: .whitespacesAndNewlines)
            let lowercased = candidate.lowercased()
            guard candidate.count <= 40,
                  !candidate.isEmpty,
                  !lowercased.hasPrefix("[realtime]"),
                  !["you", "me", "speaker", "transcript", "barn owl"].contains(lowercased)
            else { continue }
            participants.insert(candidate)
        }
        return participants.sorted()
    }

    private static func suggestedReviewContext(
        transcriptPreview: String,
        meetingType: MeetingNoteFormat,
        participants: [String]
    ) -> String {
        var lines = [
            "Context source: post-recording review",
            "Suggested meeting type: \(meetingType.displayName)"
        ]
        if !participants.isEmpty {
            lines.append("Suggested participants: \(participants.joined(separator: ", "))")
        }
        if !transcriptPreview.isEmpty {
            lines.append("Review basis: realtime transcript preview")
        } else {
            lines.append("Review basis: no realtime transcript preview was available")
        }
        return lines.joined(separator: "\n")
    }

    private static let reviewTitleStopWords: Set<String> = [
        "about", "after", "again", "also", "and", "are", "because", "but", "can", "could", "did",
        "for", "from", "going", "have", "here", "into", "just", "like", "looks", "maybe", "need",
        "now", "okay", "really", "should", "that", "the", "then", "there", "this", "was", "what",
        "when", "with", "you", "your"
    ]

    private static func searchSnippet(in text: String, query: String) -> String {
        let normalized = text.replacingOccurrences(of: "\n", with: " ")
        guard let range = normalized.lowercased().range(of: query) else {
            return String(normalized.prefix(180))
        }
        let start = normalized.index(range.lowerBound, offsetBy: -60, limitedBy: normalized.startIndex) ?? normalized.startIndex
        let end = normalized.index(range.upperBound, offsetBy: 120, limitedBy: normalized.endIndex) ?? normalized.endIndex
        return String(normalized[start..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func topLevelMarkdownTitle(in markdown: String) -> String? {
        markdown
            .split(separator: "\n", omittingEmptySubsequences: false)
            .lazy
            .compactMap { line -> String? in
                guard line.hasPrefix("# "), !line.hasPrefix("## ") else {
                    return nil
                }
                let title = line.dropFirst(2).trimmingCharacters(in: .whitespacesAndNewlines)
                return title.isEmpty ? nil : title
            }
            .first
    }

    private func recordActivity(
        level: DiagnosticsLogLevel = .info,
        category: String,
        message: String,
        details: String? = nil,
        sessionID: UUID? = nil,
        updatePreview: Bool = true
    ) {
        let safeMessage = BarnOwlErrorFormatter.sanitizeForUserDisplay(message)
        let safeDetails = details.map(BarnOwlErrorFormatter.sanitizeForUserDisplay)
        let item = BarnOwlActivityItem(
            timestamp: Date(),
            level: level,
            message: safeMessage,
            details: safeDetails
        )
        activityItems = Array(([item] + activityItems).prefix(10))
        if updatePreview {
            liveTranscriptPreview = safeMessage
        }

        Task {
            try? await diagnosticsStore.append(
                level: level,
                sessionID: sessionID,
                category: category,
                message: safeMessage,
                details: safeDetails
            )
        }
    }

    private func loadRecentDiagnostics() async {
        do {
            let entries = try await diagnosticsStore.recentEntries(limit: 8)
            activityItems = entries.map {
                BarnOwlActivityItem(
                    timestamp: $0.timestamp,
                    level: $0.level,
                    message: $0.message,
                    details: $0.details
                )
            }
        } catch {
            activityItems = []
        }
    }

    private func persistSessionState(
        _ session: RecordingSession,
        status: BarnOwlRecordingSessionStatus,
        endedAt: Date? = nil
    ) async {
        do {
            let database = try makeDatabase()
            let now = Date()
            let existingMeeting = try await database.meeting(id: session.id)
            try await database.upsertMeeting(BarnOwlMeetingRecord(
                id: session.id,
                title: session.title,
                startedAt: session.startedAt,
                endedAt: endedAt ?? session.endedAt,
                createdAt: session.startedAt,
                updatedAt: now,
                metadataJSON: Self.audioSourcesMetadataJSON(for: session.audioSources)
            ))
            try await database.upsertRecordingSession(BarnOwlRecordingSessionRecord(
                id: session.id,
                meetingID: session.id,
                status: status,
                startedAt: session.startedAt,
                endedAt: endedAt ?? session.endedAt,
                audioSourcesJSON: Self.audioSourcesMetadataJSON(for: session.audioSources),
                createdAt: session.startedAt,
                updatedAt: now
            ))
            if existingMeeting == nil {
                try await recordMeetingExportSnapshotEvent(
                    database: database,
                    meetingID: session.id,
                    type: .created
                )
            }
        } catch {
            recordActivity(
                level: .warning,
                category: "database",
                message: "Could not update Barn Owl database.",
                details: BarnOwlErrorFormatter.message(for: error),
                sessionID: session.id,
                updatePreview: false
            )
        }
    }

    private func deletePersistedMeeting(_ id: UUID) async {
        do {
            let database = try makeDatabase()
            try await database.recordMeetingExportEvent(BarnOwlMeetingExportEventRecord(
                type: .deleted,
                meetingID: id,
                meetingStableKey: "barnowl:meeting:\(id.uuidString)",
                occurredAt: Date(),
                tombstoneReason: "meeting_deleted"
            ))
            try await database.deleteMeeting(id: id)
        } catch {
            recordActivity(
                level: .warning,
                category: "database",
                message: "Could not delete recording from SQLite.",
                details: BarnOwlErrorFormatter.message(for: error),
                sessionID: id,
                updatePreview: false
            )
        }
    }

    private func recordMeetingExportTombstone(
        meetingID: UUID,
        type: BarnOwlMeetingExportEventType,
        reason: String
    ) async {
        do {
            let database = try makeDatabase()
            try await database.recordMeetingExportEvent(BarnOwlMeetingExportEventRecord(
                type: type,
                meetingID: meetingID,
                meetingStableKey: "barnowl:meeting:\(meetingID.uuidString)",
                occurredAt: Date(),
                tombstoneReason: reason
            ))
        } catch {
            recordActivity(
                level: .warning,
                category: "export",
                message: "Could not record Barn Owl export tombstone.",
                details: BarnOwlErrorFormatter.message(for: error),
                sessionID: meetingID,
                updatePreview: false
            )
        }
    }

    private func recordMeetingExportSnapshotEvent(
        meetingID: UUID,
        type: BarnOwlMeetingExportEventType
    ) async {
        do {
            let database = try makeDatabase()
            try await recordMeetingExportSnapshotEvent(
                database: database,
                meetingID: meetingID,
                type: type
            )
        } catch {
            recordActivity(
                level: .warning,
                category: "export",
                message: "Could not record Barn Owl export update event.",
                details: BarnOwlErrorFormatter.message(for: error),
                sessionID: meetingID,
                updatePreview: false
            )
        }
    }

    private func recordMeetingExportSnapshotEvent(
        database: BarnOwlDatabase,
        meetingID: UUID,
        type: BarnOwlMeetingExportEventType
    ) async throws {
        guard let state = try await database.meetingState(id: meetingID) else {
            return
        }
        let evidence = meetingEvidenceEnvelope(
            from: state,
            policy: .structuredOutputsTranscriptAndPointers,
            includeTranscriptSegments: false
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let evidenceJSON = String(decoding: try encoder.encode(evidence), as: UTF8.self)
        try await database.recordMeetingExportEvent(BarnOwlMeetingExportEventRecord(
            type: type,
            meetingID: meetingID,
            meetingStableKey: evidence.meeting.stableKey,
            occurredAt: Date(),
            schemaVersion: evidence.schemaVersion,
            envelopeJSON: evidenceJSON
        ))
    }

    private func persistCalendarContext(_ context: CalendarMeetingContext, meetingID: UUID) async {
        do {
            let database = try makeDatabase()
            let now = Date()
            let attendeesData = try JSONEncoder().encode(context.attendees)
            let attendeesJSON = String(decoding: attendeesData, as: UTF8.self)
            let rawData = try JSONEncoder().encode(context)
            let rawJSON = String(decoding: rawData, as: UTF8.self)
            try await database.upsertMeetingCalendarContext(BarnOwlMeetingCalendarContextRecord(
                meetingID: meetingID,
                calendarEventID: context.id,
                title: context.title,
                startsAt: context.startsAt,
                endsAt: context.endsAt,
                attendeesJSON: attendeesJSON,
                rawContextJSON: rawJSON,
                createdAt: now,
                updatedAt: now
            ))
        } catch {
            recordActivity(
                level: .warning,
                category: "calendar",
                message: "Could not save calendar context.",
                details: BarnOwlErrorFormatter.message(for: error),
                sessionID: meetingID,
                updatePreview: false
            )
        }
    }

    private func deletePersistedCalendarContext(meetingID: UUID) async {
        do {
            let database = try makeDatabase()
            try await database.deleteMeetingCalendarContext(meetingID: meetingID)
        } catch {
            recordActivity(
                level: .warning,
                category: "calendar",
                message: "Could not remove calendar context.",
                details: BarnOwlErrorFormatter.message(for: error),
                sessionID: meetingID,
                updatePreview: false
            )
        }
    }

    private func persistProcessedArtifact(sessionID: UUID) async {
        do {
            let store = try makeLibraryStore()
            guard let artifact = try await store.artifact(id: sessionID) else {
                return
            }

            let database = try makeDatabase()
            let now = Date()
            let beforeState = try? await database.meetingState(id: artifact.session.id)
            try await database.upsertMeeting(BarnOwlMeetingRecord(
                id: artifact.session.id,
                title: artifact.session.title,
                startedAt: artifact.session.startedAt,
                endedAt: artifact.session.endedAt,
                createdAt: artifact.session.startedAt,
                updatedAt: now,
                metadataJSON: Self.meetingMetadataJSON(
                    audioSources: artifact.session.audioSources,
                    markdown: artifact.markdown
                )
            ))

            let segmentRecords = artifact.transcriptSegments.enumerated().map { index, segment in
                BarnOwlTranscriptSegmentRecord(
                    id: segment.id,
                    meetingID: artifact.session.id,
                    sessionID: artifact.session.id,
                    variant: .final,
                    sequence: index,
                    speakerLabel: segment.speakerLabel,
                    text: segment.text,
                    startTime: segment.startTime,
                    endTime: segment.endTime,
                    confidence: segment.confidence,
                    createdAt: now,
                    updatedAt: now
                )
            }
            try await database.upsertTranscriptSegments(segmentRecords)
            try await database.replaceMeetingOutput(BarnOwlMeetingOutputRecord(
                meetingID: artifact.session.id,
                kind: "markdown",
                content: artifact.markdown,
                createdAt: now,
                updatedAt: now,
                metadataJSON: #"{"source":"local-library"}"#
            ))
            try await database.replaceMeetingOutput(BarnOwlMeetingOutputRecord(
                meetingID: artifact.session.id,
                kind: "summary",
                content: artifact.summary.overview,
                contentType: "text/plain",
                createdAt: now,
                updatedAt: now,
                metadataJSON: #"{"source":"final-processing"}"#
            ))
            try await database.replaceMeetingOutput(BarnOwlMeetingOutputRecord(
                meetingID: artifact.session.id,
                kind: "context_used",
                content: Self.markdownSection(namedAnyOf: ["Context", "Customer Context", "Team Context", "Relationship Context", "Candidate Context", "Planning Context", "Capture Context"], in: artifact.markdown),
                contentType: "text/plain",
                createdAt: now,
                updatedAt: now,
                metadataJSON: #"{"source":"note-renderer"}"#
            ))
            if let facts = Self.meetingFactsFromMarkdown(artifact.markdown),
               let factsJSON = facts.encodedJSONString() {
                try await database.replaceMeetingOutput(BarnOwlMeetingOutputRecord(
                    meetingID: artifact.session.id,
                    kind: "meeting_facts",
                    content: factsJSON,
                    contentType: "application/json",
                    createdAt: now,
                    updatedAt: now,
                    metadataJSON: #"{"source":"note-renderer"}"#
                ))
            }
            await runAutomaticRecurringKnowledgeEnrichment(
                artifact: artifact,
                database: database,
                now: now
            )
            if let beforeState,
               beforeState.generatedNotes != artifact.markdown,
               let afterState = try? await database.meetingState(id: artifact.session.id) {
                try? await database.recordMeetingVersion(
                    meetingID: artifact.session.id,
                    actor: .job,
                    changeType: .summaryRegenerated,
                    summary: "Final processing regenerated transcript, summary, and notes.",
                    before: BarnOwlMeetingVersionSnapshot(state: beforeState),
                    after: BarnOwlMeetingVersionSnapshot(state: afterState)
                )
            }
            try await recordMeetingExportSnapshotEvent(
                database: database,
                meetingID: artifact.session.id,
                type: .updated
            )
        } catch {
            recordActivity(
                level: .warning,
                category: "database",
                message: "Could not persist final transcript to SQLite.",
                details: BarnOwlErrorFormatter.message(for: error),
                sessionID: sessionID,
                updatePreview: false
            )
        }
    }

    private func runAutomaticRecurringKnowledgeEnrichment(
        artifact: LocalMeetingArtifact,
        database: BarnOwlDatabase,
        now: Date
    ) async {
        do {
            let ownerID = currentEnrichmentOwnerID()
            let transcript = artifact.transcriptSegments
                .map { "\($0.speakerLabel): \($0.text)" }
                .joined(separator: "\n")
            let candidates = try await recurringConceptsEligibleForAutomaticEnrichment(
                transcript: transcript,
                ownerID: ownerID,
                database: database,
                now: now
            )
            guard !candidates.isEmpty else { return }

            for concept in candidates.prefix(3) {
                let execution = try await executeKnowledgeEnrichment(
                    concept: concept,
                    limit: 8,
                    ownerID: ownerID,
                    database: database,
                    now: now
                )
                recordActivity(
                    category: "knowledge",
                    message: execution.run.status == .supportedCandidate
                        ? "Automatically enriched recurring concept \(concept)."
                        : "Automatically reviewed recurring concept \(concept).",
                    details: execution.run.summary,
                    sessionID: artifact.session.id,
                    updatePreview: false
                )
            }
        } catch {
            recordActivity(
                level: .warning,
                category: "knowledge",
                message: "Could not run automatic recurring knowledge enrichment.",
                details: BarnOwlErrorFormatter.message(for: error),
                sessionID: artifact.session.id,
                updatePreview: false
            )
        }
    }

    private func recurringConceptsEligibleForAutomaticEnrichment(
        transcript: String,
        ownerID: String,
        database: BarnOwlDatabase,
        now: Date
    ) async throws -> [String] {
        let candidates = Self.recurringConceptCandidates(in: transcript)
        guard !candidates.isEmpty else { return [] }

        let existingJobs = try await database.enrichmentJobs(ownerID: ownerID, limit: 200)
        let cooldownCutoff = now.addingTimeInterval(-24 * 60 * 60)
        var eligible: [(concept: String, meetingCount: Int)] = []

        for candidate in candidates {
            let normalized = BarnOwlKnowledgeEntityRecord.normalized(candidate)
            guard !normalized.isEmpty else { continue }
            let existingKnowledgeMatches = try await database.durableKnowledgeMatches(
                ownerID: ownerID,
                transcript: candidate,
                limit: 1
            )
            guard existingKnowledgeMatches.isEmpty else {
                continue
            }
            let hasRecentJob = existingJobs.contains {
                BarnOwlKnowledgeEntityRecord.normalized($0.conceptKey) == normalized
                    && $0.createdAt >= cooldownCutoff
            }
            guard !hasRecentJob else { continue }

            let searchResults = try await database.searchLibrary(BarnOwlDatabaseSearchQuery(
                text: candidate,
                limit: 24
            ))
            let distinctMeetingCount = Set(searchResults.map(\.meeting.id)).count
            guard distinctMeetingCount >= 3 else { continue }
            eligible.append((candidate, distinctMeetingCount))
        }

        return eligible
            .sorted {
                if $0.meetingCount != $1.meetingCount { return $0.meetingCount > $1.meetingCount }
                return $0.concept.localizedCaseInsensitiveCompare($1.concept) == .orderedAscending
            }
            .map(\.concept)
    }

    nonisolated static func recurringConceptCandidates(in transcript: String, limit: Int = 16) -> [String] {
        guard let regex = try? NSRegularExpression(
            pattern: #"\b[A-Z][A-Za-z0-9&.-]{2,}(?:\s+[A-Z][A-Za-z0-9&.-]{2,}){0,2}\b"#
        ) else {
            return []
        }

        let transcriptWithoutSpeakerLabels = transcript
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { line -> String in
                guard let colon = line.firstIndex(of: ":") else {
                    return String(line)
                }
                return String(line[line.index(after: colon)...])
            }
            .joined(separator: "\n")
        let nsRange = NSRange(transcriptWithoutSpeakerLabels.startIndex..<transcriptWithoutSpeakerLabels.endIndex, in: transcriptWithoutSpeakerLabels)
        var ordered: [String] = []
        var seen: Set<String> = []
        for match in regex.matches(in: transcriptWithoutSpeakerLabels, range: nsRange) {
            guard let range = Range(match.range, in: transcriptWithoutSpeakerLabels) else { continue }
            let candidate = String(transcriptWithoutSpeakerLabels[range])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let normalized = BarnOwlKnowledgeEntityRecord.normalized(candidate)
            guard !normalized.isEmpty,
                  !Self.recurringConceptStopTerms.contains(normalized),
                  seen.insert(normalized).inserted
            else {
                continue
            }
            ordered.append(candidate)
            if ordered.count >= max(1, limit) {
                break
            }
        }
        return ordered
    }

    private nonisolated static let recurringConceptStopTerms: Set<String> = [
        "barn owl",
        "call speaker",
        "room speaker",
        "meeting",
        "notes",
        "pricing strategy",
        "summary",
        "transcript"
    ]

    nonisolated static func defaultDatabaseURL() throws -> URL {
        let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory

        let directory = applicationSupport
            .appending(path: "Barn Owl", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return directory.appending(path: "barnowl.sqlite")
    }

    private nonisolated static func audioSourcesMetadataJSON(for configuration: AudioSourceConfiguration) -> String {
        #"{"microphone":\#(configuration.capturesMicrophone),"systemAudio":\#(configuration.capturesSystemAudio)}"#
    }

    private nonisolated static func audioSourceDescription(_ configuration: AudioSourceConfiguration) -> String {
        switch (configuration.capturesMicrophone, configuration.capturesSystemAudio) {
        case (true, true):
            "microphone + system audio"
        case (true, false):
            "microphone only"
        case (false, true):
            "system audio only"
        case (false, false):
            "no audio sources"
        }
    }

    private nonisolated static func audioReadinessPreview(for configuration: AudioSourceConfiguration) -> String {
        switch (configuration.capturesMicrophone, configuration.capturesSystemAudio) {
        case (true, true):
            "Checking mic and system audio..."
        case (true, false):
            "Checking microphone audio..."
        case (false, true):
            "Checking system audio..."
        case (false, false):
            "No audio sources selected."
        }
    }

    private nonisolated static func meetingMetadataJSON(audioSources: AudioSourceConfiguration, markdown: String) -> String {
        var object: [String: Any] = [
            "microphone": audioSources.capturesMicrophone,
            "systemAudio": audioSources.capturesSystemAudio
        ]
        if let meetingType = markdownMeetingType(in: markdown) {
            object["meetingType"] = meetingType
        }
        if let facts = meetingFactsFromMarkdown(markdown),
           let data = try? JSONEncoder().encode(facts),
           let jsonObject = try? JSONSerialization.jsonObject(with: data) {
            object["meetingFacts"] = jsonObject
        }
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    private nonisolated static func reviewMetadataJSON(
        audioSources: AudioSourceConfiguration,
        meetingFacts: MeetingFacts
    ) -> String {
        var object: [String: Any] = [
            "microphone": audioSources.capturesMicrophone,
            "systemAudio": audioSources.capturesSystemAudio,
            "contextReview": true
        ]
        if let meetingType = MeetingFacts.clean(meetingFacts.meetingType) {
            object["meetingType"] = meetingType
        }
        if let data = try? JSONEncoder().encode(meetingFacts),
           let jsonObject = try? JSONSerialization.jsonObject(with: data) {
            object["meetingFacts"] = jsonObject
        }
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    private nonisolated static func meetingFactsFromMarkdown(_ markdown: String) -> MeetingFacts? {
        let section = markdownSection(namedAnyOf: ["Meeting Facts"], in: markdown)
        guard !section.isEmpty else { return nil }
        var facts = MeetingFacts()
        for rawLine in section.split(separator: "\n", omittingEmptySubsequences: true).map(String.init) {
            let line = rawLine
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: #"^-\s*"#, with: "", options: .regularExpression)
            let parts = line.split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2 else {
                facts.additionalContext = MeetingFacts.normalizedList(facts.additionalContext + [line])
                continue
            }
            let key = parts[0].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
            switch key {
            case "meeting type":
                facts.meetingType = value
            case "title":
                facts.title = value
            case "participants":
                facts.participants = MeetingFacts.normalizedList(value.split(separator: ",").map(String.init))
            case "customers":
                facts.customers = MeetingFacts.normalizedList(value.split(separator: ",").map(String.init))
            case "organizations":
                facts.organizations = MeetingFacts.normalizedList(value.split(separator: ",").map(String.init))
            case "projects":
                facts.projects = MeetingFacts.normalizedList(value.split(separator: ",").map(String.init))
            case "goals":
                facts.goals = MeetingFacts.normalizedList(value.split(separator: ";").map(String.init))
            default:
                if key.range(of: #"^[a-z0-9]{2,}$"#, options: [.regularExpression, .caseInsensitive]) != nil {
                    facts.glossary[parts[0].trimmingCharacters(in: .whitespacesAndNewlines)] = value
                }
            }
        }
        return facts.contextLines.isEmpty ? nil : facts
    }

    private nonisolated static func markdownMeetingType(in markdown: String) -> String? {
        markdown
            .split(separator: "\n", omittingEmptySubsequences: false)
            .lazy
            .compactMap { line -> String? in
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard trimmed.localizedCaseInsensitiveContains("Meeting Type:"),
                      let value = trimmed.split(separator: ":", maxSplits: 1).last
                else { return nil }
                let type = value.trimmingCharacters(in: .whitespacesAndNewlines)
                return type.isEmpty ? nil : type
            }
            .first
    }

    private nonisolated static func markdownSection(namedAnyOf names: [String], in markdown: String) -> String {
        let lines = markdown.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var captured: [String] = []
        var isCapturing = false
        var captureLevel: Int?
        for line in lines {
            if let heading = markdownHeading(in: line) {
                let normalized = heading.title.lowercased()
                let matches = names.contains { normalized == $0.lowercased() }
                if matches {
                    isCapturing = true
                    captureLevel = heading.level
                    continue
                }
                if isCapturing, let captureLevel, heading.level <= captureLevel {
                    break
                }
            }
            if isCapturing {
                captured.append(line)
            }
        }
        return captured.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private nonisolated static func markdownListItems(inSectionNamedAnyOf names: [String], markdown: String) -> [String] {
        let section = markdownSection(namedAnyOf: names, in: markdown)
        guard !section.isEmpty else { return [] }
        let items = section
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { line in
                line.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            .compactMap { line -> String? in
                let cleaned: String
                if line.hasPrefix("- ") {
                    cleaned = String(line.dropFirst(2))
                } else if line.hasPrefix("* ") {
                    cleaned = String(line.dropFirst(2))
                } else if line.range(of: #"^\d+\.\s+"#, options: .regularExpression) != nil {
                    cleaned = line.replacingOccurrences(of: #"^\d+\.\s+"#, with: "", options: .regularExpression)
                } else {
                    cleaned = line
                }
                let trimmed = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : trimmed
            }
        return Array(items.prefix(100))
    }

    private nonisolated static func markdownHeading(in line: String) -> (level: Int, title: String)? {
        let hashes = line.prefix { $0 == "#" }.count
        guard hashes > 0,
              hashes < line.count,
              line.dropFirst(hashes).first == " "
        else { return nil }
        return (
            level: hashes,
            title: line.dropFirst(hashes + 1).trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    private nonisolated static func calendarContext(from record: BarnOwlMeetingCalendarContextRecord) -> CalendarMeetingContext? {
        if let rawContextJSON = record.rawContextJSON,
           let data = rawContextJSON.data(using: .utf8),
           let decoded = try? JSONDecoder().decode(CalendarMeetingContext.self, from: data) {
            return decoded
        }

        guard let title = record.title,
              let startsAt = record.startsAt,
              let endsAt = record.endsAt
        else {
            return nil
        }

        let attendees: [String]
        if let attendeesJSON = record.attendeesJSON,
           let data = attendeesJSON.data(using: .utf8),
           let decoded = try? JSONDecoder().decode([String].self, from: data) {
            attendees = decoded
        } else {
            attendees = []
        }

        return CalendarMeetingContext(
            id: record.calendarEventID ?? record.id.uuidString,
            provider: "calendar",
            title: title,
            startsAt: startsAt,
            endsAt: endsAt,
            attendees: attendees,
            confidence: 0.70,
            matchReason: "saved calendar context"
        )
    }

    private static func defaultDiagnosticsRoot() -> URL {
        let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory

        return applicationSupport
            .appending(path: "Barn Owl", directoryHint: .isDirectory)
            .appending(path: "Logs", directoryHint: .isDirectory)
    }
}

private extension RecordingHealthSourceKind {
    init?(trackKind: AudioTrackKind) {
        switch trackKind {
        case .microphone:
            self = .microphone
        case .systemAudio:
            self = .systemAudio
        case .mixed:
            return nil
        }
    }
}

private extension AudioTrackKind {
    var displayName: String {
        switch self {
        case .microphone:
            "microphone"
        case .systemAudio:
            "system audio"
        case .mixed:
            "mixed audio"
        }
    }
}

private extension AudioSourceConfiguration {
    var expectedCaptureTracks: [AudioTrackKind] {
        var tracks: [AudioTrackKind] = []
        if capturesMicrophone {
            tracks.append(.microphone)
        }
        if capturesSystemAudio {
            tracks.append(.systemAudio)
        }
        return tracks
    }
}

extension RecordingStatus {
    var systemImage: String {
        switch self {
        case .idle:
            "mic.circle"
        case .preparing:
            "hourglass"
        case .recording:
            "record.circle.fill"
        case .processing:
            "waveform.badge.magnifyingglass"
        case .failed:
            "exclamationmark.triangle.fill"
        }
    }
}

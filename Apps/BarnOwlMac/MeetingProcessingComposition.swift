import AVFoundation
import BarnOwlContext
import BarnOwlCore
import BarnOwlNotes
import BarnOwlOpenAI
import BarnOwlPersistence
import BarnOwlTranscription
import Foundation

protocol MeetingProcessing: Sendable {
    func process(
        session: RecordingSession,
        progress: MeetingProcessingProgressHandler?
    ) async throws -> URL
}

protocol MeetingSummaryRepairing: Sendable {
    func repairSummary(
        meetingID: UUID,
        progress: MeetingProcessingProgressHandler?
    ) async throws -> (RecordingSession, URL)
}

typealias MeetingProcessingProgressHandler = @MainActor @Sendable (MeetingProcessingProgress) -> Void

struct MeetingProcessingProgress: Sendable {
    var level: DiagnosticsLogLevel
    var category: String
    var message: String
    var details: String?
    var progressFraction: Double?
    var transcriptPreview: String?
    var performanceEvents: [PerformanceMetricEvent]
    var sessionID: UUID?

    init(
        level: DiagnosticsLogLevel = .info,
        category: String = "processing",
        message: String,
        details: String? = nil,
        progressFraction: Double? = nil,
        transcriptPreview: String? = nil,
        performanceEvents: [PerformanceMetricEvent] = [],
        sessionID: UUID? = nil
    ) {
        self.level = level
        self.category = category
        self.message = message
        self.details = details
        self.progressFraction = progressFraction
        self.transcriptPreview = transcriptPreview
        self.performanceEvents = performanceEvents
        self.sessionID = sessionID
    }

    func scoped(to sessionID: UUID) -> MeetingProcessingProgress {
        var copy = self
        copy.sessionID = sessionID
        return copy
    }
}

enum BarnOwlMeetingProcessingError: Error, Equatable {
    case missingApplicationSupportDirectory
    case noRecordedAudioFiles(UUID)
    case missingMeeting(UUID)
    case noFinalTranscript(UUID)
}

enum BarnOwlProcessingRetryPolicy {
    static let offlineQueuedMessage = "Network unavailable. Recording is saved locally; Barn Owl will retry final processing automatically."

    static func shouldKeepQueuedForConnectivity(_ error: Error) -> Bool {
        guard let urlError = urlError(in: error) else {
            return false
        }

        switch urlError.code {
        case .notConnectedToInternet,
             .networkConnectionLost,
             .cannotConnectToHost,
             .cannotFindHost,
             .dnsLookupFailed,
             .timedOut,
             .dataNotAllowed,
             .internationalRoamingOff:
            return true
        default:
            return false
        }
    }

    private static func urlError(in error: Error) -> URLError? {
        if let urlError = error as? URLError {
            return urlError
        }

        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            return URLError(URLError.Code(rawValue: nsError.code))
        }

        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? Error {
            return urlError(in: underlying)
        }

        if let underlyingErrors = nsError.userInfo[NSMultipleUnderlyingErrorsKey] as? [Error] {
            return underlyingErrors.compactMap(urlError(in:)).first
        }

        return nil
    }
}

enum BarnOwlJobType {
    static let finalProcessing = "final_processing"
    static let summaryProcessing = "summary_processing"
    static let noteUpdate = "note_update"
    static let indexing = "indexing"
}

struct FinalProcessingJobPayload: Codable, Equatable, Sendable {
    var session: RecordingSession
}

struct SummaryProcessingJobPayload: Codable, Equatable, Sendable {
    var meetingID: UUID
}

actor BarnOwlJobRunner {
    private let makeDatabase: @Sendable () throws -> BarnOwlDatabase
    private let meetingProcessor: any MeetingProcessing
    private let summaryRepairProcessor: any MeetingSummaryRepairing
    private let maxAttempts: Int
    private var isRunning = false

    init(
        makeDatabase: @escaping @Sendable () throws -> BarnOwlDatabase,
        meetingProcessor: any MeetingProcessing,
        summaryRepairProcessor: any MeetingSummaryRepairing = BarnOwlMeetingSummaryRepairProcessor(),
        maxAttempts: Int = 3
    ) {
        self.makeDatabase = makeDatabase
        self.meetingProcessor = meetingProcessor
        self.summaryRepairProcessor = summaryRepairProcessor
        self.maxAttempts = max(1, maxAttempts)
    }

    func enqueueFinalProcessing(session: RecordingSession, priority: Int = 100) async throws -> BarnOwlJobRecord {
        let database = try makeDatabase()
        let existing = try await database.jobs(meetingID: session.id, limit: 20)
            .first {
                $0.type == BarnOwlJobType.finalProcessing
                    && ($0.status == .pending || $0.status == .running)
            }
        if let existing {
            return existing
        }

        let payload = FinalProcessingJobPayload(session: session)
        let payloadData = try JSONEncoder().encode(payload)
        let now = Date()
        let job = BarnOwlJobRecord(
            meetingID: session.id,
            type: BarnOwlJobType.finalProcessing,
            status: .pending,
            priority: priority,
            payloadJSON: String(decoding: payloadData, as: UTF8.self),
            createdAt: now,
            updatedAt: now,
            scheduledAt: now
        )
        try await database.upsertJob(job)
        return job
    }

    func enqueueSummaryProcessing(meetingID: UUID, priority: Int = 80) async throws -> BarnOwlJobRecord {
        let database = try makeDatabase()
        let jobs = try await database.jobs(meetingID: meetingID, limit: 20)
        let existing = jobs
            .first {
                $0.type == BarnOwlJobType.summaryProcessing
                    && ($0.status == .pending || $0.status == .running)
            }
        if let existing {
            return existing
        }
        if var failed = jobs.first(where: {
            $0.type == BarnOwlJobType.summaryProcessing && $0.status == .failed
        }) {
            let now = Date()
            failed.status = .pending
            failed.priority = priority
            failed.errorMessage = nil
            failed.completedAt = nil
            failed.updatedAt = now
            failed.scheduledAt = now
            try await database.upsertJob(failed)
            return failed
        }

        let payload = SummaryProcessingJobPayload(meetingID: meetingID)
        let payloadData = try JSONEncoder().encode(payload)
        let now = Date()
        let job = BarnOwlJobRecord(
            meetingID: meetingID,
            type: BarnOwlJobType.summaryProcessing,
            status: .pending,
            priority: priority,
            payloadJSON: String(decoding: payloadData, as: UTF8.self),
            createdAt: now,
            updatedAt: now,
            scheduledAt: now
        )
        try await database.upsertJob(job)
        return job
    }

    func runAvailableJobs(
        progress: MeetingProcessingProgressHandler? = nil,
        onJobChanged: (@MainActor @Sendable () async -> Void)? = nil,
        onFinalProcessingSucceeded: (@MainActor @Sendable (RecordingSession, URL) async -> Void)? = nil,
        onFinalProcessingFailed: (@MainActor @Sendable (RecordingSession?, Error, Bool) async -> Void)? = nil
    ) async {
        guard !isRunning else { return }
        isRunning = true
        defer { isRunning = false }

        while true {
            let database: BarnOwlDatabase
            do {
                database = try makeDatabase()
            } catch {
                return
            }

            guard let job = try? await database.claimNextPendingJob() else {
                await onJobChanged?()
                return
            }
            await onJobChanged?()
            await run(
                job: job,
                database: database,
                progress: progress,
                onJobChanged: onJobChanged,
                onFinalProcessingSucceeded: onFinalProcessingSucceeded,
                onFinalProcessingFailed: onFinalProcessingFailed
            )
        }
    }

    private func run(
        job: BarnOwlJobRecord,
        database: BarnOwlDatabase,
        progress: MeetingProcessingProgressHandler?,
        onJobChanged: (@MainActor @Sendable () async -> Void)?,
        onFinalProcessingSucceeded: (@MainActor @Sendable (RecordingSession, URL) async -> Void)?,
        onFinalProcessingFailed: (@MainActor @Sendable (RecordingSession?, Error, Bool) async -> Void)?
    ) async {
        switch job.type {
        case BarnOwlJobType.finalProcessing:
            await runFinalProcessingJob(
                job,
                database: database,
                progress: progress,
                onJobChanged: onJobChanged,
                onFinalProcessingSucceeded: onFinalProcessingSucceeded,
                onFinalProcessingFailed: onFinalProcessingFailed
            )
        case BarnOwlJobType.summaryProcessing:
            await runSummaryProcessingJob(
                job,
                database: database,
                progress: progress,
                onJobChanged: onJobChanged,
                onFinalProcessingSucceeded: onFinalProcessingSucceeded,
                onFinalProcessingFailed: onFinalProcessingFailed
            )
        default:
            var failed = job
            failed.status = .failed
            failed.errorMessage = "Unsupported Barn Owl job type: \(job.type)"
            failed.completedAt = Date()
            failed.updatedAt = Date()
            try? await database.upsertJob(failed)
            await onJobChanged?()
        }
    }

    private func runFinalProcessingJob(
        _ job: BarnOwlJobRecord,
        database: BarnOwlDatabase,
        progress: MeetingProcessingProgressHandler?,
        onJobChanged: (@MainActor @Sendable () async -> Void)?,
        onFinalProcessingSucceeded: (@MainActor @Sendable (RecordingSession, URL) async -> Void)?,
        onFinalProcessingFailed: (@MainActor @Sendable (RecordingSession?, Error, Bool) async -> Void)?
    ) async {
        do {
            guard let payloadJSON = job.payloadJSON,
                  let payloadData = payloadJSON.data(using: .utf8)
            else {
                throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Missing final processing payload."))
            }
            let session = try JSONDecoder().decode(FinalProcessingJobPayload.self, from: payloadData).session
            let outputURL = try await meetingProcessor.process(session: session, progress: progress)
            var succeeded = job
            succeeded.status = .succeeded
            succeeded.errorMessage = nil
            succeeded.completedAt = Date()
            succeeded.updatedAt = Date()
            try await database.upsertJob(succeeded)
            await onFinalProcessingSucceeded?(session, outputURL)
            await autoRepairFallbackSummaryIfNeeded(
                meetingID: session.id,
                database: database,
                progress: progress
            )
        } catch {
            let decodedSession = job.payloadJSON
                .flatMap { $0.data(using: .utf8) }
                .flatMap { try? JSONDecoder().decode(FinalProcessingJobPayload.self, from: $0).session }
            let keepQueuedForConnectivity = BarnOwlProcessingRetryPolicy.shouldKeepQueuedForConnectivity(error)
            let willRetry = keepQueuedForConnectivity || job.attemptCount < maxAttempts
            var next = job
            next.status = willRetry ? .pending : .failed
            next.errorMessage = keepQueuedForConnectivity
                ? BarnOwlProcessingRetryPolicy.offlineQueuedMessage
                : BarnOwlErrorFormatter.message(for: error)
            next.updatedAt = Date()
            next.scheduledAt = willRetry
                ? Date().addingTimeInterval(
                    keepQueuedForConnectivity
                        ? Self.connectivityRetryDelay(afterAttempt: job.attemptCount)
                        : Self.backoffDelay(afterAttempt: job.attemptCount)
                )
                : nil
            next.completedAt = willRetry ? nil : Date()
            try? await database.upsertJob(next)
            await onFinalProcessingFailed?(decodedSession, error, willRetry)
        }
        await onJobChanged?()
    }

    private func runSummaryProcessingJob(
        _ job: BarnOwlJobRecord,
        database: BarnOwlDatabase,
        progress: MeetingProcessingProgressHandler?,
        onJobChanged: (@MainActor @Sendable () async -> Void)?,
        onFinalProcessingSucceeded: (@MainActor @Sendable (RecordingSession, URL) async -> Void)?,
        onFinalProcessingFailed: (@MainActor @Sendable (RecordingSession?, Error, Bool) async -> Void)?
    ) async {
        do {
            guard let payloadJSON = job.payloadJSON,
                  let payloadData = payloadJSON.data(using: .utf8)
            else {
                throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Missing summary processing payload."))
            }
            let payload = try JSONDecoder().decode(SummaryProcessingJobPayload.self, from: payloadData)
            let (session, outputURL) = try await summaryRepairProcessor.repairSummary(
                meetingID: payload.meetingID,
                progress: progress
            )
            var succeeded = job
            succeeded.status = .succeeded
            succeeded.errorMessage = nil
            succeeded.completedAt = Date()
            succeeded.updatedAt = Date()
            try await database.upsertJob(succeeded)
            await onFinalProcessingSucceeded?(session, outputURL)
        } catch {
            let decodedMeetingID = job.payloadJSON
                .flatMap { $0.data(using: .utf8) }
                .flatMap { try? JSONDecoder().decode(SummaryProcessingJobPayload.self, from: $0).meetingID }
            let keepQueuedForConnectivity = BarnOwlProcessingRetryPolicy.shouldKeepQueuedForConnectivity(error)
            let willRetry = keepQueuedForConnectivity || job.attemptCount < maxAttempts
            var next = job
            next.status = willRetry ? .pending : .failed
            next.errorMessage = keepQueuedForConnectivity
                ? BarnOwlProcessingRetryPolicy.offlineQueuedMessage
                : BarnOwlErrorFormatter.message(for: error)
            next.updatedAt = Date()
            next.scheduledAt = willRetry
                ? Date().addingTimeInterval(
                    keepQueuedForConnectivity
                        ? Self.connectivityRetryDelay(afterAttempt: job.attemptCount)
                        : Self.backoffDelay(afterAttempt: job.attemptCount)
                )
                : nil
            next.completedAt = willRetry ? nil : Date()
            try? await database.upsertJob(next)
            await progress?(MeetingProcessingProgress(
                level: .warning,
                message: willRetry ? "Summary repair will retry." : "Summary repair failed.",
                details: BarnOwlErrorFormatter.message(for: error),
                sessionID: decodedMeetingID
            ))
            await onFinalProcessingFailed?(nil, error, willRetry)
        }
        await onJobChanged?()
    }

    private static func backoffDelay(afterAttempt attempt: Int) -> TimeInterval {
        switch attempt {
        case 0, 1:
            10
        case 2:
            30
        default:
            90
        }
    }

    private func autoRepairFallbackSummaryIfNeeded(
        meetingID: UUID,
        database: BarnOwlDatabase,
        progress: MeetingProcessingProgressHandler?
    ) async {
        do {
            guard let state = try await database.meetingState(id: meetingID),
                  state.summary?.usedFallbackSummary == true
            else {
                return
            }
            _ = try await enqueueSummaryProcessing(meetingID: meetingID)
            await progress?(MeetingProcessingProgress(
                level: .warning,
                message: "Queued automatic summary repair after fallback notes.",
                sessionID: meetingID
            ))
        } catch {
            await progress?(MeetingProcessingProgress(
                level: .warning,
                message: "Could not queue automatic summary repair after fallback notes.",
                details: BarnOwlErrorFormatter.message(for: error),
                sessionID: meetingID
            ))
        }
    }

    private static func connectivityRetryDelay(afterAttempt attempt: Int) -> TimeInterval {
        switch attempt {
        case 0, 1:
            60
        case 2:
            120
        default:
            300
        }
    }

}

struct BarnOwlMeetingSummaryRepairProcessor: MeetingSummaryRepairing {
    private let makeDatabase: @Sendable () throws -> BarnOwlDatabase
    private let makeLibraryStore: @Sendable () throws -> FilesystemLocalLibraryStore
    private let makeOpenAIConfiguration: @Sendable () throws -> OpenAIConfiguration

    init(
        makeDatabase: @escaping @Sendable () throws -> BarnOwlDatabase = {
            try BarnOwlDatabase(url: try BarnOwlAppModel.defaultDatabaseURL())
        },
        makeLibraryStore: @escaping @Sendable () throws -> FilesystemLocalLibraryStore = {
            FilesystemLocalLibraryStore(rootDirectory: try BarnOwlMeetingProcessor.defaultLibraryRoot())
        },
        makeOpenAIConfiguration: @escaping @Sendable () throws -> OpenAIConfiguration = {
            try BarnOwlAPIKeyStore.makeConfiguration()
        }
    ) {
        self.makeDatabase = makeDatabase
        self.makeLibraryStore = makeLibraryStore
        self.makeOpenAIConfiguration = makeOpenAIConfiguration
    }

    func repairSummary(
        meetingID: UUID,
        progress: MeetingProcessingProgressHandler? = nil
    ) async throws -> (RecordingSession, URL) {
        let database = try makeDatabase()
        guard let meeting = try await database.meeting(id: meetingID) else {
            throw BarnOwlMeetingProcessingError.missingMeeting(meetingID)
        }

        let sessionRecords = try await database.recordingSessions(meetingID: meetingID)
        let primarySession = sessionRecords.first
        let session = RecordingSession(
            id: primarySession?.id ?? meeting.id,
            title: meeting.title,
            startedAt: primarySession?.startedAt ?? meeting.startedAt ?? meeting.createdAt,
            endedAt: primarySession?.endedAt ?? meeting.endedAt,
            audioSources: Self.audioSources(from: primarySession?.audioSourcesJSON)
        )

        let segmentRecords = try await database.transcriptSegments(
            meetingID: meetingID,
            variant: .final
        )
        let segments = segmentRecords.map(Self.transcriptSegment(from:))
        guard !segments.isEmpty else {
            throw BarnOwlMeetingProcessingError.noFinalTranscript(meetingID)
        }

        await progress?(MeetingProcessingProgress(
            message: "Regenerating meeting summary...",
            details: "\(segments.count) final transcript segment(s)",
            progressFraction: 0.72,
            sessionID: meetingID
        ))

        let configuration = try makeOpenAIConfiguration()
        let baseContext = await MeetingContextBuilder.context(for: session, contextRoot: try? BarnOwlMeetingProcessor.defaultContextRoot())
        let transcriptForFacts = segments
            .map { "\($0.speakerLabel): \($0.text)" }
            .joined(separator: "\n")
        let durableKnowledge = await MeetingContextBuilder.withDurableKnowledge(
            baseContext,
            transcript: transcriptForFacts
        )
        let context = durableKnowledge.surfaces
        let summary = try await ChunkingMeetingSummaryGenerator(
            wrapped: OpenAIMeetingSummaryGeneratorAdapter(
                client: OpenAIMeetingSummaryClient(configuration: configuration)
            ),
            progress: progress
        ).generateSummary(session: session, segments: segments, context: context.summaryGrounding)
        BarnOwlAPIKeyStore.markAPIKeyVerified(configuration.apiKey)

        var finalSession = session
        finalSession.title = MeetingTitleSuggester.title(
            currentTitle: meeting.title,
            summary: summary,
            segments: segments,
            context: context.summaryGrounding
        )
        var meetingFacts = MeetingFactsExtractor().extract(
            transcript: transcriptForFacts,
            freeformContext: MeetingContextBuilder.factsContext(from: context),
            currentTitle: finalSession.title
        )
        if let factTitle = MeetingFacts.clean(meetingFacts.title) {
            finalSession.title = factTitle
        } else {
            meetingFacts.title = finalSession.title
        }
        try? await MeetingContextBuilder.recordDurableKnowledgeApplications(
            durableKnowledge.matches,
            ownerID: BarnOwlEnrichmentSourceOwner.localUserID(),
            meetingID: meetingID,
            meetingFacts: meetingFacts,
            surface: "summary_repair",
            usedInSummaryGeneration: true,
            usedInNoteGeneration: true,
            database: database,
            createdAt: Date()
        )

        let markdown = MarkdownMeetingRenderer().render(
            session: finalSession,
            segments: segments,
            summary: summary,
            context: MeetingContextBuilder.noteContext(from: context),
            meetingFacts: meetingFacts
        )
        let artifact = LocalMeetingArtifact(
            session: finalSession,
            summary: summary,
            transcriptSegments: segments,
            markdown: markdown
        )

        await progress?(MeetingProcessingProgress(
            message: "Saving repaired summary and notes...",
            progressFraction: 0.92,
            sessionID: meetingID
        ))

        let location = try await makeLibraryStore().saveArtifact(artifact)
        if let contextRoot = try? BarnOwlMeetingProcessor.defaultContextRoot() {
            let contextProvider = LocalMarkdownContextProvider(rootDirectory: contextRoot)
            if meeting.title.caseInsensitiveCompare(finalSession.title) != .orderedSame {
                try? await contextProvider.remove(title: meeting.title)
            }
            try? await contextProvider.write(ContextArtifact(title: finalSession.title, markdown: markdown))
        }

        let now = Date()
        var updatedMeeting = meeting
        updatedMeeting.title = finalSession.title
        updatedMeeting.startedAt = updatedMeeting.startedAt ?? finalSession.startedAt
        updatedMeeting.endedAt = updatedMeeting.endedAt ?? finalSession.endedAt
        updatedMeeting.updatedAt = now
        updatedMeeting.metadataJSON = Self.meetingMetadataJSON(audioSources: finalSession.audioSources, meetingFacts: meetingFacts)
        try await database.upsertMeeting(updatedMeeting)
        try await database.replaceMeetingOutput(BarnOwlMeetingOutputRecord(
            meetingID: meetingID,
            kind: "markdown",
            content: markdown,
            createdAt: now,
            updatedAt: now,
            metadataJSON: #"{"source":"summary-repair"}"#
        ))
        try await database.replaceMeetingOutput(BarnOwlMeetingOutputRecord(
            meetingID: meetingID,
            kind: "summary",
            content: summary.overview,
            contentType: "text/plain",
            createdAt: now,
            updatedAt: now,
            metadataJSON: #"{"source":"summary-repair"}"#
        ))
        try await database.replaceMeetingOutput(BarnOwlMeetingOutputRecord(
            meetingID: meetingID,
            kind: "context_used",
            content: MeetingContextBuilder.noteContext(from: context).joined(separator: "\n"),
            contentType: "text/plain",
            createdAt: now,
            updatedAt: now,
            metadataJSON: #"{"source":"summary-repair"}"#
        ))
        if let factsJSON = meetingFacts.encodedJSONString() {
            try await database.replaceMeetingOutput(BarnOwlMeetingOutputRecord(
                meetingID: meetingID,
                kind: "meeting_facts",
                content: factsJSON,
                contentType: "application/json",
                createdAt: now,
                updatedAt: now,
                metadataJSON: #"{"source":"summary-repair"}"#
            ))
        }
        try await database.recordMeetingExportEvent(BarnOwlMeetingExportEventRecord(
            type: .summaryRepaired,
            meetingID: meetingID,
            meetingStableKey: "barnowl:meeting:\(meetingID.uuidString)",
            occurredAt: now
        ))

        await progress?(MeetingProcessingProgress(
            message: "Repaired meeting summary.",
            progressFraction: 1.0,
            sessionID: meetingID
        ))
        return (finalSession, location.markdownFileURL)
    }

    private static func transcriptSegment(from record: BarnOwlTranscriptSegmentRecord) -> TranscriptSegment {
        TranscriptSegment(
            id: record.id,
            speakerLabel: record.speakerLabel ?? "Speaker",
            text: record.text,
            startTime: record.startTime,
            endTime: record.endTime,
            confidence: record.confidence
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

    private static func meetingMetadataJSON(
        audioSources: AudioSourceConfiguration,
        meetingFacts: MeetingFacts
    ) -> String {
        var object: [String: Any] = [
            "microphone": audioSources.capturesMicrophone,
            "systemAudio": audioSources.capturesSystemAudio
        ]
        if let factsData = try? JSONEncoder().encode(meetingFacts),
           let factsObject = try? JSONSerialization.jsonObject(with: factsData) {
            object["meetingFacts"] = factsObject
        }
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }
}

struct BarnOwlMeetingProcessor: MeetingProcessing {
    private let tempAudioRoot: URL
    private let makeLibraryStore: @Sendable () throws -> FilesystemLocalLibraryStore
    private let makeOpenAIConfiguration: @Sendable () throws -> OpenAIConfiguration
    private let makeDatabase: @Sendable () throws -> BarnOwlDatabase

    init(
        tempAudioRoot: URL = BarnOwlAudioCaptureFactory.tempRoot,
        makeLibraryStore: @escaping @Sendable () throws -> FilesystemLocalLibraryStore = {
            FilesystemLocalLibraryStore(rootDirectory: try BarnOwlMeetingProcessor.defaultLibraryRoot())
        },
        makeOpenAIConfiguration: @escaping @Sendable () throws -> OpenAIConfiguration = {
            try BarnOwlAPIKeyStore.makeConfiguration()
        },
        makeDatabase: @escaping @Sendable () throws -> BarnOwlDatabase = {
            try BarnOwlDatabase(url: try BarnOwlAppModel.defaultDatabaseURL())
        }
    ) {
        self.tempAudioRoot = tempAudioRoot
        self.makeLibraryStore = makeLibraryStore
        self.makeOpenAIConfiguration = makeOpenAIConfiguration
        self.makeDatabase = makeDatabase
    }

    func process(
        session: RecordingSession,
        progress: MeetingProcessingProgressHandler? = nil
    ) async throws -> URL {
        let scopedProgress: MeetingProcessingProgressHandler?
        if let progress {
            scopedProgress = { update in
                progress(update.scoped(to: session.id))
            }
        } else {
            scopedProgress = nil
        }

        await scopedProgress?(MeetingProcessingProgress(
            message: "Looking for captured audio...",
            progressFraction: 0.05
        ))
        let audioProvider = TempAudioRecordedFileProvider(tempRoot: tempAudioRoot)
        let audioFiles = try await audioProvider.audioFiles(for: session)
        guard !audioFiles.isEmpty else {
            throw BarnOwlMeetingProcessingError.noRecordedAudioFiles(session.id)
        }
        await scopedProgress?(MeetingProcessingProgress(
            message: "Found \(audioFiles.count) audio chunk(s).",
            details: audioFiles.map { "\($0.trackLabel): \($0.url.lastPathComponent)" }.joined(separator: "\n"),
            progressFraction: 0.1
        ))

        await scopedProgress?(MeetingProcessingProgress(
            message: "Preparing OpenAI clients...",
            progressFraction: 0.15
        ))
        let configuration = try makeOpenAIConfiguration()
        let openAITranscriptionClient = OpenAIAudioFileTranscriptionClientAdapter(
            client: OpenAITranscriptionClient(configuration: configuration)
        )
        let finalTranscriptionClient: any AudioFileTranscriptionClient
        if let database = try? makeDatabase() {
            finalTranscriptionClient = CachedAudioFileTranscriptionClient(
                sessionID: session.id,
                wrapped: openAITranscriptionClient,
                cacheStore: SQLiteRollingFinalTranscriptionCacheStore(database: database),
                modelIdentifier: OpenAIModelCatalog.finalDiarization
            )
        } else {
            finalTranscriptionClient = openAITranscriptionClient
        }
        let transcriptionClient = ProgressReportingAudioFileTranscriptionClient(
            wrapped: finalTranscriptionClient,
            progress: scopedProgress,
            totalFileCount: audioFiles.count
        )
        let summaryGenerator = FallbackMeetingSummaryGenerator(
            wrapped: ChunkingMeetingSummaryGenerator(
                wrapped: OpenAIMeetingSummaryGeneratorAdapter(
                    client: OpenAIMeetingSummaryClient(configuration: configuration)
                ),
                progress: scopedProgress
            ),
            progress: scopedProgress
        )
        let pipeline = FinalTranscriptionPipeline(
            transcriptionClient: transcriptionClient,
            qualityReviewer: TranscriptSanitizingQualityReviewer(),
            summaryGenerator: summaryGenerator,
            summaryContextProvider: { _, segments, context in
                let transcript = segments
                    .map { "\($0.speakerLabel): \($0.text)" }
                    .joined(separator: "\n")
                return await MeetingContextBuilder.withDurableKnowledge(
                    MeetingContextBuilder.SurfaceContext(
                        summaryGrounding: context,
                        factExtraction: [],
                        noteRendering: []
                    ),
                    transcript: transcript
                ).surfaces.summaryGrounding
            },
            overlapRepairClient: OpenAITranscriptOverlapRepairClient(configuration: configuration)
        )
        let baseContext = await MeetingContextBuilder.context(for: session, contextRoot: try? Self.defaultContextRoot())
        let result = try await pipeline.run(
            session: session,
            audioFiles: audioFiles,
            context: baseContext.summaryGrounding
        )
        BarnOwlAPIKeyStore.markAPIKeyVerified(configuration.apiKey)
        var finalSession = session
        let transcriptForFacts = result.segments
            .map { "\($0.speakerLabel): \($0.text)" }
            .joined(separator: "\n")
        let durableKnowledge = await MeetingContextBuilder.withDurableKnowledge(
            baseContext,
            transcript: transcriptForFacts
        )
        let context = durableKnowledge.surfaces
        finalSession.title = MeetingTitleSuggester.title(
            currentTitle: session.title,
            summary: result.summary,
            segments: result.segments,
            context: context.summaryGrounding
        )
        if finalSession.title != session.title {
            await scopedProgress?(MeetingProcessingProgress(
                message: "Labeled meeting as \(finalSession.title).",
                progressFraction: 0.87
            ))
        }
        var meetingFacts = MeetingFactsExtractor().extract(
            transcript: transcriptForFacts,
            freeformContext: MeetingContextBuilder.factsContext(from: context),
            currentTitle: finalSession.title
        )
        if let factTitle = MeetingFacts.clean(meetingFacts.title) {
            finalSession.title = factTitle
        } else {
            meetingFacts.title = finalSession.title
        }
        if let database = try? makeDatabase() {
            try? await MeetingContextBuilder.recordDurableKnowledgeApplications(
                durableKnowledge.matches,
                ownerID: BarnOwlEnrichmentSourceOwner.localUserID(),
                meetingID: session.id,
                meetingFacts: meetingFacts,
                surface: "final_processing",
                usedInSummaryGeneration: true,
                usedInNoteGeneration: true,
                database: database,
                createdAt: Date()
            )
        }
        BarnOwlRealtimeTranscriptionHintsStore.learn(
            meetingFacts: meetingFacts,
            segments: result.segments
        )
        await scopedProgress?(MeetingProcessingProgress(
            message: "Running final cleanup pass...",
            details: "\(result.segments.count) final speaker turn(s)",
            progressFraction: 0.88
        ))
        await scopedProgress?(MeetingProcessingProgress(
            message: "Rendering Barn Owl notes...",
            progressFraction: 0.92
        ))
        let markdown = MarkdownMeetingRenderer().render(
            session: finalSession,
            segments: result.segments,
            summary: result.summary,
            context: MeetingContextBuilder.noteContext(from: context),
            meetingFacts: meetingFacts
        )

        let artifact = LocalMeetingArtifact(
            session: finalSession,
            summary: result.summary,
            transcriptSegments: result.segments,
            markdown: markdown
        )
        await scopedProgress?(MeetingProcessingProgress(
            message: "Saving meeting artifacts to Barn Owl Library...",
            progressFraction: 0.97
        ))
        let location = try await makeLibraryStore().saveArtifact(artifact)
        await scopedProgress?(MeetingProcessingProgress(
            message: "Refreshing local meeting context...",
            progressFraction: 0.985
        ))
        try? await LocalMarkdownContextProvider(rootDirectory: try Self.defaultContextRoot())
            .write(ContextArtifact(title: finalSession.title, markdown: markdown))
        await clearRollingTranscriptionCache(
            sessionID: session.id,
            progress: scopedProgress
        )
        await scopedProgress?(MeetingProcessingProgress(
            message: "Saved final transcript and notes.",
            details: location.markdownFileURL.lastPathComponent,
            progressFraction: 1.0
        ))
        return location.markdownFileURL
    }

    private func clearRollingTranscriptionCache(
        sessionID: UUID,
        progress: MeetingProcessingProgressHandler?
    ) async {
        do {
            try await makeDatabase().deleteRollingTranscriptions(sessionID: sessionID)
        } catch {
            await progress?(MeetingProcessingProgress(
                level: .warning,
                category: "privacy",
                message: "Could not clear rolling transcription cache.",
                details: BarnOwlErrorFormatter.message(for: error)
            ))
        }
    }

    static func defaultLibraryRoot() throws -> URL {
        guard let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            throw BarnOwlMeetingProcessingError.missingApplicationSupportDirectory
        }

        return applicationSupport
            .appending(path: "Barn Owl", directoryHint: .isDirectory)
            .appending(path: "Library", directoryHint: .isDirectory)
    }

    static func defaultContextRoot() throws -> URL {
        guard let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            throw BarnOwlMeetingProcessingError.missingApplicationSupportDirectory
        }

        return applicationSupport
            .appending(path: "Barn Owl", directoryHint: .isDirectory)
            .appending(path: "Context", directoryHint: .isDirectory)
    }
}

struct NoOpMeetingProcessor: MeetingProcessing {
    func process(
        session: RecordingSession,
        progress: MeetingProcessingProgressHandler? = nil
    ) async throws -> URL {
        await progress?(MeetingProcessingProgress(message: "No-op processor completed."))
        return FileManager.default.temporaryDirectory
            .appending(path: "\(session.id.uuidString).md")
    }
}

private enum MeetingProcessingPerformanceClock {
    static func now() -> TimeInterval {
        Date().timeIntervalSince1970
    }
}

private struct ProgressReportingAudioFileTranscriptionClient: AudioFileTranscriptionClient {
    private let wrapped: any AudioFileTranscriptionClient
    private let progress: MeetingProcessingProgressHandler?
    private let totalFileCount: Int
    private let counter = TranscriptionProgressCounter()

    init(
        wrapped: any AudioFileTranscriptionClient,
        progress: MeetingProcessingProgressHandler?,
        totalFileCount: Int
    ) {
        self.wrapped = wrapped
        self.progress = progress
        self.totalFileCount = totalFileCount
    }

    func transcribe(audioFile: RecordedAudioFile) async throws -> AudioFileTranscriptionResponse {
        await progress?(MeetingProcessingProgress(
            message: "Transcribing \(audioFile.trackLabel) chunk \(audioFile.url.lastPathComponent)...",
            details: audioDetails(for: audioFile.url),
            progressFraction: await counter.currentFraction(total: totalFileCount),
            performanceEvents: [
                .phase(
                    .modelRequest,
                    .started,
                    at: MeetingProcessingPerformanceClock.now(),
                    model: OpenAIModelCatalog.finalDiarization
                )
            ]
        ))

        do {
            let response = try await wrapped.transcribe(audioFile: audioFile)
            let completedCount = await counter.increment()
            let transcriptPreview = response.segments
                .map(\.text)
                .joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            await progress?(MeetingProcessingProgress(
                message: "Transcribed \(audioFile.trackLabel) chunk \(audioFile.url.lastPathComponent).",
                details: "\(response.segments.count) segment(s)",
                progressFraction: Self.progressFraction(completedCount: completedCount, totalFileCount: totalFileCount),
                transcriptPreview: transcriptPreview.isEmpty ? nil : transcriptPreview,
                performanceEvents: [
                    .phase(
                        .modelRequest,
                        .finished,
                        at: MeetingProcessingPerformanceClock.now(),
                        model: OpenAIModelCatalog.finalDiarization
                    )
                ]
            ))
            return response
        } catch {
            await progress?(MeetingProcessingProgress(
                level: .error,
                message: "Transcription failed for \(audioFile.trackLabel) chunk \(audioFile.url.lastPathComponent).",
                details: BarnOwlErrorFormatter.message(for: error),
                performanceEvents: [
                    .phase(
                        .modelRequest,
                        .finished,
                        at: MeetingProcessingPerformanceClock.now(),
                        model: OpenAIModelCatalog.finalDiarization
                    )
                ]
            ))
            throw error
        }
    }

    private func audioDetails(for url: URL) -> String {
        let byteCount = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        return "\(url.pathExtension.uppercased()) • \(byteCount) bytes"
    }

    private static func progressFraction(completedCount: Int, totalFileCount: Int) -> Double {
        guard totalFileCount > 0 else { return 0.75 }
        return 0.15 + (Double(completedCount) / Double(totalFileCount)) * 0.6
    }
}

private actor TranscriptionProgressCounter {
    private var completedCount = 0

    func increment() -> Int {
        completedCount += 1
        return completedCount
    }

    func currentFraction(total: Int) -> Double {
        guard total > 0 else { return 0.15 }
        return 0.15 + (Double(completedCount) / Double(total)) * 0.6
    }
}

enum MeetingTitleSuggester {
    static func title(
        currentTitle: String,
        summary: MeetingSummary,
        segments: [TranscriptSegment],
        context: [String] = []
    ) -> String {
        let contextText = context.joined(separator: "\n")
        let transcriptText = segments
            .map(\.text)
            .joined(separator: "\n")
        let organization = primaryOrganization(contextText: contextText)

        if let contextTitle = contextualTitle(from: contextText),
           !isGeneric(contextTitle),
           !isLikelyTranscriptAside(contextTitle) {
            return contextualized(
                contextTitle,
                organization: organization,
                contextText: contextText,
                transcriptText: transcriptText
            )
        }

        if let current = normalized(currentTitle),
           !isGeneric(current),
           !isLikelyTranscriptAside(current) {
            return contextualized(
                current,
                organization: organization,
                contextText: contextText,
                transcriptText: transcriptText
            )
        }

        if let suggested = normalized(summary.suggestedTitle),
           !isGeneric(suggested),
           !isLikelyTranscriptAside(suggested) {
            return contextualized(
                suggested,
                organization: organization,
                contextText: contextText,
                transcriptText: transcriptText
            )
        }

        let candidates = [
            summary.overview,
            summary.decisions.first,
            summary.actionItems.first,
            segments.first { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }?.text
        ].compactMap { $0 }

        for candidate in candidates {
            if let title = titleFromSentence(candidate),
               !isGeneric(title),
               !isLikelyTranscriptAside(title) {
                return contextualized(
                    title,
                    organization: organization,
                    contextText: contextText,
                    transcriptText: transcriptText
                )
            }
        }

        return "Meeting Notes"
    }

    private static func contextualTitle(from contextText: String) -> String? {
        firstMatch(in: contextText, patterns: [
            #"(?im)^Meeting title:\s*(.+)$"#,
            #"(?im)^Calendar event:\s*(.+)$"#,
            #"(?im)^Title:\s*(.+)$"#
        ])
    }

    private static func contextualized(
        _ title: String,
        organization: String?,
        contextText: String,
        transcriptText: String
    ) -> String {
        guard let cleanTitle = normalized(title) else { return "Meeting Notes" }
        let formattedTitle = titleCasedTopic(cleanTitle)
        guard let organization = normalized(organization),
              !organization.isEmpty
        else {
            return formattedTitle
        }

        let lowerTitle = formattedTitle.lowercased()
        let lowerOrganization = organization.lowercased()
        if lowerTitle.hasPrefix("\(lowerOrganization):") || lowerTitle.hasPrefix("\(lowerOrganization) ") {
            return formattedTitle
        }
        guard shouldPrefixWithOrganization(
            formattedTitle,
            organization: organization,
            contextText: contextText,
            transcriptText: transcriptText
        ) else {
            return formattedTitle
        }
        return "\(organization): \(formattedTitle)"
    }

    private static func shouldPrefixWithOrganization(
        _ title: String,
        organization: String,
        contextText: String,
        transcriptText: String
    ) -> Bool {
        let lowerTitle = title.lowercased()
        let lowerOrganization = organization.lowercased()
        guard !lowerTitle.contains(lowerOrganization) else { return false }
        guard !isGeneric(title) else { return false }
        guard !looksLikeInternalTitle(lowerTitle) else { return false }

        let combined = [contextText, transcriptText]
            .joined(separator: "\n")
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .lowercased()
        guard customerOrExternalSignals.contains(where: { combined.contains($0) })
                || lowerTitle.contains("feedback")
                || lowerTitle.contains("partnership")
                || lowerTitle.contains("on-site")
                || lowerTitle.contains("onsite")
                || lowerTitle.contains("executive")
                || lowerTitle.contains("ceo")
                || lowerTitle.contains("cio")
        else {
            return false
        }
        return true
    }

    private static func looksLikeInternalTitle(_ lowerTitle: String) -> Bool {
        internalTitleSignals.contains { lowerTitle.contains($0) }
    }

    private static func primaryOrganization(contextText: String) -> String? {
        firstMatch(in: contextText, patterns: [
            #"(?im)^Customer:\s*(.+)$"#,
            #"(?im)^Account:\s*(.+)$"#,
            #"(?im)^Organization:\s*(.+)$"#,
            #"(?im)^Company:\s*(.+)$"#
        ])
    }

    private static func firstMatch(in text: String, patterns: [String]) -> String? {
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(text.startIndex ..< text.endIndex, in: text)
            guard let match = regex.firstMatch(in: text, range: range),
                  match.numberOfRanges > 1,
                  let matchRange = Range(match.range(at: 1), in: text)
            else { continue }
            if let cleaned = normalized(String(text[matchRange])) {
                return cleaned
            }
        }
        return nil
    }

    private static func titleFromSentence(_ text: String) -> String? {
        let sentence = text
            .replacingOccurrences(of: "\n", with: " ")
            .split(whereSeparator: { ".?!".contains($0) })
            .first
            .map(String.init) ?? text
        let words = sentence
            .split { !$0.isLetter && !$0.isNumber && $0 != "-" }
            .map { String($0) }
            .filter { word in
                let lowercased = word.lowercased()
                return word.count > 1 && !stopWords.contains(lowercased)
            }
            .prefix(7)

        let title = words
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
        return normalized(title)
    }

    private static func titleCasedTopic(_ title: String) -> String {
        title
            .split(separator: " ")
            .map { word -> String in
                let raw = String(word)
                let trimmed = raw.trimmingCharacters(in: CharacterSet(charactersIn: ":"))
                let suffix = raw.hasSuffix(":") ? ":" : ""
                if let special = specialTitleWords[trimmed.lowercased()] {
                    return special + suffix
                }
                if trimmed.count > 1,
                   trimmed.unicodeScalars.allSatisfy({ CharacterSet.uppercaseLetters.contains($0) || CharacterSet.decimalDigits.contains($0) }) {
                    return raw
                }
                if smallTitleWords.contains(trimmed.lowercased()) {
                    return trimmed.lowercased() + suffix
                }
                return trimmed.prefix(1).uppercased() + trimmed.dropFirst() + suffix
            }
            .joined(separator: " ")
    }

    private static func normalized(_ title: String?) -> String? {
        let cleaned = title?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: #""'`“”‘’.,:;-_"#))
        guard let cleaned, !cleaned.isEmpty else { return nil }
        return String(cleaned.prefix(72))
    }

    private static func isGeneric(_ title: String) -> Bool {
        let normalizedTitle = title
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return genericTitles.contains(normalizedTitle)
            || normalizedTitle.hasPrefix("untitled")
    }

    private static func isLikelyTranscriptAside(_ title: String) -> Bool {
        let normalizedTitle = title
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return transcriptAsideTitleSignals.contains { normalizedTitle.contains($0) }
    }

    private static let genericTitles: Set<String> = [
        "meeting",
        "meeting notes",
        "sync",
        "call",
        "discussion",
        "general discussion",
        "transcript saved",
        "untitled meeting"
    ]

    private static let stopWords: Set<String> = [
        "the", "a", "an", "and", "or", "but", "to", "of", "in", "on", "for",
        "with", "from", "about", "that", "this", "these", "those", "we", "they",
        "you", "i", "it", "is", "are", "was", "were", "be", "being", "been",
        "should", "would", "could", "will", "can", "team", "speaker", "discussed",
        "reviewed", "agreed"
    ]

    private static let customerOrExternalSignals: Set<String> = [
        "account",
        "customer",
        "client",
        "prospect",
        "external",
        "exec sponsor",
        "executive sponsor",
        "onsite",
        "on-site",
        "qbr",
        "ebr",
        "partnership",
        "feedback session"
    ]

    private static let internalTitleSignals: Set<String> = [
        "1:1",
        "one-on-one",
        "one on one",
        "staff",
        "team sync",
        "standup",
        "retro",
        "retrospective",
        "planning",
        "roadmap",
        "incident",
        "interview",
        "candidate",
        "hiring",
        "design review",
        "project review"
    ]

    private static let specialTitleWords: [String: String] = [
        "ai": "AI",
        "api": "API",
        "ceo": "CEO",
        "cio": "CIO",
        "cios": "CIOs",
        "cto": "CTO",
        "dlp": "DLP",
        "gpt": "GPT"
    ]

    private static let smallTitleWords: Set<String> = [
        "and", "or", "of", "for", "to", "with", "in", "on"
    ]

    private static let transcriptAsideTitleSignals: Set<String> = [
        "mafia",
        "inside joke",
        "funny story",
        "crazy story"
    ]
}

private struct ChunkingMeetingSummaryGenerator: MeetingSummaryGenerator {
    private let wrapped: any MeetingSummaryGenerator
    private let progress: MeetingProcessingProgressHandler?
    private let maxDirectSegments: Int
    private let maxDirectCharacters: Int
    private let maxChunkSegments: Int
    private let maxChunkCharacters: Int

    init(
        wrapped: any MeetingSummaryGenerator,
        progress: MeetingProcessingProgressHandler?,
        maxDirectSegments: Int = 500,
        maxDirectCharacters: Int = 80_000,
        maxChunkSegments: Int = 300,
        maxChunkCharacters: Int = 45_000
    ) {
        self.wrapped = wrapped
        self.progress = progress
        self.maxDirectSegments = maxDirectSegments
        self.maxDirectCharacters = maxDirectCharacters
        self.maxChunkSegments = maxChunkSegments
        self.maxChunkCharacters = maxChunkCharacters
    }

    func generateSummary(
        session: RecordingSession,
        segments: [TranscriptSegment],
        context: [String]
    ) async throws -> MeetingSummary {
        let transcriptCharacterCount = segments.reduce(0) { $0 + $1.text.count }
        guard segments.count > maxDirectSegments || transcriptCharacterCount > maxDirectCharacters else {
            return try await wrapped.generateSummary(session: session, segments: segments, context: context)
        }

        let chunks = chunked(segments)
        await progress?(MeetingProcessingProgress(
            message: "Summarizing long meeting in \(chunks.count) parts...",
            details: "\(segments.count) transcript segment(s), \(transcriptCharacterCount) character(s)",
            progressFraction: 0.78,
            sessionID: session.id
        ))

        var chunkSummaries: [MeetingSummary] = []
        chunkSummaries.reserveCapacity(chunks.count)
        for (index, chunk) in chunks.enumerated() {
            let chunkNumber = index + 1
            await progress?(MeetingProcessingProgress(
                message: "Summarizing meeting part \(chunkNumber) of \(chunks.count)...",
                details: "\(chunk.count) transcript segment(s)",
                progressFraction: 0.78 + (Double(index) / Double(max(chunks.count, 1))) * 0.05,
                sessionID: session.id
            ))
            let chunkContext = context + [
                "Barn Owl is summarizing transcript part \(chunkNumber) of \(chunks.count). Focus on durable decisions, action items, open questions, customer feedback, and important technical/product details from this chronological slice. The final pass will synthesize all parts."
            ]
            let summary = try await wrapped.generateSummary(
                session: session,
                segments: chunk,
                context: chunkContext
            )
            chunkSummaries.append(summary)
        }

        await progress?(MeetingProcessingProgress(
            message: "Synthesizing meeting summary from \(chunks.count) parts...",
            progressFraction: 0.84,
            sessionID: session.id
        ))
        let syntheticSegments = zip(chunks.indices, chunkSummaries).map { index, summary in
            let chunk = chunks[index]
            return TranscriptSegment(
                speakerLabel: "Barn Owl Part \(index + 1)",
                text: Self.chunkSummaryText(summary, index: index, total: chunks.count),
                startTime: chunk.first?.startTime ?? 0,
                endTime: chunk.last?.endTime ?? chunk.first?.endTime ?? 0,
                confidence: nil
            )
        }
        let synthesisContext = context + [
            "The transcript was too long for one reliable model request, so Barn Owl summarized it in \(chunks.count) chronological parts. Synthesize these part summaries into one accurate meeting summary. Preserve concrete decisions, action items, open questions, customer feedback, names, organizations, and technical details. Do not mention that chunking happened."
        ]
        return try await wrapped.generateSummary(
            session: session,
            segments: syntheticSegments,
            context: synthesisContext
        )
    }

    private func chunked(_ segments: [TranscriptSegment]) -> [[TranscriptSegment]] {
        var chunks: [[TranscriptSegment]] = []
        var current: [TranscriptSegment] = []
        var currentCharacters = 0

        for segment in segments {
            let segmentCharacters = segment.text.count
            let wouldExceedSegments = current.count >= maxChunkSegments
            let wouldExceedCharacters = currentCharacters + segmentCharacters > maxChunkCharacters
            if !current.isEmpty && (wouldExceedSegments || wouldExceedCharacters) {
                chunks.append(current)
                current = []
                currentCharacters = 0
            }
            current.append(segment)
            currentCharacters += segmentCharacters
        }

        if !current.isEmpty {
            chunks.append(current)
        }
        return chunks
    }

    private static func chunkSummaryText(_ summary: MeetingSummary, index: Int, total: Int) -> String {
        var lines = [
            "Part \(index + 1) of \(total)",
            "Overview: \(summary.overview)"
        ]
        if !summary.decisions.isEmpty {
            lines.append("Decisions: \(summary.decisions.joined(separator: "; "))")
        }
        if !summary.actionItems.isEmpty {
            lines.append("Action items: \(summary.actionItems.joined(separator: "; "))")
        }
        if !summary.openQuestions.isEmpty {
            lines.append("Open questions: \(summary.openQuestions.joined(separator: "; "))")
        }
        return lines.joined(separator: "\n")
    }
}

private struct FallbackMeetingSummaryGenerator: MeetingSummaryGenerator {
    private let wrapped: any MeetingSummaryGenerator
    private let progress: MeetingProcessingProgressHandler?

    init(
        wrapped: any MeetingSummaryGenerator,
        progress: MeetingProcessingProgressHandler?
    ) {
        self.wrapped = wrapped
        self.progress = progress
    }

    func generateSummary(
        session: RecordingSession,
        segments: [TranscriptSegment],
        context: [String]
    ) async throws -> MeetingSummary {
        await progress?(MeetingProcessingProgress(
            message: "Generating meeting summary...",
            details: "\(segments.count) transcript segment(s)",
            progressFraction: 0.8,
            performanceEvents: [
                .phase(
                    .modelRequest,
                    .started,
                    at: MeetingProcessingPerformanceClock.now(),
                    model: OpenAIModelCatalog.summaryAndActions
                )
            ]
        ))

        do {
            let summary = try await wrapped.generateSummary(
                session: session,
                segments: segments,
                context: context
            )
            await progress?(MeetingProcessingProgress(
                message: "Generated meeting summary.",
                progressFraction: 0.86,
                performanceEvents: [
                    .phase(
                        .modelRequest,
                        .finished,
                        at: MeetingProcessingPerformanceClock.now(),
                        model: OpenAIModelCatalog.summaryAndActions
                    )
                ]
            ))
            return summary
        } catch {
            let details = BarnOwlErrorFormatter.message(for: error)
            if BarnOwlProcessingRetryPolicy.shouldKeepQueuedForConnectivity(error) {
                await progress?(MeetingProcessingProgress(
                    level: .warning,
                    message: "Summary generation hit a network error; leaving job queued for retry.",
                    details: details,
                    performanceEvents: [
                        .phase(
                            .modelRequest,
                            .finished,
                            at: MeetingProcessingPerformanceClock.now(),
                            model: OpenAIModelCatalog.summaryAndActions
                        )
                    ]
                ))
                throw error
            }
            await progress?(MeetingProcessingProgress(
                level: .warning,
                message: "Summary failed; saving transcript with fallback notes.",
                details: details,
                performanceEvents: [
                    .phase(
                        .modelRequest,
                        .finished,
                        at: MeetingProcessingPerformanceClock.now(),
                        model: OpenAIModelCatalog.summaryAndActions
                    )
                ]
            ))
            return MeetingSummary(
                overview: MeetingSummary.fallbackOverview,
                openQuestions: ["Summary generation error: \(details)"]
            )
        }
    }
}

struct TempAudioRecordedFileProvider: RecordedAudioFileProviding {
    private let tempRoot: URL
    private let chunkDurationEstimate: TimeInterval

    init(tempRoot: URL, chunkDurationEstimate: TimeInterval = 30) {
        self.tempRoot = tempRoot
        self.chunkDurationEstimate = chunkDurationEstimate
    }

    func audioFiles(for session: RecordingSession) async throws -> [RecordedAudioFile] {
        let sessionDirectory = tempRoot.appending(path: session.id.uuidString, directoryHint: .isDirectory)
        guard FileManager.default.fileExists(atPath: sessionDirectory.path(percentEncoded: false)) else {
            return []
        }

        let trackDirectories = try FileManager.default.contentsOfDirectory(
            at: sessionDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )

        var files: [RecordedAudioFile] = []
        for trackDirectory in trackDirectories {
            guard try isDirectory(trackDirectory),
                  trackDirectory.lastPathComponent != "_metadata"
            else {
                continue
            }

            let audioFileURLs = try FileManager.default.contentsOfDirectory(
                at: trackDirectory,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            )
            .filter { Self.supportedAudioFileExtensions.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

            var cumulativeOffset: TimeInterval = 0
            var expectedSequenceNumber = 0
            for audioFileURL in audioFileURLs {
                let sequenceNumber = sequenceNumber(from: audioFileURL) ?? files.count
                let metadata = try? await tempMetadata(
                    sessionID: session.id,
                    trackKind: trackDirectory.lastPathComponent,
                    sequenceNumber: sequenceNumber
                )
                if sequenceNumber > expectedSequenceNumber {
                    cumulativeOffset = max(
                        cumulativeOffset,
                        TimeInterval(sequenceNumber) * chunkDurationEstimate
                    )
                    expectedSequenceNumber = sequenceNumber
                }
                files.append(
                    RecordedAudioFile(
                        url: audioFileURL,
                        trackLabel: trackLabel(for: trackDirectory.lastPathComponent),
                        startTimeOffset: metadata?.startTimeOffset ?? cumulativeOffset,
                        sequenceNumber: sequenceNumber,
                        trackID: trackDirectory.lastPathComponent,
                        duration: metadata?.duration ?? duration(of: audioFileURL),
                        overlapDuration: metadata?.overlapDuration
                    )
                )
                if let metadata, let strideDuration = metadata.strideDuration {
                    cumulativeOffset = metadata.startTimeOffset.map { $0 + strideDuration }
                        ?? (cumulativeOffset + strideDuration)
                } else {
                    cumulativeOffset += duration(of: audioFileURL) ?? chunkDurationEstimate
                }
                expectedSequenceNumber += 1
            }
        }

        return files.sorted {
            if $0.startTimeOffset != $1.startTimeOffset {
                return $0.startTimeOffset < $1.startTimeOffset
            }

            if $0.trackLabel != $1.trackLabel {
                return $0.trackLabel < $1.trackLabel
            }

            return $0.url.lastPathComponent < $1.url.lastPathComponent
        }
    }

    private func isDirectory(_ url: URL) throws -> Bool {
        let values = try url.resourceValues(forKeys: [.isDirectoryKey])
        return values.isDirectory == true
    }

    private func sequenceNumber(from url: URL) -> Int? {
        Int(url.deletingPathExtension().lastPathComponent)
    }

    private func duration(of url: URL) -> TimeInterval? {
        guard let file = try? AVAudioFile(forReading: url),
              file.processingFormat.sampleRate > 0
        else {
            return nil
        }

        return TimeInterval(file.length) / file.processingFormat.sampleRate
    }

    private func tempMetadata(
        sessionID: UUID,
        trackKind: String,
        sequenceNumber: Int
    ) async throws -> TempAudioChunkMetadata? {
        let store = FilesystemTempAudioChunkStore(rootDirectory: tempRoot)
        return try await store.metadata(for: TempAudioChunkKey(
            sessionID: sessionID,
            trackKind: trackKind,
            sequenceNumber: sequenceNumber
        ))
    }

    private func trackLabel(for pathComponent: String) -> String {
        switch pathComponent {
        case "microphone":
            "Microphone"
        case "systemAudio":
            "System Audio"
        case "mixed":
            "Mixed Audio"
        default:
            pathComponent
        }
    }

    private static let supportedAudioFileExtensions: Set<String> = [
        "flac",
        "mp3",
        "mp4",
        "mpeg",
        "mpga",
        "m4a",
        "ogg",
        "wav",
        "webm"
    ]
}

enum MeetingContextBuilder {
    struct SurfaceContext: Sendable {
        var summaryGrounding: [String]
        var factExtraction: [String]
        var noteRendering: [String]

        static let empty = SurfaceContext(
            summaryGrounding: [],
            factExtraction: [],
            noteRendering: []
        )
    }

    struct DurableKnowledgeContext: Sendable {
        var surfaces: SurfaceContext
        var matches: [BarnOwlKnowledgeEntityRecord]
    }

    private struct ExternalContextSurfaceContext {
        var summaryGrounding: [String]
        var factExtraction: [String]
        var noteRendering: [String]
    }

    static func context(for session: RecordingSession, contextRoot: URL?) async -> SurfaceContext {
        var summaryGrounding: [String] = []
        var factExtraction: [String] = []
        var noteRendering: [String] = []

        if let calendarContext = await calendarContext(for: session.id) {
            summaryGrounding.append(contentsOf: calendarContext.contextLines)
            factExtraction.append(contentsOf: calendarContext.contextLines)
            noteRendering.append(contentsOf: displayableCalendarContextLines(from: calendarContext))
        }
        let externalContext = await externalContext(for: session.id)
        summaryGrounding.append(contentsOf: externalContext.summaryGrounding)
        factExtraction.append(contentsOf: externalContext.factExtraction)
        noteRendering.append(contentsOf: externalContext.noteRendering)

        _ = contextRoot

        return SurfaceContext(
            summaryGrounding: unique(summaryGrounding),
            factExtraction: unique(factExtraction),
            noteRendering: unique(noteRendering)
        )
    }

    static func factsContext(from context: SurfaceContext) -> String {
        context.factExtraction.joined(separator: "\n")
    }

    static func noteContext(from context: SurfaceContext) -> [String] {
        context.noteRendering
    }

    static func withDurableKnowledge(_ context: SurfaceContext, transcript: String) async -> DurableKnowledgeContext {
        do {
            let database = try BarnOwlDatabase(url: try defaultDatabaseURL())
            let ownerID = BarnOwlEnrichmentSourceOwner.localUserID()
            let matches = try await database.durableKnowledgeMatches(
                ownerID: ownerID,
                transcript: transcript,
                limit: 8
            )
            let durableLines = matches.map(Self.contextLine(for:))
            return DurableKnowledgeContext(
                surfaces: SurfaceContext(
                    summaryGrounding: unique(context.summaryGrounding + durableLines),
                    factExtraction: unique(context.factExtraction + durableLines),
                    noteRendering: context.noteRendering
                ),
                matches: matches
            )
        } catch {
            return DurableKnowledgeContext(surfaces: context, matches: [])
        }
    }

    static func recordDurableKnowledgeApplications(
        _ matches: [BarnOwlKnowledgeEntityRecord],
        ownerID: String,
        meetingID: UUID,
        meetingFacts: MeetingFacts,
        surface: String,
        usedInSummaryGeneration: Bool = false,
        usedInNoteGeneration: Bool = false,
        database: BarnOwlDatabase,
        createdAt: Date
    ) async throws {
        for entity in matches {
            try await database.upsertKnowledgeApplication(BarnOwlKnowledgeApplicationRecord(
                ownerID: ownerID,
                entityID: entity.id,
                meetingID: meetingID,
                surface: surface,
                usedInSummaryGeneration: usedInSummaryGeneration,
                usedInNoteGeneration: usedInNoteGeneration,
                influencedMeetingFacts: entityInfluencedMeetingFacts(entity, meetingFacts: meetingFacts),
                createdAt: createdAt
            ))
        }
    }

    private static func contextLine(for entity: BarnOwlKnowledgeEntityRecord) -> String {
        let summary = entity.summary
            .flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        if let summary {
            return "Known \(entity.kind): \(entity.canonicalName). \(summary)"
        }
        return "Known \(entity.kind): \(entity.canonicalName)."
    }

    private static func entityInfluencedMeetingFacts(
        _ entity: BarnOwlKnowledgeEntityRecord,
        meetingFacts: MeetingFacts
    ) -> Bool {
        let normalizedCanonical = BarnOwlKnowledgeEntityRecord.normalized(entity.canonicalName)
        guard !normalizedCanonical.isEmpty else { return false }

        let searchableValues = [
            meetingFacts.title ?? "",
            meetingFacts.meetingType ?? ""
        ] + meetingFacts.participants
            + meetingFacts.customers
            + meetingFacts.organizations
            + meetingFacts.projects
            + Array(meetingFacts.glossary.keys)
            + Array(meetingFacts.glossary.values)

        return searchableValues.contains {
            BarnOwlKnowledgeEntityRecord.normalized($0).contains(normalizedCanonical)
        }
    }

    private static func externalContext(for meetingID: UUID) async -> ExternalContextSurfaceContext {
        func render(_ source: String, body: String, limit: Int) -> String {
            "External context (\(source)): \(snippet(from: body, maxCharacters: limit))"
        }

        do {
            let database = try BarnOwlDatabase(url: try defaultDatabaseURL())
            let items = try await database.externalContextItems(meetingID: meetingID, state: .accepted, limit: 20)
                .sorted { $0.createdAt < $1.createdAt }
            return ExternalContextSurfaceContext(
                summaryGrounding: items.map { render($0.source, body: $0.body, limit: 2_400) },
                factExtraction: items.map { render($0.source, body: $0.body, limit: 2_400) },
                noteRendering: items.map { render($0.source, body: $0.body, limit: 600) }
            )
        } catch {
            return ExternalContextSurfaceContext(
                summaryGrounding: [],
                factExtraction: [],
                noteRendering: []
            )
        }
    }

    private static func displayableCalendarContextLines(from context: CalendarMeetingContext) -> [String] {
        var lines = ["Calendar event: \(context.title)"]
        if !context.attendees.isEmpty {
            lines.append("Calendar attendees: \(context.attendees.joined(separator: ", "))")
        }
        return lines
    }

    private static func unique(_ lines: [String]) -> [String] {
        var seen: Set<String> = []
        var output: [String] = []
        for line in lines {
            guard let cleaned = MeetingFacts.clean(line) else { continue }
            let key = cleaned
                .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
                .lowercased()
            guard seen.insert(key).inserted else { continue }
            output.append(cleaned)
        }
        return output
    }

    private static func calendarContext(for meetingID: UUID) async -> CalendarMeetingContext? {
        do {
            let database = try BarnOwlDatabase(url: try defaultDatabaseURL())
            guard let record = try await database.meetingCalendarContext(meetingID: meetingID) else {
                return nil
            }

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
        } catch {
            return nil
        }
    }

    private static func defaultDatabaseURL() throws -> URL {
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

    private static func snippet(from body: String, maxCharacters: Int) -> String {
        let normalized = body
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return String(normalized.prefix(max(0, maxCharacters)))
    }
}

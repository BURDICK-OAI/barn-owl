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
}

enum BarnOwlJobType {
    static let finalProcessing = "final_processing"
    static let noteUpdate = "note_update"
    static let indexing = "indexing"
}

struct FinalProcessingJobPayload: Codable, Equatable, Sendable {
    var session: RecordingSession
}

actor BarnOwlJobRunner {
    private let makeDatabase: @Sendable () throws -> BarnOwlDatabase
    private let meetingProcessor: any MeetingProcessing
    private let maxAttempts: Int
    private var isRunning = false

    init(
        makeDatabase: @escaping @Sendable () throws -> BarnOwlDatabase,
        meetingProcessor: any MeetingProcessing,
        maxAttempts: Int = 3
    ) {
        self.makeDatabase = makeDatabase
        self.meetingProcessor = meetingProcessor
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
        } catch {
            let decodedSession = job.payloadJSON
                .flatMap { $0.data(using: .utf8) }
                .flatMap { try? JSONDecoder().decode(FinalProcessingJobPayload.self, from: $0).session }
            let willRetry = job.attemptCount < maxAttempts
            var next = job
            next.status = willRetry ? .pending : .failed
            next.errorMessage = BarnOwlErrorFormatter.message(for: error)
            next.updatedAt = Date()
            next.scheduledAt = willRetry ? Date().addingTimeInterval(Self.backoffDelay(afterAttempt: job.attemptCount)) : nil
            next.completedAt = willRetry ? nil : Date()
            try? await database.upsertJob(next)
            await onFinalProcessingFailed?(decodedSession, error, willRetry)
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
            wrapped: OpenAIMeetingSummaryGeneratorAdapter(
                client: OpenAIMeetingSummaryClient(configuration: configuration)
            ),
            progress: scopedProgress
        )
        let pipeline = FinalTranscriptionPipeline(
            transcriptionClient: transcriptionClient,
            qualityReviewer: TranscriptSanitizingQualityReviewer(),
            summaryGenerator: summaryGenerator,
            overlapRepairClient: OpenAITranscriptOverlapRepairClient(configuration: configuration)
        )
        let context = await MeetingContextBuilder.context(for: session, contextRoot: try? Self.defaultContextRoot())
        let result = try await pipeline.run(session: session, audioFiles: audioFiles, context: context)
        var finalSession = session
        finalSession.title = MeetingTitleSuggester.title(
            currentTitle: session.title,
            summary: result.summary,
            segments: result.segments
        )
        if finalSession.title != session.title {
            await scopedProgress?(MeetingProcessingProgress(
                message: "Labeled meeting as \(finalSession.title).",
                progressFraction: 0.87
            ))
        }
        let transcriptForFacts = result.segments
            .map { "\($0.speakerLabel): \($0.text)" }
            .joined(separator: "\n")
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
            message: "Saving transcript to Barn Owl Library...",
            progressFraction: 0.97
        ))
        let location = try await makeLibraryStore().saveArtifact(artifact)
        await scopedProgress?(MeetingProcessingProgress(
            message: "Writing note back to local context...",
            progressFraction: 0.985
        ))
        try? await LocalMarkdownContextProvider(rootDirectory: try Self.defaultContextRoot())
            .write(ContextArtifact(title: finalSession.title, markdown: markdown))
        await clearRollingTranscriptionCache(
            sessionID: session.id,
            progress: scopedProgress
        )
        await scopedProgress?(MeetingProcessingProgress(
            message: "Saved final transcript.",
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

private enum MeetingTitleSuggester {
    static func title(
        currentTitle: String,
        summary: MeetingSummary,
        segments: [TranscriptSegment]
    ) -> String {
        if let suggested = normalized(summary.suggestedTitle),
           !isGeneric(suggested) {
            return suggested
        }

        if let current = normalized(currentTitle),
           !isGeneric(current) {
            return current
        }

        let candidates = [
            summary.overview,
            summary.decisions.first,
            summary.actionItems.first,
            segments.first { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }?.text
        ].compactMap { $0 }

        for candidate in candidates {
            if let title = titleFromSentence(candidate),
               !isGeneric(title) {
                return title
            }
        }

        return "Meeting Notes"
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

    private static let genericTitles: Set<String> = [
        "meeting",
        "meeting notes",
        "sync",
        "call",
        "discussion",
        "general discussion",
        "untitled meeting"
    ]

    private static let stopWords: Set<String> = [
        "the", "a", "an", "and", "or", "but", "to", "of", "in", "on", "for",
        "with", "from", "about", "that", "this", "these", "those", "we", "they",
        "you", "i", "it", "is", "are", "was", "were", "be", "being", "been",
        "should", "would", "could", "will", "can", "team", "speaker", "discussed",
        "reviewed", "agreed"
    ]
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
                overview: "Transcript saved. Summary generation failed, so Barn Owl kept the diarized transcript and logged the summary error.",
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

private enum MeetingContextBuilder {
    static func context(for session: RecordingSession, contextRoot: URL?) async -> [String] {
        var items: [String] = []

        if let calendarContext = await calendarContext(for: session.id) {
            items.append(contentsOf: calendarContext.contextLines)
        }
        items.append(contentsOf: await externalContext(for: session.id))

        _ = contextRoot

        return items
    }

    static func factsContext(from context: [String]) -> String {
        noteContext(from: context).joined(separator: "\n")
    }

    static func noteContext(from context: [String]) -> [String] {
        context
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .filter { line in
                let lowercased = line
                    .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
                    .lowercased()
                return !lowercased.hasPrefix("meeting title:")
                    && !lowercased.hasPrefix("started:")
                    && !lowercased.hasPrefix("audio sources:")
                    && !lowercased.hasPrefix("local context")
            }
    }

    private static func externalContext(for meetingID: UUID) async -> [String] {
        do {
            let database = try BarnOwlDatabase(url: try defaultDatabaseURL())
            let items = try await database.externalContextItems(meetingID: meetingID, state: .accepted, limit: 20)
                .sorted { $0.createdAt < $1.createdAt }
            return items.map { item in
                "External context (\(item.source)): \(snippet(from: item.body))"
            }
        } catch {
            return []
        }
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

    private static func snippet(from body: String) -> String {
        let normalized = body
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return String(normalized.prefix(600))
    }
}

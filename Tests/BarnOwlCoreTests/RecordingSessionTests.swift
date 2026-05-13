@testable import BarnOwl
import BarnOwlAudio
import BarnOwlCore
import BarnOwlOpenAI
import BarnOwlPersistence
import BarnOwlTranscription
import Darwin
import Foundation
import Testing

@Test
func defaultCaptureIncludesMicAndSystemAudio() {
    let configuration = AudioSourceConfiguration.defaultMeetingCapture

    #expect(configuration.capturesMicrophone)
    #expect(configuration.capturesSystemAudio)
}

@Test
func finishingSessionSetsEndDateWithoutChangingIdentity() {
    let session = RecordingSession(
        id: .init(uuidString: "00000000-0000-0000-0000-000000000001")!,
        title: "Design Review",
        startedAt: .init(timeIntervalSince1970: 10),
        audioSources: .defaultMeetingCapture
    )

    let finished = session.finished(at: .init(timeIntervalSince1970: 20))

    #expect(finished.id == session.id)
    #expect(finished.endedAt == .init(timeIntervalSince1970: 20))
}

@Test
func permissionReadinessRequiresEnabledSourcesOnly() {
    let permissions = RecordingPermissionSet(
        microphone: .init(kind: .microphone, decision: .granted),
        systemAudio: .init(kind: .systemAudioScreenCapture, decision: .denied)
    )

    #expect(!permissions.isReady(for: .defaultMeetingCapture))
    #expect(
        permissions.missingRequiredPermissions(for: .defaultMeetingCapture)
            == [.systemAudioScreenCapture]
    )

    let micOnlyConfiguration = AudioSourceConfiguration(
        capturesMicrophone: true,
        capturesSystemAudio: false
    )

    #expect(permissions.isReady(for: micOnlyConfiguration))
}

@Test
func stateMachineRejectsDoubleStartWithActiveSessionIdentity() {
    var machine = RecordingStateMachine()
    let session = RecordingSession(
        id: .init(uuidString: "00000000-0000-0000-0000-000000000002")!,
        title: "Planning",
        startedAt: .init(timeIntervalSince1970: 30),
        audioSources: .defaultMeetingCapture
    )

    let firstStart = machine.beginStart(
        session: session,
        permissions: .grantedForDefaultMeetingCapture
    )
    let secondStart = machine.beginStart(
        session: session,
        permissions: .grantedForDefaultMeetingCapture
    )

    #expect(
        firstStart == RecordingTransitionResult.accepted(
            RecordingLifecycleState.preparing(session)
        )
    )

    guard case .rejected(let failure) = secondStart else {
        Issue.record("Expected second start to be rejected.")
        return
    }

    #expect(failure.reason == RecordingFailureReason.alreadyRecording)
    #expect(failure.sessionID == session.id)
    #expect(machine.state == RecordingLifecycleState.preparing(session))
    #expect(machine.status == RecordingStatus.preparing)
}

@Test
func stateMachineRejectsDoubleStopWithoutLosingFinishedSession() {
    var machine = RecordingStateMachine()
    let session = RecordingSession(
        id: .init(uuidString: "00000000-0000-0000-0000-000000000003")!,
        title: "Customer Call",
        startedAt: .init(timeIntervalSince1970: 40),
        audioSources: .defaultMeetingCapture
    )
    let stoppedAt = Date(timeIntervalSince1970: 55)
    let finishedSession = session.finished(at: stoppedAt)

    machine.beginStart(session: session, permissions: .grantedForDefaultMeetingCapture)
    machine.markRecording()

    let firstStop = machine.beginStop(at: stoppedAt)
    let secondStop = machine.beginStop(at: Date(timeIntervalSince1970: 60))

    #expect(
        firstStop == RecordingTransitionResult.accepted(
            RecordingLifecycleState.stopping(finishedSession)
        )
    )

    guard case .rejected(let failure) = secondStop else {
        Issue.record("Expected second stop to be rejected.")
        return
    }

    #expect(failure.reason == RecordingFailureReason.alreadyStopping)
    #expect(failure.sessionID == session.id)
    #expect(machine.state == RecordingLifecycleState.stopping(finishedSession))
    #expect(machine.status == RecordingStatus.processing)
}

@Test
func stateMachineCanSettleCompletedRecordingBackToIdle() {
    var machine = RecordingStateMachine()
    let session = RecordingSession(
        id: .init(uuidString: "00000000-0000-0000-0000-000000000033")!,
        title: "Completed Meeting",
        startedAt: .init(timeIntervalSince1970: 90),
        audioSources: .defaultMeetingCapture
    )

    machine.beginStart(session: session, permissions: .grantedForDefaultMeetingCapture)
    machine.markRecording()
    machine.beginStop(at: Date(timeIntervalSince1970: 120))
    machine.beginProcessing()
    machine.complete()

    #expect(machine.state == .completed(session.finished(at: Date(timeIntervalSince1970: 120))))
    #expect(machine.state.activeSession?.id == session.id)

    machine.resetToIdle()

    #expect(machine.status == .idle)
    #expect(machine.state.activeSession == nil)
}

@Test
func stateMachineRejectsStartWhenPermissionsAreNotReady() {
    var machine = RecordingStateMachine()
    let session = RecordingSession(
        id: .init(uuidString: "00000000-0000-0000-0000-000000000004")!,
        title: "Interview",
        startedAt: .init(timeIntervalSince1970: 70),
        audioSources: .defaultMeetingCapture
    )
    let permissions = RecordingPermissionSet(
        microphone: .init(kind: .microphone, decision: .granted),
        systemAudio: .init(kind: .systemAudioScreenCapture, decision: .notDetermined)
    )

    let result = machine.beginStart(session: session, permissions: permissions)

    guard case .rejected(let failure) = result else {
        Issue.record("Expected start to be rejected when system capture is not ready.")
        return
    }

    #expect(failure.reason == RecordingFailureReason.permissionsNotReady)
    #expect(failure.sessionID == session.id)
    #expect(failure.missingPermissions == [.systemAudioScreenCapture])
    #expect(machine.state == RecordingLifecycleState.idle)
}

@Test
@MainActor
func appModelExtractsFirstNonEmptyTopLevelMarkdownTitle() {
    let markdown = """
    ## Summary
    Not a title.

    #   Customer Launch Review   

    # Later Title
    """

    #expect(BarnOwlAppModel.topLevelMarkdownTitle(in: markdown) == "Customer Launch Review")
    #expect(BarnOwlAppModel.topLevelMarkdownTitle(in: "## Only Subheading") == nil)
    #expect(BarnOwlAppModel.topLevelMarkdownTitle(in: "#   \n\nBody") == nil)
}

@Test
@MainActor
func appModelActivityVisibilityAppliesTTLAndMenuLimit() {
    let now = Date(timeIntervalSince1970: 1_000)
    let items = [
        makeActivityItem(message: "newest", timestamp: now),
        makeActivityItem(message: "fresh 2", timestamp: now.addingTimeInterval(-30)),
        makeActivityItem(message: "fresh 3", timestamp: now.addingTimeInterval(-60)),
        makeActivityItem(message: "fresh 4", timestamp: now.addingTimeInterval(-90)),
        makeActivityItem(message: "fresh 5 hidden by menu limit", timestamp: now.addingTimeInterval(-120)),
        makeActivityItem(
            message: "expired",
            timestamp: now.addingTimeInterval(-BarnOwlAppModel.activityVisibilityWindow - 1)
        )
    ]

    let visible = BarnOwlAppModel.visibleActivityItems(items, now: now)

    #expect(visible.map(\.message) == ["newest", "fresh 2", "fresh 3", "fresh 4"])
}

@Test
@MainActor
func appModelFormatsElapsedRecordingTimeForMenuAndHeader() {
    #expect(BarnOwlAppModel.formatElapsedDuration(0) == "00:00")
    #expect(BarnOwlAppModel.formatElapsedDuration(9.9) == "00:09")
    #expect(BarnOwlAppModel.formatElapsedDuration(65) == "01:05")
    #expect(BarnOwlAppModel.formatElapsedDuration(3_665) == "1:01:05")
}

@Test
@MainActor
func appModelComputesAudioActivityLevelFromPCM16Data() {
    let silence = Data([0, 0, 0, 0])
    #expect(BarnOwlAppModel.audioActivityLevel(forPCM16Data: silence) == 0.04)

    var samples = [Int16(0), Int16(12_000), Int16(-12_000), Int16(0)]
    let data = Data(bytes: &samples, count: samples.count * MemoryLayout<Int16>.size)
    let level = BarnOwlAppModel.audioActivityLevel(forPCM16Data: data)

    #expect(level > 0.04)
    #expect(level <= 1)
}

@Test
@MainActor
func appModelBuildsFinalRecordedAudioFileFromCaptureProgress() {
    let sessionID = UUID()
    let url = URL(fileURLWithPath: "/tmp/0.wav")
    let progress = AudioCaptureProgress(
        trackKind: .microphone,
        sequenceNumber: 0,
        fileURL: url,
        startTimeOffset: 55,
        duration: 60,
        chunkDuration: 60,
        overlapDuration: 5,
        strideDuration: 55,
        byteCount: 10,
        errorMessage: nil
    )

    let audioFile = BarnOwlAppModel.recordedAudioFile(from: progress, sessionID: sessionID)

    #expect(audioFile?.url == url)
    #expect(audioFile?.trackID == "microphone")
    #expect(audioFile?.trackLabel == "Microphone")
    #expect(audioFile?.sequenceNumber == 0)
    #expect(audioFile?.startTimeOffset == 55)
    #expect(audioFile?.duration == 60)
    #expect(audioFile?.overlapDuration == 5)
}

@Test
func tempAudioRecordedFileProviderUsesExplicitOverlapTimingMetadata() async throws {
    let tempRoot = FileManager.default.temporaryDirectory
        .appending(path: "BarnOwlProviderTimingTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: tempRoot) }

    let sessionID = UUID(uuidString: "00000000-0000-0000-0000-000000000041")!
    let session = RecordingSession(
        id: sessionID,
        title: "Provider Timing",
        startedAt: Date(timeIntervalSince1970: 100),
        audioSources: .defaultMeetingCapture
    )
    let store = FilesystemTempAudioChunkStore(rootDirectory: tempRoot)

    for (sequenceNumber, startOffset) in [(0, TimeInterval(0)), (1, TimeInterval(55))] {
        let reservation = try await store.reserveChunk(
            sessionID: sessionID,
            trackKind: "microphone",
            sequenceNumber: sequenceNumber,
            fileExtension: "wav"
        )
        try Data([UInt8(sequenceNumber + 1)]).write(to: reservation.audioFileURL)
        _ = try await store.markWritten(
            reservation,
            timingMetadata: TempAudioChunkTimingMetadata(
                startTimeOffset: startOffset,
                duration: 60,
                chunkDuration: 60,
                overlapDuration: 5,
                strideDuration: 55
            )
        )
    }

    let files = try await TempAudioRecordedFileProvider(tempRoot: tempRoot)
        .audioFiles(for: session)

    #expect(files.map(\.sequenceNumber) == [0, 1])
    #expect(files.map(\.startTimeOffset) == [0, 55])
    #expect(files.map { $0.duration ?? -1 } == [60, 60])
    #expect(files.map { $0.overlapDuration ?? -1 } == [5, 5])
}

@Test
@MainActor
func appModelDoesNotBuildFinalAudioFileForFailedCaptureProgress() {
    let progress = AudioCaptureProgress(
        trackKind: .microphone,
        sequenceNumber: nil,
        fileURL: nil,
        startTimeOffset: nil,
        duration: 0,
        chunkDuration: nil,
        overlapDuration: nil,
        strideDuration: nil,
        byteCount: nil,
        errorMessage: "write failed"
    )

    #expect(BarnOwlAppModel.recordedAudioFile(from: progress, sessionID: UUID()) == nil)
}

@Test
@MainActor
func menuBarTranscriptPreviewShowsNewestLines() {
    let preview = """
    first
    second
    third
    fourth
    fifth
    """

    #expect(MenuBarView.transcriptPreviewLines(in: preview, status: .recording) == [
        "second",
        "third",
        "fourth",
        "fifth"
    ])
}

@Test
@MainActor
func menuBarTranscriptPreviewUsesRecordingPlaceholderWhenEmpty() {
    #expect(MenuBarView.transcriptPreviewLines(in: "Ready.", status: .recording) == ["Listening for speech..."])
    #expect(MenuBarView.transcriptPreviewLines(in: "Ready.", status: .idle) == ["Ready to listen."])
}

@Test
func lifecyclePresentationDistinguishesStoppingProcessingAndComplete() {
    let session = RecordingSession(
        id: .init(uuidString: "00000000-0000-0000-0000-000000000031")!,
        title: "Design Review",
        startedAt: .init(timeIntervalSince1970: 100),
        audioSources: .defaultMeetingCapture
    )

    let stopping = BarnOwlLifecyclePresentation.make(
        state: .stopping(session),
        hasActiveProcessing: false,
        hasDisplayedNote: false
    )
    #expect(stopping.phase == .stopping)
    #expect(stopping.title == "Stopping")
    #expect(BarnOwlLifecyclePresentation.primaryActionTitle(for: .stopping(session)) == "Stopping...")

    let processing = BarnOwlLifecyclePresentation.make(
        state: .processing(session),
        hasActiveProcessing: true,
        hasDisplayedNote: false
    )
    #expect(processing.phase == .processing)
    #expect(processing.detail.contains("final transcript"))

    let complete = BarnOwlLifecyclePresentation.make(
        state: .completed(session),
        hasActiveProcessing: false,
        hasDisplayedNote: true
    )
    #expect(complete.phase == .complete)
    #expect(complete.title == "Complete")

    let collapsedTimeline = [
        BarnOwlProcessingTimelineItem(step: .recorded, status: .complete),
        BarnOwlProcessingTimelineItem(step: .transcribing, status: .complete),
        BarnOwlProcessingTimelineItem(step: .complete, status: .complete)
    ]
    #expect(!BarnOwlAppModel.hasActiveProcessing(collapsedTimeline))
}

@Test
func recorderWorkspaceKeepsLivePreviewSeparateFromFinalTranscript() {
    #expect(
        RecorderWorkspacePresentation.finalTranscriptPlaceholder(
            status: .recording,
            hasProcessingTimeline: false
        )
        .contains("Live preview stays on the Realtime Preview tab")
    )
    #expect(
        RecorderWorkspacePresentation.finalTranscriptPlaceholder(
            status: .idle,
            hasProcessingTimeline: true
        )
        .contains("still processing")
    )
    #expect(
        RecorderWorkspacePresentation.finalTranscriptPlaceholder(
            status: .idle,
            hasProcessingTimeline: false
        )
        == "No final transcript is available for this note yet."
    )
}

@Test
func errorFormatterRedactsSecretsPathsAndOpenAIResponseBodies() {
    let raw = "failed with sk-proj-secret123 at /Users/alex/Library/Application Support/Barn Owl/file.wav"
    let sanitized = BarnOwlErrorFormatter.sanitizeForUserDisplay(raw)

    #expect(!sanitized.contains("sk-proj-secret123"))
    #expect(!sanitized.contains("/Users/alex"))
    #expect(sanitized.contains("[redacted API key]"))
    #expect(sanitized.contains("[redacted local path]"))

    let error = OpenAIResponsesClientError.summaryPayloadDecodingFailed(
        "bad json",
        "Transcript excerpt that should never be shown in an error"
    )
    #expect(!BarnOwlErrorFormatter.message(for: error).contains("Transcript excerpt"))
}

@Test
func errorFormatterUsesLocalizedErrorDescriptions() {
    struct FriendlyError: LocalizedError {
        var errorDescription: String? {
            "Open System Settings and allow microphone access."
        }
    }

    #expect(
        BarnOwlErrorFormatter.message(for: FriendlyError())
        == "Open System Settings and allow microphone access."
    )
}

@Test
func errorFormatterMapsAudioCapturePermissionErrorsToActionableCopy() {
    let message = BarnOwlErrorFormatter.message(for: AudioCaptureError.permissionDenied)

    #expect(message.contains("Microphone"))
    #expect(message.contains("Screen/System Audio Recording"))
    #expect(!message.contains("permissionDenied"))
}

@Test
func developerDiagnosticsExportRedactsSecretsPathsAndOmitsDetails() {
    let entry = DiagnosticsLogEntry(
        timestamp: Date(timeIntervalSince1970: 1_800_000_000),
        level: .error,
        sessionID: UUID(uuidString: "00000000-0000-0000-0000-000000000123"),
        category: "capture",
        message: "Failed with sk-proj-secret123 at /Users/alex/Library/Application Support/Barn Owl/raw.wav",
        details: "Potential meeting transcript excerpt and Authorization: Bearer abcdefghijk"
    )
    let snapshot = BarnOwlDeveloperDiagnosticsSnapshot(
        generatedAt: Date(timeIntervalSince1970: 1_800_000_010),
        appVersion: "1.2.3",
        appBuild: "45",
        bundleIdentifier: "com.barnowl.mac",
        operatingSystem: "macOS Test",
        architecture: "arm64",
        updateChannel: "Custom update feed",
        updateManifest: "/Users/alex/Library/Application Support/Barn Owl/update-manifest.json",
        readinessLines: [
            "local_file_path=/Users/alex/Library/Application Support/Barn Owl/openai_api_key",
            "environment_configured=false"
        ],
        diagnosticsEntries: [entry]
    )

    let report = BarnOwlDeveloperDiagnosticsExporter.makeReport(snapshot)

    #expect(report.contains("Barn Owl Developer Diagnostics"))
    #expect(report.contains("details_present=true"))
    #expect(!report.contains("sk-proj-secret123"))
    #expect(!report.contains("Authorization: Bearer abcdefghijk"))
    #expect(!report.contains("/Users/alex"))
    #expect(!report.contains("Potential meeting transcript excerpt"))
}

@Test
@MainActor
func controlResponsesRedactUserVisibleErrorFields() async throws {
    let database = try BarnOwlDatabase.inMemory()
    let model = try makeQuickCommandTestModel(database: database)
    let raw = "failed with sk-proj-secret123 at /Users/alex/Library/Application Support/Barn Owl/raw.wav"

    model.lastError = raw
    model.captureStatus = raw
    model.realtimeStatus = raw
    let response = model.controlStatusResponse(
        ok: false,
        message: "Failed.",
        error: raw
    )

    #expect(response.lastError?.contains("sk-proj-secret123") == false)
    #expect(response.captureStatus?.contains("/Users/alex") == false)
    #expect(response.realtimeStatus?.contains("[redacted local path]") == true)
    #expect(response.error?.contains("[redacted API key]") == true)

    try await database.upsertJob(BarnOwlJobRecord(
        type: "final_processing",
        status: .failed,
        errorMessage: raw
    ))
    let jobsResponse = await model.controlJobsListResponse()
    let jobError = try #require(jobsResponse.jobs?.first?.errorMessage)

    #expect(!jobError.contains("sk-proj-secret123"))
    #expect(!jobError.contains("/Users/alex"))
    #expect(jobError.contains("[redacted API key]"))
    #expect(jobError.contains("[redacted local path]"))
}

@Test
func controlResponseSuggestsSlackFeedbackOnlyForNonOwnerErrors() {
    #expect(BarnOwlAppModel.shouldSuggestSlackFeedback(
        ok: false,
        errorCode: "transcription_failed",
        error: "Transcription failed.",
        lastError: nil,
        jobState: nil,
        currentUsername: "teammate",
        ownerUsername: "burdick"
    ))

    #expect(BarnOwlAppModel.slackFeedbackDraftCommand == "barnowl feedback slack")
    #expect(BarnOwlAppModel.slackFeedbackPostCommand == "barnowl feedback slack --yes")

    #expect(!BarnOwlAppModel.shouldSuggestSlackFeedback(
        ok: false,
        errorCode: "transcription_failed",
        error: "Transcription failed.",
        lastError: nil,
        jobState: nil,
        currentUsername: "burdick",
        ownerUsername: "burdick"
    ))

    #expect(!BarnOwlAppModel.shouldSuggestSlackFeedback(
        ok: true,
        errorCode: nil,
        error: nil,
        lastError: nil,
        jobState: "complete",
        currentUsername: "teammate",
        ownerUsername: "burdick"
    ))

    #expect(!BarnOwlAppModel.shouldSuggestSlackFeedback(
        ok: false,
        errorCode: "confirmation_required",
        error: "Pass --yes to confirm.",
        lastError: nil,
        jobState: nil,
        currentUsername: "teammate",
        ownerUsername: "burdick"
    ))
}

@Test
func controlBridgeTokenStoreCreatesStablePrivateToken() throws {
    let root = FileManager.default.temporaryDirectory
        .appending(path: "BarnOwlControlBridgeTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }
    let tokenURL = root.appending(path: "control-bridge-token", directoryHint: .notDirectory)
    let store = BarnOwlControlBridgeTokenStore(tokenFileURL: tokenURL)

    let firstToken = try store.loadOrCreateToken()
    let secondToken = try store.loadOrCreateToken()
    let attributes = try FileManager.default.attributesOfItem(atPath: tokenURL.path(percentEncoded: false))
    let directoryAttributes = try FileManager.default.attributesOfItem(atPath: root.path(percentEncoded: false))

    #expect(firstToken == secondToken)
    #expect(firstToken.count >= 32)
    #expect((attributes[.posixPermissions] as? Int ?? 0) & 0o777 == 0o600)
    #expect((directoryAttributes[.posixPermissions] as? Int ?? 0) & 0o777 == 0o700)
}

@Test
func controlBridgeCreatesTokenBeforeFirstPOSTCommand() async throws {
    let database = try BarnOwlDatabase.inMemory()
    let model = try await MainActor.run {
        try makeQuickCommandTestModel(database: database)
    }
    let port = try unusedLocalPort()
    let root = FileManager.default.temporaryDirectory
        .appending(path: "BarnOwlControlBridgeTokenPreflightTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }
    let tokenURL = root.appending(path: "control-bridge-token", directoryHint: .notDirectory)
    let tokenStore = BarnOwlControlBridgeTokenStore(tokenFileURL: tokenURL)
    let bridge = BarnOwlControlBridge(
        model: model,
        port: port,
        tokenStore: tokenStore,
        openCurrentMeeting: {}
    )
    bridge.start()
    defer { bridge.stop() }

    try await waitForBridge(port: port)

    let token = try String(contentsOf: tokenURL, encoding: .utf8)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    let body = #"{"command":"get_status"}"#
    let authorized = try sendLocalHTTPRequest(
        port: port,
        request: postBridgeRequest(body: body, bearerToken: token)
    )

    #expect(!token.isEmpty)
    #expect(authorized.contains(#""ok":true"#))
    #expect(!authorized.contains(#""error":"unauthorized""#))
}

@Test
func controlBridgeRequiresBearerTokenForPOSTCommands() async throws {
    let database = try BarnOwlDatabase.inMemory()
    let model = try await MainActor.run {
        try makeQuickCommandTestModel(database: database)
    }
    let port = try unusedLocalPort()
    let root = FileManager.default.temporaryDirectory
        .appending(path: "BarnOwlControlBridgeHTTPTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }
    let tokenStore = BarnOwlControlBridgeTokenStore(
        tokenFileURL: root.appending(path: "control-bridge-token", directoryHint: .notDirectory)
    )
    let token = try tokenStore.loadOrCreateToken()
    let bridge = BarnOwlControlBridge(
        model: model,
        port: port,
        tokenStore: tokenStore,
        openCurrentMeeting: {}
    )
    bridge.start()
    defer { bridge.stop() }

    try await waitForBridge(port: port)

    let body = #"{"command":"get_status"}"#
    let unauthorized = try sendLocalHTTPRequest(
        port: port,
        request: postBridgeRequest(body: body)
    )
    let authorized = try sendLocalHTTPRequest(
        port: port,
        request: postBridgeRequest(body: body, bearerToken: token)
    )

    #expect(unauthorized.contains(#""ok":false"#))
    #expect(unauthorized.contains(#""error":"unauthorized""#))
    #expect(authorized.contains(#""ok":true"#))
    #expect(!authorized.contains(#""error":"unauthorized""#))
}

@Test
@MainActor
func realtimePreviewAppendingReplacesRepeatedSettledText() {
    let first = BarnOwlAppModel.realtimePreviewAppending(
        "Ok",
        to: "Ready.",
        characterLimit: 1_200
    )
    let duplicate = BarnOwlAppModel.realtimePreviewAppending(
        "Ok",
        to: first,
        characterLimit: 1_200
    )
    let extended = BarnOwlAppModel.realtimePreviewAppending(
        "Ok, are you recording?",
        to: duplicate,
        characterLimit: 1_200
    )
    let next = BarnOwlAppModel.realtimePreviewAppending(
        "Yes, realtime is working.",
        to: extended,
        characterLimit: 1_200
    )

    #expect(first == "Ok")
    #expect(duplicate == "Ok")
    #expect(extended == "Ok, are you recording?")
    #expect(next == "Ok, are you recording?\n\nYes, realtime is working.")
}

@Test
func actionUXExplainsUnavailablePromptActions() {
    #expect(BarnOwlActionUX.notePromptDisabledReason(
        hasOpenNote: false,
        isUpdating: false,
        prompt: "tighten this"
    ) == "Open a note before updating.")
    #expect(BarnOwlActionUX.notePromptDisabledReason(
        hasOpenNote: true,
        isUpdating: true,
        prompt: "tighten this"
    ) == "Updating notes...")
    #expect(BarnOwlActionUX.notePromptDisabledReason(
        hasOpenNote: true,
        isUpdating: false,
        prompt: "   "
    ) == "Type a prompt to update this note.")
    #expect(BarnOwlActionUX.notePromptDisabledReason(
        hasOpenNote: true,
        isUpdating: false,
        prompt: "extract action items"
    ) == nil)
}

@Test
func actionUXExplainsChatAndContextDisabledStates() {
    #expect(BarnOwlActionUX.chatDisabledReason(isSending: true, draft: "status?") == "Barn Owl is thinking...")
    #expect(BarnOwlActionUX.chatDisabledReason(isSending: false, draft: " ") == "Type a question to chat.")
    #expect(BarnOwlActionUX.chatDisabledReason(isSending: false, draft: "What did we decide?") == nil)

    #expect(BarnOwlActionUX.contextDisabledReason(
        hasTarget: false,
        isUpdating: false,
        context: "Dana was there"
    ) == "Open or record a meeting before adding context.")
    #expect(BarnOwlActionUX.contextDisabledReason(
        hasTarget: true,
        isUpdating: true,
        context: "Dana was there"
    ) == "Reading context...")
    #expect(BarnOwlActionUX.contextDisabledReason(
        hasTarget: true,
        isUpdating: false,
        context: ""
    ) == "Add context before attaching it.")
}

@Test
func actionUXMapsJobStateLabels() {
    #expect(BarnOwlActionUX.jobStatusLabel(.pending) == "queued")
    #expect(BarnOwlActionUX.jobStatusLabel(.running) == "running")
    #expect(BarnOwlActionUX.jobStatusLabel(.failed) == "failed")
    #expect(BarnOwlActionUX.jobStatusLabel(.succeeded) == "complete")
}

@Test
func menuBarPresentationKeepsIdleSetupCompact() {
    #expect(!BarnOwlMenuBarPresentation.shouldShowWaveform(
        status: .idle,
        progressFraction: nil,
        processingTimelineItems: []
    ))
    #expect(!BarnOwlMenuBarPresentation.shouldShowTranscriptCard(
        status: .idle,
        liveTranscriptPreview: "Ready."
    ))
    #expect(!BarnOwlMenuBarPresentation.shouldShowStatusAndProgressCard(
        status: .idle,
        captureStatus: "Idle.",
        realtimeStatus: "Realtime transcription idle.",
        progressFraction: nil,
        isUpdateInFlight: false,
        updateStatus: "Updater idle.",
        hasProcessingTimeline: false,
        hasPerformanceSummary: false,
        hasVisibleActivity: false
    ))
    #expect(!BarnOwlMenuBarPresentation.shouldShowSessionsCard(
        quickAccessCount: 0,
        status: .idle,
        setupNeeded: true
    ))
    #expect(!BarnOwlMenuBarPresentation.shouldShowOpenLatestButton(quickAccessCount: 0, status: .idle))
    #expect(!BarnOwlMenuBarPresentation.shouldShowOpenLibraryButton(quickAccessCount: 0, status: .idle))
    #expect(BarnOwlMenuBarPresentation.shouldShowUpdateButton(
        status: .idle,
        isUpdateInFlight: false,
        updateStatus: "Updater idle."
    ))
    #expect(!BarnOwlMenuBarPresentation.shouldShowUpdateButton(
        status: .recording,
        isUpdateInFlight: false,
        updateStatus: "Updater idle."
    ))
}

@Test
func updateAvailabilityButtonTitlesMatchMenuBarPolicy() {
    #expect(BarnOwlUpdateAvailability.unknown.buttonTitle == "Update Unavailable")
    #expect(!BarnOwlUpdateAvailability.unknown.hasInstallableUpdate)
    #expect(BarnOwlUpdateAvailability.upToDate(version: "0.1.0", build: "8").buttonTitle == "Up to Date")
    #expect(!BarnOwlUpdateAvailability.upToDate(version: "0.1.0", build: "8").hasInstallableUpdate)

    let available = BarnOwlUpdateAvailability.available(BarnOwlAvailableUpdate(version: "0.1.0", build: "9", notes: nil))
    #expect(available.buttonTitle == "Update Available")
    #expect(available.hasInstallableUpdate)
}

@Test
@MainActor
func updaterSettingsAlwaysUseCanonicalGitHubFeed() throws {
    UserDefaults.standard.set(
        "/Users/tester/Library/Application Support/Barn Owl/update-manifest.json",
        forKey: BarnOwlUpdaterSettings.manifestURLDefaultsKey
    )
    defer {
        UserDefaults.standard.removeObject(forKey: BarnOwlUpdaterSettings.manifestURLDefaultsKey)
    }

    let resolvedURL = try BarnOwlUpdaterSettings.resolvedManifestURL()

    #expect(resolvedURL.absoluteString == BarnOwlUpdaterSettings.defaultGitManifestURLString)
    #expect(BarnOwlUpdaterSettings.resolvedManifestDisplayPath() == BarnOwlUpdaterSettings.defaultGitManifestURLString)
    #expect(BarnOwlUpdaterSettings.updateChannelLabel == "GitHub update feed")
}

@Test
func menuBarSetupIncludesRequiredPermissionChecks() {
    let snapshot = BarnOwlReadinessSnapshot(checks: [
        BarnOwlReadinessCheck(id: .apiKey, title: "API Key", detail: "", systemImage: "key", state: .ready),
        BarnOwlReadinessCheck(id: .microphone, title: "Microphone", detail: "", systemImage: "mic", state: .missing),
        BarnOwlReadinessCheck(id: .systemAudio, title: "System Audio", detail: "", systemImage: "speaker", state: .missing),
        BarnOwlReadinessCheck(id: .testRecording, title: "Test", detail: "", systemImage: "waveform", state: .warning),
        BarnOwlReadinessCheck(id: .storage, title: "Storage", detail: "", systemImage: "externaldrive", state: .ready),
        BarnOwlReadinessCheck(id: .updateChannel, title: "Updates", detail: "", systemImage: "arrow.down.app", state: .warning)
    ])

    #expect(!snapshot.criticalReady)
    #expect(snapshot.menuBarSetupNeeded)
}

@Test
@MainActor
func menuBarSetupIgnoresOptionalReadinessWarnings() {
    let snapshot = BarnOwlFirstRunReadiness.snapshot(
        apiKeyConfigured: true,
        apiKeyVerified: true,
        microphoneDecision: .granted,
        systemAudioDecision: .granted,
        testRecordingSucceeded: false,
        storageAvailable: true,
        storagePath: "/tmp/Barn Owl Library",
        updateChannelConfigured: false
    )

    #expect(snapshot.criticalReady)
    #expect(!snapshot.menuBarSetupNeeded)
    #expect(snapshot.summary == "Recording is ready. A couple of optional setup checks can still be finished.")
}

@Test
func menuBarProcessingTimelineDoesNotDrivePopoverChrome() {
    let runningTimeline = [
        BarnOwlProcessingTimelineItem(step: .recorded, status: .complete),
        BarnOwlProcessingTimelineItem(step: .transcribing, status: .running)
    ]

    #expect(!BarnOwlMenuBarPresentation.shouldShowWaveform(
        status: .idle,
        progressFraction: nil,
        processingTimelineItems: runningTimeline
    ))
    #expect(!BarnOwlMenuBarPresentation.shouldShowStatusAndProgressCard(
        status: .idle,
        captureStatus: "Transcribing...",
        realtimeStatus: "Realtime transcription idle.",
        progressFraction: nil,
        isUpdateInFlight: false,
        updateStatus: "Updater idle.",
        hasProcessingTimeline: true,
        hasPerformanceSummary: false,
        hasVisibleActivity: false
    ))
}

@Test
@MainActor
func quickAccessSessionsAreTheLatestTwoByActualRecency() {
    let now = Date(timeIntervalSince1970: 10_000)
    let staleFailed = BarnOwlRecentSession(
        id: UUID(),
        title: "Old failed session",
        startedAt: now.addingTimeInterval(-86_400),
        markdownURL: URL(fileURLWithPath: "/tmp/old.md"),
        overview: "Old",
        processingTimeline: [.init(step: .transcribing, status: .failed)]
    )
    let newest = BarnOwlRecentSession(
        id: UUID(),
        title: "Newest",
        startedAt: now.addingTimeInterval(-60),
        markdownURL: URL(fileURLWithPath: "/tmp/newest.md"),
        overview: "Newest"
    )
    let secondNewest = BarnOwlRecentSession(
        id: UUID(),
        title: "Second newest",
        startedAt: now.addingTimeInterval(-120),
        markdownURL: URL(fileURLWithPath: "/tmp/second.md"),
        overview: "Second"
    )
    let thirdNewest = BarnOwlRecentSession(
        id: UUID(),
        title: "Third newest",
        startedAt: now.addingTimeInterval(-180),
        markdownURL: URL(fileURLWithPath: "/tmp/third.md"),
        overview: "Third"
    )

    let quickAccess = BarnOwlAppModel.quickAccessSessions(
        [staleFailed, thirdNewest, newest, secondNewest],
        now: now
    )

    #expect(quickAccess.map(\.id) == [newest.id, secondNewest.id])
}

@Test
func menuBarPresentationShowsRecordingAndProcessingState() {
    #expect(BarnOwlMenuBarPresentation.shouldShowWaveform(
        status: .recording,
        progressFraction: nil,
        processingTimelineItems: []
    ))
    #expect(BarnOwlMenuBarPresentation.shouldShowTranscriptCard(
        status: .recording,
        liveTranscriptPreview: "Listening for speech..."
    ))
    #expect(BarnOwlMenuBarPresentation.shouldShowStatusAndProgressCard(
        status: .recording,
        captureStatus: "Recording microphone and system audio",
        realtimeStatus: "Realtime transcription connected.",
        progressFraction: nil,
        isUpdateInFlight: false,
        updateStatus: "Updater idle.",
        hasProcessingTimeline: false,
        hasPerformanceSummary: false,
        hasVisibleActivity: true
    ))
    #expect(BarnOwlMenuBarPresentation.shouldShowSessionsCard(
        quickAccessCount: 0,
        status: .processing,
        setupNeeded: false
    ))
    #expect(BarnOwlMenuBarPresentation.shouldShowOpenLatestButton(quickAccessCount: 1, status: .idle))
    #expect(BarnOwlMenuBarPresentation.shouldShowOpenLibraryButton(quickAccessCount: 1, status: .idle))
    #expect(BarnOwlMenuBarPresentation.shouldShowUpdateButton(
        status: .idle,
        isUpdateInFlight: true,
        updateStatus: "Checking local development manifest..."
    ))
}

@Test
func updaterAllowsAdHocSignaturesOnlyForLocalDevelopmentFeeds() throws {
    try BarnOwlUpdater.validateSignaturePolicy(
        BarnOwlUpdateSignatureSummary(
            hasValidSignature: true,
            isAdHoc: true,
            teamIdentifier: nil
        ),
        requiresTrustedSignature: false
    )

    #expect(throws: BarnOwlUpdateError.untrustedArchiveSignature) {
        try BarnOwlUpdater.validateSignaturePolicy(
            BarnOwlUpdateSignatureSummary(
                hasValidSignature: true,
                isAdHoc: true,
                teamIdentifier: nil
            ),
            requiresTrustedSignature: true
        )
    }
}

@Test
func updaterRequiresRemoteUpdatesToHaveDeveloperTeamIdentity() throws {
    #expect(throws: BarnOwlUpdateError.untrustedArchiveSignature) {
        try BarnOwlUpdater.validateSignaturePolicy(
            BarnOwlUpdateSignatureSummary(
                hasValidSignature: true,
                isAdHoc: false,
                teamIdentifier: nil
            ),
            requiresTrustedSignature: true
        )
    }

    #expect(throws: BarnOwlUpdateError.untrustedArchiveSignature) {
        try BarnOwlUpdater.validateSignaturePolicy(
            BarnOwlUpdateSignatureSummary(
                hasValidSignature: true,
                isAdHoc: false,
                teamIdentifier: "ABCDE12345",
                authorityNames: ["Apple Development: Example (ABCDE12345)"]
            ),
            requiresTrustedSignature: true
        )
    }
}

@Test
func updaterRequiresRemoteUpdatesToUseDeveloperIDApplicationAuthority() throws {
    try BarnOwlUpdater.validateSignaturePolicy(
        BarnOwlUpdateSignatureSummary(
            hasValidSignature: true,
            isAdHoc: false,
            teamIdentifier: "ABCDE12345",
            authorityNames: ["Developer ID Application: Example, Inc. (ABCDE12345)"]
        ),
        requiresTrustedSignature: true
    )
}

@Test
func updaterRejectsRemoteUpdatesFromDifferentDeveloperTeam() throws {
    #expect(throws: BarnOwlUpdateError.updateTeamMismatch) {
        try BarnOwlUpdater.validateSignaturePolicy(
            BarnOwlUpdateSignatureSummary(
                hasValidSignature: true,
                isAdHoc: false,
                teamIdentifier: "OTHER12345",
                authorityNames: ["Developer ID Application: Other, Inc. (OTHER12345)"]
            ),
            requiresTrustedSignature: true,
            expectedTeamIdentifier: "ABCDE12345"
        )
    }
}

@Test
func updaterRejectsInvalidUpdateSignatures() {
    #expect(throws: BarnOwlUpdateError.untrustedArchiveSignature) {
        try BarnOwlUpdater.validateSignaturePolicy(
            BarnOwlUpdateSignatureSummary(
                hasValidSignature: false,
                isAdHoc: false,
                teamIdentifier: "ABCDE12345"
            ),
            requiresTrustedSignature: false
        )
    }
}

@Test
func appDelegateSkipsMenuBarRuntimeDuringUnitTests() {
    #expect(!BarnOwlAppDelegate.shouldInstallAppRuntime(
        environment: ["XCTestConfigurationFilePath": "/tmp/BarnOwl.xctestconfiguration"],
        arguments: ["/tmp/BarnOwlApp"]
    ))
    #expect(!BarnOwlAppDelegate.shouldInstallAppRuntime(
        environment: [:],
        arguments: ["/tmp/BarnOwlApp", "/tmp/BarnOwlCoreTests.xctest"]
    ))
    #expect(BarnOwlAppDelegate.shouldInstallAppRuntime(
        environment: [:],
        arguments: ["/Applications/Barn Owl.app/Contents/MacOS/BarnOwlApp"]
    ))
}

@Test
func recorderInspectorUsesCanonicalFactsBeforeMarkdownFallbacks() {
    let facts = MeetingFacts(
        title: "Acme rollout planning",
        meetingType: "Customer Workshop",
        participants: ["Dana", "Lee"],
        customers: ["Acme"]
    )

    let text = RecorderInspectorPresentation.inferredFactsText(
        meetingFacts: facts,
        fallbackMeetingType: "One-on-One",
        fallbackParticipants: "Alex"
    )

    #expect(text.contains("customer workshop"))
    #expect(text.contains("Dana, Lee"))
    #expect(text.contains("Acme"))
    #expect(!text.contains("Alex"))
}

@Test
func recorderInspectorOnlyAppearsWhenThereIsActionableMeetingContext() {
    #expect(!RecorderInspectorPresentation.shouldShowInspector(
        hasDisplayedNote: false,
        hasActiveSession: false,
        status: .idle,
        hasJobs: false,
        hasContextInbox: false,
        hasPostRecordingReview: false,
        hasRecoveryItems: false
    ))
    #expect(RecorderInspectorPresentation.shouldShowInspector(
        hasDisplayedNote: true,
        hasActiveSession: false,
        status: .idle,
        hasJobs: false,
        hasContextInbox: false,
        hasPostRecordingReview: false,
        hasRecoveryItems: false
    ))
    #expect(RecorderInspectorPresentation.shouldShowInspector(
        hasDisplayedNote: false,
        hasActiveSession: false,
        status: .processing,
        hasJobs: true,
        hasContextInbox: false,
        hasPostRecordingReview: false,
        hasRecoveryItems: false
    ))
}

@Test
@MainActor
func quickCommandAddContextUsesLatestMeetingWhenNoIDIsSupplied() async throws {
    let database = try BarnOwlDatabase.inMemory()
    let model = try makeQuickCommandTestModel(database: database)
    let meetingID = UUID(uuidString: "00000000-0000-0000-0000-000000000701")!
    try await database.upsertMeetingState(makeQuickCommandMeetingState(id: meetingID, title: "Acme Pricing"))

    let response = await model.handleQuickCommand(BarnOwlQuickCommand(
        name: .addContext,
        context: "Dana said renewal pricing is the main risk.",
        source: "codex"
    ))

    #expect(response.ok)
    #expect(response.activeMeetingID == meetingID)
    let contextItems = try await database.externalContextItems(meetingID: meetingID, limit: 10)
    #expect(contextItems.count == 1)
    #expect(contextItems[0].body == "Dana said renewal pricing is the main risk.")
    #expect(contextItems[0].source == "codex")
}

@Test
@MainActor
func quickCommandRenameUpdatesCanonicalMeetingState() async throws {
    let database = try BarnOwlDatabase.inMemory()
    let model = try makeQuickCommandTestModel(database: database)
    let meetingID = UUID(uuidString: "00000000-0000-0000-0000-000000000702")!
    try await database.upsertMeetingState(makeQuickCommandMeetingState(id: meetingID, title: "Untitled Meeting"))

    let response = await model.handleQuickCommand(BarnOwlQuickCommand(
        name: .renameMeeting,
        meetingID: meetingID,
        title: "Acme Renewal Review"
    ))

    #expect(response.ok)
    #expect(response.activeMeetingID == meetingID)
    let state = try #require(await database.meetingState(id: meetingID))
    #expect(state.title == "Acme Renewal Review")
    #expect(state.meetingFacts?.title == "Acme Renewal Review")
}

@Test
@MainActor
func quickCommandAskNotesAnswersFromSQLiteMeetingState() async throws {
    let database = try BarnOwlDatabase.inMemory()
    let model = try makeQuickCommandTestModel(database: database)
    let meetingID = UUID(uuidString: "00000000-0000-0000-0000-000000000703")!
    try await database.upsertMeetingState(makeQuickCommandMeetingState(
        id: meetingID,
        title: "Acme Decisions",
        summary: MeetingSummary(
            overview: "Reviewed Acme pricing and renewal risk.",
            decisions: ["Use annual pricing for Acme."],
            actionItems: ["Send Dana the proposal."]
        )
    ))

    let response = await model.handleQuickCommand(BarnOwlQuickCommand(
        name: .askNotes,
        meetingID: meetingID,
        question: "What did we decide?"
    ))

    #expect(response.ok)
    #expect(response.activeMeetingID == meetingID)
    #expect(response.answer?.contains("Use annual pricing for Acme.") == true)
    #expect(response.citations?.first?.id == meetingID.uuidString)
}

@Test
@MainActor
func quickCommandOpenLatestPrefersDisplayedThenLatestCompletedMeeting() async throws {
    let database = try BarnOwlDatabase.inMemory()
    let model = try makeQuickCommandTestModel(database: database)
    let olderID = UUID(uuidString: "00000000-0000-0000-0000-000000000704")!
    let newerID = UUID(uuidString: "00000000-0000-0000-0000-000000000705")!
    try await database.upsertMeetingState(makeQuickCommandMeetingState(
        id: olderID,
        title: "Older Meeting",
        startedAt: Date(timeIntervalSince1970: 1_800_000_000)
    ))
    try await database.upsertMeetingState(makeQuickCommandMeetingState(
        id: newerID,
        title: "Newer Meeting",
        startedAt: Date(timeIntervalSince1970: 1_800_000_200)
    ))

    let response = await model.handleQuickCommand(BarnOwlQuickCommand(name: .openLatestMeeting))

    #expect(response.ok)
    #expect(response.activeMeetingID == newerID)
    #expect(model.displayedNote?.id == newerID)
}

@Test
@MainActor
func realtimeControllerCommitsOnlyAfterMinimumBufferedAudio() async throws {
    let client = TestRealtimeStreamingClient()
    var healthStates: [BarnOwlRealtimeHealthState] = []
    let controller = BarnOwlRealtimeTranscriptionController(
        client: client,
        manualCommitInterval: 0,
        updateHandler: { _ in },
        healthHandler: { healthStates.append($0) }
    )

    await controller.start()
    await controller.append(AudioRealtimePCMChunk(
        trackKind: .microphone,
        pcm16Data: makeRealtimePCM16Data(sample: 3_000, byteCount: OpenAIRealtimeTranscriptionClient.minimumCommitByteCount - 2),
        sampleRate: OpenAIRealtimeTranscriptionClient.defaultSampleRate,
        duration: 0.09
    ))
    #expect(await client.commitCount == 0)

    await controller.append(AudioRealtimePCMChunk(
        trackKind: .microphone,
        pcm16Data: makeRealtimePCM16Data(sample: 3_000, byteCount: 2),
        sampleRate: OpenAIRealtimeTranscriptionClient.defaultSampleRate,
        duration: 0.01
    ))
    #expect(await client.commitCount == 1)
    #expect(healthStates.contains(.connecting))
    #expect(healthStates.contains(.connected))
    #expect(healthStates.contains(.receivingAudio))

    await controller.stop()
}

@Test
@MainActor
func realtimeControllerReportsTranscribingForDeltas() async throws {
    let client = TestRealtimeStreamingClient(
        events: [.transcriptDelta("hello"), .transcriptCompleted("hello world")],
        initialReceiveDelayNanoseconds: 50_000_000
    )
    var updates: [BarnOwlRealtimeTranscriptionUpdate] = []
    var healthStates: [BarnOwlRealtimeHealthState] = []
    let controller = BarnOwlRealtimeTranscriptionController(
        client: client,
        manualCommitInterval: 0,
        updateHandler: { updates.append($0) },
        healthHandler: { healthStates.append($0) }
    )

    await controller.start()
    await controller.append(AudioRealtimePCMChunk(
        trackKind: .microphone,
        pcm16Data: makeRealtimePCM16Data(sample: 3_000, byteCount: OpenAIRealtimeTranscriptionClient.minimumCommitByteCount + 512),
        sampleRate: OpenAIRealtimeTranscriptionClient.defaultSampleRate,
        duration: 0.70
    ))
    try await Task.sleep(nanoseconds: 100_000_000)

    #expect(updates.map(\.text) == ["hello", "hello world"])
    #expect(updates.map(\.isFinal) == [false, true])
    #expect(healthStates.contains(.transcribing))

    await controller.stop()
}

@Test
@MainActor
func jobRunnerCompletesQueuedFinalProcessingJob() async throws {
    let database = try BarnOwlDatabase.inMemory()
    let sessionID = UUID(uuidString: "00000000-0000-0000-0000-000000000501")!
    let now = Date(timeIntervalSince1970: 1_800_005_000)
    let session = RecordingSession(
        id: sessionID,
        title: "Job Runner Test",
        startedAt: now,
        audioSources: .defaultMeetingCapture
    ).finished(at: now.addingTimeInterval(60))
    try await database.upsertMeeting(BarnOwlMeetingRecord(
        id: sessionID,
        title: session.title,
        startedAt: session.startedAt,
        endedAt: session.endedAt,
        createdAt: now,
        updatedAt: now
    ))

    let processor = FakeMeetingProcessor(
        outputURL: FileManager.default.temporaryDirectory.appending(path: "job-runner-test.md")
    )
    let runner = BarnOwlJobRunner(
        makeDatabase: { database },
        meetingProcessor: processor
    )

    _ = try await runner.enqueueFinalProcessing(session: session)
    await runner.runAvailableJobs()

    let jobs = try await database.jobs(status: .succeeded, meetingID: sessionID)
    #expect(jobs.count == 1)
    #expect(jobs[0].type == BarnOwlJobType.finalProcessing)
    #expect(await processor.processedSessionIDs == [sessionID])
}

@Test
func connectivityFailureKeepsFinalProcessingQueuedForOfflineMode() async throws {
    let database = try BarnOwlDatabase.inMemory()
    let sessionID = UUID(uuidString: "00000000-0000-0000-0000-000000000502")!
    let now = Date(timeIntervalSince1970: 1_800_005_100)
    let session = RecordingSession(
        id: sessionID,
        title: "Offline Job Runner Test",
        startedAt: now,
        audioSources: .defaultMeetingCapture
    ).finished(at: now.addingTimeInterval(60))
    try await database.upsertMeeting(BarnOwlMeetingRecord(
        id: sessionID,
        title: session.title,
        startedAt: session.startedAt,
        endedAt: session.endedAt,
        createdAt: now,
        updatedAt: now
    ))

    let processor = FakeMeetingProcessor(
        outputURL: FileManager.default.temporaryDirectory.appending(path: "offline-job-runner-test.md"),
        error: URLError(.notConnectedToInternet)
    )
    let runner = BarnOwlJobRunner(
        makeDatabase: { database },
        meetingProcessor: processor,
        maxAttempts: 1
    )

    _ = try await runner.enqueueFinalProcessing(session: session)
    await runner.runAvailableJobs()

    let job = try #require(await database.jobs(meetingID: sessionID, limit: 1).first)
    #expect(job.status == .pending)
    #expect(job.attemptCount == 1)
    #expect(job.completedAt == nil)
    #expect(job.scheduledAt != nil)
    #expect(job.errorMessage == BarnOwlProcessingRetryPolicy.offlineQueuedMessage)
}

@Test
func claimingPendingJobClearsPreviousRetryError() async throws {
    let database = try BarnOwlDatabase.inMemory()
    let jobID = UUID(uuidString: "00000000-0000-0000-0000-000000000503")!
    try await database.upsertJob(BarnOwlJobRecord(
        id: jobID,
        type: BarnOwlJobType.summaryProcessing,
        status: .pending,
        attemptCount: 4,
        errorMessage: BarnOwlProcessingRetryPolicy.offlineQueuedMessage,
        scheduledAt: Date(timeIntervalSince1970: 1_800_005_200)
    ))

    let claimed = try #require(await database.claimNextPendingJob(now: Date(timeIntervalSince1970: 1_800_005_201)))

    #expect(claimed.id == jobID)
    #expect(claimed.status == .running)
    #expect(claimed.errorMessage == nil)
    #expect(claimed.attemptCount == 5)
}

@Test
@MainActor
func staleRunningJobBecomesRetryableOnLaunchRecovery() async throws {
    let database = try BarnOwlDatabase.inMemory()
    let meetingID = UUID(uuidString: "00000000-0000-0000-0000-000000000511")!
    let jobID = UUID(uuidString: "00000000-0000-0000-0000-000000000512")!
    let now = Date(timeIntervalSince1970: 1_800_008_000)
    try await database.upsertMeeting(BarnOwlMeetingRecord(
        id: meetingID,
        title: "Interrupted Job",
        startedAt: now.addingTimeInterval(-120),
        createdAt: now.addingTimeInterval(-120),
        updatedAt: now.addingTimeInterval(-60)
    ))
    try await database.upsertJob(BarnOwlJobRecord(
        id: jobID,
        meetingID: meetingID,
        type: BarnOwlJobType.finalProcessing,
        status: .running,
        priority: 100,
        attemptCount: 1,
        createdAt: now.addingTimeInterval(-60),
        updatedAt: now.addingTimeInterval(-30),
        startedAt: now.addingTimeInterval(-30)
    ))
    let runner = BarnOwlJobRunner(makeDatabase: { database }, meetingProcessor: FakeMeetingProcessor(outputURL: FileManager.default.temporaryDirectory))

    let report = try await BarnOwlRecoveryCoordinator.recoverInterruptedWork(
        database: database,
        jobRunner: runner,
        now: now
    )

    let recovered = try #require(await database.job(id: jobID))
    #expect(report.recoveredRunningJobCount == 1)
    #expect(recovered.status == .pending)
    #expect(recovered.attemptCount == 0)
    #expect(recovered.errorMessage?.contains("Interrupted") == true)
    #expect(recovered.scheduledAt == now)
}

@Test
func failedTranscriptJobCanRetry() async throws {
    let database = try BarnOwlDatabase.inMemory()
    let jobID = UUID(uuidString: "00000000-0000-0000-0000-000000000521")!
    try await database.upsertJob(BarnOwlJobRecord(
        id: jobID,
        type: BarnOwlJobType.finalProcessing,
        status: .failed,
        errorMessage: "Transcription failed."
    ))

    let retriedCount = try await BarnOwlRecoveryCoordinator.retryFailedJobs(database: database, ids: [jobID])

    let job = try #require(await database.job(id: jobID))
    #expect(retriedCount == 1)
    #expect(job.status == .pending)
    #expect(job.errorMessage == nil)
}

@Test
func failedNoteGenerationJobCanRetry() async throws {
    let database = try BarnOwlDatabase.inMemory()
    let jobID = UUID(uuidString: "00000000-0000-0000-0000-000000000522")!
    try await database.upsertJob(BarnOwlJobRecord(
        id: jobID,
        type: BarnOwlJobType.noteUpdate,
        status: .failed,
        errorMessage: "Note generation failed."
    ))

    let retriedCount = try await BarnOwlRecoveryCoordinator.retryFailedJobs(database: database, ids: [jobID])

    let job = try #require(await database.job(id: jobID))
    #expect(retriedCount == 1)
    #expect(job.status == .pending)
    #expect(job.scheduledAt != nil)
}

@Test
@MainActor
func interruptedRecordingWithChunksQueuesRecoveryProcessing() async throws {
    let database = try BarnOwlDatabase.inMemory()
    let tempRoot = FileManager.default.temporaryDirectory
        .appending(path: "BarnOwlRecoveryTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: tempRoot) }
    let meetingID = UUID(uuidString: "00000000-0000-0000-0000-000000000531")!
    let now = Date(timeIntervalSince1970: 1_800_008_100)
    try await database.upsertMeeting(BarnOwlMeetingRecord(
        id: meetingID,
        title: "Interrupted Recording",
        startedAt: now.addingTimeInterval(-300),
        createdAt: now.addingTimeInterval(-300),
        updatedAt: now.addingTimeInterval(-120)
    ))
    try await database.upsertRecordingSession(BarnOwlRecordingSessionRecord(
        id: meetingID,
        meetingID: meetingID,
        status: .recording,
        startedAt: now.addingTimeInterval(-300),
        audioSourcesJSON: #"{"microphone":true,"systemAudio":true}"#,
        createdAt: now.addingTimeInterval(-300),
        updatedAt: now.addingTimeInterval(-120)
    ))
    let store = FilesystemTempAudioChunkStore(rootDirectory: tempRoot)
    let reservation = try await store.reserveChunk(
        sessionID: meetingID,
        trackKind: "microphone",
        sequenceNumber: 0,
        fileExtension: "wav"
    )
    _ = try await store.writeChunk(Data([1, 2, 3, 4]), to: reservation)
    let runner = BarnOwlJobRunner(makeDatabase: { database }, meetingProcessor: FakeMeetingProcessor(outputURL: FileManager.default.temporaryDirectory))

    let report = try await BarnOwlRecoveryCoordinator.recoverInterruptedWork(
        database: database,
        jobRunner: runner,
        tempRoot: tempRoot,
        now: now
    )

    let state = try #require(await database.meetingState(id: meetingID))
    #expect(report.recoveredInterruptedRecordingCount == 1)
    #expect(state.status == .processing)
    #expect(state.jobs.contains { $0.type == BarnOwlJobType.finalProcessing && $0.status == .pending })
}

@Test
@MainActor
func interruptedRecordingWithoutChunksIsVisibleAsNeedsAttention() async throws {
    let database = try BarnOwlDatabase.inMemory()
    let tempRoot = FileManager.default.temporaryDirectory
        .appending(path: "BarnOwlRecoveryTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: tempRoot) }
    let meetingID = UUID(uuidString: "00000000-0000-0000-0000-000000000532")!
    let now = Date(timeIntervalSince1970: 1_800_008_200)
    try await database.upsertMeeting(BarnOwlMeetingRecord(
        id: meetingID,
        title: "Incomplete Recording",
        startedAt: now.addingTimeInterval(-120),
        createdAt: now.addingTimeInterval(-120),
        updatedAt: now.addingTimeInterval(-60)
    ))
    try await database.upsertRecordingSession(BarnOwlRecordingSessionRecord(
        id: meetingID,
        meetingID: meetingID,
        status: .recording,
        startedAt: now.addingTimeInterval(-120),
        createdAt: now.addingTimeInterval(-120),
        updatedAt: now.addingTimeInterval(-60)
    ))
    let runner = BarnOwlJobRunner(makeDatabase: { database }, meetingProcessor: FakeMeetingProcessor(outputURL: FileManager.default.temporaryDirectory))

    let report = try await BarnOwlRecoveryCoordinator.recoverInterruptedWork(
        database: database,
        jobRunner: runner,
        tempRoot: tempRoot,
        now: now
    )

    let state = try #require(await database.meetingState(id: meetingID))
    #expect(report.incompleteRecordingCount == 1)
    #expect(report.needsAttention)
    #expect(state.status == .failed)
    #expect(state.jobs.contains { $0.status == .failed && ($0.errorMessage?.contains("no recoverable audio") ?? false) })
}

@Test
func silenceAutoStopDecisionUsesFifteenMinuteThreshold() {
    let lastAudibleAt = Date(timeIntervalSince1970: 1_800_008_300)

    #expect(!BarnOwlAppModel.shouldAutoStopForSilence(
        lastAudibleAt: lastAudibleAt,
        now: lastAudibleAt.addingTimeInterval((15 * 60) - 1)
    ))
    #expect(BarnOwlAppModel.shouldAutoStopForSilence(
        lastAudibleAt: lastAudibleAt,
        now: lastAudibleAt.addingTimeInterval(15 * 60)
    ))
}

@Test
@MainActor
func postRecordingContextReviewSuggestsTypeTitleAndParticipantsFromTranscript() {
    let session = RecordingSession(
        title: "Untitled Meeting",
        startedAt: Date(timeIntervalSince1970: 1_800_006_000),
        audioSources: .defaultMeetingCapture
    ).finished(at: Date(timeIntervalSince1970: 1_800_006_120))
    let review = BarnOwlAppModel.suggestPostRecordingContext(
        session: session,
        transcriptPreview: """
        Dana: The Acme customer workshop needs implementation requirements mapped.
        Lee: I will send the follow-up plan.
        """
    )

    #expect(review.facts.meetingType == "Customer Workshop")
    #expect(review.facts.participants == ["Dana", "Lee"])
    #expect(review.facts.title != "Untitled Meeting")
    #expect(review.contextLines.contains("Meeting type: Customer Workshop"))
}

@Test
@MainActor
func meetingFactsMarkdownSectionIsReplacedInsteadOfDuplicated() {
    let session = RecordingSession(
        title: "Acme Workshop",
        startedAt: Date(timeIntervalSince1970: 1_800_006_000),
        audioSources: .defaultMeetingCapture
    )
    let facts = MeetingFacts(
        title: "Acme Workshop",
        meetingType: "Customer Workshop",
        participants: ["Dana"],
        customers: ["Acme"]
    )
    let first = BarnOwlAppModel.markdownReplacingMeetingFacts(
        in: "# Acme Workshop\n\n## Summary\nOriginal\n",
        with: BarnOwlAppModel.meetingFactsMarkdownSection(facts, session: session)
    )
    let second = BarnOwlAppModel.markdownReplacingMeetingFacts(
        in: first,
        with: BarnOwlAppModel.meetingFactsMarkdownSection(facts, session: session)
    )

    #expect(second.components(separatedBy: "## Meeting Facts").count == 2)
    #expect(second.contains("- Meeting type: Customer Workshop"))
    #expect(second.contains("- Participants: Dana"))
    #expect(second.contains("- Customers: Acme"))
}

@Test
func meetingFactsExtractorParsesMessyFreeformContext() {
    let facts = MeetingFactsExtractor().extract(
        transcript: "",
        freeformContext: "This was with Dana and Lee about the Acme renewal. Main thing is pricing risk. Customer workshop, probably call it Acme rollout planning. Alex was there too, and SG means Strategic Growth."
    )

    #expect(facts.title == "Acme rollout planning")
    #expect(facts.meetingType == "Customer Workshop")
    #expect(facts.participants.contains("Dana"))
    #expect(facts.participants.contains("Lee"))
    #expect(facts.participants.contains("Alex"))
    #expect(facts.customers.contains("Acme"))
    #expect(facts.glossary["SG"] == "Strategic Growth")
}

@Test
func meetingFactsExtractorIgnoresSpeakerLabelsAndLowercaseNoiseOrganizations() {
    let facts = MeetingFactsExtractor().extract(
        transcript: """
        A: All right, let's see, are we recording or not?
        A: It's coming up with total random bullshit, like literally random bullshit, so something is not working there.
        """
    )

    #expect(facts.participants.isEmpty)
    #expect(facts.organizations.isEmpty)
    #expect(facts.customers.isEmpty)
}

@Test
func contextPromptGeneratorOnlyAsksUsefulQuestions() {
    let lowConfidenceFacts = MeetingFactsExtractor().extract(
        transcript: "SG came up again. SG needs an owner. someone should follow up."
    )
    let lowPrompts = ContextPromptGenerator().prompts(
        for: lowConfidenceFacts,
        transcript: "SG came up again. SG needs an owner. someone should follow up."
    )
    #expect(lowPrompts.contains { $0.kind == .title })
    #expect(lowPrompts.contains { $0.kind == .acronym })
    #expect(lowPrompts.contains { $0.kind == .actionOwner })

    let highConfidenceFacts = MeetingFactsExtractor().extract(
        transcript: "Dana: Customer workshop about Acme rollout planning. Lee: SG means Strategic Growth.",
        freeformContext: "Call it Acme rollout planning. Dana and Lee were there."
    )
    let highPrompts = ContextPromptGenerator().prompts(
        for: highConfidenceFacts,
        transcript: "Dana: Customer workshop about Acme rollout planning. Lee: SG means Strategic Growth."
    )
    #expect(highPrompts.isEmpty)
}

private func makeActivityItem(message: String, timestamp: Date) -> BarnOwlActivityItem {
    BarnOwlActivityItem(
        timestamp: timestamp,
        level: .info,
        message: message,
        details: nil
    )
}

@MainActor
private func makeQuickCommandTestModel(database: BarnOwlDatabase) throws -> BarnOwlAppModel {
    let libraryRoot = FileManager.default.temporaryDirectory
        .appending(path: "BarnOwlQuickCommandTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: libraryRoot, withIntermediateDirectories: true)
    return BarnOwlAppModel(
        makeAudioCoordinator: { _, _, _ in
            AudioSessionCoordinator(
                microphoneSource: NoOpMicrophoneAudioSource(),
                systemAudioSource: NoOpSystemAudioSource()
            )
        },
        meetingProcessor: FakeMeetingProcessor(outputURL: libraryRoot.appending(path: "processed.md")),
        makeLibraryStore: {
            FilesystemLocalLibraryStore(rootDirectory: libraryRoot)
        },
        makeDatabase: { database },
        diagnosticsStore: DiagnosticsLogStore(rootDirectory: libraryRoot.appending(path: "Diagnostics", directoryHint: .isDirectory))
    )
}

private func makeQuickCommandMeetingState(
    id: UUID,
    title: String,
    startedAt: Date = Date(timeIntervalSince1970: 1_800_000_100),
    summary: MeetingSummary = MeetingSummary(overview: "Reviewed Barn Owl quick commands.")
) -> BarnOwlMeetingState {
    let meeting = BarnOwlMeetingRecord(
        id: id,
        title: title,
        startedAt: startedAt,
        endedAt: startedAt.addingTimeInterval(30),
        createdAt: startedAt,
        updatedAt: startedAt
    )
    return BarnOwlMeetingState(
        meeting: meeting,
        status: .completed,
        meetingFacts: MeetingFacts(title: title, meetingType: "Planning / Review", participants: ["Dana"]),
        generatedNotes: [
            "# \(title)",
            "## Summary\n\(summary.overview)",
            summary.decisions.isEmpty ? nil : "## Decisions\n\(summary.decisions.map { "- \($0)" }.joined(separator: "\n"))",
            summary.actionItems.isEmpty ? nil : "## Action Items\n\(summary.actionItems.map { "- \($0)" }.joined(separator: "\n"))"
        ]
        .compactMap { $0 }
        .joined(separator: "\n\n"),
        summary: summary,
        actionItems: summary.actionItems,
        decisions: summary.decisions,
        openQuestions: summary.openQuestions,
        updatedAt: startedAt
    )
}

private func unusedLocalPort() throws -> UInt16 {
    let server = socket(AF_INET, SOCK_STREAM, 0)
    guard server >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    defer { Darwin.close(server) }

    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = 0
    address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

    let bindResult = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Darwin.bind(server, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    guard bindResult == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }

    var boundAddress = sockaddr_in()
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    let nameResult = withUnsafeMutablePointer(to: &boundAddress) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            getsockname(server, $0, &length)
        }
    }
    guard nameResult == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    return UInt16(bigEndian: boundAddress.sin_port)
}

private func waitForBridge(port: UInt16) async throws {
    let deadline = Date().addingTimeInterval(3)
    while Date() < deadline {
        if (try? sendLocalHTTPRequest(port: port, request: getBridgeStatusRequest())) != nil {
            return
        }
        try await Task.sleep(nanoseconds: 50_000_000)
    }
    throw POSIXError(.ETIMEDOUT)
}

private func getBridgeStatusRequest() -> String {
    """
    GET /status HTTP/1.1\r
    Host: 127.0.0.1\r
    Connection: close\r
    \r

    """
}

private func postBridgeRequest(body: String, bearerToken: String? = nil) -> String {
    var lines = [
        "POST / HTTP/1.1",
        "Host: 127.0.0.1",
        "Content-Type: application/json",
        "Content-Length: \(Data(body.utf8).count)",
        "Connection: close"
    ]
    if let bearerToken {
        lines.append("Authorization: Bearer \(bearerToken)")
    }
    return lines.joined(separator: "\r\n") + "\r\n\r\n" + body
}

private func sendLocalHTTPRequest(port: UInt16, request: String) throws -> String {
    let client = socket(AF_INET, SOCK_STREAM, 0)
    guard client >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    defer { Darwin.close(client) }

    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = in_port_t(port).bigEndian
    address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

    let connectResult = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Darwin.connect(client, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    guard connectResult == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }

    let requestData = Data(request.utf8)
    try requestData.withUnsafeBytes { rawBuffer in
        guard let baseAddress = rawBuffer.baseAddress else { return }
        var sent = 0
        while sent < requestData.count {
            let result = Darwin.send(client, baseAddress.advanced(by: sent), requestData.count - sent, 0)
            guard result > 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            sent += result
        }
    }

    var responseData = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)
    while true {
        let count = recv(client, &buffer, buffer.count, 0)
        guard count > 0 else { break }
        responseData.append(buffer, count: count)
    }
    return String(decoding: responseData, as: UTF8.self)
}

private struct NoOpMicrophoneAudioSource: MicrophoneAudioSource {
    func requestMicrophonePermission() async throws {}
    func startMicrophoneCapture(configuration: AudioSourceConfiguration) async throws {}
    func stopMicrophoneCapture() async {}
}

private struct NoOpSystemAudioSource: SystemAudioSource {
    func requestSystemAudioPermission() async throws {}
    func startSystemAudioCapture(configuration: AudioSourceConfiguration) async throws {}
    func stopSystemAudioCapture() async {}
}

private actor FakeMeetingProcessor: MeetingProcessing {
    private let outputURL: URL
    private let error: (any Error)?
    private var processed: [UUID] = []

    init(outputURL: URL, error: (any Error)? = nil) {
        self.outputURL = outputURL
        self.error = error
    }

    func process(
        session: RecordingSession,
        progress: MeetingProcessingProgressHandler?
    ) async throws -> URL {
        processed.append(session.id)
        if let error {
            throw error
        }
        await progress?(MeetingProcessingProgress(message: "Fake job complete.", progressFraction: 1))
        return outputURL
    }

    var processedSessionIDs: [UUID] {
        processed
    }
}

private actor TestRealtimeStreamingClient: BarnOwlRealtimeStreamingClient {
    private(set) var didConnect = false
    private(set) var appendedByteCount = 0
    private(set) var commitCount = 0
    private var events: [OpenAIRealtimeTranscriptionEvent]
    private let initialReceiveDelayNanoseconds: UInt64
    private var didDelayInitialReceive = false

    init(events: [OpenAIRealtimeTranscriptionEvent] = [], initialReceiveDelayNanoseconds: UInt64 = 0) {
        self.events = events
        self.initialReceiveDelayNanoseconds = initialReceiveDelayNanoseconds
    }

    func connect() async throws {
        didConnect = true
    }

    func appendPCM16Audio(_ audio: Data) async throws {
        appendedByteCount += audio.count
    }

    func commitAudio() async throws {
        commitCount += 1
    }

    func receiveEvent() async throws -> OpenAIRealtimeTranscriptionEvent? {
        if !didDelayInitialReceive, initialReceiveDelayNanoseconds > 0 {
            didDelayInitialReceive = true
            try await Task.sleep(nanoseconds: initialReceiveDelayNanoseconds)
        }
        if !events.isEmpty {
            return events.removeFirst()
        }
        try await Task.sleep(nanoseconds: 10_000_000_000)
        return nil
    }

    func close() async {}
}

private func makeRealtimePCM16Data(sample: Int16, byteCount: Int) -> Data {
    let evenByteCount = byteCount - (byteCount % MemoryLayout<Int16>.size)
    var data = Data()
    data.reserveCapacity(evenByteCount)
    let littleEndian = sample.littleEndian
    for _ in 0..<(evenByteCount / MemoryLayout<Int16>.size) {
        var value = littleEndian
        withUnsafeBytes(of: &value) { bytes in
            data.append(contentsOf: bytes)
        }
    }
    return data
}

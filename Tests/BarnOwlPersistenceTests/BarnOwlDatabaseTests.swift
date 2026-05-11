import BarnOwlCore
import BarnOwlPersistence
import BarnOwlTranscription
import Foundation
import Testing

@Test
func barnOwlDatabaseCreatesSchemaAndPersistsMeetingsAcrossReopen() async throws {
    let directory = try makeSQLiteTempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let databaseURL = directory.appending(path: "barnowl.sqlite")
    let meeting = makeDatabaseMeeting(title: "Roadmap Review")

    do {
        let database = try BarnOwlDatabase(url: databaseURL)
        #expect(try await database.schemaVersion() == BarnOwlDatabase.latestSchemaVersion)
        try await database.upsertMeeting(meeting)
    }

    let reopened = try BarnOwlDatabase(url: databaseURL)
    let reloaded = try #require(await reopened.meeting(id: meeting.id))

    #expect(reloaded == meeting)
}

@Test
func barnOwlDatabaseRestrictsDirectoryAndDatabaseFilePermissions() async throws {
    let directory = try makeSQLiteTempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let databaseURL = directory.appending(path: "barnowl.sqlite")

    _ = try BarnOwlDatabase(url: databaseURL)

    #expect(try posixPermissions(at: directory) == 0o700)
    #expect(try posixPermissions(at: databaseURL) == 0o600)
}

@Test
func barnOwlDatabaseUpsertsMeetingsSessionsSegmentsAndOutputs() async throws {
    let database = try BarnOwlDatabase.inMemory()
    let meetingID = UUID(uuidString: "00000000-0000-0000-0000-000000001001")!
    let sessionID = UUID(uuidString: "00000000-0000-0000-0000-000000001002")!
    let outputID = UUID(uuidString: "00000000-0000-0000-0000-000000001005")!
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    let meeting = makeDatabaseMeeting(id: meetingID, title: "Original Title", createdAt: now, updatedAt: now)
    try await database.upsertMeeting(meeting)
    try await database.upsertMeeting(makeDatabaseMeeting(
        id: meetingID,
        title: "Updated Title",
        createdAt: now.addingTimeInterval(-100),
        updatedAt: now.addingTimeInterval(10),
        metadataJSON: #"{"source":"calendar"}"#
    ))

    let session = BarnOwlRecordingSessionRecord(
        id: sessionID,
        meetingID: meetingID,
        status: .recording,
        startedAt: now,
        audioSourcesJSON: #"{"microphone":true,"system":true}"#,
        createdAt: now,
        updatedAt: now
    )
    try await database.upsertRecordingSession(session)

    let firstSegment = BarnOwlTranscriptSegmentRecord(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000001003")!,
        meetingID: meetingID,
        sessionID: sessionID,
        variant: .reviewed,
        sequence: 2,
        speakerLabel: "Sam",
        text: "Second line.",
        startTime: 2,
        endTime: 4,
        confidence: 0.9,
        createdAt: now,
        updatedAt: now
    )
    let secondSegment = BarnOwlTranscriptSegmentRecord(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000001004")!,
        meetingID: meetingID,
        sessionID: sessionID,
        variant: .reviewed,
        sequence: 1,
        speakerLabel: "Lee",
        text: "First line.",
        startTime: 0,
        endTime: 2,
        confidence: 0.95,
        createdAt: now,
        updatedAt: now
    )
    try await database.upsertTranscriptSegments([firstSegment, secondSegment])

    let output = BarnOwlMeetingOutputRecord(
        id: outputID,
        meetingID: meetingID,
        kind: "summary",
        content: "# Summary\n\nOriginal",
        createdAt: now,
        updatedAt: now
    )
    try await database.upsertMeetingOutput(output)
    try await database.upsertMeetingOutput(BarnOwlMeetingOutputRecord(
        id: outputID,
        meetingID: meetingID,
        kind: "summary",
        content: "# Summary\n\nEdited",
        createdAt: now.addingTimeInterval(-100),
        updatedAt: now.addingTimeInterval(20),
        metadataJSON: #"{"model":"test"}"#
    ))

    let updatedMeeting = try #require(await database.meeting(id: meetingID))
    let sessions = try await database.recordingSessions(meetingID: meetingID)
    let segments = try await database.transcriptSegments(meetingID: meetingID, variant: .reviewed)
    let finalSegments = try await database.transcriptSegments(meetingID: meetingID, variant: .final)
    let outputs = try await database.meetingOutputs(meetingID: meetingID, kind: "summary")

    #expect(updatedMeeting.title == "Updated Title")
    #expect(updatedMeeting.createdAt == now)
    #expect(updatedMeeting.metadataJSON == #"{"source":"calendar"}"#)
    #expect(sessions == [session])
    #expect(segments.map(\.text) == ["First line.", "Second line."])
    #expect(segments.allSatisfy { $0.variant == .reviewed })
    #expect(finalSegments.isEmpty)
    #expect(outputs.count == 1)
    #expect(outputs[0].content == "# Summary\n\nEdited")
    #expect(outputs[0].metadataJSON == #"{"model":"test"}"#)
}

@Test
func barnOwlDatabaseStoresJobsChunksAndCalendarContext() async throws {
    let database = try BarnOwlDatabase.inMemory()
    let meetingID = UUID(uuidString: "00000000-0000-0000-0000-000000001101")!
    let jobID = UUID(uuidString: "00000000-0000-0000-0000-000000001102")!
    let now = Date(timeIntervalSince1970: 1_800_001_000)

    try await database.upsertMeeting(makeDatabaseMeeting(id: meetingID, title: "Jobs Review", createdAt: now, updatedAt: now))

    let pendingJob = BarnOwlJobRecord(
        id: jobID,
        meetingID: meetingID,
        type: "summarize",
        status: .pending,
        priority: 10,
        payloadJSON: #"{"output":"summary"}"#,
        createdAt: now,
        updatedAt: now,
        scheduledAt: now.addingTimeInterval(30)
    )
    let lowerPriorityJob = BarnOwlJobRecord(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000001103")!,
        meetingID: meetingID,
        type: "index",
        status: .pending,
        priority: 1,
        createdAt: now,
        updatedAt: now,
        scheduledAt: now
    )
    try await database.upsertJob(lowerPriorityJob)
    try await database.upsertJob(pendingJob)
    try await database.upsertJob(BarnOwlJobRecord(
        id: jobID,
        meetingID: meetingID,
        type: "summarize",
        status: .running,
        priority: 10,
        attemptCount: 1,
        payloadJSON: #"{"output":"summary"}"#,
        createdAt: now,
        updatedAt: now.addingTimeInterval(10),
        scheduledAt: pendingJob.scheduledAt,
        startedAt: now.addingTimeInterval(10)
    ))

    let chunk = BarnOwlJobChunkRecord(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000001104")!,
        jobID: jobID,
        sequence: 0,
        status: .succeeded,
        payloadJSON: #"{"range":[0,30]}"#,
        resultJSON: #"{"ok":true}"#,
        createdAt: now,
        updatedAt: now
    )
    try await database.upsertJobChunk(chunk)

    let context = BarnOwlMeetingCalendarContextRecord(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000001105")!,
        meetingID: meetingID,
        calendarEventID: "event-123",
        title: "Customer Sync",
        startsAt: now,
        endsAt: now.addingTimeInterval(1_800),
        attendeesJSON: #"["alex@example.com"]"#,
        rawContextJSON: #"{"provider":"test"}"#,
        createdAt: now,
        updatedAt: now
    )
    try await database.upsertMeetingCalendarContext(context)

    let runningJob = try #require(await database.job(id: jobID))
    let pendingJobs = try await database.jobs(status: .pending, meetingID: meetingID)
    let claimedJob = try #require(await database.claimNextPendingJob(now: now.addingTimeInterval(40)))
    let chunks = try await database.jobChunks(jobID: jobID)
    let reloadedContext = try #require(await database.meetingCalendarContext(meetingID: meetingID))

    #expect(runningJob.status == .running)
    #expect(runningJob.attemptCount == 1)
    #expect(pendingJobs.map(\.id) == [lowerPriorityJob.id])
    #expect(claimedJob.id == lowerPriorityJob.id)
    #expect(claimedJob.status == .running)
    #expect(claimedJob.attemptCount == 1)
    #expect(chunks == [chunk])
    #expect(reloadedContext == context)
}

@Test
func barnOwlDatabaseStoresRollingTranscriptionCacheByChunkIdentity() async throws {
    let database = try BarnOwlDatabase.inMemory()
    let meetingID = UUID(uuidString: "00000000-0000-0000-0000-000000001131")!
    let now = Date(timeIntervalSince1970: 1_800_001_300)
    try await database.upsertMeeting(makeDatabaseMeeting(id: meetingID, title: "Rolling Cache", createdAt: now, updatedAt: now))
    try await database.upsertRecordingSession(BarnOwlRecordingSessionRecord(
        id: meetingID,
        meetingID: meetingID,
        status: .recording,
        startedAt: now,
        createdAt: now,
        updatedAt: now
    ))

    let key = RollingFinalTranscriptionKey(sessionID: meetingID, trackID: "microphone", sequenceNumber: 0)
    let audioFile = RecordedAudioFile(
        url: URL(fileURLWithPath: "/tmp/0.wav"),
        trackLabel: "Microphone",
        startTimeOffset: 55,
        sequenceNumber: 0,
        trackID: "microphone",
        duration: 60,
        overlapDuration: 5
    )
    let cache = SQLiteRollingFinalTranscriptionCacheStore(database: database, now: { now })
    let response = AudioFileTranscriptionResponse(segments: [
        AudioFileTranscriptionSegment(speakerLabel: "A", text: "Cached final chunk.", startTime: 0, endTime: 2)
    ])

    #expect(try await cache.markRunning(key: key, audioFile: audioFile, modelIdentifier: "model-a"))
    #expect(!(try await cache.markRunning(key: key, audioFile: audioFile, modelIdentifier: "model-a")))
    try await cache.markCompleted(key: key, audioFile: audioFile, modelIdentifier: "model-a", response: response)
    #expect(!(try await cache.markRunning(key: key, audioFile: audioFile, modelIdentifier: "model-a")))

    let stored = try #require(await database.rollingTranscription(
        sessionID: meetingID,
        trackID: "microphone",
        sequenceNumber: 0
    ))
    let cached = try await cache.completedResponse(for: key)

    #expect(stored.status == .completed)
    #expect(stored.trackLabel == "Microphone")
    #expect(stored.startTimeOffset == 55)
    #expect(stored.duration == 60)
    #expect(stored.overlapDuration == 5)
    #expect(stored.modelIdentifier == "model-a")
    #expect(cached == response)
    #expect(try await cache.completedResponse(for: key, modelIdentifier: "model-a") == response)
    #expect(try await cache.completedResponse(for: key, modelIdentifier: "model-b") == nil)
    #expect(try await cache.markRunning(key: key, audioFile: audioFile, modelIdentifier: "model-b"))

    let failedKey = RollingFinalTranscriptionKey(sessionID: meetingID, trackID: "microphone", sequenceNumber: 1)
    let failedFile = RecordedAudioFile(
        url: URL(fileURLWithPath: "/tmp/1.wav"),
        trackLabel: "Microphone",
        sequenceNumber: 1,
        trackID: "microphone"
    )
    try await cache.markFailed(key: failedKey, audioFile: failedFile, modelIdentifier: "model-a", errorMessage: "network")
    #expect(try await cache.completedResponse(for: failedKey) == nil)
}

@Test
func barnOwlDatabaseDeletesRollingTranscriptionCacheForCompletedSession() async throws {
    let database = try BarnOwlDatabase.inMemory()
    let meetingID = UUID(uuidString: "00000000-0000-0000-0000-000000001132")!
    let otherMeetingID = UUID(uuidString: "00000000-0000-0000-0000-000000001133")!
    let now = Date(timeIntervalSince1970: 1_800_001_350)
    try await database.upsertMeeting(makeDatabaseMeeting(id: meetingID, title: "Rolling Cache Cleanup", createdAt: now, updatedAt: now))
    try await database.upsertMeeting(makeDatabaseMeeting(id: otherMeetingID, title: "Other Cache", createdAt: now, updatedAt: now))
    try await database.upsertRecordingSession(BarnOwlRecordingSessionRecord(
        id: meetingID,
        meetingID: meetingID,
        status: .recording,
        startedAt: now,
        createdAt: now,
        updatedAt: now
    ))
    try await database.upsertRecordingSession(BarnOwlRecordingSessionRecord(
        id: otherMeetingID,
        meetingID: otherMeetingID,
        status: .recording,
        startedAt: now,
        createdAt: now,
        updatedAt: now
    ))

    let targetRecord = BarnOwlRollingTranscriptionRecord(
        sessionID: meetingID,
        trackID: "microphone",
        sequenceNumber: 0,
        trackLabel: "Microphone",
        audioFilePath: "/private/tmp/BarnOwl/AudioChunks/target.wav",
        startTimeOffset: 0,
        modelIdentifier: "model-a",
        status: .completed,
        responseJSON: #"{"segments":[{"text":"private transcript"}]}"#,
        createdAt: now,
        updatedAt: now,
        completedAt: now
    )
    let retainedRecord = BarnOwlRollingTranscriptionRecord(
        sessionID: otherMeetingID,
        trackID: "microphone",
        sequenceNumber: 0,
        trackLabel: "Microphone",
        audioFilePath: "/private/tmp/BarnOwl/AudioChunks/other.wav",
        startTimeOffset: 0,
        modelIdentifier: "model-a",
        status: .completed,
        responseJSON: #"{"segments":[{"text":"other transcript"}]}"#,
        createdAt: now,
        updatedAt: now,
        completedAt: now
    )
    try await database.upsertRollingTranscription(targetRecord)
    try await database.upsertRollingTranscription(retainedRecord)

    try await database.deleteRollingTranscriptions(sessionID: meetingID)

    #expect(try await database.rollingTranscriptions(sessionID: meetingID).isEmpty)
    #expect(try await database.rollingTranscriptions(sessionID: otherMeetingID) == [retainedRecord])
}

@Test
func barnOwlDatabaseStoresExternalContextItems() async throws {
    let database = try BarnOwlDatabase.inMemory()
    let meetingID = UUID(uuidString: "00000000-0000-0000-0000-000000001151")!
    let contextID = UUID(uuidString: "00000000-0000-0000-0000-000000001152")!
    let now = Date(timeIntervalSince1970: 1_800_001_500)

    try await database.upsertMeeting(makeDatabaseMeeting(id: meetingID, title: "Context Review", createdAt: now, updatedAt: now))

    let item = BarnOwlExternalContextItemRecord(
        id: contextID,
        meetingID: meetingID,
        source: "codex",
        body: "Customer: Acme. Goal: draft follow-up.",
        state: .accepted,
        createdAt: now,
        updatedAt: now,
        metadataJSON: #"{"surface":"test"}"#
    )
    try await database.upsertExternalContextItem(item)

    var updated = item
    updated.state = .ignored
    updated.usedInNoteGeneration = true
    updated.updatedAt = now.addingTimeInterval(10)
    try await database.upsertExternalContextItem(updated)

    let reloaded = try #require(await database.externalContextItem(id: contextID))
    let ignoredItems = try await database.externalContextItems(meetingID: meetingID, state: .ignored)
    let acceptedItems = try await database.externalContextItems(meetingID: meetingID, state: .accepted)

    #expect(reloaded == updated)
    #expect(ignoredItems == [updated])
    #expect(acceptedItems.isEmpty)

    try await database.deleteExternalContextItem(id: contextID)
    #expect(try await database.externalContextItems(meetingID: meetingID).isEmpty)
}

@Test
func deletingMeetingCascadesDatabaseRecords() async throws {
    let database = try BarnOwlDatabase.inMemory()
    let meetingID = UUID(uuidString: "00000000-0000-0000-0000-000000001201")!
    let sessionID = UUID(uuidString: "00000000-0000-0000-0000-000000001202")!
    let now = Date(timeIntervalSince1970: 1_800_002_000)

    try await database.upsertMeeting(makeDatabaseMeeting(id: meetingID, title: "Delete Me", createdAt: now, updatedAt: now))
    try await database.upsertRecordingSession(BarnOwlRecordingSessionRecord(
        id: sessionID,
        meetingID: meetingID,
        status: .completed,
        startedAt: now,
        endedAt: now.addingTimeInterval(60),
        createdAt: now,
        updatedAt: now
    ))
    try await database.upsertTranscriptSegment(BarnOwlTranscriptSegmentRecord(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000001203")!,
        meetingID: meetingID,
        sessionID: sessionID,
        variant: .final,
        sequence: 0,
        text: "Delete this transcript.",
        startTime: 0,
        endTime: 1,
        createdAt: now,
        updatedAt: now
    ))
    try await database.upsertMeetingOutput(BarnOwlMeetingOutputRecord(
        meetingID: meetingID,
        kind: "markdown",
        content: "# Delete Me",
        createdAt: now,
        updatedAt: now
    ))

    try await database.deleteMeeting(id: meetingID)

    #expect(try await database.meeting(id: meetingID) == nil)
    #expect(try await database.recordingSessions(meetingID: meetingID).isEmpty)
    #expect(try await database.transcriptSegments(meetingID: meetingID).isEmpty)
    #expect(try await database.meetingOutputs(meetingID: meetingID).isEmpty)
}

@Test
func deletingMeetingCalendarContextKeepsMeetingButRemovesContext() async throws {
    let database = try BarnOwlDatabase.inMemory()
    let meetingID = UUID(uuidString: "00000000-0000-0000-0000-000000001301")!
    let now = Date(timeIntervalSince1970: 1_800_003_000)

    try await database.upsertMeeting(makeDatabaseMeeting(id: meetingID, title: "Calendar Delete", createdAt: now, updatedAt: now))
    try await database.upsertMeetingCalendarContext(BarnOwlMeetingCalendarContextRecord(
        meetingID: meetingID,
        calendarEventID: "event-delete",
        title: "Calendar Delete",
        startsAt: now,
        endsAt: now.addingTimeInterval(1_800),
        attendeesJSON: #"["alex@example.com"]"#,
        rawContextJSON: #"{"provider":"test"}"#,
        createdAt: now,
        updatedAt: now
    ))

    try await database.deleteMeetingCalendarContext(meetingID: meetingID)

    #expect(try await database.meeting(id: meetingID) != nil)
    #expect(try await database.meetingCalendarContext(meetingID: meetingID) == nil)
}

@Test
func meetingStateAggregatesCanonicalDataAcrossTables() async throws {
    let database = try BarnOwlDatabase.inMemory()
    let meetingID = UUID(uuidString: "00000000-0000-0000-0000-000000001601")!
    let sessionID = UUID(uuidString: "00000000-0000-0000-0000-000000001602")!
    let now = Date(timeIntervalSince1970: 1_800_006_000)
    let facts = MeetingFacts(
        title: "Acme Renewal Review",
        meetingType: "Customer Workshop",
        participants: ["Dana", "Lee"],
        customers: ["Acme"],
        projects: ["Renewal"]
    )

    try await database.upsertMeeting(makeDatabaseMeeting(id: meetingID, title: "Original", createdAt: now, updatedAt: now))
    try await database.upsertRecordingSession(BarnOwlRecordingSessionRecord(
        id: sessionID,
        meetingID: meetingID,
        status: .processing,
        startedAt: now,
        endedAt: now.addingTimeInterval(900),
        createdAt: now,
        updatedAt: now
    ))
    try await database.upsertTranscriptSegment(BarnOwlTranscriptSegmentRecord(
        meetingID: meetingID,
        sessionID: sessionID,
        variant: .final,
        sequence: 0,
        speakerLabel: "Dana",
        text: "We decided to send Acme renewal pricing.",
        startTime: 0,
        endTime: 5,
        createdAt: now,
        updatedAt: now
    ))
    try await database.upsertMeetingOutput(BarnOwlMeetingOutputRecord(
        meetingID: meetingID,
        kind: "meeting_facts",
        content: facts.encodedJSONString() ?? "{}",
        contentType: "application/json",
        createdAt: now,
        updatedAt: now
    ))
    try await database.upsertMeetingOutput(BarnOwlMeetingOutputRecord(
        meetingID: meetingID,
        kind: "markdown",
        content: """
        # Acme Renewal Review

        ## Summary
        Renewal pricing needs follow-up.

        ## Decisions
        - Send pricing by Friday.

        ## Action Items
        - Dana will send renewal pricing.

        ## Open Questions
        - Does Acme need a discount?
        """,
        contentType: "text/markdown",
        createdAt: now,
        updatedAt: now
    ))
    try await database.upsertExternalContextItem(BarnOwlExternalContextItemRecord(
        meetingID: meetingID,
        source: "codex",
        body: "Acme renewal risk is pricing.",
        state: .accepted,
        createdAt: now,
        updatedAt: now,
        usedInNoteGeneration: true
    ))
    try await database.upsertJob(BarnOwlJobRecord(
        meetingID: meetingID,
        type: "generate_notes",
        status: .running,
        createdAt: now,
        updatedAt: now
    ))

    let state = try #require(await database.meetingState(id: meetingID))
    #expect(state.id == meetingID)
    #expect(state.title == "Acme Renewal Review")
    #expect(state.status == .processing)
    #expect(state.transcriptText.localizedCaseInsensitiveContains("renewal pricing"))
    #expect(state.meetingFacts?.participants == ["Dana", "Lee"])
    #expect(state.generatedNotes.localizedCaseInsensitiveContains("Renewal pricing"))
    #expect(state.summary?.overview.localizedCaseInsensitiveContains("Renewal pricing") == true)
    #expect(state.decisions.contains("Send pricing by Friday."))
    #expect(state.actionItems.contains("Dana will send renewal pricing."))
    #expect(state.openQuestions.contains("Does Acme need a discount?"))
    #expect(state.externalContextItems.map(\.body).contains("Acme renewal risk is pricing."))
    #expect(state.jobs.first?.type == "generate_notes")
    #expect(state.artifacts.contains { $0.kind == "markdown" })
}

@Test
func updatingMeetingStateTitleUpdatesSearchAndState() async throws {
    let database = try BarnOwlDatabase.inMemory()
    let meetingID = UUID(uuidString: "00000000-0000-0000-0000-000000001701")!
    let now = Date(timeIntervalSince1970: 1_800_007_000)
    let facts = MeetingFacts(title: "Old Title", meetingType: "Planning", participants: ["Dana"])

    try await database.upsertMeeting(makeDatabaseMeeting(id: meetingID, title: "Old Title", createdAt: now, updatedAt: now))
    try await database.upsertMeetingOutput(BarnOwlMeetingOutputRecord(
        meetingID: meetingID,
        kind: "meeting_facts",
        content: facts.encodedJSONString() ?? "{}",
        contentType: "application/json",
        createdAt: now,
        updatedAt: now
    ))

    let updated = try #require(await database.updateMeetingStateTitle(meetingID: meetingID, title: "Barn Owl Roadmap Review"))
    #expect(updated.title == "Barn Owl Roadmap Review")
    #expect(updated.meeting.title == "Barn Owl Roadmap Review")
    #expect(updated.meetingFacts?.title == "Barn Owl Roadmap Review")

    let results = try await database.searchLibrary(BarnOwlDatabaseSearchQuery(text: "roadmap", participant: "Dana", limit: 10))
    #expect(results.first?.meeting.id == meetingID)
}

@Test
func updatingMeetingStateNotesDoesNotOverwriteCanonicalFacts() async throws {
    let database = try BarnOwlDatabase.inMemory()
    let meetingID = UUID(uuidString: "00000000-0000-0000-0000-000000001801")!
    let now = Date(timeIntervalSince1970: 1_800_008_000)
    let facts = MeetingFacts(
        title: "Canonical Customer Workshop",
        meetingType: "Customer Workshop",
        participants: ["Dana", "Lee"]
    )

    try await database.upsertMeeting(makeDatabaseMeeting(id: meetingID, title: "Canonical Customer Workshop", createdAt: now, updatedAt: now))
    try await database.upsertMeetingOutput(BarnOwlMeetingOutputRecord(
        meetingID: meetingID,
        kind: "meeting_facts",
        content: facts.encodedJSONString() ?? "{}",
        contentType: "application/json",
        createdAt: now,
        updatedAt: now
    ))

    let editedMarkdown = """
    # User Edited Markdown

    Meeting Type: One-on-One

    ## Participants
    - Alex

    ## Summary
    Markdown was edited by hand.
    """
    let updated = try #require(await database.updateMeetingStateNotes(meetingID: meetingID, markdown: editedMarkdown))
    #expect(updated.generatedNotes == editedMarkdown)
    #expect(updated.meetingFacts?.title == "Canonical Customer Workshop")
    #expect(updated.meetingFacts?.meetingType == "Customer Workshop")
    #expect(updated.meetingFacts?.participants == ["Dana", "Lee"])
}

@Test
func oldMarkdownBackfillsMeetingStateFacts() async throws {
    let database = try BarnOwlDatabase.inMemory()
    let meetingID = UUID(uuidString: "00000000-0000-0000-0000-000000001901")!
    let now = Date(timeIntervalSince1970: 1_800_009_000)

    try await database.upsertMeeting(makeDatabaseMeeting(id: meetingID, title: "Old Markdown Meeting", createdAt: now, updatedAt: now))
    try await database.upsertMeetingOutput(BarnOwlMeetingOutputRecord(
        meetingID: meetingID,
        kind: "markdown",
        content: """
        # Old Markdown Meeting

        Meeting Type: Interview

        ## Participants
        - Dana
        - Lee

        ## Action Items
        - Send follow-up.
        """,
        createdAt: now,
        updatedAt: now
    ))

    let state = try #require(await database.meetingState(id: meetingID))
    #expect(state.meetingFacts?.title == "Old Markdown Meeting")
    #expect(state.meetingFacts?.meetingType == "Interview")
    #expect(state.meetingFacts?.participants == ["Dana", "Lee"])
    #expect(state.actionItems == ["Send follow-up."])
}

@Test
func searchLibraryFindsTranscriptNotesAndFiltersMetadata() async throws {
    let database = try BarnOwlDatabase.inMemory()
    let meetingID = UUID(uuidString: "00000000-0000-0000-0000-000000001401")!
    let sessionID = UUID(uuidString: "00000000-0000-0000-0000-000000001402")!
    let now = Date(timeIntervalSince1970: 1_800_004_000)

    try await database.upsertMeeting(makeDatabaseMeeting(
        id: meetingID,
        title: "Acme Customer Workshop",
        createdAt: now,
        updatedAt: now,
        metadataJSON: #"{"meetingType":"Customer Workshop"}"#
    ))
    try await database.upsertRecordingSession(BarnOwlRecordingSessionRecord(
        id: sessionID,
        meetingID: meetingID,
        status: .completed,
        startedAt: now,
        endedAt: now.addingTimeInterval(1_200),
        createdAt: now,
        updatedAt: now
    ))
    try await database.upsertTranscriptSegment(BarnOwlTranscriptSegmentRecord(
        meetingID: meetingID,
        sessionID: sessionID,
        variant: .final,
        sequence: 0,
        speakerLabel: "Dana",
        text: "We decided to send the implementation plan to Acme.",
        startTime: 0,
        endTime: 4,
        createdAt: now,
        updatedAt: now
    ))
    try await database.upsertMeetingOutput(BarnOwlMeetingOutputRecord(
        meetingID: meetingID,
        kind: "markdown",
        content: """
        # Acme Customer Workshop

        Meeting Type: Customer Workshop

        ## Participants
        - Dana
        - Lee

        ## Action Items
        - Send implementation plan.
        """,
        createdAt: now,
        updatedAt: now
    ))

    let results = try await database.searchLibrary(BarnOwlDatabaseSearchQuery(
        text: "implementation plan",
        meetingType: "customer",
        participant: "Dana",
        status: .completed,
        limit: 10
    ))

    let result = try #require(results.first)
    #expect(result.meeting.id == meetingID)
    #expect(result.meetingType == "Customer Workshop")
    #expect(result.status == .completed)
    #expect(result.matchedFields.contains("markdown") || result.matchedFields.contains("transcript"))
    #expect(result.snippet.localizedCaseInsensitiveContains("implementation plan"))
}

@Test
func searchLibraryUsesCanonicalMeetingFacts() async throws {
    let database = try BarnOwlDatabase.inMemory()
    let meetingID = UUID(uuidString: "00000000-0000-0000-0000-000000001501")!
    let now = Date(timeIntervalSince1970: 1_800_005_000)
    let facts = MeetingFacts(
        title: "Acme Rollout Planning",
        meetingType: "Customer Workshop",
        participants: ["Dana", "Lee"],
        customers: ["Acme"],
        projects: ["Acme rollout planning"]
    )

    try await database.upsertMeeting(makeDatabaseMeeting(
        id: meetingID,
        title: "Acme Rollout Planning",
        createdAt: now,
        updatedAt: now
    ))
    try await database.upsertMeetingOutput(BarnOwlMeetingOutputRecord(
        meetingID: meetingID,
        kind: "markdown",
        content: "# Acme Rollout Planning\n\n## Summary\nPlanning notes.",
        createdAt: now,
        updatedAt: now
    ))
    try await database.upsertMeetingOutput(BarnOwlMeetingOutputRecord(
        meetingID: meetingID,
        kind: "meeting_facts",
        content: facts.encodedJSONString() ?? "{}",
        contentType: "application/json",
        createdAt: now,
        updatedAt: now
    ))

    let results = try await database.searchLibrary(BarnOwlDatabaseSearchQuery(
        text: "Acme",
        meetingType: "workshop",
        participant: "Lee",
        limit: 10
    ))

    let result = try #require(results.first)
    #expect(result.meeting.id == meetingID)
    #expect(result.meetingType == "Customer Workshop")
    #expect(result.matchedFields.contains("meeting-facts"))
}

@Test
func meetingTitleAndPromptUpdatesCreateVersions() async throws {
    let database = try BarnOwlDatabase.inMemory()
    let meetingID = UUID(uuidString: "00000000-0000-0000-0000-000000001601")!
    let now = Date(timeIntervalSince1970: 1_800_006_000)

    try await database.upsertMeeting(makeDatabaseMeeting(id: meetingID, title: "Original", createdAt: now, updatedAt: now))
    try await database.upsertMeetingOutput(BarnOwlMeetingOutputRecord(
        meetingID: meetingID,
        kind: "markdown",
        content: "# Original\n\n## Summary\nOld notes.",
        createdAt: now,
        updatedAt: now
    ))

    _ = try #require(await database.updateMeetingStateTitle(
        meetingID: meetingID,
        title: "Renamed Meeting",
        actor: .user
    ))
    _ = try #require(await database.updateMeetingStateNotes(
        meetingID: meetingID,
        markdown: "# Renamed Meeting\n\n## Summary\nUpdated notes.",
        actor: .ai,
        changeType: .promptUpdate,
        summary: "Updated notes from prompt."
    ))

    let versions = try await database.meetingVersions(meetingID: meetingID)
    #expect(versions.count == 2)
    #expect(versions.map(\.changeType).contains(.titleRename))
    #expect(versions.map(\.changeType).contains(.promptUpdate))
    #expect(versions.first { $0.changeType == .promptUpdate }?.beforeSnapshot?.generatedNotes.contains("Old notes") == true)
    #expect(versions.first { $0.changeType == .promptUpdate }?.afterSnapshot?.generatedNotes.contains("Updated notes") == true)
}

@Test
func meetingFactsUpdateCreatesVersionAndRestoreRevertsCanonicalState() async throws {
    let database = try BarnOwlDatabase.inMemory()
    let meetingID = UUID(uuidString: "00000000-0000-0000-0000-000000001602")!
    let now = Date(timeIntervalSince1970: 1_800_006_100)

    try await database.upsertMeeting(makeDatabaseMeeting(id: meetingID, title: "Original", createdAt: now, updatedAt: now))
    try await database.upsertMeetingOutput(BarnOwlMeetingOutputRecord(
        meetingID: meetingID,
        kind: "markdown",
        content: "# Original\n\n## Summary\nOld notes.",
        createdAt: now,
        updatedAt: now
    ))

    _ = try #require(await database.updateMeetingStateFacts(
        meetingID: meetingID,
        facts: MeetingFacts(
            title: "Acme Workshop",
            meetingType: "Customer Workshop",
            participants: ["Dana"],
            customers: ["Acme"]
        ),
        actor: .user,
        changeType: .meetingFactsUpdate,
        summary: "Updated meeting facts."
    ))
    _ = try #require(await database.updateMeetingStateNotes(
        meetingID: meetingID,
        markdown: "# Acme Workshop\n\n## Summary\nNew notes.",
        actor: .ai,
        changeType: .promptUpdate,
        summary: "Updated notes from prompt."
    ))

    let versions = try await database.meetingVersions(meetingID: meetingID)
    let promptVersion = try #require(versions.first { $0.changeType == .promptUpdate })
    let restored = try #require(await database.restoreMeetingVersion(id: promptVersion.id))

    #expect(restored.generatedNotes.contains("Old notes"))
    #expect(restored.title == "Acme Workshop")
    #expect(restored.meetingFacts?.customers == ["Acme"])

    let afterRestore = try await database.meetingVersions(meetingID: meetingID)
    #expect(afterRestore.first?.changeType == .restore)
}

@Test
func failedUpdateDoesNotCreateSuccessfulVersion() async throws {
    let database = try BarnOwlDatabase.inMemory()
    let missingID = UUID(uuidString: "00000000-0000-0000-0000-000000001603")!

    let updated = try await database.updateMeetingStateNotes(
        meetingID: missingID,
        markdown: "# Missing",
        actor: .ai,
        changeType: .promptUpdate
    )

    #expect(updated == nil)
    #expect(try await database.meetingVersions(meetingID: missingID).isEmpty)
}

@Test
func processingTimelineDerivesFromDurableJobState() async throws {
    let database = try BarnOwlDatabase.inMemory()
    let meetingID = UUID(uuidString: "00000000-0000-0000-0000-000000001701")!
    let now = Date(timeIntervalSince1970: 1_800_007_000)
    try await database.upsertMeeting(makeDatabaseMeeting(id: meetingID, title: "Processing", createdAt: now, updatedAt: now))
    try await database.upsertRecordingSession(BarnOwlRecordingSessionRecord(
        id: meetingID,
        meetingID: meetingID,
        status: .processing,
        startedAt: now,
        endedAt: now.addingTimeInterval(60),
        createdAt: now,
        updatedAt: now.addingTimeInterval(60)
    ))
    try await database.upsertJob(BarnOwlJobRecord(
        meetingID: meetingID,
        type: "final_processing",
        status: .running,
        createdAt: now,
        updatedAt: now.addingTimeInterval(65),
        startedAt: now.addingTimeInterval(62)
    ))

    let timeline = try #require(await database.meetingState(id: meetingID)).processingTimeline

    #expect(timeline.first { $0.step == .recorded }?.status == .complete)
    #expect(timeline.first { $0.step == .transcribing }?.status == .running)
    #expect(timeline.first { $0.step == .writingNotes }?.status == .pending)
}

@Test
func failedProcessingJobShowsFailedTimelineStepAndRetryCandidate() async throws {
    let database = try BarnOwlDatabase.inMemory()
    let meetingID = UUID(uuidString: "00000000-0000-0000-0000-000000001702")!
    let now = Date(timeIntervalSince1970: 1_800_007_100)
    try await database.upsertMeeting(makeDatabaseMeeting(id: meetingID, title: "Failed", createdAt: now, updatedAt: now))
    try await database.upsertRecordingSession(BarnOwlRecordingSessionRecord(
        id: meetingID,
        meetingID: meetingID,
        status: .processing,
        startedAt: now,
        endedAt: now.addingTimeInterval(30),
        createdAt: now,
        updatedAt: now.addingTimeInterval(30)
    ))
    try await database.upsertJob(BarnOwlJobRecord(
        meetingID: meetingID,
        type: "final_processing",
        status: .failed,
        errorMessage: "No audio chunks found.",
        createdAt: now,
        updatedAt: now.addingTimeInterval(40),
        startedAt: now.addingTimeInterval(31),
        completedAt: now.addingTimeInterval(40)
    ))

    let timeline = try #require(await database.meetingState(id: meetingID)).processingTimeline
    let failed = try #require(timeline.first { $0.status == .failed })

    #expect(failed.step == .transcribing)
    #expect(failed.errorMessage == "No audio chunks found.")
}

@Test
func completedProcessingTimelineCollapsesCleanly() async throws {
    let database = try BarnOwlDatabase.inMemory()
    let meetingID = UUID(uuidString: "00000000-0000-0000-0000-000000001703")!
    let now = Date(timeIntervalSince1970: 1_800_007_200)
    let facts = MeetingFacts(title: "Complete", meetingType: "General Discussion", participants: ["Dana"])
    try await database.upsertMeeting(makeDatabaseMeeting(id: meetingID, title: "Complete", createdAt: now, updatedAt: now))
    try await database.upsertRecordingSession(BarnOwlRecordingSessionRecord(
        id: meetingID,
        meetingID: meetingID,
        status: .completed,
        startedAt: now,
        endedAt: now.addingTimeInterval(60),
        createdAt: now,
        updatedAt: now.addingTimeInterval(120)
    ))
    try await database.upsertTranscriptSegment(BarnOwlTranscriptSegmentRecord(
        meetingID: meetingID,
        sessionID: meetingID,
        sequence: 0,
        speakerLabel: "Dana",
        text: "Done.",
        startTime: 0,
        endTime: 1,
        createdAt: now,
        updatedAt: now
    ))
    try await database.upsertMeetingOutput(BarnOwlMeetingOutputRecord(
        meetingID: meetingID,
        kind: "meeting_facts",
        content: facts.encodedJSONString() ?? "{}",
        contentType: "application/json",
        createdAt: now,
        updatedAt: now
    ))
    try await database.upsertMeetingOutput(BarnOwlMeetingOutputRecord(
        meetingID: meetingID,
        kind: "markdown",
        content: "# Complete\n\n## Summary\nDone.",
        createdAt: now,
        updatedAt: now
    ))
    try await database.upsertJob(BarnOwlJobRecord(
        meetingID: meetingID,
        type: "final_processing",
        status: .succeeded,
        createdAt: now,
        updatedAt: now.addingTimeInterval(120),
        startedAt: now.addingTimeInterval(61),
        completedAt: now.addingTimeInterval(120)
    ))

    let timeline = try #require(await database.meetingState(id: meetingID)).processingTimeline

    #expect(timeline.allSatisfy { $0.status == .complete })
    #expect(BarnOwlProcessingTimeline.shouldCollapse(timeline))
}

@Test
func completedMeetingWithNotesDoesNotShowStaleFailedProcessingTimeline() async throws {
    let database = try BarnOwlDatabase.inMemory()
    let meetingID = UUID(uuidString: "00000000-0000-0000-0000-000000001713")!
    let now = Date(timeIntervalSince1970: 1_800_007_250)
    try await database.upsertMeeting(makeDatabaseMeeting(id: meetingID, title: "Completed Notes", createdAt: now, updatedAt: now))
    try await database.upsertRecordingSession(BarnOwlRecordingSessionRecord(
        id: meetingID,
        meetingID: meetingID,
        status: .completed,
        startedAt: now,
        endedAt: now.addingTimeInterval(45),
        createdAt: now,
        updatedAt: now.addingTimeInterval(90)
    ))
    try await database.upsertMeetingOutput(BarnOwlMeetingOutputRecord(
        meetingID: meetingID,
        kind: "markdown",
        content: "# Completed Notes\n\n## Summary\nDone.",
        createdAt: now,
        updatedAt: now.addingTimeInterval(80)
    ))
    try await database.upsertJob(BarnOwlJobRecord(
        meetingID: meetingID,
        type: "final_processing",
        status: .failed,
        errorMessage: "Stale callback after notes were written.",
        createdAt: now,
        updatedAt: now.addingTimeInterval(120),
        startedAt: now.addingTimeInterval(46),
        completedAt: now.addingTimeInterval(120)
    ))

    let timeline = try #require(await database.meetingState(id: meetingID)).processingTimeline

    #expect(timeline.allSatisfy { $0.status == .complete })
    #expect(BarnOwlProcessingTimeline.shouldCollapse(timeline))
}

@Test
func processingTimelineSurvivesDatabaseRelaunch() async throws {
    let directory = try makeSQLiteTempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let databaseURL = directory.appending(path: "barnowl.sqlite")
    let meetingID = UUID(uuidString: "00000000-0000-0000-0000-000000001704")!
    let now = Date(timeIntervalSince1970: 1_800_007_300)

    do {
        let database = try BarnOwlDatabase(url: databaseURL)
        try await database.upsertMeeting(makeDatabaseMeeting(id: meetingID, title: "Relaunch", createdAt: now, updatedAt: now))
        try await database.upsertRecordingSession(BarnOwlRecordingSessionRecord(
            id: meetingID,
            meetingID: meetingID,
            status: .processing,
            startedAt: now,
            endedAt: now.addingTimeInterval(20),
            createdAt: now,
            updatedAt: now.addingTimeInterval(20)
        ))
        try await database.upsertJob(BarnOwlJobRecord(
            meetingID: meetingID,
            type: "final_processing",
            status: .pending,
            createdAt: now,
            updatedAt: now.addingTimeInterval(21),
            scheduledAt: now.addingTimeInterval(30)
        ))
    }

    let reopened = try BarnOwlDatabase(url: databaseURL)
    let timeline = try #require(await reopened.meetingState(id: meetingID)).processingTimeline

    #expect(timeline.first { $0.step == .recorded }?.status == .complete)
    #expect(timeline.first { $0.step == .transcribing }?.status == .pending)
}

@Test
func singletonMeetingOutputsReplaceExistingRows() async throws {
    let database = try BarnOwlDatabase.inMemory()
    let meetingID = UUID(uuidString: "00000000-0000-0000-0000-000000001805")!
    let now = Date(timeIntervalSince1970: 1_800_008_500)

    try await database.upsertMeeting(makeDatabaseMeeting(id: meetingID, title: "Singleton Outputs", createdAt: now, updatedAt: now))
    try await database.replaceMeetingOutput(BarnOwlMeetingOutputRecord(
        meetingID: meetingID,
        kind: "realtime_preview",
        content: "first preview",
        createdAt: now,
        updatedAt: now
    ))
    try await database.replaceMeetingOutput(BarnOwlMeetingOutputRecord(
        meetingID: meetingID,
        kind: "realtime_preview",
        content: "second preview",
        createdAt: now.addingTimeInterval(1),
        updatedAt: now.addingTimeInterval(1)
    ))

    let outputs = try await database.meetingOutputs(meetingID: meetingID, kind: "realtime_preview")
    let state = try #require(await database.meetingState(id: meetingID))

    #expect(outputs.count == 1)
    #expect(outputs.first?.content == "second preview")
    #expect(state.realtimePreview == "second preview")
}

@Test
func meetingStateFallsBackToLiveTranscriptWhenFinalTranscriptIsEmpty() async throws {
    let database = try BarnOwlDatabase.inMemory()
    let meetingID = UUID(uuidString: "00000000-0000-0000-0000-000000001806")!
    let now = Date(timeIntervalSince1970: 1_800_008_600)

    try await database.upsertMeeting(makeDatabaseMeeting(id: meetingID, title: "Live Fallback", createdAt: now, updatedAt: now))
    try await database.upsertRecordingSession(BarnOwlRecordingSessionRecord(
        id: meetingID,
        meetingID: meetingID,
        status: .recording,
        startedAt: now,
        createdAt: now,
        updatedAt: now
    ))
    try await database.upsertTranscriptSegment(BarnOwlTranscriptSegmentRecord(
        meetingID: meetingID,
        sessionID: meetingID,
        variant: .live,
        sequence: 0,
        speakerLabel: "Realtime",
        text: "Realtime fallback text",
        startTime: 0,
        endTime: 3,
        createdAt: now,
        updatedAt: now
    ))

    let state = try #require(await database.meetingState(id: meetingID))

    #expect(state.transcriptSegments.map(\.variant) == [.live])
    #expect(state.transcriptText.contains("Realtime fallback text"))
}

@Test
func processingTimelineUsesPersistedRunningStage() async throws {
    let database = try BarnOwlDatabase.inMemory()
    let meetingID = UUID(uuidString: "00000000-0000-0000-0000-000000001807")!
    let now = Date(timeIntervalSince1970: 1_800_008_700)

    try await database.upsertMeeting(makeDatabaseMeeting(id: meetingID, title: "Stage Timeline", createdAt: now, updatedAt: now))
    try await database.upsertRecordingSession(BarnOwlRecordingSessionRecord(
        id: meetingID,
        meetingID: meetingID,
        status: .processing,
        startedAt: now,
        endedAt: now.addingTimeInterval(60),
        createdAt: now,
        updatedAt: now.addingTimeInterval(60)
    ))
    try await database.upsertJob(BarnOwlJobRecord(
        meetingID: meetingID,
        type: "final_processing",
        status: .running,
        createdAt: now,
        updatedAt: now.addingTimeInterval(61),
        startedAt: now.addingTimeInterval(61)
    ))
    try await database.replaceMeetingOutput(BarnOwlMeetingOutputRecord(
        meetingID: meetingID,
        kind: "processing_stage",
        content: "writing_notes",
        createdAt: now.addingTimeInterval(62),
        updatedAt: now.addingTimeInterval(62)
    ))

    let timeline = try #require(await database.meetingState(id: meetingID)).processingTimeline

    #expect(timeline.first { $0.step == .recorded }?.status == .complete)
    #expect(timeline.first { $0.step == .transcribing }?.status == .complete)
    #expect(timeline.first { $0.step == .writingNotes }?.status == .running)
    #expect(timeline.first { $0.step == .exportingMarkdown }?.status == .pending)
}

private func makeDatabaseMeeting(
    id: UUID = UUID(uuidString: "00000000-0000-0000-0000-000000001000")!,
    title: String,
    createdAt: Date = Date(timeIntervalSince1970: 1_800_000_000),
    updatedAt: Date = Date(timeIntervalSince1970: 1_800_000_000),
    metadataJSON: String? = nil
) -> BarnOwlMeetingRecord {
    BarnOwlMeetingRecord(
        id: id,
        externalID: "calendar-\(id.uuidString.lowercased())",
        title: title,
        startedAt: createdAt.addingTimeInterval(60),
        endedAt: createdAt.addingTimeInterval(600),
        createdAt: createdAt,
        updatedAt: updatedAt,
        metadataJSON: metadataJSON
    )
}

private func makeSQLiteTempDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appending(path: "BarnOwlSQLiteTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

private func posixPermissions(at url: URL) throws -> Int {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false))
    if let permissions = attributes[.posixPermissions] as? NSNumber {
        return permissions.intValue & 0o777
    }
    return (attributes[.posixPermissions] as? Int ?? 0) & 0o777
}

import BarnOwlCore
import Foundation
import Testing

@Test
func controlCommandDecodesSnakeCaseCommandPayload() throws {
    let data = Data(
        """
        {
          "command": "append_context",
          "sessionID": "00000000-0000-0000-0000-00000000C001",
          "context": "Customer is Acme.",
          "source": "codex"
        }
        """.utf8
    )

    let command = try JSONDecoder().decode(BarnOwlControlCommand.self, from: data)

    #expect(command.command == .appendContext)
    #expect(command.sessionID == UUID(uuidString: "00000000-0000-0000-0000-00000000C001"))
    #expect(command.context == "Customer is Acme.")
    #expect(command.source == "codex")
}

@Test
func controlResponseEncodesMachineReadableStatus() throws {
    let response = BarnOwlControlResponse(
        ok: true,
        message: "Recording started.",
        status: "Recording",
        sessionID: UUID(uuidString: "00000000-0000-0000-0000-00000000C002"),
        title: "Roadmap Review",
        realtimeStatus: "Realtime transcription streaming.",
        finalTranscriptionStatus: "Processing saved chunks while you record."
    )

    let data = try JSONEncoder().encode(response)
    let decoded = try JSONDecoder().decode(BarnOwlControlResponse.self, from: data)

    #expect(decoded == response)
}

@Test
func readCommandsDecodeMeetingSearchPayload() throws {
    let data = Data(
        """
        {
          "command": "meetings_search",
          "query": "acme pricing",
          "limit": 10,
          "format": "json"
        }
        """.utf8
    )

    let command = try JSONDecoder().decode(BarnOwlControlCommand.self, from: data)

    #expect(command.command == .meetingsSearch)
    #expect(command.query == "acme pricing")
    #expect(command.limit == 10)
    #expect(command.format == "json")
}

@Test
func codexPrimaryControlCommandsDecodePayloads() throws {
    let data = Data(
        """
        {
          "command": "wait",
          "sessionID": "00000000-0000-0000-0000-00000000C020",
          "until": "complete",
          "latest": false
        }
        """.utf8
    )

    let command = try JSONDecoder().decode(BarnOwlControlCommand.self, from: data)

    #expect(command.command == .wait)
    #expect(command.sessionID == UUID(uuidString: "00000000-0000-0000-0000-00000000C020"))
    #expect(command.until == "complete")
    #expect(command.latest == false)
}

@Test
func jobContextAndAdminCommandsDecodePayloads() throws {
    let jobID = UUID(uuidString: "00000000-0000-0000-0000-00000000C021")!
    let contextID = UUID(uuidString: "00000000-0000-0000-0000-00000000C022")!
    let meetingID = UUID(uuidString: "00000000-0000-0000-0000-00000000C023")!

    let retry = try JSONDecoder().decode(
        BarnOwlControlCommand.self,
        from: Data(#"{"command":"jobs_retry","jobID":"\#(jobID.uuidString)"}"#.utf8)
    )
    let accept = try JSONDecoder().decode(
        BarnOwlControlCommand.self,
        from: Data(#"{"command":"context_accept","contextItemID":"\#(contextID.uuidString)"}"#.utf8)
    )
    let delete = try JSONDecoder().decode(
        BarnOwlControlCommand.self,
        from: Data(#"{"command":"meeting_delete","meetingID":"\#(meetingID.uuidString)","confirmed":true}"#.utf8)
    )

    #expect(retry.command == .jobsRetry)
    #expect(retry.jobID == jobID)
    #expect(accept.command == .contextAccept)
    #expect(accept.contextItemID == contextID)
    #expect(delete.command == .meetingDelete)
    #expect(delete.meetingID == meetingID)
    #expect(delete.confirmed == true)
}

@Test
func bridgeCurrentCommandDecodesProductAlias() throws {
    let data = Data(#"{"command":"current"}"#.utf8)

    let command = try JSONDecoder().decode(BarnOwlControlCommand.self, from: data)

    #expect(command.command == .current)
}

@Test
func controlCommandNameIncludesCodexPrimaryCases() {
    let names = Set(BarnOwlControlCommandName.allCases.map(\.rawValue))

    #expect(names.contains("wait"))
    #expect(names.contains("jobs_list"))
    #expect(names.contains("jobs_retry"))
    #expect(names.contains("jobs_dismiss"))
    #expect(names.contains("context_list"))
    #expect(names.contains("context_accept"))
    #expect(names.contains("context_ignore"))
    #expect(names.contains("context_delete"))
    #expect(names.contains("meeting_delete"))
    #expect(names.contains("meeting_purge_temp_audio"))
    #expect(names.contains("diagnostics_export"))
}

@Test
func diagnosticsExportCommandDecodesOutputPath() throws {
    let data = Data(
        """
        {
          "command": "diagnostics_export",
          "outputPath": "/tmp/BarnOwl-diagnostics.md"
        }
        """.utf8
    )

    let command = try JSONDecoder().decode(BarnOwlControlCommand.self, from: data)

    #expect(command.command == .diagnosticsExport)
    #expect(command.outputPath == "/tmp/BarnOwl-diagnostics.md")
}

@Test
func quickCommandAliasesRouteToSharedCommandModel() throws {
    let data = Data(
        """
        {
          "command": "rename_meeting",
          "meetingID": "00000000-0000-0000-0000-00000000C010",
          "title": "Acme Renewal Review"
        }
        """.utf8
    )

    let command = try JSONDecoder().decode(BarnOwlControlCommand.self, from: data)
    let quickCommand = try #require(command.quickCommand)

    #expect(quickCommand.name == .renameMeeting)
    #expect(quickCommand.meetingID == UUID(uuidString: "00000000-0000-0000-0000-00000000C010"))
    #expect(quickCommand.title == "Acme Renewal Review")
}

@Test
func quickCommandStartPreservesTitleContextAndMeetingType() {
    let command = BarnOwlControlCommand(
        command: .startRecording,
        title: "Roadmap",
        meetingType: "Planning / Review",
        context: "Discuss V1 command layer.",
        source: "codex"
    )

    let quickCommand = command.quickCommand

    #expect(quickCommand?.name == .startRecording)
    #expect(quickCommand?.title == "Roadmap")
    #expect(quickCommand?.meetingType == "Planning / Review")
    #expect(quickCommand?.context == "Discuss V1 command layer.")
    #expect(quickCommand?.source == "codex")
}

@Test
func controlResponseCarriesQuickCommandStatusFields() throws {
    let meetingID = UUID(uuidString: "00000000-0000-0000-0000-00000000C011")!
    let response = BarnOwlControlResponse(
        ok: false,
        message: "No active recording to stop.",
        activeMeetingID: meetingID,
        jobState: "failed",
        errorCode: "no_active_recording"
    )

    let data = try JSONEncoder().encode(response)
    let decoded = try JSONDecoder().decode(BarnOwlControlResponse.self, from: data)

    #expect(decoded == response)
}

@Test
func meetingReadResponseCanCarryNotesActionsAndContext() throws {
    let meetingID = UUID(uuidString: "00000000-0000-0000-0000-00000000C003")!
    let contextID = UUID(uuidString: "00000000-0000-0000-0000-00000000C004")!
    let response = BarnOwlControlResponse(
        ok: true,
        message: "Barn Owl meeting.",
        meeting: BarnOwlControlMeeting(
            id: meetingID,
            title: "Acme Pricing",
            overview: "Discussed pricing.",
            meetingType: "Customer Workshop",
            status: "completed"
        ),
        notes: "# Acme Pricing",
        contextItems: [
            BarnOwlControlContextItem(
                id: contextID,
                meetingID: meetingID,
                source: "codex",
                body: "Acme is evaluating annual pricing.",
                state: "accepted",
                createdAt: Date(timeIntervalSince1970: 1_800_000_000)
            )
        ],
        actions: ["Send proposal."],
        decisions: ["Use annual plan."]
    )

    let data = try JSONEncoder().encode(response)
    let decoded = try JSONDecoder().decode(BarnOwlControlResponse.self, from: data)

    #expect(decoded == response)
}

@Test
func controlResponseCarriesCodexPrimaryStatusJobsAndReadiness() throws {
    let meetingID = UUID(uuidString: "00000000-0000-0000-0000-00000000C030")!
    let jobID = UUID(uuidString: "00000000-0000-0000-0000-00000000C031")!
    let response = BarnOwlControlResponse(
        ok: true,
        message: "Barn Owl status.",
        status: "Idle",
        appStatus: "running",
        bridgeStatus: "running",
        recordingStatus: "idle",
        meetingID: meetingID,
        activeMeetingID: meetingID,
        title: "Roadmap Review",
        jobs: [
            BarnOwlControlJob(
                id: jobID,
                meetingID: meetingID,
                type: "final_processing",
                status: "failed",
                attemptCount: 3,
                errorMessage: "No recorded audio files.",
                updatedAt: Date(timeIntervalSince1970: 1_800_000_100)
            )
        ],
        jobState: "failed",
        readinessState: "ready",
        setupReady: true,
        apiKeyConfigured: true,
        apiKeyVerified: true,
        notesReady: false,
        transcriptReady: true,
        summaryReady: false,
        markdownPath: "/tmp/meeting.md",
        diagnosticsPath: "/tmp/BarnOwl-diagnostics.md",
        lastError: "No recorded audio files.",
        nextCommand: "barnowl jobs retry --session \(meetingID.uuidString)",
        feedbackSuggested: true,
        feedbackCommand: "barnowl feedback slack --yes",
        feedbackReason: "Review redacted details before posting."
    )

    let data = try JSONEncoder().encode(response)
    let decoded = try JSONDecoder().decode(BarnOwlControlResponse.self, from: data)

    #expect(decoded == response)
    #expect(decoded.jobs?.first?.status == "failed")
    #expect(decoded.diagnosticsPath == "/tmp/BarnOwl-diagnostics.md")
    #expect(decoded.nextCommand?.contains("jobs retry") == true)
    #expect(decoded.feedbackSuggested == true)
    #expect(decoded.feedbackCommand == "barnowl feedback slack --yes")
}

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
func dashboardSnapshotResponseEncodesWidgetPayload() throws {
    let dashboard = BarnOwlControlDashboardSnapshot(
        status: "Recording",
        recordingStatus: "recording",
        activeMeetingID: UUID(uuidString: "00000000-0000-0000-0000-00000000D001"),
        title: "Roadmap Review",
        meetingType: "Team Meeting",
        audioSources: BarnOwlControlAudioSources(capturesMicrophone: true, capturesSystemAudio: false),
        liveTranscriptPreview: "Current preview",
        captureStatus: "Capturing microphone audio.",
        realtimeStatus: "Realtime connected.",
        finalTranscriptionStatus: "Final pass queued.",
        recordingElapsedText: "01:42",
        readinessState: "ready",
        setupReady: true,
        apiKeyConfigured: true,
        apiKeyVerified: true,
        updateStatus: "Updater idle.",
        updateAvailability: "Barn Owl is up to date.",
        isUpdateInFlight: false,
        recentMeetings: [],
        jobState: "running",
        contextReviewReady: false,
        lastError: nil
    )
    let response = BarnOwlControlResponse(
        ok: true,
        message: "Barn Owl dashboard snapshot.",
        dashboard: dashboard
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
func contextReviewCommandsDecodeMeetingAndReviewedContext() throws {
    let meetingID = UUID(uuidString: "00000000-0000-0000-0000-00000000C024")!
    let read = try JSONDecoder().decode(
        BarnOwlControlCommand.self,
        from: Data(#"{"command":"meeting_context_review","meetingID":"\#(meetingID.uuidString)"}"#.utf8)
    )
    let apply = try JSONDecoder().decode(
        BarnOwlControlCommand.self,
        from: Data(#"{"command":"meeting_context_review_apply","meetingID":"\#(meetingID.uuidString)","context":"Collin is spelled with two l's."}"#.utf8)
    )
    let dismiss = try JSONDecoder().decode(
        BarnOwlControlCommand.self,
        from: Data(#"{"command":"meeting_context_review_dismiss","meetingID":"\#(meetingID.uuidString)"}"#.utf8)
    )
    let suggestionID = UUID(uuidString: "00000000-0000-0000-0000-00000000C025")!
    let acceptSuggestion = try JSONDecoder().decode(
        BarnOwlControlCommand.self,
        from: Data(#"{"command":"meeting_context_review_accept_suggestion","meetingID":"\#(meetingID.uuidString)","suggestionID":"\#(suggestionID.uuidString)"}"#.utf8)
    )
    let ignoreSuggestion = try JSONDecoder().decode(
        BarnOwlControlCommand.self,
        from: Data(#"{"command":"meeting_context_review_ignore_suggestion","meetingID":"\#(meetingID.uuidString)","suggestionID":"\#(suggestionID.uuidString)"}"#.utf8)
    )

    #expect(read.command == .meetingContextReview)
    #expect(read.meetingID == meetingID)
    #expect(apply.command == .meetingContextReviewApply)
    #expect(apply.context == "Collin is spelled with two l's.")
    #expect(dismiss.command == .meetingContextReviewDismiss)
    #expect(acceptSuggestion.command == .meetingContextReviewAcceptSuggestion)
    #expect(acceptSuggestion.suggestionID == suggestionID)
    #expect(ignoreSuggestion.command == .meetingContextReviewIgnoreSuggestion)
    #expect(ignoreSuggestion.suggestionID == suggestionID)
}

@Test
func structuredMeetingContextImportDecodesMeetingFactsPayload() throws {
    let meetingID = UUID(uuidString: "00000000-0000-0000-0000-00000000C027")!
    let command = try JSONDecoder().decode(
        BarnOwlControlCommand.self,
        from: Data(
            #"""
            {
              "command":"meeting_structured_context_import",
              "meetingID":"\#(meetingID.uuidString)",
              "source":"codex",
              "confidence":0.97,
              "meetingFacts":{
                "title":"Moderna: Rosalind Pricing",
                "meetingType":"Customer Review",
                "participants":["Collin Burdick"],
                "organizations":["OpenAI"],
                "customers":["Moderna"],
                "projects":["Rosalind"],
                "glossary":{"API":"Application Programming Interface"},
                "goals":["Confirm next steps"],
                "additionalContext":["Imported from Codex enrichment."],
                "confidence":{
                  "title":0.97,
                  "meetingType":0.97,
                  "participants":0.97,
                  "organizations":0.97,
                  "context":0.97
                },
                "sources":{"title":"structured_import:codex"}
              }
            }
            """#.utf8
        )
    )

    #expect(command.command == .meetingStructuredContextImport)
    #expect(command.meetingID == meetingID)
    #expect(command.source == "codex")
    #expect(command.confidence == 0.97)
    #expect(command.meetingFacts?.title == "Moderna: Rosalind Pricing")
    #expect(command.meetingFacts?.participants == ["Collin Burdick"])
    #expect(command.meetingFacts?.projects == ["Rosalind"])
    #expect(command.meetingFacts?.glossary["API"] == "Application Programming Interface")
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
func contextLibraryCommandsDecodePayloads() throws {
    let entryID = UUID(uuidString: "00000000-0000-0000-0000-00000000C026")!
    let list = try JSONDecoder().decode(
        BarnOwlControlCommand.self,
        from: Data(#"{"command":"context_library_list","contextKind":"person","query":"Collin"}"#.utf8)
    )
    let upsert = try JSONDecoder().decode(
        BarnOwlControlCommand.self,
        from: Data(#"{"command":"context_library_upsert","contextLibraryEntryID":"\#(entryID.uuidString)","contextKind":"person","canonicalName":"Collin Burdick","aliases":["Colin Burdick"]}"#.utf8)
    )
    let delete = try JSONDecoder().decode(
        BarnOwlControlCommand.self,
        from: Data(#"{"command":"context_library_delete","contextLibraryEntryID":"\#(entryID.uuidString)","confirmed":true}"#.utf8)
    )
    let alias = try JSONDecoder().decode(
        BarnOwlControlCommand.self,
        from: Data(#"{"command":"context_library_alias_add","contextLibraryEntryID":"\#(entryID.uuidString)","alias":"Roslyn"}"#.utf8)
    )
    let evidence = try JSONDecoder().decode(
        BarnOwlControlCommand.self,
        from: Data(#"{"command":"context_library_evidence_add","contextLibraryEntryID":"\#(entryID.uuidString)","source":"codex","observedValue":"Rosalind"}"#.utf8)
    )
    let reconcile = try JSONDecoder().decode(
        BarnOwlControlCommand.self,
        from: Data(#"{"command":"context_library_reconcile","contextKind":"project","canonicalName":"Rosalind","observedValue":"Roslyn","source":"codex","confidence":0.97,"confirmed":true}"#.utf8)
    )
    let recurring = try JSONDecoder().decode(
        BarnOwlControlCommand.self,
        from: Data(#"{"command":"knowledge_recurring_concepts","limit":12}"#.utf8)
    )
    let brief = try JSONDecoder().decode(
        BarnOwlControlCommand.self,
        from: Data(#"{"command":"knowledge_concept_brief","query":"Rosalind","limit":8}"#.utf8)
    )
    let enrich = try JSONDecoder().decode(
        BarnOwlControlCommand.self,
        from: Data(#"{"command":"knowledge_enrich_concept","query":"Rosalind","limit":7}"#.utf8)
    )
    let autoReconcile = try JSONDecoder().decode(
        BarnOwlControlCommand.self,
        from: Data(#"{"command":"knowledge_auto_reconcile","limit":6}"#.utf8)
    )

    #expect(list.command == .contextLibraryList)
    #expect(list.contextKind == .person)
    #expect(list.query == "Collin")
    #expect(upsert.command == .contextLibraryUpsert)
    #expect(upsert.contextLibraryEntryID == entryID)
    #expect(upsert.contextKind == .person)
    #expect(upsert.canonicalName == "Collin Burdick")
    #expect(upsert.aliases == ["Colin Burdick"])
    #expect(delete.command == .contextLibraryDelete)
    #expect(delete.contextLibraryEntryID == entryID)
    #expect(delete.confirmed == true)
    #expect(alias.command == .contextLibraryAliasAdd)
    #expect(alias.contextLibraryEntryID == entryID)
    #expect(alias.alias == "Roslyn")
    #expect(evidence.command == .contextLibraryEvidenceAdd)
    #expect(evidence.source == "codex")
    #expect(evidence.observedValue == "Rosalind")
    #expect(reconcile.command == .contextLibraryReconcile)
    #expect(reconcile.contextKind == .project)
    #expect(reconcile.canonicalName == "Rosalind")
    #expect(reconcile.observedValue == "Roslyn")
    #expect(reconcile.confirmed == true)
    #expect(recurring.command == .knowledgeRecurringConcepts)
    #expect(recurring.limit == 12)
    #expect(brief.command == .knowledgeConceptBrief)
    #expect(brief.query == "Rosalind")
    #expect(brief.limit == 8)
    #expect(enrich.command == .knowledgeEnrichConcept)
    #expect(enrich.query == "Rosalind")
    #expect(enrich.limit == 7)
    #expect(autoReconcile.command == .knowledgeAutoReconcile)
    #expect(autoReconcile.limit == 6)
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
    #expect(names.contains("dashboard_snapshot"))
    #expect(names.contains("set_audio_sources"))
    #expect(names.contains("jobs_list"))
    #expect(names.contains("jobs_retry"))
    #expect(names.contains("jobs_dismiss"))
    #expect(names.contains("context_list"))
    #expect(names.contains("meeting_context_review"))
    #expect(names.contains("meeting_context_review_apply"))
    #expect(names.contains("meeting_context_review_dismiss"))
    #expect(names.contains("meeting_context_review_accept_suggestion"))
    #expect(names.contains("meeting_context_review_ignore_suggestion"))
    #expect(names.contains("meeting_structured_context_import"))
    #expect(names.contains("context_accept"))
    #expect(names.contains("context_ignore"))
    #expect(names.contains("context_delete"))
    #expect(names.contains("context_library_list"))
    #expect(names.contains("context_library_get"))
    #expect(names.contains("context_library_upsert"))
    #expect(names.contains("context_library_confirm"))
    #expect(names.contains("context_library_unconfirm"))
    #expect(names.contains("context_library_alias_add"))
    #expect(names.contains("context_library_alias_remove"))
    #expect(names.contains("context_library_evidence_add"))
    #expect(names.contains("context_library_evidence_list"))
    #expect(names.contains("context_library_links_list"))
    #expect(names.contains("context_library_reconcile"))
    #expect(names.contains("context_library_delete"))
    #expect(names.contains("knowledge_recurring_concepts"))
    #expect(names.contains("knowledge_unresolved_concepts"))
    #expect(names.contains("knowledge_concept_brief"))
    #expect(names.contains("knowledge_enrich_concept"))
    #expect(names.contains("knowledge_auto_reconcile"))
    #expect(names.contains("meeting_delete"))
    #expect(names.contains("meeting_purge_temp_audio"))
    #expect(names.contains("diagnostics_export"))
    #expect(names.contains("permissions_check"))
    #expect(names.contains("permissions_test"))
    #expect(names.contains("open_settings"))
    #expect(names.contains("open_notes_folder"))
}

@Test
func dashboardAndAudioSourceCommandsDecodePayloads() throws {
    let dashboard = try JSONDecoder().decode(
        BarnOwlControlCommand.self,
        from: Data(#"{"command":"dashboard_snapshot"}"#.utf8)
    )
    let audio = try JSONDecoder().decode(
        BarnOwlControlCommand.self,
        from: Data(#"{"command":"set_audio_sources","capturesMicrophone":false,"capturesSystemAudio":true}"#.utf8)
    )

    #expect(dashboard.command == .dashboardSnapshot)
    #expect(audio.command == .setAudioSources)
    #expect(audio.capturesMicrophone == false)
    #expect(audio.capturesSystemAudio == true)
}

@Test
func permissionsCommandsDecodeForCliSetupFlow() throws {
    let check = try JSONDecoder().decode(
        BarnOwlControlCommand.self,
        from: Data(#"{"command":"permissions_check"}"#.utf8)
    )
    let test = try JSONDecoder().decode(
        BarnOwlControlCommand.self,
        from: Data(#"{"command":"permissions_test"}"#.utf8)
    )

    #expect(check.command == .permissionsCheck)
    #expect(test.command == .permissionsTest)
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
        source: "codex",
        confidence: 0.95,
        capturesMicrophone: false,
        capturesSystemAudio: true
    )

    let quickCommand = command.quickCommand

    #expect(quickCommand?.name == .startRecording)
    #expect(quickCommand?.title == "Roadmap")
    #expect(quickCommand?.meetingType == "Planning / Review")
    #expect(quickCommand?.context == "Discuss V1 command layer.")
    #expect(quickCommand?.source == "codex")
    #expect(quickCommand?.confidence == 0.95)
    #expect(quickCommand?.capturesMicrophone == false)
    #expect(quickCommand?.capturesSystemAudio == true)
}

@Test
func startCommandDecodesIndependentAudioSources() throws {
    let data = Data(
        """
        {
          "command": "start_recording",
          "capturesMicrophone": false,
          "capturesSystemAudio": true
        }
        """.utf8
    )

    let command = try JSONDecoder().decode(BarnOwlControlCommand.self, from: data)
    let quickCommand = try #require(command.quickCommand)

    #expect(command.capturesMicrophone == false)
    #expect(command.capturesSystemAudio == true)
    #expect(quickCommand.capturesMicrophone == false)
    #expect(quickCommand.capturesSystemAudio == true)
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
                confidence: 0.95,
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
        feedbackCommand: "barnowl feedback slack",
        feedbackPostCommand: "barnowl feedback slack --yes",
        feedbackReason: "Review redacted details before posting."
    )

    let data = try JSONEncoder().encode(response)
    let decoded = try JSONDecoder().decode(BarnOwlControlResponse.self, from: data)

    #expect(decoded == response)
    #expect(decoded.jobs?.first?.status == "failed")
    #expect(decoded.diagnosticsPath == "/tmp/BarnOwl-diagnostics.md")
    #expect(decoded.nextCommand?.contains("jobs retry") == true)
    #expect(decoded.feedbackSuggested == true)
    #expect(decoded.feedbackCommand == "barnowl feedback slack")
    #expect(decoded.feedbackPostCommand == "barnowl feedback slack --yes")
}

@Test
func controlResponseCarriesReadyContextReview() throws {
    let meetingID = UUID(uuidString: "00000000-0000-0000-0000-00000000C040")!
    let response = BarnOwlControlResponse(
        ok: true,
        message: "Wait condition satisfied: review.",
        meetingID: meetingID,
        contextReview: BarnOwlContextReview(
            meetingID: meetingID,
            suggestedSummary: "Barn Owl thinks this was a customer workshop.",
            prompts: [ContextReviewPrompt(kind: .participants, text: "Who else was in this?")],
            facts: MeetingFacts(
                title: "Acme Review",
                participants: ["Collin Burdick"],
                customers: ["Acme Corp."]
            ),
            entitySuggestions: [
                ContextEntitySuggestion(
                    id: UUID(uuidString: "00000000-0000-0000-0000-00000000C041")!,
                    kind: .person,
                    observedValue: "Colin",
                    canonicalValue: "Collin Burdick",
                    rationale: "Invite and transcript appear to refer to the same participant.",
                    confidence: 0.98,
                    evidenceSources: ["calendar", "transcript"]
                )
            ]
        ),
        contextReviewReady: true
    )

    let data = try JSONEncoder().encode(response)
    let decoded = try JSONDecoder().decode(BarnOwlControlResponse.self, from: data)

    #expect(decoded == response)
    #expect(decoded.contextReview?.entitySuggestions.first?.canonicalValue == "Collin Burdick")
}

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
func calendarContextAttachCommandDecodesRepairPayload() throws {
    let data = Data(
        """
        {
          "command": "calendar_context_attach",
          "meetingID": "00000000-0000-0000-0000-00000000C019",
          "calendarContextJSON": "{\\"id\\":\\"event-123\\"}",
          "calendarContextState": "accepted",
          "selectedAutomatically": true
        }
        """.utf8
    )

    let command = try JSONDecoder().decode(BarnOwlControlCommand.self, from: data)

    #expect(command.command == .calendarContextAttach)
    #expect(command.meetingID == UUID(uuidString: "00000000-0000-0000-0000-00000000C019"))
    #expect(command.calendarContextJSON == #"{"id":"event-123"}"#)
    #expect(command.calendarContextState == "accepted")
    #expect(command.selectedAutomatically == true)
}

@Test
func controlResponseEncodesCalendarRepairMatches() throws {
    let matchID = UUID(uuidString: "00000000-0000-0000-0000-00000000C020")!
    let response = BarnOwlControlResponse(
        ok: true,
        message: "Barn Owl calendar context matches.",
        calendarMatches: [
            BarnOwlControlCalendarMatch(
                id: matchID,
                meetingID: UUID(uuidString: "00000000-0000-0000-0000-00000000C021")!,
                calendarEventID: "event-123",
                title: "OpenAI <> Moderna",
                state: "accepted",
                selectedAutomatically: false,
                matchReason: "unique accepted invite match",
                confidence: 0.96
            )
        ]
    )

    let data = try JSONEncoder().encode(response)
    let decoded = try JSONDecoder().decode(BarnOwlControlResponse.self, from: data)

    #expect(decoded == response)
    #expect(decoded.calendarMatches?.first?.state == "accepted")
}

@Test
func controlResponseEncodesEnrichmentConceptHistory() throws {
    let response = BarnOwlControlResponse(
        ok: true,
        message: "Barn Owl enrichment jobs.",
        enrichmentConceptHistories: [
            BarnOwlControlEnrichmentConceptHistory(
                conceptKey: "Orchid",
                supportedCandidateJobs: 3,
                conflictingJobs: 1,
                negativeEvidenceItems: 2,
                requiresConflictMemoryHold: true
            )
        ]
    )

    let data = try JSONEncoder().encode(response)
    let decoded = try JSONDecoder().decode(BarnOwlControlResponse.self, from: data)

    #expect(decoded == response)
    #expect(decoded.enrichmentConceptHistories?.first?.requiresConflictMemoryHold == true)
}

@Test
func controlResponseEncodesEnrichmentOnboardingMetadata() throws {
    let response = BarnOwlControlResponse(
        ok: true,
        message: "Barn Owl enrichment sources.",
        enrichmentAuthorityProfiles: [
            BarnOwlControlEnrichmentAuthorityProfile(
                id: "private_internal_reference",
                displayName: "Private Internal Reference",
                description: "User-authorized internal context.",
                strongestEntityKinds: ["project", "person"],
                weakestEntityKinds: ["public_event"],
                defaultWeight: 0.93,
                builtIn: true
            )
        ],
        enrichmentPolicyPacks: [
            BarnOwlControlEnrichmentPolicyPack(
                id: "balanced_autonomous_default",
                displayName: "Balanced autonomous default",
                description: "Default autonomous thresholds.",
                minimumSupportingEvidenceCount: 2,
                minimumIndependentSourceCountAfterConflictMemory: 2,
                active: true
            )
        ]
    )

    let data = try JSONEncoder().encode(response)
    let decoded = try JSONDecoder().decode(BarnOwlControlResponse.self, from: data)

    #expect(decoded == response)
    #expect(decoded.enrichmentAuthorityProfiles?.first?.id == "private_internal_reference")
    #expect(decoded.enrichmentPolicyPacks?.first?.active == true)
}

@Test
func controlResponseEncodesDurableKnowledgeLifecycleState() throws {
    let entityID = UUID(uuidString: "00000000-0000-0000-0000-00000000C123")!
    let response = BarnOwlControlResponse(
        ok: true,
        message: "Suppressed durable knowledge entity.",
        knowledgeEntities: [
            BarnOwlControlKnowledgeEntity(
                id: entityID,
                kind: "project",
                canonicalName: "Orchid",
                summary: "Internal project.",
                confidence: 0.94,
                lifecycleStatus: "suppressed",
                lifecycleReason: "Operator correction.",
                lifecycleUpdatedAt: Date(timeIntervalSince1970: 1_800_004_500),
                createdAt: Date(timeIntervalSince1970: 1_800_004_000),
                updatedAt: Date(timeIntervalSince1970: 1_800_004_500)
            )
        ]
    )

    let data = try JSONEncoder().encode(response)
    let decoded = try JSONDecoder().decode(BarnOwlControlResponse.self, from: data)

    #expect(decoded == response)
    #expect(decoded.knowledgeEntities?.first?.lifecycleStatus == "suppressed")
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
func meetingEvidenceCommandDecodesPolicyAndSegmentExpansion() throws {
    let data = Data(
        """
        {
          "command": "meeting_evidence",
          "meetingID": "00000000-0000-0000-0000-00000000C024",
          "exportPolicy": "structured_outputs_transcript_and_pointers",
          "includeTranscriptSegments": true,
          "format": "json"
        }
        """.utf8
    )

    let command = try JSONDecoder().decode(BarnOwlControlCommand.self, from: data)

    #expect(command.command == .meetingEvidence)
    #expect(command.meetingID == UUID(uuidString: "00000000-0000-0000-0000-00000000C024"))
    #expect(command.exportPolicy == "structured_outputs_transcript_and_pointers")
    #expect(command.includeTranscriptSegments == true)
}

@Test
func meetingsEvidenceCommandDecodesTimestampSyncPayload() throws {
    let data = Data(
        """
        {
          "command": "meetings_evidence",
          "since": "2026-05-17T17:00:00Z",
          "limit": 25,
          "exportPolicy": "metadata_only",
          "includeTranscriptSegments": false,
          "format": "json"
        }
        """.utf8
    )

    let command = try JSONDecoder().decode(BarnOwlControlCommand.self, from: data)

    #expect(command.command == .meetingsEvidence)
    #expect(command.since == "2026-05-17T17:00:00Z")
    #expect(command.limit == 25)
    #expect(command.exportPolicy == "metadata_only")
    #expect(command.includeTranscriptSegments == false)
}

@Test
func meetingsEvidenceCommandDecodesCursorSyncPayload() throws {
    let data = Data(
        """
        {
          "command": "meetings_evidence",
          "cursor": "opaque-next-page-token",
          "limit": 50,
          "exportPolicy": "structured_outputs_transcript_and_pointers",
          "format": "json"
        }
        """.utf8
    )

    let command = try JSONDecoder().decode(BarnOwlControlCommand.self, from: data)

    #expect(command.command == .meetingsEvidence)
    #expect(command.cursor == "opaque-next-page-token")
    #expect(command.limit == 50)
    #expect(command.exportPolicy == "structured_outputs_transcript_and_pointers")
}

@Test
func meetingExportEventsCommandDecodesTimestampAndCursorPayloads() throws {
    let timestamp = try JSONDecoder().decode(
        BarnOwlControlCommand.self,
        from: Data(
            """
            {
              "command": "meeting_export_events",
              "since": "2026-05-17T17:00:00Z",
              "limit": 25,
              "format": "json"
            }
            """.utf8
        )
    )
    let cursor = try JSONDecoder().decode(
        BarnOwlControlCommand.self,
        from: Data(
            """
            {
              "command": "meeting_export_events",
              "cursor": "opaque-event-token",
              "limit": 50,
              "format": "json"
            }
            """.utf8
        )
    )

    #expect(timestamp.command == .meetingExportEvents)
    #expect(timestamp.since == "2026-05-17T17:00:00Z")
    #expect(timestamp.limit == 25)
    #expect(cursor.command == .meetingExportEvents)
    #expect(cursor.cursor == "opaque-event-token")
    #expect(cursor.limit == 50)
}

@Test
func controlResponseEncodesMeetingEvidenceEnvelope() throws {
    let meetingID = UUID(uuidString: "00000000-0000-0000-0000-00000000C025")!
    let generatedAt = Date(timeIntervalSince1970: 1_800_000_500)
    let response = BarnOwlControlResponse(
        ok: true,
        message: "Barn Owl meeting evidence.",
        meetingEvidence: BarnOwlMeetingEvidenceEnvelope(
            source: BarnOwlMeetingEvidenceSource(
                producer: "barnowl",
                producerVersion: "test",
                tenantScope: "local_user"
            ),
            meeting: BarnOwlMeetingEvidenceMeeting(
                id: meetingID,
                stableKey: "barnowl:meeting:\(meetingID.uuidString)",
                title: "Evidence Review",
                meetingType: "Planning / Review",
                startedAt: generatedAt,
                endedAt: generatedAt.addingTimeInterval(30),
                updatedAt: generatedAt
            ),
            participants: [
                BarnOwlMeetingEvidenceParticipant(displayName: "Dana", roleHint: "participant")
            ],
            artifacts: BarnOwlMeetingEvidenceArtifacts(
                transcript: BarnOwlMeetingEvidenceArtifact(
                    pointer: "barnowl:meeting:\(meetingID.uuidString)#transcript",
                    ready: true,
                    text: "Dana: Ship the evidence contract."
                ),
                notes: BarnOwlMeetingEvidenceArtifact(
                    pointer: "barnowl:meeting:\(meetingID.uuidString)#notes",
                    ready: true
                ),
                summary: BarnOwlMeetingEvidenceArtifact(
                    pointer: "barnowl:meeting:\(meetingID.uuidString)#summary",
                    ready: true
                ),
                actions: BarnOwlMeetingEvidenceArtifact(
                    pointer: "barnowl:meeting:\(meetingID.uuidString)#actions",
                    ready: true
                )
            ),
            derived: BarnOwlMeetingEvidenceDerived(
                summary: BarnOwlMeetingEvidenceSummary(overview: "Reviewed the evidence contract."),
                decisions: ["Keep exports consumer-agnostic."],
                actionItems: ["Implement one-shot CLI export."],
                openQuestions: [],
                meetingFacts: BarnOwlMeetingEvidenceMeetingFacts(
                    title: "Evidence Review",
                    meetingType: "Planning / Review",
                    participants: ["Dana"]
                )
            ),
            transcriptSegments: [
                BarnOwlMeetingEvidenceTranscriptSegment(
                    sequence: 0,
                    speakerLabel: "Dana",
                    text: "Ship the evidence contract.",
                    startTime: 0,
                    endTime: 2.5,
                    confidence: 0.99
                )
            ],
            processing: BarnOwlMeetingEvidenceProcessing(
                state: "completed",
                ingestReadiness: .ready,
                transcriptReady: true,
                notesReady: true,
                summaryReady: true,
                usedFallbackSummary: false,
                repairRecommended: false,
                lastSuccessfulProcessingAt: generatedAt
            ),
            provenance: BarnOwlMeetingEvidenceProvenance(
                sourceOfTruth: "barnowl",
                contentPolicy: .structuredOutputsTranscriptAndPointers,
                generatedAt: generatedAt
            )
        )
    )

    let data = try JSONEncoder().encode(response)
    let decoded = try JSONDecoder().decode(BarnOwlControlResponse.self, from: data)

    #expect(decoded == response)
    #expect(decoded.meetingEvidence?.processing.ingestReadiness == .ready)
    #expect(decoded.meetingEvidence?.artifacts.transcript.text?.contains("evidence contract") == true)
}

@Test
func controlResponseEncodesMeetingEvidenceBatchSyncPage() throws {
    let since = Date(timeIntervalSince1970: 1_800_000_000)
    let nextSince = since.addingTimeInterval(60)
    let response = BarnOwlControlResponse(
        ok: true,
        message: "Barn Owl meeting evidence batch.",
        meetingEvidenceBatch: BarnOwlMeetingEvidenceBatch(
            items: [],
            sync: BarnOwlMeetingEvidenceSyncPage(
                mode: .timestamp,
                requestedSince: since,
                nextSince: nextSince,
                nextCursor: "cursor-token",
                limit: 100,
                returnedCount: 0,
                hasMore: false
            )
        )
    )

    let data = try JSONEncoder().encode(response)
    let decoded = try JSONDecoder().decode(BarnOwlControlResponse.self, from: data)

    #expect(decoded == response)
    #expect(decoded.meetingEvidenceBatch?.sync.mode == .timestamp)
    #expect(decoded.meetingEvidenceBatch?.sync.nextSince == nextSince)
    #expect(decoded.meetingEvidenceBatch?.sync.nextCursor == "cursor-token")
}

@Test
func controlResponseEncodesMeetingExportEventBatchSyncPage() throws {
    let since = Date(timeIntervalSince1970: 1_800_000_000)
    let eventID = UUID(uuidString: "00000000-0000-0000-0000-00000000C026")!
    let meetingID = UUID(uuidString: "00000000-0000-0000-0000-00000000C027")!
    let response = BarnOwlControlResponse(
        ok: true,
        message: "Barn Owl meeting export event batch.",
        meetingExportEventBatch: BarnOwlMeetingExportEventBatch(
            items: [
                BarnOwlMeetingExportEvent(
                    id: eventID,
                    type: .deleted,
                    meetingID: meetingID,
                    meetingStableKey: "barnowl:meeting:\(meetingID.uuidString)",
                    occurredAt: since,
                    schemaVersion: "1.0",
                    tombstoneReason: "meeting_deleted"
                )
            ],
            sync: BarnOwlMeetingExportEventSyncPage(
                mode: .timestamp,
                requestedSince: since,
                nextSince: since,
                nextCursor: "event-cursor-token",
                limit: 100,
                returnedCount: 1,
                hasMore: false
            )
        )
    )

    let data = try JSONEncoder().encode(response)
    let decoded = try JSONDecoder().decode(BarnOwlControlResponse.self, from: data)

    #expect(decoded == response)
    #expect(decoded.meetingExportEventBatch?.items.first?.type == .deleted)
    #expect(decoded.meetingExportEventBatch?.sync.nextCursor == "event-cursor-token")
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
    #expect(names.contains("durability_repair"))
    #expect(names.contains("context_list"))
    #expect(names.contains("context_accept"))
    #expect(names.contains("context_ignore"))
    #expect(names.contains("context_delete"))
    #expect(names.contains("meetings_evidence"))
    #expect(names.contains("enrichment_sources_list"))
    #expect(names.contains("enrichment_source_presets_list"))
    #expect(names.contains("enrichment_source_setup_preset"))
    #expect(names.contains("enrichment_source_health_check"))
    #expect(names.contains("enrichment_source_upsert"))
    #expect(names.contains("enrichment_source_enable"))
    #expect(names.contains("enrichment_source_disable"))
    #expect(names.contains("enrichment_authority_profiles_list"))
    #expect(names.contains("enrichment_authority_profile_upsert"))
    #expect(names.contains("enrichment_policy_packs_list"))
    #expect(names.contains("enrichment_policy_pack_upsert"))
    #expect(names.contains("enrichment_policy_pack_activate"))
    #expect(names.contains("knowledge_enrich"))
    #expect(names.contains("knowledge_jobs_list"))
    #expect(names.contains("knowledge_entities_list"))
    #expect(names.contains("knowledge_entity_suppress"))
    #expect(names.contains("knowledge_entity_reactivate"))
    #expect(names.contains("meeting_delete"))
    #expect(names.contains("meeting_purge_temp_audio"))
    #expect(names.contains("meeting_evidence"))
    #expect(names.contains("diagnostics_export"))
    #expect(names.contains("permissions_check"))
    #expect(names.contains("permissions_test"))
}

@Test
func enrichmentSourceUpsertCommandDecodesRegistryFields() throws {
    let data = Data(
        """
        {
          "command": "enrichment_source_upsert",
          "sourceID": "owner_private_source",
          "sourceDisplayName": "Private Reference Source",
          "sourceType": "internal_memory",
          "enabled": true,
          "scope": "personal_private",
          "authorityProfile": "private_internal_reference",
          "bestUsedFor": ["projects", "people"],
          "configJSON": "{\\"root\\":\\"private\\"}",
          "authState": "configured",
          "healthStatus": "ready"
        }
        """.utf8
    )

    let command = try JSONDecoder().decode(BarnOwlControlCommand.self, from: data)

    #expect(command.command == .enrichmentSourceUpsert)
    #expect(command.sourceID == "owner_private_source")
    #expect(command.scope == "personal_private")
    #expect(command.bestUsedFor == ["projects", "people"])
    #expect(command.authState == "configured")
}

@Test
func knowledgeEnrichCommandDecodesConceptQuery() throws {
    let command = try JSONDecoder().decode(
        BarnOwlControlCommand.self,
        from: Data(#"{"command":"knowledge_enrich","query":"Orchid","limit":6}"#.utf8)
    )

    #expect(command.command == .knowledgeEnrich)
    #expect(command.query == "Orchid")
    #expect(command.limit == 6)
}

@Test
func enrichmentPolicyAndKnowledgeLifecycleCommandsDecodeManagementFields() throws {
    let policy = try JSONDecoder().decode(
        BarnOwlControlCommand.self,
        from: Data(
            """
            {
              "command":"enrichment_policy_pack_upsert",
              "policyPackID":"strict_private",
              "displayName":"Strict private",
              "description":"Require more corroboration.",
              "minimumSupportingEvidenceCount":3,
              "minimumIndependentSourceCountAfterConflictMemory":3,
              "enabled":true
            }
            """.utf8
        )
    )
    let suppress = try JSONDecoder().decode(
        BarnOwlControlCommand.self,
        from: Data(
            #"{"command":"knowledge_entity_suppress","knowledgeEntityID":"00000000-0000-0000-0000-00000000C099","reason":"Manual correction"}"#.utf8
        )
    )

    #expect(policy.command == .enrichmentPolicyPackUpsert)
    #expect(policy.policyPackID == "strict_private")
    #expect(policy.minimumSupportingEvidenceCount == 3)
    #expect(policy.enabled == true)
    #expect(suppress.command == .knowledgeEntitySuppress)
    #expect(suppress.knowledgeEntityID == UUID(uuidString: "00000000-0000-0000-0000-00000000C099"))
    #expect(suppress.reason == "Manual correction")
}

@Test
func enrichmentSourceSetupPresetCommandDecodesConnectorSetupFields() throws {
    let command = try JSONDecoder().decode(
        BarnOwlControlCommand.self,
        from: Data(
            """
            {
              "command":"enrichment_source_setup_preset",
              "presetID":"google_drive_reference",
              "sourceID":"drive_reference",
              "sourceDisplayName":"Drive Knowledge",
              "authorityProfile":"private_internal_reference",
              "bestUsedFor":["projects","people"]
            }
            """.utf8
        )
    )

    #expect(command.command == .enrichmentSourceSetupPreset)
    #expect(command.presetID == "google_drive_reference")
    #expect(command.sourceID == "drive_reference")
    #expect(command.sourceDisplayName == "Drive Knowledge")
    #expect(command.bestUsedFor == ["projects", "people"])
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
func enrichmentOrchestratorPromotesSupportedCandidatesThroughInstalledAdapters() async {
    let source = BarnOwlEnrichmentConfiguredSource(
        descriptor: BarnOwlEnrichmentSourceDescriptor(
            id: "barnowl_memory",
            displayName: "Barn Owl Memory",
            sourceType: "local_memory",
            scope: .localPrivate,
            authorityProfile: "meeting_memory"
        ),
        enabled: true,
        authState: .notRequired,
        healthStatus: .ready
    )
    let orchestrator = BarnOwlEnrichmentOrchestrator(
        adapters: [
            StaticEnrichmentAdapter(
                sourceID: "barnowl_memory",
                evidence: [
                    enrichmentEvidence(subject: "Orchid", citation: "meeting:a"),
                    enrichmentEvidence(subject: "Orchid", citation: "meeting:b")
                ]
            )
        ]
    )

    let result = await orchestrator.run(
        request: BarnOwlEnrichmentSourceRequest(conceptKey: "Orchid", limit: 8),
        sources: [source]
    )

    #expect(result.status == .supportedCandidate)
    #expect(result.requestedSources == ["barnowl_memory"])
    #expect(result.selectedSources == ["barnowl_memory"])
    #expect(result.evidence.count == 2)
}

@Test
func enrichmentOrchestratorOrdersEligibleSourcesByRoutingPriority() async {
    let lowerPriority = BarnOwlEnrichmentConfiguredSource(
        descriptor: BarnOwlEnrichmentSourceDescriptor(
            id: "public_web",
            displayName: "Internet References",
            sourceType: "public_reference",
            scope: .publicReference,
            authorityProfile: "public_reference"
        ),
        enabled: true,
        authState: .notRequired,
        healthStatus: .ready,
        routingPriority: 0.1
    )
    let higherPriority = BarnOwlEnrichmentConfiguredSource(
        descriptor: BarnOwlEnrichmentSourceDescriptor(
            id: "owner_private_source",
            displayName: "Private Reference Source",
            sourceType: "internal_memory",
            scope: .personalPrivate,
            authorityProfile: "private_internal_reference"
        ),
        enabled: true,
        authState: .configured,
        healthStatus: .ready,
        routingPriority: 4.5
    )

    let result = await BarnOwlEnrichmentOrchestrator(
        adapters: [
            StaticEnrichmentAdapter(
                sourceID: "public_web",
                evidence: [enrichmentEvidence(subject: "Orchid", citation: "public:orchid")]
            ),
            StaticEnrichmentAdapter(
                sourceID: "owner_private_source",
                evidence: [enrichmentEvidence(subject: "Orchid", citation: "owner-private:orchid")]
            )
        ]
    ).run(
        request: BarnOwlEnrichmentSourceRequest(conceptKey: "Orchid", limit: 8),
        sources: [lowerPriority, higherPriority]
    )

    #expect(result.selectedSources == ["owner_private_source", "public_web"])
}

@Test
func enrichmentOrchestratorConflictMemoryRequiresIndependentCorroboration() async {
    let source = BarnOwlEnrichmentConfiguredSource(
        descriptor: BarnOwlEnrichmentSourceDescriptor(
            id: "owner_private_source",
            displayName: "Private Reference Source",
            sourceType: "internal_memory",
            scope: .personalPrivate,
            authorityProfile: "private_internal_reference"
        ),
        enabled: true,
        authState: .configured,
        healthStatus: .ready
    )
    let result = await BarnOwlEnrichmentOrchestrator(
        adapters: [
            StaticEnrichmentAdapter(
                sourceID: "owner_private_source",
                evidence: [
                    enrichmentEvidence(subject: "Orchid", citation: "owner-private:orchid:1"),
                    enrichmentEvidence(subject: "Orchid", citation: "owner-private:orchid:2")
                ]
            )
        ]
    ).run(
        request: BarnOwlEnrichmentSourceRequest(conceptKey: "Orchid", limit: 8),
        sources: [source],
        conceptHistory: BarnOwlEnrichmentConceptHistory(conflictingJobs: 1)
    )

    #expect(result.status == .heldConflictingEvidence)
    #expect(result.evidence.count == 2)
    #expect(result.rationale.contains("prior conflicting job"))
    #expect(result.rationale.contains("independent source adapters"))
}

@Test
func enrichmentOrchestratorConflictMemoryAllowsIndependentCorroboration() async {
    let ownerSource = BarnOwlEnrichmentConfiguredSource(
        descriptor: BarnOwlEnrichmentSourceDescriptor(
            id: "owner_private_source",
            displayName: "Private Reference Source",
            sourceType: "internal_memory",
            scope: .personalPrivate,
            authorityProfile: "private_internal_reference"
        ),
        enabled: true,
        authState: .configured,
        healthStatus: .ready
    )
    let memorySource = BarnOwlEnrichmentConfiguredSource(
        descriptor: BarnOwlEnrichmentSourceDescriptor(
            id: "barnowl_memory",
            displayName: "Barn Owl Memory",
            sourceType: "local_memory",
            scope: .localPrivate,
            authorityProfile: "meeting_memory"
        ),
        enabled: true,
        authState: .notRequired,
        healthStatus: .ready
    )
    let result = await BarnOwlEnrichmentOrchestrator(
        adapters: [
            StaticEnrichmentAdapter(
                sourceID: "owner_private_source",
                evidence: [enrichmentEvidence(
                    subject: "Orchid",
                    citation: "owner-private:orchid",
                    sourceID: "owner_private_source",
                    sourceDisplayName: "Private Reference Source",
                    authorityProfile: "private_internal_reference",
                    scope: .personalPrivate
                )]
            ),
            StaticEnrichmentAdapter(
                sourceID: "barnowl_memory",
                evidence: [enrichmentEvidence(subject: "Orchid", citation: "meeting:orchid")]
            )
        ]
    ).run(
        request: BarnOwlEnrichmentSourceRequest(conceptKey: "Orchid", limit: 8),
        sources: [ownerSource, memorySource],
        conceptHistory: BarnOwlEnrichmentConceptHistory(conflictingJobs: 1, negativeEvidenceItems: 1)
    )

    #expect(result.status == .supportedCandidate)
    #expect(Set(result.selectedSources) == Set(["barnowl_memory", "owner_private_source"]))
}

@Test
func enrichmentOrchestratorHoldsWhenConfiguredSourcesLackEligibleAdapters() async {
    let source = BarnOwlEnrichmentConfiguredSource(
        descriptor: BarnOwlEnrichmentSourceDescriptor(
            id: "public_web",
            displayName: "Internet References",
            sourceType: "public_reference",
            scope: .publicReference,
            authorityProfile: "public_reference"
        ),
        enabled: true,
        authState: .notRequired,
        healthStatus: .ready
    )

    let result = await BarnOwlEnrichmentOrchestrator(adapters: []).run(
        request: BarnOwlEnrichmentSourceRequest(conceptKey: "Orchid", limit: 8),
        sources: [source]
    )

    #expect(result.status == .heldNoEligibleSources)
    #expect(result.requestedSources == ["public_web"])
    #expect(result.selectedSources.isEmpty)
    #expect(result.evidence.isEmpty)
}

@Test
func enrichmentOrchestratorHoldsWhenSemanticCandidatesConflict() async {
    let ownerSource = BarnOwlEnrichmentConfiguredSource(
        descriptor: BarnOwlEnrichmentSourceDescriptor(
            id: "owner_private_source",
            displayName: "Private Reference Source",
            sourceType: "internal_memory",
            scope: .personalPrivate,
            authorityProfile: "private_internal_reference"
        ),
        enabled: true,
        authState: .configured,
        healthStatus: .ready
    )
    let teamSource = BarnOwlEnrichmentConfiguredSource(
        descriptor: BarnOwlEnrichmentSourceDescriptor(
            id: "workspace_glossary",
            displayName: "Workspace Glossary",
            sourceType: "internal_memory",
            scope: .workspacePrivate,
            authorityProfile: "workspace_reference"
        ),
        enabled: true,
        authState: .configured,
        healthStatus: .ready
    )
    let orchestrator = BarnOwlEnrichmentOrchestrator(
        adapters: [
            StaticEnrichmentAdapter(
                sourceID: "owner_private_source",
                evidence: [
                    enrichmentEvidence(
                        subject: "Orchid",
                        citation: "owner-private:project/orchid",
                        candidateKind: "project",
                        canonicalName: "Orchid"
                    )
                ]
            ),
            StaticEnrichmentAdapter(
                sourceID: "workspace_glossary",
                evidence: [
                    enrichmentEvidence(
                        subject: "Orchid",
                        citation: "workspace:people/orchid",
                        candidateKind: "person",
                        canonicalName: "Orchid Chen"
                    )
                ]
            )
        ]
    )

    let result = await orchestrator.run(
        request: BarnOwlEnrichmentSourceRequest(conceptKey: "Orchid", limit: 8),
        sources: [ownerSource, teamSource]
    )

    #expect(result.status == .heldConflictingEvidence)
    #expect(result.selectedSources == ["owner_private_source", "workspace_glossary"])
    #expect(result.evidence.count == 2)
    #expect(result.rationale.contains("blocked"))
}

@Test
func enrichmentOrchestratorBlocksPublicOnlyPrivateTruth() async {
    let publicSource = BarnOwlEnrichmentConfiguredSource(
        descriptor: BarnOwlEnrichmentSourceDescriptor(
            id: "public_web",
            displayName: "Internet References",
            sourceType: "public_reference",
            scope: .publicReference,
            authorityProfile: "public_reference"
        ),
        enabled: true,
        authState: .notRequired,
        healthStatus: .ready
    )
    let evidence = [
        BarnOwlEnrichmentEvidenceRecord(
            subject: "Orchid",
            candidateKind: "project",
            canonicalName: "Orchid",
            summary: "Public result claims Orchid is a project.",
            confidence: 0.84,
            sourceID: "public_web",
            sourceDisplayName: "Internet References",
            authorityProfile: "public_reference",
            freshness: .recent,
            scope: .publicReference,
            citations: ["public:orchid:1"]
        ),
        BarnOwlEnrichmentEvidenceRecord(
            subject: "Orchid",
            candidateKind: "project",
            canonicalName: "Orchid",
            summary: "Another public result claims Orchid is a project.",
            confidence: 0.81,
            sourceID: "public_web",
            sourceDisplayName: "Internet References",
            authorityProfile: "public_reference",
            freshness: .recent,
            scope: .publicReference,
            citations: ["public:orchid:2"]
        )
    ]

    let result = await BarnOwlEnrichmentOrchestrator(
        adapters: [StaticEnrichmentAdapter(sourceID: "public_web", evidence: evidence)]
    ).run(
        request: BarnOwlEnrichmentSourceRequest(conceptKey: "Orchid", limit: 8),
        sources: [publicSource]
    )

    #expect(result.status == .heldInsufficientEvidence)
    #expect(result.evidence.count == 2)
    #expect(result.rationale.contains("public-only evidence"))
}

private struct StaticEnrichmentAdapter: BarnOwlEnrichmentSourceAdapter {
    var sourceID: String
    var evidence: [BarnOwlEnrichmentEvidenceRecord]

    func healthSnapshot(
        for source: BarnOwlEnrichmentSourceDescriptor
    ) async -> BarnOwlEnrichmentSourceHealthSnapshot {
        BarnOwlEnrichmentSourceHealthSnapshot(status: .ready, authState: .notRequired)
    }

    func enrich(
        request: BarnOwlEnrichmentSourceRequest,
        source: BarnOwlEnrichmentSourceDescriptor
    ) async throws -> BarnOwlEnrichmentSourceResult {
        BarnOwlEnrichmentSourceResult(sourceID: source.id, evidence: evidence)
    }
}

private func enrichmentEvidence(
    subject: String,
    citation: String,
    candidateKind: String = "project",
    canonicalName: String? = nil,
    sourceID: String = "barnowl_memory",
    sourceDisplayName: String = "Barn Owl Memory",
    authorityProfile: String = "meeting_memory",
    scope: BarnOwlEnrichmentSourceScope = .localPrivate
) -> BarnOwlEnrichmentEvidenceRecord {
    BarnOwlEnrichmentEvidenceRecord(
        subject: subject,
        candidateKind: candidateKind,
        canonicalName: canonicalName ?? subject,
        summary: "Recurring evidence for \(subject).",
        confidence: 0.9,
        sourceID: sourceID,
        sourceDisplayName: sourceDisplayName,
        authorityProfile: authorityProfile,
        freshness: .recent,
        scope: scope,
        citations: [citation],
        observedAt: Date(timeIntervalSince1970: 1_800_000_000)
    )
}

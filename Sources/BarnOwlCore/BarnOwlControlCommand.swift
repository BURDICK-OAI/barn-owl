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
    case enrichmentSourcesList = "enrichment_sources_list"
    case enrichmentSourcePresetsList = "enrichment_source_presets_list"
    case enrichmentSourceSetupPreset = "enrichment_source_setup_preset"
    case enrichmentSourceHealthCheck = "enrichment_source_health_check"
    case enrichmentSourceUpsert = "enrichment_source_upsert"
    case enrichmentSourceEnable = "enrichment_source_enable"
    case enrichmentSourceDisable = "enrichment_source_disable"
    case enrichmentAuthorityProfilesList = "enrichment_authority_profiles_list"
    case enrichmentAuthorityProfileUpsert = "enrichment_authority_profile_upsert"
    case enrichmentPolicyPacksList = "enrichment_policy_packs_list"
    case enrichmentPolicyPackUpsert = "enrichment_policy_pack_upsert"
    case enrichmentPolicyPackActivate = "enrichment_policy_pack_activate"
    case knowledgeEnrich = "knowledge_enrich"
    case knowledgeJobsList = "knowledge_jobs_list"
    case knowledgeEntitiesList = "knowledge_entities_list"
    case knowledgeEntitySuppress = "knowledge_entity_suppress"
    case knowledgeEntityReactivate = "knowledge_entity_reactivate"
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
    public var sourceID: String?
    public var presetID: String?
    public var sourceDisplayName: String?
    public var sourceType: String?
    public var enabled: Bool?
    public var scope: String?
    public var authorityProfile: String?
    public var bestUsedFor: [String]?
    public var configJSON: String?
    public var authState: String?
    public var healthStatus: String?
    public var connectorReference: String?
    public var privacyCopyPolicy: String?
    public var queryBudgetPolicy: String?
    public var authorityProfileID: String?
    public var policyPackID: String?
    public var displayName: String?
    public var description: String?
    public var strongestEntityKinds: [String]?
    public var weakestEntityKinds: [String]?
    public var defaultWeight: Double?
    public var autoPersistPolicyJSON: String?
    public var minimumSupportingEvidenceCount: Int?
    public var minimumIndependentSourceCountAfterConflictMemory: Int?
    public var knowledgeEntityID: UUID?
    public var reason: String?

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
        capturesSystemAudio: Bool? = nil,
        sourceID: String? = nil,
        presetID: String? = nil,
        sourceDisplayName: String? = nil,
        sourceType: String? = nil,
        enabled: Bool? = nil,
        scope: String? = nil,
        authorityProfile: String? = nil,
        bestUsedFor: [String]? = nil,
        configJSON: String? = nil,
        authState: String? = nil,
        healthStatus: String? = nil,
        connectorReference: String? = nil,
        privacyCopyPolicy: String? = nil,
        queryBudgetPolicy: String? = nil,
        authorityProfileID: String? = nil,
        policyPackID: String? = nil,
        displayName: String? = nil,
        description: String? = nil,
        strongestEntityKinds: [String]? = nil,
        weakestEntityKinds: [String]? = nil,
        defaultWeight: Double? = nil,
        autoPersistPolicyJSON: String? = nil,
        minimumSupportingEvidenceCount: Int? = nil,
        minimumIndependentSourceCountAfterConflictMemory: Int? = nil,
        knowledgeEntityID: UUID? = nil,
        reason: String? = nil
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
        self.sourceID = sourceID
        self.presetID = presetID
        self.sourceDisplayName = sourceDisplayName
        self.sourceType = sourceType
        self.enabled = enabled
        self.scope = scope
        self.authorityProfile = authorityProfile
        self.bestUsedFor = bestUsedFor
        self.configJSON = configJSON
        self.authState = authState
        self.healthStatus = healthStatus
        self.connectorReference = connectorReference
        self.privacyCopyPolicy = privacyCopyPolicy
        self.queryBudgetPolicy = queryBudgetPolicy
        self.authorityProfileID = authorityProfileID
        self.policyPackID = policyPackID
        self.displayName = displayName
        self.description = description
        self.strongestEntityKinds = strongestEntityKinds
        self.weakestEntityKinds = weakestEntityKinds
        self.defaultWeight = defaultWeight
        self.autoPersistPolicyJSON = autoPersistPolicyJSON
        self.minimumSupportingEvidenceCount = minimumSupportingEvidenceCount
        self.minimumIndependentSourceCountAfterConflictMemory = minimumIndependentSourceCountAfterConflictMemory
        self.knowledgeEntityID = knowledgeEntityID
        self.reason = reason
    }
}

public enum BarnOwlEnrichmentSourceScope: String, Codable, CaseIterable, Equatable, Sendable {
    case localPrivate = "local_private"
    case personalPrivate = "personal_private"
    case workspacePrivate = "workspace_private"
    case organizationScoped = "organization_scoped"
    case publicReference = "public"

    public var displayName: String {
        switch self {
        case .localPrivate:
            return "Local private"
        case .personalPrivate:
            return "Personal private"
        case .workspacePrivate:
            return "Workspace private"
        case .organizationScoped:
            return "Organization scoped"
        case .publicReference:
            return "Public"
        }
    }
}

public enum BarnOwlEnrichmentSourceAuthState: String, Codable, CaseIterable, Equatable, Sendable {
    case notRequired = "not_required"
    case configured
    case needsAuthentication = "needs_authentication"
    case unavailable
}

public enum BarnOwlEnrichmentSourceHealthStatus: String, Codable, CaseIterable, Equatable, Sendable {
    case ready
    case disabled
    case needsAuth = "needs_auth"
    case stale
    case partial
    case error

    public var displayName: String {
        switch self {
        case .ready:
            return "Ready"
        case .disabled:
            return "Disabled"
        case .needsAuth:
            return "Needs auth"
        case .stale:
            return "Stale"
        case .partial:
            return "Partial"
        case .error:
            return "Error"
        }
    }
}

public enum BarnOwlEnrichmentSourceOwner {
    public static func localUserID(currentUsername: String = NSUserName()) -> String {
        let normalized = currentUsername.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? "local-user" : normalized
    }
}

public struct BarnOwlEnrichmentSourceDescriptor: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var displayName: String
    public var sourceType: String
    public var scope: BarnOwlEnrichmentSourceScope
    public var authorityProfile: String
    public var bestUsedFor: [String]
    public var configJSON: String?

    public init(
        id: String,
        displayName: String,
        sourceType: String,
        scope: BarnOwlEnrichmentSourceScope,
        authorityProfile: String,
        bestUsedFor: [String] = [],
        configJSON: String? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.sourceType = sourceType
        self.scope = scope
        self.authorityProfile = authorityProfile
        self.bestUsedFor = bestUsedFor
        self.configJSON = configJSON
    }
}

public struct BarnOwlEnrichmentSourceHealthSnapshot: Codable, Equatable, Sendable {
    public var status: BarnOwlEnrichmentSourceHealthStatus
    public var authState: BarnOwlEnrichmentSourceAuthState
    public var checkedAt: Date
    public var detail: String?

    public init(
        status: BarnOwlEnrichmentSourceHealthStatus,
        authState: BarnOwlEnrichmentSourceAuthState,
        checkedAt: Date = Date(),
        detail: String? = nil
    ) {
        self.status = status
        self.authState = authState
        self.checkedAt = checkedAt
        self.detail = detail
    }
}

public struct BarnOwlControlEnrichmentSourcePreset: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var displayName: String
    public var sourceType: String
    public var scope: String
    public var scopeLabel: String
    public var authorityProfile: String
    public var connectorReference: String?
    public var bestUsedFor: [String]
    public var defaultAuthState: String
    public var defaultHealthStatus: String
    public var privacyCopyPolicy: String?
    public var queryBudgetPolicy: String?

    public init(
        id: String,
        displayName: String,
        sourceType: String,
        scope: String,
        scopeLabel: String,
        authorityProfile: String,
        connectorReference: String? = nil,
        bestUsedFor: [String],
        defaultAuthState: String,
        defaultHealthStatus: String,
        privacyCopyPolicy: String? = nil,
        queryBudgetPolicy: String? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.sourceType = sourceType
        self.scope = scope
        self.scopeLabel = scopeLabel
        self.authorityProfile = authorityProfile
        self.connectorReference = connectorReference
        self.bestUsedFor = bestUsedFor
        self.defaultAuthState = defaultAuthState
        self.defaultHealthStatus = defaultHealthStatus
        self.privacyCopyPolicy = privacyCopyPolicy
        self.queryBudgetPolicy = queryBudgetPolicy
    }
}

public protocol BarnOwlEnrichmentSourceAdapter: Sendable {
    var sourceID: String { get }
    func healthSnapshot(
        for source: BarnOwlEnrichmentSourceDescriptor
    ) async -> BarnOwlEnrichmentSourceHealthSnapshot
    func enrich(
        request: BarnOwlEnrichmentSourceRequest,
        source: BarnOwlEnrichmentSourceDescriptor
    ) async throws -> BarnOwlEnrichmentSourceResult
}

public enum BarnOwlEnrichmentEvidenceFreshness: String, Codable, CaseIterable, Equatable, Sendable {
    case current
    case recent
    case stale
    case unknown
}

public struct BarnOwlEnrichmentEvidenceRecord: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var subject: String
    public var candidateKind: String
    public var canonicalName: String
    public var summary: String
    public var confidence: Double
    public var sourceID: String
    public var sourceDisplayName: String
    public var authorityProfile: String
    public var freshness: BarnOwlEnrichmentEvidenceFreshness
    public var scope: BarnOwlEnrichmentSourceScope
    public var citations: [String]
    public var observedAt: Date
    public var contradiction: Bool
    public var negativeEvidence: Bool

    public init(
        id: UUID = UUID(),
        subject: String,
        candidateKind: String,
        canonicalName: String,
        summary: String,
        confidence: Double,
        sourceID: String,
        sourceDisplayName: String,
        authorityProfile: String,
        freshness: BarnOwlEnrichmentEvidenceFreshness = .unknown,
        scope: BarnOwlEnrichmentSourceScope,
        citations: [String] = [],
        observedAt: Date = Date(),
        contradiction: Bool = false,
        negativeEvidence: Bool = false
    ) {
        self.id = id
        self.subject = subject
        self.candidateKind = candidateKind
        self.canonicalName = canonicalName
        self.summary = summary
        self.confidence = min(max(confidence, 0), 1)
        self.sourceID = sourceID
        self.sourceDisplayName = sourceDisplayName
        self.authorityProfile = authorityProfile
        self.freshness = freshness
        self.scope = scope
        self.citations = citations
        self.observedAt = observedAt
        self.contradiction = contradiction
        self.negativeEvidence = negativeEvidence
    }
}

public struct BarnOwlEnrichmentSourceRequest: Equatable, Sendable {
    public var conceptKey: String
    public var limit: Int
    public var requestedAt: Date

    public init(
        conceptKey: String,
        limit: Int = 8,
        requestedAt: Date = Date()
    ) {
        self.conceptKey = conceptKey
        self.limit = max(1, limit)
        self.requestedAt = requestedAt
    }
}

public struct BarnOwlEnrichmentConfiguredSource: Equatable, Sendable {
    public var descriptor: BarnOwlEnrichmentSourceDescriptor
    public var enabled: Bool
    public var authState: BarnOwlEnrichmentSourceAuthState
    public var healthStatus: BarnOwlEnrichmentSourceHealthStatus
    public var routingPriority: Double

    public init(
        descriptor: BarnOwlEnrichmentSourceDescriptor,
        enabled: Bool,
        authState: BarnOwlEnrichmentSourceAuthState,
        healthStatus: BarnOwlEnrichmentSourceHealthStatus,
        routingPriority: Double = 0
    ) {
        self.descriptor = descriptor
        self.enabled = enabled
        self.authState = authState
        self.healthStatus = healthStatus
        self.routingPriority = routingPriority
    }

    public var isEligibleForAutomaticEnrichment: Bool {
        enabled
            && authState != .needsAuthentication
            && authState != .unavailable
            && healthStatus != .disabled
            && healthStatus != .needsAuth
            && healthStatus != .error
    }
}

public struct BarnOwlEnrichmentSourceResult: Equatable, Sendable {
    public var sourceID: String
    public var evidence: [BarnOwlEnrichmentEvidenceRecord]
    public var summary: String?
    public var caveats: [String]

    public init(
        sourceID: String,
        evidence: [BarnOwlEnrichmentEvidenceRecord],
        summary: String? = nil,
        caveats: [String] = []
    ) {
        self.sourceID = sourceID
        self.evidence = evidence
        self.summary = summary
        self.caveats = caveats
    }
}

public enum BarnOwlEnrichmentJobStatus: String, Codable, CaseIterable, Equatable, Sendable {
    case supportedCandidate = "supported_candidate"
    case heldInsufficientEvidence = "held_insufficient_evidence"
    case heldConflictingEvidence = "held_conflicting_evidence"
    case heldNoEligibleSources = "held_no_eligible_sources"
    case failed

    public var displayName: String {
        switch self {
        case .supportedCandidate:
            return "Supported candidate"
        case .heldInsufficientEvidence:
            return "Held: insufficient evidence"
        case .heldConflictingEvidence:
            return "Held: conflicting evidence"
        case .heldNoEligibleSources:
            return "Held: no eligible sources"
        case .failed:
            return "Failed"
        }
    }
}

public struct BarnOwlEnrichmentExecutionPolicy: Equatable, Sendable {
    public var minimumSupportingEvidenceCount: Int
    public var minimumIndependentSourceCountAfterConflictMemory: Int

    public init(
        minimumSupportingEvidenceCount: Int = 2,
        minimumIndependentSourceCountAfterConflictMemory: Int = 2
    ) {
        self.minimumSupportingEvidenceCount = max(1, minimumSupportingEvidenceCount)
        self.minimumIndependentSourceCountAfterConflictMemory = max(1, minimumIndependentSourceCountAfterConflictMemory)
    }
}

public struct BarnOwlEnrichmentConceptHistory: Equatable, Sendable {
    public var supportedCandidateJobs: Int
    public var conflictingJobs: Int
    public var negativeEvidenceItems: Int

    public init(
        supportedCandidateJobs: Int = 0,
        conflictingJobs: Int = 0,
        negativeEvidenceItems: Int = 0
    ) {
        self.supportedCandidateJobs = max(0, supportedCandidateJobs)
        self.conflictingJobs = max(0, conflictingJobs)
        self.negativeEvidenceItems = max(0, negativeEvidenceItems)
    }

    public var requiresConflictMemoryHold: Bool {
        conflictingJobs > 0 || negativeEvidenceItems > 0
    }
}

public struct BarnOwlEnrichmentRunResult: Equatable, Sendable {
    public var requestedSources: [String]
    public var selectedSources: [String]
    public var evidence: [BarnOwlEnrichmentEvidenceRecord]
    public var status: BarnOwlEnrichmentJobStatus
    public var summary: String
    public var rationale: String

    public init(
        requestedSources: [String],
        selectedSources: [String],
        evidence: [BarnOwlEnrichmentEvidenceRecord],
        status: BarnOwlEnrichmentJobStatus,
        summary: String,
        rationale: String
    ) {
        self.requestedSources = requestedSources
        self.selectedSources = selectedSources
        self.evidence = evidence
        self.status = status
        self.summary = summary
        self.rationale = rationale
    }
}

public struct BarnOwlEnrichmentOrchestrator: Sendable {
    private var adapters: [any BarnOwlEnrichmentSourceAdapter]
    private var policy: BarnOwlEnrichmentExecutionPolicy

    public init(
        adapters: [any BarnOwlEnrichmentSourceAdapter],
        policy: BarnOwlEnrichmentExecutionPolicy = .init()
    ) {
        self.adapters = adapters
        self.policy = policy
    }

    public func run(
        request: BarnOwlEnrichmentSourceRequest,
        sources: [BarnOwlEnrichmentConfiguredSource],
        conceptHistory: BarnOwlEnrichmentConceptHistory = .init()
    ) async -> BarnOwlEnrichmentRunResult {
        let requestedSources = sources
            .filter(\.enabled)
            .map(\.descriptor.id)
        let eligibleSources = sources.filter(\.isEligibleForAutomaticEnrichment)
        let adaptersBySourceID = Dictionary(
            uniqueKeysWithValues: adapters.map { ($0.sourceID, $0) }
        )
        let selectedSources = eligibleSources
            .filter { adaptersBySourceID[$0.descriptor.id] != nil }
            .sorted {
                if $0.routingPriority != $1.routingPriority {
                    return $0.routingPriority > $1.routingPriority
                }
                return $0.descriptor.id.localizedCaseInsensitiveCompare($1.descriptor.id) == .orderedAscending
            }

        guard !selectedSources.isEmpty else {
            return BarnOwlEnrichmentRunResult(
                requestedSources: requestedSources,
                selectedSources: [],
                evidence: [],
                status: .heldNoEligibleSources,
                summary: "Held enrichment for \(request.conceptKey): no eligible source adapter was available.",
                rationale: "Automatic enrichment requires at least one enabled, healthy, auth-ready configured source with an installed adapter."
            )
        }

        var evidence: [BarnOwlEnrichmentEvidenceRecord] = []
        var failedSources: [String] = []
        var caveats: [String] = []

        for configuredSource in selectedSources {
            guard let adapter = adaptersBySourceID[configuredSource.descriptor.id] else {
                continue
            }
            do {
                let result = try await adapter.enrich(
                    request: request,
                    source: configuredSource.descriptor
                )
                evidence.append(contentsOf: result.evidence)
                caveats.append(contentsOf: result.caveats)
            } catch {
                failedSources.append(configuredSource.descriptor.id)
            }
        }

        if evidence.isEmpty, failedSources.count == selectedSources.count {
            return BarnOwlEnrichmentRunResult(
                requestedSources: requestedSources,
                selectedSources: selectedSources.map(\.descriptor.id),
                evidence: [],
                status: .failed,
                summary: "Enrichment failed for \(request.conceptKey): every selected source adapter failed.",
                rationale: "Selected sources were eligible, but each adapter threw before producing normalized evidence."
            )
        }

        let explicitContradiction = evidence.contains { $0.contradiction || $0.negativeEvidence }
        let semanticCandidates = Set(
            evidence
                .filter { !$0.negativeEvidence && $0.candidateKind != "unresolved_concept" }
                .map { "\($0.candidateKind.lowercased())|\($0.canonicalName.lowercased())" }
        )
        let hasSemanticConflict = explicitContradiction || semanticCandidates.count > 1
        let semanticEvidence = evidence.filter {
            !$0.negativeEvidence
                && !$0.contradiction
                && $0.candidateKind != "unresolved_concept"
        }
        let hasNonPublicSupport = evidence.contains {
            !$0.negativeEvidence
                && !$0.contradiction
                && $0.scope != .publicReference
        }
        let publicOnlyPrivateTruthKinds: Set<String> = [
            "person",
            "project",
            "internal_project",
            "internal_term",
            "customer",
            "account",
            "workspace_event"
        ]
        let blocksPublicOnlyPrivateTruth = !semanticEvidence.isEmpty
            && !hasNonPublicSupport
            && semanticEvidence.allSatisfy { $0.scope == .publicReference }
            && semanticEvidence.contains {
                publicOnlyPrivateTruthKinds.contains($0.candidateKind.lowercased())
            }
        let independentSemanticSourceCount = Set(semanticEvidence.map(\.sourceID)).count
        let holdsForConflictMemory = conceptHistory.requiresConflictMemoryHold
            && independentSemanticSourceCount < policy.minimumIndependentSourceCountAfterConflictMemory
        let status: BarnOwlEnrichmentJobStatus
        if hasSemanticConflict {
            status = .heldConflictingEvidence
        } else if blocksPublicOnlyPrivateTruth {
            status = .heldInsufficientEvidence
        } else if holdsForConflictMemory {
            status = .heldConflictingEvidence
        } else if evidence.count >= policy.minimumSupportingEvidenceCount {
            status = .supportedCandidate
        } else {
            status = .heldInsufficientEvidence
        }
        let summary: String
        let rationale: String

        switch status {
        case .supportedCandidate:
            summary = "Recorded \(evidence.count) supporting evidence item\(evidence.count == 1 ? "" : "s") for \(request.conceptKey)."
            rationale = "The current automatic policy requires at least \(policy.minimumSupportingEvidenceCount) normalized evidence items across selected adapters before promoting a supported candidate."
        case .heldInsufficientEvidence:
            summary = evidence.isEmpty
                ? "Held enrichment for \(request.conceptKey): selected adapters found no supporting evidence."
                : "Held enrichment for \(request.conceptKey): selected adapters found only \(evidence.count) supporting evidence item\(evidence.count == 1 ? "" : "s")."
            rationale = blocksPublicOnlyPrivateTruth
                ? "Automatic persistence blocks public-only evidence from establishing private people, projects, customers, accounts, internal terms, or workspace events."
                : "The current automatic policy requires at least \(policy.minimumSupportingEvidenceCount) normalized evidence items before promoting a supported candidate."
        case .heldConflictingEvidence:
            if holdsForConflictMemory && !hasSemanticConflict {
                summary = "Held enrichment for \(request.conceptKey): prior conflict memory requires stronger corroboration before automatic persistence."
                rationale = "Concept history includes \(conceptHistory.conflictingJobs) prior conflicting job\(conceptHistory.conflictingJobs == 1 ? "" : "s") and \(conceptHistory.negativeEvidenceItems) prior negative evidence item\(conceptHistory.negativeEvidenceItems == 1 ? "" : "s"). Automatic persistence now requires support from at least \(policy.minimumIndependentSourceCountAfterConflictMemory) independent source adapters."
            } else {
                summary = "Held enrichment for \(request.conceptKey): selected adapters produced conflicting semantic evidence."
                rationale = "Automatic persistence is blocked when normalized evidence contains an explicit contradiction, negative evidence, or materially different semantic candidates."
            }
        case .heldNoEligibleSources, .failed:
            summary = "Held enrichment for \(request.conceptKey)."
            rationale = "The enrichment policy did not produce a supported candidate."
        }

        let failureSuffix = failedSources.isEmpty
            ? ""
            : " Adapter failures: \(failedSources.joined(separator: ", "))."
        let caveatSuffix = caveats.isEmpty
            ? ""
            : " Caveats: \(caveats.joined(separator: " | "))."

        return BarnOwlEnrichmentRunResult(
            requestedSources: requestedSources,
            selectedSources: selectedSources.map(\.descriptor.id),
            evidence: evidence,
            status: status,
            summary: summary,
            rationale: rationale + failureSuffix + caveatSuffix
        )
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

public struct BarnOwlControlEnrichmentSource: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var displayName: String
    public var sourceType: String
    public var enabled: Bool
    public var scope: String
    public var scopeLabel: String
    public var authorityProfile: String
    public var bestUsedFor: [String]
    public var authState: String
    public var healthStatus: String
    public var healthLabel: String
    public var lastCheckedAt: Date?
    public var lastSuccessfulCheckAt: Date?
    public var lastFailedCheckAt: Date?
    public var connectorReference: String?
    public var privacyCopyPolicy: String?
    public var queryBudgetPolicy: String?
    public var attempts: Int
    public var evidenceItems: Int
    public var acceptedEvidenceItems: Int
    public var supportedJobs: Int
    public var heldJobs: Int
    public var conflictingJobs: Int
    public var failedJobs: Int
    public var lastOutcomeStatus: String?

    public init(
        id: String,
        displayName: String,
        sourceType: String,
        enabled: Bool,
        scope: String,
        scopeLabel: String,
        authorityProfile: String,
        bestUsedFor: [String],
        authState: String,
        healthStatus: String,
        healthLabel: String,
        lastCheckedAt: Date? = nil,
        lastSuccessfulCheckAt: Date? = nil,
        lastFailedCheckAt: Date? = nil,
        connectorReference: String? = nil,
        privacyCopyPolicy: String? = nil,
        queryBudgetPolicy: String? = nil,
        attempts: Int = 0,
        evidenceItems: Int = 0,
        acceptedEvidenceItems: Int = 0,
        supportedJobs: Int = 0,
        heldJobs: Int = 0,
        conflictingJobs: Int = 0,
        failedJobs: Int = 0,
        lastOutcomeStatus: String? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.sourceType = sourceType
        self.enabled = enabled
        self.scope = scope
        self.scopeLabel = scopeLabel
        self.authorityProfile = authorityProfile
        self.bestUsedFor = bestUsedFor
        self.authState = authState
        self.healthStatus = healthStatus
        self.healthLabel = healthLabel
        self.lastCheckedAt = lastCheckedAt
        self.lastSuccessfulCheckAt = lastSuccessfulCheckAt
        self.lastFailedCheckAt = lastFailedCheckAt
        self.connectorReference = connectorReference
        self.privacyCopyPolicy = privacyCopyPolicy
        self.queryBudgetPolicy = queryBudgetPolicy
        self.attempts = attempts
        self.evidenceItems = evidenceItems
        self.acceptedEvidenceItems = acceptedEvidenceItems
        self.supportedJobs = supportedJobs
        self.heldJobs = heldJobs
        self.conflictingJobs = conflictingJobs
        self.failedJobs = failedJobs
        self.lastOutcomeStatus = lastOutcomeStatus
    }
}

public struct BarnOwlControlEnrichmentAuthorityProfile: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var displayName: String
    public var description: String
    public var strongestEntityKinds: [String]
    public var weakestEntityKinds: [String]
    public var defaultWeight: Double
    public var builtIn: Bool

    public init(
        id: String,
        displayName: String,
        description: String,
        strongestEntityKinds: [String],
        weakestEntityKinds: [String],
        defaultWeight: Double,
        builtIn: Bool
    ) {
        self.id = id
        self.displayName = displayName
        self.description = description
        self.strongestEntityKinds = strongestEntityKinds
        self.weakestEntityKinds = weakestEntityKinds
        self.defaultWeight = defaultWeight
        self.builtIn = builtIn
    }
}

public struct BarnOwlControlEnrichmentPolicyPack: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var displayName: String
    public var description: String
    public var minimumSupportingEvidenceCount: Int
    public var minimumIndependentSourceCountAfterConflictMemory: Int
    public var active: Bool

    public init(
        id: String,
        displayName: String,
        description: String,
        minimumSupportingEvidenceCount: Int,
        minimumIndependentSourceCountAfterConflictMemory: Int,
        active: Bool
    ) {
        self.id = id
        self.displayName = displayName
        self.description = description
        self.minimumSupportingEvidenceCount = max(1, minimumSupportingEvidenceCount)
        self.minimumIndependentSourceCountAfterConflictMemory = max(1, minimumIndependentSourceCountAfterConflictMemory)
        self.active = active
    }
}

public struct BarnOwlControlKnowledgeEntity: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var kind: String
    public var canonicalName: String
    public var summary: String?
    public var confidence: Double
    public var sourceJobID: UUID?
    public var lifecycleStatus: String
    public var lifecycleReason: String?
    public var lifecycleUpdatedAt: Date?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID,
        kind: String,
        canonicalName: String,
        summary: String? = nil,
        confidence: Double,
        sourceJobID: UUID? = nil,
        lifecycleStatus: String,
        lifecycleReason: String? = nil,
        lifecycleUpdatedAt: Date? = nil,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.kind = kind
        self.canonicalName = canonicalName
        self.summary = summary
        self.confidence = confidence
        self.sourceJobID = sourceJobID
        self.lifecycleStatus = lifecycleStatus
        self.lifecycleReason = lifecycleReason
        self.lifecycleUpdatedAt = lifecycleUpdatedAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct BarnOwlControlEnrichmentConflict: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var jobID: UUID
    public var ownerID: String
    public var conceptKey: String
    public var summary: String
    public var conflictingSourceIDs: [String]
    public var createdAt: Date

    public init(
        id: UUID,
        jobID: UUID,
        ownerID: String,
        conceptKey: String,
        summary: String,
        conflictingSourceIDs: [String],
        createdAt: Date
    ) {
        self.id = id
        self.jobID = jobID
        self.ownerID = ownerID
        self.conceptKey = conceptKey
        self.summary = summary
        self.conflictingSourceIDs = conflictingSourceIDs
        self.createdAt = createdAt
    }
}

public struct BarnOwlControlEnrichmentConceptHistory: Codable, Equatable, Identifiable, Sendable {
    public var id: String { conceptKey.lowercased() }
    public var conceptKey: String
    public var supportedCandidateJobs: Int
    public var conflictingJobs: Int
    public var negativeEvidenceItems: Int
    public var requiresConflictMemoryHold: Bool

    public init(
        conceptKey: String,
        supportedCandidateJobs: Int,
        conflictingJobs: Int,
        negativeEvidenceItems: Int,
        requiresConflictMemoryHold: Bool
    ) {
        self.conceptKey = conceptKey
        self.supportedCandidateJobs = max(0, supportedCandidateJobs)
        self.conflictingJobs = max(0, conflictingJobs)
        self.negativeEvidenceItems = max(0, negativeEvidenceItems)
        self.requiresConflictMemoryHold = requiresConflictMemoryHold
    }
}

public struct BarnOwlControlEnrichmentJob: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var ownerID: String
    public var conceptKey: String
    public var requestedSources: [String]
    public var selectedSources: [String]
    public var status: String
    public var statusLabel: String
    public var summary: String
    public var rationale: String?
    public var evidenceCount: Int
    public var createdAt: Date
    public var updatedAt: Date
    public var finishedAt: Date?

    public init(
        id: UUID,
        ownerID: String,
        conceptKey: String,
        requestedSources: [String],
        selectedSources: [String],
        status: String,
        statusLabel: String,
        summary: String,
        rationale: String? = nil,
        evidenceCount: Int,
        createdAt: Date,
        updatedAt: Date,
        finishedAt: Date? = nil
    ) {
        self.id = id
        self.ownerID = ownerID
        self.conceptKey = conceptKey
        self.requestedSources = requestedSources
        self.selectedSources = selectedSources
        self.status = status
        self.statusLabel = statusLabel
        self.summary = summary
        self.rationale = rationale
        self.evidenceCount = evidenceCount
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.finishedAt = finishedAt
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
    public var enrichmentSources: [BarnOwlControlEnrichmentSource]?
    public var enrichmentSourcePresets: [BarnOwlControlEnrichmentSourcePreset]?
    public var enrichmentAuthorityProfiles: [BarnOwlControlEnrichmentAuthorityProfile]?
    public var enrichmentPolicyPacks: [BarnOwlControlEnrichmentPolicyPack]?
    public var enrichmentJobs: [BarnOwlControlEnrichmentJob]?
    public var enrichmentEvidence: [BarnOwlEnrichmentEvidenceRecord]?
    public var enrichmentConflicts: [BarnOwlControlEnrichmentConflict]?
    public var enrichmentConceptHistories: [BarnOwlControlEnrichmentConceptHistory]?
    public var knowledgeEntities: [BarnOwlControlKnowledgeEntity]?
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
        enrichmentSources: [BarnOwlControlEnrichmentSource]? = nil,
        enrichmentSourcePresets: [BarnOwlControlEnrichmentSourcePreset]? = nil,
        enrichmentAuthorityProfiles: [BarnOwlControlEnrichmentAuthorityProfile]? = nil,
        enrichmentPolicyPacks: [BarnOwlControlEnrichmentPolicyPack]? = nil,
        enrichmentJobs: [BarnOwlControlEnrichmentJob]? = nil,
        enrichmentEvidence: [BarnOwlEnrichmentEvidenceRecord]? = nil,
        enrichmentConflicts: [BarnOwlControlEnrichmentConflict]? = nil,
        enrichmentConceptHistories: [BarnOwlControlEnrichmentConceptHistory]? = nil,
        knowledgeEntities: [BarnOwlControlKnowledgeEntity]? = nil,
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
        self.enrichmentSources = enrichmentSources
        self.enrichmentSourcePresets = enrichmentSourcePresets
        self.enrichmentAuthorityProfiles = enrichmentAuthorityProfiles
        self.enrichmentPolicyPacks = enrichmentPolicyPacks
        self.enrichmentJobs = enrichmentJobs
        self.enrichmentEvidence = enrichmentEvidence
        self.enrichmentConflicts = enrichmentConflicts
        self.enrichmentConceptHistories = enrichmentConceptHistories
        self.knowledgeEntities = knowledgeEntities
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

import BarnOwlCore
import BarnOwlPersistence
import Foundation

enum BarnOwlRealtimeTranscriptionHintsStore {
    private static let fileName = "realtime-transcription-hints.json"
    private static let maxStoredTerms = 80
    private static let maxPromptTerms = 28
    private static let maxCuratedEntities = 12
    private static let maxAliasesPerCuratedEntity = 2

    static func currentPrompt(
        attachedContext: [String] = [],
        curatedTerms: [String] = [],
        fileURL: URL = defaultFileURL()
    ) -> String? {
        let learnedTerms = (try? load(fileURL: fileURL))?.terms ?? []
        let orderedTerms = normalizedTerms(
            contextHintTerms(from: attachedContext)
                + curatedTerms
                + learnedTerms
        )

        let terms = orderedTerms.prefix(maxPromptTerms).joined(separator: ", ")
        guard !terms.isEmpty else {
            return nil
        }

        return """
        Use these Barn Owl vocabulary hints in source order: current meeting context first, curated Context Library entries second, compact learned transcript hints last. Prefer these spellings when the audio matches: \(terms).
        Keep transcription literal; do not add words that were not spoken.
        """
    }

    static func curatedHintTerms(
        database: BarnOwlDatabase,
        ownerID: String,
        attachedContext: [String] = []
    ) async throws -> [String] {
        let normalizedContext = BarnOwlKnowledgeEntityRecord.normalized(attachedContext.joined(separator: "\n"))
        let entities = try await database.knowledgeEntities(ownerID: ownerID, limit: maxCuratedEntities * 4)
        var ranked: [(entity: BarnOwlKnowledgeEntityRecord, aliases: [BarnOwlKnowledgeAliasRecord], relevance: Int)] = []

        for entity in entities {
            let aliases = try await database.knowledgeAliases(entityID: entity.id)
            let candidateTerms = [entity.normalizedCanonicalName] + aliases.map(\.normalizedAlias)
            let relevance = candidateTerms.contains { !$0.isEmpty && normalizedContext.contains($0) } ? 1 : 0
            ranked.append((entity, aliases, relevance))
        }

        return normalizedTerms(
            ranked
                .sorted {
                    if $0.relevance != $1.relevance { return $0.relevance > $1.relevance }
                    if $0.entity.confidence != $1.entity.confidence { return $0.entity.confidence > $1.entity.confidence }
                    if $0.entity.updatedAt != $1.entity.updatedAt { return $0.entity.updatedAt > $1.entity.updatedAt }
                    return $0.entity.canonicalName.localizedCaseInsensitiveCompare($1.entity.canonicalName) == .orderedAscending
                }
                .prefix(maxCuratedEntities)
                .flatMap { item in
                    [item.entity.canonicalName]
                        + item.aliases
                            .prefix(maxAliasesPerCuratedEntity)
                            .map(\.alias)
                }
        )
    }

    static func learn(
        meetingFacts: MeetingFacts,
        segments: [TranscriptSegment],
        fileURL: URL = defaultFileURL()
    ) {
        let learnedTerms = terms(from: meetingFacts, segments: segments)
        guard !learnedTerms.isEmpty else { return }

        do {
            var hints = (try? load(fileURL: fileURL)) ?? RealtimeTranscriptionHints()
            hints.merge(learnedTerms)
            try save(hints, fileURL: fileURL)
        } catch {
            // Realtime hints are opportunistic. Final transcript saving must never fail because hints failed.
        }
    }

    static func terms(
        from meetingFacts: MeetingFacts,
        segments: [TranscriptSegment]
    ) -> [String] {
        var candidates: [String] = []
        candidates += meetingFacts.participants
        candidates += meetingFacts.organizations
        candidates += meetingFacts.customers
        candidates += meetingFacts.projects
        candidates += meetingFacts.glossary.keys
        candidates += meetingFacts.glossary.values
        return normalizedTerms(candidates)
    }

    private static func load(fileURL: URL) throws -> RealtimeTranscriptionHints {
        let data = try Data(contentsOf: fileURL)
        return try JSONDecoder().decode(RealtimeTranscriptionHints.self, from: data)
    }

    private static func save(_ hints: RealtimeTranscriptionHints, fileURL: URL) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: nil
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        let data = try encoder.encode(hints)
        try data.write(to: fileURL, options: [.atomic])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }

    private static func defaultFileURL() -> URL {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        return root
            .appending(path: "Barn Owl", directoryHint: .isDirectory)
            .appending(path: fileName, directoryHint: .notDirectory)
    }

    static func normalizedTerms(_ terms: [String]) -> [String] {
        var seen: Set<String> = []
        var normalized: [String] = []

        for term in terms {
            guard let cleaned = MeetingFacts.clean(term),
                  cleaned.count >= 2,
                  cleaned.count <= 60,
                  shouldKeepTerm(cleaned)
            else {
                continue
            }

            let key = cleaned.lowercased()
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            normalized.append(cleaned)
        }

        return Array(normalized.prefix(maxStoredTerms))
    }

    private static func contextHintTerms(from lines: [String]) -> [String] {
        let acceptedPrefixes = [
            "meeting title:",
            "calendar event:",
            "calendar attendees:",
            "participants:",
            "customer:",
            "customers:",
            "account:",
            "accounts:",
            "organization:",
            "organizations:",
            "known person:",
            "known organization:",
            "known company:",
            "known customer:",
            "known customer_account:",
            "known project:",
            "known product:",
            "known program:",
            "known glossary_term:"
        ]

        var output: [String] = []
        for line in lines {
            let cleaned = line.trimmingCharacters(in: .whitespacesAndNewlines)
            let normalized = cleaned
                .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
                .lowercased()
            guard let prefix = acceptedPrefixes.first(where: normalized.hasPrefix) else {
                continue
            }
            guard let separator = cleaned.firstIndex(of: ":") else {
                continue
            }
            let value = String(cleaned[cleaned.index(after: separator)...])
            let terms: [String]
            if prefix.contains("attendees")
                || prefix.contains("participants")
                || prefix.contains("customers")
                || prefix.contains("accounts")
                || prefix.contains("organizations") {
                terms = value
                    .replacingOccurrences(of: " and ", with: ", ")
                    .split(separator: ",")
                    .map { String($0) }
            } else {
                terms = [value]
            }
            output.append(contentsOf: terms)
        }
        return output
    }

    private static func shouldKeepTerm(_ term: String) -> Bool {
        let normalized = term
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !normalized.localizedCaseInsensitiveContains("untitled meeting") else { return false }
        guard !normalized.localizedCaseInsensitiveContains("conservative learned spelling hints") else { return false }
        guard !normalized.localizedCaseInsensitiveContains("smoke") else { return false }
        guard !normalized.localizedCaseInsensitiveContains("test") else { return false }

        let genericTerms: Set<String> = [
            "general discussion",
            "planning review",
            "planning / review",
            "team meeting",
            "customer workshop",
            "customer pitch",
            "interview",
            "hallway random capture",
            "hallway/random capture",
            "incident review",
            "room speaker a",
            "room speaker b",
            "call speaker a",
            "call speaker b",
            "speaker a",
            "speaker b",
            "room",
            "sure",
            "life"
        ]
        guard !genericTerms.contains(normalized) else { return false }
        guard !normalized.hasPrefix("room speaker ") else { return false }
        guard !normalized.hasPrefix("call speaker ") else { return false }
        guard !normalized.hasPrefix("speaker ") else { return false }

        return true
    }
}

struct RealtimeTranscriptionHints: Codable, Equatable, Sendable {
    var terms: [String] = []
    var updatedAt: Date?

    mutating func merge(_ newTerms: [String]) {
        terms = BarnOwlRealtimeTranscriptionHintsStore.normalizedTerms(terms + newTerms)
        updatedAt = Date()
    }
}

import BarnOwlCore
import Foundation

enum BarnOwlRealtimeTranscriptionHintsStore {
    private static let fileName = "realtime-transcription-hints.json"
    private static let maxStoredTerms = 80
    private static let maxPromptTerms = 28

    static func currentPrompt(
        fileURL: URL = defaultFileURL()
    ) -> String? {
        guard let hints = try? load(fileURL: fileURL),
              !hints.terms.isEmpty
        else {
            return nil
        }

        let terms = normalizedTerms(hints.terms).prefix(maxPromptTerms).joined(separator: ", ")
        guard !terms.isEmpty else {
            return nil
        }

        return """
        Use these local Barn Owl vocabulary hints learned from prior final transcripts. Prefer these spellings when the audio matches: \(terms).
        Keep transcription literal; do not add words that were not spoken.
        """
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

    private static func shouldKeepTerm(_ term: String) -> Bool {
        let normalized = term
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !normalized.localizedCaseInsensitiveContains("untitled meeting") else { return false }
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
            "speaker b"
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

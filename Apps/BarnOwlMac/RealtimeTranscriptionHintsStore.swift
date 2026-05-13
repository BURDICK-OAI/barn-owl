import BarnOwlContext
import BarnOwlCore
import Foundation

enum BarnOwlRealtimeTranscriptionHintsStore {
    private static let fileName = "realtime-transcription-hints.json"
    private static let maxStoredTerms = 80
    private static let maxPromptTerms = 28

    static func currentPrompt(
        fileURL: URL = defaultFileURL()
    ) -> String? {
        let terms = currentTerms(fileURL: fileURL).prefix(maxPromptTerms).joined(separator: ", ")
        guard !terms.isEmpty else {
            return nil
        }

        return """
        Use these local Barn Owl vocabulary hints learned from prior final transcripts. Prefer these spellings when the audio matches: \(terms).
        Keep transcription literal; do not add words that were not spoken.
        """
    }

    static func currentTerms(
        fileURL: URL = defaultFileURL()
    ) -> [String] {
        guard let hints = try? load(fileURL: fileURL),
              !hints.terms.isEmpty
        else {
            return []
        }

        return normalizedTerms(hints.terms)
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

enum BarnOwlRealtimeTranscriptionPromptBuilder {
    private static let maxParticipantNames = 12
    private static let maxSessionTerms = 12
    private static let maxLearnedTerms = 8

    static func prompt(
        calendarContext: CalendarMeetingContext?,
        sessionTitle: String?,
        learnedTerms: [String] = BarnOwlRealtimeTranscriptionHintsStore.currentTerms()
    ) -> String? {
        let highConfidenceCalendarContext = calendarContext?.isHighConfidence == true ? calendarContext : nil
        let participantNames = highConfidenceCalendarContext
            .map { CalendarAttendeeNameNormalizer.displayNames(from: $0.attendees) }
            .map { conservativeParticipantNames($0) } ?? []

        var sessionTerms: [String] = []
        if let highConfidenceCalendarContext {
            sessionTerms += properNounTerms(from: highConfidenceCalendarContext.title)
        }
        if let sessionTitle {
            sessionTerms += properNounTerms(from: sessionTitle)
        }
        sessionTerms = normalizedTerms(sessionTerms)

        let learned = normalizedTerms(learnedTerms)
            .filter(shouldUseLearnedTerm)
            .filter { term in
                !participantNames.contains { $0.localizedCaseInsensitiveCompare(term) == .orderedSame }
                    && !sessionTerms.contains { $0.localizedCaseInsensitiveCompare(term) == .orderedSame }
            }

        let limitedParticipantNames = Array(participantNames.prefix(maxParticipantNames))
        let limitedSessionTerms = Array(sessionTerms.prefix(maxSessionTerms))
        let limitedLearnedTerms = Array(learned.prefix(maxLearnedTerms))
        guard !limitedParticipantNames.isEmpty || !limitedSessionTerms.isEmpty || !limitedLearnedTerms.isEmpty else {
            return nil
        }

        var lines = ["This is live meeting transcription."]
        if !limitedParticipantNames.isEmpty {
            lines.append("Likely participant names: \(limitedParticipantNames.joined(separator: ", ")).")
        }
        if !limitedSessionTerms.isEmpty {
            lines.append("Likely meeting-specific proper nouns: \(limitedSessionTerms.joined(separator: ", ")).")
        }
        if !limitedLearnedTerms.isEmpty {
            lines.append("Conservative learned spelling hints: \(limitedLearnedTerms.joined(separator: ", ")).")
        }
        lines.append("Use these only as spelling hints when the audio sounds like them.")
        lines.append("Do not insert any name, company, project, or topic solely because it appears in this list.")
        lines.append("Keep transcription literal; do not add words that were not spoken.")
        return lines.joined(separator: "\n")
    }

    private static func conservativeParticipantNames(_ names: [String]) -> [String] {
        normalizedTerms(names)
            .filter { name in
                !name.contains("@")
                    && !isGenericTerm(name)
                    && name.split(whereSeparator: \.isWhitespace).count <= 4
            }
    }

    private static func properNounTerms(from text: String) -> [String] {
        let cleaned = text
            .replacingOccurrences(of: #"[/:<>\|\(\)\[\],;]+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return [] }

        let words = cleaned
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)

        var terms: [String] = []
        var run: [String] = []

        func flushRun() {
            guard !run.isEmpty else { return }
            if run.count <= 3 {
                terms.append(run.joined(separator: " "))
            } else {
                terms.append(contentsOf: run)
            }
            run.removeAll()
        }

        for word in words {
            let trimmed = word.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
            guard !trimmed.isEmpty else {
                flushRun()
                continue
            }

            if isProperNounToken(trimmed), !isGenericTerm(trimmed) {
                run.append(trimmed)
            } else {
                flushRun()
            }
        }
        flushRun()

        return terms
    }

    private static func shouldUseLearnedTerm(_ term: String) -> Bool {
        guard !isGenericTerm(term),
              !term.contains("@"),
              term.count <= 60,
              !looksLikePersonName(term)
        else {
            return false
        }

        return term.range(of: #"\d"#, options: .regularExpression) != nil
            || term.range(of: #"\b[A-Z]{2,}\b"#, options: .regularExpression) != nil
            || containsProductMarker(term)
            || containsOrganizationMarker(term)
    }

    private static func looksLikePersonName(_ term: String) -> Bool {
        let words = term
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
        guard words.count == 2 || words.count == 3 else { return false }
        guard !containsProductMarker(term), !containsOrganizationMarker(term) else { return false }

        return words.allSatisfy { word in
            word.range(of: #"^[A-Z][a-z'\-]+$"#, options: .regularExpression) != nil
        }
    }

    private static func isProperNounToken(_ token: String) -> Bool {
        token.range(of: #"^[A-Z][A-Za-z0-9'\-]*$"#, options: .regularExpression) != nil
            || token.range(of: #"^[A-Z0-9]{2,}$"#, options: .regularExpression) != nil
    }

    private static func normalizedTerms(_ terms: [String]) -> [String] {
        var seen: Set<String> = []
        var normalized: [String] = []

        for term in terms {
            guard let cleaned = MeetingFacts.clean(term),
                  cleaned.count >= 2,
                  cleaned.count <= 60,
                  !isGenericTerm(cleaned)
            else {
                continue
            }

            let key = cleaned
                .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
                .lowercased()
            guard seen.insert(key).inserted else { continue }
            normalized.append(cleaned)
        }

        return normalized
    }

    private static func isGenericTerm(_ term: String) -> Bool {
        let normalized = term
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let genericTerms: Set<String> = [
            "candidate", "customer", "customers", "daily", "demo", "discussion",
            "follow up", "interview", "launch", "meeting", "planning", "review",
            "roadmap", "sync", "team", "untitled", "weekly", "workshop"
        ]
        return genericTerms.contains(normalized)
    }

    private static func containsProductMarker(_ term: String) -> Bool {
        let markers = ["API", "Barn Owl", "ChatGPT", "Codex", "GPT", "OpenAI", "SDK"]
        return markers.contains { marker in
            term.range(of: marker, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
    }

    private static func containsOrganizationMarker(_ term: String) -> Bool {
        let markers = ["Corp", "Corporation", "Inc", "LLC", "Ltd", "University"]
        return markers.contains { marker in
            term.range(of: #"\b\#(marker)\b"#, options: [.regularExpression, .caseInsensitive]) != nil
        }
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

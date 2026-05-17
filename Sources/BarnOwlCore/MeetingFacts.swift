import Foundation

public struct MeetingFacts: Codable, Equatable, Sendable {
    public var title: String?
    public var meetingType: String?
    public var participants: [String]
    public var organizations: [String]
    public var customers: [String]
    public var projects: [String]
    public var glossary: [String: String]
    public var goals: [String]
    public var additionalContext: [String]
    public var confidence: MeetingFactsConfidence
    public var sources: [String: String]

    public init(
        title: String? = nil,
        meetingType: String? = nil,
        participants: [String] = [],
        organizations: [String] = [],
        customers: [String] = [],
        projects: [String] = [],
        glossary: [String: String] = [:],
        goals: [String] = [],
        additionalContext: [String] = [],
        confidence: MeetingFactsConfidence = MeetingFactsConfidence(),
        sources: [String: String] = [:]
    ) {
        self.title = title
        self.meetingType = meetingType
        self.participants = MeetingFacts.normalizedList(participants)
        self.organizations = MeetingFacts.normalizedList(organizations)
        self.customers = MeetingFacts.normalizedList(customers)
        self.projects = MeetingFacts.normalizedList(projects)
        self.glossary = glossary
        self.goals = MeetingFacts.normalizedList(goals)
        self.additionalContext = MeetingFacts.normalizedList(additionalContext)
        self.confidence = confidence
        self.sources = sources
    }

    public var displaySummary: String {
        var pieces: [String] = []
        if let type = MeetingFacts.clean(meetingType) {
            pieces.append("a \(type.lowercased())")
        } else {
            pieces.append("a meeting")
        }
        if !participants.isEmpty {
            pieces.append("with \(participants.joined(separator: ", "))")
        }
        if let organization = customers.first ?? organizations.first {
            pieces.append("about \(organization)")
        }
        if let title = MeetingFacts.clean(title) {
            return "Barn Owl thinks this was \(pieces.joined(separator: " ")) called \(title)."
        }
        return "Barn Owl thinks this was \(pieces.joined(separator: " "))."
    }

    public var contextLines: [String] {
        var lines: [String] = []
        if let title = MeetingFacts.clean(title) {
            lines.append("Meeting title: \(title)")
        }
        if let meetingType = MeetingFacts.clean(meetingType) {
            lines.append("Meeting type: \(meetingType)")
        }
        if !participants.isEmpty {
            lines.append("Participants: \(participants.joined(separator: ", "))")
        }
        if !customers.isEmpty {
            lines.append("Customers: \(customers.joined(separator: ", "))")
        }
        if !organizations.isEmpty {
            lines.append("Organizations: \(organizations.joined(separator: ", "))")
        }
        if !projects.isEmpty {
            lines.append("Projects: \(projects.joined(separator: ", "))")
        }
        if !goals.isEmpty {
            lines.append("Goals: \(goals.joined(separator: "; "))")
        }
        if !glossary.isEmpty {
            for key in glossary.keys.sorted() {
                if let value = glossary[key] {
                    lines.append("\(key): \(value)")
                }
            }
        }
        lines.append(contentsOf: additionalContext)
        return lines
    }

    public func encodedJSONString() -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(self) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    public static func decoded(from json: String?) -> MeetingFacts? {
        guard let json,
              let data = json.data(using: .utf8)
        else { return nil }
        return try? JSONDecoder().decode(MeetingFacts.self, from: data)
    }

    public static func normalizedList(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        var output: [String] = []
        for value in values {
            guard let cleaned = clean(value) else { continue }
            let key = cleaned.lowercased()
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            output.append(cleaned)
        }
        return output
    }

    public static func clean(_ value: String?) -> String? {
        let cleaned = value?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: #""'`“”‘’.,;_"#))
        guard let cleaned, !cleaned.isEmpty else { return nil }
        return cleaned
    }
}

public struct MeetingFactsConfidence: Codable, Equatable, Sendable {
    public var title: Double
    public var meetingType: Double
    public var participants: Double
    public var organizations: Double
    public var context: Double

    public init(
        title: Double = 0,
        meetingType: Double = 0,
        participants: Double = 0,
        organizations: Double = 0,
        context: Double = 0
    ) {
        self.title = title
        self.meetingType = meetingType
        self.participants = participants
        self.organizations = organizations
        self.context = context
    }
}

public struct ContextReviewPrompt: Codable, Equatable, Identifiable, Sendable {
    public enum Kind: String, Codable, Equatable, Sendable {
        case title
        case participants
        case acronym
        case organization
        case actionOwner
    }

    public var id: String
    public var kind: Kind
    public var text: String

    public init(kind: Kind, text: String) {
        self.id = "\(kind.rawValue):\(text)"
        self.kind = kind
        self.text = text
    }
}

public enum ContextEntityKind: String, Codable, CaseIterable, Equatable, Sendable {
    case person
    case organization
    case customerAccount = "customer_account"
    case internalFunction = "internal_function"
    case product
    case project
    case glossaryTerm = "glossary_term"
}

public enum ContextEntityReviewAction: String, Codable, Equatable, Sendable {
    case accept
    case edit
    case ignore
}

public struct ContextEntitySuggestion: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var kind: ContextEntityKind
    public var observedValue: String
    public var canonicalValue: String
    public var rationale: String
    public var confidence: Double
    public var evidenceSources: [String]

    public init(
        id: UUID = UUID(),
        kind: ContextEntityKind,
        observedValue: String,
        canonicalValue: String,
        rationale: String,
        confidence: Double,
        evidenceSources: [String]
    ) {
        self.id = id
        self.kind = kind
        self.observedValue = observedValue
        self.canonicalValue = canonicalValue
        self.rationale = rationale
        self.confidence = min(max(confidence, 0), 1)
        self.evidenceSources = MeetingFacts.normalizedList(evidenceSources)
    }
}

public struct BarnOwlContextReview: Codable, Equatable, Sendable {
    public var meetingID: UUID
    public var suggestedSummary: String
    public var prompts: [ContextReviewPrompt]
    public var facts: MeetingFacts
    public var entitySuggestions: [ContextEntitySuggestion]
    public var ready: Bool

    public init(
        meetingID: UUID,
        suggestedSummary: String,
        prompts: [ContextReviewPrompt],
        facts: MeetingFacts,
        entitySuggestions: [ContextEntitySuggestion] = [],
        ready: Bool = true
    ) {
        self.meetingID = meetingID
        self.suggestedSummary = suggestedSummary
        self.prompts = prompts
        self.facts = facts
        self.entitySuggestions = entitySuggestions
        self.ready = ready
    }
}

public struct MeetingFactsExtractor: Sendable {
    public init() {}

    public func extract(
        transcript: String,
        freeformContext: String = "",
        existingFacts: MeetingFacts? = nil,
        currentTitle: String? = nil
    ) -> MeetingFacts {
        let combined = [transcript, freeformContext]
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .joined(separator: "\n")
        let lowercased = combined.lowercased()
        var facts = existingFacts ?? MeetingFacts()
        var sources = facts.sources

        if let title = explicitTitle(in: freeformContext) {
            facts.title = title
            facts.confidence.title = 0.95
            sources["title"] = "user_context"
        } else if facts.title == nil,
                  let current = MeetingFacts.clean(currentTitle),
                  !Self.isGenericTitle(current) {
            facts.title = current
            facts.confidence.title = max(facts.confidence.title, 0.8)
            sources["title"] = "current_title"
        } else if facts.title == nil,
                  let inferred = inferredTitle(from: combined) {
            facts.title = inferred
            facts.confidence.title = 0.55
            sources["title"] = "inferred"
        }

        if let type = explicitMeetingType(in: lowercased) {
            facts.meetingType = type
            facts.confidence.meetingType = 0.92
            sources["meetingType"] = freeformContext.isEmpty ? "transcript" : "user_context"
        } else if facts.meetingType == nil {
            facts.meetingType = "General Discussion"
            facts.confidence.meetingType = 0.35
            sources["meetingType"] = "default"
        }

        let participants = Self.merge(
            facts.participants,
            participantsFromSpeakerLabels(transcript),
            participantsFromContext(freeformContext)
        )
        facts.participants = participants
        if !participants.isEmpty {
            facts.confidence.participants = participantsFromContext(freeformContext).isEmpty ? 0.65 : 0.9
            sources["participants"] = participantsFromContext(freeformContext).isEmpty ? "transcript" : "user_context"
        }

        let organizations = Self.merge(facts.organizations, organizationsFrom(combined))
        facts.organizations = organizations
        facts.customers = Self.merge(facts.customers, customersFrom(combined, organizations: organizations))
        if !facts.organizations.isEmpty || !facts.customers.isEmpty {
            facts.confidence.organizations = lowercased.contains("customer") || lowercased.contains("account") ? 0.85 : 0.62
            sources["organizations"] = freeformContext.isEmpty ? "transcript" : "user_context"
        }

        facts.projects = Self.merge(facts.projects, projectsFrom(combined))
        facts.goals = Self.merge(facts.goals, goalsFrom(combined))
        facts.glossary.merge(glossaryFrom(combined)) { _, new in new }

        if let context = MeetingFacts.clean(freeformContext) {
            facts.additionalContext = Self.merge(facts.additionalContext, [context])
            facts.confidence.context = 0.9
            sources["additionalContext"] = "user_context"
        } else if !combined.isEmpty {
            facts.confidence.context = max(facts.confidence.context, 0.45)
        }

        facts.sources = sources
        return facts
    }

    private func explicitTitle(in text: String) -> String? {
        firstMatch(in: text, patterns: [
            #"(?i)\bcall it\s+([^.\n]+)"#,
            #"(?i)\bcalled\s+([^.\n]+)"#,
            #"(?i)\btitle(?: should be| is|:)?\s+([^.\n]+)"#,
            #"(?i)\bname(?: this| it)?\s+([^.\n]+)"#
        ]).flatMap { MeetingFacts.clean($0) }
    }

    private func inferredTitle(from text: String) -> String? {
        let words = text
            .split { !$0.isLetter && !$0.isNumber && $0 != "-" }
            .map(String.init)
            .filter { word in
                word.count > 2 && !Self.titleStopWords.contains(word.lowercased())
            }
            .prefix(6)
        let title = words
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
        return MeetingFacts.clean(title)
    }

    private func explicitMeetingType(in lowercased: String) -> String? {
        let matches: [(String, String)] = [
            ("one-on-one", "One-on-One"),
            ("one on one", "One-on-One"),
            ("1:1", "One-on-One"),
            ("customer workshop", "Customer Workshop"),
            ("workshop", "Customer Workshop"),
            ("customer pitch", "Customer Pitch"),
            ("pitch", "Customer Pitch"),
            ("interview", "Interview"),
            ("hallway", "Hallway / Random Capture"),
            ("random meeting", "Hallway / Random Capture"),
            ("planning", "Planning / Review"),
            ("review", "Planning / Review"),
            ("team meeting", "Team Meeting"),
            ("weekly sync", "Team Meeting"),
            ("incident", "Incident Review"),
            ("postmortem", "Incident Review")
        ]
        return matches.first { lowercased.contains($0.0) }?.1
    }

    private func participantsFromSpeakerLabels(_ transcript: String) -> [String] {
        transcript
            .split(separator: "\n", omittingEmptySubsequences: true)
            .compactMap { line -> String? in
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard let colon = trimmed.firstIndex(of: ":") else { return nil }
                let name = String(trimmed[..<colon])
                return Self.isLikelyPersonName(name) ? name : nil
            }
    }

    private func participantsFromContext(_ text: String) -> [String] {
        var names: [String] = []
        names += commaAndAndList(after: #"(?i)\bwith\s+"#, in: text)
        names += commaAndAndList(after: #"(?i)\bparticipants?:\s+"#, in: text)
        names += commaAndAndList(after: #"(?i)\battendees?:\s+"#, in: text)
        names += firstMatches(in: text, pattern: #"(?i)\b([A-Z][a-z]{2,}) was there too\b"#)
        names += firstMatches(in: text, pattern: #"(?i)\b([A-Z][a-z]{2,}) was there\b"#)
        return names.filter(Self.isLikelyPersonName)
    }

    private func organizationsFrom(_ text: String) -> [String] {
        var names: [String] = []
        names += firstMatches(in: text, pattern: #"\b(?:about|for|with|related to|customer|account)\s+([A-Z][A-Za-z0-9&.-]{2,})\b"#)
        names += firstMatches(in: text, pattern: #"\b([A-Z][A-Za-z0-9&.-]{2,})\s+(?:renewal|rollout|pricing|implementation|workshop|pitch|account)\b"#)
        return names.filter(Self.isLikelyOrganizationName)
    }

    private func customersFrom(_ text: String, organizations: [String]) -> [String] {
        let lowercased = text.lowercased()
        guard lowercased.contains("customer") || lowercased.contains("account") || lowercased.contains("renewal") else {
            return []
        }
        return organizations
    }

    private func projectsFrom(_ text: String) -> [String] {
        firstMatches(in: text, pattern: #"(?i)\b([A-Z][A-Za-z0-9&.-]+(?:\s+[A-Za-z0-9&.-]+){0,3}\s+(?:rollout|launch|migration|planning|project))\b"#)
    }

    private func goalsFrom(_ text: String) -> [String] {
        firstMatches(in: text, pattern: #"(?i)\b(?:goal|main thing|objective)\s+(?:is|was|:)?\s*([^.\n]+)"#)
    }

    private func glossaryFrom(_ text: String) -> [String: String] {
        var output: [String: String] = [:]
        for match in matches(in: text, pattern: #"\b([A-Z]{2,})\s+(?:means|=|stands for)\s+([A-Za-z][A-Za-z \-]+)"#) {
            guard match.count >= 3,
                  let key = MeetingFacts.clean(match[1]),
                  let value = MeetingFacts.clean(match[2])
            else { continue }
            output[key] = value
        }
        return output
    }

    private func commaAndAndList(after prefixPattern: String, in text: String) -> [String] {
        firstMatches(in: text, pattern: prefixPattern + #"([^.\n]+)"#)
            .flatMap {
                $0.replacingOccurrences(
                    of: #"(?i)\s+\b(?:about|for|on|regarding|related to)\b.*$"#,
                    with: "",
                    options: .regularExpression
                )
                .replacingOccurrences(of: " and ", with: ", ")
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            }
    }

    private func firstMatch(in text: String, patterns: [String]) -> String? {
        for pattern in patterns {
            if let match = firstMatches(in: text, pattern: pattern).first {
                return match
            }
        }
        return nil
    }

    private func firstMatches(in text: String, pattern: String) -> [String] {
        matches(in: text, pattern: pattern).compactMap { $0.dropFirst().first }.compactMap(MeetingFacts.clean)
    }

    private func matches(in text: String, pattern: String) -> [[String]] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, range: nsRange).map { match in
            (0..<match.numberOfRanges).compactMap { index in
                let range = match.range(at: index)
                guard range.location != NSNotFound,
                      let swiftRange = Range(range, in: text)
                else { return nil }
                return String(text[swiftRange])
            }
        }
    }

    private static func merge(_ lists: [String]...) -> [String] {
        MeetingFacts.normalizedList(lists.flatMap { $0 })
    }

    private static func isGenericTitle(_ title: String) -> Bool {
        let normalized = title.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        return ["untitled meeting", "meeting", "meeting notes", "general discussion", "call"].contains(normalized)
            || normalized.hasPrefix("untitled")
    }

    private static func isLikelyPersonName(_ value: String) -> Bool {
        guard let cleaned = MeetingFacts.clean(value) else { return false }
        let lowercased = cleaned.lowercased()
        guard !personStopWords.contains(lowercased),
              !lowercased.hasPrefix("speaker "),
              cleaned.count >= 2,
              cleaned.count <= 40,
              cleaned.split(separator: " ").count <= 3,
              cleaned.first?.isUppercase == true
        else { return false }
        return true
    }

    private static func isLikelyOrganizationName(_ value: String) -> Bool {
        guard let cleaned = MeetingFacts.clean(value) else { return false }
        let lowercased = cleaned.lowercased()
        guard cleaned.count >= 3,
              cleaned.count <= 48,
              cleaned.first?.isUppercase == true,
              !organizationStopWords.contains(lowercased),
              !personStopWords.contains(lowercased)
        else { return false }
        return true
    }

    private static let titleStopWords: Set<String> = [
        "about", "and", "are", "but", "customer", "meeting", "review", "speaker", "that", "the",
        "this", "was", "were", "with", "you"
    ]

    private static let personStopWords: Set<String> = [
        "alexa", "barn", "customer", "meeting", "speaker", "strategic", "the", "this", "there",
        "transcript", "you"
    ]

    private static let organizationStopWords: Set<String> = [
        "actually", "because", "bullshit", "coming", "didn", "doesn", "literally", "random",
        "really", "recording", "some", "something", "total", "whether", "working"
    ]
}

public struct ContextPromptGenerator: Sendable {
    public init() {}

    public func prompts(for facts: MeetingFacts, transcript: String = "") -> [ContextReviewPrompt] {
        var prompts: [ContextReviewPrompt] = []
        if facts.confidence.title < 0.65 {
            prompts.append(ContextReviewPrompt(kind: .title, text: "What should this meeting be called?"))
        }
        if let acronym = repeatedAcronym(in: transcript, excluding: facts.glossary.keys) {
            prompts.append(ContextReviewPrompt(kind: .acronym, text: "What does \(acronym) mean here?"))
        }
        if transcript.localizedCaseInsensitiveContains("someone should")
            || transcript.localizedCaseInsensitiveContains("need an owner") {
            prompts.append(ContextReviewPrompt(kind: .actionOwner, text: "Who owns the follow-up?"))
        }
        if facts.participants.isEmpty || facts.confidence.participants < 0.55 {
            prompts.append(ContextReviewPrompt(kind: .participants, text: "Who else was in this?"))
        }
        if facts.confidence.organizations > 0.45,
           facts.confidence.organizations < 0.75,
           let organization = facts.organizations.first {
            prompts.append(ContextReviewPrompt(kind: .organization, text: "Is this related to \(organization)?"))
        }
        return Array(prompts.prefix(3))
    }

    private func repeatedAcronym(in text: String, excluding known: Dictionary<String, String>.Keys) -> String? {
        guard let regex = try? NSRegularExpression(pattern: #"\b[A-Z]{2,}\b"#) else { return nil }
        let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
        var counts: [String: Int] = [:]
        for match in regex.matches(in: text, range: nsRange) {
            guard let range = Range(match.range, in: text) else { continue }
            let acronym = String(text[range])
            guard known.contains(acronym) == false else { continue }
            counts[acronym, default: 0] += 1
        }
        return counts.first { $0.value >= 2 }?.key
    }
}

public struct ContextEntitySuggestionGenerator: Sendable {
    public init() {}

    public func suggestions(
        facts: MeetingFacts,
        transcript: String,
        contextLines: [String]
    ) -> [ContextEntitySuggestion] {
        let contextText = contextLines.joined(separator: "\n")
        var suggestions: [ContextEntitySuggestion] = []
        suggestions += personNameSuggestions(facts: facts, transcript: transcript, contextText: contextText)
        suggestions += organizationSuggestions(facts: facts, contextText: contextText)
        suggestions += glossarySuggestions(facts: facts)
        return Array(suggestions.prefix(8))
    }

    private func personNameSuggestions(
        facts: MeetingFacts,
        transcript: String,
        contextText: String
    ) -> [ContextEntitySuggestion] {
        let contextNames = contextualList(after: #"(?i)\b(?:calendar attendees|participants|attendees):\s+"#, in: contextText)
        guard !contextNames.isEmpty else { return [] }

        let transcriptNames = transcript
            .split(separator: "\n")
            .compactMap { line -> String? in
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard let colon = trimmed.firstIndex(of: ":") else { return nil }
                return MeetingFacts.clean(String(trimmed[..<colon]))
            }
        let observed = MeetingFacts.normalizedList(facts.participants + transcriptNames)

        return observed.compactMap { candidate in
            guard let canonical = bestNearMatch(for: candidate, in: contextNames),
                  canonical.localizedCaseInsensitiveCompare(candidate) != .orderedSame
            else {
                return nil
            }
            return ContextEntitySuggestion(
                kind: .person,
                observedValue: candidate,
                canonicalValue: canonical,
                rationale: "A nearby attendee name in saved meeting context appears to be the canonical spelling.",
                confidence: 0.94,
                evidenceSources: ["transcript", "meeting_context"]
            )
        }
    }

    private func organizationSuggestions(
        facts: MeetingFacts,
        contextText: String
    ) -> [ContextEntitySuggestion] {
        let contextualOrganizations = contextualList(
            after: #"(?i)\b(?:customers?|organizations?|accounts?):\s+"#,
            in: contextText
        )
        guard !contextualOrganizations.isEmpty else { return [] }

        let observed = MeetingFacts.normalizedList(facts.customers + facts.organizations)
        return observed.compactMap { candidate in
            guard let canonical = bestContainmentMatch(for: candidate, in: contextualOrganizations),
                  canonical.localizedCaseInsensitiveCompare(candidate) != .orderedSame
            else {
                return nil
            }
            return ContextEntitySuggestion(
                kind: facts.customers.contains(candidate) ? .customerAccount : .organization,
                observedValue: candidate,
                canonicalValue: canonical,
                rationale: "Saved context contains a fuller organization/customer form for this mention.",
                confidence: 0.90,
                evidenceSources: ["meeting_facts", "meeting_context"]
            )
        }
    }

    private func glossarySuggestions(facts: MeetingFacts) -> [ContextEntitySuggestion] {
        facts.glossary.compactMap { key, value in
            guard let acronym = MeetingFacts.clean(key),
                  let expansion = MeetingFacts.clean(value),
                  acronym.localizedCaseInsensitiveCompare(expansion) != .orderedSame
            else {
                return nil
            }
            return ContextEntitySuggestion(
                kind: .glossaryTerm,
                observedValue: acronym,
                canonicalValue: expansion,
                rationale: "The meeting glossary defines a durable acronym expansion.",
                confidence: 0.98,
                evidenceSources: ["meeting_facts.glossary"]
            )
        }
        .sorted { $0.observedValue < $1.observedValue }
    }

    private func contextualList(after prefixPattern: String, in text: String) -> [String] {
        let pattern = prefixPattern + #"([^.\n]+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
        let values = regex.matches(in: text, range: nsRange).compactMap { match -> String? in
            guard match.numberOfRanges > 1,
                  let range = Range(match.range(at: 1), in: text)
            else {
                return nil
            }
            return String(text[range])
        }
        .flatMap { value in
            value
                .replacingOccurrences(of: " and ", with: ", ")
                .split(separator: ",")
                .map { String($0) }
        }
        return MeetingFacts.normalizedList(values)
    }

    private func bestNearMatch(for candidate: String, in canonicalValues: [String]) -> String? {
        let normalizedCandidate = normalized(candidate)
        return canonicalValues
            .filter { normalized($0) != normalizedCandidate }
            .min { lhs, rhs in
                editDistance(normalizedCandidate, normalized(lhs)) < editDistance(normalizedCandidate, normalized(rhs))
            }
            .flatMap { canonical in
                editDistance(normalizedCandidate, normalized(canonical)) <= 1 ? canonical : nil
            }
    }

    private func bestContainmentMatch(for candidate: String, in canonicalValues: [String]) -> String? {
        let normalizedCandidate = normalized(candidate)
        return canonicalValues.first { canonical in
            let normalizedCanonical = normalized(canonical)
            return normalizedCanonical != normalizedCandidate
                && (normalizedCanonical.contains(normalizedCandidate) || normalizedCandidate.contains(normalizedCanonical))
        }
    }

    private func normalized(_ value: String) -> String {
        value
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .lowercased()
            .filter { $0.isLetter || $0.isNumber }
    }

    private func editDistance(_ lhs: String, _ rhs: String) -> Int {
        let left = Array(lhs)
        let right = Array(rhs)
        guard !left.isEmpty else { return right.count }
        guard !right.isEmpty else { return left.count }

        var previous = Array(0...right.count)
        for (leftIndex, leftCharacter) in left.enumerated() {
            var current = [leftIndex + 1]
            for (rightIndex, rightCharacter) in right.enumerated() {
                let substitution = previous[rightIndex] + (leftCharacter == rightCharacter ? 0 : 1)
                let insertion = current[rightIndex] + 1
                let deletion = previous[rightIndex + 1] + 1
                current.append(min(substitution, insertion, deletion))
            }
            previous = current
        }
        return previous[right.count]
    }
}

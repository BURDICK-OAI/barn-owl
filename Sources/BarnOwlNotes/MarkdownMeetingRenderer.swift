import BarnOwlCore
import Foundation

public enum MeetingNoteFormat: String, Codable, Equatable, Sendable, CaseIterable {
    case oneOnOne
    case teamMeeting
    case customerWorkshop
    case customerPitch
    case interview
    case incidentReview
    case hallwayCapture
    case planningReview
    case general

    public var displayName: String {
        switch self {
        case .oneOnOne:
            "One-on-One"
        case .teamMeeting:
            "Team Meeting"
        case .customerWorkshop:
            "Customer Workshop"
        case .customerPitch:
            "Customer Pitch"
        case .interview:
            "Interview"
        case .incidentReview:
            "Incident Review"
        case .hallwayCapture:
            "Hallway / Random Capture"
        case .planningReview:
            "Planning / Review"
        case .general:
            "General Discussion"
        }
    }

    var contextHeading: String {
        switch self {
        case .oneOnOne:
            "Relationship Context"
        case .teamMeeting:
            "Team Context"
        case .customerWorkshop, .customerPitch:
            "Customer Context"
        case .interview:
            "Candidate Context"
        case .incidentReview:
            "Incident Context"
        case .hallwayCapture:
            "Capture Context"
        case .planningReview:
            "Planning Context"
        case .general:
            "Context"
        }
    }

    var focusItems: [String] {
        switch self {
        case .oneOnOne:
            ["Feedback or coaching moments", "Blockers and support needed", "Commitments before the next 1:1"]
        case .teamMeeting:
            ["Announcements and shared context", "Decisions and owners", "Risks, dependencies, and follow-ups"]
        case .customerWorkshop:
            ["Customer goals and current workflow", "Pain points, requirements, and constraints", "Validation questions and next steps"]
        case .customerPitch:
            ["Customer priorities and buying criteria", "Value proposition, objections, and open concerns", "Stakeholders and commercial next steps"]
        case .interview:
            ["Candidate signal and evidence", "Concerns or missing signal", "Hiring recommendation and next steps"]
        case .incidentReview:
            ["Impact, timeline, and root cause", "Mitigations and owners", "Prevention work and follow-ups"]
        case .hallwayCapture:
            ["What was captured", "Likely follow-ups", "Context Barn Owl still needs"]
        case .planningReview:
            ["Goals, scope, and non-goals", "Decisions, owners, and milestones", "Risks, dependencies, and open questions"]
        case .general:
            ["Key discussion points", "Decisions and action items", "Open questions"]
        }
    }

    public static func infer(
        session: RecordingSession,
        segments: [TranscriptSegment],
        summary: MeetingSummary,
        context: [String] = []
    ) -> MeetingNoteFormat {
        let text = normalizedText(session: session, segments: segments, summary: summary, context: context)

        if matchesAny(["1:1", "one on one", "one-on-one", "performance review", "career", "manager"], in: text) {
            return .oneOnOne
        }
        if matchesAny(["customer workshop", "workshop", "implementation", "requirements", "discovery", "workflow"], in: text) {
            return .customerWorkshop
        }
        if matchesAny(["customer pitch", "pitch", "pricing", "procurement", "buying", "objection", "demo"], in: text) {
            return .customerPitch
        }
        if matchesAny(["interview", "candidate", "hiring", "onsite", "recruiting"], in: text) {
            return .interview
        }
        if matchesAny(["incident", "outage", "sev", "postmortem", "root cause", "mitigation"], in: text) {
            return .incidentReview
        }
        if matchesAny(["hallway", "random capture", "quick note", "ad hoc", "walked up", "corridor"], in: text) {
            return .hallwayCapture
        }
        if matchesAny(["planning", "planning review", "roadmap", "roadmap review", "milestone", "launch plan", "sprint", "quarterly review"], in: text) {
            return .planningReview
        }
        if matchesAny(["team meeting", "staff meeting", "weekly sync", "standup", "all hands"], in: text) {
            return .teamMeeting
        }
        return .general
    }

    private static func normalizedText(
        session: RecordingSession,
        segments: [TranscriptSegment],
        summary: MeetingSummary,
        context: [String]
    ) -> String {
        ([session.title, summary.overview]
            + summary.decisions
            + summary.actionItems
            + summary.openQuestions
            + context
            + segments.map(\.text))
            .joined(separator: " ")
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .lowercased()
    }

    private static func matchesAny(_ needles: [String], in haystack: String) -> Bool {
        needles.contains { haystack.contains($0) }
    }

    public static func fromDisplayName(_ value: String?) -> MeetingNoteFormat? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty
        else { return nil }
        return allCases.first {
            $0.displayName.caseInsensitiveCompare(value) == .orderedSame
                || $0.rawValue.caseInsensitiveCompare(value) == .orderedSame
        }
    }
}

public struct MarkdownMeetingRenderer: Sendable {
    public init() {}

    public func render(
        session: RecordingSession,
        segments: [TranscriptSegment],
        summary: MeetingSummary,
        context: [String] = [],
        meetingFacts: MeetingFacts? = nil,
        format requestedFormat: MeetingNoteFormat? = nil
    ) -> String {
        let noteContext = Self.noteContext(from: context)
        let factContext = meetingFacts.map(Self.renderableFactContext(from:)) ?? []
        let renderContext = Self.uniqueContext(noteContext + factContext)
        let format = requestedFormat
            ?? Self.trustedFormat(from: meetingFacts)
            ?? MeetingNoteFormat.infer(
            session: session,
            segments: segments,
            summary: summary,
            context: renderContext
        )
        let title = MeetingFacts.clean(meetingFacts?.title) ?? session.title
        var lines: [String] = [
            "# \(title)",
            "",
            "Started: \(session.startedAt.formatted(date: .abbreviated, time: .shortened))",
        ]
        if meetingFacts == nil {
            lines.append("Meeting Type: \(format.displayName)")
        }
        lines.append(contentsOf: [
            "",
            "## Summary",
            summary.overview,
            ""
        ])

        if let meetingFacts {
            appendMeetingFacts(meetingFacts, fallbackType: format.displayName, to: &lines)
        }
        appendSection("Decisions", summary.decisions, to: &lines)
        appendSection("Action Items", summary.actionItems, to: &lines)
        appendSection("Open Questions", summary.openQuestions, to: &lines)
        if meetingFacts == nil {
            appendSection("Participants", participants(from: segments, context: noteContext), to: &lines)
        }
        appendSection("Risks", risks(from: segments, summary: summary), to: &lines)
        appendSection("References", references(from: segments, context: renderContext), to: &lines)
        let narrativeContext = meetingFacts == nil
            ? noteContext
            : Self.uniqueContext(noteContext + Self.noteContext(from: meetingFacts?.additionalContext ?? []))
        appendSection(format.contextHeading, narrativeContext, to: &lines)

        lines.append("## Transcript")
        for segment in segments {
            lines.append("")
            lines.append("**\(segment.speakerLabel)**")
            lines.append(segment.text)
        }

        return lines.joined(separator: "\n")
    }

    private func appendMeetingFacts(_ facts: MeetingFacts, fallbackType: String, to lines: inout [String]) {
        var items: [String] = []
        if let type = MeetingFacts.clean(facts.meetingType),
           facts.confidence.meetingType >= 0.55,
           type != "General Discussion" {
            items.append("Meeting type: \(type)")
        } else if facts.confidence.meetingType >= 0.55,
                  fallbackType != "General Discussion" {
            items.append("Meeting type: \(fallbackType)")
        }
        if let title = MeetingFacts.clean(facts.title),
           !Self.isGenericTitle(title) {
            items.append("Title: \(title)")
        }
        let participants = facts.participants.filter(Self.isUsefulParticipant)
        if !participants.isEmpty {
            items.append("Participants: \(participants.joined(separator: ", "))")
        }
        if !facts.customers.isEmpty {
            items.append("Customers: \(facts.customers.joined(separator: ", "))")
        } else if facts.confidence.organizations >= 0.75, !facts.organizations.isEmpty {
            items.append("Organizations: \(facts.organizations.joined(separator: ", "))")
        }
        if !facts.projects.isEmpty {
            items.append("Projects: \(facts.projects.joined(separator: ", "))")
        }
        if !facts.goals.isEmpty {
            items.append("Goals: \(facts.goals.joined(separator: "; "))")
        }
        if !facts.glossary.isEmpty {
            for key in facts.glossary.keys.sorted() {
                if let value = facts.glossary[key] {
                    items.append("\(key): \(value)")
                }
            }
        }
        appendSection("Meeting Facts", items, to: &lines)
    }

    private static func isGenericTitle(_ title: String) -> Bool {
        let normalized = title
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized == "meeting"
            || normalized == "meeting notes"
            || normalized == "general discussion"
            || normalized == "untitled meeting"
            || normalized.hasPrefix("untitled")
    }

    private static func isUsefulParticipant(_ participant: String) -> Bool {
        guard let cleaned = MeetingFacts.clean(participant) else { return false }
        let lowercased = cleaned.lowercased()
        return cleaned.count >= 2
            && !lowercased.hasPrefix("speaker ")
            && lowercased != "speaker"
            && lowercased != "unknown"
    }

    private static func trustedFormat(from facts: MeetingFacts?) -> MeetingNoteFormat? {
        guard let facts,
              facts.confidence.meetingType >= 0.55
        else { return nil }
        return MeetingNoteFormat.fromDisplayName(facts.meetingType)
    }

    private static func renderableFactContext(from facts: MeetingFacts) -> [String] {
        var lines: [String] = []
        if let title = MeetingFacts.clean(facts.title),
           !isGenericTitle(title) {
            lines.append("Meeting title: \(title)")
        }
        if let meetingType = MeetingFacts.clean(facts.meetingType),
           facts.confidence.meetingType >= 0.55,
           meetingType != "General Discussion" {
            lines.append("Meeting type: \(meetingType)")
        }
        let participants = facts.participants.filter(isUsefulParticipant)
        if !participants.isEmpty {
            lines.append("Participants: \(participants.joined(separator: ", "))")
        }
        if !facts.customers.isEmpty {
            lines.append("Customers: \(facts.customers.joined(separator: ", "))")
        } else if facts.confidence.organizations >= 0.75, !facts.organizations.isEmpty {
            lines.append("Organizations: \(facts.organizations.joined(separator: ", "))")
        }
        if !facts.projects.isEmpty {
            lines.append("Projects: \(facts.projects.joined(separator: ", "))")
        }
        if !facts.goals.isEmpty {
            lines.append("Goals: \(facts.goals.joined(separator: "; "))")
        }
        if !facts.glossary.isEmpty {
            for key in facts.glossary.keys.sorted() {
                if let value = facts.glossary[key] {
                    lines.append("\(key): \(value)")
                }
            }
        }
        return lines
    }

    private func appendSection(_ title: String, _ items: [String], to lines: inout [String]) {
        guard !items.isEmpty else { return }
        lines.append("## \(title)")
        lines.append(contentsOf: items.map { "- \($0)" })
        lines.append("")
    }

    private static func noteContext(from context: [String]) -> [String] {
        context
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .filter { line in
                let lowercased = line
                    .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
                    .lowercased()
                return !lowercased.hasPrefix("meeting title:")
                    && !lowercased.hasPrefix("started:")
                    && !lowercased.hasPrefix("audio sources:")
                    && !lowercased.hasPrefix("local context")
            }
    }

    private static func uniqueContext(_ context: [String]) -> [String] {
        var seen: Set<String> = []
        var unique: [String] = []
        for line in context {
            let key = line
                .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
                .lowercased()
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: #"[.!?]+$"#, with: "", options: .regularExpression)
            guard !key.isEmpty, seen.insert(key).inserted else {
                continue
            }
            unique.append(line)
        }
        return unique
    }

    private func participants(from segments: [TranscriptSegment], context: [String]) -> [String] {
        let speakers = Set(segments.map(\.speakerLabel).filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
        let attendeeLines = context
            .filter { $0.localizedCaseInsensitiveContains("attendees:") || $0.localizedCaseInsensitiveContains("participants:") }
            .flatMap { line in
                line
                    .split(separator: ":", maxSplits: 1)
                    .last?
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) } ?? []
            }
        return Array(speakers.union(attendeeLines)).sorted()
    }

    private func risks(from segments: [TranscriptSegment], summary: MeetingSummary) -> [String] {
        let text = (segments.map(\.text) + summary.openQuestions)
            .joined(separator: "\n")
        let riskKeywords = ["risk", "blocked", "blocker", "concern", "dependency", "unclear", "issue"]
        let matches = text
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { line in
                let lowercased = line.lowercased()
                return riskKeywords.contains { lowercased.contains($0) }
            }
        return Array(matches.prefix(6))
    }

    private func references(from segments: [TranscriptSegment], context: [String]) -> [String] {
        let text = (segments.map(\.text) + context).joined(separator: " ")
        let patterns = [
            "customer", "company", "project", "account", "roadmap", "launch", "contract", "pricing"
        ]
        let matches = text
            .split(separator: ".")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { sentence in
                let lowercased = sentence.lowercased()
                return patterns.contains { lowercased.contains($0) }
            }
        return Array(matches.prefix(6))
    }
}

public struct ExternalParticipantNotesRenderer: Sendable {
    public init() {}

    public func render(
        title requestedTitle: String,
        startedAt: Date?,
        meetingFacts: MeetingFacts?,
        markdown: String
    ) -> String {
        let title = shareableTitle(requestedTitle, facts: meetingFacts)
        let sections = Self.markdownSections(in: markdown)
        let summary = shareableLines(
            from: sections["summary"] ?? sections["overview"] ?? ""
        )
        let decisions = shareableLines(from: sections["decisions"] ?? "")
        let actionItems = shareableLines(from: sections["action items"] ?? "")
        let openQuestions = shareableLines(from: sections["open questions"] ?? "")
        let participants = shareableParticipants(from: meetingFacts, markdownSection: sections["participants"] ?? sections["attendees"] ?? "")
        let related = shareableRelatedFacts(from: meetingFacts)

        guard !summary.isEmpty
            || !decisions.isEmpty
            || !actionItems.isEmpty
            || !openQuestions.isEmpty
            || !participants.isEmpty
            || !related.isEmpty
        else {
            return ""
        }

        var lines: [String] = [
            title,
            "",
            "Shareable recap"
        ]

        if let startedAt {
            lines.append("Date: \(startedAt.formatted(date: .abbreviated, time: .shortened))")
        }
        if !participants.isEmpty {
            lines.append("Participants: \(participants.joined(separator: ", "))")
        }
        if !related.isEmpty {
            lines.append("Related: \(related.joined(separator: ", "))")
        }

        Self.appendShareableSection("Summary", summary, to: &lines)
        Self.appendShareableSection("Decisions", decisions, to: &lines)
        Self.appendShareableSection("Action items", actionItems, to: &lines)
        Self.appendShareableSection("Open questions", openQuestions, to: &lines)

        return lines.joined(separator: "\n")
    }

    private static func appendShareableSection(_ title: String, _ items: [String], to lines: inout [String]) {
        guard !items.isEmpty else { return }
        lines.append("")
        lines.append("\(title):")
        if items.count == 1 {
            lines.append(items[0])
        } else {
            for (index, item) in items.enumerated() {
                lines.append("\(index + 1). \(item)")
            }
        }
    }

    private func shareableTitle(_ requestedTitle: String, facts: MeetingFacts?) -> String {
        let factTitle = MeetingFacts.clean(facts?.title)
        let title = factTitle ?? MeetingFacts.clean(requestedTitle) ?? "Meeting"
        return Self.isGenericTitle(title) ? "Meeting" : title
    }

    private func shareableParticipants(from facts: MeetingFacts?, markdownSection: String) -> [String] {
        let factParticipants = facts?.participants ?? []
        let markdownParticipants = Self.listItems(from: markdownSection)
        return Self.uniqueCleaned(factParticipants + markdownParticipants)
            .filter(Self.isShareableParticipant)
    }

    private func shareableRelatedFacts(from facts: MeetingFacts?) -> [String] {
        guard let facts else { return [] }
        return Self.uniqueCleaned(facts.customers + facts.projects + facts.organizations)
            .filter(Self.isShareableFact)
            .prefix(6)
            .map { $0 }
    }

    private func shareableLines(from section: String) -> [String] {
        let items = Self.listItems(from: section)
            .map(Self.plainTextLine)
            .filter(Self.isShareableLine)
        if !items.isEmpty {
            return Array(Self.uniqueLines(items).prefix(8))
        }
        return []
    }

    private static func markdownSections(in markdown: String) -> [String: String] {
        let lines = markdown.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var sections: [String: [String]] = [:]
        var currentTitle: String?
        var currentLevel: Int?

        for line in lines {
            if let heading = markdownHeading(in: line) {
                if heading.level <= 2 {
                    currentTitle = heading.title.lowercased()
                    currentLevel = heading.level
                    sections[currentTitle ?? ""] = []
                    continue
                }
                if let currentLevel, heading.level <= currentLevel {
                    currentTitle = nil
                }
            }

            guard let currentTitle else { continue }
            sections[currentTitle, default: []].append(line)
        }

        return sections.mapValues { $0.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    private static func markdownHeading(in line: String) -> (level: Int, title: String)? {
        let hashes = line.prefix { $0 == "#" }.count
        guard hashes > 0,
              hashes < line.count,
              line.dropFirst(hashes).first == " "
        else {
            return nil
        }
        return (
            level: hashes,
            title: line.dropFirst(hashes + 1).trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    private static func listItems(from text: String) -> [String] {
        text
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .map(plainTextLine)
            .filter { !$0.isEmpty }
    }

    private static func plainTextLine(_ line: String) -> String {
        line
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"^\s*[-*]\s+"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"^\s*\d+[.)]\s+"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"^\s*>\s+"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"#{1,6}\s*"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "__", with: "")
            .replacingOccurrences(of: "`", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func uniqueCleaned(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        var output: [String] = []
        for value in values {
            guard let cleaned = MeetingFacts.clean(plainTextLine(value)) else { continue }
            let key = cleaned.lowercased()
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            output.append(cleaned)
        }
        return output
    }

    private static func uniqueLines(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        var output: [String] = []
        for value in values {
            let cleaned = plainTextLine(value).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleaned.isEmpty else { continue }
            let key = cleaned.lowercased()
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            output.append(cleaned)
        }
        return output
    }

    private static func isShareableParticipant(_ value: String) -> Bool {
        let normalized = value.lowercased()
        return value.count >= 2
            && normalized != "a"
            && normalized != "speaker"
            && normalized != "unknown"
            && !normalized.hasPrefix("speaker ")
    }

    private static func isShareableFact(_ value: String) -> Bool {
        let normalized = value.lowercased()
        let blocked = ["total", "some", "whether", "unknown", "meeting", "general discussion"]
        return value.count >= 2 && !blocked.contains(normalized)
    }

    private static func isShareableLine(_ line: String) -> Bool {
        let cleaned = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleaned.count >= 3 else { return false }
        let normalized = cleaned
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .lowercased()
        let words = normalized.split(separator: " ")
        if normalized == "speaker" || (normalized.hasPrefix("speaker ") && words.count <= 2) {
            return false
        }

        let blockedPrefixes = [
            "local context",
            "external context",
            "planning context",
            "incident context",
            "capture context",
            "relationship context",
            "team context",
            "customer context",
            "meeting title:",
            "started:",
            "audio sources:",
            "debug:",
            "diagnostics:",
            "performance:",
            "realtime:",
            "capture:",
            "temporary audio",
            "api key"
        ]
        guard !blockedPrefixes.contains(where: { normalized.hasPrefix($0) }) else { return false }

        let blockedFragments = [
            "/users/",
            "library/application support",
            "raw audio",
            "transcribing failed",
            "no transcript available",
            "processing or waiting for notes"
        ]
        return !blockedFragments.contains(where: { normalized.contains($0) })
    }

    private static func isGenericTitle(_ title: String) -> Bool {
        let normalized = title
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized == "meeting"
            || normalized == "meeting notes"
            || normalized == "general discussion"
            || normalized == "untitled meeting"
            || normalized.hasPrefix("untitled")
            || normalized == "no transcript available"
    }
}

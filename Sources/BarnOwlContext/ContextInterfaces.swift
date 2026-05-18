@preconcurrency import EventKit
import Foundation

public struct ContextQuery: Equatable, Sendable {
    public var text: String
    public var limit: Int

    public init(text: String, limit: Int = 12) {
        self.text = text
        self.limit = limit
    }
}

public struct ContextItem: Equatable, Identifiable, Sendable {
    public let id: String
    public var title: String
    public var source: String
    public var body: String

    public init(id: String, title: String, source: String, body: String) {
        self.id = id
        self.title = title
        self.source = source
        self.body = body
    }
}

public struct ContextArtifact: Equatable, Sendable {
    public var title: String
    public var markdown: String

    public init(title: String, markdown: String) {
        self.title = title
        self.markdown = markdown
    }
}

public protocol ContextProvider: Sendable {
    func search(_ query: ContextQuery) async throws -> [ContextItem]
}

public protocol ContextSink: Sendable {
    func write(_ artifact: ContextArtifact) async throws
}

public protocol ReadWriteContextProvider: ContextProvider, ContextSink {}

public struct CalendarMeetingContext: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var provider: String
    public var title: String
    public var startsAt: Date
    public var endsAt: Date
    public var attendees: [String]
    public var notes: String?
    public var location: String?
    public var url: URL?
    public var confidence: Double
    public var matchReason: String

    public init(
        id: String,
        provider: String,
        title: String,
        startsAt: Date,
        endsAt: Date,
        attendees: [String] = [],
        notes: String? = nil,
        location: String? = nil,
        url: URL? = nil,
        confidence: Double,
        matchReason: String
    ) {
        self.id = id
        self.provider = provider
        self.title = title
        self.startsAt = startsAt
        self.endsAt = endsAt
        self.attendees = attendees
        self.notes = notes
        self.location = location
        self.url = url
        self.confidence = min(max(confidence, 0), 1)
        self.matchReason = matchReason
    }

    public var isHighConfidence: Bool {
        confidence >= 0.70
    }

    public var confidenceLabel: String {
        switch confidence {
        case 0.85 ... 1:
            "High confidence"
        case 0.55 ..< 0.85:
            "Medium confidence"
        default:
            "Low confidence"
        }
    }

    public var contextLines: [String] {
        var lines = [
            "Calendar event: \(title)",
            "Calendar provider: \(provider)",
            "Calendar time: \(startsAt.formatted(date: .abbreviated, time: .shortened)) - \(endsAt.formatted(date: .omitted, time: .shortened))",
            "Calendar match: \(confidenceLabel) (\(matchReason))"
        ]

        if !attendees.isEmpty {
            lines.append("Calendar attendees: \(attendees.joined(separator: ", "))")
        }
        if let location,
           !location.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines.append("Calendar location: \(location)")
        }
        if let url {
            lines.append("Calendar URL: \(url.absoluteString)")
        }
        if let notes,
           !notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines.append("Calendar notes: \(String(notes.replacingOccurrences(of: "\n", with: " ").prefix(700)))")
        }

        return lines
    }
}

public protocol CalendarMeetingContextProvider: Sendable {
    func bestContext(around date: Date) async throws -> CalendarMeetingContext?
}

public actor EmptyCalendarMeetingContextProvider: CalendarMeetingContextProvider {
    public init() {}

    public func bestContext(around date: Date) async throws -> CalendarMeetingContext? {
        nil
    }
}

public actor EventKitCalendarMeetingContextProvider: CalendarMeetingContextProvider {
    private let eventStore = EKEventStore()
    private let providerName: String
    private let searchWindow: TimeInterval

    public init(
        providerName: String = "macOS Calendar",
        searchWindow: TimeInterval = 45 * 60
    ) {
        self.providerName = providerName
        self.searchWindow = searchWindow
    }

    public func bestContext(around date: Date) async throws -> CalendarMeetingContext? {
        guard try await requestCalendarAccessIfNeeded() else {
            return nil
        }

        let windowStart = date.addingTimeInterval(-searchWindow)
        let windowEnd = date.addingTimeInterval(searchWindow)
        let predicate = eventStore.predicateForEvents(
            withStart: windowStart,
            end: windowEnd,
            calendars: nil
        )

        return eventStore.events(matching: predicate)
            .filter { !$0.isAllDay }
            .compactMap { context(for: $0, recordingStart: date) }
            .sorted { lhs, rhs in
                if lhs.confidence == rhs.confidence {
                    return lhs.startsAt < rhs.startsAt
                }
                return lhs.confidence > rhs.confidence
            }
            .first
    }

    private func requestCalendarAccessIfNeeded() async throws -> Bool {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .authorized, .fullAccess:
            return true
        case .notDetermined:
            return try await withCheckedThrowingContinuation { continuation in
                if #available(macOS 14.0, *) {
                    eventStore.requestFullAccessToEvents { granted, error in
                        if let error {
                            continuation.resume(throwing: error)
                        } else {
                            continuation.resume(returning: granted)
                        }
                    }
                } else {
                    eventStore.requestAccess(to: .event) { granted, error in
                        if let error {
                            continuation.resume(throwing: error)
                        } else {
                            continuation.resume(returning: granted)
                        }
                    }
                }
            }
        case .denied, .restricted, .writeOnly:
            return false
        @unknown default:
            return false
        }
    }

    private func context(for event: EKEvent, recordingStart: Date) -> CalendarMeetingContext? {
        let title = event.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !title.isEmpty,
              let startsAt = event.startDate,
              let endsAt = event.endDate
        else {
            return nil
        }

        let score = confidenceScore(for: event, recordingStart: recordingStart)
        guard score >= 0.35 else {
            return nil
        }

        return CalendarMeetingContext(
            id: event.eventIdentifier ?? "\(providerName)-\(startsAt.timeIntervalSince1970)-\(title)",
            provider: providerName,
            title: title,
            startsAt: startsAt,
            endsAt: endsAt,
            attendees: attendees(from: event),
            notes: event.notes,
            location: event.location,
            url: event.url,
            confidence: score,
            matchReason: matchReason(for: event, recordingStart: recordingStart, confidence: score)
        )
    }

    private func confidenceScore(for event: EKEvent, recordingStart: Date) -> Double {
        let startsAt = event.startDate ?? recordingStart
        let endsAt = event.endDate ?? startsAt
        var score = 0.0

        if recordingStart >= startsAt && recordingStart <= endsAt {
            score += 0.62
            let duration = max(endsAt.timeIntervalSince(startsAt), 1)
            let position = recordingStart.timeIntervalSince(startsAt) / duration
            score += max(0, 0.16 - abs(position - 0.35) * 0.12)
        } else {
            let boundaryDistance = min(
                abs(recordingStart.timeIntervalSince(startsAt)),
                abs(recordingStart.timeIntervalSince(endsAt))
            )
            score += max(0, 0.46 * (1 - boundaryDistance / searchWindow))
        }

        if !(event.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            score += 0.08
        }
        if !(event.attendees ?? []).isEmpty {
            score += 0.08
        }
        if event.url != nil {
            score += 0.04
        }
        if let notes = event.notes,
           !notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            score += 0.04
        }

        return min(score, 1)
    }

    private func matchReason(
        for event: EKEvent,
        recordingStart: Date,
        confidence: Double
    ) -> String {
        guard let startsAt = event.startDate,
              let endsAt = event.endDate
        else {
            return "calendar event near recording start"
        }

        if recordingStart >= startsAt && recordingStart <= endsAt {
            return "recording started during scheduled event"
        }

        let minutes = Int(min(
            abs(recordingStart.timeIntervalSince(startsAt)),
            abs(recordingStart.timeIntervalSince(endsAt))
        ) / 60)
        return "\(confidence >= 0.55 ? "nearby" : "possible") event within \(minutes) min"
    }

    private func attendees(from event: EKEvent) -> [String] {
        (event.attendees ?? [])
            .compactMap { participant in
                let url = participant.url
                if url.scheme?.caseInsensitiveCompare("mailto") == .orderedSame,
                   let email = url.absoluteString.dropFirst("mailto:".count).removingPercentEncoding,
                   !email.isEmpty {
                    return email
                }

                return participant.name?.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            .filter { !$0.isEmpty }
            .removingDuplicates()
    }
}

public actor LocalMarkdownContextProvider: ReadWriteContextProvider {
    private let rootDirectory: URL
    private let sourceName: String

    public init(rootDirectory: URL, sourceName: String = "local-markdown") {
        self.rootDirectory = rootDirectory
        self.sourceName = sourceName
    }

    public func write(_ artifact: ContextArtifact) throws {
        try createPrivateDirectory(at: rootDirectory)

        try artifact.markdown.write(
            to: fileURL(forTitle: artifact.title),
            atomically: true,
            encoding: .utf8
        )
        try protectPrivateFile(at: fileURL(forTitle: artifact.title))
    }

    public func remove(title: String) throws {
        let url = fileURL(forTitle: title)
        guard fileExists(at: url) else {
            return
        }
        try FileManager.default.removeItem(at: url)
    }

    @discardableResult
    public func removeFiles(named fileNames: [String]) throws -> Int {
        var removed = 0
        for fileName in fileNames {
            let url = rootDirectory.appending(path: fileName, directoryHint: .notDirectory)
            guard fileExists(at: url) else {
                continue
            }
            try FileManager.default.removeItem(at: url)
            removed += 1
        }
        return removed
    }

    public func search(_ query: ContextQuery) throws -> [ContextItem] {
        let limit = max(0, query.limit)
        guard limit > 0, fileExists(at: rootDirectory) else {
            return []
        }

        let terms = normalizedTerms(in: query.text)
        let markdownFiles = try FileManager.default.contentsOfDirectory(
            at: rootDirectory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
        .filter { $0.pathExtension == "md" }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }

        let items = try markdownFiles.compactMap { fileURL -> ContextItem? in
            let body = try String(contentsOf: fileURL, encoding: .utf8)
            let title = displayTitle(from: fileURL)
            let normalizedText = normalize("\(title) \(body)")
            guard terms.isEmpty || terms.allSatisfy({ normalizedText.contains($0) }) else {
                return nil
            }

            return ContextItem(
                id: fileURL.path(percentEncoded: false),
                title: title,
                source: sourceName,
                body: body
            )
        }

        return Array(items.prefix(limit))
    }

    public func fileURL(forTitle title: String) -> URL {
        rootDirectory.appending(path: "\(sanitizedTitlePathComponent(title)).md")
    }

    private func displayTitle(from fileURL: URL) -> String {
        fileURL.deletingPathExtension().lastPathComponent
    }

    private func normalizedTerms(in text: String) -> [String] {
        normalize(text)
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
    }

    private func normalize(_ text: String) -> String {
        text
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .lowercased()
    }

    private func sanitizedTitlePathComponent(_ title: String) -> String {
        let folded = title
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .lowercased()

        var result = ""
        var previousWasSeparator = false
        let allowed = CharacterSet.alphanumerics

        for scalar in folded.unicodeScalars {
            if allowed.contains(scalar) {
                result.unicodeScalars.append(scalar)
                previousWasSeparator = false
            } else if previousWasSeparator == false {
                result.append("-")
                previousWasSeparator = true
            }
        }

        let sanitized = result.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return sanitized.isEmpty ? "untitled-note" : String(sanitized.prefix(96))
    }

    private func fileExists(at url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path(percentEncoded: false))
    }

    private func createPrivateDirectory(at url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: url.path(percentEncoded: false)
        )
    }

    private func protectPrivateFile(at url: URL) throws {
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path(percentEncoded: false)
        )
    }
}

private extension Array where Element: Hashable {
    func removingDuplicates() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}

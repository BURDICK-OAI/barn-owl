import BarnOwlCore
import Foundation

public protocol LocalLibraryStore: Sendable {
    func saveSession(_ session: RecordingSession) async throws
    func session(id: RecordingSession.ID) async throws -> RecordingSession?
    func updateMarkdown(sessionID: RecordingSession.ID, markdown: String) async throws -> LocalMeetingArtifact?
    func updateSessionTitle(sessionID: RecordingSession.ID, title: String) async throws -> LocalMeetingArtifact?
    func deleteSession(id: RecordingSession.ID) async throws
    func search(_ query: LocalLibrarySearchQuery) async throws -> [LocalLibrarySearchResult]
}

public struct LocalLibrarySearchQuery: Equatable, Sendable {
    public var text: String
    public var limit: Int

    public init(text: String, limit: Int = 20) {
        self.text = text
        self.limit = limit
    }
}

public enum LocalLibrarySearchField: String, Codable, Equatable, Sendable {
    case title
    case markdown
    case summary
}

public struct LocalLibrarySearchResult: Equatable, Sendable {
    public var session: RecordingSession
    public var artifact: LocalMeetingArtifact?
    public var matchedFields: [LocalLibrarySearchField]

    public init(
        session: RecordingSession,
        artifact: LocalMeetingArtifact?,
        matchedFields: [LocalLibrarySearchField]
    ) {
        self.session = session
        self.artifact = artifact
        self.matchedFields = matchedFields
    }
}

public struct LocalMeetingArtifact: Codable, Equatable, Sendable {
    public var session: RecordingSession
    public var summary: MeetingSummary
    public var transcriptSegments: [TranscriptSegment]
    public var markdown: String

    public init(
        session: RecordingSession,
        summary: MeetingSummary,
        transcriptSegments: [TranscriptSegment],
        markdown: String
    ) {
        self.session = session
        self.summary = summary
        self.transcriptSegments = transcriptSegments
        self.markdown = markdown
    }
}

public struct LocalMeetingArtifactLocation: Equatable, Sendable {
    public var sessionDirectoryURL: URL
    public var sessionJSONFileURL: URL
    public var artifactJSONFileURL: URL
    public var markdownFileURL: URL

    public init(
        sessionDirectoryURL: URL,
        sessionJSONFileURL: URL,
        artifactJSONFileURL: URL,
        markdownFileURL: URL
    ) {
        self.sessionDirectoryURL = sessionDirectoryURL
        self.sessionJSONFileURL = sessionJSONFileURL
        self.artifactJSONFileURL = artifactJSONFileURL
        self.markdownFileURL = markdownFileURL
    }
}

public actor InMemoryLibraryStore: LocalLibraryStore {
    private var sessions: [RecordingSession.ID: RecordingSession] = [:]
    private var artifacts: [RecordingSession.ID: LocalMeetingArtifact] = [:]

    public init() {}

    public func saveSession(_ session: RecordingSession) {
        sessions[session.id] = session
    }

    public func session(id: RecordingSession.ID) -> RecordingSession? {
        sessions[id]
    }

    public func saveArtifact(_ artifact: LocalMeetingArtifact) {
        sessions[artifact.session.id] = artifact.session
        artifacts[artifact.session.id] = artifact
    }

    public func artifact(id: RecordingSession.ID) -> LocalMeetingArtifact? {
        artifacts[id]
    }

    public func updateMarkdown(sessionID: RecordingSession.ID, markdown: String) -> LocalMeetingArtifact? {
        guard var artifact = artifacts[sessionID] else {
            return nil
        }

        artifact.markdown = markdown
        artifacts[sessionID] = artifact
        sessions[sessionID] = artifact.session
        return artifact
    }

    public func updateSessionTitle(sessionID: RecordingSession.ID, title: String) -> LocalMeetingArtifact? {
        guard var artifact = artifacts[sessionID] else {
            return nil
        }

        artifact.session.title = Self.normalizedMeetingTitle(title)
        artifact.markdown = Self.markdownByReplacingTopLevelTitle(
            in: artifact.markdown,
            title: artifact.session.title
        )
        artifacts[sessionID] = artifact
        sessions[sessionID] = artifact.session
        return artifact
    }

    public func deleteSession(id: RecordingSession.ID) {
        sessions[id] = nil
        artifacts[id] = nil
    }

    public func search(_ query: LocalLibrarySearchQuery) -> [LocalLibrarySearchResult] {
        LocalLibrarySearch.rank(
            candidates: sessions.values.map { session in
                LocalLibrarySearch.Candidate(
                    session: session,
                    artifact: artifacts[session.id]
                )
            },
            query: query
        )
    }
}

public actor FilesystemLocalLibraryStore: LocalLibraryStore {
    private let rootDirectory: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public nonisolated var rootDirectoryURL: URL {
        rootDirectory
    }

    public init(rootDirectory: URL) {
        self.rootDirectory = rootDirectory

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    public func saveSession(_ session: RecordingSession) throws {
        let url = artifactLocation(for: session).sessionJSONFileURL
        try createPrivateDirectory(at: rootDirectory)
        try createPrivateDirectory(at: url.deletingLastPathComponent())
        let data = try encoder.encode(session)
        try writePrivateData(data, to: url)
    }

    public func session(id: RecordingSession.ID) throws -> RecordingSession? {
        let url = sessionJSONFileURL(for: id)
        guard fileExists(at: url) else {
            return nil
        }

        let data = try Data(contentsOf: url)
        return try decoder.decode(RecordingSession.self, from: data)
    }

    @discardableResult
    public func saveArtifact(_ artifact: LocalMeetingArtifact) throws -> LocalMeetingArtifactLocation {
        let location = artifactLocation(for: artifact.session)
        try createPrivateDirectory(at: rootDirectory)
        try createPrivateDirectory(at: location.sessionDirectoryURL)

        let sessionData = try encoder.encode(artifact.session)
        try writePrivateData(sessionData, to: location.sessionJSONFileURL)

        let artifactData = try encoder.encode(artifact)
        try writePrivateData(artifactData, to: location.artifactJSONFileURL)

        try writePrivateString(artifact.markdown, to: location.markdownFileURL)
        try removeSupersededMarkdownFiles(
            in: location.sessionDirectoryURL,
            keeping: location.markdownFileURL
        )
        try removeSupersededSessionDirectories(
            for: artifact.session.id,
            keeping: location.sessionDirectoryURL
        )

        return location
    }

    public func artifact(id: RecordingSession.ID) throws -> LocalMeetingArtifact? {
        let url = artifactJSONFileURL(for: id)
        guard fileExists(at: url) else {
            return nil
        }

        let data = try Data(contentsOf: url)
        return try decoder.decode(LocalMeetingArtifact.self, from: data)
    }

    public func updateMarkdown(sessionID: RecordingSession.ID, markdown: String) throws -> LocalMeetingArtifact? {
        guard var artifact = try artifact(id: sessionID) else {
            return nil
        }

        artifact.markdown = markdown

        let location = artifactLocation(for: artifact.session)
        let artifactData = try encoder.encode(artifact)
        try createPrivateDirectory(at: location.sessionDirectoryURL)
        try writePrivateData(artifactData, to: location.artifactJSONFileURL)
        try writePrivateString(markdown, to: location.markdownFileURL)
        try removeSupersededMarkdownFiles(
            in: location.sessionDirectoryURL,
            keeping: location.markdownFileURL
        )
        try removeSupersededSessionDirectories(
            for: artifact.session.id,
            keeping: location.sessionDirectoryURL
        )

        return artifact
    }

    public func updateSessionTitle(sessionID: RecordingSession.ID, title: String) throws -> LocalMeetingArtifact? {
        guard var artifact = try artifact(id: sessionID) else {
            return nil
        }

        let oldLocation = existingArtifactLocation(for: artifact.session)
        artifact.session.title = Self.normalizedMeetingTitle(title)
        artifact.markdown = Self.markdownByReplacingTopLevelTitle(
            in: artifact.markdown,
            title: artifact.session.title
        )

        let newLocation = artifactLocation(for: artifact.session)
        try createPrivateDirectory(at: rootDirectory)
        try createPrivateDirectory(at: newLocation.sessionDirectoryURL)

        let sessionData = try encoder.encode(artifact.session)
        try writePrivateData(sessionData, to: newLocation.sessionJSONFileURL)

        let artifactData = try encoder.encode(artifact)
        try writePrivateData(artifactData, to: newLocation.artifactJSONFileURL)
        try writePrivateString(artifact.markdown, to: newLocation.markdownFileURL)
        try removeSupersededMarkdownFiles(
            in: newLocation.sessionDirectoryURL,
            keeping: newLocation.markdownFileURL
        )
        try removeSupersededSessionDirectories(
            for: artifact.session.id,
            keeping: newLocation.sessionDirectoryURL
        )

        if oldLocation.sessionDirectoryURL != newLocation.sessionDirectoryURL,
           fileExists(at: oldLocation.sessionDirectoryURL) {
            try? FileManager.default.removeItem(at: oldLocation.sessionDirectoryURL)
        }

        return artifact
    }

    public func deleteSession(id: RecordingSession.ID) throws {
        guard let directory = try existingSessionDirectoryURL(for: id) else {
            return
        }

        try FileManager.default.removeItem(at: directory)
    }

    public func artifactLocation(for session: RecordingSession) -> LocalMeetingArtifactLocation {
        let sessionDirectory = preferredSessionDirectoryURL(for: session)
        return LocalMeetingArtifactLocation(
            sessionDirectoryURL: sessionDirectory,
            sessionJSONFileURL: sessionDirectory.appending(path: "session.json"),
            artifactJSONFileURL: sessionDirectory.appending(path: "artifact.json"),
            markdownFileURL: markdownFileURL(for: session)
        )
    }

    public func markdownFileURL(for session: RecordingSession) -> URL {
        let sessionDirectory = (try? existingSessionDirectoryURL(for: session.id))
            ?? preferredSessionDirectoryURL(for: session)
        return sessionDirectory.appending(path: "\(sanitizedTitlePathComponent(session.title)).md")
    }

    public func markdownFileURL(forSessionID id: RecordingSession.ID) throws -> URL? {
        if let artifact = try artifact(id: id) {
            return markdownFileURL(for: artifact.session)
        }

        if let session = try session(id: id) {
            return markdownFileURL(for: session)
        }

        return nil
    }

    public func artifacts(limit: Int = 20) throws -> [LocalMeetingArtifact] {
        guard fileExists(at: rootDirectory) else {
            return []
        }

        let sessionDirectories = try FileManager.default.contentsOfDirectory(
            at: rootDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )

        var artifacts: [LocalMeetingArtifact] = []
        for directory in sessionDirectories {
            let values = try directory.resourceValues(forKeys: [.isDirectoryKey])
            guard values.isDirectory == true else {
                continue
            }

            let artifactURL = directory.appending(path: "artifact.json", directoryHint: .notDirectory)
            guard fileExists(at: artifactURL) else {
                continue
            }

            let data = try Data(contentsOf: artifactURL)
            artifacts.append(try decoder.decode(LocalMeetingArtifact.self, from: data))
        }

        return Array(artifacts
            .sorted { lhs, rhs in lhs.session.startedAt > rhs.session.startedAt }
            .prefix(limit))
    }

    public func search(_ query: LocalLibrarySearchQuery) throws -> [LocalLibrarySearchResult] {
        guard fileExists(at: rootDirectory) else {
            return []
        }

        let sessionDirectories = try FileManager.default.contentsOfDirectory(
            at: rootDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )

        var candidates: [LocalLibrarySearch.Candidate] = []
        for directory in sessionDirectories {
            let values = try directory.resourceValues(forKeys: [.isDirectoryKey])
            guard values.isDirectory == true else {
                continue
            }

            let sessionURL = directory.appending(path: "session.json", directoryHint: .notDirectory)
            guard fileExists(at: sessionURL) else {
                continue
            }

            let sessionData = try Data(contentsOf: sessionURL)
            let session = try decoder.decode(RecordingSession.self, from: sessionData)
            let artifactURL = directory.appending(path: "artifact.json", directoryHint: .notDirectory)
            let artifact: LocalMeetingArtifact?
            if fileExists(at: artifactURL) {
                let artifactData = try Data(contentsOf: artifactURL)
                artifact = try decoder.decode(LocalMeetingArtifact.self, from: artifactData)
            } else {
                artifact = nil
            }

            candidates.append(LocalLibrarySearch.Candidate(session: session, artifact: artifact))
        }

        return LocalLibrarySearch.rank(candidates: candidates, query: query)
    }

    public func sessionJSONFileURL(for id: RecordingSession.ID) -> URL {
        ((try? existingSessionDirectoryURL(for: id)) ?? legacySessionDirectoryURL(for: id))
            .appending(path: "session.json")
    }

    public func artifactJSONFileURL(for id: RecordingSession.ID) -> URL {
        ((try? existingSessionDirectoryURL(for: id)) ?? legacySessionDirectoryURL(for: id))
            .appending(path: "artifact.json")
    }

    public func sessionDirectoryURL(for id: RecordingSession.ID) -> URL {
        (try? existingSessionDirectoryURL(for: id)) ?? legacySessionDirectoryURL(for: id)
    }

    private func existingArtifactLocation(for session: RecordingSession) -> LocalMeetingArtifactLocation {
        let sessionDirectory = (try? existingSessionDirectoryURL(for: session.id))
            ?? preferredSessionDirectoryURL(for: session)
        return LocalMeetingArtifactLocation(
            sessionDirectoryURL: sessionDirectory,
            sessionJSONFileURL: sessionDirectory.appending(path: "session.json"),
            artifactJSONFileURL: sessionDirectory.appending(path: "artifact.json"),
            markdownFileURL: sessionDirectory.appending(path: "\(sanitizedTitlePathComponent(session.title)).md")
        )
    }

    private func preferredSessionDirectoryURL(for session: RecordingSession) -> URL {
        let title = sanitizedTitlePathComponent(session.title)
        return rootDirectory.appending(
            path: "\(title)--\(session.id.uuidString.lowercased())",
            directoryHint: .isDirectory
        )
    }

    private func legacySessionDirectoryURL(for id: RecordingSession.ID) -> URL {
        rootDirectory.appending(path: id.uuidString, directoryHint: .isDirectory)
    }

    private func existingSessionDirectoryURL(for id: RecordingSession.ID) throws -> URL? {
        guard fileExists(at: rootDirectory) else {
            return nil
        }

        let legacy = legacySessionDirectoryURL(for: id)
        if fileExists(at: legacy) {
            return legacy
        }

        let sessionDirectories = try FileManager.default.contentsOfDirectory(
            at: rootDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )

        let idString = id.uuidString.lowercased()
        for directory in sessionDirectories {
            let values = try directory.resourceValues(forKeys: [.isDirectoryKey])
            guard values.isDirectory == true else {
                continue
            }

            let lastComponent = directory.lastPathComponent.lowercased()
            if lastComponent.hasSuffix("--\(idString)") {
                return directory
            }

            let sessionURL = directory.appending(path: "session.json", directoryHint: .notDirectory)
            guard fileExists(at: sessionURL) else {
                continue
            }
            let sessionData = try Data(contentsOf: sessionURL)
            let session = try decoder.decode(RecordingSession.self, from: sessionData)
            if session.id == id {
                return directory
            }
        }

        return nil
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
        return sanitized.isEmpty ? "untitled-meeting" : String(sanitized.prefix(96))
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

    private func writePrivateData(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
        try protectPrivateFile(at: url)
    }

    private func writePrivateString(_ string: String, to url: URL) throws {
        try string.write(to: url, atomically: true, encoding: .utf8)
        try protectPrivateFile(at: url)
    }

    private func protectPrivateFile(at url: URL) throws {
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path(percentEncoded: false)
        )
    }

    private func removeSupersededMarkdownFiles(in directory: URL, keeping keptFile: URL) throws {
        guard fileExists(at: directory) else {
            return
        }

        let keptPath = keptFile.standardizedFileURL.path(percentEncoded: false)
        let children = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )

        for child in children where child.pathExtension.caseInsensitiveCompare("md") == .orderedSame {
            let childPath = child.standardizedFileURL.path(percentEncoded: false)
            guard childPath != keptPath else {
                continue
            }
            try? FileManager.default.removeItem(at: child)
        }
    }

    private func removeSupersededSessionDirectories(
        for id: RecordingSession.ID,
        keeping keptDirectory: URL
    ) throws {
        guard fileExists(at: rootDirectory) else {
            return
        }

        let keptPath = keptDirectory.standardizedFileURL.path(percentEncoded: false)
        let idString = id.uuidString.lowercased()
        let children = try FileManager.default.contentsOfDirectory(
            at: rootDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )

        for child in children {
            let values = try child.resourceValues(forKeys: [.isDirectoryKey])
            guard values.isDirectory == true else {
                continue
            }
            let childPath = child.standardizedFileURL.path(percentEncoded: false)
            guard childPath != keptPath else {
                continue
            }
            let lastComponent = child.lastPathComponent.lowercased()
            guard lastComponent == idString || lastComponent.hasSuffix("--\(idString)") else {
                continue
            }
            try? FileManager.default.removeItem(at: child)
        }
    }
}

private extension LocalMeetingArtifact {
    static func normalizedMeetingTitle(_ title: String) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Untitled Meeting" : trimmed
    }

    static func markdownByReplacingTopLevelTitle(in markdown: String, title: String) -> String {
        let normalizedTitle = normalizedMeetingTitle(title)
        var lines = markdown.components(separatedBy: "\n")
        if let firstIndex = lines.firstIndex(where: { $0.hasPrefix("# ") }) {
            lines[firstIndex] = "# \(normalizedTitle)"
            return lines.joined(separator: "\n")
        }

        return "# \(normalizedTitle)\n\n\(markdown)"
    }
}

private extension InMemoryLibraryStore {
    static func normalizedMeetingTitle(_ title: String) -> String {
        LocalMeetingArtifact.normalizedMeetingTitle(title)
    }

    static func markdownByReplacingTopLevelTitle(in markdown: String, title: String) -> String {
        LocalMeetingArtifact.markdownByReplacingTopLevelTitle(in: markdown, title: title)
    }
}

private extension FilesystemLocalLibraryStore {
    static func normalizedMeetingTitle(_ title: String) -> String {
        LocalMeetingArtifact.normalizedMeetingTitle(title)
    }

    static func markdownByReplacingTopLevelTitle(in markdown: String, title: String) -> String {
        LocalMeetingArtifact.markdownByReplacingTopLevelTitle(in: markdown, title: title)
    }
}

private enum LocalLibrarySearch {
    struct Candidate {
        var session: RecordingSession
        var artifact: LocalMeetingArtifact?
    }

    private struct RankedCandidate {
        var result: LocalLibrarySearchResult
        var score: Int
    }

    static func rank(candidates: [Candidate], query: LocalLibrarySearchQuery) -> [LocalLibrarySearchResult] {
        let limit = max(0, query.limit)
        guard limit > 0 else {
            return []
        }

        let terms = normalizedTerms(in: query.text)
        let ranked = candidates.compactMap { candidate -> RankedCandidate? in
            let fields = searchableFields(for: candidate)
            let combined = fields.map(\.normalizedText).joined(separator: " ")

            guard terms.isEmpty || terms.allSatisfy({ combined.contains($0) }) else {
                return nil
            }

            let matchedFields = fields.compactMap { field in
                terms.isEmpty || terms.contains(where: { field.normalizedText.contains($0) })
                    ? field.field
                    : nil
            }
            let score = terms.reduce(0) { partialResult, term in
                partialResult + fields.reduce(0) { fieldScore, field in
                    fieldScore + occurrences(of: term, in: field.normalizedText)
                }
            }

            return RankedCandidate(
                result: LocalLibrarySearchResult(
                    session: candidate.session,
                    artifact: candidate.artifact,
                    matchedFields: matchedFields
                ),
                score: score
            )
        }

        return Array(ranked.sorted { lhs, rhs in
            if lhs.score != rhs.score {
                return lhs.score > rhs.score
            }
            if lhs.result.session.startedAt != rhs.result.session.startedAt {
                return lhs.result.session.startedAt > rhs.result.session.startedAt
            }
            return lhs.result.session.id.uuidString < rhs.result.session.id.uuidString
        }
        .map(\.result)
        .prefix(limit))
    }

    private static func searchableFields(for candidate: Candidate) -> [(field: LocalLibrarySearchField, normalizedText: String)] {
        var fields: [(LocalLibrarySearchField, String)] = [
            (.title, normalize(candidate.session.title))
        ]

        if let artifact = candidate.artifact {
            fields.append((.markdown, normalize(artifact.markdown)))
            fields.append((.summary, normalize(summaryText(artifact.summary))))
        }

        return fields
    }

    private static func summaryText(_ summary: MeetingSummary) -> String {
        ([summary.overview] + summary.decisions + summary.actionItems + summary.openQuestions)
            .joined(separator: " ")
    }

    private static func normalizedTerms(in text: String) -> [String] {
        normalize(text)
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
    }

    private static func normalize(_ text: String) -> String {
        text
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .lowercased()
    }

    private static func occurrences(of needle: String, in haystack: String) -> Int {
        guard needle.isEmpty == false else {
            return 0
        }

        var count = 0
        var searchRange = haystack.startIndex..<haystack.endIndex
        while let range = haystack.range(of: needle, options: [], range: searchRange) {
            count += 1
            searchRange = range.upperBound..<haystack.endIndex
        }
        return count
    }
}

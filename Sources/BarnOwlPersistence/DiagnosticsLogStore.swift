import Foundation

public enum DiagnosticsLogLevel: String, Codable, Equatable, Sendable {
    case info
    case warning
    case error
}

public struct DiagnosticsLogEntry: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var timestamp: Date
    public var level: DiagnosticsLogLevel
    public var sessionID: UUID?
    public var category: String
    public var message: String
    public var details: String?

    public init(
        id: UUID = UUID(),
        timestamp: Date,
        level: DiagnosticsLogLevel,
        sessionID: UUID? = nil,
        category: String,
        message: String,
        details: String? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.level = level
        self.sessionID = sessionID
        self.category = category
        self.message = message
        self.details = details
    }
}

public actor DiagnosticsLogStore {
    public let logFileURL: URL

    private let now: @Sendable () -> Date
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(
        rootDirectory: URL,
        fileName: String = "barnowl.log.jsonl",
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.logFileURL = rootDirectory.appending(path: fileName, directoryHint: .notDirectory)
        self.now = now

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        self.encoder = encoder

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    @discardableResult
    public func append(
        level: DiagnosticsLogLevel,
        sessionID: UUID? = nil,
        category: String,
        message: String,
        details: String? = nil
    ) throws -> DiagnosticsLogEntry {
        let entry = DiagnosticsLogEntry(
            timestamp: now(),
            level: level,
            sessionID: sessionID,
            category: category,
            message: message,
            details: details
        )
        try append(entry)
        return entry
    }

    public func append(_ entry: DiagnosticsLogEntry) throws {
        let entry = Self.redactingSensitiveValues(in: entry)
        try FileManager.default.createDirectory(
            at: logFileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let data = try encoder.encode(entry) + Data("\n".utf8)
        if FileManager.default.fileExists(atPath: logFileURL.path(percentEncoded: false)) {
            let handle = try FileHandle(forWritingTo: logFileURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } else {
            try data.write(to: logFileURL, options: .atomic)
        }
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: logFileURL.path(percentEncoded: false)
        )
    }

    public func recentEntries(limit: Int = 50) throws -> [DiagnosticsLogEntry] {
        guard FileManager.default.fileExists(atPath: logFileURL.path(percentEncoded: false)) else {
            return []
        }

        let data = try Data(contentsOf: logFileURL)
        let lines = String(decoding: data, as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: true)

        let entries = lines.compactMap { line -> DiagnosticsLogEntry? in
            guard let lineData = String(line).data(using: .utf8) else { return nil }
            return try? decoder.decode(DiagnosticsLogEntry.self, from: lineData)
        }

        return Array(entries.suffix(limit).reversed())
    }

    public static func redacted(_ text: String?) -> String? {
        guard let text else { return nil }

        return redactionPatterns.reduce(text) { partial, pattern in
            partial.replacingOccurrences(
                of: pattern.expression,
                with: pattern.replacement,
                options: .regularExpression
            )
        }
    }

    private static func redactingSensitiveValues(in entry: DiagnosticsLogEntry) -> DiagnosticsLogEntry {
        DiagnosticsLogEntry(
            id: entry.id,
            timestamp: entry.timestamp,
            level: entry.level,
            sessionID: entry.sessionID,
            category: entry.category,
            message: redacted(entry.message) ?? "",
            details: redacted(entry.details)
        )
    }

    private static let redactionPatterns: [(expression: String, replacement: String)] = [
        (#"sk-[A-Za-z0-9_-]{8,}"#, "[REDACTED_OPENAI_API_KEY]"),
        (#"(?i)(authorization\s*:\s*bearer\s+)[A-Za-z0-9._~+/\-=]{8,}"#, "$1[REDACTED_BEARER_TOKEN]"),
        (#"(?i)\b(OPENAI_API_KEY|BARNOWL_API_KEY_TO_INSTALL)\s*=\s*[^\s"']+"#, "$1=[REDACTED]"),
        (#"(?i)"(api[_-]?key|openai[_-]?api[_-]?key|authorization)"\s*:\s*"[^"]+""#, #""$1":"[REDACTED]""#)
    ]
}

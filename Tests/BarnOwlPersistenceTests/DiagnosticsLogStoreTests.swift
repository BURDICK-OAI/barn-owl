import BarnOwlPersistence
import Foundation
import Testing

@Test
func diagnosticsLogStoreAppendsJSONLinesAndReadsNewestFirst() async throws {
    let root = FileManager.default.temporaryDirectory
        .appending(path: "BarnOwlDiagnosticsTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }

    let store = DiagnosticsLogStore(rootDirectory: root, now: { Date(timeIntervalSince1970: 1) })

    let sessionID = UUID()
    try await store.append(
        level: .info,
        sessionID: sessionID,
        category: "capture",
        message: "Recording started."
    )
    try await store.append(
        level: .warning,
        sessionID: sessionID,
        category: "processing",
        message: "Summary fell back.",
        details: "OpenAI summary unavailable."
    )
    try await store.append(
        level: .error,
        category: "processing",
        message: "Transcription failed."
    )

    let entries = try await store.recentEntries(limit: 2)

    #expect(entries.map(\.message) == ["Transcription failed.", "Summary fell back."])
    #expect(entries[1].sessionID == sessionID)
    #expect(entries[1].details == "OpenAI summary unavailable.")
}

@Test
func diagnosticsLogStoreRedactsSecretsBeforeWriting() async throws {
    let root = FileManager.default.temporaryDirectory
        .appending(path: "BarnOwlDiagnosticsTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }

    let store = DiagnosticsLogStore(rootDirectory: root, now: { Date(timeIntervalSince1970: 1) })
    let messageKey = "sk-" + "proj-" + "abcdefghijklmnopqrstuvwxyz"
    let environmentKeyName = "OPENAI_API" + "_KEY"
    let environmentKey = "sk-" + "test-" + "abcdefghijklmnopqrstuvwxyz"
    let jsonKey = "sk-" + "json-" + "abcdefghijklmnopqrstuvwxyz"

    try await store.append(
        level: .error,
        category: "openai",
        message: "Request failed for \(messageKey)",
        details: #"Authorization: Bearer abcdefghijklmnop \#(environmentKeyName)=\#(environmentKey) {"api_key":"\#(jsonKey)"}"#
    )

    let rawLog = try String(contentsOf: await store.logFileURL, encoding: .utf8)
    #expect(!rawLog.contains(messageKey))
    #expect(!rawLog.contains("abcdefghijklmnop"))
    #expect(!rawLog.contains(environmentKey))
    #expect(!rawLog.contains(jsonKey))

    let entries = try await store.recentEntries(limit: 1)
    #expect(entries[0].message == "Request failed for [REDACTED_OPENAI_API_KEY]")
    #expect(entries[0].details?.contains("[REDACTED_BEARER_TOKEN]") == true)
    #expect(entries[0].details?.contains("\(environmentKeyName)=[REDACTED]") == true)
}

@Test
func diagnosticsLogStoreRestrictsLogFilePermissions() async throws {
    let root = FileManager.default.temporaryDirectory
        .appending(path: "BarnOwlDiagnosticsTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }

    let store = DiagnosticsLogStore(rootDirectory: root, now: { Date(timeIntervalSince1970: 1) })
    try await store.append(level: .info, category: "capture", message: "Recording started.")

    let attributes = try FileManager.default.attributesOfItem(
        atPath: await store.logFileURL.path(percentEncoded: false)
    )
    #expect(attributes[.posixPermissions] as? Int == 0o600)
}

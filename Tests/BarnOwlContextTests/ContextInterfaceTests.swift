import BarnOwlContext
import Foundation
import Testing

private struct StaticProvider: ContextProvider {
    let items: [ContextItem]

    func search(_ query: ContextQuery) async throws -> [ContextItem] {
        Array(items.prefix(query.limit))
    }
}

@Test
func contextProvidersCanLimitResults() async throws {
    let provider = StaticProvider(items: [
        ContextItem(id: "1", title: "One", source: "test", body: "A"),
        ContextItem(id: "2", title: "Two", source: "test", body: "B")
    ])

    let results = try await provider.search(ContextQuery(text: "anything", limit: 1))

    #expect(results.map(\.id) == ["1"])
}

@Test
func readWriteContextProvidersCanBeUsedAsSearchableSinks() async throws {
    let rootDirectory = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: rootDirectory) }

    let provider: any ReadWriteContextProvider = LocalMarkdownContextProvider(
        rootDirectory: rootDirectory,
        sourceName: "tests"
    )

    try await provider.write(ContextArtifact(
        title: "Finalized Meeting",
        markdown: "# Finalized Meeting\n\nDecision: ship local notes."
    ))
    let results = try await provider.search(ContextQuery(text: "local notes"))

    #expect(results.map(\.title) == ["finalized-meeting"])
    #expect(results.first?.source == "tests")
    #expect(results.first?.body == "# Finalized Meeting\n\nDecision: ship local notes.")
}

@Test
func localMarkdownContextProviderWritesDeterministicMarkdownFiles() async throws {
    let rootDirectory = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: rootDirectory) }

    let provider = LocalMarkdownContextProvider(rootDirectory: rootDirectory)

    try await provider.write(ContextArtifact(
        title: "  Q2 / Planning: Launch?  ",
        markdown: "# Launch\n\nContext body."
    ))
    let fileURL = await provider.fileURL(forTitle: "  Q2 / Planning: Launch?  ")
    let markdown = try String(contentsOf: fileURL, encoding: .utf8)

    #expect(fileURL.lastPathComponent == "q2-planning-launch.md")
    #expect(markdown == "# Launch\n\nContext body.")
}

@Test
func localMarkdownContextProviderRestrictsDirectoryAndFilePermissions() async throws {
    let rootDirectory = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: rootDirectory) }

    let provider = LocalMarkdownContextProvider(rootDirectory: rootDirectory)

    try await provider.write(ContextArtifact(
        title: "Private Meeting Context",
        markdown: "# Private\n\nLocal-only context."
    ))
    let fileURL = await provider.fileURL(forTitle: "Private Meeting Context")

    #expect(try posixPermissions(at: rootDirectory) == 0o700)
    #expect(try posixPermissions(at: fileURL) == 0o600)
}

@Test
func localMarkdownContextProviderSearchesDeterministically() async throws {
    let rootDirectory = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: rootDirectory) }

    let provider = LocalMarkdownContextProvider(rootDirectory: rootDirectory)

    try await provider.write(ContextArtifact(title: "Beta Notes", markdown: "Find the lighthouse reference."))
    try await provider.write(ContextArtifact(title: "Alpha Notes", markdown: "Find the lighthouse reference."))
    try await provider.write(ContextArtifact(title: "Gamma Notes", markdown: "Unrelated."))

    let results = try await provider.search(ContextQuery(text: "lighthouse", limit: 2))

    #expect(results.map(\.title) == ["alpha-notes", "beta-notes"])
}

@Test
func calendarMeetingContextProducesPromptReadyContextLines() {
    let startsAt = Date(timeIntervalSince1970: 1_800_010_000)
    let context = CalendarMeetingContext(
        id: "event-1",
        provider: "macOS Calendar",
        title: "Customer Roadmap Review",
        startsAt: startsAt,
        endsAt: startsAt.addingTimeInterval(1_800),
        attendees: ["alex.nguyen@example.com", "Sam Rivera"],
        notes: "Discuss renewal risk and Q3 launch plan.",
        location: "Google Meet",
        url: URL(string: "https://meet.google.com/abc-defg-hij"),
        confidence: 0.92,
        matchReason: "recording started during scheduled event"
    )

    let lines = context.contextLines.joined(separator: "\n")

    #expect(context.isHighConfidence)
    #expect(context.confidenceLabel == "High confidence")
    #expect(lines.contains("Calendar event: Customer Roadmap Review"))
    #expect(lines.contains("Calendar attendees: Alex Nguyen, Sam Rivera"))
    #expect(lines.contains("Calendar URL: https://meet.google.com/abc-defg-hij"))
}

@Test
func calendarAttendeeNameNormalizerPrefersRealNamesAndRejectsRoleAliases() {
    #expect(CalendarAttendeeNameNormalizer.displayName(
        name: "Alice Nguyen",
        email: "alice@example.com"
    ) == "Alice Nguyen")
    #expect(CalendarAttendeeNameNormalizer.displayName(
        name: nil,
        email: "bob.smith@example.com"
    ) == "Bob Smith")
    #expect(CalendarAttendeeNameNormalizer.displayName(
        name: nil,
        email: "sales@example.com"
    ) == nil)
    #expect(CalendarAttendeeNameNormalizer.displayNames(from: [
        "alice.nguyen@example.com",
        "Alice Nguyen",
        "support@example.com"
    ]) == ["Alice Nguyen"])
}

private func makeTempDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appending(path: "BarnOwlContextTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

private func posixPermissions(at url: URL) throws -> Int {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false))
    if let permissions = attributes[.posixPermissions] as? NSNumber {
        return permissions.intValue & 0o777
    }
    return (attributes[.posixPermissions] as? Int ?? 0) & 0o777
}

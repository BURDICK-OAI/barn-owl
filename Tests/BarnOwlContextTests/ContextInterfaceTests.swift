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
func localMarkdownContextProviderRemovesOnlyOrphanedFallbackMirrors() async throws {
    let rootDirectory = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: rootDirectory) }

    let provider = LocalMarkdownContextProvider(rootDirectory: rootDirectory)
    let fallback = "Transcript saved. Summary generation failed, so Barn Owl kept the diarized transcript and logged the summary error."

    try await provider.write(ContextArtifact(
        title: "Canonical Meeting",
        markdown: "# Canonical Meeting\n\n## Summary\n\(fallback)"
    ))
    try await provider.write(ContextArtifact(
        title: "Legacy Duplicate",
        markdown: "# Legacy Duplicate\n\n## Summary\n\(fallback)"
    ))
    try await provider.write(ContextArtifact(
        title: "Orphan Keep",
        markdown: "# Orphan Keep\n\n## Summary\nA real note without fallback text."
    ))

    let removed = try await provider.removeOrphanedMeetingFiles(
        keepingTitles: ["Canonical Meeting"],
        containingAny: [fallback]
    )

    let canonicalURL = await provider.fileURL(forTitle: "Canonical Meeting")
    let duplicateURL = await provider.fileURL(forTitle: "Legacy Duplicate")
    let orphanKeepURL = await provider.fileURL(forTitle: "Orphan Keep")
    #expect(removed == 1)
    #expect(FileManager.default.fileExists(atPath: canonicalURL.path(percentEncoded: false)))
    #expect(!FileManager.default.fileExists(atPath: duplicateURL.path(percentEncoded: false)))
    #expect(FileManager.default.fileExists(atPath: orphanKeepURL.path(percentEncoded: false)))
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
        attendees: ["alex@example.com", "sam@example.com"],
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
    #expect(lines.contains("Calendar attendees: alex@example.com, sam@example.com"))
    #expect(lines.contains("Calendar URL: https://meet.google.com/abc-defg-hij"))
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

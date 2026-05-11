import BarnOwlCore
import BarnOwlPersistence
import Foundation
import Testing

@Test
func localLibrarySearchAcrossManyMeetingsCompletesWithinSmokeBudget() async throws {
    let rootDirectory = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: rootDirectory) }

    let store = FilesystemLocalLibraryStore(rootDirectory: rootDirectory)
    for index in 0..<120 {
        let idSuffix = String(format: "%012x", index + 1_000)
        let id = try #require(UUID(uuidString: "00000000-0000-0000-0000-\(idSuffix)"))
        let repeatedNotes = (0..<24)
            .map { "Meeting \(index) note \($0) about launch readiness, capture reliability, and onboarding." }
            .joined(separator: "\n")
        let marker = index.isMultiple(of: 17) ? "\nneedle production readiness marker" : ""
        let artifact = makeArtifact(
            id: id,
            title: "Production Review \(index)",
            markdown: "# Production Review \(index)\n\n\(repeatedNotes)\(marker)",
            summary: MeetingSummary(
                overview: "Reviewed production readiness area \(index).",
                decisions: ["Keep user-facing state clear."],
                actionItems: ["Follow up on performance path \(index)."],
                openQuestions: ["What remains before shipping?"]
            )
        )
        _ = try await store.saveArtifact(artifact)
    }

    let startedAt = Date()
    let results = try await store.search(LocalLibrarySearchQuery(text: "needle production readiness", limit: 20))
    let elapsed = Date().timeIntervalSince(startedAt)

    #expect(results.count == 8)
    #expect(results.allSatisfy { $0.matchedFields.contains(.markdown) })
    #expect(elapsed < 5)
}

@Test
func artifactLocationsUseDeterministicSessionScopedPaths() async throws {
    let rootDirectory = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: rootDirectory) }

    let sessionID = UUID(uuidString: "00000000-0000-0000-0000-000000000301")!
    let session = makeSession(id: sessionID, title: "  Q2 / Planning: Launch?  ")
    let store = FilesystemLocalLibraryStore(rootDirectory: rootDirectory)

    let location = await store.artifactLocation(for: session)

    #expect(location.sessionDirectoryURL == rootDirectory
        .appending(
            path: "q2-planning-launch--00000000-0000-0000-0000-000000000301",
            directoryHint: .isDirectory
        ))
    #expect(location.sessionJSONFileURL == location.sessionDirectoryURL.appending(path: "session.json"))
    #expect(location.artifactJSONFileURL == location.sessionDirectoryURL.appending(path: "artifact.json"))
    #expect(location.markdownFileURL == location.sessionDirectoryURL.appending(path: "q2-planning-launch.md"))
}

@Test
func savingArtifactRoundTripsJSON() async throws {
    let rootDirectory = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: rootDirectory) }

    let artifact = makeArtifact()
    let store = FilesystemLocalLibraryStore(rootDirectory: rootDirectory)

    let location = try await store.saveArtifact(artifact)
    let reloadedArtifact = try #require(await store.artifact(id: artifact.session.id))
    let reloadedSession = try #require(await store.session(id: artifact.session.id))
    let artifactData = try Data(contentsOf: location.artifactJSONFileURL)
    let decodedArtifact = try JSONDecoder.configuredForLocalLibraryTests.decode(
        LocalMeetingArtifact.self,
        from: artifactData
    )

    #expect(reloadedArtifact == artifact)
    #expect(reloadedSession == artifact.session)
    #expect(decodedArtifact == artifact)
}

@Test
func savingArtifactWritesMarkdownFileAndCanLocateIt() async throws {
    let rootDirectory = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: rootDirectory) }

    let artifact = makeArtifact(markdown: "# Product Review\n\n## Summary\nShip the thing.")
    let store = FilesystemLocalLibraryStore(rootDirectory: rootDirectory)

    let location = try await store.saveArtifact(artifact)
    let locatedMarkdownURL = try #require(await store.markdownFileURL(forSessionID: artifact.session.id))
    let markdown = try String(contentsOf: locatedMarkdownURL, encoding: .utf8)

    #expect(canonicalFilePath(locatedMarkdownURL) == canonicalFilePath(location.markdownFileURL))
    #expect(FileManager.default.fileExists(atPath: location.markdownFileURL.path(percentEncoded: false)))
    #expect(markdown == artifact.markdown)
}

@Test
func savingArtifactRestrictsLibraryDirectoryAndFilePermissions() async throws {
    let rootDirectory = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: rootDirectory) }

    let artifact = makeArtifact(markdown: "# Product Review\n\nPrivate notes.")
    let store = FilesystemLocalLibraryStore(rootDirectory: rootDirectory)

    let location = try await store.saveArtifact(artifact)

    #expect(try posixPermissions(at: rootDirectory) == 0o700)
    #expect(try posixPermissions(at: location.sessionDirectoryURL) == 0o700)
    #expect(try posixPermissions(at: location.sessionJSONFileURL) == 0o600)
    #expect(try posixPermissions(at: location.artifactJSONFileURL) == 0o600)
    #expect(try posixPermissions(at: location.markdownFileURL) == 0o600)
}

@Test
func markdownFileNamesSanitizeUnsafeTitles() async throws {
    let rootDirectory = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: rootDirectory) }

    let session = makeSession(title: "../.. / :Budget*Review? <>|")
    let store = FilesystemLocalLibraryStore(rootDirectory: rootDirectory)

    let markdownURL = await store.markdownFileURL(for: session)

    #expect(markdownURL.lastPathComponent == "budget-review.md")
    #expect(markdownURL.deletingLastPathComponent().lastPathComponent.hasPrefix("budget-review--"))
    #expect(markdownURL.pathComponents.contains("..") == false)
}

@Test
func artifactPersistenceDoesNotStoreAudioPathsOrRawAudio() async throws {
    let rootDirectory = try makeTempDirectory()
    let rawAudioURL = rootDirectory.appending(path: "raw-audio.caf")
    defer { try? FileManager.default.removeItem(at: rootDirectory) }
    try Data([1, 2, 3]).write(to: rawAudioURL)

    let store = FilesystemLocalLibraryStore(rootDirectory: rootDirectory.appending(path: "Library"))
    let artifact = makeArtifact()

    let location = try await store.saveArtifact(artifact)
    let sessionJSON = try String(contentsOf: location.sessionJSONFileURL, encoding: .utf8)
    let artifactJSON = try String(contentsOf: location.artifactJSONFileURL, encoding: .utf8)
    let persistedFiles = try persistedFileURLs(in: location.sessionDirectoryURL)

    #expect(sessionJSON.contains(rawAudioURL.path(percentEncoded: false)) == false)
    #expect(artifactJSON.contains(rawAudioURL.path(percentEncoded: false)) == false)
    #expect(artifactJSON.contains("temporaryAudioPath") == false)
    #expect(artifactJSON.contains("rawAudio") == false)
    #expect(!persistedFiles.contains { ["caf", "wav", "m4a", "mp3"].contains($0.pathExtension) })
}

@Test
func updatingMarkdownBySessionIDPreservesSessionAndArtifactIdentity() async throws {
    let rootDirectory = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: rootDirectory) }

    let artifact = makeArtifact(markdown: "# Product Review\n\nOriginal notes")
    let store = FilesystemLocalLibraryStore(rootDirectory: rootDirectory)

    let location = try await store.saveArtifact(artifact)
    let updatedMarkdown = "# Product Review\n\nEdited notes with follow-up."
    let updatedArtifact = try #require(await store.updateMarkdown(
        sessionID: artifact.session.id,
        markdown: updatedMarkdown
    ))
    let reloadedArtifact = try #require(await store.artifact(id: artifact.session.id))
    let reloadedSession = try #require(await store.session(id: artifact.session.id))
    let persistedMarkdown = try String(contentsOf: location.markdownFileURL, encoding: .utf8)

    #expect(updatedArtifact.session == artifact.session)
    #expect(updatedArtifact.summary == artifact.summary)
    #expect(updatedArtifact.transcriptSegments == artifact.transcriptSegments)
    #expect(updatedArtifact.markdown == updatedMarkdown)
    #expect(reloadedArtifact == updatedArtifact)
    #expect(reloadedSession == artifact.session)
    #expect(persistedMarkdown == updatedMarkdown)
}

@Test
func updatingMarkdownForMissingSessionReturnsNil() async throws {
    let rootDirectory = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: rootDirectory) }

    let store = FilesystemLocalLibraryStore(rootDirectory: rootDirectory)
    let updatedArtifact = try await store.updateMarkdown(
        sessionID: UUID(uuidString: "00000000-0000-0000-0000-000000000399")!,
        markdown: "No-op"
    )

    #expect(updatedArtifact == nil)
}

@Test
func updatingSessionTitleRenamesFolderAndMarkdownHeading() async throws {
    let rootDirectory = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: rootDirectory) }

    let artifact = makeArtifact(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000323")!,
        title: "Original Name",
        markdown: "# Original Name\n\nNotes"
    )
    let store = FilesystemLocalLibraryStore(rootDirectory: rootDirectory)

    let oldLocation = try await store.saveArtifact(artifact)
    let updatedArtifact = try #require(await store.updateSessionTitle(
        sessionID: artifact.session.id,
        title: "Customer Launch Review"
    ))
    let newLocation = try #require(await store.markdownFileURL(forSessionID: artifact.session.id))
        .deletingLastPathComponent()
    let reloadedArtifact = try #require(await store.artifact(id: artifact.session.id))

    #expect(updatedArtifact.session.title == "Customer Launch Review")
    #expect(updatedArtifact.markdown.hasPrefix("# Customer Launch Review"))
    #expect(reloadedArtifact == updatedArtifact)
    #expect(newLocation.lastPathComponent == "customer-launch-review--00000000-0000-0000-0000-000000000323")
    #expect(FileManager.default.fileExists(atPath: oldLocation.sessionDirectoryURL.path(percentEncoded: false)) == false)
}

@Test
func markdownFileURLKeepsExistingSessionFolderWhenTitleDraftChanges() async throws {
    let rootDirectory = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: rootDirectory) }

    let sessionID = UUID(uuidString: "00000000-0000-0000-0000-000000000324")!
    let artifact = makeArtifact(
        id: sessionID,
        title: "Original Name",
        markdown: "# Original Name\n\nNotes"
    )
    let store = FilesystemLocalLibraryStore(rootDirectory: rootDirectory)

    let savedLocation = try await store.saveArtifact(artifact)
    let draftSession = makeSession(id: sessionID, title: "Draft Rename")
    let draftMarkdownURL = await store.markdownFileURL(for: draftSession)

    #expect(canonicalFilePath(draftMarkdownURL.deletingLastPathComponent()) == canonicalFilePath(savedLocation.sessionDirectoryURL))
    #expect(draftMarkdownURL.lastPathComponent == "draft-rename.md")
}

@Test
func searchFindsStoredSessionsByTitleMarkdownAndSummary() async throws {
    let rootDirectory = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: rootDirectory) }

    let store = FilesystemLocalLibraryStore(rootDirectory: rootDirectory)
    let titleMatch = makeArtifact(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000311")!,
        title: "Roadmap Planning",
        markdown: "# Notes\n\nGeneral discussion"
    )
    let markdownMatch = makeArtifact(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000312")!,
        title: "Weekly Sync",
        markdown: "# Weekly Sync\n\nDiscussed lighthouse rollout."
    )
    let summaryMatch = makeArtifact(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000313")!,
        title: "Support Review",
        markdown: "# Support Review\n\nNo launch terms here.",
        summary: MeetingSummary(
            overview: "Customer escalation mentions lighthouse.",
            decisions: [],
            actionItems: [],
            openQuestions: []
        )
    )

    try await store.saveArtifact(titleMatch)
    try await store.saveArtifact(markdownMatch)
    try await store.saveArtifact(summaryMatch)

    let titleResults = try await store.search(LocalLibrarySearchQuery(text: "roadmap"))
    let markdownResults = try await store.search(LocalLibrarySearchQuery(text: "lighthouse rollout"))
    let summaryResults = try await store.search(LocalLibrarySearchQuery(text: "customer escalation"))

    #expect(titleResults.map(\.session.id) == [titleMatch.session.id])
    #expect(titleResults.first?.matchedFields == [.title])
    #expect(markdownResults.map(\.session.id) == [markdownMatch.session.id])
    #expect(markdownResults.first?.matchedFields == [.markdown])
    #expect(summaryResults.map(\.session.id) == [summaryMatch.session.id])
    #expect(summaryResults.first?.matchedFields == [.summary])
}

@Test
func searchUsesDeterministicScoringAndLimit() async throws {
    let rootDirectory = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: rootDirectory) }

    let store = FilesystemLocalLibraryStore(rootDirectory: rootDirectory)
    let lowerScore = makeArtifact(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000321")!,
        title: "Alpha",
        markdown: "needle"
    )
    let higherScore = makeArtifact(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000322")!,
        title: "Needle Review",
        markdown: "needle needle"
    )

    try await store.saveArtifact(lowerScore)
    try await store.saveArtifact(higherScore)

    let results = try await store.search(LocalLibrarySearchQuery(text: "needle", limit: 1))

    #expect(results.map(\.session.id) == [higherScore.session.id])
}

@Test
func deletingSessionRemovesLibraryFolderAndSearchResults() async throws {
    let rootDirectory = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: rootDirectory) }

    let store = FilesystemLocalLibraryStore(rootDirectory: rootDirectory)
    let artifact = makeArtifact(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000323")!,
        title: "Delete Me",
        markdown: "# Delete Me\n\nneedle"
    )

    try await store.saveArtifact(artifact)
    let markdownURL = try #require(await store.markdownFileURL(forSessionID: artifact.session.id))
    #expect(FileManager.default.fileExists(atPath: markdownURL.path(percentEncoded: false)))

    try await store.deleteSession(id: artifact.session.id)

    #expect(try await store.artifact(id: artifact.session.id) == nil)
    #expect(try await store.session(id: artifact.session.id) == nil)
    #expect(try await store.search(LocalLibrarySearchQuery(text: "needle")).isEmpty)
    #expect(!FileManager.default.fileExists(atPath: markdownURL.deletingLastPathComponent().path(percentEncoded: false)))
}

private func makeArtifact(
    id: UUID = UUID(uuidString: "00000000-0000-0000-0000-000000000302")!,
    title: String = "Product Review",
    markdown: String = "# Product Review\n\nNotes",
    summary: MeetingSummary = MeetingSummary(
        overview: "Reviewed product launch status.",
        decisions: ["Ship the scoped persistence work."],
        actionItems: ["Add focused persistence tests."],
        openQuestions: ["Should export live next?"]
    )
) -> LocalMeetingArtifact {
    LocalMeetingArtifact(
        session: makeSession(id: id, title: title),
        summary: summary,
        transcriptSegments: [
            TranscriptSegment(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000303")!,
                speakerLabel: "Alex",
                text: "Let's keep the library local.",
                startTime: 0,
                endTime: 2.5,
                confidence: 0.98
            )
        ],
        markdown: markdown
    )
}

private func makeSession(
    id: UUID = UUID(uuidString: "00000000-0000-0000-0000-000000000304")!,
    title: String
) -> RecordingSession {
    RecordingSession(
        id: id,
        title: title,
        startedAt: Date(timeIntervalSince1970: 1_775_000_000),
        endedAt: Date(timeIntervalSince1970: 1_775_000_600),
        audioSources: .defaultMeetingCapture
    )
}

private func persistedFileURLs(in directory: URL) throws -> [URL] {
    let enumerator = FileManager.default.enumerator(
        at: directory,
        includingPropertiesForKeys: [.isRegularFileKey],
        options: [.skipsHiddenFiles]
    )

    return try enumerator?.compactMap { item in
        guard let url = item as? URL else {
            return nil
        }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey])
        return values.isRegularFile == true ? url : nil
    } ?? []
}

private func makeTempDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appending(path: "BarnOwlPersistenceTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

private func canonicalFilePath(_ url: URL) -> String {
    url.resolvingSymlinksInPath().path(percentEncoded: false)
}

private func posixPermissions(at url: URL) throws -> Int {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false))
    if let permissions = attributes[.posixPermissions] as? NSNumber {
        return permissions.intValue & 0o777
    }
    return (attributes[.posixPermissions] as? Int ?? 0) & 0o777
}

private extension JSONDecoder {
    static var configuredForLocalLibraryTests: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

import AppKit
import BarnOwlAudio
import BarnOwlCore
import BarnOwlOpenAI
import BarnOwlPersistence
import SwiftUI
import UniformTypeIdentifiers

private enum ContextEntityKind: String, CaseIterable, Hashable {
    case person
    case organization = "company"
    case customerAccount = "customer_account"
    case internalFunction = "internal_function"
    case product
    case project
    case event
    case glossaryTerm = "internal_term"

    static func displaying(_ rawKind: String) -> ContextEntityKind {
        switch rawKind {
        case "person":
            .person
        case "company", "organization":
            .organization
        case "account", "customer", "customer_account":
            .customerAccount
        case "internal_function":
            .internalFunction
        case "product":
            .product
        case "project":
            .project
        case "event":
            .event
        default:
            .glossaryTerm
        }
    }
}

private struct BarnOwlContextEntityRecord: Sendable {
    var id: UUID
    var kind: ContextEntityKind
    var canonicalName: String
    var confidence: Double
    var isConfirmed: Bool
    var createdAt: Date
    var updatedAt: Date
}

private struct BarnOwlContextEntityAliasRecord: Sendable {
    var entityID: UUID
    var alias: String
    var confidence: Double
    var isConfirmed: Bool
    var createdAt: Date
    var updatedAt: Date
}

private extension BarnOwlDatabase {
    func contextEntities(limit: Int) throws -> [BarnOwlContextEntityRecord] {
        try knowledgeEntities(
            ownerID: BarnOwlEnrichmentSourceOwner.localUserID(),
            limit: limit
        ).map { entity in
            BarnOwlContextEntityRecord(
                id: entity.id,
                kind: ContextEntityKind.displaying(entity.kind),
                canonicalName: entity.canonicalName,
                confidence: entity.confidence,
                isConfirmed: entity.lifecycleStatus == .active,
                createdAt: entity.createdAt,
                updatedAt: entity.updatedAt
            )
        }
    }

    func contextEntityAliases(entityID: UUID) throws -> [BarnOwlContextEntityAliasRecord] {
        try knowledgeAliases(entityID: entityID).map { alias in
            BarnOwlContextEntityAliasRecord(
                entityID: alias.entityID,
                alias: alias.alias,
                confidence: alias.confidence,
                isConfirmed: true,
                createdAt: alias.createdAt,
                updatedAt: alias.updatedAt
            )
        }
    }

    func upsertContextEntity(_ entity: BarnOwlContextEntityRecord) throws {
        try upsertKnowledgeEntity(BarnOwlKnowledgeEntityRecord(
            id: entity.id,
            ownerID: BarnOwlEnrichmentSourceOwner.localUserID(),
            kind: entity.kind.rawValue,
            canonicalName: entity.canonicalName,
            confidence: entity.confidence,
            lifecycleStatus: entity.isConfirmed ? .active : .suppressed,
            createdAt: entity.createdAt,
            updatedAt: entity.updatedAt
        ))
    }

    func deleteContextEntityAliases(entityID: UUID) throws {
        try deleteKnowledgeAliases(
            entityID: entityID,
            ownerID: BarnOwlEnrichmentSourceOwner.localUserID()
        )
    }

    func upsertContextEntityAlias(_ alias: BarnOwlContextEntityAliasRecord) throws {
        try upsertKnowledgeAlias(BarnOwlKnowledgeAliasRecord(
            ownerID: BarnOwlEnrichmentSourceOwner.localUserID(),
            entityID: alias.entityID,
            alias: alias.alias,
            confidence: alias.confidence,
            createdAt: alias.createdAt,
            updatedAt: alias.updatedAt
        ))
    }

    func deleteContextEntity(id: UUID) throws {
        _ = try setKnowledgeEntityLifecycleStatus(
            id: id,
            ownerID: BarnOwlEnrichmentSourceOwner.localUserID(),
            status: .suppressed,
            reason: "Removed from Context Library."
        )
    }
}

private struct ContextLibraryEntry: Identifiable, Equatable {
    let id: UUID
    var kind: ContextEntityKind
    var canonicalName: String
    var aliases: [String]
    var confidence: Double
    var isConfirmed: Bool
    var createdAt: Date
    var updatedAt: Date
}

private struct ContextLibraryDraft: Equatable {
    var kind: ContextEntityKind = .person
    var canonicalName = ""
    var aliasesText = ""

    var normalizedAliases: [String] {
        var seen = Set<String>()
        return aliasesText
            .components(separatedBy: CharacterSet(charactersIn: ",\n"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { alias in
                guard !alias.isEmpty else { return false }
                return seen.insert(alias.lowercased()).inserted
            }
    }
}

private enum ContextLibrarySheetMode: String, Identifiable {
    case manage
    case add

    var id: String { rawValue }
}

private func contextLibraryKindTitle(_ kind: ContextEntityKind) -> String {
    switch kind {
    case .person:
        "Person"
    case .organization:
        "Organization"
    case .customerAccount:
        "Customer Account"
    case .internalFunction:
        "Internal Function"
    case .product:
        "Product"
    case .project:
        "Project"
    case .event:
        "Event"
    case .glossaryTerm:
        "Glossary Term"
    }
}

private struct ContextLibraryManagerSheet: View {
    let initialMode: ContextLibrarySheetMode
    let onEntriesChanged: ([ContextLibraryEntry]) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var entries: [ContextLibraryEntry] = []
    @State private var searchText = ""
    @State private var selectedKindRawValue = "all"
    @State private var draft = ContextLibraryDraft()
    @State private var editingEntryID: UUID?
    @State private var showsEditor = false
    @State private var pendingDeletion: ContextLibraryEntry?
    @State private var status = ""
    @State private var isRefreshing = false
    @State private var isSaving = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Context Library")
                        .font(.title3.weight(.semibold))
                    Text("Search, filter, create, edit, and delete durable entries Barn Owl can reuse in later meetings.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer()

                Button("Done") {
                    dismiss()
                }
                .buttonStyle(.bordered)
            }

            HStack(spacing: 10) {
                TextField("Search names, accounts, terms, or aliases", text: $searchText)
                    .textFieldStyle(.roundedBorder)

                Picker("Type", selection: $selectedKindRawValue) {
                    Text("All Types").tag("all")
                    ForEach(ContextEntityKind.allCases, id: \.rawValue) { kind in
                        Text(contextLibraryKindTitle(kind)).tag(kind.rawValue)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 190)

                Button(isRefreshing ? "Refreshing..." : "Refresh") {
                    Task {
                        await refreshEntries()
                    }
                }
                .buttonStyle(.borderless)
                .disabled(isRefreshing || isSaving)
            }

            HStack(spacing: 8) {
                Button("Add Entry") {
                    beginCreatingEntry()
                }
                .buttonStyle(.borderedProminent)
                .disabled(isSaving)

                Text("\(filteredEntries.count) shown of \(entries.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer()
            }

            if showsEditor {
                editorCard
            }

            if !status.isEmpty {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .padding(9)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if filteredEntries.isEmpty {
                        Text(entries.isEmpty ? "No Context Library entries yet." : "No entries match the current search and filter.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .padding(14)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    } else {
                        ForEach(filteredEntries) { entry in
                            libraryRow(entry)
                        }
                    }
                }
                .padding(.vertical, 2)
            }
        }
        .padding(20)
        .frame(minWidth: 680, idealWidth: 760, maxWidth: 860)
        .frame(minHeight: 620, idealHeight: 700, maxHeight: 820)
        .task {
            await refreshEntries()
            if initialMode == .add {
                beginCreatingEntry()
            }
        }
        .alert(
            "Delete Context Library entry?",
            isPresented: Binding(
                get: { pendingDeletion != nil },
                set: { if !$0 { pendingDeletion = nil } }
            )
        ) {
            Button("Delete Entry", role: .destructive) {
                guard let entry = pendingDeletion else { return }
                Task {
                    await deleteEntry(entry)
                }
            }
            Button("Cancel", role: .cancel) {
                pendingDeletion = nil
            }
        } message: {
            Text("This removes the saved mapping from this macOS user's local Context Library.")
        }
    }

    private var editorCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(editingEntryID == nil ? "Add Entry" : "Edit Entry")
                    .font(.callout.weight(.semibold))
                Spacer()
                Button("Cancel") {
                    resetEditor()
                }
                .buttonStyle(.borderless)
                .disabled(isSaving)
            }

            Picker("Type", selection: $draft.kind) {
                ForEach(ContextEntityKind.allCases, id: \.self) { kind in
                    Text(contextLibraryKindTitle(kind)).tag(kind)
                }
            }
            .pickerStyle(.menu)

            TextField("Canonical name or term", text: $draft.canonicalName)
                .textFieldStyle(.roundedBorder)

            TextField("Aliases or misheard forms, comma-separated", text: $draft.aliasesText)
                .textFieldStyle(.roundedBorder)

            Text("Aliases are the names, spellings, or misheard forms Barn Owl should map back to the canonical value.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Button(isSaving ? "Saving..." : saveButtonTitle) {
                    Task {
                        await saveEntry()
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(
                    isSaving
                        || draft.canonicalName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                )

                Spacer()
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func libraryRow(_ entry: ContextLibraryEntry) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(contextLibraryKindTitle(entry.kind))
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(BarnOwlSettingsTheme.success)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(BarnOwlSettingsTheme.success.opacity(0.12), in: RoundedRectangle(cornerRadius: 7, style: .continuous))

                Text(entry.canonicalName)
                    .font(.callout.weight(.semibold))

                Spacer(minLength: 8)

                Button("Edit Entry") {
                    beginEditingEntry(entry)
                }
                .buttonStyle(.borderless)
                .disabled(isSaving)

                Button("Delete Entry", role: .destructive) {
                    pendingDeletion = entry
                }
                .buttonStyle(.borderless)
                .disabled(isSaving)
            }

            Text(entry.aliases.isEmpty ? "No aliases saved." : "Aliases: \(entry.aliases.joined(separator: ", "))")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.opacity(0.45), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var selectedKind: ContextEntityKind? {
        guard selectedKindRawValue != "all" else { return nil }
        return ContextEntityKind(rawValue: selectedKindRawValue)
    }

    private var filteredEntries: [ContextLibraryEntry] {
        let normalizedSearch = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return entries.filter { entry in
            let matchesKind = selectedKind.map { entry.kind == $0 } ?? true
            guard matchesKind else { return false }
            guard !normalizedSearch.isEmpty else { return true }
            let searchableText = ([entry.canonicalName] + entry.aliases)
                .joined(separator: " ")
            return searchableText.localizedCaseInsensitiveContains(normalizedSearch)
        }
    }

    private var saveButtonTitle: String {
        editingEntryID == nil ? "Add Entry" : "Save Changes"
    }

    private func beginCreatingEntry() {
        editingEntryID = nil
        draft = ContextLibraryDraft()
        showsEditor = true
        status = ""
    }

    private func beginEditingEntry(_ entry: ContextLibraryEntry) {
        editingEntryID = entry.id
        draft = ContextLibraryDraft(
            kind: entry.kind,
            canonicalName: entry.canonicalName,
            aliasesText: entry.aliases.joined(separator: ", ")
        )
        showsEditor = true
        status = "Editing \(entry.canonicalName)."
    }

    private func resetEditor() {
        editingEntryID = nil
        draft = ContextLibraryDraft()
        showsEditor = false
    }

    private func refreshEntries() async {
        isRefreshing = true
        defer { isRefreshing = false }

        do {
            let database = try BarnOwlDatabase(url: try BarnOwlAppModel.defaultDatabaseURL())
            let entities = try await database.contextEntities(limit: 500)
            var refreshedEntries: [ContextLibraryEntry] = []
            refreshedEntries.reserveCapacity(entities.count)

            for entity in entities {
                let aliases = try await database.contextEntityAliases(entityID: entity.id)
                    .map(\.alias)
                refreshedEntries.append(ContextLibraryEntry(
                    id: entity.id,
                    kind: entity.kind,
                    canonicalName: entity.canonicalName,
                    aliases: aliases,
                    confidence: entity.confidence,
                    isConfirmed: entity.isConfirmed,
                    createdAt: entity.createdAt,
                    updatedAt: entity.updatedAt
                ))
            }

            entries = refreshedEntries
            onEntriesChanged(refreshedEntries)
        } catch {
            status = "Could not load Context Library: \(BarnOwlErrorFormatter.message(for: error))"
        }
    }

    private func saveEntry() async {
        let canonicalName = draft.canonicalName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !canonicalName.isEmpty else {
            status = "Enter a canonical name or term before saving."
            return
        }

        let duplicate = entries.contains { entry in
            entry.id != editingEntryID
                && entry.kind == draft.kind
                && entry.canonicalName.localizedCaseInsensitiveCompare(canonicalName) == .orderedSame
        }
        guard !duplicate else {
            status = "That Context Library entry already exists for this type."
            return
        }

        isSaving = true
        defer { isSaving = false }

        do {
            let database = try BarnOwlDatabase(url: try BarnOwlAppModel.defaultDatabaseURL())
            let now = Date()
            let existing = editingEntryID.flatMap { id in
                entries.first(where: { $0.id == id })
            }
            let entityID = existing?.id ?? UUID()
            try await database.upsertContextEntity(BarnOwlContextEntityRecord(
                id: entityID,
                kind: draft.kind,
                canonicalName: canonicalName,
                confidence: existing?.confidence ?? 1,
                isConfirmed: true,
                createdAt: existing?.createdAt ?? now,
                updatedAt: now
            ))
            try await database.deleteContextEntityAliases(entityID: entityID)
            for alias in draft.normalizedAliases where alias.localizedCaseInsensitiveCompare(canonicalName) != .orderedSame {
                try await database.upsertContextEntityAlias(BarnOwlContextEntityAliasRecord(
                    entityID: entityID,
                    alias: alias,
                    confidence: 1,
                    isConfirmed: true,
                    createdAt: now,
                    updatedAt: now
                ))
            }

            status = existing == nil
                ? "Added entry to the Context Library."
                : "Updated Context Library entry."
            resetEditor()
            await refreshEntries()
        } catch {
            status = "Could not save Context Library entry: \(BarnOwlErrorFormatter.message(for: error))"
        }
    }

    private func deleteEntry(_ entry: ContextLibraryEntry) async {
        isSaving = true
        defer {
            isSaving = false
            pendingDeletion = nil
        }

        do {
            let database = try BarnOwlDatabase(url: try BarnOwlAppModel.defaultDatabaseURL())
            try await database.deleteContextEntity(id: entry.id)
            if editingEntryID == entry.id {
                resetEditor()
            }
            status = "Deleted Context Library entry for \(entry.canonicalName)."
            await refreshEntries()
        } catch {
            status = "Could not delete Context Library entry: \(BarnOwlErrorFormatter.message(for: error))"
        }
    }
}

struct SettingsView: View {
    @AppStorage(BarnOwlFinalTranscriptionMode.defaultsKey) private var finalTranscriptionModeRawValue =
        BarnOwlFinalTranscriptionMode.speakerTurns.rawValue
    @State private var apiKey = ""
    @State private var apiKeyStatus = ""
    @State private var hasStoredAPIKey = false
    @State private var apiKeyConnectionState: APIKeyConnectionState = .missing
    @State private var isValidatingAPIKey = false
    @State private var readinessSnapshot = BarnOwlFirstRunReadiness.placeholderSnapshot
    @State private var readinessChecks: [String] = []
    @State private var readinessActionStatus = ""
    @State private var updateSettingsStatus = ""
    @State private var updateAvailability: BarnOwlUpdateAvailability = .unknown
    @State private var releaseNotesAvailability: BarnOwlReleaseNotesAvailability = .unknown
    @State private var showReleaseNotesHistory = false
    @State private var codexBridgeStatus = "checking"
    @State private var codexIntegrationLines: [String] = []
    @State private var codexIntegrationStatus = ""
    @State private var isRunningCaptureTest = false
    @State private var isRepairingAPIKeyAccess = false
    @State private var showReadinessDiagnostics = false
    @State private var developerDiagnosticsStatus = ""
    @State private var isExportingDeveloperDiagnostics = false
    @State private var contextLibraryEntries: [ContextLibraryEntry] = []
    @State private var contextLibraryStatus = ""
    @State private var contextLibrarySheetMode: ContextLibrarySheetMode?
    @State private var isRefreshingContextLibrary = false
    @State private var enrichmentSources: [BarnOwlEnrichmentSourceRecord] = []
    @State private var enrichmentSourceUsefulnessByID: [String: BarnOwlEnrichmentSourceUsefulnessRecord] = [:]
    @State private var recentEnrichmentConceptHistories: [BarnOwlControlEnrichmentConceptHistory] = []
    @State private var enrichmentAuthorityProfiles: [BarnOwlEnrichmentAuthorityProfileRecord] = []
    @State private var enrichmentPolicyPacks: [BarnOwlEnrichmentPolicyPackRecord] = []
    @State private var enrichmentSourcesStatus = ""
    @State private var isRefreshingEnrichmentSources = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                tldrSection
                onboardingReadinessSection
                openAISection
                transcriptionSection
                codexIntegrationSection
                contextLibrarySection
                enrichmentSourcesSection
                developerDiagnosticsSection
                readinessSection
            }
            .padding(20)
        }
        .background(BarnOwlSettingsTheme.background)
        .frame(minWidth: 560, idealWidth: 640, maxWidth: 720)
        .frame(minHeight: 560)
        .onAppear {
            BarnOwlUpdaterSettings.clearLegacyManifestOverride()
            refreshAPIKeyStatus()
            refreshReadinessChecks()
            Task {
                await refreshCodexIntegration()
                await refreshContextLibrary()
                await refreshEnrichmentSources()
                await refreshUpdateNotice()
            }
        }
        .sheet(item: $contextLibrarySheetMode, onDismiss: {
            Task {
                await refreshContextLibrary()
            }
        }) { mode in
            ContextLibraryManagerSheet(
                initialMode: mode,
                onEntriesChanged: { entries in
                    contextLibraryEntries = entries
                }
            )
        }
    }

    private var onboardingReadinessSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            BarnOwlReadinessOnboardingView(
                snapshot: readinessSnapshot,
                actionHandler: handleReadinessAction
            )

            if !readinessActionStatus.isEmpty {
                settingsStatusMessage(readinessActionStatus)
            }

            if !updateSettingsStatus.isEmpty {
                settingsStatusMessage(updateSettingsStatus)
            }

            releaseNotesSection
        }
    }

    @ViewBuilder
    private var releaseNotesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Release Notes")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                Spacer(minLength: 8)

                if case .available = updateAvailability {
                    BarnOwlSettingsStatusPill(
                        title: "Update Available",
                        systemImage: nil,
                        tint: BarnOwlSettingsTheme.warning
                    )
                }
            }

            switch releaseNotesAvailability {
            case .loaded(let notes):
                if let latest = notes.first {
                    latestReleaseNotesRow(latest)

                    if notes.count > 1 {
                        DisclosureGroup(isExpanded: $showReleaseNotesHistory) {
                            ScrollView(.vertical, showsIndicators: true) {
                                VStack(alignment: .leading, spacing: 8) {
                                    ForEach(Array(notes.dropFirst())) { note in
                                        releaseNoteHistoryRow(note)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .frame(maxHeight: 180)
                            .padding(.top, 4)
                        } label: {
                            Text(showReleaseNotesHistory ? "Hide earlier releases" : "Show all release notes (\(notes.count))")
                                .font(.caption.weight(.medium))
                        }
                        .foregroundStyle(.secondary)
                    }
                } else {
                    settingsStatusMessage("No published release notes were found in the update feed.")
                }
            case .loading:
                settingsStatusMessage("Loading release notes...")
            case .unavailable(let message):
                settingsStatusMessage("Release notes unavailable: \(message)")
            case .unknown:
                settingsStatusMessage("Release notes have not been loaded yet.")
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func latestReleaseNotesRow(_ note: BarnOwlReleaseNote) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                BarnOwlSettingsStatusPill(
                    title: "Latest",
                    systemImage: nil,
                    tint: BarnOwlSettingsTheme.success
                )
                Text("Barn Owl \(note.version) (\(note.build))")
                    .font(.caption.weight(.semibold))
            }

            releaseNoteBody(note.notes)
        }
    }

    private func releaseNoteHistoryRow(_ note: BarnOwlReleaseNote) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Barn Owl \(note.version) (\(note.build))")
                .font(.caption.weight(.semibold))
            releaseNoteBody(note.notes)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    @ViewBuilder
    private func releaseNoteBody(_ notes: String) -> some View {
        let parsed = parseReleaseNoteBody(notes)
        VStack(alignment: .leading, spacing: 4) {
            if let title = parsed.title {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            if parsed.highlights.isEmpty {
                Text(parsed.fallback)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(Array(parsed.highlights.enumerated()), id: \.offset) { _, highlight in
                    HStack(alignment: .top, spacing: 5) {
                        Text("-")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                        Text(highlight)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private func parseReleaseNoteBody(_ notes: String) -> (title: String?, highlights: [String], fallback: String) {
        let lines = notes
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard let firstLine = lines.first else {
            return (nil, [], "")
        }

        let title = firstLine.hasPrefix("- ") ? nil : firstLine
        let bulletLines = (title == nil ? lines : Array(lines.dropFirst()))
        let highlights = bulletLines.compactMap { line -> String? in
            guard line.hasPrefix("- ") else { return nil }
            return String(line.dropFirst(2)).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return (title, highlights, notes.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private var header: some View {
        HStack(spacing: 12) {
            BarnOwlMark(status: readinessSnapshot.overallState == .missing ? .failed : .idle, headTurn: 0.2)
                .frame(width: 46, height: 46)

            VStack(alignment: .leading, spacing: 3) {
                Text("Barn Owl Settings")
                    .font(.title3.weight(.semibold))
                Text("Local-first meeting capture, context, and durable memory.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            BarnOwlSettingsStatusPill(
                title: readinessSnapshot.statusTitle,
                systemImage: readinessSnapshot.overallState == .ready ? "checkmark.circle.fill" : "exclamationmark.triangle.fill",
                tint: readinessSnapshot.overallState == .ready ? BarnOwlSettingsTheme.success : BarnOwlSettingsTheme.warning
            )
        }
    }

    private var openAISection: some View {
        settingsCard {
            VStack(alignment: .leading, spacing: 12) {
                settingsSectionHeader(
                    "OpenAI Connection",
                    systemImage: "key.horizontal",
                    status: apiKeyConnectionState.connectionStatusTitle,
                    tint: apiKeyConnectionState.tint
                )

                Label(
                    apiKeyConnectionState.detail,
                    systemImage: apiKeyConnectionState.detailSystemImage
                )
                .foregroundStyle(apiKeyConnectionState.tint)

                Text("Each macOS user adds their own OpenAI API key. Barn Owl stores it in a private local user config file and keeps it out of the app bundle.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                SecureField("OpenAI API key", text: $apiKey)
                    .textFieldStyle(.roundedBorder)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        keyButtons
                    }
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(.vertical, 1)
                }

                if !apiKeyStatus.isEmpty {
                    settingsStatusMessage(apiKeyStatus)
                }

                Text("Need a key? Create one in the OpenAI dashboard, paste it here, then Save & Test. If this Mac has an older Keychain-saved key, use Migrate Keychain Key once or paste the key again.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var transcriptionSection: some View {
        settingsCard {
            VStack(alignment: .leading, spacing: 12) {
                settingsSectionHeader("Final Transcript", systemImage: "waveform.badge.mic")

                Picker("Mode", selection: $finalTranscriptionModeRawValue) {
                    ForEach(BarnOwlFinalTranscriptionMode.allCases) { mode in
                        Text(mode.title).tag(mode.rawValue)
                    }
                }
                .pickerStyle(.segmented)

                Text(finalTranscriptionMode.detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var finalTranscriptionMode: BarnOwlFinalTranscriptionMode {
        BarnOwlFinalTranscriptionMode(rawValue: finalTranscriptionModeRawValue) ?? .speakerTurns
    }

    private var tldrSection: some View {
        settingsCard {
            VStack(alignment: .leading, spacing: 12) {
                settingsSectionHeader("TLDR", systemImage: "sparkles")

                VStack(alignment: .leading, spacing: 9) {
                    settingsTLDRLine(
                        title: "Capture",
                        detail: "Ask Codex with `$barnowl` to record the meeting. Codex should start immediately, attach useful context while it runs, stop on request, wait for processing, then return the finished notes."
                    )
                    settingsTLDRLine(
                        title: "Context",
                        detail: "Barn Owl keeps source-labeled meeting context, durable Context Library entries, and enrichment results together so transcripts, notes, titles, and memory stay better grounded."
                    )
                    settingsTLDRLine(
                        title: "Operate",
                        detail: "Use the bundled `$barnowl` Codex skill or `barnowl` CLI for recording, context, jobs, recent meetings, search, notes, actions, chat, diagnostics, and retries."
                    )
                    settingsTLDRLine(
                        title: "Reuse",
                        detail: "Barn Owl turns meetings into local Markdown artifacts and structured evidence that support later meeting-memory questions, exports, and downstream consumers."
                    )
                    settingsTLDRLine(
                        title: "Improve",
                        detail: "Review titles, notes, actions, and suggested context when needed. Accepted corrections and durable mappings strengthen the learning loop for future meetings."
                    )
                }

                Text("The app is the local operator surface for setup, permissions, API key entry, bridge status, diagnostics, enrichment and Context Library maintenance, and manual review. Recording artifacts, transcript memory, local exports, and the CLI bridge stay on this Mac.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)

                Text("First time here? Use the guided readiness and OpenAI sections above, then configure Codex Integration, Context Library, and Enrichment Sources below so capture, operation, and long-term learning are set up together.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var keyButtons: some View {
        Group {
            Button("Save & Test Key") {
                saveAPIKey()
            }
            .buttonStyle(.borderedProminent)
            .disabled(apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isValidatingAPIKey)

            Button("Clear Saved Key") {
                clearAPIKey()
            }
            .buttonStyle(.bordered)
            .disabled(!hasStoredAPIKey || isValidatingAPIKey)

            Button("Test Key") {
                Task {
                    await testAPIKey()
                }
            }
            .buttonStyle(.bordered)
            .disabled(!hasStoredAPIKey || isValidatingAPIKey || isRepairingAPIKeyAccess)

            Button("Migrate Keychain Key") {
                repairAPIKeyAccess()
            }
            .buttonStyle(.bordered)
            .disabled(isValidatingAPIKey || isRepairingAPIKeyAccess)

            Button("Create API Key") {
                openOpenAIAPIKeysPage()
            }
            .buttonStyle(.bordered)
        }
    }

    private var readinessSection: some View {
        settingsCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    settingsSectionHeader("Readiness Diagnostics", systemImage: "checklist")
                    Spacer()
                    Button(showReadinessDiagnostics ? "Hide" : "Show") {
                        showReadinessDiagnostics.toggle()
                    }
                    .buttonStyle(.borderless)
                    Button("Refresh") {
                        refreshReadinessChecks()
                    }
                    .buttonStyle(.borderless)
                }

                Text("Sanitized setup checks for troubleshooting. Private paths, keys, and meeting content stay out of this view.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if showReadinessDiagnostics {
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(readinessChecks, id: \.self) { check in
                            Text(check)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                                .lineLimit(2)
                        }
                    }
                }
            }
        }
    }

    private var developerDiagnosticsSection: some View {
        settingsCard {
            VStack(alignment: .leading, spacing: 12) {
                settingsSectionHeader("Developer Diagnostics", systemImage: "stethoscope")

                Text("Export a redacted diagnostics report when something fails. It includes app, setup, update, and recent error metadata, but not API keys, raw audio, transcripts, or private local paths.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Button(isExportingDeveloperDiagnostics ? "Exporting..." : "Export Developer Diagnostics") {
                    exportDeveloperDiagnostics()
                }
                .buttonStyle(.bordered)
                .disabled(isExportingDeveloperDiagnostics)

                if !developerDiagnosticsStatus.isEmpty {
                    settingsStatusMessage(developerDiagnosticsStatus)
                }
            }
        }
    }

    private var codexIntegrationSection: some View {
        settingsCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    settingsSectionHeader("Codex Integration", systemImage: "terminal")
                    Spacer()
                    Label(
                        codexBridgeStatus == "running" ? "Bridge running" : "Bridge not running",
                        systemImage: codexBridgeStatus == "running" ? "checkmark.seal.fill" : "exclamationmark.triangle.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(codexBridgeStatus == "running" ? BarnOwlSettingsTheme.success : BarnOwlSettingsTheme.warning)
                }

                Text("Install the local CLI and bundled `$barnowl` skill so Codex can run capture, context, retrieval, diagnostics, and recovery from chat. The app stays here for setup, permissions, API key entry, enrichment visibility, bridge checks, and manual review.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                ViewThatFits(in: .horizontal) {
                    HStack {
                        codexIntegrationButtons
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        codexIntegrationButtons
                    }
                }

                VStack(alignment: .leading, spacing: 5) {
                    ForEach(codexIntegrationLines, id: \.self) { line in
                        Text(line)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .lineLimit(2)
                    }
                }

                Text("Example prompt: Use $barnowl to record this meeting. Start now, attach concise calendar and chat context while it runs, stop when I ask, wait for processing, then return the Markdown notes, actions, and anything that needs review.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .textSelection(.enabled)

                if !codexIntegrationStatus.isEmpty {
                    settingsStatusMessage(codexIntegrationStatus)
                }
            }
        }
    }

    private var contextLibrarySection: some View {
        settingsCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    settingsSectionHeader("Context Library", systemImage: "text.badge.checkmark")
                    Spacer()
                    Button(isRefreshingContextLibrary ? "Refreshing..." : "Refresh") {
                        Task {
                            await refreshContextLibrary()
                        }
                    }
                    .buttonStyle(.borderless)
                    .disabled(isRefreshingContextLibrary)
                }

                Text("Saved names, organizations, accounts, and terms Barn Owl can recognize and reuse in future meetings.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                contextLibrarySummaryRow

                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        contextLibraryButtons
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        contextLibraryButtons
                    }
                }

                if contextLibraryEntries.isEmpty {
                    Text("No Context Library entries saved yet.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Recently updated")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)

                        ForEach(Array(contextLibraryEntries.prefix(3))) { entry in
                            contextLibraryPreviewRow(entry)
                        }
                    }
                }

                if !contextLibraryStatus.isEmpty {
                    settingsStatusMessage(contextLibraryStatus)
                }
            }
        }
    }

    private var contextLibrarySummaryRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Text("\(contextLibraryEntries.count)")
                    .font(.system(size: 24, weight: .semibold, design: .rounded))
                Text(contextLibraryEntries.count == 1 ? "entry" : "entries")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
            }

            if contextLibraryEntries.isEmpty {
                Text("Add people, companies, accounts, products, projects, internal functions, and glossary terms once so Barn Owl can reuse them later.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                HStack(spacing: 8) {
                    ForEach(contextLibrarySummaryChips, id: \.label) { chip in
                        Text("\(chip.count) \(chip.label)")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .background(.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var contextLibraryButtons: some View {
        Group {
            Button("Manage Context Library") {
                contextLibrarySheetMode = .manage
            }
            .buttonStyle(.borderedProminent)

            Button("Add Entry") {
                contextLibrarySheetMode = .add
            }
            .buttonStyle(.bordered)
        }
    }

    private func contextLibraryPreviewRow(_ entry: ContextLibraryEntry) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(contextLibraryKindTitle(entry.kind))
                .font(.caption2.weight(.bold))
                .foregroundStyle(BarnOwlSettingsTheme.success)
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .background(BarnOwlSettingsTheme.success.opacity(0.12), in: RoundedRectangle(cornerRadius: 7, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(entry.canonicalName)
                    .font(.callout.weight(.semibold))
                Text(entry.aliases.isEmpty ? "No aliases" : entry.aliases.joined(separator: ", "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.opacity(0.45), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var contextLibrarySummaryChips: [(label: String, count: Int)] {
        let counts = Dictionary(grouping: contextLibraryEntries, by: \.kind)
            .mapValues(\.count)
        let preferredKinds: [ContextEntityKind] = [.person, .organization, .glossaryTerm, .customerAccount]
        return preferredKinds.compactMap { kind in
            guard let count = counts[kind], count > 0 else { return nil }
            return (contextLibraryKindTitle(kind).lowercased(), count)
        }
        .prefix(3)
        .map { $0 }
    }

    private var enrichmentSourcesSection: some View {
        settingsCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    settingsSectionHeader("Enrichment Sources", systemImage: "books.vertical")
                    Spacer()
                    Button(isRefreshingEnrichmentSources ? "Refreshing..." : "Refresh") {
                        Task {
                            await refreshEnrichmentSources()
                        }
                    }
                    .buttonStyle(.borderless)
                    .disabled(isRefreshingEnrichmentSources)
                }

                Text("Use Codex with the bundled `$barnowl` skill or the `barnowl` CLI to create and verify real enrichment-source connections. Once a source is connected for this macOS user, Barn Owl lists it here.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(alignment: .leading, spacing: 8) {
                    Text("Examples Codex can configure")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    LazyVGrid(
                        columns: [
                            GridItem(.flexible(minimum: 180), alignment: .leading),
                            GridItem(.flexible(minimum: 180), alignment: .leading)
                        ],
                        alignment: .leading,
                        spacing: 6
                    ) {
                        ForEach(BarnOwlAppModel.enrichmentSourcePresets) { preset in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(preset.displayName)
                                    .font(.caption.weight(.semibold))
                                    .lineLimit(1)
                                Text("\(preset.scopeLabel) · \(preset.connectorReference ?? "built-in")")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                                    .lineLimit(1)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 4)
                            .padding(.horizontal, 7)
                            .background(.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                        }
                    }

                    Text("Examples only. Codex handles the setup work; this panel stays focused on connected sources and their health.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(10)
                .background(.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

                if connectedEnrichmentSources.isEmpty {
                    settingsStatusMessage("No enrichment sources are connected yet.")
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(connectedEnrichmentSources) { source in
                            enrichmentSourceRow(source)
                        }
                    }
                }

                if !enrichmentPolicyPacks.isEmpty {
                    Divider()
                    Text("Automation policy")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    ForEach(enrichmentPolicyPacks) { pack in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 8) {
                                Text(pack.displayName)
                                    .font(.caption.weight(.semibold))
                                if pack.active {
                                    BarnOwlSettingsStatusPill(
                                        title: "Active",
                                        systemImage: nil,
                                        tint: BarnOwlSettingsTheme.success
                                    )
                                } else {
                                    Button("Activate") {
                                        Task {
                                            await activateEnrichmentPolicyPack(pack.id)
                                        }
                                    }
                                    .buttonStyle(.borderless)
                                }
                            }
                            Text(pack.description)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            Text("Automatic promotion threshold: \(pack.minimumSupportingEvidenceCount) evidence item\(pack.minimumSupportingEvidenceCount == 1 ? "" : "s"). Conflict-memory threshold: \(pack.minimumIndependentSourceCountAfterConflictMemory) independent source\(pack.minimumIndependentSourceCountAfterConflictMemory == 1 ? "" : "s").")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                if !enrichmentAuthorityProfiles.isEmpty {
                    Divider()
                    Text("Authority profiles")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    ForEach(enrichmentAuthorityProfiles) { profile in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 8) {
                                Text(profile.displayName)
                                    .font(.caption.weight(.semibold))
                                if profile.builtIn {
                                    BarnOwlSettingsStatusPill(
                                        title: "Preset",
                                        systemImage: nil,
                                        tint: .secondary
                                    )
                                }
                            }
                            Text(profile.description)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            if !profile.strongestEntityKinds.isEmpty {
                                Text("Strongest for: \(profile.strongestEntityKinds.joined(separator: ", ")). Weight \(profile.defaultWeight.formatted(.number.precision(.fractionLength(2)))).")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                if !recentEnrichmentConceptHistories.isEmpty {
                    Divider()
                    Text("Recent concept memory")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    ForEach(recentEnrichmentConceptHistories) { history in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 8) {
                                Text(history.conceptKey)
                                    .font(.caption.weight(.semibold))
                                if history.requiresConflictMemoryHold {
                                    BarnOwlSettingsStatusPill(
                                        title: "Higher bar active",
                                        systemImage: nil,
                                        tint: .orange
                                    )
                                }
                            }
                            Text("\(history.supportedCandidateJobs) supported, \(history.conflictingJobs) conflicted, \(history.negativeEvidenceItems) negative evidence item\(history.negativeEvidenceItems == 1 ? "" : "s").")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                if !enrichmentSourcesStatus.isEmpty {
                    settingsStatusMessage(enrichmentSourcesStatus)
                }
            }
        }
    }

    private func enrichmentSourceRow(_ source: BarnOwlEnrichmentSourceRecord) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(source.displayName)
                        .font(.callout.weight(.semibold))
                    Text(source.id)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                HStack(spacing: 8) {
                    BarnOwlSettingsStatusPill(
                        title: source.healthStatus.displayName,
                        systemImage: nil,
                        tint: enrichmentSourceTint(source.healthStatus)
                    )
                    Toggle(
                        source.enabled ? "Enabled" : "Disabled",
                        isOn: Binding(
                            get: { source.enabled },
                            set: { enabled in
                                Task {
                                    await setEnrichmentSourceEnabled(sourceID: source.id, enabled: enabled)
                                }
                            }
                        )
                    )
                    .toggleStyle(.switch)
                    .labelsHidden()
                }
            }

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                BarnOwlSettingsStatusPill(
                    title: source.scope.displayName,
                    systemImage: nil,
                    tint: .secondary
                )
                Text(source.authorityProfile)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                let checkedAt = source.lastCheckedAt?.formatted(date: .abbreviated, time: .shortened) ?? "Not checked yet"
                Text("Auth: \(source.authState.rawValue.replacingOccurrences(of: "_", with: " ")) · \(checkedAt)")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }

            if !source.bestUsedFor.isEmpty {
                Text("Best for: \(source.bestUsedFor.joined(separator: ", "))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            if let usefulness = enrichmentSourceUsefulnessByID[source.id] {
                Text("Usefulness: \(usefulness.attempts) run\(usefulness.attempts == 1 ? "" : "s") · \(usefulness.supportedJobs) supported · \(usefulness.heldJobs) held · \(usefulness.conflictingJobs) conflicted · \(usefulness.acceptedEvidenceItems)/\(usefulness.evidenceItems) accepted")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var connectedEnrichmentSources: [BarnOwlEnrichmentSourceRecord] {
        enrichmentSources.filter { source in
            !Self.operationalEnrichmentSourceIDs.contains(source.id)
        }
    }

    private static let operationalEnrichmentSourceIDs: Set<String> = [
        "barnowl_memory",
        "public_web"
    ]

    private var codexIntegrationButtons: some View {
        Group {
            Button("Install CLI") {
                installCodexCLI()
            }
            .buttonStyle(.borderedProminent)

            Button("Install Codex Skill") {
                installCodexSkill()
            }
            .buttonStyle(.bordered)

            Button("Test CLI") {
                testCodexCLI()
            }
            .buttonStyle(.bordered)

            Button("Refresh") {
                Task {
                    await refreshCodexIntegration()
                }
            }
            .buttonStyle(.borderless)
        }
    }

    private func settingsCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(.primary.opacity(0.08), lineWidth: 1)
            )
    }

    @ViewBuilder
    private func settingsSectionHeader(
        _ title: String,
        systemImage: String,
        status: String? = nil,
        tint: Color = .secondary
    ) -> some View {
        if let status {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Label(title, systemImage: systemImage)
                    .font(.headline)
                Spacer(minLength: 8)
                BarnOwlSettingsStatusPill(title: status, systemImage: nil, tint: tint)
            }
        } else {
            Label(title, systemImage: systemImage)
                .font(.headline)
        }
    }

    private func settingsStatusMessage(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
            .padding(9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func settingsTLDRLine(title: String, detail: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title)
                .font(.callout.weight(.semibold))
                .frame(width: 88, alignment: .leading)
            Text(detail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func saveAPIKey() {
        do {
            try BarnOwlAPIKeyStore.saveAPIKey(apiKey)
            apiKey = ""
            apiKeyStatus = "Saved locally. Testing OpenAI connection..."
            apiKeyConnectionState = .testing
            refreshAPIKeyStatus()
            refreshReadinessChecks()
            Task {
                await validateSavedAPIKey(successMessage: "Saved and tested. OpenAI authentication works.")
            }
        } catch {
            apiKeyStatus = "Could not save API key."
            refreshAPIKeyStatus()
        }
    }

    private func clearAPIKey() {
        do {
            try BarnOwlAPIKeyStore.deleteStoredAPIKey()
            apiKey = ""
            apiKeyStatus = "Saved API key removed."
            apiKeyConnectionState = .missing
            refreshAPIKeyStatus()
            refreshReadinessChecks()
        } catch {
            apiKeyStatus = "Could not remove saved API key."
        }
    }

    private func repairAPIKeyAccess() {
        guard !isRepairingAPIKeyAccess else { return }
        isRepairingAPIKeyAccess = true
        defer {
            isRepairingAPIKeyAccess = false
            refreshAPIKeyStatus()
            refreshReadinessChecks()
        }

        do {
            try BarnOwlAPIKeyStore.repairSavedAPIKeyAccess()
            apiKeyStatus = "Migrated the saved key to Barn Owl's local user config."
        } catch {
            apiKeyConnectionState = .failed
            apiKeyStatus = "Could not read the older Keychain key. Paste the key again, then choose Save & Test Key."
        }
    }

    @MainActor
    private func testAPIKey() async {
        await validateSavedAPIKey(successMessage: "OpenAI connection works.")
    }

    @MainActor
    private func validateSavedAPIKey(successMessage: String) async {
        guard !isValidatingAPIKey else { return }
        isValidatingAPIKey = true
        apiKeyConnectionState = .testing
        if apiKeyStatus.isEmpty {
            apiKeyStatus = "Testing OpenAI connection..."
        }
        defer {
            isValidatingAPIKey = false
            refreshReadinessChecks()
        }

        do {
            try await validateCurrentConfiguredAPIKey(successMessage: successMessage)
        } catch {
            if Self.isOpenAIAuthenticationFailure(error) {
                BarnOwlAPIKeyStore.invalidateCachedAPIKeyAfterAuthenticationFailure()
                do {
                    try await validateCurrentConfiguredAPIKey(successMessage: successMessage)
                    return
                } catch {
                    apiKeyConnectionState = BarnOwlAPIKeyStore.hasConfiguredAPIKey() ? .failed : .missing
                    apiKeyStatus = apiKeyValidationMessage(for: error)
                }
            } else {
                apiKeyConnectionState = BarnOwlAPIKeyStore.hasConfiguredAPIKey() ? .failed : .missing
                apiKeyStatus = apiKeyValidationMessage(for: error)
            }
        }
    }

    @MainActor
    private func validateCurrentConfiguredAPIKey(successMessage: String) async throws {
        let key = try BarnOwlAPIKeyStore.loadAPIKey()
        try await OpenAIKeyValidationClient(apiKey: key).validate()
        BarnOwlAPIKeyStore.markAPIKeyVerified(key)
        apiKeyConnectionState = .verified
        apiKeyStatus = successMessage
    }

    private func refreshAPIKeyStatus() {
        hasStoredAPIKey = BarnOwlAPIKeyStore.hasConfiguredAPIKey()
        guard hasStoredAPIKey else {
            apiKeyConnectionState = .missing
            return
        }

        switch apiKeyConnectionState {
        case .testing, .failed:
            return
        case .missing, .savedUntested, .verified:
            apiKeyConnectionState = BarnOwlAPIKeyStore.hasVerifiedAPIKey() ? .verified : .savedUntested
        }
    }

    @MainActor
    private func checkForUpdates() async {
        updateSettingsStatus = "Checking GitHub update feed..."
        do {
            let result = try await BarnOwlUpdater.checkAndInstallLatest()
            switch result {
            case .upToDate(let version, let build):
                updateAvailability = .upToDate(version: version, build: build)
                updateSettingsStatus = "Barn Owl is up to date: \(version) (\(build))."
            case .installing(let version, let build):
                updateAvailability = .available(.init(version: version, build: build, notes: nil))
                updateSettingsStatus = "Installing Barn Owl \(version) (\(build)) and restarting."
            }
        } catch {
            updateAvailability = .unavailable(BarnOwlErrorFormatter.message(for: error))
            updateSettingsStatus = "Could not check updates: \(BarnOwlErrorFormatter.message(for: error))"
        }
        refreshReadinessChecks()
    }

    @MainActor
    private func refreshUpdateNotice() async {
        releaseNotesAvailability = .loading
        updateAvailability = await BarnOwlUpdater.checkLatestAvailability()
        releaseNotesAvailability = await BarnOwlUpdater.loadReleaseNotesAvailability()
    }

    private func exportDeveloperDiagnostics() {
        guard !isExportingDeveloperDiagnostics else { return }

        let panel = NSSavePanel()
        panel.title = "Export Barn Owl Developer Diagnostics"
        panel.nameFieldStringValue = BarnOwlDeveloperDiagnosticsExporter.defaultFileName()
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.canCreateDirectories = true

        guard panel.runModal() == .OK, let url = panel.url else {
            developerDiagnosticsStatus = "Diagnostics export canceled."
            return
        }

        isExportingDeveloperDiagnostics = true
        developerDiagnosticsStatus = "Exporting developer diagnostics..."
        Task {
            do {
                let entries = try await BarnOwlDeveloperDiagnosticsExporter
                    .diagnosticsLogStore()
                    .recentEntries(limit: 80)
                let snapshot = await MainActor.run {
                    BarnOwlDeveloperDiagnosticsExporter.makeSnapshot(
                        readinessLines: BarnOwlSettingsReadinessChecks.lines(),
                        diagnosticsEntries: entries
                    )
                }
                let report = BarnOwlDeveloperDiagnosticsExporter.makeReport(snapshot)
                try BarnOwlDeveloperDiagnosticsExporter.export(report, to: url)
                await MainActor.run {
                    developerDiagnosticsStatus = "Exported redacted developer diagnostics."
                    isExportingDeveloperDiagnostics = false
                }
            } catch {
                await MainActor.run {
                    developerDiagnosticsStatus = "Could not export diagnostics: \(BarnOwlErrorFormatter.message(for: error))"
                    isExportingDeveloperDiagnostics = false
                }
            }
        }
    }

    private func installCodexCLI() {
        do {
            _ = try BarnOwlCodexIntegration.installCLI()
            codexIntegrationStatus = "Installed CLI at ~/bin/barnowl."
        } catch {
            codexIntegrationStatus = "Could not install CLI: \(BarnOwlErrorFormatter.message(for: error))"
        }
        Task {
            await refreshCodexIntegration()
        }
    }

    private func installCodexSkill() {
        do {
            _ = try BarnOwlCodexIntegration.installCodexSkill()
            codexIntegrationStatus = "Installed Codex skill at ~/.codex/skills/barnowl."
        } catch {
            codexIntegrationStatus = "Could not install Codex skill: \(BarnOwlErrorFormatter.message(for: error))"
        }
        Task {
            await refreshCodexIntegration()
        }
    }

    private func testCodexCLI() {
        do {
            codexIntegrationStatus = try BarnOwlCodexIntegration.testCLI()
        } catch {
            codexIntegrationStatus = "Could not run CLI: \(BarnOwlErrorFormatter.message(for: error))"
        }
        Task {
            await refreshCodexIntegration()
        }
    }

    @MainActor
    private func refreshCodexIntegration() async {
        codexBridgeStatus = await BarnOwlCodexIntegration.bridgeStatus()
        codexIntegrationLines = BarnOwlCodexIntegration.snapshot(bridgeStatus: codexBridgeStatus).lines
    }

    @MainActor
    private func refreshContextLibrary() async {
        isRefreshingContextLibrary = true
        defer { isRefreshingContextLibrary = false }

        do {
            let database = try BarnOwlDatabase(url: try BarnOwlAppModel.defaultDatabaseURL())
            let entities = try await database.contextEntities(limit: 500)
            var entries: [ContextLibraryEntry] = []
            entries.reserveCapacity(entities.count)

            for entity in entities {
                let aliases = try await database.contextEntityAliases(entityID: entity.id)
                    .map(\.alias)
                entries.append(ContextLibraryEntry(
                    id: entity.id,
                    kind: entity.kind,
                    canonicalName: entity.canonicalName,
                    aliases: aliases,
                    confidence: entity.confidence,
                    isConfirmed: entity.isConfirmed,
                    createdAt: entity.createdAt,
                    updatedAt: entity.updatedAt
                ))
            }

            contextLibraryEntries = entries
        } catch {
            contextLibraryStatus = "Could not load Context Library: \(BarnOwlErrorFormatter.message(for: error))"
        }
    }

    @MainActor
    private func refreshEnrichmentSources() async {
        guard !isRefreshingEnrichmentSources else { return }
        isRefreshingEnrichmentSources = true
        defer { isRefreshingEnrichmentSources = false }

        do {
            let database = try BarnOwlDatabase(url: try BarnOwlAppModel.defaultDatabaseURL())
            let ownerID = BarnOwlEnrichmentSourceOwner.localUserID()
            enrichmentSources = try await database.enrichmentSources(ownerID: ownerID)
            enrichmentSourceUsefulnessByID = Dictionary(
                uniqueKeysWithValues: try await database.enrichmentSourceUsefulness(ownerID: ownerID)
                    .map { ($0.sourceID, $0) }
            )
            enrichmentAuthorityProfiles = try await database.enrichmentAuthorityProfiles(ownerID: ownerID)
            enrichmentPolicyPacks = try await database.enrichmentPolicyPacks(ownerID: ownerID)
            let recentJobs = try await database.enrichmentJobs(ownerID: ownerID, limit: 12)
            var conceptHistories: [BarnOwlControlEnrichmentConceptHistory] = []
            var seenConcepts: Set<String> = []
            for job in recentJobs {
                guard BarnOwlAppModel.shouldDisplayRecentRecurringConceptMemory(job.conceptKey) else {
                    continue
                }
                let normalizedConcept = job.conceptKey.lowercased()
                guard !seenConcepts.contains(normalizedConcept) else { continue }
                seenConcepts.insert(normalizedConcept)
                let jobsForConcept = try await database.enrichmentJobs(
                    ownerID: ownerID,
                    conceptKey: job.conceptKey,
                    limit: 50
                )
                var negativeEvidenceItems = 0
                var hasResolvedSemanticEvidence = false
                for conceptJob in jobsForConcept {
                    let evidence = try await database.enrichmentJobEvidence(jobID: conceptJob.id)
                        .compactMap(\.evidence)
                    negativeEvidenceItems += evidence
                        .filter(\.negativeEvidence)
                        .count
                    hasResolvedSemanticEvidence = hasResolvedSemanticEvidence || evidence.contains {
                        !$0.negativeEvidence
                            && !$0.contradiction
                            && $0.candidateKind != "unresolved_concept"
                    }
                }
                let supportedJobs = jobsForConcept.filter { $0.status == .supportedCandidate }.count
                let conflictingJobs = jobsForConcept.filter { $0.status == .heldConflictingEvidence }.count
                let history = BarnOwlEnrichmentConceptHistory(
                    supportedCandidateJobs: supportedJobs,
                    conflictingJobs: conflictingJobs,
                    negativeEvidenceItems: negativeEvidenceItems
                )
                guard BarnOwlAppModel.shouldDisplayRecentRecurringConceptMemory(
                    job.conceptKey,
                    history: history,
                    hasResolvedSemanticEvidence: hasResolvedSemanticEvidence
                ) else {
                    continue
                }
                conceptHistories.append(BarnOwlControlEnrichmentConceptHistory(
                    conceptKey: job.conceptKey,
                    supportedCandidateJobs: history.supportedCandidateJobs,
                    conflictingJobs: history.conflictingJobs,
                    negativeEvidenceItems: history.negativeEvidenceItems,
                    requiresConflictMemoryHold: history.requiresConflictMemoryHold
                ))
            }
            recentEnrichmentConceptHistories = conceptHistories
            enrichmentSourcesStatus = ""
        } catch {
            enrichmentSourcesStatus = "Could not load enrichment sources. \(BarnOwlErrorFormatter.message(for: error))"
        }
    }

    @MainActor
    private func setEnrichmentSourceEnabled(sourceID: String, enabled: Bool) async {
        do {
            let database = try BarnOwlDatabase(url: try BarnOwlAppModel.defaultDatabaseURL())
            let ownerID = BarnOwlEnrichmentSourceOwner.localUserID()
            guard try await database.setEnrichmentSourceEnabled(ownerID: ownerID, id: sourceID, enabled: enabled) != nil else {
                enrichmentSourcesStatus = "Could not find enrichment source \(sourceID)."
                return
            }
            await refreshEnrichmentSources()
            enrichmentSourcesStatus = enabled ? "Enabled \(sourceID)." : "Disabled \(sourceID)."
        } catch {
            enrichmentSourcesStatus = "Could not update enrichment source: \(BarnOwlErrorFormatter.message(for: error))"
        }
    }

    @MainActor
    private func activateEnrichmentPolicyPack(_ policyPackID: String) async {
        do {
            let database = try BarnOwlDatabase(url: try BarnOwlAppModel.defaultDatabaseURL())
            let ownerID = BarnOwlEnrichmentSourceOwner.localUserID()
            guard var pack = try await database.enrichmentPolicyPack(ownerID: ownerID, id: policyPackID) else {
                enrichmentSourcesStatus = "Could not find enrichment policy pack \(policyPackID)."
                return
            }
            pack.active = true
            pack.updatedAt = Date()
            try await database.upsertEnrichmentPolicyPack(pack)
            await refreshEnrichmentSources()
            enrichmentSourcesStatus = "Activated policy pack \(policyPackID)."
        } catch {
            enrichmentSourcesStatus = "Could not activate enrichment policy pack: \(BarnOwlErrorFormatter.message(for: error))"
        }
    }

    private func enrichmentSourceTint(_ status: BarnOwlEnrichmentSourceHealthStatus) -> Color {
        switch status {
        case .ready:
            return BarnOwlSettingsTheme.success
        case .disabled:
            return .secondary
        case .needsAuth, .stale, .partial:
            return BarnOwlSettingsTheme.warning
        case .error:
            return .red
        }
    }

    private func refreshReadinessChecks() {
        let lines = BarnOwlSettingsReadinessChecks.lines()
        readinessChecks = lines
        refreshAPIKeyStatus()
        readinessSnapshot = BarnOwlFirstRunReadiness.currentSnapshot(
            hasConfiguredAPIKey: hasStoredAPIKey,
            hasVerifiedAPIKey: BarnOwlAPIKeyStore.hasVerifiedAPIKey()
        )
    }

    private func handleReadinessAction(_ check: BarnOwlReadinessCheck) {
        switch check.action {
        case .addAPIKey:
            apiKeyStatus = "Paste your OpenAI API key below, then choose Save & Test Key."
        case .testAPIKey:
            if hasStoredAPIKey {
                Task {
                    await testAPIKey()
                }
            } else {
                apiKeyStatus = "Paste your OpenAI API key below, then choose Save & Test Key."
            }
        case .openMicrophoneSettings:
            readinessActionStatus = "Opening macOS Microphone privacy settings."
            openSystemPrivacySettings(anchor: "Privacy_Microphone")
        case .openSystemAudioSettings:
            readinessActionStatus = "Opening macOS Screen & System Audio Recording settings."
            openSystemPrivacySettings(anchor: "Privacy_ScreenCapture")
        case .runCaptureTest:
            Task {
                await runLocalCaptureTest()
            }
        case .revealStorage:
            revealLibraryInFinder()
        case .checkUpdates:
            Task {
                await checkForUpdates()
            }
        case nil:
            break
        }
    }

    private func openSystemPrivacySettings(anchor: String) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") else {
            updateSettingsStatus = "Could not open macOS Privacy settings."
            return
        }
        if !NSWorkspace.shared.open(url) {
            updateSettingsStatus = "Could not open macOS Privacy settings. Open System Settings manually."
        }
    }

    private func openOpenAIAPIKeysPage() {
        guard let url = URL(string: "https://platform.openai.com/api-keys") else {
            apiKeyStatus = "Could not open the OpenAI API keys page."
            return
        }
        if !NSWorkspace.shared.open(url) {
            apiKeyStatus = "Could not open the OpenAI API keys page. Visit platform.openai.com/api-keys manually."
        }
    }

    private func apiKeyValidationMessage(for error: Error) -> String {
        if let configurationError = error as? OpenAIConfigurationError,
           configurationError == .missingAPIKey {
            return "No API key is saved yet. Paste a key, then choose Save & Test Key."
        }

        guard let validationError = error as? OpenAIKeyValidationError else {
            return "Could not test OpenAI connection: \(BarnOwlErrorFormatter.message(for: error))"
        }

        switch validationError {
        case .invalidAPIKey:
            return "OpenAI rejected this key. Check the pasted key or create a new one."
        case .insufficientPermissions:
            return "OpenAI accepted the key, but it does not have enough permissions for Barn Owl."
        case .quotaOrRateLimited:
            return "OpenAI accepted the key, but the project is out of quota, missing billing, or rate limited."
        case .unsuccessfulStatusCode(let statusCode, _):
            return "OpenAI key test failed with status \(statusCode)."
        }
    }

    private static func isOpenAIAuthenticationFailure(_ error: Error) -> Bool {
        switch error {
        case OpenAIKeyValidationError.invalidAPIKey:
            return true
        case OpenAIKeyValidationError.unsuccessfulStatusCode(let statusCode, _):
            return statusCode == 401
        default:
            return false
        }
    }

    private func revealLibraryInFinder() {
        do {
            let url = try BarnOwlMeetingProcessor.defaultLibraryRoot()
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            updateSettingsStatus = "Could not reveal Barn Owl Library: \(BarnOwlErrorFormatter.message(for: error))"
            return
        }
    }

    @MainActor
    private func runLocalCaptureTest() async {
        guard !isRunningCaptureTest else { return }
        isRunningCaptureTest = true
        readinessActionStatus = "Requesting microphone permission..."
        defer {
            isRunningCaptureTest = false
            refreshReadinessChecks()
        }

        let microphoneDecision = await BarnOwlFirstRunReadiness.requestMicrophoneDecision()
        guard microphoneDecision == .granted else {
            BarnOwlFirstRunReadiness.clearLocalCaptureReadiness()
            readinessActionStatus = BarnOwlFirstRunReadiness.microphonePermissionBlockedMessage(for: microphoneDecision)
            return
        }

        let hasSystemAudioEvidence = BarnOwlFirstRunReadiness.hasSystemAudioCaptureEvidence()
        readinessActionStatus = hasSystemAudioEvidence
            ? "Checking system audio readiness..."
            : "Requesting system audio permission..."
        let systemAudioDecision = BarnOwlFirstRunReadiness.requestSystemAudioDecisionIfNeeded()
        readinessActionStatus = systemAudioDecision == .granted
            ? "Running a short local mic/system-audio capture test..."
            : "Running a short local capture test. macOS may ask for Screen & System Audio Recording permission."
        do {
            let result = try await BarnOwlLocalCaptureReadinessTest.run()
            result.applyReadinessMarkers()
            readinessActionStatus = result.summary
        } catch {
            BarnOwlFirstRunReadiness.clearSystemAudioCaptureReadiness()
            readinessActionStatus = "Local capture test failed: \(BarnOwlErrorFormatter.message(for: error))"
        }
    }
}

private enum APIKeyConnectionState {
    case missing
    case savedUntested
    case testing
    case verified
    case failed

    var connectionStatusTitle: String {
        switch self {
        case .missing:
            return "Missing"
        case .savedUntested:
            return "Test needed"
        case .testing:
            return "Testing"
        case .verified:
            return "Connected"
        case .failed:
            return "Needs attention"
        }
    }

    var detail: String {
        switch self {
        case .missing:
            return "No API key saved yet."
        case .savedUntested:
            return "API key saved locally. Test it to finish setup."
        case .testing:
            return "Testing the saved API key with OpenAI."
        case .verified:
            return "API key saved locally and verified with OpenAI."
        case .failed:
            return "API key saved locally, but the last test failed."
        }
    }

    var tint: Color {
        switch self {
        case .verified:
            return BarnOwlSettingsTheme.success
        case .savedUntested, .testing:
            return BarnOwlSettingsTheme.warning
        case .missing, .failed:
            return BarnOwlSettingsTheme.warning
        }
    }

    var detailSystemImage: String {
        switch self {
        case .verified:
            return "checkmark.seal.fill"
        case .testing:
            return "clock.fill"
        case .missing, .savedUntested, .failed:
            return "exclamationmark.triangle.fill"
        }
    }
}

enum BarnOwlSettingsReadinessChecks {
    static func lines(
        apiKeyDiagnostics: () -> [String] = BarnOwlAPIKeyStore.diagnosticLines,
        libraryRoot: () throws -> URL = BarnOwlMeetingProcessor.defaultLibraryRoot,
        contextRoot: () throws -> URL = BarnOwlMeetingProcessor.defaultContextRoot,
        permissionDiagnostics: () -> [String] = { BarnOwlFirstRunReadiness.diagnosticLines() }
    ) -> [String] {
        var checks = apiKeyDiagnostics().map(BarnOwlErrorFormatter.sanitizeForUserDisplay)
        checks.append(contentsOf: permissionDiagnostics().map(BarnOwlErrorFormatter.sanitizeForUserDisplay))

        if (try? libraryRoot()) != nil {
            checks.append("library_storage=writable")
        } else {
            checks.append("library_storage=unavailable")
        }

        if (try? contextRoot()) != nil {
            checks.append("local_context_storage=writable")
        } else {
            checks.append("local_context_storage=unavailable")
        }

        return checks
    }
}

struct BarnOwlLocalCaptureReadinessResult {
    let capturedTrackKinds: Set<AudioTrackKind>

    var capturedMicrophone: Bool {
        capturedTrackKinds.contains(.microphone) || capturedTrackKinds.contains(.mixed)
    }

    var capturedSystemAudio: Bool {
        capturedTrackKinds.contains(.systemAudio) || capturedTrackKinds.contains(.mixed)
    }

    var capturedAllRequiredTracks: Bool {
        capturedMicrophone && capturedSystemAudio
    }

    var summary: String {
        if capturedAllRequiredTracks {
            return "Local capture test passed. Mic and system-audio tracks were captured without uploading audio."
        }

        return "Local capture test captured microphone audio. System audio was not observed during the short test; play audio from another app and rerun to verify call/system audio capture."
    }

    @MainActor
    func applyReadinessMarkers() {
        if capturedAllRequiredTracks {
            BarnOwlFirstRunReadiness.markLocalCaptureTestSucceeded()
            return
        }

        if capturedMicrophone {
            BarnOwlFirstRunReadiness.markCaptureSucceeded(trackKind: .microphone)
        }
        if capturedSystemAudio {
            BarnOwlFirstRunReadiness.markCaptureSucceeded(trackKind: .systemAudio)
        }
    }
}

enum BarnOwlLocalCaptureReadinessTest {
    @MainActor
    static func run(durationNanoseconds: UInt64 = 1_100_000_000) async throws -> BarnOwlLocalCaptureReadinessResult {
        let sessionID = UUID()
        var capturedTrackKinds: Set<AudioTrackKind> = []
        let coordinator = BarnOwlAudioCaptureFactory.makeCoordinator(
            sessionID: sessionID,
            progressHandler: { progress in
                guard progress.errorMessage == nil,
                      progress.byteCount ?? 0 > 0,
                      !capturedTrackKinds.contains(progress.trackKind)
                else {
                    return
                }
                capturedTrackKinds.insert(progress.trackKind)
            }
        )

        do {
            try await coordinator.start(configuration: .defaultMeetingCapture)
            try await Task.sleep(nanoseconds: durationNanoseconds)
            await coordinator.stop()
            let result = BarnOwlLocalCaptureReadinessResult(capturedTrackKinds: capturedTrackKinds)
            if !result.capturedMicrophone {
                throw BarnOwlLocalCaptureReadinessError.missingTracks([.microphone])
            }
            await BarnOwlAudioCaptureFactory.deleteTemporaryAudio(for: sessionID)
            return result
        } catch {
            await coordinator.stop()
            await BarnOwlAudioCaptureFactory.deleteTemporaryAudio(for: sessionID)
            throw error
        }
    }
}

private enum BarnOwlLocalCaptureReadinessError: LocalizedError {
    case missingTracks([AudioTrackKind])

    var errorDescription: String? {
        switch self {
        case .missingTracks(let trackKinds):
            let names = trackKinds.map(Self.displayName(for:)).joined(separator: " and ")
            return "Capture started, but no \(names) audio chunk was written."
        }
    }

    private static func displayName(for trackKind: AudioTrackKind) -> String {
        switch trackKind {
        case .microphone:
            return "microphone"
        case .systemAudio:
            return "system-audio"
        case .mixed:
            return "mixed"
        }
    }
}

private enum BarnOwlSettingsTheme {
    static let background = LinearGradient(
        colors: [
            Color(nsColor: .windowBackgroundColor),
            Color(red: 0.92, green: 0.88, blue: 0.80).opacity(0.22)
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
    static let success = Color(red: 0.22, green: 0.48, blue: 0.36)
    static let warning = Color(red: 0.82, green: 0.45, blue: 0.12)
}

private struct BarnOwlSettingsStatusPill: View {
    var title: String
    var systemImage: String?
    var tint: Color

    var body: some View {
        Label {
            Text(title)
        } icon: {
            if let systemImage {
                Image(systemName: systemImage)
            }
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(tint)
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(tint.opacity(0.12), in: Capsule())
        .overlay {
            Capsule()
                .stroke(tint.opacity(0.18), lineWidth: 1)
        }
    }
}

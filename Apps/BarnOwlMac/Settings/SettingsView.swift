import AppKit
import BarnOwlAudio
import BarnOwlCore
import BarnOwlOpenAI
import BarnOwlPersistence
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @State private var apiKey = ""
    @State private var apiKeyStatus = ""
    @State private var hasStoredAPIKey = false
    @State private var apiKeyConnectionState: APIKeyConnectionState = .missing
    @State private var isValidatingAPIKey = false
    @State private var readinessSnapshot = BarnOwlFirstRunReadiness.placeholderSnapshot
    @State private var readinessChecks: [String] = []
    @State private var updateManifestURL = ""
    @State private var updateSettingsStatus = ""
    @State private var codexBridgeStatus = "checking"
    @State private var codexIntegrationLines: [String] = []
    @State private var codexIntegrationStatus = ""
    @State private var isRunningCaptureTest = false
    @State private var isRepairingAPIKeyAccess = false
    @State private var showReadinessDiagnostics = false
    @State private var developerDiagnosticsStatus = ""
    @State private var isExportingDeveloperDiagnostics = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                tldrSection
                onboardingReadinessSection
                openAISection
                codexIntegrationSection
                updaterSection
                developerDiagnosticsSection
                readinessSection
            }
            .padding(20)
        }
        .background(BarnOwlSettingsTheme.background)
        .frame(minWidth: 560, idealWidth: 640, maxWidth: 720)
        .frame(minHeight: 560)
        .onAppear {
            refreshAPIKeyStatus()
            refreshUpdaterSettings()
            refreshReadinessChecks()
            Task {
                await refreshCodexIntegration()
            }
        }
    }

    private var onboardingReadinessSection: some View {
        BarnOwlReadinessOnboardingView(
            snapshot: readinessSnapshot,
            actionHandler: handleReadinessAction
        )
    }

    private var header: some View {
        HStack(spacing: 12) {
            BarnOwlMark(status: readinessSnapshot.criticalReady ? .idle : .failed, headTurn: 0.2)
                .frame(width: 46, height: 46)

            VStack(alignment: .leading, spacing: 3) {
                Text("Barn Owl Settings")
                    .font(.title3.weight(.semibold))
                Text("Local-first setup for fast, quiet recording.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            BarnOwlSettingsStatusPill(
                title: readinessSnapshot.criticalReady ? "Ready" : "Setup needed",
                systemImage: readinessSnapshot.criticalReady ? "checkmark.circle.fill" : "exclamationmark.triangle.fill",
                tint: readinessSnapshot.criticalReady ? BarnOwlSettingsTheme.success : BarnOwlSettingsTheme.warning
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

                Text("Each macOS user adds their own OpenAI API key. Barn Owl stores it in Keychain and keeps it out of the app bundle.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                SecureField("OpenAI API key", text: $apiKey)
                    .textFieldStyle(.roundedBorder)

                ViewThatFits(in: .horizontal) {
                    HStack {
                        keyButtons
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        keyButtons
                    }
                }

                if !apiKeyStatus.isEmpty {
                    settingsStatusMessage(apiKeyStatus)
                }

                Text("Need a key? Create one in the OpenAI dashboard, paste it here, then Save & Test. If macOS keeps asking for Keychain access, use Repair Keychain Access from this section.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var tldrSection: some View {
        settingsCard {
            VStack(alignment: .leading, spacing: 12) {
                settingsSectionHeader("TLDR", systemImage: "sparkles")

                VStack(alignment: .leading, spacing: 9) {
                    settingsTLDRLine(
                        title: "Codex + CLI",
                        detail: "Use `barnowl` and the bundled `$barnowl` skill as the primary control path: start, stop, wait, attach context, retry jobs, and retrieve notes without opening the UI."
                    )
                    settingsTLDRLine(
                        title: "Mac app",
                        detail: "Keep the app for first-run setup, permissions, API key entry, bridge status, and occasional manual review."
                    )
                    settingsTLDRLine(
                        title: "Workflow",
                        detail: "`barnowl start`, `barnowl context add`, `barnowl stop`, `barnowl wait`, then `barnowl meeting notes <id> --format markdown`."
                    )
                    settingsTLDRLine(
                        title: "Codex skill",
                        detail: "Install `$barnowl` so Codex starts recording immediately when asked and recovers failed processing with job commands when needed."
                    )
                }

                Text("Everything is local-first: your app data, SQLite library, Markdown exports, CLI bridge, and Codex skill live on this Mac.")
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

            Button("Repair Keychain Access") {
                repairAPIKeyAccess()
            }
            .buttonStyle(.bordered)
            .disabled(isValidatingAPIKey || isRepairingAPIKeyAccess)

            Button("Create API Key") {
                openOpenAIAPIKeysPage()
            }
            .buttonStyle(.borderless)
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

    private var updaterSection: some View {
        settingsCard {
            VStack(alignment: .leading, spacing: 12) {
                settingsSectionHeader(
                    "Updates",
                    systemImage: "arrow.down.app",
                    status: BarnOwlUpdaterSettings.updateChannelLabel,
                    tint: BarnOwlSettingsTheme.success
                )

                Text("Barn Owl checks a local or HTTPS update manifest on launch, periodically while idle, and when you ask. This can point at a Git-hosted manifest or a manifest sent with an ad-hoc app build.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Text("Current feed: \(BarnOwlUpdaterSettings.updateChannelLabel)")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .textSelection(.enabled)
                    .lineLimit(2)

                TextField("Optional HTTPS update feed or local manifest path", text: $updateManifestURL)
                    .textFieldStyle(.roundedBorder)

                ViewThatFits(in: .horizontal) {
                    HStack {
                        updaterButtons
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        updaterButtons
                    }
                }

                if !updateSettingsStatus.isEmpty {
                    settingsStatusMessage(updateSettingsStatus)
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

                Text("Install the local CLI and bundled `$barnowl` skill so Codex is the day-to-day interface. The app stays here for setup, permissions, API key entry, bridge checks, and manual review.")
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

                Text("Example prompt: Use $barnowl to record this meeting. Codex should start immediately, attach context, stop on request, wait for processing, then fetch Markdown notes.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .textSelection(.enabled)

                if !codexIntegrationStatus.isEmpty {
                    settingsStatusMessage(codexIntegrationStatus)
                }
            }
        }
    }

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

    private var updaterButtons: some View {
        Group {
            Button("Save Update Feed") {
                saveUpdaterSettings()
            }
            .buttonStyle(.borderedProminent)

            Button("Use Local Default") {
                updateManifestURL = ""
                saveUpdaterSettings()
            }
            .buttonStyle(.bordered)

            Button("Check & Install") {
                Task {
                    await checkForUpdates()
                }
            }
            .buttonStyle(.bordered)
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
            apiKeyStatus = "Saved to macOS Keychain. Testing OpenAI connection..."
            apiKeyConnectionState = .testing
            refreshAPIKeyStatus()
            refreshReadinessChecks()
            Task {
                await validateSavedAPIKey(successMessage: "Saved and tested. OpenAI authentication works.")
            }
        } catch {
            apiKeyStatus = "Could not save API key to macOS Keychain."
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
            apiKeyStatus = "Re-saved the key to Barn Owl's current Keychain storage. If macOS asks, choose Always Allow once."
        } catch {
            apiKeyConnectionState = .failed
            apiKeyStatus = "Could not repair Keychain access. Paste the key again, then choose Save & Test Key."
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

    private func refreshUpdaterSettings() {
        updateManifestURL = BarnOwlUpdaterSettings.manifestURLString
    }

    private func saveUpdaterSettings() {
        BarnOwlUpdaterSettings.manifestURLString = updateManifestURL
        refreshUpdaterSettings()
        if updateManifestURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            updateSettingsStatus = "Using local development manifest."
        } else {
            updateSettingsStatus = "Saved update manifest URL."
        }
        refreshReadinessChecks()
    }

    @MainActor
    private func checkForUpdates() async {
        updateSettingsStatus = "Checking \(BarnOwlUpdaterSettings.updateChannelLabel.lowercased())..."
        do {
            let result = try await BarnOwlUpdater.checkAndInstallLatest()
            switch result {
            case .upToDate(let version, let build):
                updateSettingsStatus = "Barn Owl is up to date: \(version) (\(build))."
            case .installing(let version, let build):
                updateSettingsStatus = "Installing Barn Owl \(version) (\(build)) and restarting."
            }
        } catch {
            updateSettingsStatus = "Could not check updates: \(BarnOwlErrorFormatter.message(for: error))"
        }
        refreshReadinessChecks()
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
            openSystemPrivacySettings(anchor: "Privacy_Microphone")
        case .openSystemAudioSettings:
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
        updateSettingsStatus = "Running a short local capture test..."
        defer {
            isRunningCaptureTest = false
            refreshReadinessChecks()
        }

        do {
            let summary = try await BarnOwlLocalCaptureReadinessTest.run()
            BarnOwlFirstRunReadiness.markLocalCaptureTestSucceeded()
            updateSettingsStatus = summary
        } catch {
            BarnOwlFirstRunReadiness.clearLocalCaptureReadiness()
            updateSettingsStatus = "Local capture test failed: \(BarnOwlErrorFormatter.message(for: error))"
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
            return "API key saved in macOS Keychain. Test it to finish setup."
        case .testing:
            return "Testing the saved API key with OpenAI."
        case .verified:
            return "API key saved in macOS Keychain and verified with OpenAI."
        case .failed:
            return "API key saved in macOS Keychain, but the last test failed."
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

enum BarnOwlLocalCaptureReadinessTest {
    @MainActor
    static func run(durationNanoseconds: UInt64 = 1_100_000_000) async throws -> String {
        let sessionID = UUID()
        var capturedTrackKinds: [AudioTrackKind] = []
        let coordinator = BarnOwlAudioCaptureFactory.makeCoordinator(
            sessionID: sessionID,
            progressHandler: { progress in
                guard progress.errorMessage == nil,
                      progress.byteCount ?? 0 > 0,
                      !capturedTrackKinds.contains(progress.trackKind)
                else {
                    return
                }
                capturedTrackKinds.append(progress.trackKind)
            }
        )

        do {
            try await coordinator.start(configuration: .defaultMeetingCapture)
            try await Task.sleep(nanoseconds: durationNanoseconds)
            await coordinator.stop()
            let missingTrackKinds = [AudioTrackKind.microphone, .systemAudio]
                .filter { !capturedTrackKinds.contains($0) }
            if !missingTrackKinds.isEmpty {
                throw BarnOwlLocalCaptureReadinessError.missingTracks(missingTrackKinds)
            }
            await BarnOwlAudioCaptureFactory.deleteTemporaryAudio(for: sessionID)
            return "Local capture test passed. Mic and system-audio tracks were captured without uploading audio."
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

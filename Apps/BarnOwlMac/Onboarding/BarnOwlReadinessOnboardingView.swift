import AVFoundation
import BarnOwlAudio
import BarnOwlCore
import CoreGraphics
import SwiftUI

struct BarnOwlReadinessOnboardingView: View {
    @Environment(\.colorScheme) private var colorScheme

    var snapshot: BarnOwlReadinessSnapshot
    var actionHandler: (BarnOwlReadinessCheck) -> Void = { _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            LazyVGrid(columns: columns, alignment: .leading, spacing: 10) {
                ForEach(snapshot.checks) { check in
                    BarnOwlReadinessTile(check: check) {
                        actionHandler(check)
                    }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(readinessBackground, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(BarnOwlDesign.amber.opacity(0.18), lineWidth: 1)
        }
        .shadow(color: BarnOwlDesign.softShadow, radius: 8, y: 3)
        .accessibilityElement(children: .contain)
    }

    private var header: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 10) {
                readinessTitle
                Spacer(minLength: 8)
                BarnOwlReadinessPill(state: snapshot.criticalReady ? .ready : .missing)
            }

            VStack(alignment: .leading, spacing: 8) {
                readinessTitle
                BarnOwlReadinessPill(state: snapshot.criticalReady ? .ready : .missing)
            }
        }
    }

    private var readinessTitle: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("First-Run Readiness")
                .font(.headline)
            Text(snapshot.summary)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var columns: [GridItem] {
        [
            GridItem(.adaptive(minimum: 220), spacing: 10, alignment: .topLeading)
        ]
    }

    private var readinessBackground: some ShapeStyle {
        if colorScheme == .dark {
            LinearGradient(
                colors: [
                    Color(nsColor: .controlBackgroundColor).opacity(0.98),
                    Color(nsColor: .windowBackgroundColor).opacity(0.98),
                    BarnOwlDesign.amber.opacity(0.06)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        } else {
            LinearGradient(
                colors: [
                    BarnOwlDesign.cream.opacity(0.72),
                    Color(nsColor: .controlBackgroundColor).opacity(0.88),
                    BarnOwlDesign.amber.opacity(0.10)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
    }
}

private struct BarnOwlReadinessTile: View {
    @Environment(\.colorScheme) private var colorScheme

    var check: BarnOwlReadinessCheck
    var action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            tileHeader

            Spacer(minLength: 8)

            HStack {
                BarnOwlReadinessPill(state: check.state)
                Spacer(minLength: 6)
                if let actionTitle = check.actionTitle {
                    Button(actionTitle) {
                        action()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .font(.caption.weight(.semibold))
                    .help(actionTitle)
                }
            }
        }
        .padding(11)
        .frame(maxWidth: .infinity, minHeight: 136, alignment: .topLeading)
        .background(tileBackground, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(check.state.tint.opacity(check.state == .missing ? 0.32 : 0.14), lineWidth: 1)
        }
    }

    private var tileHeader: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: check.systemImage)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(check.state.tint)
                .frame(width: 26, height: 26)
                .background(check.state.tint.opacity(0.13), in: RoundedRectangle(cornerRadius: 7, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                Text(check.title)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(check.detail)
                    .font(.caption)
                    .foregroundStyle(colorScheme == .dark ? Color.primary.opacity(0.74) : Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .lineLimit(4)
            }

            Spacer(minLength: 0)
        }
    }

    private var tileBackground: Color {
        colorScheme == .dark
            ? Color.white.opacity(0.055)
            : Color(nsColor: .textBackgroundColor).opacity(0.70)
    }
}

private struct BarnOwlReadinessPill: View {
    @Environment(\.colorScheme) private var colorScheme

    var state: BarnOwlReadinessState

    var body: some View {
        Text(state.title)
            .font(.caption2.monospaced().weight(.bold))
            .foregroundStyle(state.foreground(for: colorScheme))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(state.background(for: colorScheme), in: Capsule())
            .overlay {
                Capsule()
                    .stroke(state.tint.opacity(0.24), lineWidth: 1)
            }
            .accessibilityLabel(state.accessibilityLabel)
    }
}

struct BarnOwlReadinessCheck: Identifiable, Equatable {
    enum ID: String, CaseIterable {
        case apiKey
        case microphone
        case systemAudio
        case testRecording
        case storage
        case updateChannel
    }

    var id: ID
    var title: String
    var detail: String
    var systemImage: String
    var state: BarnOwlReadinessState
    var actionTitle: String?
    var action: BarnOwlReadinessAction? = nil
}

enum BarnOwlReadinessAction: Equatable {
    case addAPIKey
    case testAPIKey
    case openMicrophoneSettings
    case openSystemAudioSettings
    case runCaptureTest
    case revealStorage
    case checkUpdates
}

struct BarnOwlReadinessSnapshot: Equatable {
    var checks: [BarnOwlReadinessCheck]

    var criticalReady: Bool {
        requiredChecks.allSatisfy { $0.state == .ready }
    }

    var menuBarSetupNeeded: Bool {
        menuBarBlockingChecks.contains { $0.state != .ready }
    }

    var allReady: Bool {
        checks.allSatisfy { $0.state == .ready }
    }

    var summary: String {
        if criticalReady && allReady {
            return "Barn Owl is ready to record, transcribe, save notes, and check for updates."
        }
        if criticalReady {
            return "Recording is ready. A couple of optional setup checks can still be finished."
        }
        return "Finish the missing setup items before the first real meeting."
    }

    private var requiredChecks: [BarnOwlReadinessCheck] {
        checks.filter { [.apiKey, .microphone, .systemAudio, .storage].contains($0.id) }
    }

    private var menuBarBlockingChecks: [BarnOwlReadinessCheck] {
        requiredChecks
    }
}

enum BarnOwlReadinessState: String, Equatable {
    case ready
    case warning
    case missing

    var title: String {
        switch self {
        case .ready:
            "READY"
        case .warning:
            "WARNING"
        case .missing:
            "MISSING"
        }
    }

    var tint: Color {
        switch self {
        case .ready:
            BarnOwlDesign.moss
        case .warning:
            BarnOwlDesign.amber
        case .missing:
            Color(red: 0.82, green: 0.36, blue: 0.18)
        }
    }

    var foreground: Color {
        switch self {
        case .ready:
            Color(red: 0.12, green: 0.26, blue: 0.18)
        case .warning:
            Color(red: 0.32, green: 0.18, blue: 0.08)
        case .missing:
            Color(red: 0.42, green: 0.12, blue: 0.04)
        }
    }

    var background: Color {
        tint.opacity(0.16)
    }

    func foreground(for colorScheme: ColorScheme) -> Color {
        guard colorScheme == .dark else { return foreground }
        switch self {
        case .ready:
            return Color(red: 0.57, green: 0.86, blue: 0.68)
        case .warning:
            return Color(red: 1.0, green: 0.67, blue: 0.25)
        case .missing:
            return Color(red: 1.0, green: 0.49, blue: 0.32)
        }
    }

    func background(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark ? tint.opacity(0.18) : background
    }

    var accessibilityLabel: String {
        switch self {
        case .ready:
            "Ready"
        case .warning:
            "Warning"
        case .missing:
            "Missing"
        }
    }
}

@MainActor
enum BarnOwlFirstRunReadiness {
    nonisolated static let testRecordingSucceededDefaultsKey = "BarnOwlReadinessTestRecordingSucceeded"
    nonisolated static let microphoneCaptureSucceededDefaultsKey = "BarnOwlReadinessMicrophoneCaptureSucceeded"
    nonisolated static let systemAudioCaptureSucceededDefaultsKey = "BarnOwlReadinessSystemAudioCaptureSucceeded"

    static var placeholderSnapshot: BarnOwlReadinessSnapshot {
        snapshot(
            apiKeyConfigured: false,
            apiKeyVerified: false,
            microphoneDecision: .unknown,
            systemAudioDecision: .unknown,
            testRecordingSucceeded: false,
            storageAvailable: false,
            storagePath: nil,
            updateChannelConfigured: false
        )
    }

    static func currentSnapshot(
        hasConfiguredAPIKey: Bool = BarnOwlAPIKeyStore.hasConfiguredAPIKey(),
        hasVerifiedAPIKey: Bool = BarnOwlAPIKeyStore.hasVerifiedAPIKey(),
        testRecordingSucceeded: Bool = UserDefaults.standard.bool(forKey: testRecordingSucceededDefaultsKey),
        microphoneCaptureSucceeded: Bool = UserDefaults.standard.bool(forKey: microphoneCaptureSucceededDefaultsKey),
        systemAudioCaptureSucceeded: Bool = UserDefaults.standard.bool(forKey: systemAudioCaptureSucceededDefaultsKey),
        microphoneDecision: CapturePermissionDecision? = nil,
        systemAudioDecision: CapturePermissionDecision? = nil
    ) -> BarnOwlReadinessSnapshot {
        let storageCheck = currentStorageCheck()
        let microphonePreviouslySucceeded = testRecordingSucceeded || microphoneCaptureSucceeded
        let systemAudioPreviouslySucceeded = testRecordingSucceeded || systemAudioCaptureSucceeded
        let resolvedMicrophoneDecision = microphoneDecision ?? currentMicrophoneDecision()
        let resolvedSystemAudioDecision = systemAudioDecision ?? currentSystemAudioDecision()

        return snapshot(
            apiKeyConfigured: hasConfiguredAPIKey,
            apiKeyVerified: hasVerifiedAPIKey,
            microphoneDecision: effectivePermissionDecision(
                resolvedMicrophoneDecision,
                captureSucceeded: microphonePreviouslySucceeded
            ),
            systemAudioDecision: effectiveSystemAudioPermissionDecision(
                resolvedSystemAudioDecision,
                captureSucceeded: systemAudioPreviouslySucceeded
            ),
            testRecordingSucceeded: testRecordingSucceeded,
            storageAvailable: storageCheck.available,
            storagePath: storageCheck.path,
            updateChannelConfigured: currentUpdateChannelConfigured()
        )
    }

    static func snapshot(
        apiKeyConfigured: Bool,
        apiKeyVerified: Bool,
        microphoneDecision: CapturePermissionDecision,
        systemAudioDecision: CapturePermissionDecision,
        testRecordingSucceeded: Bool,
        storageAvailable: Bool,
        storagePath: String?,
        updateChannelConfigured: Bool
    ) -> BarnOwlReadinessSnapshot {
        let storageDescription = storagePath == nil
            ? "Barn Owl could not resolve or write to the library location."
            : "Barn Owl can write to its local library."

        return BarnOwlReadinessSnapshot(checks: [
            BarnOwlReadinessCheck(
                id: .apiKey,
                title: "API Key",
                detail: apiKeyDetail(configured: apiKeyConfigured, verified: apiKeyVerified),
                systemImage: "key.horizontal.fill",
                state: apiKeyState(configured: apiKeyConfigured, verified: apiKeyVerified),
                actionTitle: apiKeyConfigured ? "Test Key" : "Add Key Below",
                action: apiKeyConfigured ? .testAPIKey : .addAPIKey
            ),
            BarnOwlReadinessCheck(
                id: .microphone,
                title: "Microphone Permission",
                detail: microphoneDetail(for: microphoneDecision),
                systemImage: "mic.fill",
                state: permissionState(for: microphoneDecision),
                actionTitle: permissionActionTitle(for: microphoneDecision),
                action: microphoneAction(for: microphoneDecision)
            ),
            BarnOwlReadinessCheck(
                id: .systemAudio,
                title: "System Audio Permission",
                detail: systemAudioDetail(for: systemAudioDecision),
                systemImage: "speaker.wave.2.fill",
                state: permissionState(for: systemAudioDecision),
                actionTitle: permissionActionTitle(for: systemAudioDecision),
                action: systemAudioAction(for: systemAudioDecision)
            ),
            BarnOwlReadinessCheck(
                id: .testRecording,
                title: "Local Capture Test",
                detail: testRecordingSucceeded
                    ? "A short local mic/system-audio capture test produced both audio tracks. Nothing was uploaded."
                    : "Run a short local capture test to confirm both audio tracks before a real meeting. Nothing is uploaded.",
                systemImage: "waveform.path.ecg",
                state: testRecordingSucceeded ? .ready : .warning,
                actionTitle: testRecordingSucceeded ? "Run Again" : "Run Test",
                action: .runCaptureTest
            ),
            BarnOwlReadinessCheck(
                id: .storage,
                title: "Storage Location",
                detail: storageDescription,
                systemImage: "externaldrive.fill",
                state: storageAvailable ? .ready : .warning,
                actionTitle: storageAvailable ? "Reveal" : nil,
                action: storageAvailable ? .revealStorage : nil
            ),
            BarnOwlReadinessCheck(
                id: .updateChannel,
                title: "Update Channel",
                detail: updateChannelConfigured
                    ? "An update manifest is configured."
                    : "No update manifest is configured yet. Recording still works, but updates need Settings.",
                systemImage: "arrow.down.app.fill",
                state: updateChannelConfigured ? .ready : .warning,
                actionTitle: "Check Updates",
                action: .checkUpdates
            )
        ])
    }

    private static func apiKeyState(
        configured: Bool,
        verified: Bool
    ) -> BarnOwlReadinessState {
        if verified {
            return .ready
        }
        return configured ? .warning : .missing
    }

    private static func apiKeyDetail(
        configured: Bool,
        verified: Bool
    ) -> String {
        if verified {
            return "A local OpenAI API key is saved and verified for this macOS user."
        }
        if configured {
            return "A local OpenAI API key is saved, but it needs a successful test before Barn Owl treats setup as ready."
        }
        return "Add and test an OpenAI API key before recording. The app bundle never ships with your key."
    }

    private static func currentMicrophoneDecision() -> CapturePermissionDecision {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return .granted
        case .notDetermined:
            return .notDetermined
        case .denied:
            return .denied
        case .restricted:
            return .restricted
        @unknown default:
            return .unknown
        }
    }

    static func requestMicrophoneDecision() async -> CapturePermissionDecision {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return .granted
        case .notDetermined:
            let granted = await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    continuation.resume(returning: granted)
                }
            }
            return granted ? .granted : currentMicrophoneDecision()
        case .denied:
            return .denied
        case .restricted:
            return .restricted
        @unknown default:
            return .unknown
        }
    }

    nonisolated static func microphonePermissionBlockedMessage(
        for decision: CapturePermissionDecision
    ) -> String {
        switch decision {
        case .denied:
            return "Microphone access is denied in macOS. Open System Settings > Privacy & Security > Microphone, allow Barn Owl, then retry. macOS will not show another prompt until access is granted or reset."
        case .restricted:
            return "Microphone access is restricted by macOS policy. Allow Barn Owl in Privacy & Security before recording."
        case .notDetermined:
            return "Barn Owl requested microphone access, but macOS has not returned a permission decision yet. Retry the local capture test."
        default:
            return "Barn Owl needs Microphone and Screen/System Audio Recording permissions before recording."
        }
    }

    nonisolated static func microphonePermissionRecoveryCommand(
        for decision: CapturePermissionDecision
    ) -> String {
        switch decision {
        case .denied, .restricted:
            return "Open System Settings > Privacy & Security > Microphone, allow Barn Owl, then rerun `barnowl permissions test`."
        default:
            return "Rerun `barnowl permissions test`."
        }
    }

    nonisolated static func diagnosticLines(
        userDefaults: UserDefaults = .standard
    ) -> [String] {
        let microphoneStatus: String
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            microphoneStatus = "authorized"
        case .notDetermined:
            microphoneStatus = "not_determined"
        case .denied:
            microphoneStatus = "denied"
        case .restricted:
            microphoneStatus = "restricted"
        @unknown default:
            microphoneStatus = "unknown"
        }

        let systemAudioPreflight: String
        if #available(macOS 14.2, *) {
            systemAudioPreflight = CGPreflightScreenCaptureAccess() ? "true" : "false"
        } else {
            systemAudioPreflight = "unavailable"
        }

        return [
            "microphone_authorization=\(microphoneStatus)",
            "system_audio_screen_capture_preflight=\(systemAudioPreflight)",
            "local_capture_test_succeeded=\(userDefaults.bool(forKey: testRecordingSucceededDefaultsKey))",
            "microphone_capture_succeeded=\(userDefaults.bool(forKey: microphoneCaptureSucceededDefaultsKey))",
            "system_audio_capture_succeeded=\(userDefaults.bool(forKey: systemAudioCaptureSucceededDefaultsKey))"
        ]
    }

    static func currentRecordingPermissionSet(
        userDefaults: UserDefaults = .standard
    ) -> RecordingPermissionSet {
        let microphoneDecision = effectivePermissionDecision(
            currentMicrophoneDecision(),
            captureSucceeded: userDefaults.bool(forKey: microphoneCaptureSucceededDefaultsKey)
        )
        let systemAudioDecision = effectiveSystemAudioPermissionDecision(
            currentSystemAudioDecision(),
            captureSucceeded: userDefaults.bool(forKey: systemAudioCaptureSucceededDefaultsKey)
        )

        return RecordingPermissionSet(
            microphone: CapturePermissionState(kind: .microphone, decision: microphoneDecision),
            systemAudio: CapturePermissionState(kind: .systemAudioScreenCapture, decision: systemAudioDecision)
        )
    }

    static func markCaptureSucceeded(trackKind: AudioTrackKind) {
        switch trackKind {
        case .microphone:
            UserDefaults.standard.set(true, forKey: microphoneCaptureSucceededDefaultsKey)
        case .systemAudio:
            UserDefaults.standard.set(true, forKey: systemAudioCaptureSucceededDefaultsKey)
        case .mixed:
            UserDefaults.standard.set(true, forKey: microphoneCaptureSucceededDefaultsKey)
            UserDefaults.standard.set(true, forKey: systemAudioCaptureSucceededDefaultsKey)
        }
    }

    static func markLocalCaptureTestSucceeded() {
        UserDefaults.standard.set(true, forKey: testRecordingSucceededDefaultsKey)
        UserDefaults.standard.set(true, forKey: microphoneCaptureSucceededDefaultsKey)
        UserDefaults.standard.set(true, forKey: systemAudioCaptureSucceededDefaultsKey)
    }

    static func clearLocalCaptureReadiness() {
        UserDefaults.standard.set(false, forKey: testRecordingSucceededDefaultsKey)
        UserDefaults.standard.set(false, forKey: microphoneCaptureSucceededDefaultsKey)
        UserDefaults.standard.set(false, forKey: systemAudioCaptureSucceededDefaultsKey)
    }

    private static func effectivePermissionDecision(
        _ decision: CapturePermissionDecision,
        captureSucceeded: Bool
    ) -> CapturePermissionDecision {
        guard captureSucceeded else { return decision }

        switch decision {
        case .granted, .unknown, .checking, .requesting:
            return .granted
        case .notDetermined, .denied, .restricted, .unavailable:
            return decision
        }
    }

    private static func effectiveSystemAudioPermissionDecision(
        _ decision: CapturePermissionDecision,
        captureSucceeded: Bool
    ) -> CapturePermissionDecision {
        guard captureSucceeded else { return decision }

        switch decision {
        case .unavailable:
            return .unavailable
        case .granted, .unknown, .checking, .requesting, .notDetermined, .denied, .restricted:
            return .granted
        }
    }

    private static func currentSystemAudioDecision() -> CapturePermissionDecision {
        guard #available(macOS 14.2, *) else {
            return .unavailable
        }
        if CGPreflightScreenCaptureAccess() {
            return .granted
        }
        return .notDetermined
    }

    private static func currentStorageCheck() -> (available: Bool, path: String?) {
        guard let libraryRoot = try? BarnOwlMeetingProcessor.defaultLibraryRoot() else {
            return (false, nil)
        }

        do {
            try FileManager.default.createDirectory(at: libraryRoot, withIntermediateDirectories: true)
            let probe = libraryRoot.appending(path: ".barnowl-readiness", directoryHint: .notDirectory)
            try "ok".write(to: probe, atomically: true, encoding: .utf8)
            try? FileManager.default.removeItem(at: probe)
            return (true, libraryRoot.path(percentEncoded: false))
        } catch {
            return (false, libraryRoot.path(percentEncoded: false))
        }
    }

    private static func currentUpdateChannelConfigured() -> Bool {
        (try? BarnOwlUpdaterSettings.resolvedManifestURL()) != nil
    }

    private static func permissionState(for decision: CapturePermissionDecision) -> BarnOwlReadinessState {
        switch decision {
        case .granted:
            return .ready
        case .denied, .restricted, .notDetermined:
            return .missing
        case .unavailable, .unknown, .checking, .requesting:
            return .warning
        }
    }

    private static func microphoneDetail(for decision: CapturePermissionDecision) -> String {
        switch decision {
        case .granted:
            return "macOS has granted microphone access."
        case .notDetermined:
            return "Run the local capture test to trigger the macOS microphone prompt."
        case .denied, .restricted:
            return "Microphone access is blocked in macOS privacy settings."
        default:
            return "Microphone permission could not be confirmed."
        }
    }

    private static func systemAudioDetail(for decision: CapturePermissionDecision) -> String {
        switch decision {
        case .granted:
            return "System audio capture is ready. Barn Owl records audio only, not screen contents."
        case .notDetermined:
            return "Run the local capture test to trigger Screen & System Audio Recording permission. Barn Owl uses it for audio only."
        case .denied, .restricted:
            return "System audio capture is blocked in macOS privacy settings."
        case .unavailable:
            return "This macOS version does not expose the Core Audio tap path Barn Owl uses for system audio."
        default:
            return "System audio permission could not be confirmed."
        }
    }

    private static func permissionActionTitle(for decision: CapturePermissionDecision) -> String? {
        switch decision {
        case .granted, .unavailable:
            return nil
        case .denied, .restricted:
            return "Open Settings"
        case .unknown, .notDetermined, .checking, .requesting:
            return "Run Test"
        }
    }

    private static func microphoneAction(for decision: CapturePermissionDecision) -> BarnOwlReadinessAction? {
        switch decision {
        case .granted, .unavailable:
            return nil
        case .denied, .restricted:
            return .openMicrophoneSettings
        case .unknown, .notDetermined, .checking, .requesting:
            return .runCaptureTest
        }
    }

    private static func systemAudioAction(for decision: CapturePermissionDecision) -> BarnOwlReadinessAction? {
        switch decision {
        case .granted, .unavailable:
            return nil
        case .denied, .restricted:
            return .openSystemAudioSettings
        case .unknown, .notDetermined, .checking, .requesting:
            return .runCaptureTest
        }
    }
}

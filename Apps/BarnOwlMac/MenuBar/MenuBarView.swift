import AppKit
import BarnOwlCore
import BarnOwlPersistence
import SwiftUI

struct MenuBarView: View {
    @ObservedObject var model: BarnOwlAppModel
    var openRecorder: (() -> Void)?
    var openSettings: (() -> Void)?
    var quit: (() -> Void)?
    @State private var showDetails = false
    @State private var readinessSnapshot = BarnOwlFirstRunReadiness.placeholderSnapshot

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                menuHeader

                if BarnOwlMenuBarPresentation.shouldShowWaveform(
                    status: model.status,
                    progressFraction: model.progressFraction,
                    processingTimelineItems: model.processingTimelineItems
                ) {
                    BarnOwlWaveformStrip(
                        levels: model.waveformLevels,
                        isActive: model.status == .recording,
                        elapsedText: model.status == .recording ? model.recordingElapsedText : "--:--"
                    )
                }

                if setupNeeded {
                    readinessCard
                } else if BarnOwlMenuBarPresentation.shouldShowTranscriptCard(
                    status: model.status,
                    liveTranscriptPreview: model.liveTranscriptPreview
                ) {
                    transcriptCard
                }

                if BarnOwlMenuBarPresentation.shouldShowStatusAndProgressCard(
                    status: model.status,
                    captureStatus: model.captureStatus,
                    realtimeStatus: model.realtimeStatus,
                    progressFraction: model.progressFraction,
                    isUpdateInFlight: model.isUpdateInFlight,
                    updateStatus: model.updateStatus,
                    hasProcessingTimeline: false,
                    hasPerformanceSummary: false,
                    hasVisibleActivity: shouldShowActivity
                ) {
                    statusAndProgressCard
                }

                if let lastError = model.lastError {
                    errorCard(lastError)
                }

                actionButtons
                    .tint(BarnOwlDesign.amber)

                if BarnOwlMenuBarPresentation.shouldShowSessionsCard(
                    quickAccessCount: model.quickAccessSessions.count,
                    status: model.status,
                    setupNeeded: setupNeeded
                ) {
                    sessionsCard
                }

                footerBar
            }
            .padding(14)
        }
        .foregroundStyle(.white)
        .background(BarnOwlDesign.darkPopoverBackground)
        .onAppear {
            refreshReadinessSnapshot()
            Task { await model.refreshUpdateAvailability() }
        }
        .onChange(of: model.status) { _, _ in
            refreshReadinessSnapshot()
        }
        .onChange(of: model.captureStatus) { _, _ in
            refreshReadinessSnapshot()
        }
    }

    private var menuHeader: some View {
        HStack(spacing: 12) {
            BarnOwlMenuBarIcon(
                status: model.status,
                firstRecordingPause: 250_000_000 ... 600_000_000,
                recordingPause: 25_000_000_000 ... 35_000_000_000
            )
                .frame(width: 46, height: 46)

            VStack(alignment: .leading, spacing: 3) {
                Text("Barn Owl")
                    .font(.title3.weight(.semibold))
                Text(menuSubtitle)
                    .font(.callout)
                    .foregroundStyle(.white.opacity(0.58))
            }

            Spacer()

            headerUpdateControl

            Circle()
                .fill(menuStatusTint)
                .frame(width: 11, height: 11)
                .shadow(color: menuStatusTint.opacity(0.45), radius: 5)

            Button {
                openSettings?()
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white.opacity(0.52))
            .contentShape(Rectangle())
            .help("Open Settings")
            .accessibilityLabel("Open Settings")
        }
    }

    private var transcriptCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Realtime Preview")
                    .font(.headline)
                Spacer()
                Text(model.status == .recording ? "Live" : model.lifecyclePresentation.title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(model.status == .recording ? .black.opacity(0.82) : .white.opacity(0.66))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(model.status == .recording ? Color.green.opacity(0.92) : .white.opacity(0.10), in: Capsule())
            }

            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(transcriptPreviewLines.enumerated()), id: \.offset) { index, line in
                    Text(line)
                        .font(.callout)
                        .foregroundStyle(.white.opacity(index == 0 && model.status == .recording ? 0.88 : 0.72))
                        .lineLimit(3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(12)
        .background(Color.black.opacity(0.28), in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(BarnOwlDesign.darkStroke)
        }
    }

    private var readinessCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Setup needed", systemImage: "checklist")
                .font(.headline)
                .foregroundStyle(BarnOwlDesign.amberLight)

            Text(readinessSnapshot.summary)
                .font(.callout)
                .foregroundStyle(.white.opacity(0.70))
                .fixedSize(horizontal: false, vertical: true)

            Button("Open Settings") {
                openSettings?()
            }
            .buttonStyle(.borderedProminent)
            .tint(BarnOwlDesign.amber)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(BarnOwlDesign.amber.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(BarnOwlDesign.amber.opacity(0.22))
        }
    }

    private var statusAndProgressCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            if model.lifecyclePresentation.phase == .recording {
                HStack(spacing: 8) {
                    Circle()
                        .fill(.red)
                        .frame(width: 8, height: 8)
                    Text(model.lifecyclePresentation.detail)
                        .font(.headline)
                    Spacer()
                    Text(model.recordingElapsedText)
                        .font(.callout.monospacedDigit().weight(.semibold))
                        .foregroundStyle(.white.opacity(0.60))
                }
            } else if model.lifecyclePresentation.phase == .stopping {
                Label(model.lifecyclePresentation.title, systemImage: model.lifecyclePresentation.systemImage)
                    .font(.headline)
                    .foregroundStyle(.white.opacity(0.82))
                Text(model.captureStatus)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.62))
                    .fixedSize(horizontal: false, vertical: true)
            } else if let progress = model.progressFraction, progress < 1 {
                ProgressView(value: progress) {
                    Text(model.lifecyclePresentation.title)
                } currentValueLabel: {
                    Text(progress.formatted(.percent.precision(.fractionLength(0))))
                }
                .controlSize(.small)
                .tint(BarnOwlDesign.amber)
                .foregroundStyle(.white.opacity(0.76))
            }

            if shouldShowPrimaryStatusLine {
                Label(model.captureStatus, systemImage: model.lifecyclePresentation.systemImage)
                    .font(.caption)
                    .foregroundStyle(model.status == .failed ? .red : .white.opacity(0.62))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if model.status == .recording {
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Circle()
                        .fill(realtimeHealthTint)
                        .frame(width: 6, height: 6)
                    Text("Realtime preview: \(model.realtimeStatus)")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.62))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Label("High-quality pass: \(model.finalTranscriptionStatus)", systemImage: "text.magnifyingglass")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.62))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if model.isUpdateInFlight || model.updateStatus != "Updater idle." {
                Label(model.updateStatus, systemImage: model.isUpdateInFlight ? "arrow.triangle.2.circlepath" : "arrow.down.app")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.62))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if model.status == .recording,
               model.recordingReadinessSummary.state != .ready {
                Label(model.recordingReadinessSummary.message, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(model.recordingReadinessSummary.state == .blocked ? .red : BarnOwlDesign.amberLight)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if shouldShowActivity {
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        showDetails.toggle()
                    }
                } label: {
                    Label(showDetails ? "Hide Details" : "Show Details", systemImage: showDetails ? "chevron.down" : "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.58))
                }
                .buttonStyle(.plain)

                if showDetails {
                    activityDetails
                }
            }
        }
        .padding(12)
        .background(Color.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 12))
    }

    private var activityDetails: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(visibleActivityItems.prefix(4)) { item in
                HStack(alignment: .top, spacing: 7) {
                    Circle()
                        .fill(item.level.tint)
                        .frame(width: 6, height: 6)
                        .padding(.top, 5)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.message)
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.78))
                            .lineLimit(2)
                        if let details = item.details, !details.isEmpty {
                            Text(details)
                                .font(.caption2)
                                .foregroundStyle(.white.opacity(0.40))
                                .lineLimit(1)
                        }
                    }
                }
            }
        }
        .padding(9)
        .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
    }

    private func errorCard(_ lastError: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(lastError)
                .font(.callout)
                .foregroundStyle(.red)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)

            if shouldShowAPIKeyAction {
                Button("Open Settings to Add API Key") {
                    openSettings?()
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(12)
        .background(.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
    }

    private var sessionsCard: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text("Recent Sessions")
                    .font(.headline)
                Spacer()
                Button("Refresh") {
                    Task { await model.refreshRecentSessions() }
                }
                .buttonStyle(.borderless)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.52))
            }

            if model.quickAccessSessions.isEmpty {
                Text("Completed sessions stay here briefly for quick access.")
                    .font(.callout)
                    .foregroundStyle(.white.opacity(0.48))
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                VStack(spacing: 7) {
                    ForEach(model.quickAccessSessions) { session in
                        Button {
                            Task {
                                await model.openRecentSession(session.id)
                                openRecorder?()
                            }
                        } label: {
                            HStack(alignment: .center, spacing: 8) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(session.title)
                                        .font(.callout.weight(.medium))
                                        .foregroundStyle(.white.opacity(0.88))
                                        .lineLimit(1)
                                    Text(session.startedAt.formatted(date: .abbreviated, time: .shortened))
                                        .font(.caption)
                                        .foregroundStyle(.white.opacity(0.42))
                                        .lineLimit(1)
                                    if session.isProcessing {
                                        Label(session.processingSummary, systemImage: session.processingTimeline.contains { $0.status == .failed } ? "exclamationmark.triangle" : "clock")
                                            .font(.caption2.weight(.semibold))
                                            .foregroundStyle(session.processingTimeline.contains { $0.status == .failed } ? .red : BarnOwlDesign.amberLight)
                                            .lineLimit(1)
                                    }
                                    Text(session.overview)
                                        .font(.caption)
                                        .foregroundStyle(.white.opacity(0.52))
                                        .lineLimit(2)
                                }

                                Spacer(minLength: 4)

                                Image(systemName: "chevron.right")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.white.opacity(0.30))
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(9)
                            .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
                            .contentShape(RoundedRectangle(cornerRadius: 10))
                        }
                        .buttonStyle(.plain)
                        .help("Open \(session.title) in Barn Owl")
                    }
                }
            }
        }
        .padding(12)
        .background(Color.black.opacity(0.18), in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(BarnOwlDesign.darkStroke)
        }
    }

    private var footerBar: some View {
        HStack {
            Button("Open Barn Owl") {
                openRecorder?()
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white.opacity(0.72))

            Spacer()

            Button("Quit") {
                quit?()
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white.opacity(0.46))
        }
        .font(.callout.weight(.medium))
    }

    private var actionButtons: some View {
        VStack(alignment: .leading, spacing: 8) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    primaryActionButton
                        .frame(maxWidth: .infinity)
                    audioSourcePicker
                        .frame(maxWidth: .infinity)
                }

                VStack(alignment: .leading, spacing: 8) {
                    primaryActionButton
                    audioSourcePicker
                }
            }

            if shouldShowSecondaryActions {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        openAppButton
                            .frame(maxWidth: .infinity)
                        if shouldShowOpenLibraryButton {
                            openLibraryButton
                                .frame(maxWidth: .infinity)
                        }
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        openAppButton
                        if shouldShowOpenLibraryButton {
                            openLibraryButton
                        }
                    }
                }
            }
        }
    }

    private var primaryActionButton: some View {
        Button {
            Task { await model.toggleRecording() }
        } label: {
            Text(model.primaryActionTitle)
                .frame(maxWidth: .infinity)
        }
        .keyboardShortcut("r")
        .buttonStyle(.borderedProminent)
        .tint(BarnOwlDesign.amber)
        .disabled(!model.canUsePrimaryAction)
    }

    private var audioSourcePicker: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) {
                audioSourceToggle(
                    title: "Microphone",
                    systemImage: "mic",
                    isEnabled: model.selectedAudioSources.capturesMicrophone,
                    toggle: {
                        model.setMicrophoneCaptureEnabled(!model.selectedAudioSources.capturesMicrophone)
                    }
                )
                audioSourceToggle(
                    title: "System Audio",
                    systemImage: "speaker.wave.2",
                    isEnabled: model.selectedAudioSources.capturesSystemAudio,
                    toggle: {
                        model.setSystemAudioCaptureEnabled(!model.selectedAudioSources.capturesSystemAudio)
                    }
                )
            }

            HStack(spacing: 6) {
                audioSourceToggle(
                    title: "Mic",
                    systemImage: "mic",
                    isEnabled: model.selectedAudioSources.capturesMicrophone,
                    toggle: {
                        model.setMicrophoneCaptureEnabled(!model.selectedAudioSources.capturesMicrophone)
                    }
                )
                audioSourceToggle(
                    title: "System",
                    systemImage: "speaker.wave.2",
                    isEnabled: model.selectedAudioSources.capturesSystemAudio,
                    toggle: {
                        model.setSystemAudioCaptureEnabled(!model.selectedAudioSources.capturesSystemAudio)
                    }
                )
            }
        }
        .padding(3)
        .background(.black.opacity(0.20), in: Capsule())
        .overlay { Capsule().stroke(.white.opacity(0.08)) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Audio sources")
    }

    private func audioSourceToggle(
        title: String,
        systemImage: String,
        isEnabled: Bool,
        toggle: @escaping () -> Void
    ) -> some View {
        Button {
            toggle()
        } label: {
            Label(title, systemImage: systemImage)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .padding(.horizontal, 8)
                .foregroundStyle(isEnabled ? .black.opacity(0.82) : .white.opacity(0.68))
                .background(
                    isEnabled
                        ? BarnOwlDesign.amber.opacity(model.status == .recording ? 0.40 : 0.95)
                        : .black.opacity(0.20),
                    in: Capsule()
                )
                .overlay {
                    Capsule()
                        .stroke(isEnabled ? BarnOwlDesign.amberLight.opacity(0.34) : .white.opacity(0.07))
                }
        }
        .buttonStyle(.plain)
        .disabled(model.status == .recording)
        .help(model.status == .recording ? "Audio sources can be changed before the next recording." : "Toggle \(title.lowercased()) for the next recording.")
    }

    private var openAppButton: some View {
        Button {
            openRecorder?()
        } label: {
            Text("Open App")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
    }

    private var openLibraryButton: some View {
        Button {
            model.openLibraryInFinder()
        } label: {
            Text("Open Notes Folder")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .help("Open the Barn Owl notes folder in Finder")
    }

    @ViewBuilder
    private var headerUpdateControl: some View {
        if updateButtonIsProminent {
            updateButtonBase
                .buttonStyle(.plain)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.black.opacity(0.82))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(BarnOwlDesign.amber, in: Capsule())
        } else {
            Text(updateButtonTitle)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white.opacity(0.36))
                .lineLimit(1)
                .help(updateButtonHelp)
        }
    }

    private var updateButtonBase: some View {
        Button {
            Task { await model.checkForUpdatesAndInstallLatest() }
        } label: {
            Text(updateButtonTitle)
        }
            .disabled(!updateButtonIsEnabled)
            .help(updateButtonHelp)
    }

    private var updateButtonTitle: String {
        if model.isUpdateInFlight {
            return "Updating..."
        }
        switch model.updateAvailability {
        case .unknown:
            return "Checking..."
        case .checking:
            return "Checking..."
        case .available:
            return "Update Available"
        case .upToDate:
            return "Up to date"
        case .unavailable:
            return "Update unavailable"
        }
    }

    private var updateButtonIsProminent: Bool {
        model.updateAvailability.hasInstallableUpdate && !model.isUpdateInFlight && model.status != .recording
    }

    private var updateButtonIsEnabled: Bool {
        if model.isUpdateInFlight || model.status == .recording {
            return false
        }
        switch model.updateAvailability {
        case .available:
            return true
        case .unknown, .checking, .upToDate, .unavailable:
            return false
        }
    }

    private var updateButtonHelp: String {
        if model.status == .recording {
            return "Stop recording before updating Barn Owl"
        }
        if model.isUpdateInFlight {
            return "Barn Owl is installing an update"
        }
        return model.updateAvailability.statusText
    }

    private var shouldShowActivity: Bool {
        model.status != .idle && !visibleActivityItems.isEmpty
    }

    private var realtimeHealthTint: Color {
        switch model.realtimeHealthState {
        case .connected, .receivingAudio, .transcribing:
            .green
        case .degraded, .fallbackActive:
            BarnOwlDesign.amber
        case .idle, .connecting, .reconnecting, .stopped:
            .white.opacity(0.42)
        }
    }

    private var shouldShowPrimaryStatusLine: Bool {
        model.status == .recording || model.status == .processing || model.status == .failed
    }

    private var shouldShowSecondaryActions: Bool {
        model.status != .recording || shouldShowOpenLibraryButton
    }

    private var shouldShowOpenLatestButton: Bool {
        BarnOwlMenuBarPresentation.shouldShowOpenLatestButton(
            quickAccessCount: model.quickAccessSessions.count,
            status: model.status
        )
    }

    private var shouldShowOpenLibraryButton: Bool {
        BarnOwlMenuBarPresentation.shouldShowOpenLibraryButton(
            quickAccessCount: model.quickAccessSessions.count,
            status: model.status
        )
    }

    private var visibleActivityItems: [BarnOwlActivityItem] {
        model.visibleActivityItems
    }

    private var shouldShowAPIKeyAction: Bool {
        guard let lastError = model.lastError else { return false }
        return lastError.localizedCaseInsensitiveContains("API key")
    }

    private var transcriptPreviewLines: [String] {
        BarnOwlMenuBarPresentation.transcriptPreviewLines(in: model.liveTranscriptPreview, status: model.status)
    }

    private var setupNeeded: Bool {
        model.status == .idle && model.progressFraction == nil && readinessSnapshot.menuBarSetupNeeded
    }

    private var menuSubtitle: String {
        if model.progressFraction != nil {
            return model.lifecyclePresentation.title
        }
        return setupNeeded ? "Setup needed" : model.lifecyclePresentation.title
    }

    private var menuStatusTint: Color {
        if model.progressFraction != nil {
            return model.lifecyclePresentation.tint
        }
        return setupNeeded ? BarnOwlDesign.amber : model.lifecyclePresentation.tint
    }

    private func refreshReadinessSnapshot() {
        readinessSnapshot = BarnOwlFirstRunReadiness.currentSnapshot()
    }

    static func transcriptPreviewLines(in preview: String, status: RecordingStatus) -> [String] {
        BarnOwlMenuBarPresentation.transcriptPreviewLines(in: preview, status: status)
    }
}

enum BarnOwlMenuBarPresentation {
    static func transcriptPreviewLines(in preview: String, status: RecordingStatus) -> [String] {
        let rawLines = preview
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0 != "Ready." }

        if rawLines.isEmpty {
            return status == .recording
                ? ["Listening for speech..."]
                : ["Ready to listen."]
        }
        return Array(rawLines.suffix(4))
    }

    static func shouldShowWaveform(
        status: RecordingStatus,
        progressFraction: Double?,
        processingTimelineItems: [BarnOwlProcessingTimelineItem]
    ) -> Bool {
        status == .recording
            || status == .processing
            || progressFraction != nil
    }

    static func shouldShowTranscriptCard(
        status: RecordingStatus,
        liveTranscriptPreview: String
    ) -> Bool {
        if status == .recording || status == .processing || status == .failed {
            return true
        }
        let lines = transcriptPreviewLines(in: liveTranscriptPreview, status: status)
        return !lines.allSatisfy { $0 == "Ready to listen." || $0 == "Listening for speech..." }
    }

    static func shouldShowStatusAndProgressCard(
        status: RecordingStatus,
        captureStatus: String,
        realtimeStatus: String,
        progressFraction: Double?,
        isUpdateInFlight: Bool,
        updateStatus: String,
        hasProcessingTimeline: Bool,
        hasPerformanceSummary: Bool,
        hasVisibleActivity: Bool
    ) -> Bool {
        status != .idle
            || progressFraction != nil
            || isUpdateInFlight
            || updateStatus != "Updater idle."
            || hasPerformanceSummary
            || hasVisibleActivity
    }

    static func shouldShowSessionsCard(
        quickAccessCount: Int,
        status: RecordingStatus,
        setupNeeded: Bool
    ) -> Bool {
        quickAccessCount > 0 || status == .recording || status == .processing || status == .failed || !setupNeeded
    }

    static func shouldShowOpenLatestButton(quickAccessCount: Int, status: RecordingStatus) -> Bool {
        quickAccessCount > 0 || status == .processing || status == .failed
    }

    static func shouldShowOpenLibraryButton(quickAccessCount: Int, status: RecordingStatus) -> Bool {
        quickAccessCount > 0 || status == .processing || status == .failed
    }

    static func shouldShowUpdateButton(
        status: RecordingStatus,
        isUpdateInFlight: Bool,
        updateStatus: String
    ) -> Bool {
        status != .recording || isUpdateInFlight || updateStatus != "Updater idle."
    }
}

private struct BarnOwlWaveformStrip: View {
    var levels: [Double]
    var isActive: Bool
    var elapsedText: String

    var body: some View {
        HStack(spacing: 3) {
            ForEach(Array(displayLevels.enumerated()), id: \.offset) { index, level in
                Capsule()
                    .fill(isActive && index >= max(0, displayLevels.count - 12) ? BarnOwlDesign.amber : Color.white.opacity(0.18))
                    .frame(width: 4, height: 26 * CGFloat(isActive ? level : 0.16))
                    .animation(.easeInOut(duration: 0.16), value: level)
            }

            Spacer(minLength: 8)

            Text(elapsedText)
                .font(.caption.monospacedDigit().weight(.semibold))
                .foregroundStyle(.white.opacity(0.55))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(
            LinearGradient(
                colors: [BarnOwlDesign.amber.opacity(0.22), Color.black.opacity(0.18)],
                startPoint: .leading,
                endPoint: .trailing
            ),
            in: RoundedRectangle(cornerRadius: 12)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(BarnOwlDesign.amber.opacity(0.20))
        }
    }

    private var displayLevels: [Double] {
        let sanitized = levels.map { min(max($0, 0.04), 1) }
        if sanitized.count >= 24 {
            return Array(sanitized.suffix(24))
        }
        return Array(repeating: 0.16, count: 24 - sanitized.count) + sanitized
    }
}

private extension DiagnosticsLogLevel {
    var tint: Color {
        switch self {
        case .info:
            .white.opacity(0.42)
        case .warning, .error:
            BarnOwlDesign.amber
        }
    }
}

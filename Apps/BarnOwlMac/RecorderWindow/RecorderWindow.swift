import AppKit
import BarnOwlCore
import BarnOwlNotes
import BarnOwlPersistence
import SwiftUI

private enum RecorderWorkspaceTab: String, CaseIterable {
    case notes = "Notes"
    case share = "Share"
    case chat = "Chat"
    case transcript = "Transcript"
    case summary = "Summary"
    case insights = "Insights"
    case history = "History"
    case performance = "Performance"

    var systemImage: String {
        switch self {
        case .notes: "doc.text"
        case .share: "envelope"
        case .chat: "bubble.left.and.bubble.right"
        case .transcript: "quote.bubble"
        case .summary: "text.alignleft"
        case .insights: "lightbulb"
        case .history: "clock.arrow.circlepath"
        case .performance: "speedometer"
        }
    }
}

struct RecorderWindow: View {
    @ObservedObject var model: BarnOwlAppModel
    @State private var selectedTab: RecorderWorkspaceTab = .notes
    @State private var sessionPendingDeletion: BarnOwlRecentSession?
    @State private var searchTask: Task<Void, Never>?
    @State private var shareNotesCopyStatus = ""

    var body: some View {
        GeometryReader { proxy in
            let isCompact = proxy.size.width < 860

            if isCompact {
                VStack(spacing: 0) {
                    header(isCompact: true)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)

                    Divider()

                    sidebar
                        .frame(height: min(180, max(132, proxy.size.height * 0.28)))
                        .background(BarnOwlDesign.warmPanel)

                    Divider()

                    noteWorkspace(isCompact: true)
                        .padding(16)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                HStack(spacing: 0) {
                    sidebar
                        .frame(width: sidebarWidth(for: proxy.size.width))
                        .background(.ultraThinMaterial)

                    Divider()

                    VStack(spacing: 0) {
                        header(isCompact: proxy.size.width < 1_020)
                            .padding(.horizontal, 20)
                            .padding(.vertical, 16)

                        Divider()

                        noteWorkspace(isCompact: proxy.size.width < 1_240)
                            .padding(20)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
        }
        .frame(minWidth: 460, minHeight: 520)
        .background(BarnOwlDesign.windowBackground)
        .alert("Delete Recording?", isPresented: deleteConfirmationPresented) {
            Button("Delete", role: .destructive) {
                if let session = sessionPendingDeletion {
                    Task { await model.deleteRecentSession(session.id) }
                }
                sessionPendingDeletion = nil
            }
            Button("Cancel", role: .cancel) {
                sessionPendingDeletion = nil
            }
        } message: {
            Text(deleteConfirmationMessage)
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                BarnOwlMenuBarIcon(
                    status: model.status,
                    firstRecordingPause: 250_000_000 ... 700_000_000,
                    recordingPause: 25_000_000_000 ... 35_000_000_000
                )
                    .frame(width: 42, height: 42)
                    .shadow(color: BarnOwlDesign.softShadow, radius: 5, y: 2)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Barn Owl")
                        .font(.headline.weight(.semibold))
                    Text(model.lifecyclePresentation.title)
                        .font(.caption)
                        .foregroundStyle(model.lifecyclePresentation.tint)
                }
            }
            .padding(.top, 4)

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search notes", text: $model.noteSearchQuery)
                    .textFieldStyle(.plain)
                    .onSubmit {
                        Task { await model.searchNotes() }
                    }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(BarnOwlDesign.warmField, in: RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(BarnOwlDesign.warmStroke)
            }
            .onChange(of: model.noteSearchQuery) { _, _ in
                scheduleSearch()
            }
            .onExitCommand {
                clearSearch()
            }

            if model.isSearchInFlight || !model.searchStatus.isEmpty {
                inlineActionStatus(
                    text: model.searchStatus,
                    isRunning: model.isSearchInFlight,
                    isError: model.searchStatus.localizedCaseInsensitiveContains("failed")
                )
            }

            if !model.recoveryAttentionItems.isEmpty {
                needsAttentionSection
            }

            HStack {
                Text("Recent Sessions")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Button {
                    Task { await model.refreshRecentSessions() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Refresh sessions")
            }

            if displayedSessionCount == 0 {
                ContentUnavailableView(
                    "No Notes",
                    systemImage: "doc.text.magnifyingglass",
                    description: Text(emptySearchDescription)
                )
                .font(.caption)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: selectedSessionBinding) {
                    if !model.noteSearchResults.isEmpty {
                        ForEach(model.noteSearchResults) { result in
                            SearchResultRow(result: result, isSelected: model.displayedNote?.id == result.id)
                                .tag(result.id)
                        }
                    } else {
                        ForEach(filteredSessions) { session in
                            SessionRow(session: session, isSelected: model.displayedNote?.id == session.id)
                                .tag(session.id)
                                .contextMenu {
                                    Button("Show Markdown in Finder") {
                                        revealInFinder(session.markdownURL)
                                    }
                                    Divider()
                                    Button("Delete Recording", role: .destructive) {
                                        sessionPendingDeletion = session
                                    }
                                }
                        }
                    }
                }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)
            }
        }
        .padding(14)
    }

    private var needsAttentionSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Needs Attention", systemImage: "exclamationmark.triangle.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.red)

            ForEach(model.recoveryAttentionItems.prefix(3)) { item in
                RecoveryAttentionRow(
                    item: item,
                    retry: {
                        Task { await model.retryRecoveryAttentionItem(item) }
                    },
                    dismiss: {
                        Task { await model.dismissRecoveryAttentionItem(item) }
                    }
                )
            }
        }
        .padding(10)
        .background(.red.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(.red.opacity(0.16))
        }
    }

    private func header(isCompact: Bool) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 14) {
                headerIdentity

                Spacer(minLength: 16)

                headerControls(
                    alignment: .trailing,
                    textAlignment: .trailing,
                    frameAlignment: .trailing,
                    maxStatusWidth: 260
                )
            }

            VStack(alignment: .leading, spacing: 12) {
                headerIdentity

                headerControls(
                    alignment: .leading,
                    textAlignment: .leading,
                    frameAlignment: .leading,
                    maxStatusWidth: isCompact ? nil : 420
                )
            }
        }
        .padding(12)
        .background(BarnOwlDesign.warmPanel, in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(BarnOwlDesign.warmStroke)
        }
    }

    private var headerIdentity: some View {
        HStack(spacing: 14) {
            BarnOwlMenuBarIcon(
                status: model.status,
                firstRecordingPause: 250_000_000 ... 700_000_000,
                recordingPause: 25_000_000_000 ... 35_000_000_000
            )
                .frame(width: 54, height: 54)
                .shadow(color: BarnOwlDesign.softShadow, radius: 6, y: 3)

            VStack(alignment: .leading, spacing: 3) {
                if model.displayedNote != nil {
                    renameControls
                } else {
                    Text(currentTitle)
                        .font(.title2.weight(.semibold))
                        .lineLimit(1)
                }
                Text(currentSubtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .layoutPriority(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var renameControls: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                renameTextField
                renameButton
            }

            VStack(alignment: .leading, spacing: 6) {
                renameTextField
                renameButton
            }
        }
    }

    private var renameTextField: some View {
        TextField("Meeting name", text: $model.noteTitleDraft)
            .textFieldStyle(.roundedBorder)
            .font(.title3.weight(.semibold))
            .frame(minWidth: 120, idealWidth: 320, maxWidth: .infinity)
            .layoutPriority(1)
            .onSubmit {
                Task { await model.saveDisplayedMeetingTitle() }
            }
    }

    private var renameButton: some View {
        Button("Rename") {
            Task { await model.saveDisplayedMeetingTitle() }
        }
        .disabled(model.noteTitleDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    private func headerControls(
        alignment: HorizontalAlignment,
        textAlignment: TextAlignment,
        frameAlignment: Alignment,
        maxStatusWidth: CGFloat?
    ) -> some View {
        VStack(alignment: alignment, spacing: 6) {
            Button(model.primaryActionTitle) {
                Task { await model.toggleRecording() }
            }
            .buttonStyle(.borderedProminent)
            .tint(BarnOwlDesign.amber)
            .disabled(!model.canUsePrimaryAction)

            if model.lifecyclePresentation.phase == .recording {
                Label("Recording \(model.recordingElapsedText)", systemImage: model.lifecyclePresentation.systemImage)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.red)
                    .lineLimit(1)
                    .multilineTextAlignment(textAlignment)
                    .frame(maxWidth: maxStatusWidth, alignment: frameAlignment)
            } else if model.status != .idle || model.captureStatus != "Idle." {
                Label(model.lifecyclePresentation.title, systemImage: model.lifecyclePresentation.systemImage)
                    .font(.caption)
                    .foregroundStyle(model.status == .failed ? .red : .secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(textAlignment)
                    .frame(maxWidth: maxStatusWidth, alignment: frameAlignment)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if model.status == .recording {
                pipelineStatusLabel(
                    "Realtime preview",
                    status: model.realtimeStatus,
                    systemImage: "waveform",
                    textAlignment: textAlignment,
                    frameAlignment: frameAlignment,
                    maxStatusWidth: maxStatusWidth
                )

                pipelineStatusLabel(
                    "High-quality pass",
                    status: model.finalTranscriptionStatus,
                    systemImage: "text.magnifyingglass",
                    textAlignment: textAlignment,
                    frameAlignment: frameAlignment,
                    maxStatusWidth: maxStatusWidth
                )
            }

        }
    }

    private func pipelineStatusLabel(
        _ title: String,
        status: String,
        systemImage: String,
        textAlignment: TextAlignment,
        frameAlignment: Alignment,
        maxStatusWidth: CGFloat?
    ) -> some View {
        Label("\(title): \(status)", systemImage: systemImage)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(2)
            .multilineTextAlignment(textAlignment)
            .frame(maxWidth: maxStatusWidth, alignment: frameAlignment)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func noteWorkspace(isCompact: Bool) -> some View {
        Group {
            if isCompact {
                ScrollView {
                    noteWorkspaceContent(isCompact: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                noteWorkspaceContent(isCompact: false)
            }
        }
    }

    private func noteWorkspaceContent(isCompact: Bool) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            progressSection

            toolbarButtons

            if shouldShowPostRecordingContextReview {
                postRecordingContextReviewPanel
            }

            if isCompact {
                VStack(alignment: .leading, spacing: 16) {
                    noteTabs
                    selectedTabContent(minHeight: 220, maxHeight: 280)
                    promptAndContextPanel(width: nil)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HStack(spacing: 0) {
                    mainEditorColumn
                        .frame(minWidth: 300, maxWidth: .infinity, maxHeight: .infinity)
                        .layoutPriority(1)

                    if shouldShowContextInspector {
                        Divider()
                            .padding(.vertical, -20)

                        contextInspector
                            .frame(width: 300)
                            .frame(maxHeight: .infinity)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            if let lastError = model.lastError {
                Label(lastError, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .font(.callout)
                    .padding(10)
                    .background(.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            }

        }
    }

    private var mainEditorColumn: some View {
        VStack(alignment: .leading, spacing: 14) {
            noteTabs

            selectedTabContent(minHeight: 430, maxHeight: .infinity)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            promptBar
        }
        .padding(.trailing, 18)
    }

    private var noteTabs: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(visibleWorkspaceTabs, id: \.self) { tab in
                    Button {
                        selectedTab = tab
                    } label: {
                        Label(tab.rawValue, systemImage: tab.systemImage)
                            .labelStyle(.titleAndIcon)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(currentWorkspaceTab == tab ? .primary : .secondary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(currentWorkspaceTab == tab ? BarnOwlDesign.amber.opacity(0.16) : .clear, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .contentShape(Capsule())
                    .help(tab.rawValue)
                    .accessibilityAddTraits(currentWorkspaceTab == tab ? .isSelected : [])
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func selectedTabContent(minHeight: CGFloat, maxHeight: CGFloat?) -> some View {
        switch currentWorkspaceTab {
        case .notes:
            noteEditor(minHeight: minHeight, maxHeight: maxHeight)
        case .share:
            externalNotesPanel(minHeight: minHeight, maxHeight: maxHeight)
        case .chat:
            chatPanel(minHeight: minHeight, maxHeight: maxHeight)
        case .transcript:
            readOnlyMarkdownPanel(
                title: "Final Transcript",
                systemImage: "quote.bubble",
                text: transcriptText,
                placeholder: RecorderWorkspacePresentation.finalTranscriptPlaceholder(
                    status: model.status,
                    hasProcessingTimeline: !model.processingTimelineItems.isEmpty
                ),
                minHeight: minHeight,
                maxHeight: maxHeight
            )
        case .summary:
            readOnlyMarkdownPanel(
                title: "Summary",
                systemImage: "text.alignleft",
                text: summaryText,
                placeholder: "No summary section found yet.",
                minHeight: minHeight,
                maxHeight: maxHeight
            )
        case .insights:
            readOnlyMarkdownPanel(
                title: "Insights",
                systemImage: "lightbulb",
                text: insightsText,
                placeholder: "No decisions, action items, or open questions found yet.",
                minHeight: minHeight,
                maxHeight: maxHeight
            )
        case .history:
            historyPanel(minHeight: minHeight, maxHeight: maxHeight)
        case .performance:
            readOnlyMarkdownPanel(
                title: "Performance",
                systemImage: "speedometer",
                text: performanceText,
                placeholder: "Performance details appear after a recording starts.",
                minHeight: minHeight,
                maxHeight: maxHeight
            )
        }
    }

    private var promptBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    promptField
                    promptUpdateButton
                }

                VStack(alignment: .leading, spacing: 8) {
                    promptField
                    promptUpdateButton
                }
            }

            if model.noteActionStatus.isEmpty == false {
                HStack(spacing: 8) {
                    inlineActionStatus(
                        text: model.noteActionStatus,
                        isRunning: model.isNoteUpdateInFlight,
                        isError: model.noteActionStatus.localizedCaseInsensitiveContains("failed")
                    )

                    if model.noteActionStatus.localizedCaseInsensitiveContains("failed") {
                        Button("Retry") {
                            Task { await model.applyPromptToDisplayedNote() }
                        }
                        .controlSize(.small)
                    }

                    if model.noteActionStatus.localizedCaseInsensitiveContains("api key") {
                        Button("Settings") {
                            openSettings()
                        }
                        .controlSize(.small)
                    }
                }
            } else if let reason = promptDisabledReason {
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(11)
        .background(BarnOwlDesign.warmField, in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(BarnOwlDesign.warmStroke)
        }
        .tint(BarnOwlDesign.amber)
    }

    private func historyPanel(minHeight: CGFloat, maxHeight: CGFloat?) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("History", systemImage: "clock.arrow.circlepath")
                    .font(.headline)
                Spacer()
                if let latest = model.meetingHistoryItems.first {
                    Button {
                        Task { await model.restoreMeetingHistoryItem(latest.id) }
                    } label: {
                        Label("Undo Last", systemImage: "arrow.uturn.backward")
                    }
                    .disabled(model.isHistoryRestoreInFlight)
                    .controlSize(.small)
                }
                Button {
                    Task { await model.refreshMeetingHistory() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Refresh history")
            }

            if !model.historyStatus.isEmpty {
                inlineActionStatus(
                    text: model.historyStatus,
                    isRunning: model.isHistoryRestoreInFlight,
                    isError: model.historyStatus.localizedCaseInsensitiveContains("failed")
                        || model.historyStatus.localizedCaseInsensitiveContains("could not")
                )
            }

            if model.meetingHistoryItems.isEmpty {
                ContentUnavailableView(
                    "No History Yet",
                    systemImage: "clock",
                    description: Text("Changes to notes, context, title, and meeting facts will appear here.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(model.meetingHistoryItems) { item in
                            historyRow(item)
                        }
                    }
                    .padding(2)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: minHeight, maxHeight: maxHeight, alignment: .topLeading)
        .background(BarnOwlDesign.warmField, in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(BarnOwlDesign.warmStroke)
        }
    }

    private func historyRow(_ item: BarnOwlMeetingHistoryItem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: historyIcon(for: item.changeType))
                    .foregroundStyle(BarnOwlDesign.amber)
                    .frame(width: 18)

                VStack(alignment: .leading, spacing: 3) {
                    Text(item.summary)
                        .font(.callout.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    Text("\(item.displayChangeType) • \(item.displayActor) • \(item.createdAt.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 8)

                Button("Restore") {
                    Task { await model.restoreMeetingHistoryItem(item.id) }
                }
                .disabled(model.isHistoryRestoreInFlight)
                .controlSize(.small)
            }

            if item.beforeTitle != item.afterTitle {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("Title")
                        .font(.caption.weight(.semibold))
                    Text(item.beforeTitle ?? "None")
                        .strikethrough()
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Image(systemName: "arrow.right")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Text(item.afterTitle ?? "None")
                        .lineLimit(1)
                }
                .font(.caption)
            }

            if item.beforeMarkdown != item.afterMarkdown {
                DisclosureGroup("Compare note changes") {
                    VStack(alignment: .leading, spacing: 6) {
                        diffPreview(before: item.beforeMarkdown, after: item.afterMarkdown)
                    }
                    .padding(.top, 6)
                }
                .font(.caption)
            }
        }
        .padding(10)
        .background(.background.opacity(0.55), in: RoundedRectangle(cornerRadius: 10))
    }

    private func diffPreview(before: String, after: String) -> some View {
        let beforeLines = before.components(separatedBy: .newlines)
        let afterLines = after.components(separatedBy: .newlines)
        let beforeSet = Set(beforeLines.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })
        let afterSet = Set(afterLines.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })
        let removed = beforeLines.filter { !afterSet.contains($0.trimmingCharacters(in: .whitespacesAndNewlines)) && !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.prefix(5)
        let added = afterLines.filter { !beforeSet.contains($0.trimmingCharacters(in: .whitespacesAndNewlines)) && !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.prefix(5)

        return VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(removed), id: \.self) { line in
                Text("- \(line)")
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }
            ForEach(Array(added), id: \.self) { line in
                Text("+ \(line)")
                    .foregroundStyle(.green)
                    .lineLimit(2)
            }
            if removed.isEmpty && added.isEmpty {
                Text("Metadata changed; note text was unchanged.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func historyIcon(for changeType: BarnOwlMeetingVersionChangeType) -> String {
        switch changeType {
        case .noteRewrite, .promptUpdate:
            "doc.text"
        case .contextUpdate:
            "text.badge.plus"
        case .titleRename:
            "text.cursor"
        case .participantCorrection:
            "person.2"
        case .meetingFactsUpdate:
            "list.bullet.clipboard"
        case .summaryRegenerated, .actionsRegenerated:
            "sparkles"
        case .restore:
            "arrow.uturn.backward"
        }
    }

    private var promptField: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "sparkles")
                .foregroundStyle(BarnOwlDesign.amber)
                .padding(.top, 2)
            CommandTextEditor(
                text: $model.notePrompt,
                placeholder: "Ask Barn Owl to rename, tighten decisions, extract follow-ups, or rewrite this note.",
                minHeight: 24,
                maxHeight: 88,
                isEnabled: !model.isNoteUpdateInFlight,
                onSubmit: {
                    Task { await model.applyPromptToDisplayedNote() }
                }
            )
            .frame(minHeight: 24, maxHeight: 88)
            .accessibilityLabel("Note update prompt")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var promptUpdateButton: some View {
        Button {
            Task { await model.applyPromptToDisplayedNote() }
        } label: {
            HStack(spacing: 6) {
                if model.isNoteUpdateInFlight {
                    ProgressView()
                        .controlSize(.small)
                }
                Text(model.isNoteUpdateInFlight ? "Updating..." : "Update")
            }
        }
        .disabled(!canRunPromptUpdate)
        .help(promptDisabledReason ?? "Update this note")
    }

    private var promptDisabledReason: String? {
        BarnOwlActionUX.notePromptDisabledReason(
            hasOpenNote: model.displayedNote != nil,
            isUpdating: model.isNoteUpdateInFlight,
            prompt: model.notePrompt
        )
    }

    private var contextDisabledReason: String? {
        BarnOwlActionUX.contextDisabledReason(
            hasTarget: model.displayedNote != nil || model.activeSession != nil,
            isUpdating: model.isContextUpdateInFlight,
            context: model.contextDraft
        )
    }

    private var chatDisabledReason: String? {
        BarnOwlActionUX.chatDisabledReason(
            isSending: model.isChatInFlight,
            draft: model.chatDraft
        )
    }

    private func commandContextEditor(
        text: Binding<String>,
        placeholder: String,
        minHeight: CGFloat,
        maxHeight: CGFloat? = nil
    ) -> some View {
        CommandTextEditor(
            text: text,
            placeholder: placeholder,
            minHeight: minHeight,
            maxHeight: maxHeight ?? minHeight,
            isEnabled: !model.isContextUpdateInFlight,
            onSubmit: {
                Task { await model.appendContextToDisplayedNote() }
            }
        )
        .frame(minHeight: minHeight, maxHeight: maxHeight)
        .padding(8)
        .background(BarnOwlDesign.warmField, in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(BarnOwlDesign.warmStroke)
        }
    }

    private func inlineActionStatus(text: String, isRunning: Bool = false, isError: Bool = false) -> some View {
        HStack(spacing: 6) {
            if isRunning {
                ProgressView()
                    .controlSize(.small)
            } else {
                Image(systemName: isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .foregroundStyle(isError ? .red : BarnOwlDesign.moss)
            }
            Text(text)
                .font(.caption)
                .foregroundStyle(isError ? .red : .secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func openSettings() {
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func scheduleSearch() {
        searchTask?.cancel()
        searchTask = Task {
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            await model.searchNotes()
        }
    }

    private func clearSearch() {
        model.noteSearchQuery = ""
        model.searchMeetingTypeFilter = ""
        model.searchParticipantFilter = ""
        model.searchStatusFilter = nil
        Task { await model.searchNotes() }
    }

    private var emptySearchDescription: String {
        if model.isSearchInFlight {
            return "Searching..."
        }
        if !model.searchStatus.isEmpty,
           model.searchStatus.localizedCaseInsensitiveContains("failed") {
            return "Search is unavailable. Check diagnostics for details."
        }
        if hasSearchFilters || !model.noteSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "No notes match this search."
        }
        return "Completed transcripts will show up here."
    }

    private var contextInspector: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                inspectorCard(title: "Jobs", systemImage: "clock.arrow.circlepath") {
                    jobStatusContent
                }

                inspectorCard(title: "Context Inbox", systemImage: "tray.full") {
                    contextInboxContent
                }

                inspectorCard(title: "Context Review", systemImage: "square.stack.3d.up") {
                    Text(inferredFactsText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    commandContextEditor(
                        text: $model.contextDraft,
                        placeholder: "Add anything Barn Owl should know: people, project, customer, goals, corrections, acronyms, prior context...",
                        minHeight: 110,
                        maxHeight: 150
                    )
                    HStack(spacing: 8) {
                        Button {
                            Task { await model.appendContextToDisplayedNote() }
                        } label: {
                            HStack(spacing: 6) {
                                if model.isContextUpdateInFlight {
                                    ProgressView()
                                        .controlSize(.small)
                                }
                                Text(model.isContextUpdateInFlight ? "Adding..." : "Add Context")
                            }
                        }
                        .disabled(contextDisabledReason != nil)
                        .help(contextDisabledReason ?? "Attach context")

                        if !model.contextReviewStatus.isEmpty {
                            inlineActionStatus(
                                text: model.contextReviewStatus,
                                isRunning: model.isContextUpdateInFlight,
                                isError: model.contextReviewStatus.localizedCaseInsensitiveContains("failed")
                            )
                        } else if let reason = contextDisabledReason {
                            Text(reason)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                inspectorCard(title: "Related Notes", systemImage: "link") {
                    if filteredSessions.prefix(3).isEmpty {
                        Text("Search or complete more notes to populate this.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(Array(filteredSessions.prefix(3))) { session in
                            Button {
                                Task { await model.openRecentSession(session.id) }
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(session.title)
                                        .font(.caption.weight(.semibold))
                                        .lineLimit(1)
                                    Text(session.overview)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                if canShowRetentionActions {
                    inspectorCard(title: "Retention", systemImage: "externaldrive.badge.minus") {
                        Text("Final notes are kept in the Barn Owl library. Temporary audio is purged after processing, and can be purged manually here too.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button("Purge Temporary Audio") {
                            Task { await model.purgeTemporaryAudioForDisplayedRecording() }
                        }
                        .disabled(model.displayedNote == nil && model.activeSession == nil)
                        Button("Delete Recording", role: .destructive) {
                            if let session = model.recentSessions.first(where: { $0.id == model.displayedNote?.id }) {
                                sessionPendingDeletion = session
                            }
                        }
                        .disabled(model.displayedNote == nil)
                    }
                }

                statusStrip
            }
            .padding(.leading, 18)
        }
    }

    private var postRecordingContextReviewPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                Label("Context Review", systemImage: "text.badge.checkmark")
                    .font(.headline)
                Spacer()
                Text("Final notes already generated")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(BarnOwlDesign.moss)
            }

            Text(model.postRecordingContextReview?.suggestedSummary ?? "Barn Owl inferred meeting context from the transcript.")
                .font(.callout.weight(.semibold))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)

            Text("Add messy context, corrections, acronyms, people, customer details, or goals. Barn Owl will keep structured meeting facts behind the scenes.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let prompts = model.postRecordingContextReview?.prompts, !prompts.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(prompts) { prompt in
                        Label(prompt.text, systemImage: "sparkle.magnifyingglass")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(BarnOwlDesign.amber)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.background.opacity(0.45), in: RoundedRectangle(cornerRadius: 10))
            }

            CommandTextEditor(
                text: reviewFreeformContextBinding,
                placeholder: "Add anything Barn Owl should know: people, project, customer, goals, corrections, acronyms, prior context...",
                minHeight: 88,
                maxHeight: 140,
                isEnabled: !model.isContextUpdateInFlight,
                onSubmit: {
                    Task { await model.addPostRecordingContext() }
                }
            )
            .frame(minHeight: 88, maxHeight: 140)
            .padding(8)
            .background(BarnOwlDesign.warmField, in: RoundedRectangle(cornerRadius: 10))
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .stroke(BarnOwlDesign.warmStroke)
            }

            if !model.contextReviewStatus.isEmpty {
                inlineActionStatus(
                    text: model.contextReviewStatus,
                    isRunning: model.isContextUpdateInFlight,
                    isError: model.contextReviewStatus.localizedCaseInsensitiveContains("failed")
                )
            }

            ViewThatFits(in: .horizontal) {
                HStack {
                    Button(model.isContextUpdateInFlight ? "Working..." : "Looks right") {
                        Task { await model.approvePostRecordingContextReview() }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(BarnOwlDesign.amber)
                    .disabled(model.isContextUpdateInFlight)

                    Button(model.isContextUpdateInFlight ? "Reading..." : "Add context") {
                        Task { await model.addPostRecordingContext() }
                    }
                    .disabled(model.isContextUpdateInFlight)

                    Button(model.isContextUpdateInFlight ? "Regenerating..." : "Regenerate notes") {
                        Task { await model.regenerateNotesFromPostRecordingContext() }
                    }
                    .disabled(model.isContextUpdateInFlight)

                    Button("Not now") {
                        Task { await model.processPostRecordingContextWithoutEdits() }
                    }
                    .disabled(model.isContextUpdateInFlight)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Button(model.isContextUpdateInFlight ? "Working..." : "Looks right") {
                        Task { await model.approvePostRecordingContextReview() }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(BarnOwlDesign.amber)
                    .disabled(model.isContextUpdateInFlight)

                    Button(model.isContextUpdateInFlight ? "Reading..." : "Add context") {
                        Task { await model.addPostRecordingContext() }
                    }
                    .disabled(model.isContextUpdateInFlight)

                    Button(model.isContextUpdateInFlight ? "Regenerating..." : "Regenerate notes") {
                        Task { await model.regenerateNotesFromPostRecordingContext() }
                    }
                    .disabled(model.isContextUpdateInFlight)

                    Button("Not now") {
                        Task { await model.processPostRecordingContextWithoutEdits() }
                    }
                    .disabled(model.isContextUpdateInFlight)
                }
            }
        }
        .padding(12)
        .background(BarnOwlDesign.amber.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(BarnOwlDesign.amber.opacity(0.25))
        }
    }

    private var toolbarButtons: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                noteToolbarButton(saveNoteToolbarAction)
                noteOverflowMenu
            }

            VStack(alignment: .leading, spacing: 8) {
                noteToolbarButton(saveNoteToolbarAction)
                noteOverflowMenu
            }
        }
        .tint(BarnOwlDesign.amber)
    }

    private var noteOverflowMenu: some View {
        Menu("More") {
            ForEach(noteToolbarSecondaryActions) { action in
                noteToolbarButton(action)
            }
        }
        .disabled(noteToolbarSecondaryActions.allSatisfy(\.isDisabled))
        .help("Export, reveal, and delete actions")
    }

    @ViewBuilder
    private func noteToolbarButton(_ action: NoteToolbarAction) -> some View {
        if let keyboardShortcut = action.keyboardShortcut {
            Button(action.title, role: action.role) {
                action.perform()
            }
            .disabled(action.isDisabled)
            .keyboardShortcut(KeyEquivalent(Character(keyboardShortcut)), modifiers: [.command])
        } else {
            Button(action.title, role: action.role) {
                action.perform()
            }
            .disabled(action.isDisabled)
        }
    }

    private var saveNoteToolbarAction: NoteToolbarAction {
        NoteToolbarAction(
            title: "Save Edits",
            isDisabled: model.displayedNote == nil,
            keyboardShortcut: "s",
            perform: { Task { await model.saveDisplayedNoteDraft() } }
        )
    }

    private var noteToolbarSecondaryActions: [NoteToolbarAction] {
        [
            NoteToolbarAction(
                title: "Open Markdown in Finder",
                isDisabled: model.displayedNote == nil,
                keyboardShortcut: nil,
                perform: { Task { await model.openDisplayedMarkdownInFinder() } }
            ),
            NoteToolbarAction(
                title: "Open Library in Finder",
                isDisabled: false,
                keyboardShortcut: nil,
                perform: { model.openLibraryInFinder() }
            ),
            NoteToolbarAction(
                title: "Delete Recording",
                isDisabled: model.displayedNote == nil,
                keyboardShortcut: nil,
                role: .destructive,
                perform: {
                    if let session = model.recentSessions.first(where: { $0.id == model.displayedNote?.id }) {
                        sessionPendingDeletion = session
                    }
                }
            )
        ]
    }

    private func noteEditor(minHeight: CGFloat, maxHeight: CGFloat?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(model.displayedNote == nil ? "Realtime Preview" : "Markdown Note", systemImage: model.displayedNote == nil ? "waveform" : "doc.plaintext")
                .font(.headline)

            if model.displayedNote == nil {
                Text("Fast preview while recording. The final diarized transcript is generated after you stop.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                livePreview(minHeight: minHeight, maxHeight: maxHeight)
            } else {
                editor(
                    text: $model.noteDraft,
                    placeholder: "No note content.",
                    minHeight: minHeight,
                    maxHeight: maxHeight
                )
            }
        }
    }

    private func livePreview(minHeight: CGFloat, maxHeight: CGFloat?) -> some View {
        ScrollView {
            Text(model.liveTranscriptPreview)
                .font(.system(.body, design: .default))
                .foregroundStyle(model.status == .idle ? .secondary : .primary)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .padding(12)
                .textSelection(.enabled)
        }
        .frame(minHeight: minHeight, maxHeight: maxHeight)
        .background(BarnOwlDesign.warmField, in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(BarnOwlDesign.warmStroke)
        }
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func readOnlyMarkdownPanel(
        title: String,
        systemImage: String,
        text: String,
        placeholder: String,
        minHeight: CGFloat,
        maxHeight: CGFloat?
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: systemImage)
                .font(.headline)

            ScrollView {
                Text(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? placeholder : text)
                    .font(.system(.body, design: .default))
                    .foregroundStyle(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .secondary : .primary)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(12)
                    .textSelection(.enabled)
            }
            .frame(minHeight: minHeight, maxHeight: maxHeight)
            .background(BarnOwlDesign.warmField, in: RoundedRectangle(cornerRadius: 10))
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .stroke(BarnOwlDesign.warmStroke)
            }
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
    }

    private func externalNotesPanel(minHeight: CGFloat, maxHeight: CGFloat?) -> some View {
        let text = externalParticipantNotesText
        let isEmpty = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Label("External Notes", systemImage: "envelope")
                    .font(.headline)
                Spacer()
                Button("Copy Email Notes") {
                    copyExternalParticipantNotes()
                }
                .disabled(isEmpty)
            }

            Text("Email-friendly recap for participants. Barn Owl excludes private local context, diagnostics, file paths, and raw transcript.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            ScrollView {
                Text(isEmpty ? "External notes will appear after a transcript or summary is available." : text)
                    .font(.system(.body, design: .default))
                    .foregroundStyle(isEmpty ? .secondary : .primary)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(12)
                    .textSelection(.enabled)
            }
            .frame(minHeight: minHeight, maxHeight: maxHeight)
            .background(BarnOwlDesign.warmField, in: RoundedRectangle(cornerRadius: 10))
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .stroke(BarnOwlDesign.warmStroke)
            }
            .clipShape(RoundedRectangle(cornerRadius: 10))

            if !shareNotesCopyStatus.isEmpty {
                Label(shareNotesCopyStatus, systemImage: "checkmark.circle.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(BarnOwlDesign.moss)
            }
        }
    }

    private func chatPanel(minHeight: CGFloat, maxHeight: CGFloat?) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Barn Owl Chat", systemImage: "bubble.left.and.bubble.right")
                    .font(.headline)
                Spacer()
                if model.isChatInFlight {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(model.chatMessages) { message in
                            ChatMessageBubble(message: message)
                                .id(message.id)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                }
                .frame(minHeight: minHeight, maxHeight: maxHeight)
                .background(BarnOwlDesign.warmField, in: RoundedRectangle(cornerRadius: 10))
                .overlay {
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(BarnOwlDesign.warmStroke)
                }
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .onChange(of: model.chatMessages.count) { _, _ in
                    DispatchQueue.main.async {
                        if let last = model.chatMessages.last {
                            withAnimation(.easeOut(duration: 0.18)) {
                                proxy.scrollTo(last.id, anchor: .bottom)
                            }
                        }
                    }
                }
            }

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    chatField
                    chatSendButton
                }

                VStack(alignment: .leading, spacing: 8) {
                    chatField
                    chatSendButton
                }
            }

            if !model.chatStatus.isEmpty {
                HStack(spacing: 8) {
                    inlineActionStatus(
                        text: model.chatStatus,
                        isRunning: model.isChatInFlight,
                        isError: model.chatStatus.localizedCaseInsensitiveContains("failed")
                    )
                    if model.lastFailedChatQuestion != nil {
                        Button("Retry") {
                            Task { await model.sendChatMessage() }
                        }
                        .controlSize(.small)
                    }
                    if model.chatStatus.localizedCaseInsensitiveContains("api key") {
                        Button("Settings") {
                            openSettings()
                        }
                        .controlSize(.small)
                    }
                }
            } else if let reason = chatDisabledReason {
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var chatField: some View {
        CommandTextEditor(
            text: $model.chatDraft,
            placeholder: "Ask what changed, draft follow-up, extract decisions, or find context.",
            minHeight: 34,
            maxHeight: 98,
            isEnabled: !model.isChatInFlight,
            onSubmit: {
                Task { await model.sendChatMessage() }
            }
        )
        .frame(minHeight: 34, maxHeight: 98)
        .padding(8)
        .background(BarnOwlDesign.warmField, in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(BarnOwlDesign.warmStroke)
        }
    }

    private var chatSendButton: some View {
        Button {
            Task { await model.sendChatMessage() }
        } label: {
            HStack(spacing: 6) {
                if model.isChatInFlight {
                    ProgressView()
                        .controlSize(.small)
                }
                Text(model.isChatInFlight ? "Thinking..." : "Ask")
            }
        }
        .disabled(chatDisabledReason != nil)
        .help(chatDisabledReason ?? "Ask Barn Owl")
    }

    private func promptAndContextPanel(width: CGFloat?) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 8) {
                Label("Prompt", systemImage: "sparkles")
                    .font(.headline)
                CommandTextEditor(
                    text: $model.notePrompt,
                    placeholder: "Ask Barn Owl to tighten decisions, extract follow-ups, rewrite the note, or rename the meeting.",
                    minHeight: 120,
                    maxHeight: 160,
                    isEnabled: !model.isNoteUpdateInFlight,
                    onSubmit: {
                        Task { await model.applyPromptToDisplayedNote() }
                    }
                )
                .frame(minHeight: 120, maxHeight: 160)
                .padding(8)
                .background(BarnOwlDesign.warmField, in: RoundedRectangle(cornerRadius: 10))
                .overlay {
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(BarnOwlDesign.warmStroke)
                }

                promptUpdateButton
            }

            VStack(alignment: .leading, spacing: 8) {
                Label("Context Inbox", systemImage: "tray.full")
                    .font(.headline)
                contextInboxContent
            }

            VStack(alignment: .leading, spacing: 8) {
                Label("Context", systemImage: "plus.bubble")
                    .font(.headline)
                commandContextEditor(
                    text: $model.contextDraft,
                    placeholder: "Add names, project context, acronyms, meeting type, or corrections.",
                    minHeight: 110,
                    maxHeight: 150
                )
                Button {
                    Task { await model.appendContextToDisplayedNote() }
                } label: {
                    HStack(spacing: 6) {
                        if model.isContextUpdateInFlight {
                            ProgressView()
                                .controlSize(.small)
                        }
                        Text(model.isContextUpdateInFlight ? "Adding..." : "Add Context")
                    }
                }
                .disabled(contextDisabledReason != nil)
                .help(contextDisabledReason ?? "Attach context")
            }

        }
        .padding(12)
        .background(BarnOwlDesign.warmPanel, in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(BarnOwlDesign.warmStroke)
        }
        .frame(width: width)
        .frame(maxWidth: width == nil ? .infinity : width, maxHeight: .infinity)
        .tint(BarnOwlDesign.amber)
    }

    private func inspectorCard<Content: View>(
        title: String,
        systemImage: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: systemImage)
                .font(.headline)
                .foregroundStyle(.primary)

            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(BarnOwlDesign.warmPanel, in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(BarnOwlDesign.warmStroke)
        }
    }

    private var statusStrip: some View {
        VStack(alignment: .leading, spacing: 7) {
            Label(model.lifecyclePresentation.title, systemImage: model.lifecyclePresentation.systemImage)
                .font(.caption.weight(.semibold))
                .foregroundStyle(model.lifecyclePresentation.tint)

            if model.status == .recording {
                Label("Realtime preview: \(model.realtimeStatus)", systemImage: "waveform")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Label("High-quality pass: \(model.finalTranscriptionStatus)", systemImage: "text.magnifyingglass")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let latestJob = model.jobSummaries.first {
                Label(latestJob.displayText, systemImage: "clock.arrow.circlepath")
                    .font(.caption2)
                    .foregroundStyle(latestJob.status == .failed ? .red : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let activeStep = model.processingTimelineItems.first(where: { $0.status == .running || $0.status == .failed || $0.status == .pending }),
               !BarnOwlProcessingTimeline.shouldCollapse(model.processingTimelineItems) {
                Label(activeStep.status == .failed ? "\(activeStep.step.label) failed" : activeStep.step.label, systemImage: activeStep.status == .failed ? "exclamationmark.triangle" : "clock")
                    .font(.caption2)
                    .foregroundStyle(activeStep.status == .failed ? .red : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(BarnOwlDesign.amber.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder
    private var jobStatusContent: some View {
        if model.jobSummaries.isEmpty {
            Text("No background jobs are running.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            ForEach(model.jobSummaries.prefix(5)) { job in
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Image(systemName: jobIcon(for: job.status))
                            .foregroundStyle(jobColor(for: job.status))
                        Text(job.displayText)
                            .font(.caption.weight(.semibold))
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        Text(job.updatedAt.formatted(date: .omitted, time: .shortened))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    if let error = job.errorMessage, !error.isEmpty {
                        Text(error)
                            .font(.caption2)
                            .foregroundStyle(.red)
                            .lineLimit(3)
                    }
                }
            }

            Button("Retry Failed Jobs") {
                Task { await model.retryFailedJobs() }
            }
            .disabled(!model.jobSummaries.contains { $0.status == .failed })
            .help(model.jobSummaries.contains { $0.status == .failed } ? "Retry failed jobs" : "No failed jobs to retry.")
            if !model.jobSummaries.contains(where: { $0.status == .failed }) {
                Text("No failed jobs to retry.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var contextInboxContent: some View {
        if model.contextInboxItems.isEmpty {
            Text("CLI, Codex, and manual context will appear here.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            ForEach(model.contextInboxItems.prefix(6)) { item in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Text(item.source.capitalized)
                            .font(.caption.weight(.semibold))
                        Text(item.stateLabel)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(contextStateColor(item.state))
                        Spacer(minLength: 4)
                        Text(item.createdAt.formatted(date: .omitted, time: .shortened))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    Text(item.body)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(4)
                        .textSelection(.enabled)

                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 8) {
                            contextInboxButtons(item)
                        }
                        VStack(alignment: .leading, spacing: 6) {
                            contextInboxButtons(item)
                        }
                    }
                }
                .padding(8)
                .background(BarnOwlDesign.warmField, in: RoundedRectangle(cornerRadius: 8))
            }

            Button("Refresh Context") {
                Task { await model.refreshContextInbox() }
            }
            .controlSize(.small)
        }
    }

    @ViewBuilder
    private func contextInboxButtons(_ item: BarnOwlContextInboxItem) -> some View {
        Button("Accept") {
            Task { await model.setContextInboxItemState(item.id, state: .accepted) }
        }
        .controlSize(.small)
        .disabled(item.state == .accepted)

        Button("Ignore") {
            Task { await model.setContextInboxItemState(item.id, state: .ignored) }
        }
        .controlSize(.small)
        .disabled(item.state == .ignored)

        Button("Delete", role: .destructive) {
            Task { await model.deleteContextInboxItem(item.id) }
        }
        .controlSize(.small)
    }

    private func contextStateColor(_ state: BarnOwlExternalContextState) -> Color {
        switch state {
        case .pending:
            return BarnOwlDesign.amber
        case .accepted:
            return BarnOwlDesign.moss
        case .ignored:
            return .secondary
        }
    }

    private var canRunPromptUpdate: Bool {
        model.displayedNote != nil
            && !model.isNoteUpdateInFlight
            && !model.notePrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var canShowRetentionActions: Bool {
        model.displayedNote != nil || model.activeSession != nil
    }

    private var reviewFreeformContextBinding: Binding<String> {
        Binding(
            get: { model.postRecordingContextReview?.freeformContextDraft ?? "" },
            set: { model.postRecordingContextReview?.freeformContextDraft = $0 }
        )
    }

    private func sidebarWidth(for windowWidth: CGFloat) -> CGFloat {
        min(250, max(190, windowWidth * 0.23))
    }

    private func editor(
        text: Binding<String>,
        placeholder: String,
        minHeight: CGFloat,
        maxHeight: CGFloat? = nil,
        isDisabled: Bool = false
    ) -> some View {
        ZStack(alignment: .topLeading) {
            TextEditor(text: text)
                .font(.system(.body, design: .default))
                .scrollContentBackground(.hidden)
                .padding(4)
                .disabled(isDisabled)

            if text.wrappedValue.isEmpty {
                Text(placeholder)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 12)
                    .lineLimit(6)
                    .allowsHitTesting(false)
            }
        }
        .frame(minHeight: minHeight, maxHeight: maxHeight)
        .background(BarnOwlDesign.warmField, in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(BarnOwlDesign.warmStroke)
        }
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder
    private var progressSection: some View {
        if model.lifecyclePresentation.phase == .recording {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    recordingProgressTitle
                    Spacer()
                    realtimeProgressText
                }

                VStack(alignment: .leading, spacing: 6) {
                    recordingProgressTitle
                    realtimeProgressText
                }
            }
            .padding(10)
            .background(.red.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
        } else if model.lifecyclePresentation.phase == .stopping {
            VStack(alignment: .leading, spacing: 6) {
                Label("Stopping recording", systemImage: model.lifecyclePresentation.systemImage)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(BarnOwlDesign.amber)
                Text(model.captureStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(10)
            .background(BarnOwlDesign.amber.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        } else if BarnOwlProcessingTimeline.shouldCollapse(model.processingTimelineItems) {
            Label("Processed", systemImage: "checkmark.circle.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(BarnOwlDesign.moss)
                .padding(10)
                .background(BarnOwlDesign.moss.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        } else if !model.processingTimelineItems.isEmpty {
            ProcessingTimelineCard(
                items: model.processingTimelineItems,
                isCompact: false,
                onRetry: { Task { await model.retryFailedJobs() } }
            )
        } else if let progress = model.progressFraction, progress < 1 {
            ProgressView(value: progress) {
                Text("Processing transcript")
            }
            .tint(BarnOwlDesign.moss)
        }
    }

    private var recordingProgressTitle: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(.red)
                .frame(width: 8, height: 8)
            Text("Recording")
                .font(.callout.weight(.semibold))
            Text(model.recordingElapsedText)
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    private var realtimeProgressText: some View {
        Text(model.realtimeStatus)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(2)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var filteredSessions: [BarnOwlRecentSession] {
        let query = model.noteSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return model.recentSessions }
        return model.recentSessions.filter { session in
            session.title.localizedCaseInsensitiveContains(query)
                || session.overview.localizedCaseInsensitiveContains(query)
        }
    }

    private var selectedSessionBinding: Binding<UUID?> {
        Binding(
            get: { model.displayedNote?.id },
            set: { id in
                guard let id else { return }
                Task { await model.openRecentSession(id) }
            }
        )
    }

    private var displayedSessionCount: Int {
        model.noteSearchResults.isEmpty ? filteredSessions.count : model.noteSearchResults.count
    }

    private var visibleWorkspaceTabs: [RecorderWorkspaceTab] {
        if model.displayedNote == nil {
            var liveTabs: [RecorderWorkspaceTab] = [.notes]
            if model.status != .idle || !model.performanceSummaryText.isEmpty {
                liveTabs.append(.performance)
            }
            return liveTabs
        }

        var tabs: [RecorderWorkspaceTab] = [.notes, .share, .chat, .transcript, .summary]
        if !model.meetingHistoryItems.isEmpty {
            tabs.append(.history)
        }
        return tabs
    }

    private var currentWorkspaceTab: RecorderWorkspaceTab {
        visibleWorkspaceTabs.contains(selectedTab) ? selectedTab : .notes
    }

    private var shouldShowPostRecordingContextReview: Bool {
        guard model.postRecordingContextReview != nil else { return false }
        let markdown = model.displayedNote?.markdown.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return markdown.isEmpty || markdown == "No Markdown export has been generated yet."
    }

    private var hasSearchFilters: Bool {
        false
    }

    private var currentTitle: String {
        model.displayedNote?.title ?? model.activeSession?.title ?? "Barn Owl"
    }

    private var deleteConfirmationPresented: Binding<Bool> {
        Binding(
            get: { sessionPendingDeletion != nil },
            set: { isPresented in
                if !isPresented {
                    sessionPendingDeletion = nil
                }
            }
        )
    }

    private var deleteConfirmationMessage: String {
        guard let session = sessionPendingDeletion else {
            return "This removes the recording from the Barn Owl library."
        }

        return "This removes \"\(session.title)\" from the Barn Owl library, including its Markdown note and local metadata."
    }

    private var currentSubtitle: String {
        if let date = model.displayedNote?.startedAt ?? model.activeSession?.startedAt {
            return date.formatted(date: .abbreviated, time: .shortened)
        }
        return model.lifecyclePresentation.detail
    }

    private var meetingTypeLabel: String {
        let text = [
            model.displayedNote?.title,
            model.noteDraft,
            model.contextDraft
        ]
        .compactMap { $0 }
        .joined(separator: " ")
        .lowercased()

        if text.contains("customer") || text.contains("workshop") || text.contains("pitch") {
            return "Customer Workshop"
        }
        if text.contains("1:1") || text.contains("one-on-one") || text.contains("one on one") {
            return "One-on-One"
        }
        if text.contains("roadmap") || text.contains("planning") {
            return "Roadmap Sync"
        }
        if text.contains("team") || text.contains("staff") {
            return "Team Meeting"
        }
        return "General Meeting"
    }

    private var inferredFactsText: String {
        RecorderInspectorPresentation.inferredFactsText(
            meetingFacts: model.displayedNote?.meetingFacts,
            fallbackMeetingType: meetingTypeLabel,
            fallbackParticipants: participantText
        )
    }

    private var shouldShowContextInspector: Bool {
        RecorderInspectorPresentation.shouldShowInspector(
            hasDisplayedNote: model.displayedNote != nil,
            hasActiveSession: model.activeSession != nil,
            status: model.status,
            hasJobs: !model.jobSummaries.isEmpty,
            hasContextInbox: !model.contextInboxItems.isEmpty,
            hasPostRecordingReview: model.postRecordingContextReview != nil,
            hasRecoveryItems: !model.recoveryAttentionItems.isEmpty
        )
    }

    private func jobIcon(for status: BarnOwlJobStatus) -> String {
        switch status {
        case .pending: "clock"
        case .running: "arrow.trianglehead.2.clockwise"
        case .succeeded: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        case .canceled: "xmark.circle"
        }
    }

    private func jobColor(for status: BarnOwlJobStatus) -> Color {
        switch status {
        case .pending: .secondary
        case .running: BarnOwlDesign.amber
        case .succeeded: BarnOwlDesign.moss
        case .failed: .red
        case .canceled: .secondary
        }
    }

    private var transcriptText: String {
        markdownSection(namedAnyOf: ["Transcript", "Diarized Transcript", "Full Transcript"])
    }

    private var summaryText: String {
        markdownSection(namedAnyOf: ["Summary", "Overview"])
    }

    private var insightsText: String {
        [
            markdownSection(namedAnyOf: ["Action Items", "Decisions", "Open Questions"]),
            markdownSection(namedAnyOf: ["Format Focus", "Insights"])
        ]
        .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        .joined(separator: "\n\n")
    }

    private var participantText: String {
        markdownSection(namedAnyOf: ["Participants", "Attendees"])
    }

    private var performanceText: String {
        let parts = [
            model.status == .recording ? "Recording elapsed: \(model.recordingElapsedText)" : nil,
            model.realtimeStatus.isEmpty ? nil : "Realtime: \(model.realtimeStatus)",
            model.finalTranscriptionStatus == BarnOwlAppModel.finalTranscriptionIdleStatus ? nil : "High-quality: \(model.finalTranscriptionStatus)",
            model.performanceSummaryText.isEmpty ? nil : "Performance: \(model.performanceSummaryText)",
            model.captureStatus == "Idle." ? nil : "Capture: \(model.captureStatus)"
        ]
        .compactMap { $0 }

        return parts.isEmpty ? "" : parts.joined(separator: "\n")
    }

    private var externalParticipantNotesText: String {
        ExternalParticipantNotesRenderer().render(
            title: currentTitle,
            startedAt: model.displayedNote?.startedAt ?? model.activeSession?.startedAt,
            meetingFacts: model.displayedNote?.meetingFacts,
            markdown: selectedMarkdownSource
        )
    }

    private func markdownSection(namedAnyOf names: [String]) -> String {
        let markdown = selectedMarkdownSource
        let lines = markdown.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var captured: [String] = []
        var isCapturing = false
        var captureLevel: Int?

        for line in lines {
            if let heading = markdownHeading(in: line) {
                let normalized = heading.title.lowercased()
                let matches = names.contains { normalized == $0.lowercased() }
                if matches {
                    isCapturing = true
                    captureLevel = heading.level
                    continue
                }

                if isCapturing,
                   let captureLevel,
                   heading.level <= captureLevel {
                    break
                }
            }

            if isCapturing {
                captured.append(line)
            }
        }

        return captured.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var selectedMarkdownSource: String {
        model.displayedNote == nil ? model.liveTranscriptPreview : model.noteDraft
    }

    private func markdownHeading(in line: String) -> (level: Int, title: String)? {
        let hashes = line.prefix { $0 == "#" }.count
        guard hashes > 0,
              hashes < line.count,
              line.dropFirst(hashes).first == " "
        else {
            return nil
        }

        return (
            level: hashes,
            title: line.dropFirst(hashes + 1).trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    private func revealInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func copyExternalParticipantNotes() {
        let text = externalParticipantNotesText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        shareNotesCopyStatus = "Copied email notes"
    }
}

enum RecorderInspectorPresentation {
    static func shouldShowInspector(
        hasDisplayedNote: Bool,
        hasActiveSession: Bool,
        status: RecordingStatus,
        hasJobs: Bool,
        hasContextInbox: Bool,
        hasPostRecordingReview: Bool,
        hasRecoveryItems: Bool
    ) -> Bool {
        hasDisplayedNote
            || hasActiveSession
            || status == .recording
            || status == .processing
            || hasJobs
            || hasContextInbox
            || hasPostRecordingReview
            || hasRecoveryItems
    }

    static func inferredFactsText(
        meetingFacts: MeetingFacts?,
        fallbackMeetingType: String,
        fallbackParticipants: String
    ) -> String {
        if let meetingFacts,
           !meetingFacts.contextLines.isEmpty {
            let lines = meetingFacts.contextLines
                .prefix(6)
                .joined(separator: "\n")
            return "\(meetingFacts.displaySummary)\n\(lines)"
        }

        let participants = fallbackParticipants.trimmingCharacters(in: .whitespacesAndNewlines)
        if !participants.isEmpty {
            return "Barn Owl thinks this is a \(fallbackMeetingType.lowercased()) with \(participants)."
        }
        return "Barn Owl thinks this is a \(fallbackMeetingType.lowercased()). Add context only if something important is missing."
    }
}

enum RecorderWorkspacePresentation {
    static func finalTranscriptPlaceholder(
        status: RecordingStatus,
        hasProcessingTimeline: Bool
    ) -> String {
        switch status {
        case .recording:
            return "Live preview stays on the Realtime Preview tab while recording. The final diarized transcript appears here after you stop."
        case .preparing, .processing:
            return "Final diarized transcript is still processing. Realtime preview remains separate from final transcript."
        case .idle, .failed:
            if hasProcessingTimeline {
                return "Final diarized transcript is still processing. Realtime preview remains separate from final transcript."
            }
            return "No final transcript is available for this note yet."
        }
    }
}

private struct NoteToolbarAction: Identifiable {
    var id: String { title }
    var title: String
    var isDisabled: Bool
    var keyboardShortcut: String?
    var role: ButtonRole? = nil
    var perform: () -> Void
}

private struct CommandTextEditor: View {
    @Binding var text: String
    var placeholder: String
    var minHeight: CGFloat
    var maxHeight: CGFloat
    var isEnabled = true
    var onSubmit: () -> Void

    var body: some View {
        ZStack(alignment: .topLeading) {
            CommandTextEditorRepresentable(
                text: $text,
                isEnabled: isEnabled,
                onSubmit: onSubmit
            )

            if text.isEmpty {
                Text(placeholder)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .lineLimit(4)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 3)
                    .allowsHitTesting(false)
            }
        }
        .frame(minHeight: minHeight, maxHeight: maxHeight)
    }
}

private struct CommandTextEditorRepresentable: NSViewRepresentable {
    @Binding var text: String
    var isEnabled: Bool
    var onSubmit: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder

        let textView = CommandNSTextView()
        textView.delegate = context.coordinator
        textView.onSubmit = onSubmit
        textView.isRichText = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.drawsBackground = false
        textView.font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        textView.textColor = NSColor.labelColor
        textView.textContainerInset = NSSize(width: 0, height: 0)
        textView.textContainer?.lineFragmentPadding = 0
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]

        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? CommandNSTextView else { return }
        if textView.string != text {
            textView.string = text
        }
        textView.isEditable = isEnabled
        textView.onSubmit = onSubmit
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        @Binding private var text: String

        init(text: Binding<String>) {
            _text = text
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            text = textView.string
        }
    }
}

private final class CommandNSTextView: NSTextView {
    var onSubmit: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        let isReturn = event.keyCode == 36 || event.keyCode == 76
        if isReturn {
            if event.modifierFlags.contains(.command) {
                onSubmit?()
                return
            }
            if event.modifierFlags.contains(.shift) {
                super.keyDown(with: event)
                return
            }
            onSubmit?()
            return
        }
        super.keyDown(with: event)
    }
}

private struct ProcessingTimelineCard: View {
    var items: [BarnOwlProcessingTimelineItem]
    var isCompact: Bool
    var onRetry: (() -> Void)?
    @State private var showDetails = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Processing in background", systemImage: "clock.arrow.circlepath")
                    .font(.caption.weight(.semibold))
                Spacer()
                if items.contains(where: { $0.status == .failed }), let onRetry {
                    Button("Retry") { onRetry() }
                        .controlSize(.small)
                }
            }

            let visibleItems = isCompact ? Array(items.prefix(5)) : items
            ForEach(visibleItems) { item in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: icon(for: item.status))
                        .foregroundStyle(color(for: item.status))
                        .frame(width: 14)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(item.step.label)
                                .font(.caption)
                                .foregroundStyle(.primary)
                            if let elapsed = elapsedText(for: item) {
                                Text(elapsed)
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                        }
                        if item.status == .failed, let error = item.errorMessage, showDetails {
                            Text(error)
                                .font(.caption2)
                                .foregroundStyle(.red)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer(minLength: 4)
                    Text(item.status.rawValue.capitalized)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(color(for: item.status))
                }
            }

            if items.contains(where: { $0.errorMessage != nil }) {
                Button(showDetails ? "Hide Details" : "Show Details") {
                    withAnimation(.easeInOut(duration: 0.16)) {
                        showDetails.toggle()
                    }
                }
                .buttonStyle(.plain)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .background(BarnOwlDesign.moss.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(BarnOwlDesign.moss.opacity(0.14))
        }
    }

    private func icon(for status: BarnOwlProcessingTimelineStatus) -> String {
        switch status {
        case .pending: "circle"
        case .running: "arrow.triangle.2.circlepath"
        case .complete: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        }
    }

    private func color(for status: BarnOwlProcessingTimelineStatus) -> Color {
        switch status {
        case .pending: .secondary
        case .running: BarnOwlDesign.amber
        case .complete: BarnOwlDesign.moss
        case .failed: .red
        }
    }

    private func elapsedText(for item: BarnOwlProcessingTimelineItem) -> String? {
        guard let startedAt = item.startedAt else { return nil }
        let endedAt = item.completedAt ?? Date()
        let seconds = max(0, Int(endedAt.timeIntervalSince(startedAt)))
        guard seconds > 0 else { return nil }
        return seconds < 60 ? "\(seconds)s" : "\(seconds / 60)m \(seconds % 60)s"
    }
}

private struct RecoveryAttentionRow: View {
    var item: BarnOwlRecoveryAttentionItem
    var retry: () -> Void
    var dismiss: () -> Void
    @State private var showDetails = false

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundStyle(.red)
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title)
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                    Text(item.message)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 4)
            }

            HStack(spacing: 8) {
                if item.canRetry {
                    Button("Retry", action: retry)
                        .controlSize(.small)
                }
                Button("Dismiss", action: dismiss)
                    .controlSize(.small)
                if item.details?.isEmpty == false {
                    Button(showDetails ? "Hide Details" : "Details") {
                        withAnimation(.easeInOut(duration: 0.16)) {
                            showDetails.toggle()
                        }
                    }
                    .controlSize(.small)
                }
            }

            if showDetails, let details = item.details, !details.isEmpty {
                Text(details)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(8)
        .background(BarnOwlDesign.warmField, in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct SessionRow: View {
    var session: BarnOwlRecentSession
    var isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: isSelected ? "doc.text.fill" : "doc.text")
                    .foregroundStyle(isSelected ? BarnOwlDesign.amber : .secondary)
                Text(session.title)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
            }

            Text(session.startedAt.formatted(date: .abbreviated, time: .shortened))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            if session.isProcessing {
                Label(session.processingSummary, systemImage: session.processingTimeline.contains { $0.status == .failed } ? "exclamationmark.triangle" : "clock")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(session.processingTimeline.contains { $0.status == .failed } ? .red : BarnOwlDesign.amber)
                    .lineLimit(1)
            }

            Text(session.overview)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .padding(.vertical, 4)
    }
}

private struct SearchResultRow: View {
    var result: BarnOwlNoteSearchResult
    var isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: isSelected ? "magnifyingglass.circle.fill" : "magnifyingglass")
                    .foregroundStyle(isSelected ? BarnOwlDesign.amber : .secondary)
                Text(result.title)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
            }

            Text(result.startedAt.formatted(date: .abbreviated, time: .shortened))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            if result.meetingType != nil || result.status != nil {
                HStack(spacing: 5) {
                    if let meetingType = result.meetingType {
                        Text(meetingType)
                    }
                    if let status = result.status {
                        Text(status.rawValue.capitalized)
                    }
                }
                .font(.caption2.weight(.medium))
                .foregroundStyle(BarnOwlDesign.amber)
                .lineLimit(1)
            }

            Text(result.snippet)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(3)
        }
        .padding(.vertical, 4)
    }
}

private struct ChatMessageBubble: View {
    var message: BarnOwlChatMessage

    private var isUser: Bool {
        message.role == .user
    }

    var body: some View {
        VStack(alignment: isUser ? .trailing : .leading, spacing: 4) {
            Text(message.role.rawValue)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(isUser ? BarnOwlDesign.amber : .secondary)

            Text(message.text)
                .font(.callout)
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .frame(maxWidth: 560, alignment: .leading)
                .padding(10)
                .background(
                    isUser ? BarnOwlDesign.amber.opacity(0.16) : BarnOwlDesign.warmPanel,
                    in: RoundedRectangle(cornerRadius: 10)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(isUser ? BarnOwlDesign.amber.opacity(0.25) : BarnOwlDesign.warmStroke)
                }
        }
        .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
    }
}

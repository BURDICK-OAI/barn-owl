import BarnOwlCore
import BarnOwlPersistence
import Darwin
import Foundation
import Security

final class BarnOwlControlBridge: @unchecked Sendable {
    static let defaultPort: UInt16 = 8765

    private weak var model: BarnOwlAppModel?
    private let openCurrentMeeting: @MainActor () -> Void
    private let openSettings: @MainActor () -> Void
    private let port: UInt16
    private let tokenStore: BarnOwlControlBridgeTokenStore
    private var socketFileDescriptor: Int32 = -1
    private var serverTask: Task<Void, Never>?

    init(
        model: BarnOwlAppModel,
        port: UInt16 = BarnOwlControlBridge.defaultPort,
        tokenStore: BarnOwlControlBridgeTokenStore = BarnOwlControlBridgeTokenStore(),
        openCurrentMeeting: @escaping @MainActor () -> Void,
        openSettings: @escaping @MainActor () -> Void = {}
    ) {
        self.model = model
        self.port = port
        self.tokenStore = tokenStore
        self.openCurrentMeeting = openCurrentMeeting
        self.openSettings = openSettings
    }

    deinit {
        stop()
    }

    func start() {
        guard serverTask == nil else { return }
        serverTask = Task.detached(priority: .utility) { [weak self] in
            await self?.run()
        }
    }

    func stop() {
        serverTask?.cancel()
        serverTask = nil
        if socketFileDescriptor >= 0 {
            Darwin.close(socketFileDescriptor)
            socketFileDescriptor = -1
        }
    }

    private func run() async {
        guard preflightAuthorizationToken() else { return }

        let server = socket(AF_INET, SOCK_STREAM, 0)
        guard server >= 0 else {
            await logBridge(
                "Control bridge could not create its local server socket.",
                level: .warning,
                details: "errno=\(errno)"
            )
            return
        }
        socketFileDescriptor = server

        var reuse: Int32 = 1
        setsockopt(server, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(port).bigEndian
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(server, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            Darwin.close(server)
            socketFileDescriptor = -1
            await logBridge(
                "Control bridge could not bind its local loopback port.",
                level: .warning,
                details: "port=\(port) errno=\(errno)"
            )
            return
        }

        guard listen(server, 16) == 0 else {
            Darwin.close(server)
            socketFileDescriptor = -1
            await logBridge(
                "Control bridge could not listen on its local loopback port.",
                level: .warning,
                details: "port=\(port) errno=\(errno)"
            )
            return
        }

        await logBridge("Control bridge listening on 127.0.0.1:\(port).")

        while !Task.isCancelled {
            let client = accept(server, nil, nil)
            guard client >= 0 else {
                if Task.isCancelled { break }
                continue
            }
            Task.detached(priority: .utility) { [weak self] in
                await self?.handleClient(client)
            }
        }
    }

    private func preflightAuthorizationToken() -> Bool {
        do {
            _ = try tokenStore.loadOrCreateToken()
            return true
        } catch {
            Task { @MainActor [weak self] in
                self?.model?.recordExternalCommand(
                    "Control bridge could not create authorization token.",
                    level: .warning,
                    details: BarnOwlErrorFormatter.message(for: error)
                )
            }
            return false
        }
    }

    private func handleClient(_ client: Int32) async {
        defer { Darwin.close(client) }
        let requestData = readRequest(from: client)
        let response = await response(for: requestData)
        let body = (try? JSONEncoder.barnOwlControl.encode(response)) ?? Data(#"{"ok":false,"message":"Encoding failed."}"#.utf8)
        let header = """
        HTTP/1.1 \(response.ok ? "200 OK" : "400 Bad Request")\r
        Content-Type: application/json\r
        Content-Length: \(body.count)\r
        Connection: close\r
        \r

        """
        var payload = Data(header.utf8)
        payload.append(body)
        payload.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            _ = Darwin.send(client, baseAddress, payload.count, 0)
        }
    }

    private func readRequest(from client: Int32) -> Data {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        var expectedBodyLength: Int?
        while data.count < 131_072 {
            let count = recv(client, &buffer, buffer.count, 0)
            guard count > 0 else { break }
            data.append(buffer, count: count)

            if expectedBodyLength == nil,
               let headerEnd = data.range(of: Data("\r\n\r\n".utf8)) {
                let headerData = data[..<headerEnd.lowerBound]
                let headerText = String(decoding: headerData, as: UTF8.self)
                expectedBodyLength = Self.contentLength(in: headerText) ?? 0
            }

            if let expectedBodyLength,
               let headerEnd = data.range(of: Data("\r\n\r\n".utf8)) {
                let bodyStart = headerEnd.upperBound
                if data.distance(from: bodyStart, to: data.endIndex) >= expectedBodyLength {
                    break
                }
            }
        }
        return data
    }

    private func response(for data: Data) async -> BarnOwlControlResponse {
        guard let request = HTTPControlRequest(data: data) else {
            return BarnOwlControlResponse(ok: false, message: "Invalid HTTP request.", error: "invalid_request")
        }

        let command: BarnOwlControlCommand
        if request.method == "GET", request.path == "/status" {
            command = BarnOwlControlCommand(command: .getStatus)
        } else if request.method == "POST" {
            guard isAuthorized(request) else {
                return BarnOwlControlResponse(
                    ok: false,
                    message: "Barn Owl control bridge authorization failed.",
                    error: "unauthorized"
                )
            }
            do {
                command = try JSONDecoder.barnOwlControl.decode(BarnOwlControlCommand.self, from: request.body)
            } catch {
                return BarnOwlControlResponse(
                    ok: false,
                    message: "Could not decode Barn Owl command.",
                    error: BarnOwlErrorFormatter.message(for: error)
                )
            }
        } else {
            return BarnOwlControlResponse(ok: false, message: "Unsupported route.", error: "\(request.method) \(request.path)")
        }

        await logBridge("External command: \(command.command.rawValue)")
        return await handle(command)
    }

    private func isAuthorized(_ request: HTTPControlRequest) -> Bool {
        guard let token = try? tokenStore.loadOrCreateToken(),
              !token.isEmpty,
              let authorization = request.headers["authorization"]
        else {
            return false
        }
        return authorization == "Bearer \(token)"
    }

    @MainActor
    private func handle(_ command: BarnOwlControlCommand) async -> BarnOwlControlResponse {
        guard let model else {
            return BarnOwlControlResponse(ok: false, message: "Barn Owl app model is unavailable.", error: "model_unavailable")
        }

        switch command.command {
        case .getStatus:
            return await model.controlCodexStatusResponse()
        case .dashboardSnapshot:
            return await model.controlDashboardSnapshotResponse()
        case .getCurrent, .current:
            return await model.controlCurrentResponse()
        case .wait:
            if command.until?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "review" {
                return await controlContextReviewWaitResponse(
                    model: model,
                    meetingID: command.meetingID ?? command.sessionID,
                    latest: command.latest == true
                )
            }
            return await model.controlWaitSnapshotResponse(
                meetingID: command.meetingID ?? command.sessionID,
                latest: command.latest == true,
                until: command.until ?? "complete"
            )
        case .jobsList:
            return await model.controlJobsListResponse(meetingID: command.meetingID ?? command.sessionID)
        case .jobsRetry:
            return await model.controlJobsRetryResponse(
                meetingID: command.meetingID ?? command.sessionID,
                jobID: command.jobID
            )
        case .jobsDismiss:
            guard let jobID = command.jobID else {
                return model.controlStatusResponse(ok: false, message: "jobs_dismiss requires jobID.", error: "missing_job_id")
            }
            return await model.controlJobsDismissResponse(jobID: jobID)
        case .summariesRetry:
            return await model.controlSummariesRetryResponse(
                meetingID: command.meetingID ?? command.sessionID,
                all: command.all == true
            )
        case .meetingsRecent:
            return await model.controlRecentMeetingsResponse(limit: command.limit ?? 10)
        case .meetingsSearch:
            return await model.controlSearchMeetingsResponse(query: command.query ?? "", limit: command.limit ?? 10)
        case .meetingGet:
            guard let meetingID = command.meetingID ?? command.sessionID else {
                return model.controlStatusResponse(ok: false, message: "meeting_get requires meetingID.", error: "missing_meeting_id")
            }
            return await model.controlMeetingResponse(meetingID: meetingID)
        case .meetingTranscript:
            guard let meetingID = command.meetingID ?? command.sessionID else {
                return model.controlStatusResponse(ok: false, message: "meeting_transcript requires meetingID.", error: "missing_meeting_id")
            }
            return await model.controlMeetingTranscriptResponse(meetingID: meetingID)
        case .meetingNotes:
            guard let meetingID = command.meetingID ?? command.sessionID else {
                return model.controlStatusResponse(ok: false, message: "meeting_notes requires meetingID.", error: "missing_meeting_id")
            }
            return await model.controlMeetingNotesResponse(meetingID: meetingID)
        case .meetingSummary:
            guard let meetingID = command.meetingID ?? command.sessionID else {
                return model.controlStatusResponse(ok: false, message: "meeting_summary requires meetingID.", error: "missing_meeting_id")
            }
            return await model.controlMeetingSummaryResponse(meetingID: meetingID)
        case .meetingContext:
            guard let meetingID = command.meetingID ?? command.sessionID else {
                return model.controlStatusResponse(ok: false, message: "meeting_context requires meetingID.", error: "missing_meeting_id")
            }
            return await model.controlMeetingContextResponse(meetingID: meetingID)
        case .meetingContextReview:
            guard let meetingID = command.meetingID ?? command.sessionID else {
                return model.controlStatusResponse(ok: false, message: "meeting_context_review requires meetingID.", error: "missing_meeting_id")
            }
            return controlContextReviewResponse(model: model, meetingID: meetingID)
        case .meetingContextReviewApply:
            guard let meetingID = command.meetingID ?? command.sessionID else {
                return model.controlStatusResponse(ok: false, message: "meeting_context_review_apply requires meetingID.", error: "missing_meeting_id")
            }
            guard var review = matchingContextReview(model: model, meetingID: meetingID) else {
                return missingContextReviewResponse(model: model, meetingID: meetingID)
            }
            if let context = command.context {
                review.freeformContextDraft = context
                model.postRecordingContextReview = review
            }
            await model.approvePostRecordingContextReview()
            var response = model.controlStatusResponse(
                message: model.contextReviewStatus.isEmpty ? "Transcript suggestions applied." : model.contextReviewStatus,
                activeMeetingID: meetingID
            )
            response.contextReviewReady = false
            return response
        case .meetingContextReviewDismiss:
            guard let meetingID = command.meetingID ?? command.sessionID else {
                return model.controlStatusResponse(ok: false, message: "meeting_context_review_dismiss requires meetingID.", error: "missing_meeting_id")
            }
            guard matchingContextReview(model: model, meetingID: meetingID) != nil else {
                return missingContextReviewResponse(model: model, meetingID: meetingID)
            }
            model.dismissPostRecordingContextReviewForNow()
            var response = controlContextReviewResponse(model: model, meetingID: meetingID)
            response.message = model.noteActionStatus.isEmpty ? "Transcript suggestions dismissed for now." : model.noteActionStatus
            return response
        case .meetingContextReviewAcceptSuggestion:
            guard let meetingID = command.meetingID ?? command.sessionID else {
                return model.controlStatusResponse(ok: false, message: "meeting_context_review_accept_suggestion requires meetingID.", error: "missing_meeting_id")
            }
            guard matchingContextReview(model: model, meetingID: meetingID) != nil else {
                return missingContextReviewResponse(model: model, meetingID: meetingID)
            }
            guard let suggestionID = command.suggestionID else {
                return model.controlStatusResponse(ok: false, message: "meeting_context_review_accept_suggestion requires suggestionID.", error: "missing_suggestion_id")
            }
            guard await model.acceptContextEntitySuggestion(suggestionID) else {
                return model.controlStatusResponse(ok: false, message: model.noteActionStatus, activeMeetingID: meetingID, error: "context_suggestion_accept_failed")
            }
            var response = controlContextReviewResponse(model: model, meetingID: meetingID)
            response.message = model.noteActionStatus
            return response
        case .meetingContextReviewIgnoreSuggestion:
            guard let meetingID = command.meetingID ?? command.sessionID else {
                return model.controlStatusResponse(ok: false, message: "meeting_context_review_ignore_suggestion requires meetingID.", error: "missing_meeting_id")
            }
            guard matchingContextReview(model: model, meetingID: meetingID) != nil else {
                return missingContextReviewResponse(model: model, meetingID: meetingID)
            }
            guard let suggestionID = command.suggestionID else {
                return model.controlStatusResponse(ok: false, message: "meeting_context_review_ignore_suggestion requires suggestionID.", error: "missing_suggestion_id")
            }
            guard await model.ignoreContextEntitySuggestion(suggestionID) else {
                return model.controlStatusResponse(ok: false, message: model.noteActionStatus, activeMeetingID: meetingID, error: "context_suggestion_ignore_failed")
            }
            var response = controlContextReviewResponse(model: model, meetingID: meetingID)
            response.message = model.noteActionStatus
            return response
        case .meetingActions:
            guard let meetingID = command.meetingID ?? command.sessionID else {
                return model.controlStatusResponse(ok: false, message: "meeting_actions requires meetingID.", error: "missing_meeting_id")
            }
            return await model.controlMeetingActionsResponse(meetingID: meetingID)
        case .meetingDelete:
            guard command.confirmed == true else {
                return model.controlStatusResponse(ok: false, message: "meeting_delete requires confirmation.", error: "confirmation_required")
            }
            guard let meetingID = command.meetingID ?? command.sessionID else {
                return model.controlStatusResponse(ok: false, message: "meeting_delete requires meetingID.", error: "missing_meeting_id")
            }
            return await model.controlDeleteMeetingResponse(meetingID: meetingID)
        case .meetingPurgeTempAudio:
            guard command.confirmed == true else {
                return model.controlStatusResponse(ok: false, message: "meeting_purge_temp_audio requires confirmation.", error: "confirmation_required")
            }
            guard let meetingID = command.meetingID ?? command.sessionID else {
                return model.controlStatusResponse(ok: false, message: "meeting_purge_temp_audio requires meetingID.", error: "missing_meeting_id")
            }
            return await model.controlPurgeTemporaryAudioResponse(meetingID: meetingID)
        case .contextList:
            return await model.controlContextListResponse(meetingID: command.meetingID ?? command.sessionID)
        case .contextAccept:
            guard let contextItemID = command.contextItemID else {
                return model.controlStatusResponse(ok: false, message: "context_accept requires contextItemID.", error: "missing_context_item_id")
            }
            return await model.controlContextStateResponse(itemID: contextItemID, state: .accepted)
        case .contextIgnore:
            guard let contextItemID = command.contextItemID else {
                return model.controlStatusResponse(ok: false, message: "context_ignore requires contextItemID.", error: "missing_context_item_id")
            }
            return await model.controlContextStateResponse(itemID: contextItemID, state: .ignored)
        case .contextDelete:
            guard let contextItemID = command.contextItemID else {
                return model.controlStatusResponse(ok: false, message: "context_delete requires contextItemID.", error: "missing_context_item_id")
            }
            return await model.controlContextDeleteResponse(itemID: contextItemID)
        case .contextLibraryList:
            return await model.controlContextLibraryListResponse(
                kind: command.contextKind,
                query: command.query
            )
        case .contextLibraryUpsert:
            return await model.controlContextLibraryUpsertResponse(
                entryID: command.contextLibraryEntryID,
                kind: command.contextKind,
                canonicalName: command.canonicalName,
                aliases: command.aliases
            )
        case .contextLibraryDelete:
            guard let entryID = command.contextLibraryEntryID else {
                return model.controlStatusResponse(ok: false, message: "context_library_delete requires contextLibraryEntryID.", error: "missing_context_library_entry_id")
            }
            return await model.controlContextLibraryDeleteResponse(entryID: entryID)
        case .chat:
            return await model.controlChatResponse(question: command.query ?? command.prompt ?? "")
        case .diagnosticsExport:
            return await model.controlExportDeveloperDiagnosticsResponse(outputPath: command.outputPath)
        case .permissionsCheck:
            return model.controlPermissionsCheckResponse()
        case .permissionsTest:
            return await model.controlPermissionsTestResponse()
        case .setAudioSources:
            return await model.controlSetAudioSourcesResponse(
                capturesMicrophone: command.capturesMicrophone,
                capturesSystemAudio: command.capturesSystemAudio
            )
        case .startRecording, .stopRecording, .addContext, .appendContext, .setTitle, .renameMeeting, .askNotes, .openLatestMeeting:
            guard let quickCommand = command.quickCommand else {
                return model.controlStatusResponse(ok: false, message: "Unsupported quick command.", error: "unsupported_quick_command")
            }
            let response = await model.handleQuickCommand(quickCommand)
            if command.command == .openLatestMeeting, response.ok {
                openCurrentMeeting()
            }
            return response
        case .setContext:
            guard let context = command.context else {
                return model.controlStatusResponse(ok: false, message: "set_context requires context.", error: "missing_context")
            }
            let item = await model.setExternalContext(
                context,
                source: command.source ?? "cli",
                meetingID: command.sessionID,
                confidence: command.confidence
            )
            let message: String
            if let item {
                message = item.state == .accepted ? "Context set." : "Context queued for review."
            } else {
                message = "Context was not set."
            }
            return model.controlStatusResponse(
                ok: item != nil,
                message: message,
                contextItemID: item?.id
            )
        case .setMeetingType:
            guard let meetingType = command.meetingType else {
                return model.controlStatusResponse(ok: false, message: "set_meeting_type requires meeting_type.", error: "missing_meeting_type")
            }
            let ok = await model.setMeetingType(meetingType, meetingID: command.sessionID)
            return model.controlStatusResponse(ok: ok, message: ok ? "Meeting type updated." : model.noteActionStatus)
        case .updateNotes:
            guard let prompt = command.prompt else {
                return model.controlStatusResponse(ok: false, message: "update_notes requires prompt.", error: "missing_prompt")
            }
            let ok = await model.updateDisplayedNoteWithPrompt(prompt, meetingID: command.sessionID)
            return model.controlStatusResponse(ok: ok, message: model.noteActionStatus)
        case .openCurrentMeeting:
            openCurrentMeeting()
            return model.controlStatusResponse(message: "Opened Barn Owl.")
        case .openSettings:
            openSettings()
            return model.controlStatusResponse(message: "Opened Barn Owl Settings.")
        case .openNotesFolder:
            model.openLibraryInFinder()
            return model.controlStatusResponse(message: "Opened the Barn Owl notes folder.")
        }
    }

    @MainActor
    private func controlContextReviewWaitResponse(
        model: BarnOwlAppModel,
        meetingID requestedMeetingID: UUID?,
        latest: Bool
    ) async -> BarnOwlControlResponse {
        var response = await model.controlWaitSnapshotResponse(
            meetingID: requestedMeetingID,
            latest: latest,
            until: "review"
        )
        guard response.ok else { return response }

        let meetingID = requestedMeetingID ?? response.meetingID ?? response.activeMeetingID
        guard let review = matchingContextReview(model: model, meetingID: meetingID) else {
            response.contextReviewReady = false
            return response
        }

        response.message = "Wait condition satisfied: review."
        response.meetingID = review.session.id
        response.activeMeetingID = review.session.id
        response.title = review.session.title
        response.contextReview = controlContextReview(from: review)
        response.contextReviewReady = true
        response.nextCommand = "barnowl meeting context-review \(review.session.id.uuidString)"
        return response
    }

    @MainActor
    private func controlContextReviewResponse(
        model: BarnOwlAppModel,
        meetingID: UUID
    ) -> BarnOwlControlResponse {
        guard let review = matchingContextReview(model: model, meetingID: meetingID) else {
            return missingContextReviewResponse(model: model, meetingID: meetingID)
        }
        var response = model.controlStatusResponse(
            message: "Transcript suggestions are ready.",
            activeMeetingID: meetingID,
            nextCommand: "barnowl meeting context-review apply \(meetingID.uuidString)"
        )
        response.meetingID = meetingID
        response.contextReview = controlContextReview(from: review)
        response.contextReviewReady = true
        return response
    }

    @MainActor
    private func missingContextReviewResponse(
        model: BarnOwlAppModel,
        meetingID: UUID
    ) -> BarnOwlControlResponse {
        var response = model.controlStatusResponse(
            message: "No transcript suggestions are ready for this meeting.",
            activeMeetingID: meetingID
        )
        response.ok = false
        response.meetingID = meetingID
        response.contextReviewReady = false
        response.errorCode = "context_review_not_found"
        response.error = "context_review_not_found"
        return response
    }

    @MainActor
    private func matchingContextReview(
        model: BarnOwlAppModel,
        meetingID: UUID?
    ) -> BarnOwlPostRecordingContextReview? {
        guard let review = model.postRecordingContextReview else { return nil }
        guard meetingID == nil || review.session.id == meetingID else { return nil }
        return review
    }

    @MainActor
    private func controlContextReview(from review: BarnOwlPostRecordingContextReview) -> BarnOwlContextReview {
        BarnOwlContextReview(
            meetingID: review.session.id,
            suggestedSummary: review.suggestedSummary,
            prompts: review.prompts,
            facts: review.facts,
            entitySuggestions: review.entitySuggestions
        )
    }

    @MainActor
    private func logBridge(
        _ message: String,
        level: DiagnosticsLogLevel = .info,
        details: String? = nil
    ) {
        model?.recordExternalCommand(message, level: level, details: details)
    }

    private static func contentLength(in headerText: String) -> Int? {
        for line in headerText.split(separator: "\r\n") {
            let parts = line.split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2,
                  parts[0].trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare("Content-Length") == .orderedSame
            else {
                continue
            }
            return Int(parts[1].trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return nil
    }
}

struct BarnOwlControlBridgeTokenStore: Sendable {
    var tokenFileURL: URL

    init(tokenFileURL: URL? = nil) {
        self.tokenFileURL = tokenFileURL ?? Self.defaultTokenFileURL()
    }

    func loadOrCreateToken() throws -> String {
        let fileManager = FileManager.default
        let directory = tokenFileURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path(percentEncoded: false))

        if fileManager.fileExists(atPath: tokenFileURL.path(percentEncoded: false)),
           let token = try? String(contentsOf: tokenFileURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !token.isEmpty {
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tokenFileURL.path(percentEncoded: false))
            return token
        }

        let token = try Self.generateToken()
        try token.appending("\n").write(to: tokenFileURL, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tokenFileURL.path(percentEncoded: false))
        return token
    }

    private static func defaultTokenFileURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library", directoryHint: .isDirectory)
            .appending(path: "Application Support", directoryHint: .isDirectory)
            .appending(path: "Barn Owl", directoryHint: .isDirectory)
            .appending(path: "control-bridge-token", directoryHint: .notDirectory)
    }

    private static func generateToken() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else {
            throw POSIXError(.EIO)
        }
        return Data(bytes)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

private struct HTTPControlRequest {
    var method: String
    var path: String
    var headers: [String: String]
    var body: Data

    init?(data: Data) {
        guard let headerEnd = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let headerText = String(decoding: data[..<headerEnd.lowerBound], as: UTF8.self)
        guard let requestLine = headerText.split(separator: "\r\n").first else { return nil }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else { return nil }
        method = String(parts[0]).uppercased()
        path = String(parts[1])
        headers = [:]
        for (key, value) in headerText
            .split(separator: "\r\n")
            .dropFirst()
            .compactMap({ line -> (String, String)? in
                let parts = line.split(separator: ":", maxSplits: 1).map(String.init)
                guard parts.count == 2 else { return nil }
                return (
                    parts[0].trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
                    parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
                )
            }) {
            headers[key] = value
        }
        body = Data(data[headerEnd.upperBound...])
    }
}

private extension JSONEncoder {
    static var barnOwlControl: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

private extension JSONDecoder {
    static var barnOwlControl: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

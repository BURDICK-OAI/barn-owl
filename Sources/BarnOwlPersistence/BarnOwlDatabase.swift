import BarnOwlCore
import BarnOwlTranscription
import Foundation
import SQLite3

private final class SQLiteDatabaseHandle: @unchecked Sendable {
    let pointer: OpaquePointer?

    init(_ pointer: OpaquePointer?) {
        self.pointer = pointer
    }

    deinit {
        sqlite3_close(pointer)
    }
}

public enum BarnOwlDatabaseError: Error, Equatable, Sendable {
    case openFailed(path: String, message: String)
    case prepareFailed(sql: String, message: String)
    case bindFailed(sql: String, index: Int32, message: String)
    case stepFailed(sql: String, message: String)
    case invalidUUID(String)
}

public actor BarnOwlDatabase {
    public static let latestSchemaVersion = 5

    private let url: URL
    private let database: SQLiteDatabaseHandle

    public nonisolated var databaseURL: URL {
        url
    }

    public init(url: URL) throws {
        self.url = url
        try Self.createPrivateDirectory(at: url.deletingLastPathComponent())

        var database: OpaquePointer?
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        if sqlite3_open_v2(url.path(percentEncoded: false), &database, flags, nil) != SQLITE_OK {
            let message = database.map { String(cString: sqlite3_errmsg($0)) } ?? "Unknown SQLite error"
            sqlite3_close(database)
            throw BarnOwlDatabaseError.openFailed(path: url.path(percentEncoded: false), message: message)
        }

        self.database = SQLiteDatabaseHandle(database)
        try Self.migrateToLatestSchema(database: database)
        try Self.protectPrivateFile(at: url)
    }

    public static func inMemory() throws -> BarnOwlDatabase {
        try BarnOwlDatabase(memoryIdentifier: ":memory:")
    }

    private init(memoryIdentifier: String) throws {
        self.url = URL(fileURLWithPath: ":memory:")

        var database: OpaquePointer?
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        if sqlite3_open_v2(memoryIdentifier, &database, flags, nil) != SQLITE_OK {
            let message = database.map { String(cString: sqlite3_errmsg($0)) } ?? "Unknown SQLite error"
            sqlite3_close(database)
            throw BarnOwlDatabaseError.openFailed(path: memoryIdentifier, message: message)
        }

        self.database = SQLiteDatabaseHandle(database)
        try Self.migrateToLatestSchema(database: database)
    }

    private static func createPrivateDirectory(at url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: url.path(percentEncoded: false)
        )
    }

    private static func protectPrivateFile(at url: URL) throws {
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path(percentEncoded: false)
        )
    }

    public func schemaVersion() throws -> Int {
        try intValue("PRAGMA user_version") ?? 0
    }

    public func upsertMeeting(_ meeting: BarnOwlMeetingRecord) throws {
        try withStatement(
            """
            INSERT INTO meetings (
                id, external_id, title, started_at, ended_at, created_at, updated_at, metadata_json
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                external_id = excluded.external_id,
                title = excluded.title,
                started_at = excluded.started_at,
                ended_at = excluded.ended_at,
                updated_at = excluded.updated_at,
                metadata_json = excluded.metadata_json
            """
        ) { statement, sql in
            try bind(meeting.id, at: 1, in: statement, sql: sql)
            try bind(meeting.externalID, at: 2, in: statement, sql: sql)
            try bind(meeting.title, at: 3, in: statement, sql: sql)
            try bind(meeting.startedAt, at: 4, in: statement, sql: sql)
            try bind(meeting.endedAt, at: 5, in: statement, sql: sql)
            try bind(meeting.createdAt, at: 6, in: statement, sql: sql)
            try bind(meeting.updatedAt, at: 7, in: statement, sql: sql)
            try bind(meeting.metadataJSON, at: 8, in: statement, sql: sql)
            try stepDone(statement, sql: sql)
        }
    }

    public func meeting(id: UUID) throws -> BarnOwlMeetingRecord? {
        try withStatement("SELECT * FROM meetings WHERE id = ?") { statement, sql in
            try bind(id, at: 1, in: statement, sql: sql)
            guard sqlite3_step(statement) == SQLITE_ROW else {
                return nil
            }
            return try readMeeting(statement)
        }
    }

    public func deleteMeeting(id: UUID) throws {
        try withStatement("DELETE FROM meetings WHERE id = ?") { statement, sql in
            try bind(id, at: 1, in: statement, sql: sql)
            try stepDone(statement, sql: sql)
        }
    }

    public func meetings(limit: Int = 50) throws -> [BarnOwlMeetingRecord] {
        try withStatement("SELECT * FROM meetings ORDER BY COALESCE(started_at, created_at) DESC, id ASC LIMIT ?") { statement, sql in
            try bind(max(0, limit), at: 1, in: statement, sql: sql)
            return try readRows(statement, sql: sql, readMeeting)
        }
    }

    public func meetingState(id: UUID) throws -> BarnOwlMeetingState? {
        guard let meeting = try meeting(id: id) else {
            return nil
        }
        return try meetingState(from: meeting)
    }

    public func meetingStates(limit: Int = 50) throws -> [BarnOwlMeetingState] {
        try meetings(limit: limit).map { try meetingState(from: $0) }
    }

    public func upsertMeetingState(_ state: BarnOwlMeetingState) throws {
        try upsertMeeting(state.meeting)
        for session in state.recordingSessions {
            try upsertRecordingSession(session)
        }
        try upsertTranscriptSegments(state.transcriptSegments)
        for contextItem in state.externalContextItems {
            try upsertExternalContextItem(contextItem)
        }
        for job in state.jobs {
            try upsertJob(job)
        }
        if let factsJSON = state.meetingFacts?.encodedJSONString() {
            try replaceMeetingOutput(BarnOwlMeetingOutputRecord(
                meetingID: state.id,
                kind: "meeting_facts",
                content: factsJSON,
                contentType: "application/json",
                updatedAt: state.updatedAt,
                metadataJSON: #"{"source":"meeting-state"}"#
            ))
        }
        if !state.generatedNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            try replaceMeetingOutput(BarnOwlMeetingOutputRecord(
                meetingID: state.id,
                kind: "markdown",
                content: state.generatedNotes,
                contentType: "text/markdown",
                updatedAt: state.updatedAt,
                metadataJSON: #"{"source":"meeting-state"}"#
            ))
        }
        if let summary = state.summary {
            try replaceMeetingOutput(BarnOwlMeetingOutputRecord(
                meetingID: state.id,
                kind: "summary",
                content: summary.overview,
                contentType: "text/plain",
                updatedAt: state.updatedAt,
                metadataJSON: #"{"source":"meeting-state"}"#
            ))
        }
        if !state.realtimePreview.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            try replaceMeetingOutput(BarnOwlMeetingOutputRecord(
                meetingID: state.id,
                kind: "realtime_preview",
                content: state.realtimePreview,
                contentType: "text/plain",
                updatedAt: state.updatedAt,
                metadataJSON: #"{"source":"meeting-state"}"#
            ))
        }
        if !state.realtimeStatus.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            try replaceMeetingOutput(BarnOwlMeetingOutputRecord(
                meetingID: state.id,
                kind: "realtime_status",
                content: state.realtimeStatus,
                contentType: "text/plain",
                updatedAt: state.updatedAt,
                metadataJSON: #"{"source":"meeting-state"}"#
            ))
        }
        let singletonKinds: Set<String> = [
            "markdown",
            "summary",
            "meeting_facts",
            "realtime_preview",
            "realtime_status",
            "processing_stage"
        ]
        for artifact in state.artifacts where !singletonKinds.contains(artifact.kind) {
            try upsertMeetingOutput(BarnOwlMeetingOutputRecord(
                id: artifact.id,
                meetingID: artifact.meetingID,
                kind: artifact.kind,
                content: artifact.content,
                contentType: artifact.contentType,
                createdAt: artifact.createdAt,
                updatedAt: artifact.updatedAt,
                metadataJSON: artifact.metadataJSON
            ))
        }
    }

    public func updateMeetingStateTitle(
        meetingID: UUID,
        title: String,
        actor: BarnOwlMeetingVersionActor? = nil,
        summary: String? = nil
    ) throws -> BarnOwlMeetingState? {
        guard var state = try meetingState(id: meetingID) else {
            return nil
        }
        let before = BarnOwlMeetingVersionSnapshot(state: state)
        var meeting = state.meeting
        meeting.title = title
        meeting.updatedAt = Self.nextUpdatedAt(after: state.updatedAt)
        if var facts = state.meetingFacts {
            facts.title = title
            state.meetingFacts = facts
        }
        state.meeting = meeting
        state.updatedAt = meeting.updatedAt
        try upsertMeetingState(state)
        let afterState = try meetingState(id: meetingID)
        if let actor, let afterState {
            try recordMeetingVersion(
                meetingID: meetingID,
                actor: actor,
                changeType: .titleRename,
                summary: summary ?? "Renamed meeting to \(title).",
                before: before,
                after: BarnOwlMeetingVersionSnapshot(state: afterState)
            )
        }
        return afterState
    }

    public func updateMeetingStateNotes(
        meetingID: UUID,
        markdown: String,
        actor: BarnOwlMeetingVersionActor? = nil,
        changeType: BarnOwlMeetingVersionChangeType = .noteRewrite,
        summary: String? = nil
    ) throws -> BarnOwlMeetingState? {
        guard var state = try meetingState(id: meetingID) else {
            return nil
        }
        let before = BarnOwlMeetingVersionSnapshot(state: state)
        state.generatedNotes = markdown
        state.updatedAt = Self.nextUpdatedAt(after: state.updatedAt)
        try replaceMeetingOutput(BarnOwlMeetingOutputRecord(
            meetingID: meetingID,
            kind: "markdown",
            content: markdown,
            contentType: "text/markdown",
            updatedAt: state.updatedAt,
            metadataJSON: #"{"source":"meeting-state-user-edit"}"#
        ))
        let afterState = try meetingState(id: meetingID)
        if let actor, let afterState {
            try recordMeetingVersion(
                meetingID: meetingID,
                actor: actor,
                changeType: changeType,
                summary: summary ?? "Updated meeting notes.",
                before: before,
                after: BarnOwlMeetingVersionSnapshot(state: afterState)
            )
        }
        return afterState
    }

    public func updateMeetingStateFacts(
        meetingID: UUID,
        facts: MeetingFacts,
        actor: BarnOwlMeetingVersionActor? = nil,
        changeType: BarnOwlMeetingVersionChangeType = .meetingFactsUpdate,
        summary: String? = nil
    ) throws -> BarnOwlMeetingState? {
        guard var state = try meetingState(id: meetingID) else {
            return nil
        }
        let before = BarnOwlMeetingVersionSnapshot(state: state)
        var meeting = state.meeting
        if let title = MeetingFacts.clean(facts.title) {
            meeting.title = title
        }
        meeting.updatedAt = Self.nextUpdatedAt(after: state.updatedAt)
        state.meeting = meeting
        state.meetingFacts = facts
        state.updatedAt = meeting.updatedAt
        try upsertMeetingState(state)
        let afterState = try meetingState(id: meetingID)
        if let actor, let afterState {
            try recordMeetingVersion(
                meetingID: meetingID,
                actor: actor,
                changeType: changeType,
                summary: summary ?? "Updated meeting facts.",
                before: before,
                after: BarnOwlMeetingVersionSnapshot(state: afterState)
            )
        }
        return afterState
    }

    public func searchLibrary(_ query: BarnOwlDatabaseSearchQuery) throws -> [BarnOwlDatabaseSearchResult] {
        let normalizedQuery = query.text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let states = try meetingStates(limit: max(query.limit * 8, 100))
        var results: [BarnOwlDatabaseSearchResult] = []

        for state in states {
            var meeting = state.meeting
            meeting.title = state.title
            if let startedAfter = query.startedAfter,
               let startedAt = meeting.startedAt,
               startedAt < startedAfter {
                continue
            }
            if let startedBefore = query.startedBefore,
               let startedAt = meeting.startedAt,
               startedAt > startedBefore {
                continue
            }

            let meetingFacts = state.meetingFacts
            let meetingType = meetingFacts?.meetingType
            let participants = MeetingFacts.normalizedList(meetingFacts?.participants ?? [])
            let factsText = meetingFacts?.contextLines.joined(separator: "\n") ?? ""

            if let statusFilter = query.status,
               state.status != statusFilter {
                continue
            }
            if let meetingTypeFilter = query.meetingType?.trimmingCharacters(in: .whitespacesAndNewlines),
               !meetingTypeFilter.isEmpty,
               meetingType?.localizedCaseInsensitiveContains(meetingTypeFilter) != true {
                continue
            }
            if let participantFilter = query.participant?.trimmingCharacters(in: .whitespacesAndNewlines),
               !participantFilter.isEmpty,
               !participants.contains(where: { $0.localizedCaseInsensitiveContains(participantFilter) }) {
                continue
            }

            let fields: [(name: String, text: String, weight: Double)] = [
                ("title", state.title, 5),
                ("summary", state.summary?.overview ?? "", 4),
                ("markdown", state.generatedNotes, 3),
                ("meeting-facts", factsText, 3),
                ("decisions", state.decisions.joined(separator: "\n"), 3),
                ("actions", state.actionItems.joined(separator: "\n"), 3),
                ("open-questions", state.openQuestions.joined(separator: "\n"), 2),
                ("transcript", state.transcriptSegments.map(\.text).joined(separator: "\n"), 2),
                ("participants", participants.joined(separator: ", "), 2),
                ("external-context", state.externalContextItems.map(\.body).joined(separator: "\n"), 2)
            ]

            var matchedFields: [String] = []
            var score = normalizedQuery.isEmpty ? 0.1 : 0
            var snippet = ""
            for field in fields {
                guard !field.text.isEmpty else { continue }
                let lowercased = field.text.lowercased()
                if normalizedQuery.isEmpty || lowercased.contains(normalizedQuery) {
                    matchedFields.append(field.name)
                    score += normalizedQuery.isEmpty ? field.weight * 0.05 : field.weight
                    if snippet.isEmpty {
                        snippet = Self.snippet(in: field.text, query: normalizedQuery)
                    }
                }
            }

            guard normalizedQuery.isEmpty || score > 0 else { continue }
            if snippet.isEmpty {
                snippet = state.summary?.overview ?? state.title
            }
            results.append(BarnOwlDatabaseSearchResult(
                meeting: meeting,
                snippet: snippet,
                matchedFields: matchedFields,
                score: score,
                meetingType: meetingType,
                status: state.status
            ))
        }

        return Array(results
            .sorted {
                if $0.score == $1.score {
                    return ($0.meeting.startedAt ?? $0.meeting.createdAt) > ($1.meeting.startedAt ?? $1.meeting.createdAt)
                }
                return $0.score > $1.score
            }
            .prefix(max(0, query.limit)))
    }

    public func upsertRecordingSession(_ session: BarnOwlRecordingSessionRecord) throws {
        try withStatement(
            """
            INSERT INTO recording_sessions (
                id, meeting_id, status, started_at, ended_at, audio_sources_json, created_at, updated_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                meeting_id = excluded.meeting_id,
                status = excluded.status,
                started_at = excluded.started_at,
                ended_at = excluded.ended_at,
                audio_sources_json = excluded.audio_sources_json,
                updated_at = excluded.updated_at
            """
        ) { statement, sql in
            try bind(session.id, at: 1, in: statement, sql: sql)
            try bind(session.meetingID, at: 2, in: statement, sql: sql)
            try bind(session.status.rawValue, at: 3, in: statement, sql: sql)
            try bind(session.startedAt, at: 4, in: statement, sql: sql)
            try bind(session.endedAt, at: 5, in: statement, sql: sql)
            try bind(session.audioSourcesJSON, at: 6, in: statement, sql: sql)
            try bind(session.createdAt, at: 7, in: statement, sql: sql)
            try bind(session.updatedAt, at: 8, in: statement, sql: sql)
            try stepDone(statement, sql: sql)
        }
    }

    public func recordingSession(id: UUID) throws -> BarnOwlRecordingSessionRecord? {
        try withStatement("SELECT * FROM recording_sessions WHERE id = ?") { statement, sql in
            try bind(id, at: 1, in: statement, sql: sql)
            guard sqlite3_step(statement) == SQLITE_ROW else {
                return nil
            }
            return try readRecordingSession(statement)
        }
    }

    public func recordingSessions(meetingID: UUID) throws -> [BarnOwlRecordingSessionRecord] {
        try withStatement("SELECT * FROM recording_sessions WHERE meeting_id = ? ORDER BY started_at ASC, id ASC") { statement, sql in
            try bind(meetingID, at: 1, in: statement, sql: sql)
            return try readRows(statement, sql: sql, readRecordingSession)
        }
    }

    public func upsertTranscriptSegment(_ segment: BarnOwlTranscriptSegmentRecord) throws {
        try upsertTranscriptSegments([segment])
    }

    public func upsertTranscriptSegments(_ segments: [BarnOwlTranscriptSegmentRecord]) throws {
        guard segments.isEmpty == false else {
            return
        }

        try transaction {
            for segment in segments {
                try withStatement(
                    """
                    INSERT INTO transcript_segments (
                        id, meeting_id, session_id, variant, sequence, speaker_label, text, start_time, end_time,
                        confidence, created_at, updated_at
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET
                        meeting_id = excluded.meeting_id,
                        session_id = excluded.session_id,
                        variant = excluded.variant,
                        sequence = excluded.sequence,
                        speaker_label = excluded.speaker_label,
                        text = excluded.text,
                        start_time = excluded.start_time,
                        end_time = excluded.end_time,
                        confidence = excluded.confidence,
                        updated_at = excluded.updated_at
                    """
                ) { statement, sql in
                    try bind(segment.id, at: 1, in: statement, sql: sql)
                    try bind(segment.meetingID, at: 2, in: statement, sql: sql)
                    try bind(segment.sessionID, at: 3, in: statement, sql: sql)
                    try bind(segment.variant.rawValue, at: 4, in: statement, sql: sql)
                    try bind(segment.sequence, at: 5, in: statement, sql: sql)
                    try bind(segment.speakerLabel, at: 6, in: statement, sql: sql)
                    try bind(segment.text, at: 7, in: statement, sql: sql)
                    try bind(segment.startTime, at: 8, in: statement, sql: sql)
                    try bind(segment.endTime, at: 9, in: statement, sql: sql)
                    try bind(segment.confidence, at: 10, in: statement, sql: sql)
                    try bind(segment.createdAt, at: 11, in: statement, sql: sql)
                    try bind(segment.updatedAt, at: 12, in: statement, sql: sql)
                    try stepDone(statement, sql: sql)
                }
            }
        }
    }

    public func transcriptSegments(
        meetingID: UUID,
        sessionID: UUID? = nil,
        variant: BarnOwlTranscriptVariant? = nil
    ) throws -> [BarnOwlTranscriptSegmentRecord] {
        if let sessionID {
            let variantFilter = variant == nil ? "" : " AND variant = ?"
            return try withStatement("SELECT * FROM transcript_segments WHERE meeting_id = ? AND session_id = ?\(variantFilter) ORDER BY sequence ASC, start_time ASC, id ASC") { statement, sql in
                try bind(meetingID, at: 1, in: statement, sql: sql)
                try bind(sessionID, at: 2, in: statement, sql: sql)
                if let variant {
                    try bind(variant.rawValue, at: 3, in: statement, sql: sql)
                }
                return try readRows(statement, sql: sql, readTranscriptSegment)
            }
        }

        let variantFilter = variant == nil ? "" : " AND variant = ?"
        return try withStatement("SELECT * FROM transcript_segments WHERE meeting_id = ?\(variantFilter) ORDER BY sequence ASC, start_time ASC, id ASC") { statement, sql in
            try bind(meetingID, at: 1, in: statement, sql: sql)
            if let variant {
                try bind(variant.rawValue, at: 2, in: statement, sql: sql)
            }
            return try readRows(statement, sql: sql, readTranscriptSegment)
        }
    }

    public func upsertMeetingOutput(_ output: BarnOwlMeetingOutputRecord) throws {
        try withStatement(
            """
            INSERT INTO meeting_outputs (
                id, meeting_id, kind, content, content_type, created_at, updated_at, metadata_json
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                meeting_id = excluded.meeting_id,
                kind = excluded.kind,
                content = excluded.content,
                content_type = excluded.content_type,
                updated_at = excluded.updated_at,
                metadata_json = excluded.metadata_json
            """
        ) { statement, sql in
            try bind(output.id, at: 1, in: statement, sql: sql)
            try bind(output.meetingID, at: 2, in: statement, sql: sql)
            try bind(output.kind, at: 3, in: statement, sql: sql)
            try bind(output.content, at: 4, in: statement, sql: sql)
            try bind(output.contentType, at: 5, in: statement, sql: sql)
            try bind(output.createdAt, at: 6, in: statement, sql: sql)
            try bind(output.updatedAt, at: 7, in: statement, sql: sql)
            try bind(output.metadataJSON, at: 8, in: statement, sql: sql)
            try stepDone(statement, sql: sql)
        }
    }

    public func replaceMeetingOutput(_ output: BarnOwlMeetingOutputRecord) throws {
        try transaction {
            try withStatement("DELETE FROM meeting_outputs WHERE meeting_id = ? AND kind = ?") { statement, sql in
                try bind(output.meetingID, at: 1, in: statement, sql: sql)
                try bind(output.kind, at: 2, in: statement, sql: sql)
                try stepDone(statement, sql: sql)
            }
            try upsertMeetingOutput(output)
        }
    }

    public func meetingOutputs(meetingID: UUID, kind: String? = nil) throws -> [BarnOwlMeetingOutputRecord] {
        if let kind {
            return try withStatement(
                "SELECT * FROM meeting_outputs WHERE meeting_id = ? AND kind = ? ORDER BY updated_at DESC, id ASC"
            ) { statement, sql in
                try bind(meetingID, at: 1, in: statement, sql: sql)
                try bind(kind, at: 2, in: statement, sql: sql)
                return try readRows(statement, sql: sql, readMeetingOutput)
            }
        }

        return try withStatement("SELECT * FROM meeting_outputs WHERE meeting_id = ? ORDER BY updated_at DESC, id ASC") { statement, sql in
            try bind(meetingID, at: 1, in: statement, sql: sql)
            return try readRows(statement, sql: sql, readMeetingOutput)
        }
    }

    public func deleteMeetingOutput(meetingID: UUID, kind: String) throws {
        try withStatement("DELETE FROM meeting_outputs WHERE meeting_id = ? AND kind = ?") { statement, sql in
            try bind(meetingID, at: 1, in: statement, sql: sql)
            try bind(kind, at: 2, in: statement, sql: sql)
            try stepDone(statement, sql: sql)
        }
    }

    public func upsertJob(_ job: BarnOwlJobRecord) throws {
        try withStatement(
            """
            INSERT INTO jobs (
                id, meeting_id, type, status, priority, attempt_count, payload_json, error_message,
                created_at, updated_at, scheduled_at, started_at, completed_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                meeting_id = excluded.meeting_id,
                type = excluded.type,
                status = excluded.status,
                priority = excluded.priority,
                attempt_count = excluded.attempt_count,
                payload_json = excluded.payload_json,
                error_message = excluded.error_message,
                updated_at = excluded.updated_at,
                scheduled_at = excluded.scheduled_at,
                started_at = excluded.started_at,
                completed_at = excluded.completed_at
            """
        ) { statement, sql in
            try bind(job.id, at: 1, in: statement, sql: sql)
            try bind(job.meetingID, at: 2, in: statement, sql: sql)
            try bind(job.type, at: 3, in: statement, sql: sql)
            try bind(job.status.rawValue, at: 4, in: statement, sql: sql)
            try bind(job.priority, at: 5, in: statement, sql: sql)
            try bind(job.attemptCount, at: 6, in: statement, sql: sql)
            try bind(job.payloadJSON, at: 7, in: statement, sql: sql)
            try bind(job.errorMessage, at: 8, in: statement, sql: sql)
            try bind(job.createdAt, at: 9, in: statement, sql: sql)
            try bind(job.updatedAt, at: 10, in: statement, sql: sql)
            try bind(job.scheduledAt, at: 11, in: statement, sql: sql)
            try bind(job.startedAt, at: 12, in: statement, sql: sql)
            try bind(job.completedAt, at: 13, in: statement, sql: sql)
            try stepDone(statement, sql: sql)
        }
    }

    public func job(id: UUID) throws -> BarnOwlJobRecord? {
        try withStatement("SELECT * FROM jobs WHERE id = ?") { statement, sql in
            try bind(id, at: 1, in: statement, sql: sql)
            guard sqlite3_step(statement) == SQLITE_ROW else {
                return nil
            }
            return try readJob(statement)
        }
    }

    public func jobs(
        status: BarnOwlJobStatus? = nil,
        meetingID: UUID? = nil,
        limit: Int = 50
    ) throws -> [BarnOwlJobRecord] {
        var filters: [String] = []
        if status != nil {
            filters.append("status = ?")
        }
        if meetingID != nil {
            filters.append("meeting_id = ?")
        }

        let whereClause = filters.isEmpty ? "" : " WHERE \(filters.joined(separator: " AND "))"
        let sql = """
        SELECT * FROM jobs\(whereClause)
        ORDER BY priority DESC, COALESCE(scheduled_at, created_at) ASC, created_at ASC, id ASC
        LIMIT ?
        """

        return try withStatement(sql) { statement, sql in
            var index: Int32 = 1
            if let status {
                try bind(status.rawValue, at: index, in: statement, sql: sql)
                index += 1
            }
            if let meetingID {
                try bind(meetingID, at: index, in: statement, sql: sql)
                index += 1
            }
            try bind(max(0, limit), at: index, in: statement, sql: sql)
            return try readRows(statement, sql: sql, readJob)
        }
    }

    public func claimNextPendingJob(now: Date = Date()) throws -> BarnOwlJobRecord? {
        var claimedJob: BarnOwlJobRecord?
        try transaction {
            let nextJob = try withStatement(
                """
                SELECT * FROM jobs
                WHERE status = ? AND (scheduled_at IS NULL OR scheduled_at <= ?)
                ORDER BY priority DESC, COALESCE(scheduled_at, created_at) ASC, created_at ASC, id ASC
                LIMIT 1
                """
            ) { statement, sql in
                try bind(BarnOwlJobStatus.pending.rawValue, at: 1, in: statement, sql: sql)
                try bind(now, at: 2, in: statement, sql: sql)
                guard sqlite3_step(statement) == SQLITE_ROW else {
                    return nil as BarnOwlJobRecord?
                }
                return try readJob(statement)
            }

            guard var job = nextJob else { return }
            job.status = .running
            job.attemptCount += 1
            job.startedAt = now
            job.updatedAt = now
            try upsertJob(job)
            claimedJob = job
        }
        return claimedJob
    }

    public func upsertJobChunk(_ chunk: BarnOwlJobChunkRecord) throws {
        try withStatement(
            """
            INSERT INTO job_chunks (
                id, job_id, sequence, status, payload_json, result_json, error_message, created_at, updated_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                job_id = excluded.job_id,
                sequence = excluded.sequence,
                status = excluded.status,
                payload_json = excluded.payload_json,
                result_json = excluded.result_json,
                error_message = excluded.error_message,
                updated_at = excluded.updated_at
            """
        ) { statement, sql in
            try bind(chunk.id, at: 1, in: statement, sql: sql)
            try bind(chunk.jobID, at: 2, in: statement, sql: sql)
            try bind(chunk.sequence, at: 3, in: statement, sql: sql)
            try bind(chunk.status.rawValue, at: 4, in: statement, sql: sql)
            try bind(chunk.payloadJSON, at: 5, in: statement, sql: sql)
            try bind(chunk.resultJSON, at: 6, in: statement, sql: sql)
            try bind(chunk.errorMessage, at: 7, in: statement, sql: sql)
            try bind(chunk.createdAt, at: 8, in: statement, sql: sql)
            try bind(chunk.updatedAt, at: 9, in: statement, sql: sql)
            try stepDone(statement, sql: sql)
        }
    }

    public func jobChunks(jobID: UUID) throws -> [BarnOwlJobChunkRecord] {
        try withStatement("SELECT * FROM job_chunks WHERE job_id = ? ORDER BY sequence ASC, id ASC") { statement, sql in
            try bind(jobID, at: 1, in: statement, sql: sql)
            return try readRows(statement, sql: sql, readJobChunk)
        }
    }

    public func upsertRollingTranscription(_ record: BarnOwlRollingTranscriptionRecord) throws {
        try withStatement(
            """
            INSERT INTO rolling_transcription_chunks (
                id, session_id, track_id, sequence_number, track_label, audio_file_path,
                start_time_offset, duration, overlap_duration, model_identifier, status,
                error_message, response_json, created_at, updated_at, completed_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(session_id, track_id, sequence_number) DO UPDATE SET
                track_label = excluded.track_label,
                audio_file_path = COALESCE(excluded.audio_file_path, rolling_transcription_chunks.audio_file_path),
                start_time_offset = excluded.start_time_offset,
                duration = excluded.duration,
                overlap_duration = excluded.overlap_duration,
                model_identifier = excluded.model_identifier,
                status = excluded.status,
                error_message = excluded.error_message,
                response_json = excluded.response_json,
                updated_at = excluded.updated_at,
                completed_at = excluded.completed_at
            """
        ) { statement, sql in
            try bind(record.id, at: 1, in: statement, sql: sql)
            try bind(record.sessionID, at: 2, in: statement, sql: sql)
            try bind(record.trackID, at: 3, in: statement, sql: sql)
            try bind(record.sequenceNumber, at: 4, in: statement, sql: sql)
            try bind(record.trackLabel, at: 5, in: statement, sql: sql)
            try bind(record.audioFilePath, at: 6, in: statement, sql: sql)
            try bind(record.startTimeOffset, at: 7, in: statement, sql: sql)
            try bind(record.duration, at: 8, in: statement, sql: sql)
            try bind(record.overlapDuration, at: 9, in: statement, sql: sql)
            try bind(record.modelIdentifier, at: 10, in: statement, sql: sql)
            try bind(record.status.rawValue, at: 11, in: statement, sql: sql)
            try bind(record.errorMessage, at: 12, in: statement, sql: sql)
            try bind(record.responseJSON, at: 13, in: statement, sql: sql)
            try bind(record.createdAt, at: 14, in: statement, sql: sql)
            try bind(record.updatedAt, at: 15, in: statement, sql: sql)
            try bind(record.completedAt, at: 16, in: statement, sql: sql)
            try stepDone(statement, sql: sql)
        }
    }

    public func rollingTranscription(
        sessionID: UUID,
        trackID: String,
        sequenceNumber: Int
    ) throws -> BarnOwlRollingTranscriptionRecord? {
        try withStatement(
            """
            SELECT * FROM rolling_transcription_chunks
            WHERE session_id = ? AND track_id = ? AND sequence_number = ?
            """
        ) { statement, sql in
            try bind(sessionID, at: 1, in: statement, sql: sql)
            try bind(trackID, at: 2, in: statement, sql: sql)
            try bind(sequenceNumber, at: 3, in: statement, sql: sql)
            guard sqlite3_step(statement) == SQLITE_ROW else {
                return nil
            }
            return try readRollingTranscription(statement)
        }
    }

    public func rollingTranscriptions(sessionID: UUID) throws -> [BarnOwlRollingTranscriptionRecord] {
        try withStatement(
            "SELECT * FROM rolling_transcription_chunks WHERE session_id = ? ORDER BY start_time_offset ASC, track_id ASC, sequence_number ASC"
        ) { statement, sql in
            try bind(sessionID, at: 1, in: statement, sql: sql)
            return try readRows(statement, sql: sql, readRollingTranscription)
        }
    }

    public func deleteRollingTranscriptions(sessionID: UUID) throws {
        try withStatement("DELETE FROM rolling_transcription_chunks WHERE session_id = ?") { statement, sql in
            try bind(sessionID, at: 1, in: statement, sql: sql)
            try stepDone(statement, sql: sql)
        }
    }

    public func upsertMeetingCalendarContext(_ context: BarnOwlMeetingCalendarContextRecord) throws {
        try withStatement(
            """
            INSERT INTO meeting_calendar_context (
                id, meeting_id, calendar_event_id, title, starts_at, ends_at, attendees_json,
                raw_context_json, created_at, updated_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(meeting_id) DO UPDATE SET
                calendar_event_id = excluded.calendar_event_id,
                title = excluded.title,
                starts_at = excluded.starts_at,
                ends_at = excluded.ends_at,
                attendees_json = excluded.attendees_json,
                raw_context_json = excluded.raw_context_json,
                updated_at = excluded.updated_at
            """
        ) { statement, sql in
            try bind(context.id, at: 1, in: statement, sql: sql)
            try bind(context.meetingID, at: 2, in: statement, sql: sql)
            try bind(context.calendarEventID, at: 3, in: statement, sql: sql)
            try bind(context.title, at: 4, in: statement, sql: sql)
            try bind(context.startsAt, at: 5, in: statement, sql: sql)
            try bind(context.endsAt, at: 6, in: statement, sql: sql)
            try bind(context.attendeesJSON, at: 7, in: statement, sql: sql)
            try bind(context.rawContextJSON, at: 8, in: statement, sql: sql)
            try bind(context.createdAt, at: 9, in: statement, sql: sql)
            try bind(context.updatedAt, at: 10, in: statement, sql: sql)
            try stepDone(statement, sql: sql)
        }
    }

    public func meetingCalendarContext(meetingID: UUID) throws -> BarnOwlMeetingCalendarContextRecord? {
        try withStatement("SELECT * FROM meeting_calendar_context WHERE meeting_id = ?") { statement, sql in
            try bind(meetingID, at: 1, in: statement, sql: sql)
            guard sqlite3_step(statement) == SQLITE_ROW else {
                return nil
            }
            return try readMeetingCalendarContext(statement)
        }
    }

    public func deleteMeetingCalendarContext(meetingID: UUID) throws {
        try withStatement("DELETE FROM meeting_calendar_context WHERE meeting_id = ?") { statement, sql in
            try bind(meetingID, at: 1, in: statement, sql: sql)
            try stepDone(statement, sql: sql)
        }
    }

    public func upsertExternalContextItem(_ item: BarnOwlExternalContextItemRecord) throws {
        try withStatement(
            """
            INSERT INTO external_context_items (
                id, meeting_id, source, body, state, created_at, updated_at, used_in_note_generation, metadata_json
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                meeting_id = excluded.meeting_id,
                source = excluded.source,
                body = excluded.body,
                state = excluded.state,
                updated_at = excluded.updated_at,
                used_in_note_generation = excluded.used_in_note_generation,
                metadata_json = excluded.metadata_json
            """
        ) { statement, sql in
            try bind(item.id, at: 1, in: statement, sql: sql)
            try bind(item.meetingID, at: 2, in: statement, sql: sql)
            try bind(item.source, at: 3, in: statement, sql: sql)
            try bind(item.body, at: 4, in: statement, sql: sql)
            try bind(item.state.rawValue, at: 5, in: statement, sql: sql)
            try bind(item.createdAt, at: 6, in: statement, sql: sql)
            try bind(item.updatedAt, at: 7, in: statement, sql: sql)
            try bind(item.usedInNoteGeneration ? 1 : 0, at: 8, in: statement, sql: sql)
            try bind(item.metadataJSON, at: 9, in: statement, sql: sql)
            try stepDone(statement, sql: sql)
        }
    }

    public func externalContextItem(id: UUID) throws -> BarnOwlExternalContextItemRecord? {
        try withStatement("SELECT * FROM external_context_items WHERE id = ?") { statement, sql in
            try bind(id, at: 1, in: statement, sql: sql)
            guard sqlite3_step(statement) == SQLITE_ROW else {
                return nil
            }
            return try readExternalContextItem(statement)
        }
    }

    public func externalContextItems(
        meetingID: UUID? = nil,
        state: BarnOwlExternalContextState? = nil,
        limit: Int = 100
    ) throws -> [BarnOwlExternalContextItemRecord] {
        var filters: [String] = []
        if meetingID != nil {
            filters.append("meeting_id = ?")
        }
        if state != nil {
            filters.append("state = ?")
        }
        let whereClause = filters.isEmpty ? "" : " WHERE \(filters.joined(separator: " AND "))"
        let sql = """
        SELECT * FROM external_context_items\(whereClause)
        ORDER BY created_at DESC, id ASC
        LIMIT ?
        """

        return try withStatement(sql) { statement, sql in
            var index: Int32 = 1
            if let meetingID {
                try bind(meetingID, at: index, in: statement, sql: sql)
                index += 1
            }
            if let state {
                try bind(state.rawValue, at: index, in: statement, sql: sql)
                index += 1
            }
            try bind(max(0, limit), at: index, in: statement, sql: sql)
            return try readRows(statement, sql: sql, readExternalContextItem)
        }
    }

    public func deleteExternalContextItem(id: UUID) throws {
        try withStatement("DELETE FROM external_context_items WHERE id = ?") { statement, sql in
            try bind(id, at: 1, in: statement, sql: sql)
            try stepDone(statement, sql: sql)
        }
    }

    public func recordMeetingVersion(
        meetingID: UUID,
        actor: BarnOwlMeetingVersionActor,
        changeType: BarnOwlMeetingVersionChangeType,
        summary: String,
        before: BarnOwlMeetingVersionSnapshot?,
        after: BarnOwlMeetingVersionSnapshot?,
        createdAt: Date = Date()
    ) throws {
        let record = BarnOwlMeetingVersionRecord(
            meetingID: meetingID,
            createdAt: createdAt,
            actor: actor,
            changeType: changeType,
            summary: summary,
            beforeJSON: BarnOwlMeetingVersionRecord.encodeSnapshot(before),
            afterJSON: BarnOwlMeetingVersionRecord.encodeSnapshot(after)
        )
        try upsertMeetingVersion(record)
    }

    public func upsertMeetingVersion(_ version: BarnOwlMeetingVersionRecord) throws {
        try withStatement(
            """
            INSERT INTO meeting_versions (
                id, meeting_id, created_at, actor, change_type, summary, before_json, after_json
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                meeting_id = excluded.meeting_id,
                created_at = excluded.created_at,
                actor = excluded.actor,
                change_type = excluded.change_type,
                summary = excluded.summary,
                before_json = excluded.before_json,
                after_json = excluded.after_json
            """
        ) { statement, sql in
            try bind(version.id, at: 1, in: statement, sql: sql)
            try bind(version.meetingID, at: 2, in: statement, sql: sql)
            try bind(version.createdAt, at: 3, in: statement, sql: sql)
            try bind(version.actor.rawValue, at: 4, in: statement, sql: sql)
            try bind(version.changeType.rawValue, at: 5, in: statement, sql: sql)
            try bind(version.summary, at: 6, in: statement, sql: sql)
            try bind(version.beforeJSON, at: 7, in: statement, sql: sql)
            try bind(version.afterJSON, at: 8, in: statement, sql: sql)
            try stepDone(statement, sql: sql)
        }
    }

    public func meetingVersions(meetingID: UUID, limit: Int = 50) throws -> [BarnOwlMeetingVersionRecord] {
        try withStatement(
            """
            SELECT * FROM meeting_versions
            WHERE meeting_id = ?
            ORDER BY created_at DESC, id ASC
            LIMIT ?
            """
        ) { statement, sql in
            try bind(meetingID, at: 1, in: statement, sql: sql)
            try bind(max(0, limit), at: 2, in: statement, sql: sql)
            return try readRows(statement, sql: sql, readMeetingVersion)
        }
    }

    public func meetingVersion(id: UUID) throws -> BarnOwlMeetingVersionRecord? {
        try withStatement("SELECT * FROM meeting_versions WHERE id = ?") { statement, sql in
            try bind(id, at: 1, in: statement, sql: sql)
            guard sqlite3_step(statement) == SQLITE_ROW else {
                return nil
            }
            return try readMeetingVersion(statement)
        }
    }

    public func restoreMeetingVersion(id: UUID, actor: BarnOwlMeetingVersionActor = .user) throws -> BarnOwlMeetingState? {
        guard let version = try meetingVersion(id: id),
              let snapshot = version.beforeSnapshot,
              var state = try meetingState(id: version.meetingID)
        else {
            return nil
        }
        let beforeRestore = BarnOwlMeetingVersionSnapshot(state: state)
        let now = Self.nextUpdatedAt(after: state.updatedAt)
        var meeting = state.meeting
        meeting.title = snapshot.title
        meeting.updatedAt = now
        state.meeting = meeting
        state.generatedNotes = snapshot.generatedNotes
        state.meetingFacts = snapshot.meetingFacts
        state.summary = snapshot.summary
        state.actionItems = snapshot.actionItems
        state.decisions = snapshot.decisions
        state.openQuestions = snapshot.openQuestions
        state.updatedAt = now
        try upsertMeetingState(state)
        if !snapshot.actionItems.isEmpty {
            try upsertMeetingOutput(BarnOwlMeetingOutputRecord(
                meetingID: version.meetingID,
                kind: "actions",
                content: snapshot.actionItems.joined(separator: "\n"),
                contentType: "text/plain",
                updatedAt: now,
                metadataJSON: #"{"source":"version-restore"}"#
            ))
        }
        if !snapshot.decisions.isEmpty {
            try upsertMeetingOutput(BarnOwlMeetingOutputRecord(
                meetingID: version.meetingID,
                kind: "decisions",
                content: snapshot.decisions.joined(separator: "\n"),
                contentType: "text/plain",
                updatedAt: now,
                metadataJSON: #"{"source":"version-restore"}"#
            ))
        }
        if !snapshot.openQuestions.isEmpty {
            try upsertMeetingOutput(BarnOwlMeetingOutputRecord(
                meetingID: version.meetingID,
                kind: "open_questions",
                content: snapshot.openQuestions.joined(separator: "\n"),
                contentType: "text/plain",
                updatedAt: now,
                metadataJSON: #"{"source":"version-restore"}"#
            ))
        }
        if snapshot.generatedNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            try deleteMeetingOutput(meetingID: version.meetingID, kind: "markdown")
        }
        if snapshot.meetingFacts == nil {
            try deleteMeetingOutput(meetingID: version.meetingID, kind: "meeting_facts")
        }
        if snapshot.summary == nil {
            try deleteMeetingOutput(meetingID: version.meetingID, kind: "summary")
        }
        if snapshot.actionItems.isEmpty {
            try deleteMeetingOutput(meetingID: version.meetingID, kind: "actions")
            try deleteMeetingOutput(meetingID: version.meetingID, kind: "action_items")
        }
        if snapshot.decisions.isEmpty {
            try deleteMeetingOutput(meetingID: version.meetingID, kind: "decisions")
        }
        if snapshot.openQuestions.isEmpty {
            try deleteMeetingOutput(meetingID: version.meetingID, kind: "open_questions")
        }
        let restored = try meetingState(id: version.meetingID)
        if let restored {
            try recordMeetingVersion(
                meetingID: version.meetingID,
                actor: actor,
                changeType: .restore,
                summary: "Restored previous version from \(version.changeType.rawValue.replacingOccurrences(of: "_", with: " ")).",
                before: beforeRestore,
                after: BarnOwlMeetingVersionSnapshot(state: restored)
            )
        }
        return restored
    }
}

private extension BarnOwlDatabase {
    func meetingState(from meeting: BarnOwlMeetingRecord) throws -> BarnOwlMeetingState {
        let outputs = try meetingOutputs(meetingID: meeting.id)
        let sessions = try recordingSessions(meetingID: meeting.id)
        let finalSegments = try transcriptSegments(meetingID: meeting.id, variant: .final)
        let segments = finalSegments.isEmpty
            ? try transcriptSegments(meetingID: meeting.id, variant: .live)
            : finalSegments
        let jobs = try jobs(meetingID: meeting.id, limit: 100)
        let context = try externalContextItems(meetingID: meeting.id, state: .accepted, limit: 100)
        let markdown = outputs.first { $0.kind == "markdown" }?.content ?? ""
        let summaryText = outputs.first { $0.kind == "summary" }?.content
            ?? Self.markdownSection(namedAnyOf: ["Summary"], in: markdown)
        let decisions = Self.outputList(kind: "decisions", outputs: outputs)
            + Self.markdownListItems(inSectionNamedAnyOf: ["Decisions", "Key Decisions"], markdown: markdown)
        let actionItems = Self.outputList(kind: "actions", outputs: outputs)
            + Self.outputList(kind: "action_items", outputs: outputs)
            + Self.markdownListItems(inSectionNamedAnyOf: ["Action Items", "Actions", "Next Steps"], markdown: markdown)
        let openQuestions = Self.outputList(kind: "open_questions", outputs: outputs)
            + Self.markdownListItems(inSectionNamedAnyOf: ["Open Questions"], markdown: markdown)
        let calendarContext = try meetingCalendarContext(meetingID: meeting.id)
        var facts = Self.meetingFacts(metadataJSON: meeting.metadataJSON, outputs: outputs)
            ?? Self.meetingFactsFromMarkdown(markdown, meeting: meeting)
            ?? MeetingFacts(title: meeting.title)
        if MeetingFacts.clean(facts.title) == nil {
            facts.title = meeting.title
        }
        if MeetingFacts.clean(facts.meetingType) == nil {
            facts.meetingType = Self.meetingType(in: markdown, metadataJSON: meeting.metadataJSON)
        }
        if facts.participants.isEmpty {
            facts.participants = Self.participants(in: markdown, calendarContext: calendarContext)
        }
        let status = sessions.sorted { $0.startedAt > $1.startedAt }.first?.status
        let summary = summaryText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? nil
            : MeetingSummary(
                suggestedTitle: facts.title,
                overview: summaryText,
                decisions: Self.canonicalSentenceList(decisions),
                actionItems: Self.canonicalSentenceList(actionItems),
                openQuestions: Self.canonicalSentenceList(openQuestions)
            )
        let artifacts = outputs.map {
            BarnOwlMeetingStateArtifact(
                id: $0.id,
                meetingID: $0.meetingID,
                kind: $0.kind,
                content: $0.content,
                contentType: $0.contentType,
                url: Self.artifactURL(from: $0.metadataJSON),
                createdAt: $0.createdAt,
                updatedAt: $0.updatedAt,
                metadataJSON: $0.metadataJSON
            )
        }
        let realtimePreview = outputs.first { $0.kind == "realtime_preview" }?.content ?? ""
        let realtimeStatus = outputs.first { $0.kind == "realtime_status" }?.content ?? ""

        return BarnOwlMeetingState(
            meeting: meeting,
            recordingSessions: sessions,
            status: status,
            transcriptSegments: segments,
            realtimePreview: realtimePreview,
            realtimeStatus: realtimeStatus,
            meetingFacts: facts,
            speakerMappings: Self.speakerMappings(from: meeting.metadataJSON, outputs: outputs),
            externalContextItems: context,
            generatedNotes: markdown,
            summary: summary,
            actionItems: Self.canonicalSentenceList(actionItems),
            decisions: Self.canonicalSentenceList(decisions),
            openQuestions: Self.canonicalSentenceList(openQuestions),
            jobs: jobs,
            artifacts: artifacts,
            version: 1
        )
    }

    static func migrateToLatestSchema(database: OpaquePointer?) throws {
        try execute("PRAGMA foreign_keys = ON", database: database)
        try execute("PRAGMA journal_mode = WAL", database: database)
        try execute("PRAGMA synchronous = NORMAL", database: database)

        let version = try intValue("PRAGMA user_version", database: database) ?? 0
        if version < 1 {
            try execute("BEGIN IMMEDIATE TRANSACTION", database: database)
            do {
                try execute(schemaV1SQL, database: database)
                try execute("PRAGMA user_version = 1", database: database)
                try execute("COMMIT", database: database)
            } catch {
                try? execute("ROLLBACK", database: database)
                throw error
            }
        }
        if version < 2 {
            try execute("BEGIN IMMEDIATE TRANSACTION", database: database)
            do {
                try execute(schemaV2SQL, database: database)
                try execute("PRAGMA user_version = 2", database: database)
                try execute("COMMIT", database: database)
            } catch {
                try? execute("ROLLBACK", database: database)
                throw error
            }
        }
        if version < 3 {
            try execute("BEGIN IMMEDIATE TRANSACTION", database: database)
            do {
                try execute(schemaV3SQL, database: database)
                try execute("PRAGMA user_version = 3", database: database)
                try execute("COMMIT", database: database)
            } catch {
                try? execute("ROLLBACK", database: database)
                throw error
            }
        }
        if version < 4 {
            try execute("BEGIN IMMEDIATE TRANSACTION", database: database)
            do {
                try execute(schemaV4SQL, database: database)
                try execute("PRAGMA user_version = 4", database: database)
                try execute("COMMIT", database: database)
            } catch {
                try? execute("ROLLBACK", database: database)
                throw error
            }
        }
        if version < 5 {
            try execute("BEGIN IMMEDIATE TRANSACTION", database: database)
            do {
                try execute(schemaV5SQL, database: database)
                try execute("PRAGMA user_version = \(latestSchemaVersion)", database: database)
                try execute("COMMIT", database: database)
            } catch {
                try? execute("ROLLBACK", database: database)
                throw error
            }
        }
    }

    static func execute(_ sql: String, database: OpaquePointer?) throws {
        var errorMessage: UnsafeMutablePointer<Int8>?
        if sqlite3_exec(database, sql, nil, nil, &errorMessage) != SQLITE_OK {
            let message = errorMessage.map { String(cString: $0) } ?? currentErrorMessage(for: database)
            sqlite3_free(errorMessage)
            throw BarnOwlDatabaseError.stepFailed(sql: sql, message: message)
        }
    }

    static func intValue(_ sql: String, database: OpaquePointer?) throws -> Int? {
        var statement: OpaquePointer?
        if sqlite3_prepare_v2(database, sql, -1, &statement, nil) != SQLITE_OK {
            throw BarnOwlDatabaseError.prepareFailed(sql: sql, message: currentErrorMessage(for: database))
        }

        guard let statement else {
            throw BarnOwlDatabaseError.prepareFailed(sql: sql, message: "SQLite returned a nil statement")
        }

        defer {
            sqlite3_finalize(statement)
        }

        guard sqlite3_step(statement) == SQLITE_ROW else {
            return nil
        }
        return Int(sqlite3_column_int64(statement, 0))
    }

    static func currentErrorMessage(for database: OpaquePointer?) -> String {
        guard let database else {
            return "SQLite database is closed"
        }
        return String(cString: sqlite3_errmsg(database))
    }

    func migrateToLatestSchema() throws {
        try execute("PRAGMA foreign_keys = ON")
        try execute("PRAGMA journal_mode = WAL")
        try execute("PRAGMA synchronous = NORMAL")

        let version = try schemaVersion()
        if version < 1 {
            try transaction {
                try execute(Self.schemaV1SQL)
                try execute("PRAGMA user_version = 1")
            }
        }
        if version < 2 {
            try transaction {
                try execute(Self.schemaV2SQL)
                try execute("PRAGMA user_version = 2")
            }
        }
        if version < 3 {
            try transaction {
                try execute(Self.schemaV3SQL)
                try execute("PRAGMA user_version = 3")
            }
        }
        if version < 4 {
            try transaction {
                try execute(Self.schemaV4SQL)
                try execute("PRAGMA user_version = 4")
            }
        }
        if version < 5 {
            try transaction {
                try execute(Self.schemaV5SQL)
                try execute("PRAGMA user_version = \(Self.latestSchemaVersion)")
            }
        }
    }

    func execute(_ sql: String) throws {
        try Self.execute(sql, database: database.pointer)
    }

    func transaction(_ body: () throws -> Void) throws {
        try execute("BEGIN IMMEDIATE TRANSACTION")
        do {
            try body()
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    func withStatement<T>(_ sql: String, _ body: (OpaquePointer, String) throws -> T) throws -> T {
        var statement: OpaquePointer?
        if sqlite3_prepare_v2(database.pointer, sql, -1, &statement, nil) != SQLITE_OK {
            throw BarnOwlDatabaseError.prepareFailed(sql: sql, message: currentErrorMessage)
        }

        guard let statement else {
            throw BarnOwlDatabaseError.prepareFailed(sql: sql, message: "SQLite returned a nil statement")
        }

        defer {
            sqlite3_finalize(statement)
        }

        return try body(statement, sql)
    }

    func stepDone(_ statement: OpaquePointer, sql: String) throws {
        if sqlite3_step(statement) != SQLITE_DONE {
            throw BarnOwlDatabaseError.stepFailed(sql: sql, message: currentErrorMessage)
        }
    }

    func readRows<T>(_ statement: OpaquePointer, sql: String, _ read: (OpaquePointer) throws -> T) throws -> [T] {
        var rows: [T] = []
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_ROW {
                rows.append(try read(statement))
            } else if result == SQLITE_DONE {
                return rows
            } else {
                throw BarnOwlDatabaseError.stepFailed(sql: sql, message: currentErrorMessage)
            }
        }
    }

    func intValue(_ sql: String) throws -> Int? {
        try withStatement(sql) { statement, sql in
            guard sqlite3_step(statement) == SQLITE_ROW else {
                return nil
            }
            return Int(sqlite3_column_int64(statement, 0))
        }
    }

    var currentErrorMessage: String {
        guard let database = database.pointer else {
            return "SQLite database is closed"
        }
        return String(cString: sqlite3_errmsg(database))
    }

    func bind(_ value: UUID?, at index: Int32, in statement: OpaquePointer, sql: String) throws {
        try bind(value?.uuidString.lowercased(), at: index, in: statement, sql: sql)
    }

    func bind(_ value: String?, at index: Int32, in statement: OpaquePointer, sql: String) throws {
        let result: Int32
        if let value {
            result = sqlite3_bind_text(statement, index, value, -1, Self.sqliteTransient)
        } else {
            result = sqlite3_bind_null(statement, index)
        }
        if result != SQLITE_OK {
            throw BarnOwlDatabaseError.bindFailed(sql: sql, index: index, message: currentErrorMessage)
        }
    }

    func bind(_ value: Date?, at index: Int32, in statement: OpaquePointer, sql: String) throws {
        let result: Int32
        if let value {
            result = sqlite3_bind_double(statement, index, value.timeIntervalSince1970)
        } else {
            result = sqlite3_bind_null(statement, index)
        }
        if result != SQLITE_OK {
            throw BarnOwlDatabaseError.bindFailed(sql: sql, index: index, message: currentErrorMessage)
        }
    }

    func bind(_ value: TimeInterval?, at index: Int32, in statement: OpaquePointer, sql: String) throws {
        let result: Int32
        if let value {
            result = sqlite3_bind_double(statement, index, value)
        } else {
            result = sqlite3_bind_null(statement, index)
        }
        if result != SQLITE_OK {
            throw BarnOwlDatabaseError.bindFailed(sql: sql, index: index, message: currentErrorMessage)
        }
    }

    func bind(_ value: Int, at index: Int32, in statement: OpaquePointer, sql: String) throws {
        if sqlite3_bind_int64(statement, index, sqlite3_int64(value)) != SQLITE_OK {
            throw BarnOwlDatabaseError.bindFailed(sql: sql, index: index, message: currentErrorMessage)
        }
    }

    func columnString(_ statement: OpaquePointer, _ index: Int32) -> String? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL,
              let text = sqlite3_column_text(statement, index) else {
            return nil
        }
        return String(cString: text)
    }

    func columnRequiredString(_ statement: OpaquePointer, _ index: Int32) -> String {
        columnString(statement, index) ?? ""
    }

    func columnUUID(_ statement: OpaquePointer, _ index: Int32) throws -> UUID? {
        guard let string = columnString(statement, index) else {
            return nil
        }
        guard let uuid = UUID(uuidString: string) else {
            throw BarnOwlDatabaseError.invalidUUID(string)
        }
        return uuid
    }

    func columnRequiredUUID(_ statement: OpaquePointer, _ index: Int32) throws -> UUID {
        let string = columnRequiredString(statement, index)
        guard let uuid = UUID(uuidString: string) else {
            throw BarnOwlDatabaseError.invalidUUID(string)
        }
        return uuid
    }

    func columnDate(_ statement: OpaquePointer, _ index: Int32) -> Date? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else {
            return nil
        }
        return Date(timeIntervalSince1970: sqlite3_column_double(statement, index))
    }

    func columnRequiredDate(_ statement: OpaquePointer, _ index: Int32) -> Date {
        Date(timeIntervalSince1970: sqlite3_column_double(statement, index))
    }

    func columnDouble(_ statement: OpaquePointer, _ index: Int32) -> Double? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else {
            return nil
        }
        return sqlite3_column_double(statement, index)
    }

    func readMeeting(_ statement: OpaquePointer) throws -> BarnOwlMeetingRecord {
        BarnOwlMeetingRecord(
            id: try columnRequiredUUID(statement, 0),
            externalID: columnString(statement, 1),
            title: columnRequiredString(statement, 2),
            startedAt: columnDate(statement, 3),
            endedAt: columnDate(statement, 4),
            createdAt: columnRequiredDate(statement, 5),
            updatedAt: columnRequiredDate(statement, 6),
            metadataJSON: columnString(statement, 7)
        )
    }

    func readRecordingSession(_ statement: OpaquePointer) throws -> BarnOwlRecordingSessionRecord {
        BarnOwlRecordingSessionRecord(
            id: try columnRequiredUUID(statement, 0),
            meetingID: try columnRequiredUUID(statement, 1),
            status: BarnOwlRecordingSessionStatus(rawValue: columnRequiredString(statement, 2)) ?? .pending,
            startedAt: columnRequiredDate(statement, 3),
            endedAt: columnDate(statement, 4),
            audioSourcesJSON: columnString(statement, 5),
            createdAt: columnRequiredDate(statement, 6),
            updatedAt: columnRequiredDate(statement, 7)
        )
    }

    func readTranscriptSegment(_ statement: OpaquePointer) throws -> BarnOwlTranscriptSegmentRecord {
        BarnOwlTranscriptSegmentRecord(
            id: try columnRequiredUUID(statement, 0),
            meetingID: try columnRequiredUUID(statement, 1),
            sessionID: try columnUUID(statement, 2),
            variant: BarnOwlTranscriptVariant(rawValue: columnRequiredString(statement, 3)) ?? .final,
            sequence: Int(sqlite3_column_int64(statement, 4)),
            speakerLabel: columnString(statement, 5),
            text: columnRequiredString(statement, 6),
            startTime: sqlite3_column_double(statement, 7),
            endTime: sqlite3_column_double(statement, 8),
            confidence: columnDouble(statement, 9),
            createdAt: columnRequiredDate(statement, 10),
            updatedAt: columnRequiredDate(statement, 11)
        )
    }

    func readMeetingOutput(_ statement: OpaquePointer) throws -> BarnOwlMeetingOutputRecord {
        BarnOwlMeetingOutputRecord(
            id: try columnRequiredUUID(statement, 0),
            meetingID: try columnRequiredUUID(statement, 1),
            kind: columnRequiredString(statement, 2),
            content: columnRequiredString(statement, 3),
            contentType: columnRequiredString(statement, 4),
            createdAt: columnRequiredDate(statement, 5),
            updatedAt: columnRequiredDate(statement, 6),
            metadataJSON: columnString(statement, 7)
        )
    }

    func readJob(_ statement: OpaquePointer) throws -> BarnOwlJobRecord {
        BarnOwlJobRecord(
            id: try columnRequiredUUID(statement, 0),
            meetingID: try columnUUID(statement, 1),
            type: columnRequiredString(statement, 2),
            status: BarnOwlJobStatus(rawValue: columnRequiredString(statement, 3)) ?? .pending,
            priority: Int(sqlite3_column_int64(statement, 4)),
            attemptCount: Int(sqlite3_column_int64(statement, 5)),
            payloadJSON: columnString(statement, 6),
            errorMessage: columnString(statement, 7),
            createdAt: columnRequiredDate(statement, 8),
            updatedAt: columnRequiredDate(statement, 9),
            scheduledAt: columnDate(statement, 10),
            startedAt: columnDate(statement, 11),
            completedAt: columnDate(statement, 12)
        )
    }

    func readJobChunk(_ statement: OpaquePointer) throws -> BarnOwlJobChunkRecord {
        BarnOwlJobChunkRecord(
            id: try columnRequiredUUID(statement, 0),
            jobID: try columnRequiredUUID(statement, 1),
            sequence: Int(sqlite3_column_int64(statement, 2)),
            status: BarnOwlJobStatus(rawValue: columnRequiredString(statement, 3)) ?? .pending,
            payloadJSON: columnString(statement, 4),
            resultJSON: columnString(statement, 5),
            errorMessage: columnString(statement, 6),
            createdAt: columnRequiredDate(statement, 7),
            updatedAt: columnRequiredDate(statement, 8)
        )
    }

    func readRollingTranscription(_ statement: OpaquePointer) throws -> BarnOwlRollingTranscriptionRecord {
        BarnOwlRollingTranscriptionRecord(
            id: try columnRequiredUUID(statement, 0),
            sessionID: try columnRequiredUUID(statement, 1),
            trackID: columnRequiredString(statement, 2),
            sequenceNumber: Int(sqlite3_column_int64(statement, 3)),
            trackLabel: columnRequiredString(statement, 4),
            audioFilePath: columnString(statement, 5),
            startTimeOffset: sqlite3_column_double(statement, 6),
            duration: columnDouble(statement, 7),
            overlapDuration: columnDouble(statement, 8),
            modelIdentifier: columnString(statement, 9),
            status: BarnOwlRollingTranscriptionStatus(rawValue: columnRequiredString(statement, 10)) ?? .pending,
            errorMessage: columnString(statement, 11),
            responseJSON: columnString(statement, 12),
            createdAt: columnRequiredDate(statement, 13),
            updatedAt: columnRequiredDate(statement, 14),
            completedAt: columnDate(statement, 15)
        )
    }

    func readMeetingCalendarContext(_ statement: OpaquePointer) throws -> BarnOwlMeetingCalendarContextRecord {
        BarnOwlMeetingCalendarContextRecord(
            id: try columnRequiredUUID(statement, 0),
            meetingID: try columnRequiredUUID(statement, 1),
            calendarEventID: columnString(statement, 2),
            title: columnString(statement, 3),
            startsAt: columnDate(statement, 4),
            endsAt: columnDate(statement, 5),
            attendeesJSON: columnString(statement, 6),
            rawContextJSON: columnString(statement, 7),
            createdAt: columnRequiredDate(statement, 8),
            updatedAt: columnRequiredDate(statement, 9)
        )
    }

    func readExternalContextItem(_ statement: OpaquePointer) throws -> BarnOwlExternalContextItemRecord {
        BarnOwlExternalContextItemRecord(
            id: try columnRequiredUUID(statement, 0),
            meetingID: try columnUUID(statement, 1),
            source: columnRequiredString(statement, 2),
            body: columnRequiredString(statement, 3),
            state: BarnOwlExternalContextState(rawValue: columnRequiredString(statement, 4)) ?? .pending,
            createdAt: columnRequiredDate(statement, 5),
            updatedAt: columnRequiredDate(statement, 6),
            usedInNoteGeneration: sqlite3_column_int(statement, 8) != 0,
            metadataJSON: columnString(statement, 7)
        )
    }

    func readMeetingVersion(_ statement: OpaquePointer) throws -> BarnOwlMeetingVersionRecord {
        BarnOwlMeetingVersionRecord(
            id: try columnRequiredUUID(statement, 0),
            meetingID: try columnRequiredUUID(statement, 1),
            createdAt: columnRequiredDate(statement, 2),
            actor: BarnOwlMeetingVersionActor(rawValue: columnRequiredString(statement, 3)) ?? .system,
            changeType: BarnOwlMeetingVersionChangeType(rawValue: columnRequiredString(statement, 4)) ?? .noteRewrite,
            summary: columnRequiredString(statement, 5),
            beforeJSON: columnString(statement, 6),
            afterJSON: columnString(statement, 7)
        )
    }

    static func outputList(kind: String, outputs: [BarnOwlMeetingOutputRecord]) -> [String] {
        outputs
            .filter { $0.kind == kind }
            .flatMap { output in
                output.content
                    .split(whereSeparator: \.isNewline)
                    .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
                    .map { line in
                        line.trimmingCharacters(in: CharacterSet(charactersIn: "-*•0123456789. )"))
                    }
                    .filter { !$0.isEmpty }
            }
    }

    static func canonicalSentenceList(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        var output: [String] = []
        for value in values {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let key = MeetingFacts.clean(trimmed)?.lowercased(),
                  !seen.contains(key)
            else { continue }
            seen.insert(key)
            output.append(trimmed)
        }
        return output
    }

    static func nextUpdatedAt(after current: Date) -> Date {
        max(Date(), current.addingTimeInterval(0.001))
    }

    static func markdownSection(namedAnyOf names: [String], in markdown: String) -> String {
        let lines = markdown.components(separatedBy: .newlines)
        var capture = false
        var captured: [String] = []
        let normalizedNames = Set(names.map { $0.lowercased() })

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("#") {
                let heading = trimmed
                    .drop(while: { $0 == "#" })
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased()
                if capture {
                    break
                }
                capture = normalizedNames.contains(heading)
                continue
            }
            if capture {
                captured.append(line)
            }
        }

        return captured
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func markdownListItems(inSectionNamedAnyOf names: [String], markdown: String) -> [String] {
        markdownSection(namedAnyOf: names, in: markdown)
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.hasPrefix("-") || $0.hasPrefix("*") || $0.hasPrefix("•") }
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "-*• ")) }
            .filter { !$0.isEmpty }
    }

    static func meetingFactsFromMarkdown(_ markdown: String, meeting: BarnOwlMeetingRecord) -> MeetingFacts? {
        let factsSection = markdownSection(namedAnyOf: ["Meeting Facts"], in: markdown)
        guard !factsSection.isEmpty else { return nil }
        var facts = MeetingFacts(title: meeting.title)
        for line in factsSection.components(separatedBy: .newlines) {
            let cleaned = line.trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "-*• "))
            let parts = cleaned.split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            let key = parts[0].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
            switch key {
            case "title":
                facts.title = value
            case "meeting type":
                facts.meetingType = value
            case "participants":
                facts.participants = MeetingFacts.normalizedList(value.split(separator: ",").map(String.init))
            case "customers":
                facts.customers = MeetingFacts.normalizedList(value.split(separator: ",").map(String.init))
            case "organizations":
                facts.organizations = MeetingFacts.normalizedList(value.split(separator: ",").map(String.init))
            case "projects":
                facts.projects = MeetingFacts.normalizedList(value.split(separator: ",").map(String.init))
            case "goals":
                facts.goals = MeetingFacts.normalizedList(value.split(separator: ";").map(String.init))
            default:
                facts.additionalContext = MeetingFacts.normalizedList(facts.additionalContext + [cleaned])
            }
        }
        return facts
    }

    static func artifactURL(from metadataJSON: String?) -> URL? {
        guard let metadataJSON,
              let data = metadataJSON.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let path = object["path"] as? String ?? object["url"] as? String
        else { return nil }
        if path.hasPrefix("file://") {
            return URL(string: path)
        }
        return URL(fileURLWithPath: path)
    }

    static func speakerMappings(
        from metadataJSON: String?,
        outputs: [BarnOwlMeetingOutputRecord]
    ) -> [String: String] {
        let jsonCandidates = [metadataJSON] + outputs.map(\.metadataJSON)
        for json in jsonCandidates.compactMap({ $0 }) {
            guard let data = json.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let mappings = object["speakerMappings"] as? [String: String]
            else { continue }
            return mappings
        }
        return [:]
    }

    static func meetingType(in markdown: String, metadataJSON: String?) -> String? {
        if let metadataJSON,
           let data = metadataJSON.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let factsObject = object["meetingFacts"],
           let factsData = try? JSONSerialization.data(withJSONObject: factsObject),
           let facts = try? JSONDecoder().decode(MeetingFacts.self, from: factsData),
           let meetingType = MeetingFacts.clean(facts.meetingType) {
            return meetingType
        }
        if let metadataJSON,
           let data = metadataJSON.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let meetingType = object["meetingType"] as? String,
           !meetingType.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return meetingType
        }

        for line in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.localizedCaseInsensitiveContains("Meeting Type:"),
               let value = trimmed.split(separator: ":", maxSplits: 1).last {
                let type = value.trimmingCharacters(in: .whitespacesAndNewlines)
                return type.isEmpty ? nil : type
            }
        }
        return nil
    }

    static func participants(
        in markdown: String,
        calendarContext: BarnOwlMeetingCalendarContextRecord?
    ) -> [String] {
        var participants: Set<String> = []
        if let attendeesJSON = calendarContext?.attendeesJSON,
           let data = attendeesJSON.data(using: .utf8),
           let attendees = try? JSONDecoder().decode([String].self, from: data) {
            participants.formUnion(attendees)
        }

        let lines = markdown.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        for (index, line) in lines.enumerated() {
            if line.trimmingCharacters(in: .whitespacesAndNewlines).localizedCaseInsensitiveContains("## Participants") {
                for participantLine in lines.dropFirst(index + 1) {
                    let trimmed = participantLine.trimmingCharacters(in: .whitespacesAndNewlines)
                    if trimmed.hasPrefix("## ") { break }
                    if trimmed.hasPrefix("- ") {
                        participants.insert(String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespacesAndNewlines))
                    }
                }
            }
        }
        return participants.filter { !$0.isEmpty }.sorted()
    }

    static func meetingFacts(
        metadataJSON: String?,
        outputs: [BarnOwlMeetingOutputRecord]
    ) -> MeetingFacts? {
        if let output = outputs
            .filter({ $0.kind == "meeting_facts" })
            .sorted(by: { $0.updatedAt > $1.updatedAt })
            .first,
           let facts = MeetingFacts.decoded(from: output.content) {
            return facts
        }
        guard let metadataJSON,
              let data = metadataJSON.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let factsObject = object["meetingFacts"],
              let factsData = try? JSONSerialization.data(withJSONObject: factsObject)
        else { return nil }
        return try? JSONDecoder().decode(MeetingFacts.self, from: factsData)
    }

    static func snippet(in text: String, query: String) -> String {
        let normalized = text.replacingOccurrences(of: "\n", with: " ")
        guard !query.isEmpty,
              let range = normalized.lowercased().range(of: query)
        else {
            return String(normalized.prefix(220)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let start = normalized.index(range.lowerBound, offsetBy: -70, limitedBy: normalized.startIndex) ?? normalized.startIndex
        let end = normalized.index(range.upperBound, offsetBy: 150, limitedBy: normalized.endIndex) ?? normalized.endIndex
        return String(normalized[start..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    static let schemaV1SQL = """
    CREATE TABLE IF NOT EXISTS meetings (
        id TEXT PRIMARY KEY,
        external_id TEXT,
        title TEXT NOT NULL,
        started_at REAL,
        ended_at REAL,
        created_at REAL NOT NULL,
        updated_at REAL NOT NULL,
        metadata_json TEXT
    );

    CREATE TABLE IF NOT EXISTS recording_sessions (
        id TEXT PRIMARY KEY,
        meeting_id TEXT NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,
        status TEXT NOT NULL,
        started_at REAL NOT NULL,
        ended_at REAL,
        audio_sources_json TEXT,
        created_at REAL NOT NULL,
        updated_at REAL NOT NULL
    );

    CREATE TABLE IF NOT EXISTS transcript_segments (
        id TEXT PRIMARY KEY,
        meeting_id TEXT NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,
        session_id TEXT REFERENCES recording_sessions(id) ON DELETE SET NULL,
        variant TEXT NOT NULL DEFAULT 'final',
        sequence INTEGER NOT NULL,
        speaker_label TEXT,
        text TEXT NOT NULL,
        start_time REAL NOT NULL,
        end_time REAL NOT NULL,
        confidence REAL,
        created_at REAL NOT NULL,
        updated_at REAL NOT NULL
    );

    CREATE TABLE IF NOT EXISTS jobs (
        id TEXT PRIMARY KEY,
        meeting_id TEXT REFERENCES meetings(id) ON DELETE CASCADE,
        type TEXT NOT NULL,
        status TEXT NOT NULL,
        priority INTEGER NOT NULL DEFAULT 0,
        attempt_count INTEGER NOT NULL DEFAULT 0,
        payload_json TEXT,
        error_message TEXT,
        created_at REAL NOT NULL,
        updated_at REAL NOT NULL,
        scheduled_at REAL,
        started_at REAL,
        completed_at REAL
    );

    CREATE TABLE IF NOT EXISTS job_chunks (
        id TEXT PRIMARY KEY,
        job_id TEXT NOT NULL REFERENCES jobs(id) ON DELETE CASCADE,
        sequence INTEGER NOT NULL,
        status TEXT NOT NULL,
        payload_json TEXT,
        result_json TEXT,
        error_message TEXT,
        created_at REAL NOT NULL,
        updated_at REAL NOT NULL
    );

    CREATE TABLE IF NOT EXISTS meeting_outputs (
        id TEXT PRIMARY KEY,
        meeting_id TEXT NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,
        kind TEXT NOT NULL,
        content TEXT NOT NULL,
        content_type TEXT NOT NULL,
        created_at REAL NOT NULL,
        updated_at REAL NOT NULL,
        metadata_json TEXT
    );

    CREATE TABLE IF NOT EXISTS meeting_calendar_context (
        id TEXT PRIMARY KEY,
        meeting_id TEXT NOT NULL UNIQUE REFERENCES meetings(id) ON DELETE CASCADE,
        calendar_event_id TEXT,
        title TEXT,
        starts_at REAL,
        ends_at REAL,
        attendees_json TEXT,
        raw_context_json TEXT,
        created_at REAL NOT NULL,
        updated_at REAL NOT NULL
    );

    CREATE INDEX IF NOT EXISTS idx_recording_sessions_meeting ON recording_sessions(meeting_id, started_at);
    CREATE INDEX IF NOT EXISTS idx_transcript_segments_meeting ON transcript_segments(meeting_id, variant, sequence);
    CREATE INDEX IF NOT EXISTS idx_transcript_segments_session ON transcript_segments(session_id, variant, sequence);
    CREATE INDEX IF NOT EXISTS idx_jobs_status_schedule ON jobs(status, scheduled_at, priority);
    CREATE INDEX IF NOT EXISTS idx_jobs_meeting ON jobs(meeting_id, created_at);
    CREATE INDEX IF NOT EXISTS idx_job_chunks_job ON job_chunks(job_id, sequence);
    CREATE INDEX IF NOT EXISTS idx_meeting_outputs_meeting ON meeting_outputs(meeting_id, kind, updated_at);
    """

    static let schemaV2SQL = """
    CREATE TABLE IF NOT EXISTS external_context_items (
        id TEXT PRIMARY KEY,
        meeting_id TEXT REFERENCES meetings(id) ON DELETE CASCADE,
        source TEXT NOT NULL,
        body TEXT NOT NULL,
        state TEXT NOT NULL,
        created_at REAL NOT NULL,
        updated_at REAL NOT NULL,
        metadata_json TEXT
    );

    CREATE INDEX IF NOT EXISTS idx_external_context_meeting ON external_context_items(meeting_id, state, created_at);
    CREATE INDEX IF NOT EXISTS idx_external_context_state ON external_context_items(state, created_at);
    """

    static let schemaV3SQL = """
    ALTER TABLE external_context_items ADD COLUMN used_in_note_generation INTEGER NOT NULL DEFAULT 0;
    """

    static let schemaV4SQL = """
    CREATE TABLE IF NOT EXISTS meeting_versions (
        id TEXT PRIMARY KEY,
        meeting_id TEXT NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,
        created_at REAL NOT NULL,
        actor TEXT NOT NULL,
        change_type TEXT NOT NULL,
        summary TEXT NOT NULL,
        before_json TEXT,
        after_json TEXT
    );

    CREATE INDEX IF NOT EXISTS idx_meeting_versions_meeting ON meeting_versions(meeting_id, created_at);
    CREATE INDEX IF NOT EXISTS idx_meeting_versions_change_type ON meeting_versions(change_type, created_at);
    """

    static let schemaV5SQL = """
    CREATE TABLE IF NOT EXISTS rolling_transcription_chunks (
        id TEXT PRIMARY KEY,
        session_id TEXT NOT NULL REFERENCES recording_sessions(id) ON DELETE CASCADE,
        track_id TEXT NOT NULL,
        sequence_number INTEGER NOT NULL,
        track_label TEXT NOT NULL,
        audio_file_path TEXT,
        start_time_offset REAL NOT NULL,
        duration REAL,
        overlap_duration REAL,
        model_identifier TEXT,
        status TEXT NOT NULL,
        error_message TEXT,
        response_json TEXT,
        created_at REAL NOT NULL,
        updated_at REAL NOT NULL,
        completed_at REAL,
        UNIQUE(session_id, track_id, sequence_number)
    );

    CREATE INDEX IF NOT EXISTS idx_rolling_transcription_session ON rolling_transcription_chunks(session_id, status, sequence_number);
    """
}

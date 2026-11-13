import Foundation
import SQLite3

/// Read T3's projections without touching its event store or running provider sessions.
enum T3SessionTransfer {
    struct Thread {
        var id: String
        var title: String
        var cwd: String
        var updatedAt: Date?
    }

    static var database: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".t3/userdata/statev2.sqlite")
    }

    private static func rows(_ sql: String, database: URL, id: String? = nil) throws -> [[String]] {
        var db: OpaquePointer?
        guard sqlite3_open_v2(database.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
            sqlite3_close(db)
            throw CodexSessionTransfer.error("Couldn't read T3's local database.")
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 2000)
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw CodexSessionTransfer.error("This T3 database schema isn't supported.")
        }
        defer { sqlite3_finalize(statement) }
        if let id {
            _ = id.withCString { sqlite3_bind_text(statement, 1, $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
        }
        var result: [[String]] = []
        var status = sqlite3_step(statement)
        while status == SQLITE_ROW {
            result.append((0..<sqlite3_column_count(statement)).map {
                sqlite3_column_text(statement, $0).map { String(cString: $0) } ?? ""
            })
            status = sqlite3_step(statement)
        }
        guard status == SQLITE_DONE else { throw CodexSessionTransfer.error("T3's database couldn't be read completely. Try again.") }
        return result
    }

    static func threads(database: URL = database) throws -> [Thread] {
        try rows("""
            SELECT t.thread_id, t.title, COALESCE(json_extract(t.payload_json, '$.worktreePath'), p.workspace_root), t.updated_at
            FROM orchestration_v2_projection_threads t
            JOIN projection_projects p ON p.project_id = t.project_id
            WHERE t.deleted_at IS NULL AND t.archived_at IS NULL
            ORDER BY t.updated_at DESC LIMIT 500
            """, database: database).map {
                Thread(id: $0[0], title: $0[1], cwd: $0[2], updatedAt: date($0[3]))
            }
    }

    static func date(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }

    static func transcript(_ thread: Thread, database: URL = database) throws -> (String, Data) {
        let messages = try rows("""
            SELECT role, payload_json FROM orchestration_v2_projection_messages
            WHERE thread_id = ? AND role IN ('user','assistant') AND streaming = 0
            ORDER BY created_at, message_id
            """, database: database, id: thread.id)
        let steps: [CodexStep] = try messages.compactMap { row in
            guard let data = row[1].data(using: .utf8),
                  let message = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let text = message["text"] as? String, !text.isEmpty else { return nil }
            let timestamp = (message["createdAt"] as? String).flatMap(date)
            return row[0] == "user" ? .user(text, timestamp) : .agent(text, timestamp)
        }
        guard steps.contains(where: \.isUserMessage) else {
            throw CodexSessionTransfer.error("This T3 thread has no completed messages to copy.")
        }
        let id = UUID().uuidString.lowercased()
        var writer = ClaudeTranscriptWriter(sessionID: id, cwd: thread.cwd, gitBranch: nil)
        _ = writer.write(steps, title: thread.title, source: "T3 Code (conversation text only; attachments and tool state were not copied)")
        return (id, writer.data)
    }

    static func transfer(_ thread: Thread, to destination: LaunchProfile) throws -> (metadata: URL?, codexID: String?) {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: thread.cwd, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw CodexSessionTransfer.error("The working folder no longer exists: \(thread.cwd). Restore it before copying this conversation.")
        }
        let (id, data) = try transcript(thread)
        // Codex discovers imports only inside Claude's projects tree.
        let folder = CodeSessionTransfer.projectsDirectory.appendingPathComponent(ClaudeTranscriptWriter.projectSlug(for: thread.cwd))
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("\(id).jsonl")
        try data.write(to: file, options: .atomic)
        if destination.provider == .codex {
            let session = CodeSessionTransfer.Session(id: id, title: thread.title, cwd: thread.cwd,
                lastActivityAt: thread.updatedAt, fileURL: file, transcriptURL: file)
            return (nil, try CodexSessionTransfer.importClaudeSession(session, into: destination))
        }
        guard let directory = CodeSessionTransfer.sessionsDirectory(for: destination, orgID: destination.organizationUUID, creatingIfNeeded: true) else {
            throw CodexSessionTransfer.error("Open Claude Code in the destination account once, then try again.")
        }
        let metadata = try CodexSessionTransfer.registerSession(cliSessionID: id, cwd: thread.cwd, title: thread.title,
            createdAt: thread.updatedAt ?? Date(), in: directory)
        return (metadata, nil)
    }
}

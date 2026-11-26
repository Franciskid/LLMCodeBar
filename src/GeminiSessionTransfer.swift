import AppKit
import Foundation
import SQLite3

/// Reading and transferring Google Antigravity / Gemini conversations.
///
/// Supports transferring conversations in every direction:
/// - Gemini ↔ Gemini (between two Antigravity accounts — starts a fresh conversation in
///   the destination account seeded with the full transcript, so thought signatures and
///   account-scoped state never clash).
/// - Gemini → Claude Code (writes a native Claude Code `.jsonl` transcript and registers
///   it in the destination Claude account's Code list).
/// - Gemini → Codex / ChatGPT (translates to Claude JSONL and runs Codex's own importer).
/// - Gemini → T3 Code (hands off via T3's `t3` CLI).
/// - Claude Code / Claude Chat / Codex / T3 Code → Gemini (starts a new Antigravity
///   conversation in the destination Gemini account seeded with the transcript).
enum GeminiSessionTransfer {
    struct Conversation: Equatable {
        var id: String
        var title: String
        var cwd: String
        var updatedAt: Date?
        var stepCount: Int

        var projectName: String {
            guard !cwd.isEmpty else { return "" }
            let name = URL(fileURLWithPath: cwd).lastPathComponent
            return name.isEmpty ? cwd : name
        }

        var displayTitle: String {
            let firstLine = title
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .components(separatedBy: .newlines).first ?? ""
            if !firstLine.isEmpty { return firstLine }
            return projectName.isEmpty ? "Gemini conversation" : projectName
        }
    }

    struct SeedResult {
        var cascadeID: String
        var title: String
        var truncated: Bool
    }

    /// Keep seeded handoffs well within model context and RPC payload limits.
    static let handoffLimit = 120_000

    // MARK: Storage locations

    /// Antigravity stores conversations under `~/.gemini/antigravity`.
    static var defaultAppDataDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".gemini/antigravity", isDirectory: true)
    }

    // MARK: Listing conversations (instant local read)

    /// Lists Antigravity conversations, newest first. Reads `agyhub_summaries_proto.pb`
    /// and/or `conversation_summaries.db` directly from disk so the transfer window loads
    /// instantaneously without spawning a background server.
    static func conversations(in directory: URL = defaultAppDataDirectory, limit: Int = 200) -> [Conversation] {
        var byID: [String: Conversation] = [:]

        let protoURL = directory.appendingPathComponent("agyhub_summaries_proto.pb")
        if let data = try? Data(contentsOf: protoURL) {
            for item in parseSummariesProtobuf(data) {
                byID[item.id] = item
            }
        }

        let sqliteURL = directory.appendingPathComponent("conversation_summaries.db")
        if FileManager.default.fileExists(atPath: sqliteURL.path) {
            for item in readSummariesSQLite(database: sqliteURL) {
                if let existing = byID[item.id] {
                    let newer = (item.updatedAt ?? .distantPast) > (existing.updatedAt ?? .distantPast)
                    if newer { byID[item.id] = item }
                } else {
                    byID[item.id] = item
                }
            }
        }

        // Also surface any conversation file on disk that isn't indexed in summaries yet.
        let conversationsDir = directory.appendingPathComponent("conversations", isDirectory: true)
        if let files = try? FileManager.default.contentsOfDirectory(
            at: conversationsDir,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]) {
            for file in files where file.pathExtension == "pb" || file.pathExtension == "db" {
                let id = file.deletingPathExtension().lastPathComponent
                guard UUID(uuidString: id) != nil, byID[id] == nil else { continue }
                let values = try? file.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
                guard (values?.fileSize ?? 0) > 0 else { continue }
                byID[id] = Conversation(
                    id: id,
                    title: "",
                    cwd: "",
                    updatedAt: values?.contentModificationDate,
                    stepCount: 1)
            }
        }

        return byID.values
            .filter { $0.stepCount > 0 }
            .sorted { ($0.updatedAt ?? .distantPast) > ($1.updatedAt ?? .distantPast) }
            .prefix(limit)
            .map { $0 }
    }

    // MARK: Reading full conversation history via Antigravity

    static func readHistory(of conversation: Conversation, from source: LaunchProfile) throws -> GeminiConversationHistory {
        try GeminiAuthStore.withActivatedProfile(source) {
            let server = try GeminiLanguageServer(appPath: source.appPath)
            defer { server.stop() }
            _ = server.waitForAuth(timeout: 3.0)
            let response = try server.rpc("GetCascadeTrajectory", body: ["cascadeId": conversation.id], timeout: 30)
            guard let trajectory = response["trajectory"] as? [String: Any] else {
                throw error("Couldn't read that Gemini conversation.")
            }
            let steps = GeminiConversationHistory.parseSteps(from: trajectory)
            return GeminiConversationHistory(cwd: conversation.cwd.isEmpty ? nil : conversation.cwd, steps: steps)
        }
    }

    // MARK: Transferring FROM Gemini

    /// Transfers a Gemini conversation to another Gemini / Antigravity account by seeding
    /// a new conversation in the destination account.
    static func transfer(_ conversation: Conversation, from source: LaunchProfile, to destination: LaunchProfile) throws -> SeedResult {
        let history = try readHistory(of: conversation, from: source)
        guard history.steps.contains(where: \.isUserMessage) else {
            throw error("That conversation has no messages to bring across.")
        }
        return try seedConversation(
            title: conversation.displayTitle,
            cwd: history.cwd ?? conversation.cwd,
            sourceLabel: "Gemini (\(ChatTransfer.accountLabel(source)))",
            steps: history.steps,
            into: destination)
    }

    /// Copies a Gemini conversation into a Claude Code account as a native `.jsonl` session.
    static func moveToClaudeCode(_ conversation: Conversation, from source: LaunchProfile, to destination: LaunchProfile) throws -> CodexSessionTransfer.ClaudeImport {
        guard let directory = CodeSessionTransfer.sessionsDirectory(
            for: destination,
            orgID: destination.organizationUUID,
            creatingIfNeeded: true) else {
            throw error("Couldn't find where \(ChatTransfer.accountLabel(destination)) keeps its Code sessions. Open Claude Code in that account once, then try again.")
        }

        let history = try readHistory(of: conversation, from: source)
        guard history.steps.contains(where: \.isUserMessage) else {
            throw error("That conversation has no messages to bring across.")
        }

        let cwd = resolvedCWD(history.cwd ?? conversation.cwd)
        let sessionID = UUID().uuidString.lowercased()
        var writer = ClaudeTranscriptWriter(sessionID: sessionID, cwd: cwd, gitBranch: nil)
        let trimmed = writer.write(history.steps, title: conversation.displayTitle, source: "Gemini (Antigravity)")

        let projectFolder = CodeSessionTransfer.projectsDirectory
            .appendingPathComponent(ClaudeTranscriptWriter.projectSlug(for: cwd), isDirectory: true)
        try FileManager.default.createDirectory(at: projectFolder, withIntermediateDirectories: true)
        let transcriptURL = projectFolder.appendingPathComponent("\(sessionID).jsonl")
        try writer.data.write(to: transcriptURL, options: .atomic)

        let metadataURL = try CodexSessionTransfer.registerSession(
            cliSessionID: sessionID,
            cwd: cwd,
            title: conversation.displayTitle,
            createdAt: conversation.updatedAt ?? Date(),
            in: directory)
        return CodexSessionTransfer.ClaudeImport(sessionID: sessionID, metadataURL: metadataURL, transcriptURL: transcriptURL, trimmed: trimmed)
    }

    /// Copies a Gemini conversation into a ChatGPT / Codex account through Codex's importer.
    static func moveToCodex(_ conversation: Conversation, from source: LaunchProfile, to destination: LaunchProfile) throws -> String {
        let history = try readHistory(of: conversation, from: source)
        guard history.steps.contains(where: \.isUserMessage) else {
            throw error("That conversation has no messages to bring across.")
        }

        let cwd = resolvedCWD(history.cwd ?? conversation.cwd)
        let sessionID = UUID().uuidString.lowercased()
        var writer = ClaudeTranscriptWriter(sessionID: sessionID, cwd: cwd, gitBranch: nil)
        _ = writer.write(history.steps, title: conversation.displayTitle, source: "Gemini (Antigravity)")

        let projectFolder = CodeSessionTransfer.projectsDirectory
            .appendingPathComponent(ClaudeTranscriptWriter.projectSlug(for: cwd), isDirectory: true)
        try FileManager.default.createDirectory(at: projectFolder, withIntermediateDirectories: true)
        let transcriptURL = projectFolder.appendingPathComponent("\(sessionID).jsonl")
        try writer.data.write(to: transcriptURL, options: .atomic)

        let session = CodeSessionTransfer.Session(
            id: sessionID,
            title: conversation.displayTitle,
            cwd: cwd,
            lastActivityAt: conversation.updatedAt,
            fileURL: transcriptURL,
            transcriptURL: transcriptURL)
        return try CodexSessionTransfer.importClaudeSession(session, into: destination)
    }

    // MARK: Transferring INTO Gemini (from any source)

    /// Starts a new Antigravity conversation in `destination` seeded with the given
    /// conversation history. All network work runs through Antigravity's `language_server`.
    static func seedConversation(
        title: String,
        cwd: String,
        sourceLabel: String,
        steps: [CodexStep],
        into destination: LaunchProfile
    ) throws -> SeedResult {
        guard steps.contains(where: \.isUserMessage) else {
            throw error("That conversation has no messages to bring across.")
        }

        let (prompt, truncated) = handoffPrompt(title: title, sourceLabel: sourceLabel, steps: steps)

        return try GeminiAuthStore.withActivatedProfile(destination) {
            let server = try GeminiLanguageServer(appPath: destination.appPath)
            defer { server.stop() }
            guard server.waitForAuth() else {
                throw error("Not signed in to \(ChatTransfer.accountLabel(destination)) in Antigravity.")
            }

            // Pick a valid Gemini model provisioned for the destination account.
            let statusJSON = try? server.rpc("GetUserStatus", timeout: 20)
            let snapshot = statusJSON.map { GeminiLanguageServer.parseUsageSnapshot(userStatusJSON: $0, quotaSummaryJSON: nil) }
            let chosenModel = snapshot.flatMap { GeminiLanguageServer.cheapestGeminiModels(from: $0.models).first }

            var startBody: [String: Any] = [
                "source": "CORTEX_TRAJECTORY_SOURCE_CASCADE_CLIENT",
            ]
            if let chosenModel {
                startBody["requestedModel"] = chosenModel.id
            }
            var isDirectory: ObjCBool = false
            if !cwd.isEmpty, FileManager.default.fileExists(atPath: cwd, isDirectory: &isDirectory), isDirectory.boolValue {
                let uri = URL(fileURLWithPath: cwd).absoluteString
                startBody["workspaceUris"] = [uri]
            }

            let started = try server.rpc("StartCascade", body: startBody, timeout: 15)
            guard let cascadeID = started["cascadeId"] as? String, !cascadeID.isEmpty else {
                throw error("Antigravity didn't create a new conversation.")
            }

            var messageBody: [String: Any] = [
                "cascadeId": cascadeID,
                "items": [["text": prompt]],
            ]
            if let chosenModel {
                messageBody["cascadeConfig"] = [
                    "plannerConfig": [
                        "requestedModel": ["model": chosenModel.id],
                    ],
                ]
            }
            _ = try server.rpc("SendUserCascadeMessage", body: messageBody, timeout: 30)

            // Wait for Antigravity's initial confirmation reply so the conversation is
            // persisted and ready when the user opens Antigravity.
            let deadline = Date().addingTimeInterval(60)
            while Date() < deadline {
                Thread.sleep(forTimeInterval: 0.75)
                if let trajectory = try? server.rpc("GetCascadeTrajectory", body: ["cascadeId": cascadeID], timeout: 10),
                   let responseSteps = (trajectory["trajectory"] as? [String: Any])?["steps"] as? [[String: Any]] {
                    if let errorStep = responseSteps.first(where: { $0["type"] as? String == "CORTEX_STEP_TYPE_ERROR_MESSAGE" }) {
                        let message = ((errorStep["errorMessage"] as? [String: Any])?["error"] as? [String: Any])?["userErrorMessage"] as? String
                            ?? "Antigravity returned an error while seeding the conversation."
                        throw error(message)
                    }
                    let done = responseSteps.contains { step in
                        let type = step["type"] as? String
                        let status = step["status"] as? String
                        return (type == "CORTEX_STEP_TYPE_PLANNER_RESPONSE" || type == "CORTEX_STEP_TYPE_NOTIFY_USER")
                            && status == "CORTEX_STEP_STATUS_DONE"
                    }
                    if done { break }
                }
            }

            return SeedResult(cascadeID: cascadeID, title: title, truncated: truncated)
        }
    }

    /// Formats a conversation for seeding into Antigravity. Keeps the first message and
    /// as much of the tail as fits within `limit`.
    static func handoffPrompt(title: String, sourceLabel: String, steps: [CodexStep], limit: Int = handoffLimit) -> (text: String, truncated: Bool) {
        let intro = """
            This conversation (“\(title)”) is being continued here from \(sourceLabel) via LLMCodeBar. \
            The history so far is below: read it, pick up with the exact same context and decisions, \
            and reply with a brief summary of where things stand and what you'd do next. \
            Do not modify any files or run commands yet — wait for my next message.
            """
        let blocks = steps.compactMap(formatStep)
        let budget = max(2_000, limit - intro.utf8.count - 96)

        var kept = blocks
        var truncated = false
        if blocks.reduce(0, { $0 + $1.utf8.count + 2 }) > budget, let first = blocks.first {
            truncated = true
            var tail: [String] = []
            var used = first.utf8.count + 120
            for block in blocks.dropFirst().reversed() {
                let size = block.utf8.count + 2
                if used + size > budget { break }
                tail.insert(block, at: 0)
                used += size
            }
            let omitted = max(0, blocks.count - 1 - tail.count)
            kept = [first] + (omitted > 0 ? ["[\(omitted) earlier message\(omitted == 1 ? "" : "s") left out to fit.]"] : []) + tail
            if used > budget {
                kept = [String(first.prefix(budget))]
            }
        }
        let body = intro + "\n\n<conversation>\n" + kept.joined(separator: "\n\n") + "\n</conversation>"
        return (body, truncated)
    }

    private static func formatStep(_ step: CodexStep) -> String? {
        switch step {
        case let .user(text, _):
            let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return body.isEmpty ? nil : "## User\n\n\(body)"
        case let .agent(text, _):
            let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return body.isEmpty ? nil : "## Assistant\n\n\(body)"
        case let .command(command, output, failed, _):
            let shown = output.count > 600 ? String(output.prefix(600)) + "\n…" : output
            return "## Assistant ran `\(command)`\(failed ? " (failed)" : "")" + (shown.isEmpty ? "" : "\n\n```\n\(shown)\n```")
        case let .note(text, _):
            let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return body.isEmpty ? nil : "_\(body)_"
        }
    }

    private static func resolvedCWD(_ cwd: String) -> String {
        var isDir: ObjCBool = false
        if !cwd.isEmpty, FileManager.default.fileExists(atPath: cwd, isDirectory: &isDir), isDir.boolValue {
            return cwd
        }
        return FileManager.default.homeDirectoryForCurrentUser.path
    }

    // MARK: Reading summaries from `agyhub_summaries_proto.pb` (Protobuf wire decoder)

    /// Parses Antigravity's `agyhub_summaries_proto.pb` without any external protobuf library.
    /// Wire layout: top-level repeated field 1 (`Entry { field 1: cascadeId, field 2: CascadeTrajectorySummary }`),
    /// where `CascadeTrajectorySummary` carries field 1 = title, field 2 = stepCount,
    /// field 3 = Timestamp(lastModifiedTime), field 9 = Workspace(field 1 = workspaceFolderAbsoluteUri).
    static func parseSummariesProtobuf(_ data: Data) -> [Conversation] {
        var conversations: [Conversation] = []
        for field in ProtobufWire.readFields(data) where field.number == 1 {
            guard case let .bytes(entryData) = field.value else { continue }
            var id: String?
            var summaryData: Data?
            for entryField in ProtobufWire.readFields(entryData) {
                if entryField.number == 1, case let .bytes(bytes) = entryField.value {
                    id = String(data: bytes, encoding: .utf8)
                } else if entryField.number == 2, case let .bytes(bytes) = entryField.value {
                    summaryData = bytes
                }
            }
            guard let id, !id.isEmpty, let summaryData else { continue }

            var title = ""
            var stepCount = 0
            var updatedAt: Date?
            var cwd = ""

            for sub in ProtobufWire.readFields(summaryData) {
                switch (sub.number, sub.value) {
                case (1, let .bytes(bytes)):
                    title = String(data: bytes, encoding: .utf8) ?? ""
                case (2, let .varint(count)):
                    stepCount = Int(count)
                case (3, let .bytes(tsData)):
                    updatedAt = parseProtoTimestamp(tsData)
                case (9, let .bytes(wsData)) where cwd.isEmpty:
                    if let uri = firstStringField(in: wsData, number: 1) ?? firstStringField(in: wsData, number: 2) {
                        cwd = filePath(fromURI: uri)
                    }
                default:
                    break
                }
            }
            conversations.append(Conversation(id: id, title: title, cwd: cwd, updatedAt: updatedAt, stepCount: stepCount))
        }
        return conversations
    }

    private static func parseProtoTimestamp(_ data: Data) -> Date? {
        var seconds: Int64?
        var nanos: Int64 = 0
        for field in ProtobufWire.readFields(data) {
            if field.number == 1, case let .varint(v) = field.value {
                seconds = Int64(bitPattern: v)
            } else if field.number == 2, case let .varint(v) = field.value {
                nanos = Int64(bitPattern: v)
            }
        }
        guard let seconds, seconds > 0 else { return nil }
        return Date(timeIntervalSince1970: Double(seconds) + Double(nanos) / 1_000_000_000)
    }

    private static func firstStringField(in data: Data, number: Int) -> String? {
        for field in ProtobufWire.readFields(data) where field.number == number {
            if case let .bytes(bytes) = field.value, let text = String(data: bytes, encoding: .utf8), !text.isEmpty {
                return text
            }
        }
        return nil
    }

    private static func readSummariesSQLite(database: URL) -> [Conversation] {
        var db: OpaquePointer?
        let escaped = database.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? database.path
        guard sqlite3_open_v2("file:\(escaped)?mode=ro", &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK, let db else {
            sqlite3_close(db)
            return []
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 1000)

        let sql = """
            SELECT conversation_id, title, workspace_uris, step_count, last_modified_time
            FROM conversation_summaries
            WHERE parent_conversation_id = '' AND step_count > 0
            ORDER BY last_modified_time DESC
            LIMIT 200
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return [] }
        defer { sqlite3_finalize(stmt) }

        func text(_ col: Int32) -> String {
            sqlite3_column_text(stmt, col).map { String(cString: $0) } ?? ""
        }

        var results: [Conversation] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = text(0)
            guard !id.isEmpty else { continue }
            let title = text(1)
            let urisRaw = text(2)
            let steps = Int(sqlite3_column_int64(stmt, 3))
            let modifiedRaw = text(4)
            let cwd = firstPath(fromWorkspaceURIsJSON: urisRaw)
            let updatedAt = parseSQLiteDate(modifiedRaw)
            results.append(Conversation(id: id, title: title, cwd: cwd, updatedAt: updatedAt, stepCount: steps))
        }
        return results
    }

    private static func firstPath(fromWorkspaceURIsJSON raw: String) -> String {
        guard let data = raw.data(using: .utf8),
              let uris = try? JSONSerialization.jsonObject(with: data) as? [String],
              let first = uris.first else {
            return ""
        }
        return filePath(fromURI: first)
    }

    static func filePath(fromURI uri: String) -> String {
        if let url = URL(string: uri), url.isFileURL {
            return url.path
        }
        return uri
    }

    private static func parseSQLiteDate(_ raw: String) -> Date? {
        let iso = raw.replacingOccurrences(of: " ", with: "T")
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return fractional.date(from: iso) ?? plain.date(from: iso)
    }

    private static func error(_ message: String) -> NSError {
        NSError(domain: "LLMUsageBar.GeminiSessionTransfer", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

// MARK: - Parsing an Antigravity trajectory into shared CodexStep values

struct GeminiConversationHistory {
    var cwd: String?
    var steps: [CodexStep]

    static func parseSteps(from trajectory: [String: Any]) -> [CodexStep] {
        let rawSteps = (trajectory["steps"] as? [[String: Any]]) ?? []
        var steps: [CodexStep] = []

        for step in rawSteps {
            let type = step["type"] as? String ?? ""
            let metadata = step["metadata"] as? [String: Any]
            let date = ((metadata?["completedAt"] as? String) ?? (metadata?["createdAt"] as? String)).flatMap(parseISODate)

            switch type {
            case "CORTEX_STEP_TYPE_USER_INPUT":
                guard let userInput = step["userInput"] as? [String: Any],
                      let items = userInput["items"] as? [[String: Any]] else { continue }
                var parts: [String] = []
                for item in items {
                    if let text = item["text"] as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        parts.append(text.trimmingCharacters(in: .whitespacesAndNewlines))
                    } else if let ref = item["item"] as? [String: Any],
                              let range = ref["fileLineRange"] as? [String: Any],
                              let uri = range["absoluteUri"] as? String {
                        parts.append("[\(GeminiSessionTransfer.filePath(fromURI: uri))]")
                    }
                }
                let joined = parts.joined(separator: "\n")
                if !joined.isEmpty {
                    steps.append(.user(joined, date))
                }

            case "CORTEX_STEP_TYPE_PLANNER_RESPONSE":
                guard let response = step["plannerResponse"] as? [String: Any] else { continue }
                let text = ((response["modifiedResponse"] as? String) ?? (response["response"] as? String) ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty {
                    steps.append(.agent(text, date))
                }

            case "CORTEX_STEP_TYPE_NOTIFY_USER":
                guard let notify = step["notifyUser"] as? [String: Any] else { continue }
                let text = ((notify["notificationContent"] as? String) ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty {
                    steps.append(.agent(text, date))
                }

            case "CORTEX_STEP_TYPE_RUN_COMMAND":
                guard let run = step["runCommand"] as? [String: Any] else { continue }
                let command = ((run["commandLine"] as? String) ?? (run["proposedCommandLine"] as? String) ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !command.isEmpty else { continue }
                let output: String
                if let combined = run["combinedOutput"] as? [String: Any] {
                    output = (combined["full"] as? String) ?? ""
                } else if let combined = run["combinedOutput"] as? String {
                    output = combined
                } else {
                    output = ""
                }
                let failed = (run["exitCode"] as? Int ?? 0) != 0
                steps.append(.command(command, output: output, failed: failed, date))

            case "CORTEX_STEP_TYPE_CODE_ACTION":
                if let action = step["codeAction"] as? [String: Any],
                   let spec = action["actionSpec"] as? [String: Any],
                   let uri = (spec["createFile"] as? [String: Any])?["path"] as? String
                       ?? (spec["editFile"] as? [String: Any])?["path"] as? String {
                    steps.append(.note("Edited `\(GeminiSessionTransfer.filePath(fromURI: uri))`", date))
                }

            default:
                break
            }
        }
        return steps
    }

    private static func parseISODate(_ raw: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return fractional.date(from: raw) ?? plain.date(from: raw)
    }
}

// MARK: - Minimal Protobuf Wire Reader

enum ProtobufWire {
    enum Value {
        case varint(UInt64)
        case bytes(Data)
        case fixed64(UInt64)
        case fixed32(UInt32)
    }

    struct Field {
        var number: Int
        var value: Value
    }

    static func readFields(_ data: Data) -> [Field] {
        var fields: [Field] = []
        var offset = 0
        let bytes = Array(data)
        let count = bytes.count

        while offset < count {
            guard let (tag, afterTag) = readVarint(bytes, offset: offset) else { break }
            offset = afterTag
            let fieldNumber = Int(tag >> 3)
            let wireType = Int(tag & 0x07)
            guard fieldNumber > 0 else { break }

            switch wireType {
            case 0:
                guard let (val, next) = readVarint(bytes, offset: offset) else { return fields }
                fields.append(Field(number: fieldNumber, value: .varint(val)))
                offset = next
            case 1:
                guard offset + 8 <= count else { return fields }
                var val: UInt64 = 0
                for i in 0..<8 { val |= UInt64(bytes[offset + i]) << (i * 8) }
                fields.append(Field(number: fieldNumber, value: .fixed64(val)))
                offset += 8
            case 2:
                guard let (length, afterLen) = readVarint(bytes, offset: offset) else { return fields }
                let len = Int(length)
                guard len >= 0, afterLen + len <= count else { return fields }
                fields.append(Field(number: fieldNumber, value: .bytes(Data(bytes[afterLen..<(afterLen + len)]))))
                offset = afterLen + len
            case 5:
                guard offset + 4 <= count else { return fields }
                var val: UInt32 = 0
                for i in 0..<4 { val |= UInt32(bytes[offset + i]) << (i * 8) }
                fields.append(Field(number: fieldNumber, value: .fixed32(val)))
                offset += 4
            default:
                return fields
            }
        }
        return fields
    }

    private static func readVarint(_ bytes: [UInt8], offset: Int) -> (UInt64, Int)? {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        var idx = offset
        while idx < bytes.count {
            let byte = bytes[idx]
            idx += 1
            result |= UInt64(byte & 0x7F) << shift
            if (byte & 0x80) == 0 {
                return (result, idx)
            }
            shift += 7
            if shift >= 64 { return nil }
        }
        return nil
    }
}

import AppKit
import SQLite3

/// Moving a coding session between Claude Code and Codex, in either direction.
///
/// The two agents keep their sessions in unrelated formats, so unlike a Claude to Claude
/// move nothing can be shared - the session is translated and the destination gets its own
/// copy. Afterwards the two are independent: what you say in one doesn't reach the other.
///
/// - Claude Code to Codex goes through Codex's own importer. The `codex` binary bundled in
///   ChatGPT.app runs an app server that can import Claude Code transcripts
///   (`externalAgentConfig/import`), the same path ChatGPT's "import from Claude Code" uses,
///   so the thread comes out exactly as Codex would make it.
/// - Codex to Claude Code has no importer on Claude's side, so we write the transcript
///   ourselves: Codex's messages become Claude's messages, its shell commands become real
///   `Bash` calls with their output, and file edits and other tools become short notes.
///   Then the session is registered with the destination account the way a Claude to
///   Claude move is.
enum CodexSessionTransfer {
    struct Thread: Equatable {
        var id: String
        var title: String
        var cwd: String
        var updatedAt: Date?
        var rolloutURL: URL

        var projectName: String {
            let name = URL(fileURLWithPath: cwd).lastPathComponent
            return name.isEmpty ? cwd : name
        }

        var displayTitle: String {
            let firstLine = title
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .components(separatedBy: .newlines).first ?? ""
            return firstLine.isEmpty ? projectName : firstLine
        }
    }

    // MARK: Where a ChatGPT account keeps Codex

    /// The `CODEX_HOME` a ChatGPT profile runs with. Profiles LLMCodeBar created keep their
    /// own under the data dir, the same place `CodexAuthStore` looks for their login.
    static func codexHome(for profile: LaunchProfile) -> URL {
        let own = URL(fileURLWithPath: Launcher.expanding(profile.dataDir), isDirectory: true)
            .appendingPathComponent("CodexHome", isDirectory: true)
        if FileManager.default.fileExists(atPath: own.appendingPathComponent("auth.json").path) {
            return own
        }
        if let env = ProcessInfo.processInfo.environment["CODEX_HOME"], !env.isEmpty {
            return URL(fileURLWithPath: env, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex", isDirectory: true)
    }

    /// The bundled CLI first, since it's the one that matches the app's storage format.
    static func codexExecutable(for profile: LaunchProfile) -> URL? {
        let app = Launcher.expanding(profile.appPath)
        let candidates = [
            "\(app)/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
            "\(app)/Contents/Resources/codex-cli/bin/codex",
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
        ]
        return candidates
            .first { FileManager.default.isExecutableFile(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
    }

    // MARK: Listing

    /// The account's Codex threads, newest first. Read straight from Codex's own thread
    /// index, so the list matches the app's sidebar: no archived threads, and no subagent
    /// threads (reviewers and helpers Codex spawns on its own, which have a JSON source).
    static func threads(for profile: LaunchProfile, limit: Int = 200) -> [Thread] {
        guard let database = stateDatabase(in: codexHome(for: profile)) else { return [] }

        var handle: OpaquePointer?
        guard sqlite3_open_v2(database.path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(handle)
            return []
        }
        defer { sqlite3_close(handle) }
        sqlite3_busy_timeout(handle, 2000)

        let query = """
            SELECT id, rollout_path, cwd, COALESCE(NULLIF(name, ''), title), recency_at_ms
            FROM threads
            WHERE archived = 0 AND preview <> '' AND source NOT LIKE '{%'
            ORDER BY recency_at_ms DESC
            LIMIT \(limit)
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, query, -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }

        func text(_ column: Int32) -> String {
            sqlite3_column_text(statement, column).map { String(cString: $0) } ?? ""
        }

        var threads: [Thread] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let rollout = text(1)
            guard !rollout.isEmpty, FileManager.default.fileExists(atPath: rollout) else { continue }
            let recency = sqlite3_column_int64(statement, 4)
            threads.append(Thread(
                id: text(0),
                title: text(3),
                cwd: text(2),
                updatedAt: recency > 0 ? Date(timeIntervalSince1970: Double(recency) / 1000) : nil,
                rolloutURL: URL(fileURLWithPath: rollout)))
        }
        return threads
    }

    /// `state_<n>.sqlite`, newest schema version first - the number goes up when Codex
    /// migrates, and an old file can be left behind.
    private static func stateDatabase(in home: URL) -> URL? {
        let files = (try? FileManager.default.contentsOfDirectory(at: home, includingPropertiesForKeys: nil)) ?? []
        return files
            .filter { $0.lastPathComponent.hasPrefix("state_") && $0.pathExtension == "sqlite" }
            .max { version(of: $0) < version(of: $1) }
    }

    private static func version(of url: URL) -> Int {
        Int(url.deletingPathExtension().lastPathComponent.dropFirst("state_".count)) ?? 0
    }

    // MARK: Claude Code to Codex

    /// Imports a Claude Code session into a ChatGPT account and returns the new thread id.
    static func importClaudeSession(_ session: CodeSessionTransfer.Session, into destination: LaunchProfile) throws -> String {
        guard let transcript = session.transcriptURL else {
            throw error("That session's transcript is no longer on disk, so there's nothing to hand over.")
        }
        guard let executable = codexExecutable(for: destination) else {
            throw error("Couldn't find Codex inside \(Launcher.expanding(destination.appPath)). Update the ChatGPT app, then try again.")
        }
        let home = codexHome(for: destination)

        let server = try CodexAppServer(executable: executable, codexHome: home)
        defer { server.stop() }

        _ = try server.request("initialize", params: [
            "clientInfo": ["name": "llmcodebar", "title": "LLMCodeBar", "version": appVersion],
            "capabilities": ["experimentalApi": true],
        ])
        server.notify("initialized")

        let item: [String: Any] = [
            "itemType": "SESSIONS",
            "description": "Claude Code session moved by LLMCodeBar",
            "cwd": NSNull(),
            "details": ["sessions": [[
                "cwd": session.cwd,
                "path": transcript.path,
                "title": session.displayTitle,
            ]]],
        ]
        let response = try server.request("externalAgentConfig/import", params: ["migrationItems": [item]])
        let importID = response["importId"] as? String
        let completed = try server.waitForNotification("externalAgentConfig/import/completed", timeout: 180) { params in
            importID == nil || params["importId"] as? String == importID
        }

        let results = (completed["itemTypeResults"] as? [[String: Any]]) ?? []
        let successes = results.flatMap { ($0["successes"] as? [[String: Any]]) ?? [] }
        if let thread = successes.compactMap({ $0["target"] as? String }).first {
            return thread
        }
        let failures = results.flatMap { ($0["failures"] as? [[String: Any]]) ?? [] }
        if let message = failures.compactMap({ $0["message"] as? String }).first {
            throw error("Codex couldn't import it: \(message)")
        }
        // Neither a success nor a failure means Codex has already imported this exact
        // transcript (it remembers each one by content hash) - point at that thread.
        if let existing = previouslyImportedThread(source: transcript, codexHome: home) {
            return existing
        }
        throw error("Codex finished the import without creating a thread.")
    }

    private static func previouslyImportedThread(source: URL, codexHome: URL) -> String? {
        let registry = codexHome.appendingPathComponent("external_agent_session_imports.json")
        guard let data = try? Data(contentsOf: registry),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let records = json["records"] as? [[String: Any]] else {
            return nil
        }
        return records
            .filter { $0["source_path"] as? String == source.path }
            .max { ($0["imported_at"] as? Double ?? 0) < ($1["imported_at"] as? Double ?? 0) }?["imported_thread_id"] as? String
    }

    /// Opens a thread in ChatGPT. `codex://threads/<id>` is the app's own link to a thread;
    /// launching first matters because a cold app drops a link that arrives while it boots.
    static func openThread(_ threadID: String, in profile: LaunchProfile) {
        let wasRunning = RunningProfileDetector.isRunning(profile)
        try? Launcher.launch(profile)
        guard let url = URL(string: "codex://threads/\(threadID)") else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + (wasRunning ? 0.4 : 4)) {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: Codex to Claude Code

    struct ClaudeImport {
        var sessionID: String
        var metadataURL: URL
        var transcriptURL: URL
        /// True when old tool output had to be left out to keep the transcript a size
        /// Claude can actually pick up.
        var trimmed: Bool
    }

    /// Writes a Codex thread out as a Claude Code session in the destination account.
    static func moveThread(_ thread: Thread, to destination: LaunchProfile) throws -> ClaudeImport {
        guard let directory = CodeSessionTransfer.sessionsDirectory(
                for: destination,
                orgID: destination.organizationUUID,
                creatingIfNeeded: true) else {
            throw error("Couldn't find where \(ChatTransfer.accountLabel(destination)) keeps its Code sessions. Open Claude Code in that account once, then try again.")
        }

        let rollout = try CodexRollout(url: thread.rolloutURL)
        guard rollout.steps.contains(where: \.isUserMessage) else {
            throw error("That thread has no messages to bring across.")
        }
        let cwd = rollout.cwd ?? thread.cwd
        let sessionID = UUID().uuidString.lowercased()

        var writer = ClaudeTranscriptWriter(sessionID: sessionID, cwd: cwd, gitBranch: rollout.gitBranch)
        let trimmed = writer.write(rollout.steps, title: thread.displayTitle)

        let projectFolder = CodeSessionTransfer.projectsDirectory
            .appendingPathComponent(ClaudeTranscriptWriter.projectSlug(for: cwd), isDirectory: true)
        try FileManager.default.createDirectory(at: projectFolder, withIntermediateDirectories: true)
        let transcriptURL = projectFolder.appendingPathComponent("\(sessionID).jsonl")
        try writer.data.write(to: transcriptURL, options: .atomic)

        let metadataURL = try registerSession(
            cliSessionID: sessionID,
            cwd: cwd,
            title: thread.displayTitle,
            createdAt: rollout.startedAt ?? thread.updatedAt ?? Date(),
            in: directory)
        return ClaudeImport(sessionID: sessionID, metadataURL: metadataURL, transcriptURL: transcriptURL, trimmed: trimmed)
    }

    /// The desktop app's record of a session: the file that makes it show up in the Code
    /// list. Model, effort and permission mode follow whatever the account used last, so
    /// the moved session behaves like the account's own.
    private static func registerSession(cliSessionID: String, cwd: String, title: String, createdAt: Date, in directory: URL) throws -> URL {
        let newest = (try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]))?
            .filter { $0.lastPathComponent.hasPrefix("local_") && $0.pathExtension == "json" }
            .max { left, right in
                let leftDate = (try? left.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                let rightDate = (try? right.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                return leftDate < rightDate
            }
        let template = newest
            .flatMap { try? Data(contentsOf: $0) }
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]

        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let localID = "local_\(UUID().uuidString.lowercased())"
        var json: [String: Any] = [
            "sessionId": localID,
            "cliSessionId": cliSessionID,
            "cwd": cwd,
            "originCwd": cwd,
            "createdAt": Int64(createdAt.timeIntervalSince1970 * 1000),
            "lastActivityAt": now,
            "lastFocusedAt": now,
            "isArchived": false,
            "title": title,
            "titleSource": "user",
            "permissionMode": template["permissionMode"] as? String ?? "default",
            "alwaysAllowedReasons": [String](),
            "sessionPermissionUpdates": [Any](),
        ]
        for key in ["model", "effort", "chromePermissionMode"] {
            if let value = template[key] {
                json[key] = value
            }
        }

        let target = directory.appendingPathComponent("\(localID).json")
        let encoded = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
        try encoded.write(to: target, options: .atomic)
        return target
    }

    private static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    static func error(_ message: String) -> NSError {
        NSError(domain: "LLMUsageBar.CodexSessionTransfer", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

// MARK: - Reading a Codex thread

/// One thing that happened in a Codex thread, reduced to what Claude can make sense of.
enum CodexStep {
    case user(String, Date?)
    case agent(String, Date?)
    case command(String, output: String, failed: Bool, Date?)
    /// Anything without a Claude equivalent - file edits, MCP calls, web searches -
    /// summarised as a line of the agent's own narration.
    case note(String, Date?)

    var isUserMessage: Bool {
        if case .user = self { return true }
        return false
    }
}

/// A Codex rollout file (`~/.codex/sessions/.../rollout-*.jsonl`).
///
/// Every record the UI shows is logged as an `item_completed` event, which is the easiest
/// stream to follow: it carries what the user actually typed rather than the context Codex
/// wraps around it, and a command arrives with its output already attached. Older rollouts
/// predate those events and log `user_message` / `agent_message` instead.
struct CodexRollout {
    var cwd: String?
    var gitBranch: String?
    var startedAt: Date?
    var steps: [CodexStep] = []

    init(url: URL) throws {
        guard let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8) else {
            throw CodexSessionTransfer.error("Couldn't read that Codex thread.")
        }

        var itemSteps: [CodexStep] = []
        var legacySteps: [CodexStep] = []

        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let record = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let payload = record["payload"] as? [String: Any] else {
                continue
            }
            let date = (record["timestamp"] as? String).flatMap(Self.parseDate)

            switch record["type"] as? String {
            case "session_meta":
                cwd = payload["cwd"] as? String
                gitBranch = (payload["git"] as? [String: Any])?["branch"] as? String
                startedAt = (payload["timestamp"] as? String).flatMap(Self.parseDate) ?? date

            case "event_msg":
                switch payload["type"] as? String {
                case "item_completed":
                    if let item = payload["item"] as? [String: Any], let step = Self.step(for: item, date: date) {
                        itemSteps.append(step)
                    }
                case "user_message":
                    if let message = payload["message"] as? String, !message.isEmpty {
                        legacySteps.append(.user(message, date))
                    }
                case "agent_message":
                    if let message = payload["message"] as? String, !message.isEmpty {
                        legacySteps.append(.agent(message, date))
                    }
                default:
                    break
                }

            default:
                break
            }
        }

        steps = itemSteps.contains(where: \.isUserMessage) ? itemSteps : legacySteps
    }

    private static func step(for item: [String: Any], date: Date?) -> CodexStep? {
        switch item["type"] as? String {
        case "UserMessage":
            let parts = (item["content"] as? [[String: Any]]) ?? []
            var text = parts.compactMap { $0["text"] as? String }.joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let images = parts.compactMap { part -> String? in
                guard (part["type"] as? String)?.contains("image") == true else { return nil }
                return (part["path"] as? String) ?? (part["url"] as? String) ?? "image"
            }
            if !images.isEmpty {
                text += "\n\n" + images.map { "[Image attached in Codex: \($0)]" }.joined(separator: "\n")
            }
            return text.isEmpty ? nil : .user(text, date)

        case "AgentMessage":
            let text = ((item["content"] as? [[String: Any]]) ?? [])
                .compactMap { $0["text"] as? String }
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : .agent(text, date)

        case "CommandExecution":
            let command: String
            if let argv = item["command"] as? [String] {
                // Codex runs everything as `<shell> -lc <script>`; the script is the command.
                command = argv.count >= 3 && argv[argv.count - 2] == "-lc" ? argv[argv.count - 1] : argv.joined(separator: " ")
            } else {
                command = (item["command"] as? String) ?? ""
            }
            guard !command.isEmpty else { return nil }
            let output = (item["aggregated_output"] as? String) ?? (item["formatted_output"] as? String) ?? (item["stdout"] as? String) ?? ""
            let exitCode = (item["exit_code"] as? Int) ?? 0
            return .command(command, output: output, failed: exitCode != 0, date)

        case "FileChange":
            let changes = (item["changes"] as? [String: [String: Any]]) ?? [:]
            guard !changes.isEmpty else { return nil }
            let lines = changes.keys.sorted().map { path -> String in
                let change = changes[path] ?? [:]
                switch change["type"] as? String {
                case "add":
                    return "Created `\(path)`"
                case "delete":
                    return "Deleted `\(path)`"
                default:
                    let diff = (change["unified_diff"] as? String).map { "\n```diff\n\(ClaudeTranscriptWriter.clip($0, to: 1500))\n```" } ?? ""
                    return "Edited `\(path)`\(diff)"
                }
            }
            return .note(lines.joined(separator: "\n"), date)

        case "McpToolCall":
            let server = item["server"] as? String ?? "tool"
            let tool = item["tool"] as? String ?? ""
            return .note("Used `\(server).\(tool)` in Codex.", date)

        case "WebSearch":
            let query = (item["query"] as? String) ?? ""
            return .note(query.isEmpty ? "Searched the web." : "Searched the web for “\(query)”.", date)

        default:
            return nil
        }
    }

    private static func parseDate(_ raw: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: raw) ?? ISO8601DateFormatter().date(from: raw)
    }
}

// MARK: - Writing a Claude Code transcript

/// Builds `~/.claude/projects/<slug>/<session id>.jsonl` the way Claude Code writes it:
/// one JSON object per message, each pointing at the one before through `parentUuid`.
struct ClaudeTranscriptWriter {
    /// Around 100k tokens. Codex threads routinely run past a million tokens of tool
    /// output; carried over whole, the session would be too big to send on its first turn.
    static let characterBudget = 400_000
    static let outputLimit = 2_000

    let sessionID: String
    let cwd: String
    let gitBranch: String?
    private(set) var data = Data()
    private var lastUUID: String?
    /// Claude Code writes each block of one model reply as its own line, all under the
    /// reply's message id, and merges them back when it sends the history. Consecutive
    /// assistant lines share an id here for the same reason.
    private var assistantMessageID: String?

    init(sessionID: String, cwd: String, gitBranch: String?) {
        self.sessionID = sessionID
        self.cwd = cwd
        self.gitBranch = gitBranch
    }

    /// Claude Code names a project folder after its path with every character that isn't
    /// a letter or digit turned into a dash.
    static func projectSlug(for path: String) -> String {
        String(path.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) && $0.isASCII ? Character($0) : "-" })
    }

    static func clip(_ text: String, to limit: Int) -> String {
        guard text.count > limit else { return text }
        let head = text.prefix(limit * 2 / 3)
        let tail = text.suffix(limit / 4)
        return "\(head)\n… [\(text.count - head.count - tail.count) characters left out] …\n\(tail)"
    }

    /// Writes the steps out. Returns true when older tool output had to be dropped to fit.
    mutating func write(_ steps: [CodexStep], title: String) -> Bool {
        let (fitted, trimmed) = Self.fit(steps)

        appendEntry([
            "type": "user",
            "isMeta": true,
            "message": ["role": "user", "content": [[
                "type": "text",
                "text": """
                <system-reminder>This session was moved here from Codex (the ChatGPT app). \
                Everything below happened there: the messages are what was said, and the commands \
                ran with Codex's tools. Files may have changed since, so check them again before \
                relying on what the history says about them.\(trimmed ? " Older tool output was left out to keep the history a workable size." : "")</system-reminder>
                """,
            ]]],
        ], date: steps.first.flatMap(Self.date))

        for step in fitted {
            switch step {
            case let .user(text, date):
                appendEntry(["type": "user", "message": ["role": "user", "content": text]], date: date)

            case let .agent(text, date), let .note(text, date):
                appendAssistant([["type": "text", "text": text]], stopReason: "end_turn", date: date)

            case let .command(command, output, failed, date):
                let toolID = "toolu_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
                appendAssistant([[
                    "type": "tool_use",
                    "id": toolID,
                    "name": "Bash",
                    "input": ["command": command, "description": "Ran in Codex"],
                ]], stopReason: "tool_use", date: date)
                let clipped = Self.clip(output, to: Self.outputLimit)
                appendEntry([
                    "type": "user",
                    "message": ["role": "user", "content": [[
                        "type": "tool_result",
                        "tool_use_id": toolID,
                        "content": clipped.isEmpty ? "(no output)" : clipped,
                        "is_error": failed,
                    ]]],
                    "toolUseResult": ["stdout": clipped, "stderr": "", "interrupted": false, "isImage": false],
                ], date: date)
            }
        }

        appendLine(["type": "custom-title", "customTitle": title, "sessionId": sessionID])
        return trimmed
    }

    /// Drops tool output from the oldest end until the history fits the budget, then whole
    /// commands and notes if it still doesn't. Messages are always kept.
    private static func fit(_ steps: [CodexStep]) -> ([CodexStep], Bool) {
        func size(_ step: CodexStep) -> Int {
            switch step {
            case let .user(text, _), let .agent(text, _), let .note(text, _): return text.count
            case let .command(command, output, _, _): return command.count + min(output.count, outputLimit + 80)
            }
        }

        var steps = steps
        var total = steps.reduce(0) { $0 + size($1) }
        guard total > characterBudget else { return (steps, false) }

        for index in steps.indices where total > characterBudget {
            if case let .command(command, output, failed, date) = steps[index], !output.isEmpty {
                let before = size(steps[index])
                steps[index] = .command(command, output: "", failed: failed, date)
                total -= before - size(steps[index])
            }
        }
        var kept: [CodexStep] = []
        for step in steps {
            switch step {
            case .command, .note:
                if total > characterBudget {
                    total -= size(step)
                    continue
                }
            default:
                break
            }
            kept.append(step)
        }
        return (kept, true)
    }

    private static func date(_ step: CodexStep) -> Date? {
        switch step {
        case let .user(_, date), let .agent(_, date), let .note(_, date), let .command(_, _, _, date): return date
        }
    }

    private mutating func appendAssistant(_ content: [[String: Any]], stopReason: String, date: Date?) {
        appendEntry([
            "type": "assistant",
            "message": [
                "id": currentAssistantMessageID(),
                "type": "message",
                "role": "assistant",
                // Claude Code's own marker for messages no model call produced.
                "model": "<synthetic>",
                "content": content,
                "stop_reason": stopReason,
                "stop_sequence": NSNull(),
                "usage": ["input_tokens": 0, "output_tokens": 0],
            ],
        ], date: date)
    }

    private mutating func currentAssistantMessageID() -> String {
        if let assistantMessageID {
            return assistantMessageID
        }
        let id = "msg_codex_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        assistantMessageID = id
        return id
    }

    private mutating func appendEntry(_ fields: [String: Any], date: Date?) {
        if fields["type"] as? String != "assistant" {
            assistantMessageID = nil
        }
        let uuid = UUID().uuidString.lowercased()
        var entry = fields
        entry["uuid"] = uuid
        entry["parentUuid"] = lastUUID ?? NSNull()
        entry["isSidechain"] = false
        entry["userType"] = "external"
        entry["sessionId"] = sessionID
        entry["cwd"] = cwd
        entry["timestamp"] = Self.timestampFormatter.string(from: date ?? Date())
        if let gitBranch {
            entry["gitBranch"] = gitBranch
        }
        appendLine(entry)
        lastUUID = uuid
    }

    private mutating func appendLine(_ object: [String: Any]) {
        guard let line = try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes]) else { return }
        data.append(line)
        data.append(0x0A)
    }

    private static let timestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}

// MARK: - Talking to Codex's app server

/// A short-lived `codex app-server` over stdio: newline-delimited JSON-RPC. It runs
/// against the destination's `CODEX_HOME`, so it writes into the same thread store the
/// ChatGPT app reads.
private final class CodexAppServer {
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let lock = NSLock()
    private let arrived = DispatchSemaphore(value: 0)
    private var buffer = Data()
    private var messages: [[String: Any]] = []
    private var nextID = 1

    init(executable: URL, codexHome: URL) throws {
        try FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: true)
        var environment = ProcessInfo.processInfo.environment
        environment["CODEX_HOME"] = codexHome.path
        process.executableURL = executable
        process.arguments = ["app-server"]
        process.environment = environment
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            self?.receive(handle.availableData)
        }
        try process.run()
    }

    func stop() {
        output.fileHandleForReading.readabilityHandler = nil
        try? input.fileHandleForWriting.close()
        if process.isRunning {
            process.terminate()
        }
    }

    func request(_ method: String, params: [String: Any], timeout: TimeInterval = 30) throws -> [String: Any] {
        let id = nextID
        nextID += 1
        try send(["id": id, "method": method, "params": params])
        let reply = try waitFor(timeout: timeout, description: method) { $0["id"] as? Int == id }
        if let failure = reply["error"] as? [String: Any] {
            throw CodexSessionTransfer.error("Codex refused it: \(failure["message"] as? String ?? "unknown error")")
        }
        return (reply["result"] as? [String: Any]) ?? [:]
    }

    func notify(_ method: String) {
        try? send(["method": method])
    }

    func waitForNotification(_ method: String, timeout: TimeInterval, where matches: @escaping ([String: Any]) -> Bool) throws -> [String: Any] {
        let message = try waitFor(timeout: timeout, description: method) { message in
            message["method"] as? String == method && matches((message["params"] as? [String: Any]) ?? [:])
        }
        return (message["params"] as? [String: Any]) ?? [:]
    }

    private func send(_ message: [String: Any]) throws {
        var line = try JSONSerialization.data(withJSONObject: message)
        line.append(0x0A)
        try input.fileHandleForWriting.write(contentsOf: line)
    }

    private func receive(_ chunk: Data) {
        guard !chunk.isEmpty else { return }
        lock.lock()
        buffer.append(chunk)
        var parsed = 0
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)
            if let message = try? JSONSerialization.jsonObject(with: line) as? [String: Any] {
                messages.append(message)
                parsed += 1
            }
        }
        lock.unlock()
        for _ in 0..<parsed {
            arrived.signal()
        }
    }

    private func waitFor(timeout: TimeInterval, description: String, _ matches: ([String: Any]) -> Bool) throws -> [String: Any] {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            lock.lock()
            if let index = messages.firstIndex(where: matches) {
                let message = messages.remove(at: index)
                lock.unlock()
                return message
            }
            lock.unlock()

            guard process.isRunning else {
                throw CodexSessionTransfer.error("Codex stopped before answering \(description).")
            }
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else {
                throw CodexSessionTransfer.error("Codex took too long to answer \(description).")
            }
            _ = arrived.wait(timeout: .now() + min(remaining, 1))
        }
    }
}

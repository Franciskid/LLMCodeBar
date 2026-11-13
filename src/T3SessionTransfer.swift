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

// MARK: - Into T3

/// Starts a T3 thread from a conversation held elsewhere (a Claude chat, a Claude Code
/// session, a Codex thread). T3 has no way to adopt another agent's session, so the new
/// thread's first message carries the history as text - the same kind of handoff T3
/// itself makes when a thread changes provider. It goes through T3's own `t3` command,
/// so nothing is written into T3's database behind its back.
extension T3SessionTransfer {
    struct Handoff {
        var title: String
        /// Where the thread works. T3 runs it in the project that holds this folder.
        var cwd: String
        /// Where the conversation came from, for the first line ("Claude Code").
        var source: String
        var steps: [CodexStep]
    }

    struct Started {
        var threadID: String
        var projectPath: String
    }

    /// T3 keeps imported history under 64,000 bytes; leave room for the framing.
    static let handoffLimit = 56_000

    /// The `t3` command T3 Code installs for the desktop app.
    static var cliPath = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".t3/bin/t3").path

    static var isInstalled: Bool { FileManager.default.isExecutableFile(atPath: cliPath) }

    /// The first message of the new thread: what this is, how to pick it up, then the
    /// conversation. A long one keeps its first message and as much of the end as fits.
    static func handoffMessage(_ handoff: Handoff) -> String {
        let intro = """
            This conversation was moved here from \(handoff.source) (“\(handoff.title)”) by LLMCodeBar. Its history so far is below, as text: attachments, tool output and anything outside this folder didn't come with it.

            Read it, then reply with a short summary of where things stand and what you'd do next. Don't change anything yet: wait for my next message.
            """
        let blocks = handoff.steps.compactMap(block(for:))
        let budget = handoffLimit - intro.utf8.count - 64
        var kept = blocks
        var omitted = 0
        if blocks.reduce(0, { $0 + $1.utf8.count + 2 }) > budget, let first = blocks.first {
            var tail: [String] = []
            var used = first.utf8.count + 120
            for block in blocks.dropFirst().reversed() {
                let size = block.utf8.count + 2
                if used + size > budget { break }
                tail.insert(block, at: 0)
                used += size
            }
            omitted = blocks.count - 1 - tail.count
            kept = [first] + (omitted > 0 ? ["[\(omitted) message\(omitted == 1 ? "" : "s") left out here to fit.]"] : []) + tail
            if used > budget { kept = [String(first.prefix(budget))] }
        }
        return intro + "\n\n<conversation>\n" + kept.joined(separator: "\n\n") + "\n</conversation>"
    }

    private static func block(for step: CodexStep) -> String? {
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
            return "_\(text)_"
        }
    }

    /// A Claude Code transcript (`~/.claude/projects/…/<id>.jsonl`) reduced to what was
    /// said: user messages, the agent's replies, and which tools it used. Tool results,
    /// side chains and the app's own injected text are left out.
    static func claudeCodeSteps(transcript: URL) throws -> [CodexStep] {
        guard let text = try? String(contentsOf: transcript, encoding: .utf8) else {
            throw CodexSessionTransfer.error("That session's transcript can't be read.")
        }
        var steps: [CodexStep] = []
        for line in text.split(separator: "\n") {
            guard let data = line.data(using: .utf8),
                  let entry = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let type = entry["type"] as? String, type == "user" || type == "assistant",
                  entry["isSidechain"] as? Bool != true, entry["isMeta"] as? Bool != true,
                  let message = entry["message"] as? [String: Any] else { continue }
            let date = (entry["timestamp"] as? String).flatMap(date)
            var texts: [String] = []
            var tools: [String] = []
            if let content = message["content"] as? String {
                texts.append(content)
            } else if let content = message["content"] as? [[String: Any]] {
                for part in content {
                    switch part["type"] as? String {
                    case "text": if let text = part["text"] as? String { texts.append(text) }
                    case "tool_use": if let name = part["name"] as? String { tools.append(name) }
                    default: break
                    }
                }
            }
            let said = texts.map(stripInjected).joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if type == "user" {
                guard !said.isEmpty, !said.hasPrefix("<command-"), !said.hasPrefix("<local-command") else { continue }
                steps.append(.user(said, date))
            } else {
                if !said.isEmpty { steps.append(.agent(said, date)) }
                if !tools.isEmpty { steps.append(.note("Used \(tools.joined(separator: ", "))", date)) }
            }
        }
        return steps
    }

    /// Removes the reminders the app slips into user messages.
    private static func stripInjected(_ text: String) -> String {
        var result = text
        while let start = result.range(of: "<system-reminder>"),
              let end = result.range(of: "</system-reminder>", range: start.upperBound..<result.endIndex) {
            result.removeSubrange(start.lowerBound..<end.upperBound)
        }
        return result
    }

    /// Creates the thread and returns its id. T3 has to be running; the folder becomes a
    /// T3 project if no project holds it yet (a worktree goes to its repository's project).
    static func start(_ handoff: Handoff) throws -> Started {
        guard isInstalled else {
            throw CodexSessionTransfer.error("T3 Code isn't installed, or hasn't set up its t3 command yet. Open T3 Code once, then try again.")
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: handoff.cwd, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw CodexSessionTransfer.error("The working folder no longer exists: \(handoff.cwd).")
        }
        guard handoff.steps.contains(where: \.isUserMessage) else {
            throw CodexSessionTransfer.error("That conversation has no messages to bring across.")
        }
        let message = handoffMessage(handoff)
        let title = String(handoff.title.prefix(120))
        var candidates = [handoff.cwd]
        if let repository = repositoryRoot(of: handoff.cwd), repository != handoff.cwd { candidates.append(repository) }
        for path in candidates {
            do {
                return Started(threadID: try startThread(in: path, title: title, message: message), projectPath: path)
            } catch let failure as CLIFailure where failure.noProject {
                continue
            }
        }
        // No project holds it: add the folder as one, then start there.
        _ = try runCLI(["project", "add", handoff.cwd])
        return Started(threadID: try startThread(in: handoff.cwd, title: title, message: message), projectPath: handoff.cwd)
    }

    /// Brings T3 Code forward on the project.
    static func open(projectPath: String) {
        DispatchQueue.global(qos: .utility).async { _ = try? runCLI(["app", projectPath]) }
    }

    private static func startThread(in path: String, title: String, message: String) throws -> String {
        let output = try runCLI(["thread", "start", path, "-", "--title", title, "--json"], input: message)
        if let data = output.data(using: .utf8),
           let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
           let id = (json["threadId"] as? String) ?? (json["id"] as? String) {
            return id
        }
        let line = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { throw CodexSessionTransfer.error("T3 didn't say which thread it started.") }
        return line
    }

    struct CLIFailure: LocalizedError {
        var message: String
        var noProject: Bool { message.contains("No T3 Code project matches") }
        var errorDescription: String? {
            let lower = message.lowercased()
            if lower.contains("connect") || lower.contains("not running") || lower.contains("econnrefused") || lower.contains("no running") {
                return "T3 Code isn't running. Open it, then try again."
            }
            return message.isEmpty ? "T3's t3 command failed." : "T3: \(message)"
        }
    }

    /// Runs `t3` with `input` on stdin. Output is small (an id, a line of error).
    private static func runCLI(_ arguments: [String], input: String? = nil, timeout: TimeInterval = 60) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: cliPath)
        process.arguments = arguments
        let output = Pipe(), errors = Pipe(), stdin = Pipe()
        process.standardOutput = output
        process.standardError = errors
        process.standardInput = stdin
        var collected = Data(), collectedErrors = Data()
        let lock = NSLock()
        output.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            lock.lock(); collected.append(chunk); lock.unlock()
        }
        errors.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            lock.lock(); collectedErrors.append(chunk); lock.unlock()
        }
        try process.run()
        if let input { stdin.fileHandleForWriting.write(Data(input.utf8)) }
        try? stdin.fileHandleForWriting.close()
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline { Foundation.Thread.sleep(forTimeInterval: 0.05) }
        if process.isRunning {
            process.terminate()
            throw CodexSessionTransfer.error("T3 took too long to answer. Is T3 Code open?")
        }
        output.fileHandleForReading.readabilityHandler = nil
        errors.fileHandleForReading.readabilityHandler = nil
        lock.lock()
        collected.append(output.fileHandleForReading.readDataToEndOfFile())
        collectedErrors.append(errors.fileHandleForReading.readDataToEndOfFile())
        let text = String(decoding: collected, as: UTF8.self)
        let errorText = String(decoding: collectedErrors, as: UTF8.self)
        lock.unlock()
        guard process.terminationStatus == 0 else {
            throw CLIFailure(message: (errorText + "\n" + text).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return text
    }

    /// The main checkout of the git repository holding `path`, if any.
    private static func repositoryRoot(of path: String) -> String? {
        guard let common = try? ProcessRunner.run("/usr/bin/git", arguments: ["-C", path, "rev-parse", "--path-format=absolute", "--git-common-dir"]) else { return nil }
        let dir = common.trimmingCharacters(in: .whitespacesAndNewlines)
        guard dir.hasSuffix("/.git") else { return nil }
        return String(dir.dropLast(5))
    }
}

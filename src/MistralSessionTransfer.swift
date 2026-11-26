import AppKit
import Foundation

/// Lists and reads local Mistral Vibe unified sessions (`~/.vibe/logs/session/unified/`)
/// so conversations can be transferred between Mistral Vibe, Claude Code, Codex, Gemini
/// (Antigravity), and T3 Code.
enum MistralSessionTransfer {
    struct Session {
        var id: String
        var title: String
        var cwd: String
        var updatedAt: Date?
        var model: String?
        var directoryURL: URL

        var displayTitle: String {
            let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "Untitled Vibe session" : trimmed
        }

        var projectName: String {
            cwd.isEmpty ? "" : URL(fileURLWithPath: cwd).lastPathComponent
        }
    }

    struct CopyResult {
        var metadataURL: URL
        var trimmed: Bool
    }

    struct SeedResult {
        var title: String
        var truncated: Bool
    }

    static var unifiedSessionsDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".vibe/logs/session/unified", isDirectory: true)
    }

    /// Lists local Vibe sessions newest-first from `~/.vibe/logs/session/unified/*/meta.json`.
    static func sessions(in root: URL = unifiedSessionsDirectory, limit: Int = 200) -> [Session] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var collected: [Session] = []
        for dir in entries {
            guard (try? dir.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
            let metaURL = dir.appendingPathComponent("meta.json")
            guard let data = try? Data(contentsOf: metaURL),
                  let meta = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }
            // Skip archived or child sub-sessions so the transfer list stays clean.
            if meta["archived_at"] as? String != nil { continue }
            if meta["parent_session_id"] as? String != nil { continue }

            let id = (meta["session_id"] as? String) ?? dir.lastPathComponent
            let env = meta["environment"] as? [String: Any]
            let cwd = (env?["working_directory"] as? String)
                ?? (meta["origin_directory"] as? String)
                ?? ""
            let updatedAt = parseISODate(meta["bumped_at"] as? String)
                ?? parseISODate(meta["end_time"] as? String)
                ?? parseISODate(meta["start_time"] as? String)
                ?? (try? dir.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
            let config = meta["config"] as? [String: Any]
            let model = (config?["active_model"] as? String) ?? (config?["model_name"] as? String)
            let rawTitle = (meta["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let title = rawTitle.isEmpty ? (cwd.isEmpty ? id : URL(fileURLWithPath: cwd).lastPathComponent) : rawTitle

            collected.append(Session(
                id: id,
                title: title,
                cwd: cwd,
                updatedAt: updatedAt,
                model: model,
                directoryURL: dir))
        }

        return Array(collected
            .sorted { ($0.updatedAt ?? .distantPast) > ($1.updatedAt ?? .distantPast) }
            .prefix(limit))
    }

    /// Reads the user and assistant messages from a Vibe unified session's recovery journal.
    static func readHistory(of session: Session) throws -> (cwd: String?, steps: [CodexStep]) {
        let journalDir = session.directoryURL.appendingPathComponent("journal", isDirectory: true)
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: journalDir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            throw CodexSessionTransfer.error("That Vibe session has no readable journal.")
        }
        let journalFiles = files
            .filter { $0.pathExtension == "jsonl" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        var combinedLines: [String] = []
        for file in journalFiles {
            if let text = try? String(contentsOf: file, encoding: .utf8) {
                combinedLines.append(contentsOf: text.split(separator: "\n").map(String.init))
            }
        }
        let steps = parseJournalLines(combinedLines)
        guard steps.contains(where: \.isUserMessage) else {
            throw CodexSessionTransfer.error("That Vibe session has no completed messages to transfer.")
        }
        return (session.cwd.isEmpty ? nil : session.cwd, steps)
    }

    /// Pure parser for Vibe unified session `journal/*.jsonl` lines. Keeps the latest
    /// revision of each `projection_delta` `entry` with `type == "message"` in order.
    static func parseJournalLines(_ lines: [String]) -> [CodexStep] {
        struct EntryState {
            var id: String
            var role: String
            var text: String
            var timestamp: Date?
        }

        var order: [String] = []
        var byID: [String: EntryState] = [:]

        for line in lines {
            guard !line.isEmpty,
                  let data = line.data(using: .utf8),
                  let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  (obj["type"] as? String) == "projection_delta",
                  let payload = obj["payload"] as? [String: Any],
                  let deltas = payload["delta"] as? [[String: Any]] else {
                continue
            }
            for delta in deltas {
                guard let entry = delta["entry"] as? [String: Any],
                      (entry["type"] as? String) == "message",
                      let role = entry["role"] as? String,
                      role == "user" || role == "assistant" else {
                    continue
                }
                let text = extractText(from: entry["content"])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                let id = (entry["id"] as? String) ?? UUID().uuidString
                let createdAt: Date?
                if let ms = entry["createdAt"] as? Double {
                    createdAt = Date(timeIntervalSince1970: ms > 100_000_000_000 ? ms / 1000.0 : ms)
                } else if let ms = entry["createdAt"] as? Int {
                    let d = Double(ms)
                    createdAt = Date(timeIntervalSince1970: d > 100_000_000_000 ? d / 1000.0 : d)
                } else {
                    createdAt = nil
                }
                if byID[id] == nil {
                    order.append(id)
                }
                byID[id] = EntryState(id: id, role: role, text: text, timestamp: createdAt)
            }
        }

        var steps: [CodexStep] = []
        for id in order {
            guard let item = byID[id] else { continue }
            let cleaned = stripWrapperBlocks(item.text).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleaned.isEmpty else { continue }
            if item.role == "user" {
                steps.append(.user(cleaned, item.timestamp))
            } else {
                steps.append(.agent(cleaned, item.timestamp))
            }
        }
        return steps
    }

    // MARK: Outbound transfers

    static func moveToClaudeCode(_ session: Session, to destination: LaunchProfile) throws -> CopyResult {
        let history = try readHistory(of: session)
        let cwd = try validatedWorkingDirectory(history.cwd ?? session.cwd)
        let sessionID = UUID().uuidString.lowercased()
        var writer = ClaudeTranscriptWriter(sessionID: sessionID, cwd: cwd, gitBranch: nil)
        let trimmed = writer.write(history.steps, title: session.displayTitle, source: "Mistral Vibe")

        let folder = CodeSessionTransfer.projectsDirectory
            .appendingPathComponent(ClaudeTranscriptWriter.projectSlug(for: cwd))
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let transcriptURL = folder.appendingPathComponent("\(sessionID).jsonl")
        try writer.data.write(to: transcriptURL, options: .atomic)

        guard let directory = CodeSessionTransfer.sessionsDirectory(
            for: destination,
            orgID: destination.organizationUUID,
            creatingIfNeeded: true) else {
            throw CodexSessionTransfer.error("Open Claude Code in the destination account once, then try again.")
        }
        let metadata = try CodexSessionTransfer.registerSession(
            cliSessionID: sessionID,
            cwd: cwd,
            title: session.displayTitle,
            createdAt: session.updatedAt ?? Date(),
            in: directory)
        return CopyResult(metadataURL: metadata, trimmed: trimmed)
    }

    static func moveToCodex(_ session: Session, to destination: LaunchProfile) throws -> String {
        let history = try readHistory(of: session)
        let cwd = try validatedWorkingDirectory(history.cwd ?? session.cwd)
        let sessionID = UUID().uuidString.lowercased()
        var writer = ClaudeTranscriptWriter(sessionID: sessionID, cwd: cwd, gitBranch: nil)
        _ = writer.write(history.steps, title: session.displayTitle, source: "Mistral Vibe")

        let folder = CodeSessionTransfer.projectsDirectory
            .appendingPathComponent(ClaudeTranscriptWriter.projectSlug(for: cwd))
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let transcriptURL = folder.appendingPathComponent("\(sessionID).jsonl")
        try writer.data.write(to: transcriptURL, options: .atomic)

        let codeSession = CodeSessionTransfer.Session(
            id: sessionID,
            title: session.displayTitle,
            cwd: cwd,
            lastActivityAt: session.updatedAt,
            fileURL: transcriptURL,
            transcriptURL: transcriptURL)
        return try CodexSessionTransfer.importClaudeSession(codeSession, into: destination)
    }

    static func moveToGemini(_ session: Session, to destination: LaunchProfile) throws -> GeminiSessionTransfer.SeedResult {
        let history = try readHistory(of: session)
        return try GeminiSessionTransfer.seedConversation(
            title: session.displayTitle,
            cwd: history.cwd ?? session.cwd,
            sourceLabel: "Mistral Vibe",
            steps: history.steps,
            into: destination)
    }

    // MARK: Inbound handoff (to Mistral Vibe)

    /// Prepares a compact handoff prompt on the clipboard and opens Mistral Vibe so the user
    /// can paste it into a new session without automatically spending monthly API budget.
    static func prepareHandoffToVibe(
        title: String,
        sourceLabel: String,
        steps: [CodexStep],
        destination: LaunchProfile
    ) throws -> SeedResult {
        guard steps.contains(where: \.isUserMessage) else {
            throw CodexSessionTransfer.error("That conversation has no messages to bring across.")
        }
        let (prompt, truncated) = GeminiSessionTransfer.handoffPrompt(
            title: title,
            sourceLabel: sourceLabel,
            steps: steps)
        DispatchQueue.main.sync {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(prompt, forType: .string)
        }
        return SeedResult(title: title, truncated: truncated)
    }

    // MARK: Helpers

    private static func validatedWorkingDirectory(_ path: String) throws -> String {
        let fallback = FileManager.default.homeDirectoryForCurrentUser.path
        let chosen = path.isEmpty ? fallback : path
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: chosen, isDirectory: &isDir), isDir.boolValue {
            return chosen
        }
        return fallback
    }

    private static func extractText(from content: Any?) -> String {
        if let str = content as? String { return str }
        guard let blocks = content as? [[String: Any]] else { return "" }
        return blocks.compactMap { block -> String? in
            if let text = block["text"] as? String { return text }
            return nil
        }.joined(separator: "\n\n")
    }

    private static func stripWrapperBlocks(_ text: String) -> String {
        var result = text
        for tag in ["t3_code_instructions", "system-reminder"] {
            while let start = result.range(of: "<\(tag)>"),
                  let end = result.range(of: "</\(tag)>", range: start.upperBound..<result.endIndex) {
                result.removeSubrange(start.lowerBound..<end.upperBound)
            }
        }
        return result
    }

    private static func parseISODate(_ raw: String?) -> Date? {
        guard let raw else { return nil }
        let frac = ISO8601DateFormatter()
        frac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return frac.date(from: raw) ?? plain.date(from: raw)
    }
}

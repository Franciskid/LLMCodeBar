import Foundation

/// Moving a Claude Code session between accounts.
///
/// A Code session is almost entirely local, which makes this far simpler than moving a
/// chat. The desktop app keeps one small metadata file per session under
/// `<data dir>/claude-code-sessions/<account uuid>/<org uuid>/local_<id>.json`, and that
/// file only *points* at the transcript - which lives in `~/.claude/projects`, outside
/// any account's storage and shared by every Claude on the machine.
///
/// So a transfer here is a metadata copy. The conversation itself never moves: it arrives
/// whole instead of as a summary, costs no usage, and takes no time. Both accounts end up
/// pointing at the same transcript, so picking the session up in the second account
/// continues the same history rather than a fork of it - as close to one session in two
/// accounts as the machine allows. The catch is that they're the same file: don't run the
/// session in both accounts at once.
enum CodeSessionTransfer {
    struct Session: Equatable {
        /// The app's own id for the session, e.g. `local_e1e969fa-…`. Also the file name.
        var id: String
        var title: String
        var cwd: String
        var lastActivityAt: Date?
        var fileURL: URL
        /// False when the transcript has been cleaned up, which would make the session
        /// arrive empty - worth refusing rather than transferring a shell.
        var hasTranscript: Bool

        /// The folder the session was working in, which is how you actually recognise it.
        var projectName: String {
            let name = URL(fileURLWithPath: cwd).lastPathComponent
            return name.isEmpty ? cwd : name
        }

        var displayTitle: String {
            let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? projectName : trimmed
        }
    }

    /// Fields that belong to the account the session came from - connector ids and the
    /// tools enabled on them are org-scoped, so they'd be meaningless in another account.
    private static let accountScopedKeys = ["remoteMcpServersConfig", "enabledMcpTools"]

    private static let sessionsFolder = "claude-code-sessions"
    private static let sessionPrefix = "local_"

    // MARK: Listing

    /// The most recently active Code sessions in an account. Pure filesystem work, so the
    /// menu can read this on the spot instead of waiting for a refresh.
    static func sessions(for profile: LaunchProfile, orgID: String? = nil, limit: Int = 5) -> [Session] {
        guard let directory = sessionsDirectory(for: profile, orgID: orgID) else { return [] }
        let fileManager = FileManager.default
        guard let files = try? fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]) else {
            return []
        }

        // Sort by file date first so only a handful of files are ever parsed, however
        // many sessions the account has accumulated.
        let candidates = files
            .filter { $0.lastPathComponent.hasPrefix(sessionPrefix) && $0.pathExtension == "json" }
            .sorted { left, right in
                let leftDate = (try? left.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                let rightDate = (try? right.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                return leftDate > rightDate
            }
            .prefix(limit * 3)

        return candidates
            .compactMap(session(at:))
            .sorted { ($0.lastActivityAt ?? .distantPast) > ($1.lastActivityAt ?? .distantPast) }
            .prefix(limit)
            .map { $0 }
    }

    private static func session(at url: URL) -> Session? {
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = json["sessionId"] as? String,
              json["isArchived"] as? Bool != true else {
            return nil
        }
        let cliSessionID = json["cliSessionId"] as? String
        return Session(
            id: id,
            title: (json["title"] as? String) ?? "",
            cwd: (json["cwd"] as? String) ?? "",
            lastActivityAt: (json["lastActivityAt"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) },
            fileURL: url,
            hasTranscript: cliSessionID.map(transcriptExists) ?? false)
    }

    /// Claude Code stores transcripts as `~/.claude/projects/<slugged cwd>/<id>.jsonl`.
    /// The slug rules aren't worth reproducing - just look for the id in any project.
    private static func transcriptExists(cliSessionID: String) -> Bool {
        let projects = URL(fileURLWithPath: NSString(string: "~/.claude/projects").expandingTildeInPath, isDirectory: true)
        guard let folders = try? FileManager.default.contentsOfDirectory(
                at: projects,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]) else {
            return false
        }
        return folders.contains { folder in
            FileManager.default.fileExists(atPath: folder.appendingPathComponent("\(cliSessionID).jsonl").path)
        }
    }

    // MARK: Transferring

    @discardableResult
    static func transfer(session: Session, to destination: LaunchProfile, destinationOrgID: String? = nil) throws -> URL {
        guard session.hasTranscript else {
            throw error("That session's transcript is no longer on disk, so there's nothing to hand over.")
        }
        guard let directory = sessionsDirectory(for: destination, orgID: destinationOrgID, creatingIfNeeded: true) else {
            throw error("Couldn't find where \(ChatTransfer.accountLabel(destination)) keeps its Code sessions. Open Claude Code in that account once, then try again.")
        }

        guard let data = try? Data(contentsOf: session.fileURL),
              var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw error("Couldn't read that session.")
        }

        // Connector ids and the tools enabled on them belong to the account the session
        // came from. Drop them - unless the destination already knows this session, in
        // which case keep what it already had rather than wiping its own settings.
        let target = directory.appendingPathComponent("\(session.id).json")
        let existing = (try? Data(contentsOf: target))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        for key in accountScopedKeys {
            if let inherited = existing?[key] {
                json[key] = inherited
            } else {
                json.removeValue(forKey: key)
            }
        }

        // Land it at the top of the destination's list, where you'd expect to find the
        // session you just moved.
        let now = Date().timeIntervalSince1970 * 1000
        json["lastActivityAt"] = now
        json["lastFocusedAt"] = now

        let encoded = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
        try encoded.write(to: target, options: .atomic)
        return target
    }

    /// The destination app reads this folder once, when it starts: it logs
    /// "Loaded N persisted sessions from …" at launch and never looks again. So a session
    /// dropped in beside a running Claude stays invisible until that Claude restarts,
    /// which is the difference between this feature working and appearing to do nothing.
    static func needsRestartToAppear(_ destination: LaunchProfile) -> Bool {
        RunningProfileDetector.isRunning(destination)
    }

    /// Quits the destination Claude and starts it again so it picks the session up.
    /// Waits for the process to actually go away first - relaunching into a half-dead
    /// instance leaves the app confused about which one owns the data directory.
    static func restart(_ profile: LaunchProfile, completion: @escaping (Bool) -> Void) {
        guard let running = RunningProfileDetector.runningApplication(for: profile) else {
            DispatchQueue.main.async {
                try? Launcher.launch(profile)
                completion(true)
            }
            return
        }

        running.terminate()
        DispatchQueue.global(qos: .userInitiated).async {
            let deadline = Date().addingTimeInterval(15)
            while !running.isTerminated, Date() < deadline {
                Thread.sleep(forTimeInterval: 0.25)
            }
            let stopped = running.isTerminated
            DispatchQueue.main.async {
                if stopped {
                    try? Launcher.launch(profile)
                }
                completion(stopped)
            }
        }
    }

    // MARK: Locating an account's session folder

    /// `<data dir>/claude-code-sessions/<account uuid>/<org uuid>`. The account uuid is
    /// the one already recorded for the profile; the org folder is picked by id when we
    /// know it, and otherwise by whichever one the app has been writing to.
    private static func sessionsDirectory(for profile: LaunchProfile, orgID: String?, creatingIfNeeded: Bool = false) -> URL? {
        guard let accountUUID = profile.accountUUID, !accountUUID.isEmpty else { return nil }
        let accountDirectory = URL(fileURLWithPath: Launcher.expanding(profile.dataDir), isDirectory: true)
            .appendingPathComponent(sessionsFolder, isDirectory: true)
            .appendingPathComponent(accountUUID, isDirectory: true)

        if let orgID, !orgID.isEmpty {
            let directory = accountDirectory.appendingPathComponent(orgID, isDirectory: true)
            if creatingIfNeeded {
                try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            }
            if FileManager.default.fileExists(atPath: directory.path) {
                return directory
            }
        }

        let organizations = (try? FileManager.default.contentsOfDirectory(
            at: accountDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles])) ?? []
        return organizations
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
            .max { left, right in
                let leftDate = (try? left.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                let rightDate = (try? right.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                return leftDate < rightDate
            }
    }

    private static func error(_ message: String) -> NSError {
        NSError(domain: "LLMUsageBar.CodeSessionTransfer", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

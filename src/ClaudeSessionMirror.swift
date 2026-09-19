import Foundation

/// Keeps every Claude account's Code session history in every Claude window.
///
/// The desktop app files each Code session under the *window's* data directory,
/// `<dataDir>/claude-code-sessions/<account uuid>/<org uuid>/local_<id>.json`, and a
/// window lists only the folder of the account it is signed in to. The conversation
/// itself lives in `~/.claude/projects`, shared by every window. So when a re-login
/// lands an account in a different window than usual, nothing is deleted - but that
/// window has an empty folder for the account and its whole history looks gone.
///
/// Mirroring those small metadata files into every window makes the history follow the
/// account wherever it signs in:
///  * A window's copy for the account it is signed in to is live: the app owns it and
///    rewrites it. We only ever add sessions that are missing there, never overwrite.
///  * Every other copy is dormant, and is refreshed whenever the live one moves on.
///  * A session that disappears from a folder we've already seen it in was deleted in
///    the app, and is not brought back there.
///  * Nothing is ever deleted.
enum ClaudeSessionMirror {
    private static let sessionsFolder = "claude-code-sessions"
    private static let sessionPrefix = "local_"

    private struct Copy {
        let dir: String
        let url: URL
        let modified: Date
    }

    /// Mirrors every session into every Claude window and returns, per profile id, how
    /// many sessions were added to the account that window is signed in to. A running
    /// window only reads its sessions when it starts, so those need a restart to show.
    @discardableResult
    static func sync(_ profiles: [LaunchProfile]) -> [String: Int] {
        var windowByDir: [String: LaunchProfile] = [:]
        for profile in profiles where profile.provider == .claude && profile.isPendingLogin != true {
            windowByDir[normalized(profile.dataDir)] = profile
        }
        guard windowByDir.count >= 2 else { return [:] }

        // "account/org/file" -> every copy of that session on disk.
        var copies: [String: [Copy]] = [:]
        for dir in windowByDir.keys {
            let root = URL(fileURLWithPath: dir, isDirectory: true).appendingPathComponent(sessionsFolder, isDirectory: true)
            for account in subdirectories(of: root) {
                for org in subdirectories(of: account) {
                    for file in sessionFiles(in: org) {
                        let key = "\(account.lastPathComponent)/\(org.lastPathComponent)/\(file.lastPathComponent)"
                        copies[key, default: []].append(Copy(dir: dir, url: file, modified: modificationDate(file)))
                    }
                }
            }
        }

        var seen = loadSeen()
        var restored: [String: Int] = [:]

        for (key, found) in copies {
            let account = String(key.prefix { $0 != "/" }).lowercased()
            // Only the server's answer says which window an account is live in; the
            // local caches keep the previous owner around.
            let liveDirs = Set(windowByDir.filter { _, profile in
                profile.identityVerified == true && profile.accountUUID?.lowercased() == account
            }.keys)
            let liveCopy = found.filter { liveDirs.contains($0.dir) }.max { $0.modified < $1.modified }
            guard let source = liveCopy ?? found.max(by: { $0.modified < $1.modified }) else { continue }

            // Deleted in the window that owns the account - the one place a deletion can
            // be made. Dormant copies elsewhere must not carry it back into any window.
            let deletedByUser = liveDirs.contains { dir in
                seen[dir]?.contains(key) == true && !found.contains { $0.dir == dir }
            }
            if deletedByUser { continue }

            for dir in windowByDir.keys where dir != source.dir {
                let target = URL(fileURLWithPath: dir, isDirectory: true)
                    .appendingPathComponent(sessionsFolder, isDirectory: true)
                    .appendingPathComponent(key)
                let isLive = liveDirs.contains(dir)

                if let existing = found.first(where: { $0.dir == dir }) {
                    // Refresh a dormant copy once the live one has moved on. A live copy
                    // belongs to the running app and is never overwritten. A copy carries
                    // its source's timestamp, so "same date" already means "in sync".
                    guard !isLive, liveCopy != nil,
                          source.modified > existing.modified else { continue }
                    copy(source, to: target)
                } else {
                    // Missing here. If it was here before, it was deleted in the app.
                    guard seen[dir]?.contains(key) != true else { continue }
                    if copy(source, to: target), isLive, let profile = windowByDir[dir] {
                        restored[profile.id, default: 0] += 1
                    }
                }
            }
        }

        // Remember everything each window has held, so a later deletion is respected.
        // Sessions gone from every window can never come back, so stop tracking them.
        let existingKeys = Set(copies.keys)
        for dir in windowByDir.keys {
            let root = URL(fileURLWithPath: dir, isDirectory: true).appendingPathComponent(sessionsFolder, isDirectory: true)
            var keys = (seen[dir] ?? []).intersection(existingKeys)
            for key in existingKeys where FileManager.default.fileExists(atPath: root.appendingPathComponent(key).path) {
                keys.insert(key)
            }
            seen[dir] = keys
        }
        saveSeen(seen)
        return restored
    }

    /// How many Code sessions a window holds per account, for the diagnostic dump.
    static func inventory(dataDir: String) -> [String: Int] {
        let root = URL(fileURLWithPath: normalized(dataDir), isDirectory: true)
            .appendingPathComponent(sessionsFolder, isDirectory: true)
        var counts: [String: Int] = [:]
        for account in subdirectories(of: root) {
            let total = subdirectories(of: account).reduce(0) { $0 + sessionFiles(in: $1).count }
            if total > 0 { counts[account.lastPathComponent] = total }
        }
        return counts
    }

    // MARK: Files

    /// Writes atomically and keeps the source's modification date, so a fresh copy
    /// never looks newer than the session it came from.
    @discardableResult
    private static func copy(_ source: Copy, to target: URL) -> Bool {
        let fileManager = FileManager.default
        do {
            let data = try Data(contentsOf: source.url)
            try fileManager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: target, options: .atomic)
            try? fileManager.setAttributes([.modificationDate: source.modified], ofItemAtPath: target.path)
            return true
        } catch {
            return false
        }
    }

    private static func subdirectories(of url: URL) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles])) ?? [])
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
    }

    private static func sessionFiles(in url: URL) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles])) ?? [])
            .filter { $0.lastPathComponent.hasPrefix(sessionPrefix) && $0.pathExtension == "json" }
    }

    private static func modificationDate(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
    }

    private static func normalized(_ path: String) -> String {
        URL(fileURLWithPath: Launcher.expanding(path)).standardizedFileURL.path
    }

    // MARK: What each window has held

    private static var seenURL: URL {
        Paths.shared.appSupport.appendingPathComponent("session_mirror.json")
    }

    private static func loadSeen() -> [String: Set<String>] {
        guard let data = try? Data(contentsOf: seenURL),
              let decoded = try? JSONDecoder().decode([String: [String]].self, from: data) else {
            return [:]
        }
        return decoded.mapValues(Set.init)
    }

    private static func saveSeen(_ seen: [String: Set<String>]) {
        Paths.shared.ensureSupportDirectory()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        if let data = try? encoder.encode(seen.mapValues { $0.sorted() }) {
            try? data.write(to: seenURL, options: .atomic)
        }
    }
}

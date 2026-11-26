import AppKit
import Foundation

/// Starts Claude 5-hour windows through the official Claude Code CLI (`claude -p`), the
/// documented way to use a Claude subscription without the interactive screen. Each
/// Claude account needs its own Claude Code login: a config folder (`CLAUDE_CONFIG_DIR`)
/// signed in to the same email. Logins are found by asking `claude auth status` in each
/// known folder, so nothing is guessed from file contents.
enum ClaudeCodeCLI {
    struct Login {
        /// nil = Claude Code's default folder (`~/.claude`), run without `CLAUDE_CONFIG_DIR`.
        var configDir: String?
        var email: String
        var plan: String?

        var displayPath: String {
            guard let configDir else { return "~/.claude" }
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            return configDir.hasPrefix(home) ? "~" + configDir.dropFirst(home.count) : configDir
        }
    }

    private struct CachedStatus {
        var login: Login?
        var checkedAt: Date
    }

    private static let lock = NSLock()
    private static var statusCache: [String: CachedStatus] = [:]
    private static let cacheLifetime: TimeInterval = 15 * 60

    // MARK: Finding the CLI and its logins

    static func executable() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            "\(home)/.local/bin/claude",
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
            "\(home)/.claude/local/claude",
        ]
        return candidates
            .first { FileManager.default.isExecutableFile(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
    }

    /// Where LLMCodeBar keeps the Claude Code logins it sets up itself.
    static var managedLoginsFolder: URL {
        Paths.shared.appSupport.appendingPathComponent("ClaudeCode", isDirectory: true)
    }

    /// Every folder that might hold a Claude Code login: the default one, the ones T3 Code
    /// and other tools keep next to it (`~/.claude-*`, `~/.claude-t3/*`), and LLMCodeBar's own.
    static func candidateConfigDirs() -> [String?] {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        var dirs: [String?] = [nil]
        func subfolders(of url: URL) -> [URL] {
            ((try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey])) ?? [])
                .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
                .sorted { $0.path < $1.path }
        }
        for entry in subfolders(of: home) where entry.lastPathComponent.hasPrefix(".claude-") {
            if entry.lastPathComponent == ".claude-t3" {
                dirs += subfolders(of: entry).map(\.path)
            } else {
                dirs.append(entry.path)
            }
        }
        dirs += subfolders(of: managedLoginsFolder).map(\.path)
        return dirs
    }

    /// The Claude Code login for this account, matched by email.
    static func login(for profile: LaunchProfile) -> Login? {
        guard let email = profile.accountEmail?.lowercased(), !email.isEmpty, executable() != nil else { return nil }
        return candidateConfigDirs().lazy.compactMap { status(configDir: $0) }.first { $0.email == email }
    }

    /// Forgets what `claude auth status` said, so a fresh sign-in is picked up right away.
    static func invalidateCache() {
        lock.lock()
        statusCache.removeAll()
        lock.unlock()
    }

    /// `claude auth status` for one folder; nil when it isn't signed in with a Claude
    /// subscription (an API key or a third-party provider can't start a 5h window).
    static func status(configDir: String?) -> Login? {
        let key = configDir ?? "~default"
        lock.lock()
        if let cached = statusCache[key], Date().timeIntervalSince(cached.checkedAt) < cacheLifetime {
            lock.unlock()
            return cached.login
        }
        lock.unlock()

        var login: Login?
        if let executable = executable(),
           let result = try? run(executable, ["auth", "status"], configDir: configDir, timeout: 20),
           let json = try? JSONSerialization.jsonObject(with: Data(result.output.utf8)) as? [String: Any],
           json["loggedIn"] as? Bool == true,
           json["authMethod"] as? String == "claude.ai",
           let email = (json["email"] as? String)?.lowercased(), !email.isEmpty {
            login = Login(configDir: configDir, email: email, plan: json["subscriptionType"] as? String)
        }
        lock.lock()
        statusCache[key] = CachedStatus(login: login, checkedAt: Date())
        lock.unlock()
        return login
    }

    // MARK: Starting the window

    /// Sends "hi" with Claude Code on Haiku, in an empty folder, with no tools, no saved
    /// session and every customization (hooks, plugins, MCP servers, CLAUDE.md) off.
    static func sendThrowawayHi(login: Login) throws -> String {
        guard let executable = executable() else { throw error("Claude Code isn't installed.") }
        let workdir = FileManager.default.temporaryDirectory.appendingPathComponent("LLMCodeBar-session-start", isDirectory: true)
        try? FileManager.default.createDirectory(at: workdir, withIntermediateDirectories: true)
        let arguments = [
            "-p", "hi",
            "--model", "haiku",
            "--output-format", "json",
            "--no-session-persistence",
            "--tools", "",
            "--strict-mcp-config",
            "--safe-mode",
        ]
        let result = try run(executable, arguments, configDir: login.configDir, cwd: workdir, timeout: 120)
        let json = result.output
            .split(separator: "\n")
            .reversed()
            .lazy
            .compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
            .first { $0["type"] as? String == "result" }
        if let json, json["is_error"] as? Bool != true, result.status == 0 {
            return "Haiku"
        }
        let message = (json?["result"] as? String) ?? result.errorOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        throw error(message.isEmpty ? "Claude Code exited with status \(result.status)." : String(message.prefix(200)))
    }

    // MARK: Signing in

    /// Opens Terminal on `claude auth login` with a new config folder kept for this
    /// account, so the person signs in with the right account in their browser.
    static func openSignIn(for profile: LaunchProfile) throws {
        guard let executable = executable() else {
            throw error("Claude Code isn't installed. Install it from https://claude.com/claude-code, then try again.")
        }
        let folder = managedLoginsFolder.appendingPathComponent(profile.id, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let email = profile.accountEmail ?? "this account"
        let script = """
            #!/bin/sh
            clear
            echo "Sign in to Claude Code as \(shellSafe(email)) for LLMCodeBar."
            echo "Pick that same account in the browser window that opens."
            echo
            export CLAUDE_CONFIG_DIR=\(shellQuote(folder.path))
            \(shellQuote(executable.path)) auth login
            echo
            echo "Done. You can close this window."
            """
        let scriptURL = FileManager.default.temporaryDirectory.appendingPathComponent("llmcodebar-claude-login-\(UUID().uuidString.prefix(8)).command")
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: scriptURL.path)
        invalidateCache()
        NSWorkspace.shared.open(scriptURL)
    }

    // MARK: Helpers

    private struct RunResult {
        var status: Int32
        var output: String
        var errorOutput: String
    }

    private static func run(_ executable: URL, _ arguments: [String], configDir: String?, cwd: URL? = nil, timeout: TimeInterval) throws -> RunResult {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        if let cwd { process.currentDirectoryURL = cwd }
        var environment = ProcessInfo.processInfo.environment
        // Only the subscription login may be used, never an API key or another provider.
        for key in ["ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "CLAUDE_CODE_OAUTH_TOKEN", "ANTHROPIC_BASE_URL",
                    "CLAUDE_CODE_USE_BEDROCK", "CLAUDE_CODE_USE_VERTEX", "CLAUDECODE", "CLAUDE_CODE_ENTRYPOINT", "CLAUDE_CONFIG_DIR"] {
            environment.removeValue(forKey: key)
        }
        if let configDir { environment["CLAUDE_CONFIG_DIR"] = configDir }
        process.environment = environment
        process.standardInput = FileHandle.nullDevice

        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        var outData = Data()
        var errData = Data()
        let group = DispatchGroup()
        for (pipe, isOutput) in [(output, true), (errors, false)] {
            group.enter()
            DispatchQueue.global(qos: .utility).async {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                if isOutput { outData = data } else { errData = data }
                group.leave()
            }
        }
        try process.run()
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning {
            process.terminate()
            _ = group.wait(timeout: .now() + 2)
            throw error("Claude Code took too long to answer.")
        }
        _ = group.wait(timeout: .now() + 5)
        return RunResult(
            status: process.terminationStatus,
            output: String(data: outData, encoding: .utf8) ?? "",
            errorOutput: String(data: errData, encoding: .utf8) ?? "")
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func shellSafe(_ value: String) -> String {
        value.filter { $0.isLetter || $0.isNumber || "@._+-".contains($0) }
    }

    static func error(_ message: String) -> NSError {
        NSError(domain: "LLMUsageBar.ClaudeCode", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

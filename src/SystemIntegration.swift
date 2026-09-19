import AppKit
import ServiceManagement

enum AutostartManager {
    static func sync(enabled: Bool) {
        // Prefer the modern login-item API (shows under System Settings > General >
        // Login Items). Fall back to a user LaunchAgent if it refuses (e.g. an
        // unsigned/ad-hoc build), which still relaunches the app on login.
        if #available(macOS 13.0, *) {
            let service = SMAppService.mainApp
            do {
                if enabled {
                    if service.status != .enabled { try service.register() }
                } else if service.status == .enabled {
                    try service.unregister()
                }
                try? FileManager.default.removeItem(at: Paths.shared.launchAgentURL)
                return
            } catch {
                // fall through to the LaunchAgent approach
            }
        }
        if enabled {
            install()
        } else {
            try? FileManager.default.removeItem(at: Paths.shared.launchAgentURL)
        }
    }

    /// The real current state, so the checkbox can reflect what macOS actually has.
    static var isEnabled: Bool {
        if #available(macOS 13.0, *), SMAppService.mainApp.status == .enabled {
            return true
        }
        return FileManager.default.fileExists(atPath: Paths.shared.launchAgentURL.path)
    }

    private static func install() {
        let bundlePath = Bundle.main.bundlePath
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
          <key>Label</key>
          <string>fr.fraserv.llmusagebar</string>
          <key>ProgramArguments</key>
          <array>
            <string>/usr/bin/open</string>
            <string>\(bundlePath)</string>
          </array>
          <key>RunAtLoad</key>
          <true/>
        </dict>
        </plist>
        """
        let fm = FileManager.default
        try? fm.createDirectory(at: Paths.shared.launchAgentURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? plist.data(using: .utf8)?.write(to: Paths.shared.launchAgentURL, options: .atomic)
    }
}

enum Launcher {
    static func launch(_ profile: LaunchProfile) throws {
        let fm = FileManager.default
        let appURL = URL(fileURLWithPath: expanding(profile.appPath))
        let dataDir = expanding(profile.dataDir)

        guard fm.fileExists(atPath: appURL.path) else {
            throw NSError(domain: "LLMUsageBar.Launcher", code: 1, userInfo: [NSLocalizedDescriptionKey: "\(profile.provider.rawValue) app not found at \(appURL.path)"])
        }

        try fm.createDirectory(atPath: dataDir, withIntermediateDirectories: true)

        if profile.provider == .codex {
            let codexHome = URL(fileURLWithPath: dataDir, isDirectory: true)
                .appendingPathComponent("CodexHome", isDirectory: true)
            try fm.createDirectory(at: codexHome, withIntermediateDirectories: true)
        }

        if let running = RunningProfileDetector.runningApplication(for: profile) {
            running.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
            return
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = [
            "-na",
            appURL.path,
            "--args",
            "--user-data-dir=\(dataDir)"
        ]
        try process.run()
    }

    static func bundleIdentifier(for appPath: String) -> String? {
        let appURL = URL(fileURLWithPath: expanding(appPath))
        return Bundle(url: appURL)?.bundleIdentifier
    }

    static func expanding(_ path: String) -> String {
        NSString(string: path).expandingTildeInPath
    }
}

/// Opens a specific chat in the Claude desktop app. Claude registers a `claude://`
/// scheme and accepts `claude://claude.ai/chat/<uuid>`, which lands straight in that
/// conversation instead of wherever the app happened to be.
enum ClaudeDeepLink {
    /// Whether a link can be aimed at a given account. macOS hands the URL to whichever
    /// instance of the app claims the scheme, so as soon as a second Claude profile is
    /// running the link could land in the wrong account - better to not send it at all.
    static func canTarget(_ destination: LaunchProfile, among profiles: [LaunchProfile]) -> Bool {
        let claudeProfiles = profiles.filter { $0.provider == .claude }
        let running = RunningProfileDetector.runningProfileIDs(claudeProfiles)
        return !running.contains { $0 != destination.id }
    }

    @discardableResult
    static func open(conversationUUID: String) -> Bool {
        guard let url = URL(string: "claude://claude.ai/chat/\(conversationUUID)") else { return false }
        return NSWorkspace.shared.open(url)
    }
}

/// Works out which running desktop-app instance belongs to which account.
///
/// This used to shell out to `pgrep -flf <dataDir>` once per profile, which was wrong
/// in two ways that both made a closed account show as "Open":
///
///  * macOS `pgrep -f` matches a process's *environment block*, not just its argv.
///    Anything ever spawned from a Claude window - a dev server, a node tool, a Claude
///    Code CLI - inherits that window's environment and keeps matching long after the
///    Claude that started it has quit.
///  * The match was an unanchored substring, so the default profile dir
///    `~/Library/Application Support/Claude` also matched every sibling starting with
///    the same path, `~/Library/Application Support/Claude-3p` included. (It was also
///    read as an extended regex, so `.` in a path matched any character.)
///
/// A phantom "running" instance then got resolved by bundle identifier, which cannot
/// tell two instances of the same app apart - so clicking the account that was really
/// closed just re-activated the other one's window.
///
/// Both problems go away by only looking at real GUI applications and reading their
/// actual arguments.
enum RunningProfileDetector {
    static func runningProfileIDs(_ profiles: [LaunchProfile]) -> Set<String> {
        Set(snapshot(profiles).keys)
    }

    static func runningApplication(for profile: LaunchProfile) -> NSRunningApplication? {
        snapshot([profile])[profile.id]
    }

    static func isRunning(_ profile: LaunchProfile) -> Bool {
        runningApplication(for: profile) != nil
    }

    /// One pass over the running applications: profile id -> the instance serving it.
    /// An instance is matched to a profile by comparing user-data directories for
    /// equality - never as a substring.
    static func snapshot(_ profiles: [LaunchProfile]) -> [String: NSRunningApplication] {
        var matches: [String: NSRunningApplication] = [:]
        let processes = ProcessTable()

        for (appPath, group) in Dictionary(grouping: profiles, by: { Launcher.expanding($0.appPath) }) {
            guard let bundleID = Launcher.bundleIdentifier(for: appPath) else { continue }
            let instances = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
                .filter { !$0.isTerminated && $0.processIdentifier > 0 }
            guard !instances.isEmpty else { continue }

            var profilesByDataDir: [String: LaunchProfile] = [:]
            for profile in group {
                profilesByDataDir[normalized(profile.dataDir)] = profile
            }

            for instance in instances {
                guard let dataDir = dataDir(of: instance, appPath: appPath, processes: processes),
                      let profile = profilesByDataDir[dataDir] else { continue }
                // First instance wins, so a stray duplicate can't displace the one we
                // would activate.
                if matches[profile.id] == nil {
                    matches[profile.id] = instance
                }
            }
        }
        return matches
    }

    /// The directory an instance is actually running out of.
    ///
    /// Chromium-family apps carry `--user-data-dir` on the main process only when they
    /// were launched with one, which is how we start extra accounts. Launched from the
    /// Dock they fall back to a built-in default that isn't always the bundle name -
    /// the ChatGPT app still uses `Codex`, for instance. Their helper processes always
    /// spell the directory out, though, so ask those before guessing.
    private static func dataDir(of instance: NSRunningApplication, appPath: String, processes: ProcessTable) -> String? {
        let pid = instance.processIdentifier
        if let explicit = ProcessArguments.userDataDir(forPID: pid) {
            return normalized(explicit)
        }
        for child in processes.children(of: pid) {
            guard let arguments = ProcessArguments.arguments(forPID: child),
                  // Only the app's own helpers - not whatever tooling it happens to
                  // spawn, which may carry an unrelated directory.
                  arguments.first?.hasPrefix("\(appPath)/") == true,
                  let dataDir = ProcessArguments.userDataDir(in: arguments) else { continue }
            return normalized(dataDir)
        }
        return defaultDataDir(forAppPath: appPath)
    }

    /// Last resort for an instance that never named a directory: the Electron default,
    /// `~/Library/Application Support/<CFBundleName>`.
    private static func defaultDataDir(forAppPath appPath: String) -> String? {
        let name = (Bundle(path: appPath)?.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? URL(fileURLWithPath: appPath).deletingPathExtension().lastPathComponent
        guard !name.isEmpty else { return nil }
        let support = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        return normalized(support.appendingPathComponent(name, isDirectory: true).path)
    }

    /// Tilde-expanded and standardised, so two spellings of one directory compare equal.
    private static func normalized(_ path: String) -> String {
        URL(fileURLWithPath: Launcher.expanding(path)).standardizedFileURL.path
    }
}

/// The parent/child layout of the process table, read once and reused.
final class ProcessTable {
    private lazy var childrenByParent: [pid_t: [pid_t]] = Self.load()

    func children(of pid: pid_t) -> [pid_t] {
        childrenByParent[pid] ?? []
    }

    private static func load() -> [pid_t: [pid_t]] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size = 0
        guard sysctl(&mib, 4, nil, &size, nil, 0) == 0, size > 0 else { return [:] }

        let capacity = size / MemoryLayout<kinfo_proc>.stride
        var entries = [kinfo_proc](repeating: kinfo_proc(), count: capacity)
        guard sysctl(&mib, 4, &entries, &size, nil, 0) == 0 else { return [:] }

        var result: [pid_t: [pid_t]] = [:]
        for entry in entries.prefix(size / MemoryLayout<kinfo_proc>.stride) {
            result[entry.kp_eproc.e_ppid, default: []].append(entry.kp_proc.p_pid)
        }
        return result
    }
}

/// Reads another process's arguments - and only its arguments - straight from the
/// kernel. Deliberately not `pgrep -f`/`ps`, which also search the environment block
/// that every child process inherits and then keeps for its whole life.
enum ProcessArguments {
    /// The value of `--user-data-dir` in a process's argv, or nil when it has none.
    static func userDataDir(forPID pid: pid_t) -> String? {
        guard let arguments = arguments(forPID: pid) else { return nil }
        return userDataDir(in: arguments)
    }

    /// Accepts either the `--user-data-dir=<dir>` or the space-separated spelling.
    static func userDataDir(in arguments: [String]) -> String? {
        let flag = "--user-data-dir"
        for (index, argument) in arguments.enumerated() {
            if argument.hasPrefix("\(flag)=") {
                return String(argument.dropFirst(flag.count + 1))
            }
            if argument == flag, arguments.indices.contains(index + 1) {
                return arguments[index + 1]
            }
        }
        return nil
    }

    /// `KERN_PROCARGS2` lays the buffer out as: argc, the executable path, padding
    /// nulls, then argc null-terminated arguments, then the environment. We stop at
    /// argc and never look at what follows.
    static func arguments(forPID pid: pid_t) -> [String]? {
        var argMax: Int32 = 0
        var argMaxSize = MemoryLayout<Int32>.size
        var argMaxMib: [Int32] = [CTL_KERN, KERN_ARGMAX]
        guard sysctl(&argMaxMib, 2, &argMax, &argMaxSize, nil, 0) == 0, argMax > 0 else { return nil }

        var buffer = [CChar](repeating: 0, count: Int(argMax))
        var size = Int(argMax)
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }

        var argc: Int32 = 0
        memcpy(&argc, buffer, MemoryLayout<Int32>.size)
        guard argc > 0 else { return [] }

        var index = MemoryLayout<Int32>.size
        while index < size, buffer[index] != 0 { index += 1 }
        while index < size, buffer[index] == 0 { index += 1 }

        var arguments: [String] = []
        while index < size, arguments.count < Int(argc) {
            var end = index
            while end < size, buffer[end] != 0 { end += 1 }
            arguments.append(String(decoding: buffer[index..<end].map { UInt8(bitPattern: $0) }, as: UTF8.self))
            index = end + 1
        }
        return arguments
    }
}

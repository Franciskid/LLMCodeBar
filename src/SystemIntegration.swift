import AppKit

enum AutostartManager {
    static func sync(enabled: Bool) {
        if enabled {
            install()
        } else {
            try? FileManager.default.removeItem(at: Paths.shared.launchAgentURL)
        }
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

    static func executableName(for appPath: String) -> String {
        let appURL = URL(fileURLWithPath: expanding(appPath))
        if let name = Bundle(url: appURL)?.object(forInfoDictionaryKey: "CFBundleExecutable") as? String, !name.isEmpty {
            return name
        }
        return appURL.deletingPathExtension().lastPathComponent
    }

    static func expanding(_ path: String) -> String {
        NSString(string: path).expandingTildeInPath
    }
}

enum RunningProfileDetector {
    static func runningProfileIDs(_ profiles: [LaunchProfile]) -> Set<String> {
        Set(profiles.filter(isRunning).map(\.id))
    }

    static func runningApplication(for profile: LaunchProfile) -> NSRunningApplication? {
        if let pid = mainProcessID(for: profile),
           let app = NSRunningApplication(processIdentifier: pid) {
            return app
        }
        guard isRunning(profile),
              let bundleID = Launcher.bundleIdentifier(for: profile.appPath) else {
            return nil
        }
        return NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first
    }

    static func isRunning(_ profile: LaunchProfile) -> Bool {
        matchingProcessOutput(for: profile)?.isEmpty == false
    }

    private static func mainProcessID(for profile: LaunchProfile) -> pid_t? {
        guard let output = matchingProcessOutput(for: profile) else { return nil }
        let executable = Launcher.executableName(for: profile.appPath)
        let appMainPath = "\(Launcher.expanding(profile.appPath))/Contents/MacOS/\(executable)"

        for line in output.split(separator: "\n") {
            let text = String(line)
            guard text.contains(appMainPath) else { continue }
            let pieces = text.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            if let first = pieces.first, let pid = Int32(String(first)) {
                return pid_t(pid)
            }
        }
        return nil
    }

    private static func matchingProcessOutput(for profile: LaunchProfile) -> String? {
        let dataDir = Launcher.expanding(profile.dataDir)
        return try? ProcessRunner.run("/usr/bin/pgrep", arguments: ["-flf", dataDir], timeout: 1.5)
    }
}


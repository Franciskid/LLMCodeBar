import AppKit

// Checks LLMCodeBar can reach a Claude window's reply box: --probe-claude-window <pid>
// [--send <claude:// link> <text>] --out <file>. Started with `open -n` so macOS applies
// LLMCodeBar's own Accessibility permission.
if let index = CommandLine.arguments.firstIndex(of: "--probe-claude-window"),
   let pid = CommandLine.arguments.dropFirst(index + 1).first.flatMap({ pid_t($0) }) {
    let arguments = CommandLine.arguments
    var report = ClaudeWindowMessenger.probe(pid: pid)
    if let send = arguments.firstIndex(of: "--send"), arguments.count > send + 2,
       let link = URL(string: arguments[send + 1]), let app = NSRunningApplication(processIdentifier: pid) {
        var polls = 0
        let result = ClaudeWindowMessenger.send(arguments[send + 2], opening: link, in: app) {
            polls += 1
            return polls >= 2
        }
        report += "\nSend: \(result)"
    }
    if let out = arguments.firstIndex(of: "--out"), arguments.count > out + 1 {
        try? report.write(toFile: arguments[out + 1], atomically: true, encoding: .utf8)
    } else {
        print(report)
    }
    exit(0)
}

// Prints what "Continue after limits" sees and would do now. Reads only.
if CommandLine.arguments.contains("--continue-dry-run") {
    print(KeepGoing.shared.dryRun(config: ConfigStore.shared.loadCached()))
    exit(0)
}

if CommandLine.arguments.contains("--dump-inferred-json") {
    let config = ConfigStore.shared.load()
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    if let data = try? encoder.encode(config), let text = String(data: data, encoding: .utf8) {
        print(text)
    }
    exit(0)
}

if CommandLine.arguments.contains("--dump-usage-json") {
    let inferred = ConfigStore.shared.load()
    let refreshed = UsageRefresher.refresh(inferred)
    ConfigStore.shared.save(refreshed)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    if let data = try? encoder.encode(refreshed), let text = String(data: data, encoding: .utf8) {
        print(text)
    }
    exit(0)
}

if CommandLine.arguments.contains("--prove-quota-json") {
    let inferred = ConfigStore.shared.load()
    let proof = UsageRefresher.quotaProof(inferred)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    if let data = try? encoder.encode(proof), let text = String(data: data, encoding: .utf8) {
        print(text)
    }
    exit(0)
}

if CommandLine.arguments.contains("--dump-running-json") {
    let config = ConfigStore.shared.load()
    let running = RunningProfileDetector.snapshot(config.profiles)
    let rows: [[String: Any]] = config.profiles.map { profile in
        [
            "provider": profile.provider.rawValue,
            "email": profile.accountEmail ?? "",
            "plan": profile.accountPlan ?? "",
            "dataDir": Launcher.expanding(profile.dataDir),
            "running": running[profile.id] != nil,
            // The exact instance we would activate - the old bundle-id lookup could
            // not tell two instances of the same app apart.
            "pid": running[profile.id].map { Int($0.processIdentifier) } ?? -1
        ]
    }
    if let data = try? JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys]),
       let text = String(data: data, encoding: .utf8) {
        print(text)
    }
    exit(0)
}

/// Who each Claude window is really signed in as, asked of claude.ai rather than read
/// out of the window's local caches - which keep the previous account after a re-login.
if CommandLine.arguments.contains("--dump-claude-accounts") {
    let config = ConfigStore.shared.loadCached()
    for profile in config.profiles where profile.provider == .claude {
        print("data dir: \(Launcher.expanding(profile.dataDir))")
        print("  stored: \(profile.accountEmail ?? "-")  uuid=\(profile.accountUUID ?? "-")  verified=\(profile.identityVerified == true)")
        do {
            let cookieHeader = try UsageRefresher.claudeCookieHeader(for: profile, allowKeychain: true)
            let account = try UsageRefresher.claudeAccount(cookieHeader: cookieHeader)
            print("  server: \(account.email ?? "-")  uuid=\(account.uuid)  name=\(account.name ?? "-")")
        } catch {
            print("  server: unavailable - \(error.localizedDescription)")
        }
        let sessions = ClaudeSessionMirror.inventory(dataDir: profile.dataDir)
        for (account, count) in sessions.sorted(by: { $0.key < $1.key }) {
            print("  history: \(account): \(count) session\(count == 1 ? "" : "s")")
        }
    }
    print("claude:// handler held by LLMCodeBar: \(ClaudeLinkRouter.holdsScheme)")
    exit(0)
}

if CommandLine.arguments.contains("--check-update") {
    print("installed: \(Updater.currentVersion)")
    do {
        let latest = try Updater.latestRelease()
        print("latest:    \(latest.version)  (\(latest.tag))")
        print("asset:     \(latest.downloadURL.absoluteString)")
        print(Updater.isNewer(latest.version, than: Updater.currentVersion) ? "status:    update available" : "status:    up to date")
        exit(0)
    } catch {
        print("status:    check failed - \(error.localizedDescription)")
        exit(1)
    }
}

if CommandLine.arguments.contains("--install-update") {
    do {
        guard let release = try Updater.availableUpdate() else {
            print("Already on \(Updater.currentVersion); nothing to install.")
            exit(0)
        }
        print("Downloading \(release.version)...")
        let staged = try Updater.stage(release)
        print("Verified \(staged.sourceApp)")
        try Updater.install(staged)
        print("Swapping in \(release.version) and relaunching \(staged.destination)")
        exit(0)
    } catch {
        print("Update failed: \(error.localizedDescription)")
        exit(1)
    }
}

if let launchIndex = CommandLine.arguments.firstIndex(of: "--launch-profile-email"),
   CommandLine.arguments.indices.contains(launchIndex + 1) {
    let email = CommandLine.arguments[launchIndex + 1].lowercased()
    let providerIndex = CommandLine.arguments.firstIndex(of: "--provider")
    let provider = providerIndex.flatMap { index -> Provider? in
        guard CommandLine.arguments.indices.contains(index + 1) else { return nil }
        return Provider(rawValue: CommandLine.arguments[index + 1])
    }
    let config = ConfigStore.shared.load()
    guard let profile = config.profiles.first(where: { profile in
        profile.accountEmail?.lowercased() == email && (provider == nil || profile.provider == provider)
    }) else {
        print("No profile found for \(provider?.rawValue ?? "any provider") \(email)")
        exit(2)
    }
    do {
        try Launcher.launch(profile)
        print("Launched \(profile.provider.rawValue) \(profile.accountEmail ?? profile.label)")
        exit(0)
    } catch {
        print("Launch failed: \(error.localizedDescription)")
        exit(1)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()

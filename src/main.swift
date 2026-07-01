import AppKit

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
    let runningIDs = RunningProfileDetector.runningProfileIDs(config.profiles)
    let rows: [[String: Any]] = config.profiles.map { profile in
        [
            "provider": profile.provider.rawValue,
            "email": profile.accountEmail ?? "",
            "plan": profile.accountPlan ?? "",
            "dataDir": Launcher.expanding(profile.dataDir),
            "running": runningIDs.contains(profile.id)
        ]
    }
    if let data = try? JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys]),
       let text = String(data: data, encoding: .utf8) {
        print(text)
    }
    exit(0)
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

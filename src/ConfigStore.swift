import Foundation

final class ConfigStore {
    static let shared = ConfigStore()
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    private init() {
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    }

    func load() -> AppConfig {
        Paths.shared.ensureSupportDirectory()
        guard let data = try? Data(contentsOf: Paths.shared.configURL),
              let existing = try? decoder.decode(AppConfig.self, from: data) else {
            let config = AppConfig(launchAtLogin: true, autoApproveCookieAccess: true, configVersion: Self.currentConfigVersion, profiles: inferProfiles(existing: []))
            save(config)
            return config
        }

        // Start from the decoded config so every stored option is preserved; only
        // re-infer the profile list and apply one-time migrations.
        var config = existing
        config.autoApproveCookieAccess = existing.autoApproveCookieAccess ?? true
        migrateCodexRename(&config.profiles)
        config.profiles = inferProfiles(existing: config.profiles)
        if config.configVersion == nil {
            // One-time migration for configs written before these options existed:
            // opt the user into launch-at-login (explicitly requested) and cookie access.
            config.launchAtLogin = true
            config.autoApproveCookieAccess = true
            config.configVersion = Self.currentConfigVersion
        }
        save(config)
        return config
    }

    static let currentConfigVersion = 1

    func loadCached() -> AppConfig {
        Paths.shared.ensureSupportDirectory()
        guard let data = try? Data(contentsOf: Paths.shared.configURL),
              let existing = try? decoder.decode(AppConfig.self, from: data) else {
            return AppConfig(launchAtLogin: false, autoApproveCookieAccess: true, configVersion: nil, profiles: [])
        }
        return existing
    }

    func save(_ config: AppConfig) {
        Paths.shared.ensureSupportDirectory()
        if let data = try? encoder.encode(config) {
            try? data.write(to: Paths.shared.configURL, options: .atomic)
        }
        AutostartManager.sync(enabled: config.launchAtLogin)
    }

    func inferProfiles(existing: [LaunchProfile]? = nil) -> [LaunchProfile] {
        let existingProfiles = existing ?? loadExistingProfilesWithoutInferring()
        var resultsByKey: [String: LaunchProfile] = [:]
        let existingByKey = Dictionary(uniqueKeysWithValues: existingProfiles.map { (profileKey(provider: $0.provider, dataDir: $0.dataDir), $0) })

        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path
        let support = "\(home)/Library/Application Support"

        let claudeApp = "/Applications/Claude.app"
        let codexApp = defaultAppPath(for: .codex)

        var candidates: [(provider: Provider, appPath: String, dataDir: String, userAdded: Bool)] = []

        if fm.fileExists(atPath: claudeApp) {
            candidates.append((.claude, claudeApp, "\(support)/Claude", false))
            if let dirs = try? fm.contentsOfDirectory(atPath: support) {
                for dir in dirs.sorted() where dir.hasPrefix("Claude-") {
                    let path = "\(support)/\(dir)"
                    var isDir: ObjCBool = false
                    if fm.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue {
                        candidates.append((.claude, claudeApp, path, false))
                    }
                }
            }
        }

        if fm.fileExists(atPath: codexApp) || CodexAuthStore.accountInfo() != nil {
            let codexDataDirs = [
                "\(support)/Codex",
                "\(support)/com.openai.codex"
            ]
            for candidate in codexDataDirs where fm.fileExists(atPath: candidate) {
                candidates.append((.codex, codexApp, candidate, false))
            }
            if CodexAuthStore.accountInfo() != nil, !codexDataDirs.contains(where: fm.fileExists(atPath:)) {
                candidates.append((.codex, codexApp, "\(support)/Codex", false))
            }
        }

        candidates.append(contentsOf: generatedProfileCandidates())
        candidates.append(contentsOf: existingProfiles.map { profile in
            (profile.provider, profile.appPath, profile.dataDir, profile.isUserAdded == true)
        })

        for candidate in candidates {
            let key = profileKey(provider: candidate.provider, dataDir: candidate.dataDir)
            var profile = existingByKey[key]
            let signature = AccountResolver.signature(in: candidate.dataDir)
            let recentlyScanned = profile?.scanUpdatedAt.map { Date().timeIntervalSince($0) < 300 } ?? false
            let missingIdentity = profile.map { existing in
                existing.signedIn != true ||
                    existing.accountEmail == nil ||
                    existing.accountPlan == nil ||
                    (candidate.provider == .codex && existing.accountUUID == nil)
            } ?? true
            let needsScan = profile == nil ||
                profile?.isPendingLogin == true ||
                missingIdentity ||
                (profile?.scanSignature != signature && !recentlyScanned)
            let identity = needsScan ? AccountResolver.identity(in: candidate.dataDir, provider: candidate.provider) : nil

            if var existingProfile = profile {
                existingProfile.appPath = candidate.appPath
                if let identity {
                    existingProfile.apply(identity: identity)
                    existingProfile.scanSignature = signature
                    existingProfile.scanUpdatedAt = Date()
                } else if needsScan {
                    existingProfile.scanSignature = signature
                    existingProfile.scanUpdatedAt = Date()
                }
                if candidate.userAdded {
                    existingProfile.isUserAdded = true
                }
                normalizePlanConsistency(&existingProfile)
                if identity != nil ||
                    existingProfile.isUserAdded == true ||
                    existingProfile.signedIn == true ||
                    existingProfile.accountEmail != nil ||
                    existingProfile.accountName != nil {
                    resultsByKey[key] = existingProfile
                }
                continue
            }

            if let identity {
                profile = .make(provider: candidate.provider, appPath: candidate.appPath, dataDir: candidate.dataDir, identity: identity, isUserAdded: candidate.userAdded)
                profile?.scanSignature = signature
                profile?.scanUpdatedAt = Date()
                if var madeProfile = profile {
                    normalizePlanConsistency(&madeProfile)
                    profile = madeProfile
                }
                resultsByKey[key] = profile
            }
        }

        return deduplicated(resultsByKey.values)
    }

    func createPendingProfile(provider: Provider) -> LaunchProfile {
        Paths.shared.ensureSupportDirectory()
        let appPath = defaultAppPath(for: provider)
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let dataDir = Paths.shared.profilesURL
            .appendingPathComponent(provider.rawValue, isDirectory: true)
            .appendingPathComponent(stamp, isDirectory: true)
            .path
        try? FileManager.default.createDirectory(atPath: dataDir, withIntermediateDirectories: true)
        return .pending(provider: provider, appPath: appPath, dataDir: dataDir)
    }

    private func loadExistingProfilesWithoutInferring() -> [LaunchProfile] {
        guard let data = try? Data(contentsOf: Paths.shared.configURL),
              let config = try? decoder.decode(AppConfig.self, from: data) else {
            return []
        }
        return config.profiles
    }

    private func generatedProfileCandidates() -> [(provider: Provider, appPath: String, dataDir: String, userAdded: Bool)] {
        let fm = FileManager.default
        var candidates: [(Provider, String, String, Bool)] = []

        for provider in Provider.allCases {
            let dir = Paths.shared.profilesURL.appendingPathComponent(provider.rawValue, isDirectory: true)
            guard let children = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey]) else {
                continue
            }
            for child in children {
                var isDir: ObjCBool = false
                if fm.fileExists(atPath: child.path, isDirectory: &isDir), isDir.boolValue {
                    candidates.append((provider, defaultAppPath(for: provider), child.path, true))
                }
            }
        }
        return candidates
    }

    /// Codex's desktop app was renamed to ChatGPT. Repoint stored profiles at the new
    /// bundle (so the right icon shows) and refresh auto-generated "Codex - " labels.
    /// Idempotent: once migrated, neither branch matches again.
    private func migrateCodexRename(_ profiles: inout [LaunchProfile]) {
        for i in profiles.indices where profiles[i].provider == .codex {
            if profiles[i].appPath == "/Applications/Codex.app" {
                profiles[i].appPath = defaultAppPath(for: .codex)
            }
            if profiles[i].label.hasPrefix("Codex - ") {
                profiles[i].label = "ChatGPT - " + profiles[i].label.dropFirst("Codex - ".count)
            }
        }
    }

    private func defaultAppPath(for provider: Provider) -> String {
        switch provider {
        case .claude: return "/Applications/Claude.app"
        case .codex:
            // Codex's desktop app is now the ChatGPT app; fall back to the old bundle
            // only if someone still has it installed.
            let chatGPT = "/Applications/ChatGPT.app"
            let legacyCodex = "/Applications/Codex.app"
            if FileManager.default.fileExists(atPath: chatGPT) { return chatGPT }
            if FileManager.default.fileExists(atPath: legacyCodex) { return legacyCodex }
            return chatGPT
        }
    }

    private func profileKey(provider: Provider, dataDir: String) -> String {
        "\(provider.rawValue)|\(Launcher.expanding(dataDir))"
    }

    private func deduplicated(_ profiles: Dictionary<String, LaunchProfile>.Values) -> [LaunchProfile] {
        var uniqueByAccount: [String: LaunchProfile] = [:]
        var anonymous: [LaunchProfile] = []

        for profile in profiles {
            guard let key = accountKey(for: profile) else {
                anonymous.append(profile)
                continue
            }

            if let existing = uniqueByAccount[key] {
                uniqueByAccount[key] = preferredProfile(existing, profile)
            } else {
                uniqueByAccount[key] = profile
            }
        }

        return (Array(uniqueByAccount.values) + anonymous).sorted(by: sortProfiles)
    }

    private func accountKey(for profile: LaunchProfile) -> String? {
        guard profile.isPendingLogin != true else { return nil }
        if let accountUUID = profile.accountUUID?.lowercased(), !accountUUID.isEmpty {
            return "\(profile.provider.rawValue)|uuid|\(accountUUID)"
        }
        if let email = profile.accountEmail?.lowercased(), !email.isEmpty {
            return "\(profile.provider.rawValue)|email|\(email)"
        }
        return nil
    }

    private func preferredProfile(_ lhs: LaunchProfile, _ rhs: LaunchProfile) -> LaunchProfile {
        profileScore(rhs) > profileScore(lhs) ? rhs : lhs
    }

    private func profileScore(_ profile: LaunchProfile) -> Int {
        var score = 0
        if profile.isPendingLogin != true { score += 1000 }
        if profile.signedIn == true { score += 100 }
        if profile.accountEmail != nil { score += 60 }
        if profile.accountPlan != nil { score += 40 }
        if profile.accountUUID != nil { score += 30 }
        if profile.usage != nil { score += 15 }
        if profile.isUserAdded == true { score += 8 }
        if profile.scanSignature?.isEmpty == false { score += 6 }
        if profile.dataDir.contains("/Library/Application Support/Codex") { score += 3 }
        if profile.dataDir.contains("/Library/Application Support/com.openai.codex") { score -= 2 }
        return score
    }

    private func normalizePlanConsistency(_ profile: inout LaunchProfile) {
        guard profile.provider == .claude else { return }
        let currentIsPaid = ["pro", "max", "team", "plus"].contains((profile.accountPlan ?? "").lowercased())
        switch profile.billingType {
        case "none":
            // A "none" reading is only trusted when we don't already know it's paid;
            // the local billing cache spuriously reports "none", which flipped Pro to Free.
            if !currentIsPaid { setPlan("Free", on: &profile) }
        case "stripe_subscription":
            setPlan("Pro", on: &profile)
        default:
            break
        }
    }

    private func setPlan(_ plan: String, on profile: inout LaunchProfile) {
        profile.accountPlan = plan
        if var usage = profile.usage {
            usage.accountPlan = plan
            profile.usage = usage
        }
    }

    private func sortProfiles(_ lhs: LaunchProfile, _ rhs: LaunchProfile) -> Bool {
        if lhs.provider.rawValue != rhs.provider.rawValue {
            return lhs.provider.rawValue < rhs.provider.rawValue
        }
        return lhs.label.localizedCaseInsensitiveCompare(rhs.label) == .orderedAscending
    }
}


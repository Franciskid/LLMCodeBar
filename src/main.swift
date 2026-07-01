import AppKit
import CommonCrypto
import Foundation
import Security

enum Provider: String, Codable, CaseIterable {
    case claude = "Claude"
    case codex = "Codex"
}

struct UsageWindow: Codable {
    var title: String
    var usedPercent: Double
    var remainingPercent: Double
    var resetsAt: Date?

    var displayText: String {
        let remaining = Int(remainingPercent.rounded())
        if let resetsAt {
            return "\(remaining)% left - resets \(Self.shortResetFormatter.string(from: resetsAt))"
        }
        return "\(remaining)% left"
    }

    private static let shortResetFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE HH:mm"
        return formatter
    }()
}

struct UsageInfo: Codable {
    var source: String
    var status: String?
    var windows: [UsageWindow]
    var creditsRemaining: Double?
    var accountEmail: String?
    var accountPlan: String?
    var updatedAt: Date

    var primaryPercentUsed: Double? {
        windows.first?.usedPercent
    }

    var summaryLine: String {
        if let status, windows.isEmpty, creditsRemaining == nil {
            return status
        }

        var parts = windows.prefix(2).map { "\($0.title): \($0.displayText)" }
        if let creditsRemaining {
            parts.append(String(format: "%.0f credits", creditsRemaining))
        }
        if parts.isEmpty, let status {
            parts.append(status)
        }
        return parts.isEmpty ? "Usage unavailable" : parts.joined(separator: "  ")
    }
}

struct QuotaProofReport: Codable {
    var generatedAt: String
    var profiles: [QuotaProof]
}

struct QuotaProof: Codable {
    var provider: Provider
    var email: String?
    var plan: String?
    var endpoint: String
    var httpStatus: Int?
    var status: String?
    var parserMatchesProvider: Bool
    var windows: [QuotaWindowProof]
    var creditsRemaining: Double?
}

struct QuotaWindowProof: Codable {
    var title: String
    var providerUsedPercent: Double?
    var parsedUsedPercent: Double?
    var providerRemainingPercent: Double?
    var parsedRemainingPercent: Double?
    var providerReset: String?
    var parsedReset: String?
    var matches: Bool
}

struct LaunchProfile: Codable, Identifiable {
    var id: String
    var label: String
    var provider: Provider
    var appPath: String
    var dataDir: String
    var accountName: String?
    var accountEmail: String?
    var signedIn: Bool?
    var accountPlan: String?
    var quotaSummary: String?
    var quotaSource: String?
    var billingType: String?
    var accountUUID: String?
    var isUserAdded: Bool?
    var isPendingLogin: Bool?
    var createdAt: Date?
    var scanSignature: String?
    var scanUpdatedAt: Date?
    var usage: UsageInfo?

    static func make(provider: Provider, appPath: String, dataDir: String, identity: AccountIdentity, isUserAdded: Bool = false) -> LaunchProfile {
        let account = identity.displayName ?? identity.email ?? "Signed-in account"
        return LaunchProfile(
            id: UUID().uuidString,
            label: "\(provider.rawValue) - \(account)",
            provider: provider,
            appPath: appPath,
            dataDir: dataDir,
            accountName: identity.displayName,
            accountEmail: identity.email,
            signedIn: identity.isSignedIn,
            accountPlan: identity.planName,
            quotaSummary: identity.quotaSummary,
            quotaSource: identity.quotaSource,
            billingType: identity.billingType,
            accountUUID: identity.accountUUID,
            isUserAdded: isUserAdded,
            isPendingLogin: false,
            createdAt: Date(),
            scanSignature: nil,
            scanUpdatedAt: nil,
            usage: nil
        )
    }

    static func pending(provider: Provider, appPath: String, dataDir: String) -> LaunchProfile {
        LaunchProfile(
            id: UUID().uuidString,
            label: "\(provider.rawValue) - Connect account",
            provider: provider,
            appPath: appPath,
            dataDir: dataDir,
            accountName: nil,
            accountEmail: nil,
            signedIn: false,
            accountPlan: nil,
            quotaSummary: nil,
            quotaSource: nil,
            billingType: nil,
            accountUUID: nil,
            isUserAdded: true,
            isPendingLogin: true,
            createdAt: Date(),
            scanSignature: nil,
            scanUpdatedAt: nil,
            usage: nil
        )
    }

    mutating func apply(identity: AccountIdentity) {
        let account = identity.displayName ?? identity.email ?? "Signed-in account"
        label = "\(provider.rawValue) - \(account)"
        accountName = identity.displayName
        accountEmail = identity.email
        signedIn = identity.isSignedIn
        if let planName = identity.planName {
            accountPlan = planName
        }
        quotaSummary = identity.quotaSummary
        quotaSource = identity.quotaSource
        if let identityBillingType = identity.billingType {
            billingType = identityBillingType
        }
        if let identityAccountUUID = identity.accountUUID {
            accountUUID = identityAccountUUID
        }
        isPendingLogin = false
    }
}

struct AccountIdentity {
    var displayName: String?
    var email: String?
    var isSignedIn: Bool
    var planName: String?
    var quotaSummary: String?
    var quotaSource: String?
    var billingType: String?
    var accountUUID: String?

    var hasUsableLabel: Bool {
        displayName != nil || email != nil || isSignedIn
    }
}

struct AppConfig: Codable {
    var launchAtLogin: Bool
    var profiles: [LaunchProfile]
}

final class Paths {
    static let shared = Paths()

    let appSupport: URL
    let configURL: URL
    let profilesURL: URL
    let launchAgentURL: URL

    private init() {
        let fm = FileManager.default
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        appSupport = support.appendingPathComponent("LLM Usage Bar", isDirectory: true)
        configURL = appSupport.appendingPathComponent("config.json")
        profilesURL = appSupport.appendingPathComponent("Profiles", isDirectory: true)
        launchAgentURL = fm.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/fr.fraserv.llmusagebar.plist")
    }

    func ensureSupportDirectory() {
        try? FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: profilesURL, withIntermediateDirectories: true)
    }
}

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
            let config = AppConfig(launchAtLogin: false, profiles: inferProfiles(existing: []))
            save(config)
            return config
        }

        let config = AppConfig(launchAtLogin: existing.launchAtLogin, profiles: inferProfiles(existing: existing.profiles))
        save(config)
        return config
    }

    func loadCached() -> AppConfig {
        Paths.shared.ensureSupportDirectory()
        guard let data = try? Data(contentsOf: Paths.shared.configURL),
              let existing = try? decoder.decode(AppConfig.self, from: data) else {
            return AppConfig(launchAtLogin: false, profiles: [])
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
        let codexApp = "/Applications/Codex.app"

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

    private func defaultAppPath(for provider: Provider) -> String {
        switch provider {
        case .claude: return "/Applications/Claude.app"
        case .codex: return "/Applications/Codex.app"
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
        if profile.billingType == "none" {
            profile.accountPlan = "Free"
            if var usage = profile.usage {
                usage.accountPlan = "Free"
                profile.usage = usage
            }
        }
    }

    private func sortProfiles(_ lhs: LaunchProfile, _ rhs: LaunchProfile) -> Bool {
        if lhs.provider.rawValue != rhs.provider.rawValue {
            return lhs.provider.rawValue < rhs.provider.rawValue
        }
        return lhs.label.localizedCaseInsensitiveCompare(rhs.label) == .orderedAscending
    }
}

enum AccountResolver {
    private static let maxReadableBytes = 1_500_000
    private static let maxFilesPerStore = 8
    private static let maxBlobFilesPerStore = 16

    static func signature(in dataDir: String) -> String {
        let root = URL(fileURLWithPath: Launcher.expanding(dataDir))
        return relevantFiles(under: root).map { file in
            let values = try? file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            let modified = values?.contentModificationDate?.timeIntervalSince1970 ?? 0
            return "\(file.path):\(values?.fileSize ?? 0):\(modified)"
        }.joined(separator: "|")
    }

    static func identity(in dataDir: String, provider: Provider) -> AccountIdentity? {
        if provider == .codex, let account = CodexAuthStore.accountInfo(dataDir: dataDir) {
            return AccountIdentity(
                displayName: nil,
                email: account.email,
                isSignedIn: true,
                planName: account.plan,
                quotaSummary: nil,
                quotaSource: nil,
                billingType: nil,
                accountUUID: account.accountID
            )
        }

        let root = URL(fileURLWithPath: Launcher.expanding(dataDir))
        let files = relevantFiles(under: root)
        var emails: [String] = []
        var names: [String] = []
        var billingTypes: [String] = []
        var accountUUIDs: [String] = []
        var planSignals: [String] = []
        var signedIn = false

        for file in files {
            guard let text = readableText(from: file) else { continue }
            if text.contains("@") {
                emails.append(contentsOf: extractEmails(from: text))
            }
            if containsAny(["displayName", "display_name", "fullName", "full_name", "name", "email_address", "userEmail", "user_email"], in: text) {
                names.append(contentsOf: extractNamedValues(from: text))
            }
            if text.contains("\"billing_type\"") {
                billingTypes.append(contentsOf: captureMatches(pattern: #""billing_type"\s*:\s*"([^"]+)""#, in: text))
                if text.range(of: #""billing_type"\s*:\s*null"#, options: [.regularExpression, .caseInsensitive]) != nil {
                    billingTypes.append("none")
                }
            }
            if text.contains("\"account_uuid\"") {
                accountUUIDs.append(contentsOf: captureMatches(pattern: #""account_uuid"\s*:\s*"([^"]+)""#, in: text))
            }
            if containsAny(["membership", "plan", "subscription", "billing_plan", "account_plan"], in: text) {
                planSignals.append(contentsOf: planSignalsFrom(text: text))
            }
            if text.contains("\"account_id\"") ||
                text.contains("\"last_signed_in_username\"") ||
                text.contains("\"email_address\"") ||
                text.contains("\"account_uuid\"") ||
                text.contains("sessionKey") ||
                text.contains("lastSignedIn") {
                signedIn = true
            }
        }

        let email = preferredEmail(from: emails, provider: provider)
        let name = preferredName(from: names, excluding: email, provider: provider)
        let displayName = (email == nil || (name?.contains(" ") == true)) ? name : nil
        let billingType = billingTypes.first
        let accountUUID = accountUUIDs.first
        let planName = planName(provider: provider, billingType: billingType, planSignals: planSignals)

        if email != nil || displayName != nil {
            return AccountIdentity(
                displayName: displayName,
                email: email,
                isSignedIn: true,
                planName: planName,
                quotaSummary: nil,
                quotaSource: nil,
                billingType: billingType,
                accountUUID: accountUUID
            )
        }

        if provider == .codex && signedIn {
            return AccountIdentity(
                displayName: nil,
                email: nil,
                isSignedIn: true,
                planName: planName,
                quotaSummary: nil,
                quotaSource: nil,
                billingType: billingType,
                accountUUID: accountUUID
            )
        }

        return nil
    }

    private static func relevantFiles(under root: URL) -> [URL] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: root.path) else { return [] }

        var files: [URL] = []
        let directNames = [
            "Preferences",
            "Secure Preferences",
            "Local State",
            "config.json",
            "bridge-state.json",
            "buddy-tokens.json",
            "Default/Preferences",
            "Default/Secure Preferences",
            "Default/Partitions/codex-browser-app/Preferences",
            "Default/Partitions/codex-browser-app/Secure Preferences"
        ]

        for name in directNames {
            let file = root.appendingPathComponent(name)
            if fm.fileExists(atPath: file.path), isReadableCandidate(file) {
                files.append(file)
            }
        }

        let storageDirs: [(path: String, recursive: Bool, allowExtensionless: Bool, limit: Int)] = [
            ("Local Storage/leveldb", false, false, maxFilesPerStore),
            ("Session Storage", false, false, maxFilesPerStore),
            ("IndexedDB/https_claude.ai_0.indexeddb.leveldb", false, false, maxFilesPerStore),
            ("IndexedDB/https_claude.ai_0.indexeddb.blob", true, true, maxBlobFilesPerStore),
            ("Default/Local Storage/leveldb", false, false, maxFilesPerStore),
            ("Default/Session Storage", false, false, maxFilesPerStore),
            ("Default/IndexedDB/https_claude.ai_0.indexeddb.leveldb", false, false, maxFilesPerStore),
            ("Default/IndexedDB/https_claude.ai_0.indexeddb.blob", true, true, maxBlobFilesPerStore),
            ("Default/IndexedDB/https_chatgpt.com_0.indexeddb.leveldb", false, false, maxFilesPerStore),
            ("Default/Partitions/codex-browser-app/Local Storage/leveldb", false, false, maxFilesPerStore),
            ("Default/Partitions/codex-browser-app/Session Storage", false, false, maxFilesPerStore),
            ("Default/Partitions/codex-browser-app/IndexedDB/https_chatgpt.com_0.indexeddb.leveldb", false, false, maxFilesPerStore)
        ]

        for storageDir in storageDirs {
            let dir = root.appendingPathComponent(storageDir.path)
            files.append(contentsOf: relevantStoreFiles(
                in: dir,
                recursive: storageDir.recursive,
                allowExtensionless: storageDir.allowExtensionless,
                limit: storageDir.limit
            ))
        }

        return Array(Set(files)).sorted {
            modificationDate($0) > modificationDate($1)
        }
    }

    private static func relevantStoreFiles(in dir: URL, recursive: Bool, allowExtensionless: Bool, limit: Int) -> [URL] {
        let fm = FileManager.default
        var files: [URL] = []
        if recursive {
            guard let enumerator = fm.enumerator(
                at: dir,
                includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles]
            ) else {
                return []
            }
            for case let file as URL in enumerator where isRelevantFile(file, allowExtensionless: allowExtensionless) && isReadableCandidate(file) {
                files.append(file)
            }
        } else if let entries = try? fm.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) {
            files = entries.filter { isRelevantFile($0, allowExtensionless: allowExtensionless) && isReadableCandidate($0) }
        }

        return Array(files.sorted {
            modificationDate($0) > modificationDate($1)
        }.prefix(limit))
    }

    private static func modificationDate(_ file: URL) -> Date {
        (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }

    private static func isRelevantFile(_ file: URL, allowExtensionless: Bool = false) -> Bool {
        let name = file.lastPathComponent
        let allowedNames = [
            "Preferences",
            "Secure Preferences",
            "Local State"
        ]
        if allowedNames.contains(name) { return true }
        if name.hasSuffix(".ldb") || name.hasSuffix(".log") { return true }
        return allowExtensionless && !name.contains(".")
    }

    private static func isReadableCandidate(_ file: URL) -> Bool {
        guard let values = try? file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
              values.isRegularFile == true,
              (values.fileSize ?? 0) <= maxReadableBytes else {
            return false
        }
        return true
    }

    private static func readableText(from file: URL) -> String? {
        guard isReadableCandidate(file),
              let data = try? Data(contentsOf: file) else {
            return nil
        }

        return normalizeStorageText(String(decoding: data, as: UTF8.self))
    }

    private static func normalizeStorageText(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\u{0}", with: "")
            .replacingOccurrences(of: "\\u0022", with: "\"")
            .replacingOccurrences(of: "\\\"", with: "\"")
    }

    private static func extractEmails(from text: String) -> [String] {
        matches(
            pattern: #"[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}"#,
            in: text,
            options: [.caseInsensitive]
        )
        .map { $0.lowercased() }
    }

    private static func extractNamedValues(from text: String) -> [String] {
        let patterns = [
            #""(?:displayName|display_name|fullName|full_name|full_name|name|email|email_address|userEmail|user_email)"\s*:\s*"([^"]{3,120})""#,
            #"(?:displayName|display_name|fullName|full_name|name|email|email_address|userEmail|user_email)\\?":\\?"([^"\\]{3,120})\\?""#
        ]
        return patterns.flatMap { pattern in
            captureMatches(pattern: pattern, in: text)
        }
    }

    private static func preferredEmail(from emails: [String], provider: Provider) -> String? {
        let blockedDomains = [
            "example.com",
            "example.org",
            "getsentry.com",
            "openssl.org",
            "sourceware.org"
        ]
        let filtered = emails.filter { email in
            let parts = email.split(separator: "@")
            guard parts.count == 2,
                  parts[0].count >= 2,
                  let domain = parts.last else { return false }
            let domainText = String(domain)
            let domainParts = domainText.split(separator: ".")
            guard domainParts.count >= 2,
                  let tld = domainParts.last,
                  tld.count >= 2,
                  !["oa", "png", "jpg", "jpeg", "gif", "webp", "svg", "local"].contains(String(tld)) else {
                return false
            }
            if blockedDomains.contains(domainText) { return false }
            if email.contains("opengraph-image") { return false }
            return true
        }

        if provider == .claude {
            return filtered.first
        }
        let likelyAccountEmail = filtered.first { email in
            email.contains("openai") || email.contains("gmail") || email.contains("icloud") || email.contains("francois") || email.contains("francis")
        }
        return provider == .codex ? likelyAccountEmail : (likelyAccountEmail ?? filtered.first)
    }

    private static func preferredName(from names: [String], excluding email: String?, provider: Provider) -> String? {
        let blocked = Set([
            "Claude",
            "Codex",
            "Votre Codex",
            "Personne 1",
            "Personne 1",
            "Web Store",
            "Chromium PDF Viewer",
            "Anthropic",
            "Stable",
            "Auto",
            "All users",
            "Auto full",
            "Auto Stage3",
            "Auto Main Cohort",
            "M108 and Above"
        ])

        for rawName in names {
            let name = rawName
                .replacingOccurrences(of: #"\"#, with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty,
                  !blocked.contains(name),
                  name != email,
                  !name.contains("@"),
                  looksLikeHumanName(name),
                  name.count >= 3,
                  name.count <= 80 else {
                continue
            }
            return name
        }
        return nil
    }

    private static func planName(provider: Provider, billingType: String?, planSignals: [String]) -> String? {
        if provider == .claude, billingType == "none" {
            return "Free"
        }

        if let explicitPlan = planSignals.first(where: { signal in
            let lower = signal.lowercased()
            return ["max", "pro", "team", "plus", "free"].contains(lower)
        }) {
            return displayPlan(explicitPlan)
        }

        switch provider {
        case .claude:
            if billingType == "stripe_subscription" {
                return "Pro"
            }
        case .codex:
            return nil
        }

        return nil
    }

    private static func planSignalsFrom(text: String) -> [String] {
        var signals: [String] = []
        let patterns = [
            #""(?:plan|subscription_tier|tier|billing_plan|account_plan|membership)"\s*:\s*"(max|pro|team|plus|free)""#,
            #""(?:plan|subscription|membership)"[^"}]{0,140}"(max|pro|team|plus|free)""#,
            #"billing_type[^\n\r]{0,260}_?(max|pro|team|plus|free)"#,
            #"stripe_subscrip[^\n\r]{0,180}_?(max|pro|team|plus|free)"#,
            #""billing_type"\s*:\s*"([^"]+)""#
        ]

        for pattern in patterns {
            signals.append(contentsOf: captureMatches(pattern: pattern, in: text).map { $0.lowercased() })
        }

        return Array(Set(signals))
    }

    private static func displayPlan(_ raw: String) -> String {
        switch raw.lowercased() {
        case "max": return "Max"
        case "pro": return "Pro"
        case "team": return "Team"
        case "plus": return "Plus"
        case "free": return "Free"
        default: return raw
        }
    }

    private static func looksLikeHumanName(_ value: String) -> Bool {
        let letterCount = value.unicodeScalars.filter { CharacterSet.letters.contains($0) }.count
        guard letterCount >= 2 else { return false }
        if value.contains(".") || value.contains("_") || value.contains(",") || value.contains("\t") {
            return false
        }
        if value.rangeOfCharacter(from: .decimalDigits) != nil {
            return false
        }
        return value.range(
            of: #"^[\p{L}][\p{L} '\-]{1,78}$"#,
            options: [.regularExpression]
        ) != nil
    }

    private static func matches(pattern: String, in text: String, options: NSRegularExpression.Options = []) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, range: range).compactMap { result in
            guard let matchRange = Range(result.range, in: text) else { return nil }
            return String(text[matchRange])
        }
    }

    private static func captureMatches(pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, range: range).compactMap { result in
            guard result.numberOfRanges > 1,
                  let matchRange = Range(result.range(at: 1), in: text) else {
                return nil
            }
            return String(text[matchRange])
        }
    }

    private static func containsAny(_ needles: [String], in text: String) -> Bool {
        needles.contains { text.range(of: $0, options: [.caseInsensitive]) != nil }
    }
}

struct HTTPResponse {
    var statusCode: Int
    var data: Data
}

enum SimpleHTTP {
    static func get(_ url: URL, headers: [String: String], timeout: TimeInterval = 8) throws -> HTTPResponse {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = timeout
        headers.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
        return try perform(request)
    }

    static func postJSON(_ url: URL, body: [String: String], headers: [String: String], timeout: TimeInterval = 8) throws -> HTTPResponse {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        headers.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
        return try perform(request)
    }

    private static func perform(_ request: URLRequest) throws -> HTTPResponse {
        let semaphore = DispatchSemaphore(value: 0)
        var output: Result<HTTPResponse, Error>!
        URLSession.shared.dataTask(with: request) { data, response, error in
            defer { semaphore.signal() }
            if let error {
                output = .failure(error)
                return
            }
            guard let http = response as? HTTPURLResponse else {
                output = .failure(NSError(domain: "LLMUsageBar.HTTP", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid HTTP response"]))
                return
            }
            output = .success(HTTPResponse(statusCode: http.statusCode, data: data ?? Data()))
        }.resume()
        semaphore.wait()
        return try output.get()
    }
}

enum ProcessRunner {
    static func run(_ executable: String, arguments: [String], environment: [String: String]? = nil, timeout: TimeInterval = 5) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let environment {
            process.environment = environment
        }

        let output = Pipe()
        let error = Pipe()
        process.standardOutput = output
        process.standardError = error
        try process.run()

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        if process.isRunning {
            process.terminate()
            throw NSError(domain: "LLMUsageBar.Process", code: -2, userInfo: [NSLocalizedDescriptionKey: "\(executable) timed out"])
        }

        let data = output.fileHandleForReading.readDataToEndOfFile()
        if process.terminationStatus != 0 {
            let stderr = String(data: error.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw NSError(domain: "LLMUsageBar.Process", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: stderr.isEmpty ? "\(executable) failed" : stderr])
        }
        return String(data: data, encoding: .utf8) ?? ""
    }
}

enum ElectronCookieReader {
    struct Cookie {
        var host: String
        var name: String
        var value: String
    }

    static func cookieHeader(from dataDir: String, domains: [String], keychainServices: [String]) throws -> String {
        let cookieURL = URL(fileURLWithPath: Launcher.expanding(dataDir)).appendingPathComponent("Cookies")
        guard FileManager.default.fileExists(atPath: cookieURL.path) else {
            throw NSError(domain: "LLMUsageBar.Cookies", code: 1, userInfo: [NSLocalizedDescriptionKey: "Cookie database not found"])
        }

        let domainPredicate = domains.map { "host_key like '%\($0.replacingOccurrences(of: "'", with: "''"))'" }.joined(separator: " or ")
        let sql = "select host_key,name,value,hex(encrypted_value) from cookies where \(domainPredicate) order by host_key,name;"
        let output = try ProcessRunner.run(
            "/usr/bin/sqlite3",
            arguments: ["-separator", "\t", cookieURL.path, sql],
            timeout: 5)

        let passphrase = keychainServices.compactMap(keychainPassword(service:)).first
        let cookies = output
            .split(whereSeparator: \.isNewline)
            .compactMap { line -> Cookie? in
                let parts = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
                guard parts.count >= 4 else { return nil }
                let host = parts[0]
                let name = parts[1]
                let plain = parts[2]
                let encryptedHex = parts[3]
                let value: String?
                if !plain.isEmpty {
                    value = plain
                } else if let passphrase, let encrypted = Data(hexString: encryptedHex) {
                    value = decryptChromiumCookie(encrypted, passphrase: passphrase)
                } else {
                    value = nil
                }
                guard let value, !value.isEmpty else { return nil }
                return Cookie(host: host, name: name, value: value)
            }

        guard !cookies.isEmpty else {
            throw NSError(domain: "LLMUsageBar.Cookies", code: 2, userInfo: [NSLocalizedDescriptionKey: "No readable cookies found"])
        }
        return cookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
    }

    private static func keychainPassword(service: String) -> String? {
        for account in keychainAccountCandidates(for: service) {
            if let password = modernKeychainPassword(service: service, account: account) {
                return password
            }
            if let password = legacyKeychainPassword(service: service, account: account) {
                return password
            }
        }
        return nil
    }

    private static func keychainAccountCandidates(for service: String) -> [String?] {
        let guessed = service
            .replacingOccurrences(of: " Safe Storage", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var candidates: [String?] = guessed.isEmpty ? [] : [guessed]
        candidates.append(nil)
        return candidates
    }

    private static func modernKeychainPassword(service: String, account: String?) -> String? {
        for useDataProtectionKeychain in [false, true] {
            var query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecReturnData as String: kCFBooleanTrue as Any,
                kSecMatchLimit as String: kSecMatchLimitOne,
            ]
            if useDataProtectionKeychain {
                query[kSecUseDataProtectionKeychain as String] = kCFBooleanTrue as Any
            }
            if let account {
                query[kSecAttrAccount as String] = account
            }

            var item: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &item)
            if status == errSecSuccess,
               let data = item as? Data,
               let password = String(data: data, encoding: .utf8),
               !password.isEmpty {
                return password
            }
        }
        return nil
    }

    private static func legacyKeychainPassword(service: String, account: String?) -> String? {
        var length: UInt32 = 0
        var passwordData: UnsafeMutableRawPointer?

        let status: OSStatus = service.withCString { servicePointer in
            if let account {
                return account.withCString { accountPointer in
                    SecKeychainFindGenericPassword(
                        nil,
                        UInt32(strlen(servicePointer)),
                        servicePointer,
                        UInt32(strlen(accountPointer)),
                        accountPointer,
                        &length,
                        &passwordData,
                        nil)
                }
            }

            return SecKeychainFindGenericPassword(
                nil,
                UInt32(strlen(servicePointer)),
                servicePointer,
                0,
                nil,
                &length,
                &passwordData,
                nil)
        }
        guard status == errSecSuccess, let passwordData else { return nil }
        defer { SecKeychainItemFreeContent(nil, passwordData) }
        return String(data: Data(bytes: passwordData, count: Int(length)), encoding: .utf8)
    }

    private static func decryptChromiumCookie(_ encrypted: Data, passphrase: String) -> String? {
        guard encrypted.count > 3 else { return nil }
        let prefix = String(data: encrypted.prefix(3), encoding: .utf8)
        let cipher = (prefix == "v10" || prefix == "v11") ? Data(encrypted.dropFirst(3)) : encrypted
        let salt = Array("saltysalt".utf8)
        let iv = Array(repeating: UInt8(ascii: " "), count: kCCBlockSizeAES128)
        var key = Array(repeating: UInt8(0), count: kCCKeySizeAES128)
        let derivationStatus = passphrase.withCString { password in
            CCKeyDerivationPBKDF(
                CCPBKDFAlgorithm(kCCPBKDF2),
                password,
                strlen(password),
                salt,
                salt.count,
                CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1),
                1003,
                &key,
                key.count)
        }
        guard derivationStatus == kCCSuccess else { return nil }

        var output = Array(repeating: UInt8(0), count: cipher.count + kCCBlockSizeAES128)
        let outputCapacity = output.count
        var outputLength = 0
        let cryptStatus = cipher.withUnsafeBytes { cipherBytes in
            key.withUnsafeBytes { keyBytes in
                iv.withUnsafeBytes { ivBytes in
                    output.withUnsafeMutableBytes { outputBytes in
                        CCCrypt(
                            CCOperation(kCCDecrypt),
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionPKCS7Padding),
                            keyBytes.baseAddress,
                            key.count,
                            ivBytes.baseAddress,
                            cipherBytes.baseAddress,
                            cipher.count,
                            outputBytes.baseAddress,
                            outputCapacity,
                            &outputLength)
                    }
                }
            }
        }
        guard cryptStatus == kCCSuccess else { return nil }
        let decrypted = Data(output.prefix(outputLength))
        if let text = readableCookieValue(from: decrypted) {
            return text
        }
        if decrypted.count > 32 {
            return readableCookieValue(from: Data(decrypted.dropFirst(32)))
        }
        return nil
    }

    private static func readableCookieValue(from data: Data) -> String? {
        guard let value = String(data: data, encoding: .utf8), !value.isEmpty else {
            return nil
        }
        let hasControlCharacters = value.unicodeScalars.contains { scalar in
            scalar.value < 0x20 || scalar.value == 0x7f
        }
        return hasControlCharacters ? nil : value
    }
}

enum ClaudeCDPCookieReader {
    static func cookieHeader(from dataDir: String) -> String? {
        let portFile = URL(fileURLWithPath: Launcher.expanding(dataDir), isDirectory: true)
            .appendingPathComponent("DevToolsActivePort")
        guard let contents = try? String(contentsOf: portFile, encoding: .utf8),
              let portLine = contents.split(whereSeparator: \.isNewline).first,
              let port = Int(portLine) else {
            return nil
        }

        guard let targetsURL = URL(string: "http://127.0.0.1:\(port)/json"),
              let response = try? SimpleHTTP.get(targetsURL, headers: [:], timeout: 1),
              response.statusCode == 200,
              let targets = try? JSONSerialization.jsonObject(with: response.data) as? [[String: Any]] else {
            return nil
        }

        let webSocketURLString = targets.compactMap { target -> String? in
            guard let ws = target["webSocketDebuggerUrl"] as? String else { return nil }
            let url = (target["url"] as? String) ?? ""
            return url.contains("claude.ai") ? ws : nil
        }.first ?? targets.compactMap { $0["webSocketDebuggerUrl"] as? String }.first

        guard let webSocketURLString,
              let webSocketURL = URL(string: webSocketURLString),
              let cookies = fetchCookies(webSocketURL: webSocketURL) else {
            return nil
        }

        let claudeCookies = cookies.compactMap { cookie -> String? in
            guard let domain = cookie["domain"] as? String,
                  domain.contains("claude.ai"),
                  let name = cookie["name"] as? String,
                  let value = cookie["value"] as? String,
                  !value.isEmpty else {
                return nil
            }
            return "\(name)=\(value)"
        }

        return claudeCookies.isEmpty ? nil : claudeCookies.joined(separator: "; ")
    }

    private static func fetchCookies(webSocketURL: URL) -> [[String: Any]]? {
        let task = URLSession.shared.webSocketTask(with: webSocketURL)
        let semaphore = DispatchSemaphore(value: 0)
        var output: [[String: Any]]?

        task.resume()
        let message = #"{"id":1,"method":"Network.getAllCookies"}"#
        task.send(.string(message)) { error in
            if error != nil {
                semaphore.signal()
                return
            }

            task.receive { result in
                defer { semaphore.signal() }
                guard case let .success(message) = result else { return }

                let data: Data?
                switch message {
                case let .string(text):
                    data = text.data(using: .utf8)
                case let .data(raw):
                    data = raw
                @unknown default:
                    data = nil
                }

                guard let data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let result = json["result"] as? [String: Any],
                      let cookies = result["cookies"] as? [[String: Any]] else {
                    return
                }
                output = cookies
            }
        }

        _ = semaphore.wait(timeout: .now() + 2)
        task.cancel(with: .normalClosure, reason: nil)
        return output
    }
}

extension Data {
    init?(hexString: String) {
        let cleaned = hexString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleaned.count % 2 == 0 else { return nil }
        var bytes: [UInt8] = []
        var index = cleaned.startIndex
        while index < cleaned.endIndex {
            let next = cleaned.index(index, offsetBy: 2)
            guard let byte = UInt8(cleaned[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        self = Data(bytes)
    }
}

struct CodexAccountInfo {
    var email: String?
    var plan: String?
    var accountID: String?
}

struct CodexCredentials {
    var accessToken: String
    var refreshToken: String?
    var idToken: String?
    var accountID: String?
    var authURL: URL
}

enum CodexAuthStore {
    private static let refreshEndpoint = URL(string: "https://auth.openai.com/oauth/token")!
    private static let oauthClientID = "app_EMoamEEZ73f0CkXaXp7hrann"

    static func accountInfo(dataDir: String? = nil) -> CodexAccountInfo? {
        guard let credentials = try? loadCredentials(dataDir: dataDir) else { return nil }
        let payload = credentials.idToken.flatMap(parseJWT)
        let auth = payload?["https://api.openai.com/auth"] as? [String: Any]
        let profile = payload?["https://api.openai.com/profile"] as? [String: Any]
        let email = normalized((payload?["email"] as? String) ?? (profile?["email"] as? String))
        let plan = displayPlan(normalized((auth?["chatgpt_plan_type"] as? String) ?? (payload?["chatgpt_plan_type"] as? String)))
        let accountID = normalized(credentials.accountID ?? (auth?["chatgpt_account_id"] as? String))
        return CodexAccountInfo(email: email, plan: plan, accountID: accountID)
    }

    static func loadCredentials(dataDir: String? = nil) throws -> CodexCredentials {
        let authURL = authFileCandidates(dataDir: dataDir).first { FileManager.default.fileExists(atPath: $0.path) }
        guard let authURL else {
            throw NSError(domain: "LLMUsageBar.CodexAuth", code: 1, userInfo: [NSLocalizedDescriptionKey: "Codex auth.json not found"])
        }
        let data = try Data(contentsOf: authURL)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(domain: "LLMUsageBar.CodexAuth", code: 2, userInfo: [NSLocalizedDescriptionKey: "Codex auth.json is invalid"])
        }
        if let apiKey = normalized(json["OPENAI_API_KEY"] as? String) {
            return CodexCredentials(accessToken: apiKey, refreshToken: nil, idToken: nil, accountID: nil, authURL: authURL)
        }
        guard let tokens = json["tokens"] as? [String: Any],
              let access = normalized((tokens["access_token"] as? String) ?? (tokens["accessToken"] as? String)) else {
            throw NSError(domain: "LLMUsageBar.CodexAuth", code: 3, userInfo: [NSLocalizedDescriptionKey: "Codex auth.json has no access token"])
        }
        let idToken = normalized((tokens["id_token"] as? String) ?? (tokens["idToken"] as? String))
        let payload = idToken.flatMap(parseJWT)
        let auth = payload?["https://api.openai.com/auth"] as? [String: Any]
        let accountID = normalized((tokens["account_id"] as? String) ?? (tokens["accountId"] as? String)) ??
            normalized(auth?["chatgpt_account_id"] as? String)
        return CodexCredentials(
            accessToken: access,
            refreshToken: normalized((tokens["refresh_token"] as? String) ?? (tokens["refreshToken"] as? String)),
            idToken: idToken,
            accountID: accountID,
            authURL: authURL)
    }

    static func refreshCredentials(_ credentials: CodexCredentials) throws -> CodexCredentials {
        guard let refreshToken = credentials.refreshToken, !refreshToken.isEmpty else {
            return credentials
        }

        let response = try SimpleHTTP.postJSON(
            refreshEndpoint,
            body: [
                "client_id": oauthClientID,
                "grant_type": "refresh_token",
                "refresh_token": refreshToken,
                "scope": "openid profile email",
            ],
            headers: [:])
        guard response.statusCode == 200,
              let json = try JSONSerialization.jsonObject(with: response.data) as? [String: Any] else {
            throw NSError(domain: "LLMUsageBar.CodexAuth", code: response.statusCode, userInfo: [NSLocalizedDescriptionKey: "Codex token refresh HTTP \(response.statusCode)"])
        }

        let refreshed = CodexCredentials(
            accessToken: normalized(json["access_token"] as? String) ?? credentials.accessToken,
            refreshToken: normalized(json["refresh_token"] as? String) ?? credentials.refreshToken,
            idToken: normalized(json["id_token"] as? String) ?? credentials.idToken,
            accountID: credentials.accountID,
            authURL: credentials.authURL)
        try? saveCredentials(refreshed)
        return refreshed
    }

    private static func saveCredentials(_ credentials: CodexCredentials) throws {
        var json: [String: Any] = [:]
        if let data = try? Data(contentsOf: credentials.authURL),
           let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            json = existing
        }

        var tokens: [String: Any] = [
            "access_token": credentials.accessToken
        ]
        if let refreshToken = credentials.refreshToken {
            tokens["refresh_token"] = refreshToken
        }
        if let idToken = credentials.idToken {
            tokens["id_token"] = idToken
        }
        if let accountID = credentials.accountID {
            tokens["account_id"] = accountID
        }
        json["tokens"] = tokens
        json["last_refresh"] = ISO8601DateFormatter().string(from: Date())

        let data = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
        try FileManager.default.createDirectory(at: credentials.authURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: credentials.authURL, options: [.atomic])
    }

    static func parseJWT(_ token: String) -> [String: Any]? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var payload = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while payload.count % 4 != 0 {
            payload.append("=")
        }
        guard let data = Data(base64Encoded: payload),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return json
    }

    static func displayPlan(_ raw: String?) -> String? {
        guard let raw else { return nil }
        switch raw.lowercased() {
        case "plus": return "Plus"
        case "pro": return "Pro"
        case "team": return "Team"
        case "enterprise": return "Enterprise"
        case "free": return "Free"
        case "go": return "Go"
        default: return raw
        }
    }

    private static func authFileCandidates(dataDir: String?) -> [URL] {
        var urls: [URL] = []
        if let dataDir {
            let root = URL(fileURLWithPath: Launcher.expanding(dataDir), isDirectory: true)
            urls.append(root.appendingPathComponent("CodexHome/auth.json"))
            urls.append(root.appendingPathComponent("auth.json"))
        }
        if let codexHome = ProcessInfo.processInfo.environment["CODEX_HOME"], !codexHome.isEmpty {
            urls.append(URL(fileURLWithPath: codexHome, isDirectory: true).appendingPathComponent("auth.json"))
        }
        urls.append(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/auth.json"))
        return urls
    }

    private static func normalized(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
}

enum UsageRefresher {
    static func refresh(_ config: AppConfig) -> AppConfig {
        var updated = config
        let profiles = updated.profiles
        var refreshed = Array<LaunchProfile?>(repeating: nil, count: profiles.count)
        let lock = NSLock()

        DispatchQueue.concurrentPerform(iterations: profiles.count) { index in
            var profile = profiles[index]
            switch profile.provider {
            case .claude:
                profile = refreshClaude(profile)
            case .codex:
                profile = refreshCodex(profile)
            }
            lock.lock()
            refreshed[index] = profile
            lock.unlock()
        }

        for index in refreshed.indices {
            if let profile = refreshed[index] {
                updated.profiles[index] = profile
            }
        }
        return updated
    }

    static func quotaProof(_ config: AppConfig) -> QuotaProofReport {
        QuotaProofReport(
            generatedAt: isoString(Date()) ?? "",
            profiles: config.profiles.map { profile in
                switch profile.provider {
                case .claude:
                    return claudeProof(profile)
                case .codex:
                    return codexProof(profile)
                }
            })
    }

    private static func claudeProof(_ profile: LaunchProfile) -> QuotaProof {
        let endpoint = "https://claude.ai/api/organizations/{org}/usage"
        do {
            let cookieHeader = try ClaudeCDPCookieReader.cookieHeader(from: profile.dataDir) ??
                ElectronCookieReader.cookieHeader(
                    from: profile.dataDir,
                    domains: ["claude.ai"],
                    keychainServices: [
                        "Chromium Safe Storage",
                        "Claude Safe Storage",
                        "Chrome Safe Storage",
                        "Brave Safe Storage",
                        "Microsoft Edge Safe Storage",
                        "Arc Safe Storage",
                    ])
            let orgID = try claudeOrganizationID(cookieHeader: cookieHeader)
            let response = try SimpleHTTP.get(
                URL(string: "https://claude.ai/api/organizations/\(orgID)/usage")!,
                headers: claudeHeaders(cookieHeader: cookieHeader))
            guard response.statusCode == 200,
                  let json = try JSONSerialization.jsonObject(with: response.data) as? [String: Any] else {
                return QuotaProof(
                    provider: profile.provider,
                    email: profile.accountEmail,
                    plan: profile.accountPlan,
                    endpoint: endpoint,
                    httpStatus: response.statusCode,
                    status: "Claude usage HTTP \(response.statusCode)",
                    parserMatchesProvider: false,
                    windows: [],
                    creditsRemaining: nil)
            }

            let windows = [
                claudeProofWindow(key: "five_hour", title: "5h", json: json),
                claudeProofWindow(key: "seven_day", title: "Week", json: json),
                claudeProofWindow(key: "seven_day_sonnet", title: "Sonnet week", json: json),
            ].compactMap { $0 }
            return QuotaProof(
                provider: profile.provider,
                email: profile.accountEmail,
                plan: profile.accountPlan,
                endpoint: endpoint,
                httpStatus: response.statusCode,
                status: windows.isEmpty ? "Claude usage unavailable" : nil,
                parserMatchesProvider: !windows.isEmpty && windows.allSatisfy(\.matches),
                windows: windows,
                creditsRemaining: nil)
        } catch {
            return QuotaProof(
                provider: profile.provider,
                email: profile.accountEmail,
                plan: profile.accountPlan,
                endpoint: endpoint,
                httpStatus: nil,
                status: error.localizedDescription,
                parserMatchesProvider: false,
                windows: [],
                creditsRemaining: nil)
        }
    }

    private static func codexProof(_ profile: LaunchProfile) -> QuotaProof {
        let endpoint = "https://chatgpt.com/backend-api/wham/usage"
        let account = CodexAuthStore.accountInfo(dataDir: profile.dataDir)
        do {
            var credentials = try CodexAuthStore.loadCredentials(dataDir: profile.dataDir)
            var response = try codexUsageResponse(credentials: credentials)
            if response.statusCode == 401 || response.statusCode == 403 {
                credentials = try CodexAuthStore.refreshCredentials(credentials)
                response = try codexUsageResponse(credentials: credentials)
            }
            guard (200...299).contains(response.statusCode),
                  let json = try JSONSerialization.jsonObject(with: response.data) as? [String: Any] else {
                return QuotaProof(
                    provider: profile.provider,
                    email: account?.email ?? profile.accountEmail,
                    plan: account?.plan ?? profile.accountPlan,
                    endpoint: endpoint,
                    httpStatus: response.statusCode,
                    status: "Codex usage HTTP \(response.statusCode)",
                    parserMatchesProvider: false,
                    windows: [],
                    creditsRemaining: nil)
            }

            let rateLimit = json["rate_limit"] as? [String: Any]
            let windows = [
                codexProofWindow(rateLimit?["primary_window"], title: "5h"),
                codexProofWindow(rateLimit?["secondary_window"], title: "Week"),
            ].compactMap { $0 }
            let credits = json["credits"] as? [String: Any]
            let balance = flexibleDouble(credits?["balance"])
            let plan = CodexAuthStore.displayPlan((json["plan_type"] as? String) ?? account?.plan)

            return QuotaProof(
                provider: profile.provider,
                email: account?.email ?? profile.accountEmail,
                plan: plan,
                endpoint: endpoint,
                httpStatus: response.statusCode,
                status: windows.isEmpty && balance == nil ? "Codex usage unavailable" : nil,
                parserMatchesProvider: !windows.isEmpty && windows.allSatisfy(\.matches),
                windows: windows,
                creditsRemaining: balance)
        } catch {
            return QuotaProof(
                provider: profile.provider,
                email: account?.email ?? profile.accountEmail,
                plan: account?.plan ?? profile.accountPlan,
                endpoint: endpoint,
                httpStatus: nil,
                status: error.localizedDescription,
                parserMatchesProvider: false,
                windows: [],
                creditsRemaining: nil)
        }
    }

    private static func refreshClaude(_ profile: LaunchProfile) -> LaunchProfile {
        var profile = profile
        do {
            let cookieHeader = try ClaudeCDPCookieReader.cookieHeader(from: profile.dataDir) ??
                ElectronCookieReader.cookieHeader(
                    from: profile.dataDir,
                    domains: ["claude.ai"],
                    keychainServices: [
                        "Chromium Safe Storage",
                        "Claude Safe Storage",
                        "Chrome Safe Storage",
                        "Brave Safe Storage",
                        "Microsoft Edge Safe Storage",
                        "Arc Safe Storage",
                    ])
            let orgID = try claudeOrganizationID(cookieHeader: cookieHeader)
            let usage = try claudeUsage(cookieHeader: cookieHeader, orgID: orgID, profile: profile)
            profile.usage = usage
            if let email = usage.accountEmail {
                profile.accountEmail = email
                profile.label = "\(profile.provider.rawValue) - \(email)"
                profile.signedIn = true
            }
            if let plan = usage.accountPlan {
                profile.accountPlan = plan
            }
        } catch {
            profile.usage = UsageInfo(
                source: "claude-web",
                status: error.localizedDescription,
                windows: [],
                creditsRemaining: nil,
                accountEmail: profile.accountEmail,
                accountPlan: profile.accountPlan,
                updatedAt: Date())
        }
        return profile
    }

    private static func refreshCodex(_ profile: LaunchProfile) -> LaunchProfile {
        var profile = profile
        let account = CodexAuthStore.accountInfo(dataDir: profile.dataDir)
        if let email = account?.email {
            profile.accountEmail = email
            profile.label = "\(profile.provider.rawValue) - \(email)"
            profile.signedIn = true
        }
        if let plan = account?.plan {
            profile.accountPlan = plan
        }
        if let accountID = account?.accountID {
            profile.accountUUID = accountID
        }

        do {
            let usage = try codexUsage(profile: profile)
            profile.usage = usage
            if let email = usage.accountEmail {
                profile.accountEmail = email
                profile.label = "\(profile.provider.rawValue) - \(email)"
            }
            if let plan = usage.accountPlan {
                profile.accountPlan = plan
            }
        } catch {
            profile.usage = UsageInfo(
                source: "codex-oauth",
                status: error.localizedDescription,
                windows: [],
                creditsRemaining: nil,
                accountEmail: profile.accountEmail,
                accountPlan: profile.accountPlan,
                updatedAt: Date())
        }
        return profile
    }

    private static func claudeOrganizationID(cookieHeader: String) throws -> String {
        if let direct = cookieValue("lastActiveOrg", in: cookieHeader) {
            return direct
        }
        let response = try SimpleHTTP.get(
            URL(string: "https://claude.ai/api/bootstrap")!,
            headers: claudeHeaders(cookieHeader: cookieHeader))
        guard response.statusCode == 200,
              let json = try JSONSerialization.jsonObject(with: response.data) as? [String: Any],
              let account = json["account"] as? [String: Any],
              let org = account["lastActiveOrgId"] as? String else {
            throw NSError(domain: "LLMUsageBar.Claude", code: response.statusCode, userInfo: [NSLocalizedDescriptionKey: "Claude organization unavailable"])
        }
        return org
    }

    private static func claudeUsage(cookieHeader: String, orgID: String, profile: LaunchProfile) throws -> UsageInfo {
        let response = try SimpleHTTP.get(
            URL(string: "https://claude.ai/api/organizations/\(orgID)/usage")!,
            headers: claudeHeaders(cookieHeader: cookieHeader))
        guard response.statusCode == 200,
              let json = try JSONSerialization.jsonObject(with: response.data) as? [String: Any] else {
            throw NSError(domain: "LLMUsageBar.Claude", code: response.statusCode, userInfo: [NSLocalizedDescriptionKey: "Claude usage HTTP \(response.statusCode)"])
        }

        var windows: [UsageWindow] = []
        appendClaudeWindow(key: "five_hour", title: "5h", json: json, windows: &windows)
        appendClaudeWindow(key: "seven_day", title: "Week", json: json, windows: &windows)
        appendClaudeWindow(key: "seven_day_sonnet", title: "Sonnet week", json: json, windows: &windows)

        return UsageInfo(
            source: "claude-web",
            status: windows.isEmpty ? "Claude usage unavailable" : nil,
            windows: windows,
            creditsRemaining: nil,
            accountEmail: profile.accountEmail,
            accountPlan: profile.accountPlan,
            updatedAt: Date())
    }

    private static func appendClaudeWindow(key: String, title: String, json: [String: Any], windows: inout [UsageWindow]) {
        guard let block = json[key] as? [String: Any],
              let used = flexibleDouble(block["utilization"]) else { return }
        windows.append(UsageWindow(
            title: title,
            usedPercent: max(0, min(100, used)),
            remainingPercent: max(0, min(100, 100 - used)),
            resetsAt: (block["resets_at"] as? String).flatMap(parseISODate)))
    }

    private static func claudeProofWindow(key: String, title: String, json: [String: Any]) -> QuotaWindowProof? {
        guard let block = json[key] as? [String: Any],
              let providerUsed = flexibleDouble(block["utilization"]) else { return nil }
        let parsedUsed = clampPercent(providerUsed)
        let parsedRemaining = clampPercent(100 - providerUsed)
        let providerReset = block["resets_at"] as? String
        let parsedReset = providerReset.flatMap(parseISODate).flatMap(isoString)
        return QuotaWindowProof(
            title: title,
            providerUsedPercent: providerUsed,
            parsedUsedPercent: parsedUsed,
            providerRemainingPercent: parsedRemaining,
            parsedRemainingPercent: parsedRemaining,
            providerReset: providerReset,
            parsedReset: parsedReset,
            matches: percentMatches(providerUsed, parsedUsed) && percentMatches(clampPercent(100 - providerUsed), parsedRemaining) && (providerReset == nil || parsedReset != nil))
    }

    private static func claudeHeaders(cookieHeader: String) -> [String: String] {
        [
            "Cookie": cookieHeader,
            "Accept": "application/json",
            "Content-Type": "application/json",
            "Origin": "https://claude.ai",
            "Referer": "https://claude.ai",
            "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X) LLMUsageBar",
        ]
    }

    private static func codexUsage(profile: LaunchProfile) throws -> UsageInfo {
        var credentials = try CodexAuthStore.loadCredentials(dataDir: profile.dataDir)
        var response = try codexUsageResponse(credentials: credentials)
        if response.statusCode == 401 || response.statusCode == 403 {
            credentials = try CodexAuthStore.refreshCredentials(credentials)
            response = try codexUsageResponse(credentials: credentials)
        }
        guard (200...299).contains(response.statusCode),
              let json = try JSONSerialization.jsonObject(with: response.data) as? [String: Any] else {
            throw NSError(domain: "LLMUsageBar.Codex", code: response.statusCode, userInfo: [NSLocalizedDescriptionKey: "Codex usage HTTP \(response.statusCode)"])
        }

        let account = CodexAuthStore.accountInfo(dataDir: profile.dataDir)
        let plan = CodexAuthStore.displayPlan((json["plan_type"] as? String) ?? account?.plan)
        let rateLimit = json["rate_limit"] as? [String: Any]
        var windows: [UsageWindow] = []
        appendCodexWindow(rateLimit?["primary_window"], title: "5h", windows: &windows)
        appendCodexWindow(rateLimit?["secondary_window"], title: "Week", windows: &windows)

        let credits = json["credits"] as? [String: Any]
        let balance = flexibleDouble(credits?["balance"])

        return UsageInfo(
            source: "codex-oauth",
            status: windows.isEmpty && balance == nil ? "Codex usage unavailable" : nil,
            windows: windows,
            creditsRemaining: balance,
            accountEmail: account?.email,
            accountPlan: plan,
            updatedAt: Date())
    }

    private static func codexUsageResponse(credentials: CodexCredentials) throws -> HTTPResponse {
        var headers = [
            "Authorization": "Bearer \(credentials.accessToken)",
            "Accept": "application/json",
            "User-Agent": "LLMUsageBar",
        ]
        if let accountID = credentials.accountID {
            headers["ChatGPT-Account-Id"] = accountID
        }
        return try SimpleHTTP.get(
            URL(string: "https://chatgpt.com/backend-api/wham/usage")!,
            headers: headers)
    }

    private static func appendCodexWindow(_ raw: Any?, title: String, windows: inout [UsageWindow]) {
        guard let block = raw as? [String: Any],
              let used = flexibleDouble(block["used_percent"]) else { return }
        let resetSeconds = flexibleDouble(block["reset_at"])
        windows.append(UsageWindow(
            title: title,
            usedPercent: max(0, min(100, used)),
            remainingPercent: max(0, min(100, 100 - used)),
            resetsAt: resetSeconds.map { Date(timeIntervalSince1970: $0) }))
    }

    private static func codexProofWindow(_ raw: Any?, title: String) -> QuotaWindowProof? {
        guard let block = raw as? [String: Any],
              let providerUsed = flexibleDouble(block["used_percent"]) else { return nil }
        let parsedUsed = clampPercent(providerUsed)
        let parsedRemaining = clampPercent(100 - providerUsed)
        let resetSeconds = flexibleDouble(block["reset_at"])
        let parsedReset = resetSeconds.map { Date(timeIntervalSince1970: $0) }.flatMap(isoString)
        return QuotaWindowProof(
            title: title,
            providerUsedPercent: providerUsed,
            parsedUsedPercent: parsedUsed,
            providerRemainingPercent: parsedRemaining,
            parsedRemainingPercent: parsedRemaining,
            providerReset: resetSeconds.map { String(format: "%.0f", $0) },
            parsedReset: parsedReset,
            matches: percentMatches(providerUsed, parsedUsed) && percentMatches(clampPercent(100 - providerUsed), parsedRemaining) && (resetSeconds == nil || parsedReset != nil))
    }

    private static func cookieValue(_ name: String, in header: String) -> String? {
        header.split(separator: ";").compactMap { part -> String? in
            let pieces = part.trimmingCharacters(in: .whitespaces).split(separator: "=", maxSplits: 1)
            guard pieces.count == 2, pieces[0] == name else { return nil }
            return String(pieces[1])
        }.first
    }

    private static func flexibleDouble(_ value: Any?) -> Double? {
        if let value = value as? Double { return value }
        if let value = value as? Int { return Double(value) }
        if let value = value as? String { return Double(value.trimmingCharacters(in: .whitespacesAndNewlines)) }
        return nil
    }

    private static func clampPercent(_ value: Double) -> Double {
        max(0, min(100, value))
    }

    private static func percentMatches(_ provider: Double?, _ parsed: Double?) -> Bool {
        switch (provider, parsed) {
        case let (provider?, parsed?):
            return abs(clampPercent(provider) - parsed) < 0.0001
        case (nil, nil):
            return true
        default:
            return false
        }
    }

    private static func isoString(_ date: Date?) -> String? {
        guard let date else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private static func parseISODate(_ raw: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return fractional.date(from: raw) ?? plain.date(from: raw)
    }
}

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

final class SettingsWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    private var config: AppConfig
    private let onSave: (AppConfig) -> Void
    private let table = NSTableView()
    private let labelField = NSTextField()
    private let appPathField = NSTextField()
    private let dataDirField = NSTextField()
    private let providerPopup = NSPopUpButton()
    private let launchAtLogin = NSButton(checkboxWithTitle: "Launch at login", target: nil, action: nil)
    private let statusLabel = NSTextField(labelWithString: "")

    init(config: AppConfig, onSave: @escaping (AppConfig) -> Void) {
        self.config = config
        self.onSave = onSave
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 430),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "LLM Usage Bar Settings"
        window.center()
        super.init(window: window)
        buildUI()
        loadSelection()
    }

    required init?(coder: NSCoder) {
        nil
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        config.profiles.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = NSTableCellView()
        let text = NSTextField(labelWithString: config.profiles[row].label)
        text.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(text)
        NSLayoutConstraint.activate([
            text.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
            text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
            text.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
        ])
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        loadSelection()
    }

    private func buildUI() {
        guard let content = window?.contentView else { return }

        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        table.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("profile")))
        table.headerView = nil
        table.delegate = self
        table.dataSource = self
        table.rowHeight = 30
        scroll.documentView = table

        let listTitle = NSTextField(labelWithString: "Accounts")
        listTitle.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        let addAccountButton = NSButton(title: "+", target: self, action: #selector(addAccount))
        addAccountButton.bezelStyle = .rounded
        addAccountButton.toolTip = "Add Claude or Codex account"
        addAccountButton.widthAnchor.constraint(equalToConstant: 32).isActive = true

        let listHeader = NSStackView(views: [listTitle, addAccountButton])
        listHeader.translatesAutoresizingMaskIntoConstraints = false
        listHeader.orientation = .horizontal
        listHeader.spacing = 8
        listTitle.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let leftPane = NSStackView(views: [listHeader, scroll])
        leftPane.translatesAutoresizingMaskIntoConstraints = false
        leftPane.orientation = .vertical
        leftPane.spacing = 8

        providerPopup.addItems(withTitles: Provider.allCases.map(\.rawValue))
        launchAtLogin.state = config.launchAtLogin ? .on : .off

        let form = NSStackView()
        form.translatesAutoresizingMaskIntoConstraints = false
        form.orientation = .vertical
        form.spacing = 10

        addRow(to: form, label: "Label", control: labelField)
        addRow(to: form, label: "Provider", control: providerPopup)
        addRow(to: form, label: "App path", control: appPathField)
        addRow(to: form, label: "Profile data folder", control: dataDirField)
        form.addArrangedSubview(launchAtLogin)

        statusLabel.textColor = .secondaryLabelColor
        form.addArrangedSubview(statusLabel)

        let removeButton = NSButton(title: "Remove", target: self, action: #selector(removeProfile))
        let inferButton = NSButton(title: "Infer Connected Accounts", target: self, action: #selector(inferExisting))
        let saveButton = NSButton(title: "Save", target: self, action: #selector(save))
        saveButton.keyEquivalent = "\r"

        let buttons = NSStackView(views: [removeButton, inferButton, saveButton])
        buttons.translatesAutoresizingMaskIntoConstraints = false
        buttons.orientation = .horizontal
        buttons.spacing = 8
        form.addArrangedSubview(buttons)

        content.addSubview(leftPane)
        content.addSubview(form)

        NSLayoutConstraint.activate([
            leftPane.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            leftPane.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            leftPane.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
            leftPane.widthAnchor.constraint(equalToConstant: 230),

            form.leadingAnchor.constraint(equalTo: leftPane.trailingAnchor, constant: 18),
            form.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            form.topAnchor.constraint(equalTo: content.topAnchor, constant: 18)
        ])

        if !config.profiles.isEmpty {
            table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }
    }

    private func addRow(to form: NSStackView, label: String, control: NSView) {
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false

        let labelView = NSTextField(labelWithString: label)
        labelView.alignment = .right
        labelView.widthAnchor.constraint(equalToConstant: 130).isActive = true

        control.translatesAutoresizingMaskIntoConstraints = false
        control.widthAnchor.constraint(greaterThanOrEqualToConstant: 360).isActive = true

        row.addArrangedSubview(labelView)
        row.addArrangedSubview(control)
        form.addArrangedSubview(row)
    }

    private func loadSelection() {
        let row = table.selectedRow
        guard row >= 0, row < config.profiles.count else { return }
        let profile = config.profiles[row]
        labelField.stringValue = profile.label
        providerPopup.selectItem(withTitle: profile.provider.rawValue)
        appPathField.stringValue = profile.appPath
        dataDirField.stringValue = profile.dataDir
        statusLabel.stringValue = statusText(for: profile)
    }

    private func writeSelection() {
        let row = table.selectedRow
        guard row >= 0, row < config.profiles.count else { return }
        config.profiles[row].label = labelField.stringValue
        config.profiles[row].provider = Provider(rawValue: providerPopup.titleOfSelectedItem ?? "Claude") ?? .claude
        config.profiles[row].appPath = appPathField.stringValue
        config.profiles[row].dataDir = dataDirField.stringValue
    }

    private func statusText(for profile: LaunchProfile) -> String {
        if profile.isPendingLogin == true {
            return "Waiting for login in the isolated \(profile.provider.rawValue) window."
        }

        var parts: [String] = []
        if let email = profile.accountEmail {
            parts.append(email)
        } else if let name = profile.accountName {
            parts.append(name)
        } else if profile.signedIn == true {
            parts.append("Signed in; exact account name is not exposed locally.")
        }

        if let plan = profile.accountPlan {
            parts.append("Subscription: \(plan)")
        }

        return parts.isEmpty ? "No connected account detected in this profile." : parts.joined(separator: "   ")
    }

    @objc private func addAccount() {
        writeSelection()

        let alert = NSAlert()
        alert.messageText = "Add Account"
        alert.informativeText = "Choose the app to open in a new isolated profile, then sign in there. LLM Usage Bar will detect the account automatically."
        alert.addButton(withTitle: "Open Login Window")
        alert.addButton(withTitle: "Cancel")

        let picker = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 240, height: 28))
        picker.addItems(withTitles: Provider.allCases.map(\.rawValue))
        if let selected = providerPopup.titleOfSelectedItem {
            picker.selectItem(withTitle: selected)
        }
        alert.accessoryView = picker

        guard alert.runModal() == .alertFirstButtonReturn,
              let provider = Provider(rawValue: picker.titleOfSelectedItem ?? "") else {
            return
        }

        let profile = ConfigStore.shared.createPendingProfile(provider: provider)
        config.profiles.append(profile)
        onSave(config)
        table.reloadData()
        table.selectRowIndexes(IndexSet(integer: config.profiles.count - 1), byExtendingSelection: false)

        do {
            try Launcher.launch(profile)
            statusLabel.stringValue = "Opened \(provider.rawValue). Sign in there; this list will update automatically."
        } catch {
            config.profiles[config.profiles.count - 1] = profile
            onSave(config)
            table.reloadData()
            statusLabel.stringValue = "Could not open login window: \(error.localizedDescription)"
        }
    }

    @objc private func removeProfile() {
        let row = table.selectedRow
        guard row >= 0, row < config.profiles.count else { return }
        config.profiles.remove(at: row)
        table.reloadData()
        if !config.profiles.isEmpty {
            table.selectRowIndexes(IndexSet(integer: min(row, config.profiles.count - 1)), byExtendingSelection: false)
        }
    }

    @objc private func inferExisting() {
        writeSelection()
        let selectedID = selectedProfileID()
        let selectedProvider = selectedProviderValue()
        let inferred = ConfigStore.shared.inferProfiles(existing: config.profiles)
        config.profiles = inferred
        table.reloadData()
        restoreSelection(id: selectedID, provider: selectedProvider)
        statusLabel.stringValue = "Inferred \(inferred.count) connected account(s)."
    }

    @objc private func save() {
        writeSelection()
        config.launchAtLogin = launchAtLogin.state == .on
        onSave(config)
        statusLabel.stringValue = "Saved."
        table.reloadData()
    }

    func refreshFromDiskPreservingSelection() {
        let selectedID = selectedProfileID()
        let selectedProvider = selectedProviderValue()
        config = ConfigStore.shared.load()
        table.reloadData()
        restoreSelection(id: selectedID, provider: selectedProvider)
    }

    private func selectedProfileID() -> String? {
        let row = table.selectedRow
        guard row >= 0, row < config.profiles.count else { return nil }
        return config.profiles[row].id
    }

    private func selectedProviderValue() -> Provider? {
        let row = table.selectedRow
        guard row >= 0, row < config.profiles.count else { return nil }
        return config.profiles[row].provider
    }

    private func restoreSelection(id: String?, provider: Provider?) {
        guard !config.profiles.isEmpty else {
            loadSelection()
            return
        }

        if let id, let row = config.profiles.firstIndex(where: { $0.id == id }) {
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            return
        }

        if let provider, let row = config.profiles.firstIndex(where: { $0.provider == provider }) {
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            return
        }

        table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
    }
}

enum ProfileFormatting {
    static func title(for profile: LaunchProfile) -> String {
        if profile.isPendingLogin == true {
            return "Connect account"
        }
        if let email = profile.accountEmail {
            return email
        }
        if let name = profile.accountName {
            return name
        }
        return profile.signedIn == true ? "Signed-in account" : "Not signed in"
    }

    static func subtitle(for profile: LaunchProfile) -> String {
        var parts = [profile.provider.rawValue]
        if let plan = profile.usage?.accountPlan ?? profile.accountPlan {
            parts.append(plan)
        } else if profile.signedIn == true {
            parts.append("Subscription unknown")
        }
        return parts.joined(separator: " · ")
    }

    static func detail(for profile: LaunchProfile, isRefreshing: Bool) -> String {
        if let usage = profile.usage {
            return usage.summaryLine
        }
        if profile.isPendingLogin == true {
            return "Waiting for login in the isolated profile"
        }
        return isRefreshing ? "Checking account and quota..." : "Usage not refreshed yet"
    }

    static func usageLines(for profile: LaunchProfile, isRefreshing: Bool) -> [String] {
        if let usage = profile.usage {
            var lines = usage.windows.prefix(3).map { window in
                "\(window.title): \(window.displayText.replacingOccurrences(of: " - ", with: " · "))"
            }
            if let creditsRemaining = usage.creditsRemaining {
                lines.append(String(format: "Credits: %.0f", creditsRemaining))
            }
            if lines.isEmpty, let status = usage.status {
                lines.append(status)
            }
            return lines.isEmpty ? ["Usage unavailable"] : lines
        }
        if profile.isPendingLogin == true {
            return ["Waiting for login in the isolated profile"]
        }
        return [isRefreshing ? "Checking account and quota..." : "Usage not refreshed yet"]
    }

    static func windowTitle(_ title: String) -> String {
        switch title {
        case "5h": return "Session"
        case "Week": return "Weekly"
        case "Sonnet week": return "Sonnet"
        default: return title
        }
    }

    static func usedText(for window: UsageWindow) -> String {
        "\(Int(window.usedPercent.rounded()))% used"
    }

    static func resetText(for window: UsageWindow) -> String {
        guard let resetsAt = window.resetsAt else { return "--:--" }
        return resetClockFormatter.string(from: resetsAt)
    }

    static func primaryUsagePercent(for profile: LaunchProfile) -> Double? {
        profile.usage?.primaryPercentUsed
    }

    static func bestUsagePercent(in profiles: [LaunchProfile]) -> Double? {
        profiles
            .filter { !isFreePlan($0.usage?.accountPlan ?? $0.accountPlan) }
            .compactMap(primaryUsagePercent(for:))
            .max()
    }

    static func isFreePlan(_ plan: String?) -> Bool {
        plan?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "free"
    }

    static func providerSymbol(for provider: Provider) -> String {
        switch provider {
        case .claude: return "sparkles"
        case .codex: return "terminal"
        }
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    private static let resetClockFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        formatter.timeZone = .current
        return formatter
    }()
}

enum MenuBarIcon {
    static func make(usagePercent: Double?, isRefreshing: Bool) -> NSImage {
        let size = NSSize(width: 24, height: 18)
        let image = NSImage(size: size)
        image.lockFocus()
        defer { image.unlockFocus() }

        let accent = isRefreshing ? NSColor.systemBlue : color(for: usagePercent)
        let stroke = NSColor.labelColor.withAlphaComponent(0.72)
        let softAccent = accent.withAlphaComponent(0.22)
        let center = NSPoint(x: 12, y: 9)
        let nodes = [
            NSPoint(x: 5, y: 5),
            NSPoint(x: 5, y: 13),
            NSPoint(x: 12, y: 15),
            NSPoint(x: 19, y: 12),
            NSPoint(x: 18, y: 5),
            center
        ]

        let glow = NSBezierPath(ovalIn: NSRect(x: 6, y: 3, width: 12, height: 12))
        softAccent.setFill()
        glow.fill()

        stroke.setStroke()
        let links = NSBezierPath()
        links.lineWidth = 1.25
        links.move(to: nodes[0])
        links.line(to: center)
        links.line(to: nodes[2])
        links.move(to: nodes[1])
        links.line(to: center)
        links.line(to: nodes[3])
        links.move(to: nodes[4])
        links.line(to: center)
        links.stroke()

        NSColor.labelColor.withAlphaComponent(0.20).setStroke()
        let ringRect = NSRect(x: center.x - 5.2, y: center.y - 5.2, width: 10.4, height: 10.4)
        let ring = NSBezierPath(ovalIn: ringRect)
        ring.lineWidth = 1.3
        ring.stroke()

        if let usagePercent {
            let remaining = max(0, min(1, (100 - usagePercent) / 100))
            accent.setStroke()
            let arc = NSBezierPath()
            arc.lineWidth = 1.8
            arc.appendArc(
                withCenter: center,
                radius: 5.2,
                startAngle: 90,
                endAngle: 90 - CGFloat(360 * remaining),
                clockwise: true)
            arc.stroke()
        }

        for node in nodes.dropLast() {
            NSColor.labelColor.withAlphaComponent(0.82).setFill()
            NSBezierPath(ovalIn: NSRect(x: node.x - 1.35, y: node.y - 1.35, width: 2.7, height: 2.7)).fill()
        }

        accent.setFill()
        NSBezierPath(ovalIn: NSRect(x: center.x - 2.35, y: center.y - 2.35, width: 4.7, height: 4.7)).fill()

        image.isTemplate = false
        return image
    }

    private static func color(for usagePercent: Double?) -> NSColor {
        guard let usagePercent else { return .systemTeal }
        if usagePercent >= 90 { return .systemRed }
        if usagePercent >= 70 { return .systemOrange }
        return .systemGreen
    }
}

final class UsageBarView: NSView {
    var usedPercent: Double? {
        didSet { needsDisplay = true }
    }
    var accentColor: NSColor = .systemGreen {
        didSet { needsDisplay = true }
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: 124, height: 6)
    }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 0, dy: 1)
        NSColor.separatorColor.withAlphaComponent(0.5).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3).fill()

        guard let usedPercent else { return }
        let percent = max(0, min(1, usedPercent / 100))
        let fillWidth = rect.width * CGFloat(percent)
        let fillRect = NSRect(x: rect.minX, y: rect.minY, width: fillWidth, height: rect.height)
        accentColor.setFill()
        NSBezierPath(roundedRect: fillRect, xRadius: 3, yRadius: 3).fill()
    }
}

final class StatusDotView: NSView {
    var isRunning = false {
        didSet { needsDisplay = true }
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: 8, height: 8)
    }

    override func draw(_ dirtyRect: NSRect) {
        let color = isRunning ? NSColor.systemGreen : NSColor.tertiaryLabelColor.withAlphaComponent(0.5)
        color.setFill()
        NSBezierPath(ovalIn: bounds.insetBy(dx: 1, dy: 1)).fill()
    }
}

final class QuotaWindowView: NSView {
    init(window: UsageWindow) {
        super.init(frame: NSRect(x: 0, y: 0, width: 300, height: 30))
        translatesAutoresizingMaskIntoConstraints = false

        let title = NSTextField(labelWithString: ProfileFormatting.windowTitle(window.title))
        title.translatesAutoresizingMaskIntoConstraints = false
        title.font = .systemFont(ofSize: 11.5, weight: .semibold)
        title.textColor = .labelColor

        let used = NSTextField(labelWithString: ProfileFormatting.usedText(for: window))
        used.translatesAutoresizingMaskIntoConstraints = false
        used.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        used.textColor = .secondaryLabelColor

        let reset = NSTextField(labelWithString: ProfileFormatting.resetText(for: window))
        reset.translatesAutoresizingMaskIntoConstraints = false
        reset.font = .monospacedDigitSystemFont(ofSize: 10.5, weight: .medium)
        reset.textColor = .secondaryLabelColor
        reset.alignment = .right

        let bar = UsageBarView()
        bar.translatesAutoresizingMaskIntoConstraints = false
        bar.usedPercent = window.usedPercent
        bar.accentColor = Self.color(for: window.usedPercent)

        addSubview(title)
        addSubview(used)
        addSubview(bar)
        addSubview(reset)

        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: leadingAnchor),
            title.topAnchor.constraint(equalTo: topAnchor),
            title.trailingAnchor.constraint(lessThanOrEqualTo: used.leadingAnchor, constant: -8),

            used.trailingAnchor.constraint(equalTo: trailingAnchor),
            used.firstBaselineAnchor.constraint(equalTo: title.firstBaselineAnchor),

            bar.leadingAnchor.constraint(equalTo: leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: reset.leadingAnchor, constant: -10),
            bar.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 5),
            bar.heightAnchor.constraint(equalToConstant: 6),

            reset.trailingAnchor.constraint(equalTo: trailingAnchor),
            reset.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            reset.widthAnchor.constraint(equalToConstant: 42),
            bar.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor)
        ])
    }

    private static func color(for usedPercent: Double) -> NSColor {
        if usedPercent >= 90 { return .systemRed }
        if usedPercent >= 70 { return .systemOrange }
        return .systemGreen
    }

    required init?(coder: NSCoder) {
        nil
    }
}

final class ProfileMenuItemView: NSView {
    private let profileID: String
    private weak var actionTarget: AnyObject?
    private let action: Selector
    private var trackingArea: NSTrackingArea?
    private var isHovering = false {
        didSet { needsDisplay = true }
    }

    init(profile: LaunchProfile, target: AnyObject, action: Selector, isRefreshing: Bool, isRunning: Bool) {
        self.profileID = profile.id
        self.actionTarget = target
        self.action = action
        let windowCount = max(1, min(2, profile.usage?.windows.count ?? 0))
        super.init(frame: NSRect(x: 0, y: 0, width: 408, height: CGFloat(58 + windowCount * 35)))
        identifier = NSUserInterfaceItemIdentifier(profileID)
        wantsLayer = true

        let appIcon = NSWorkspace.shared.icon(forFile: Launcher.expanding(profile.appPath))
        appIcon.size = NSSize(width: 28, height: 28)
        let icon = NSImageView(image: appIcon)
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.imageScaling = .scaleProportionallyUpOrDown

        let title = NSTextField(labelWithString: ProfileFormatting.title(for: profile))
        title.translatesAutoresizingMaskIntoConstraints = false
        title.font = .systemFont(ofSize: 13.5, weight: .semibold)
        title.lineBreakMode = .byTruncatingMiddle

        let subtitle = NSTextField(labelWithString: ProfileFormatting.subtitle(for: profile))
        subtitle.translatesAutoresizingMaskIntoConstraints = false
        subtitle.font = .systemFont(ofSize: 11.5, weight: .medium)
        subtitle.textColor = .secondaryLabelColor
        subtitle.lineBreakMode = .byTruncatingTail

        let dot = StatusDotView()
        dot.translatesAutoresizingMaskIntoConstraints = false
        dot.isRunning = isRunning

        let running = NSTextField(labelWithString: isRunning ? "Open" : "Closed")
        running.translatesAutoresizingMaskIntoConstraints = false
        running.font = .systemFont(ofSize: 10.5, weight: .medium)
        running.textColor = isRunning ? .systemGreen : .tertiaryLabelColor

        let statusStack = NSStackView(views: [dot, running])
        statusStack.translatesAutoresizingMaskIntoConstraints = false
        statusStack.orientation = .horizontal
        statusStack.spacing = 5
        statusStack.alignment = .centerY

        let quotaViews: [NSView]
        if let windows = profile.usage?.windows, !windows.isEmpty {
            quotaViews = windows.prefix(2).map { QuotaWindowView(window: $0) }
        } else {
            let label = NSTextField(labelWithString: ProfileFormatting.usageLines(for: profile, isRefreshing: isRefreshing).first ?? "Usage unavailable")
            label.translatesAutoresizingMaskIntoConstraints = false
            label.font = .systemFont(ofSize: 11, weight: .medium)
            label.textColor = .secondaryLabelColor
            quotaViews = [label]
        }

        let quotaStack = NSStackView(views: quotaViews)
        quotaStack.translatesAutoresizingMaskIntoConstraints = false
        quotaStack.orientation = .vertical
        quotaStack.spacing = 5
        quotaStack.alignment = .leading

        addSubview(icon)
        addSubview(title)
        addSubview(subtitle)
        addSubview(statusStack)
        addSubview(quotaStack)

        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            icon.topAnchor.constraint(equalTo: topAnchor, constant: 14),
            icon.widthAnchor.constraint(equalToConstant: 28),
            icon.heightAnchor.constraint(equalToConstant: 28),

            statusStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            statusStack.topAnchor.constraint(equalTo: topAnchor, constant: 16),

            title.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 12),
            title.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            title.trailingAnchor.constraint(equalTo: statusStack.leadingAnchor, constant: -10),

            subtitle.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            subtitle.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 2),
            subtitle.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),

            quotaStack.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            quotaStack.topAnchor.constraint(equalTo: subtitle.bottomAnchor, constant: 8),
            quotaStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            quotaStack.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -10)
        ])
    }

    override func updateTrackingAreas() {
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) {
        isHovering = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovering = false
    }

    override func mouseDown(with event: NSEvent) {
        performOpen(self)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard isHovering else { return }
        NSColor.controlAccentColor.withAlphaComponent(0.12).setFill()
        let rect = bounds.insetBy(dx: 8, dy: 5)
        NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8).fill()
    }

    @objc private func performOpen(_ sender: Any?) {
        _ = (actionTarget as? NSObject)?.perform(action, with: self)
    }

    required init?(coder: NSCoder) {
        nil
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var config = ConfigStore.shared.loadCached()
    private var settingsWindow: SettingsWindowController?
    private var refreshTimer: Timer?
    private var refreshInFlight = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        updateStatusIcon()
        rebuildMenu()
        refreshAllAsync()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 120, repeats: true) { [weak self] _ in
            self?.refreshAllAsync()
        }
    }

    private func rebuildMenu() {
        let menu = NSMenu()
        menu.autoenablesItems = false

        if config.profiles.isEmpty {
            let empty = NSMenuItem(title: refreshInFlight ? "Finding Claude and Codex accounts..." : "No Claude/Codex accounts found", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        } else {
            let runningIDs = RunningProfileDetector.runningProfileIDs(config.profiles)
            for profile in config.profiles {
                let item = NSMenuItem()
                item.view = ProfileMenuItemView(
                    profile: profile,
                    target: self,
                    action: #selector(openProfileButton(_:)),
                    isRefreshing: refreshInFlight,
                    isRunning: runningIDs.contains(profile.id))
                menu.addItem(item)
            }
        }

        menu.addItem(NSMenuItem.separator())

        let settings = NSMenuItem(title: "Settings...", action: #selector(showSettings), keyEquivalent: ",")
        settings.target = self
        settings.isEnabled = true
        menu.addItem(settings)

        let refresh = NSMenuItem(title: refreshInFlight ? "Refreshing..." : "Refresh", action: #selector(refresh), keyEquivalent: "r")
        refresh.target = self
        refresh.isEnabled = !refreshInFlight
        menu.addItem(refresh)

        menu.addItem(NSMenuItem.separator())
        let quit = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        quit.isEnabled = true
        menu.addItem(quit)

        statusItem.menu = menu
    }

    private func updateStatusIcon() {
        guard let button = statusItem?.button else { return }
        button.title = ""
        button.imagePosition = .imageOnly
        button.image = MenuBarIcon.make(
            usagePercent: ProfileFormatting.bestUsagePercent(in: config.profiles),
            isRefreshing: refreshInFlight)
        button.toolTip = "LLM Usage Bar"
    }

    @objc private func openProfileButton(_ sender: Any) {
        statusItem.menu?.cancelTracking()
        let id: String?
        if let view = sender as? NSView {
            id = view.identifier?.rawValue
        } else if let button = sender as? NSButton {
            id = button.identifier?.rawValue
        } else {
            id = nil
        }
        guard let id else { return }
        openProfile(id: id)
    }

    private func openProfile(id: String) {
        guard let profile = config.profiles.first(where: { $0.id == id }) else { return }
        do {
            try Launcher.launch(profile)
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
                self?.refreshAllAsync()
            }
        } catch {
            showError("Could not launch \(profile.label): \(error.localizedDescription)")
        }
    }

    @objc private func showSettings() {
        settingsWindow = SettingsWindowController(config: config) { [weak self] newConfig in
            guard let self else { return }
            self.config = newConfig
            ConfigStore.shared.save(newConfig)
            self.updateStatusIcon()
            self.rebuildMenu()
            self.refreshAllAsync()
        }
        settingsWindow?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func refresh() {
        refreshAllAsync()
    }

    private func refreshAllAsync() {
        guard !refreshInFlight else { return }
        refreshInFlight = true
        updateStatusIcon()
        rebuildMenu()

        DispatchQueue.global(qos: .utility).async { [weak self] in
            let loaded = ConfigStore.shared.load()
            let refreshed = UsageRefresher.refresh(loaded)
            ConfigStore.shared.save(refreshed)

            DispatchQueue.main.async {
                guard let self else { return }
                self.config = refreshed
                self.refreshInFlight = false
                self.settingsWindow?.refreshFromDiskPreservingSelection()
                self.updateStatusIcon()
                self.rebuildMenu()
            }
        }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private func showError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "LLM Usage Bar"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.runModal()
    }
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

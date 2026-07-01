import AppKit
import Foundation

enum Provider: String, Codable, CaseIterable {
    case claude = "Claude"
    case codex = "Codex"
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
            createdAt: Date()
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
            quotaSummary: "Waiting for login",
            quotaSource: nil,
            billingType: nil,
            accountUUID: nil,
            isUserAdded: true,
            isPendingLogin: true,
            createdAt: Date()
        )
    }

    mutating func apply(identity: AccountIdentity) {
        let account = identity.displayName ?? identity.email ?? "Signed-in account"
        label = "\(provider.rawValue) - \(account)"
        accountName = identity.displayName
        accountEmail = identity.email
        signedIn = identity.isSignedIn
        accountPlan = identity.planName
        quotaSummary = identity.quotaSummary
        quotaSource = identity.quotaSource
        billingType = identity.billingType
        accountUUID = identity.accountUUID
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

        if fm.fileExists(atPath: codexApp) {
            [
                "\(support)/Codex",
                "\(support)/com.openai.codex"
            ]
            .forEach { candidate in
                if fm.fileExists(atPath: candidate) {
                    candidates.append((.codex, codexApp, candidate, false))
                }
            }
        }

        candidates.append(contentsOf: generatedProfileCandidates())
        candidates.append(contentsOf: existingProfiles.map { profile in
            (profile.provider, profile.appPath, profile.dataDir, profile.isUserAdded == true)
        })

        for candidate in candidates {
            let key = profileKey(provider: candidate.provider, dataDir: candidate.dataDir)
            var profile = existingByKey[key]
            let identity = AccountResolver.identity(in: candidate.dataDir, provider: candidate.provider)

            if var existingProfile = profile {
                existingProfile.appPath = candidate.appPath
                if let identity {
                    existingProfile.apply(identity: identity)
                }
                if candidate.userAdded {
                    existingProfile.isUserAdded = true
                }
                if identity != nil || existingProfile.isUserAdded == true {
                    resultsByKey[key] = existingProfile
                }
                continue
            }

            if let identity {
                profile = .make(provider: candidate.provider, appPath: candidate.appPath, dataDir: candidate.dataDir, identity: identity, isUserAdded: candidate.userAdded)
                resultsByKey[key] = profile
            }
        }

        return resultsByKey.values.sorted { lhs, rhs in
            if lhs.provider.rawValue != rhs.provider.rawValue {
                return lhs.provider.rawValue < rhs.provider.rawValue
            }
            return lhs.label.localizedCaseInsensitiveCompare(rhs.label) == .orderedAscending
        }
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
}

enum AccountResolver {
    static func identity(in dataDir: String, provider: Provider) -> AccountIdentity? {
        let root = URL(fileURLWithPath: Launcher.expanding(dataDir))
        let files = relevantFiles(under: root)
        var emails: [String] = []
        var names: [String] = []
        var billingTypes: [String] = []
        var accountUUIDs: [String] = []
        var quotaSignals: [String] = []
        var signedIn = false

        for file in files {
            guard let text = readableText(from: file) else { continue }
            emails.append(contentsOf: extractEmails(from: text))
            names.append(contentsOf: extractNamedValues(from: text))
            billingTypes.append(contentsOf: captureMatches(pattern: #""billing_type"\s*:\s*"([^"]+)""#, in: text))
            accountUUIDs.append(contentsOf: captureMatches(pattern: #""account_uuid"\s*:\s*"([^"]+)""#, in: text))
            quotaSignals.append(contentsOf: quotaSignalsFrom(text: text, provider: provider))
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
        let planName = planName(provider: provider, billingType: billingType, quotaSignals: quotaSignals)
        let quotaSummary = quotaSummary(provider: provider, quotaSignals: quotaSignals)
        let quotaSource = quotaSummary == nil ? nil : "local app cache"

        if email != nil || displayName != nil {
            return AccountIdentity(
                displayName: displayName,
                email: email,
                isSignedIn: true,
                planName: planName,
                quotaSummary: quotaSummary,
                quotaSource: quotaSource,
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
                quotaSummary: quotaSummary,
                quotaSource: quotaSource,
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
            "Default/Account Web Data",
            "Default/Login Data For Account",
            "Default/Partitions/codex-browser-app/Preferences",
            "Default/Partitions/codex-browser-app/Secure Preferences",
            "Default/Partitions/codex-browser-app/Account Web Data",
            "Default/Partitions/codex-browser-app/Login Data For Account"
        ]

        for name in directNames {
            let file = root.appendingPathComponent(name)
            if fm.fileExists(atPath: file.path) {
                files.append(file)
            }
        }

        let relativeDirs = [
            "Local Storage/leveldb",
            "Session Storage",
            "Default/Local Storage/leveldb",
            "Default/Session Storage",
            "Default/Partitions/codex-browser-app/Local Storage/leveldb",
            "Default/Partitions/codex-browser-app/Session Storage"
        ]

        for relativeDir in relativeDirs {
            let dir = root.appendingPathComponent(relativeDir)
            guard let enumerator = fm.enumerator(
                at: dir,
                includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
                options: [.skipsHiddenFiles]
            ) else {
                continue
            }

            for case let file as URL in enumerator {
                guard isRelevantFile(file) else { continue }
                files.append(file)
            }
        }

        return Array(Set(files)).sorted { $0.path < $1.path }
    }

    private static func isRelevantFile(_ file: URL) -> Bool {
        let name = file.lastPathComponent
        let allowedNames = [
            "Preferences",
            "Secure Preferences",
            "Local State",
            "Account Web Data",
            "Login Data For Account"
        ]
        if allowedNames.contains(name) { return true }
        return name.hasSuffix(".ldb") || name.hasSuffix(".log")
    }

    private static func readableText(from file: URL) -> String? {
        guard let values = try? file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
              values.isRegularFile == true,
              (values.fileSize ?? 0) <= 8_000_000,
              let data = try? Data(contentsOf: file) else {
            return nil
        }

        if let text = String(data: data, encoding: .utf8) {
            return normalizeStorageText(text)
        }

        let bytes = data.map { byte -> UInt8 in
            if byte == 9 || byte == 10 || byte == 13 || (byte >= 32 && byte <= 126) {
                return byte
            }
            return 32
        }
        return String(bytes: bytes, encoding: .utf8).map(normalizeStorageText)
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
            guard let domain = email.split(separator: "@").last else { return false }
            if blockedDomains.contains(String(domain)) { return false }
            if email.contains("opengraph-image") { return false }
            return true
        }

        if provider == .claude {
            return filtered.first
        }
        return filtered.first { email in
            email.contains("openai") || email.contains("gmail") || email.contains("icloud") || email.contains("francois") || email.contains("francis")
        } ?? filtered.first
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

    private static func planName(provider: Provider, billingType: String?, quotaSignals: [String]) -> String? {
        if let explicitPlan = quotaSignals.first(where: { signal in
            let lower = signal.lowercased()
            return lower.contains("pro") || lower.contains("max") || lower.contains("team") || lower.contains("plus")
        }) {
            return explicitPlan
        }

        switch provider {
        case .claude:
            if billingType == "stripe_subscription" {
                return "Paid subscription"
            }
        case .codex:
            if quotaSignals.contains(where: { $0.lowercased().contains("workspace_credits") || $0.lowercased().contains("rate_limit") }) {
                return "Signed-in subscription"
            }
        }

        return nil
    }

    private static func quotaSummary(provider: Provider, quotaSignals: [String]) -> String? {
        switch provider {
        case .claude:
            if quotaSignals.contains(where: { $0.lowercased().contains("billing_type") }) {
                return "subscription detected; remaining window not cached"
            }
        case .codex:
            let lower = quotaSignals.map { $0.lowercased() }
            if lower.contains(where: { $0.contains("rate_limit_reset") }) {
                return "rate-limit metadata cached; exact remaining quota not cached"
            }
            if lower.contains(where: { $0.contains("workspace_credits") }) {
                return "workspace credit metadata cached"
            }
        }
        return nil
    }

    private static func quotaSignalsFrom(text: String, provider: Provider) -> [String] {
        var signals: [String] = []
        let patterns = [
            #""billing_type"\s*:\s*"([^"]+)""#,
            #""(?:membership|plan|subscription|rate_limit_reset|workspace_credits|remaining_threshold_percent|free_plan_upgrade_cta|go_usage_setting|codex_turn[^"]*)"\s*:?\s*"?([^",}\]]{1,120})"?"#
        ]

        for pattern in patterns {
            signals.append(contentsOf: captureMatches(pattern: pattern, in: text))
        }

        if provider == .codex {
            for token in ["rate_limit_reset", "workspace_credits", "free_plan_upgrade_cta", "go_usage_setting"] where text.contains(token) {
                signals.append(token)
            }
        }

        return Array(Set(signals))
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
        let infoURL = appURL.appendingPathComponent("Contents/Info.plist")
        let info = NSDictionary(contentsOf: infoURL)
        let executableName = info?["CFBundleExecutable"] as? String ?? appURL.deletingPathExtension().lastPathComponent
        let executableURL = appURL.appendingPathComponent("Contents/MacOS/\(executableName)")
        let dataDir = expanding(profile.dataDir)

        try fm.createDirectory(atPath: dataDir, withIntermediateDirectories: true)

        let process = Process()
        process.executableURL = executableURL
        process.arguments = ["--user-data-dir=\(dataDir)"]
        process.environment = ProcessInfo.processInfo.environment
        try process.run()
    }

    static func expanding(_ path: String) -> String {
        NSString(string: path).expandingTildeInPath
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

        let addButton = NSButton(title: "Add Account...", target: self, action: #selector(addAccount))
        let removeButton = NSButton(title: "Remove", target: self, action: #selector(removeProfile))
        let inferButton = NSButton(title: "Infer Connected Accounts", target: self, action: #selector(inferExisting))
        let saveButton = NSButton(title: "Save", target: self, action: #selector(save))
        saveButton.keyEquivalent = "\r"

        let buttons = NSStackView(views: [addButton, removeButton, inferButton, saveButton])
        buttons.translatesAutoresizingMaskIntoConstraints = false
        buttons.orientation = .horizontal
        buttons.spacing = 8
        form.addArrangedSubview(buttons)

        content.addSubview(scroll)
        content.addSubview(form)

        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            scroll.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            scroll.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
            scroll.widthAnchor.constraint(equalToConstant: 230),

            form.leadingAnchor.constraint(equalTo: scroll.trailingAnchor, constant: 18),
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
            parts.append("Plan: \(plan)")
        }

        if let quota = profile.quotaSummary {
            parts.append("Quota: \(quota)")
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

        var profile = ConfigStore.shared.createPendingProfile(provider: provider)
        config.profiles.append(profile)
        onSave(config)
        table.reloadData()
        table.selectRowIndexes(IndexSet(integer: config.profiles.count - 1), byExtendingSelection: false)

        do {
            try Launcher.launch(profile)
            statusLabel.stringValue = "Opened \(provider.rawValue). Sign in there; this list will update automatically."
        } catch {
            profile.quotaSummary = "Could not open login window: \(error.localizedDescription)"
            config.profiles[config.profiles.count - 1] = profile
            onSave(config)
            table.reloadData()
            statusLabel.stringValue = profile.quotaSummary ?? "Could not open login window."
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

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var config = ConfigStore.shared.load()
    private var settingsWindow: SettingsWindowController?
    private var refreshTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "LLM"
        rebuildMenu()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    private func rebuildMenu() {
        let menu = NSMenu()

        let title = NSMenuItem(title: "Connected LLM Accounts", action: nil, keyEquivalent: "")
        title.isEnabled = false
        menu.addItem(title)

        if config.profiles.isEmpty {
            let empty = NSMenuItem(title: "No connected Claude/Codex accounts inferred", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        } else {
            for profile in config.profiles {
                let item = NSMenuItem(title: accountSummary(for: profile), action: nil, keyEquivalent: "")
                item.isEnabled = false
                menu.addItem(item)
            }
        }

        menu.addItem(NSMenuItem.separator())

        for profile in config.profiles {
            let item = NSMenuItem(title: "Open \(profile.label)", action: #selector(openProfile(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = profile.id
            menu.addItem(item)
        }

        menu.addItem(NSMenuItem.separator())
        let addClaude = NSMenuItem(title: "Add Claude Account...", action: #selector(addClaudeAccount), keyEquivalent: "")
        addClaude.target = self
        menu.addItem(addClaude)

        let addCodex = NSMenuItem(title: "Add Codex Account...", action: #selector(addCodexAccount), keyEquivalent: "")
        addCodex.target = self
        menu.addItem(addCodex)

        menu.addItem(NSMenuItem.separator())
        let settings = NSMenuItem(title: "Settings...", action: #selector(showSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)

        let refresh = NSMenuItem(title: "Refresh", action: #selector(refresh), keyEquivalent: "r")
        refresh.target = self
        menu.addItem(refresh)

        menu.addItem(NSMenuItem.separator())
        let quit = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        statusItem.menu = menu
    }

    private func accountSummary(for profile: LaunchProfile) -> String {
        var base: String
        if let email = profile.accountEmail, let name = profile.accountName {
            base = "\(profile.provider.rawValue): \(name) <\(email)>"
        } else if let email = profile.accountEmail {
            base = "\(profile.provider.rawValue): \(email)"
        } else if let name = profile.accountName {
            base = "\(profile.provider.rawValue): \(name)"
        } else if profile.isPendingLogin == true {
            return "\(profile.provider.rawValue): waiting for login"
        } else {
            base = "\(profile.provider.rawValue): signed-in account"
        }

        var details: [String] = []
        if let plan = profile.accountPlan {
            details.append(plan)
        }
        if let quota = profile.quotaSummary {
            details.append(quota)
        }
        return details.isEmpty ? base : "\(base) - \(details.joined(separator: " - "))"
    }

    @objc private func openProfile(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              let profile = config.profiles.first(where: { $0.id == id }) else {
            return
        }
        do {
            try Launcher.launch(profile)
            rebuildMenu()
        } catch {
            showError("Could not launch \(profile.label): \(error.localizedDescription)")
        }
    }

    @objc private func showSettings() {
        settingsWindow = SettingsWindowController(config: config) { [weak self] newConfig in
            self?.config = newConfig
            ConfigStore.shared.save(newConfig)
            self?.rebuildMenu()
        }
        settingsWindow?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func refresh() {
        config = ConfigStore.shared.load()
        settingsWindow?.refreshFromDiskPreservingSelection()
        rebuildMenu()
    }

    @objc private func addClaudeAccount() {
        addAccount(provider: .claude)
    }

    @objc private func addCodexAccount() {
        addAccount(provider: .codex)
    }

    private func addAccount(provider: Provider) {
        var newConfig = ConfigStore.shared.load()
        let profile = ConfigStore.shared.createPendingProfile(provider: provider)
        newConfig.profiles.append(profile)
        config = newConfig
        ConfigStore.shared.save(newConfig)
        rebuildMenu()
        do {
            try Launcher.launch(profile)
        } catch {
            showError("Could not open \(provider.rawValue) login window: \(error.localizedDescription)")
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

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()

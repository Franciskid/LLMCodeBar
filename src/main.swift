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

    static func make(provider: Provider, appPath: String, dataDir: String, identity: AccountIdentity) -> LaunchProfile {
        let account = identity.displayName ?? identity.email ?? "Signed-in account"
        return LaunchProfile(
            id: UUID().uuidString,
            label: "\(provider.rawValue) - \(account)",
            provider: provider,
            appPath: appPath,
            dataDir: dataDir,
            accountName: identity.displayName,
            accountEmail: identity.email,
            signedIn: identity.isSignedIn
        )
    }
}

struct AccountIdentity {
    var displayName: String?
    var email: String?
    var isSignedIn: Bool

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
    let launchAgentURL: URL

    private init() {
        let fm = FileManager.default
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        appSupport = support.appendingPathComponent("LLM Usage Bar", isDirectory: true)
        configURL = appSupport.appendingPathComponent("config.json")
        launchAgentURL = fm.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/fr.fraserv.llmusagebar.plist")
    }

    func ensureSupportDirectory() {
        try? FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
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
            let config = AppConfig(launchAtLogin: false, profiles: inferProfiles())
            save(config)
            return config
        }

        var config = AppConfig(launchAtLogin: existing.launchAtLogin, profiles: inferProfiles())
        let previousByPath = Dictionary(uniqueKeysWithValues: existing.profiles.map { ("\($0.provider.rawValue)|\($0.dataDir)", $0) })
        for index in config.profiles.indices {
            let key = "\(config.profiles[index].provider.rawValue)|\(config.profiles[index].dataDir)"
            if let previous = previousByPath[key] {
                config.profiles[index].id = previous.id
            }
        }
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

    func inferProfiles() -> [LaunchProfile] {
        var results: [LaunchProfile] = []
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path
        let support = "\(home)/Library/Application Support"

        let claudeApp = "/Applications/Claude.app"
        let codexApp = "/Applications/Codex.app"

        if fm.fileExists(atPath: claudeApp) {
            let base = "\(support)/Claude"
            if let identity = AccountResolver.identity(in: base, provider: .claude) {
                results.append(.make(provider: .claude, appPath: claudeApp, dataDir: base, identity: identity))
            }
            if let dirs = try? fm.contentsOfDirectory(atPath: support) {
                for dir in dirs.sorted() where dir.hasPrefix("Claude-") {
                    let path = "\(support)/\(dir)"
                    var isDir: ObjCBool = false
                    if fm.fileExists(atPath: path, isDirectory: &isDir),
                       isDir.boolValue,
                       let identity = AccountResolver.identity(in: path, provider: .claude) {
                        results.append(.make(provider: .claude, appPath: claudeApp, dataDir: path, identity: identity))
                    }
                }
            }
        }

        if fm.fileExists(atPath: codexApp) {
            let candidates = [
                "\(support)/Codex",
                "\(support)/com.openai.codex"
            ]
            for candidate in candidates where fm.fileExists(atPath: candidate) {
                if let identity = AccountResolver.identity(in: candidate, provider: .codex) {
                    results.append(.make(provider: .codex, appPath: codexApp, dataDir: candidate, identity: identity))
                }
            }
        }

        return deduplicate(results)
    }

    private func deduplicate(_ profiles: [LaunchProfile]) -> [LaunchProfile] {
        var seen = Set<String>()
        var output: [LaunchProfile] = []
        for profile in profiles {
            let key = "\(profile.provider.rawValue)|\(profile.dataDir)"
            if !seen.contains(key) {
                seen.insert(key)
                output.append(profile)
            }
        }
        return output
    }
}

enum AccountResolver {
    static func identity(in dataDir: String, provider: Provider) -> AccountIdentity? {
        let root = URL(fileURLWithPath: Launcher.expanding(dataDir))
        let files = relevantFiles(under: root)
        var emails: [String] = []
        var names: [String] = []
        var signedIn = false

        for file in files {
            guard let text = readableText(from: file) else { continue }
            emails.append(contentsOf: extractEmails(from: text))
            names.append(contentsOf: extractNamedValues(from: text))
            if text.contains("\"account_id\"") ||
                text.contains("\"last_signed_in_username\"") ||
                text.contains("sessionKey") ||
                text.contains("lastSignedIn") {
                signedIn = true
            }
        }

        let email = preferredEmail(from: emails, provider: provider)
        let name = preferredName(from: names, excluding: email, provider: provider)
        let displayName = (email == nil || (name?.contains(" ") == true)) ? name : nil

        if email != nil || displayName != nil {
            return AccountIdentity(displayName: displayName, email: email, isSignedIn: true)
        }

        if provider == .codex && signedIn {
            return AccountIdentity(displayName: nil, email: nil, isSignedIn: true)
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
            "buddy-tokens.json"
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
            "Default",
            "Default/Local Storage/leveldb",
            "Default/Session Storage",
            "Default/Partitions/codex-browser-app",
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
            return text
        }

        let bytes = data.map { byte -> UInt8 in
            if byte == 9 || byte == 10 || byte == 13 || (byte >= 32 && byte <= 126) {
                return byte
            }
            return 32
        }
        return String(bytes: bytes, encoding: .utf8)
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
            #""(?:displayName|display_name|fullName|full_name|name|email|userEmail|user_email)"\s*:\s*"([^"]{3,120})""#,
            #"(?:displayName|display_name|fullName|full_name|name|email|userEmail|user_email)\\?":\\?"([^"\\]{3,120})\\?""#
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

        let removeButton = NSButton(title: "Remove", target: self, action: #selector(removeProfile))
        let inferButton = NSButton(title: "Infer Connected Accounts", target: self, action: #selector(inferExisting))
        let saveButton = NSButton(title: "Save", target: self, action: #selector(save))
        saveButton.keyEquivalent = "\r"

        let buttons = NSStackView(views: [removeButton, inferButton, saveButton])
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
        statusLabel.stringValue = profile.accountEmail ?? profile.accountName ?? "Signed-in account detected; exact account name is not exposed locally."
    }

    private func writeSelection() {
        let row = table.selectedRow
        guard row >= 0, row < config.profiles.count else { return }
        config.profiles[row].label = labelField.stringValue
        config.profiles[row].provider = Provider(rawValue: providerPopup.titleOfSelectedItem ?? "Claude") ?? .claude
        config.profiles[row].appPath = appPathField.stringValue
        config.profiles[row].dataDir = dataDirField.stringValue
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
        let inferred = ConfigStore.shared.inferProfiles()
        config.profiles = inferred
        table.reloadData()
        if !config.profiles.isEmpty {
            table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }
        statusLabel.stringValue = "Inferred \(inferred.count) connected account(s)."
    }

    @objc private func save() {
        writeSelection()
        config.launchAtLogin = launchAtLogin.state == .on
        onSave(config)
        statusLabel.stringValue = "Saved."
        table.reloadData()
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
            self?.rebuildMenu()
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
        let note = NSMenuItem(title: "Subscription quota: unavailable until real provider adapter is connected", action: nil, keyEquivalent: "")
        note.isEnabled = false
        menu.addItem(note)

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
        if let email = profile.accountEmail, let name = profile.accountName {
            return "\(profile.provider.rawValue): \(name) <\(email)>"
        }
        if let email = profile.accountEmail {
            return "\(profile.provider.rawValue): \(email)"
        }
        if let name = profile.accountName {
            return "\(profile.provider.rawValue): \(name)"
        }
        return "\(profile.provider.rawValue): signed-in account"
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
        rebuildMenu()
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

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()

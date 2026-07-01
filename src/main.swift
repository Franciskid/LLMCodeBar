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
    var fiveHourBudget: Double
    var weeklyBudget: Double

    static func make(label: String, provider: Provider, appPath: String, dataDir: String) -> LaunchProfile {
        LaunchProfile(
            id: UUID().uuidString,
            label: label,
            provider: provider,
            appPath: appPath,
            dataDir: dataDir,
            fiveHourBudget: 100,
            weeklyBudget: 100
        )
    }
}

struct AppConfig: Codable {
    var launchAtLogin: Bool
    var profiles: [LaunchProfile]
}

struct UsageEvent: Codable, Identifiable {
    var id: String
    var profileId: String
    var provider: Provider
    var date: Date
    var units: Double
    var note: String
}

final class Paths {
    static let shared = Paths()

    let appSupport: URL
    let configURL: URL
    let eventsURL: URL
    let launchAgentURL: URL

    private init() {
        let fm = FileManager.default
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        appSupport = support.appendingPathComponent("LLM Usage Bar", isDirectory: true)
        configURL = appSupport.appendingPathComponent("config.json")
        eventsURL = appSupport.appendingPathComponent("usage_events.json")
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
              let config = try? decoder.decode(AppConfig.self, from: data) else {
            let config = AppConfig(launchAtLogin: false, profiles: inferProfiles())
            save(config)
            return config
        }
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
            if fm.fileExists(atPath: base) {
                results.append(.make(label: "Claude - Current", provider: .claude, appPath: claudeApp, dataDir: base))
            }
            if let dirs = try? fm.contentsOfDirectory(atPath: support) {
                for dir in dirs.sorted() where dir.hasPrefix("Claude-") {
                    let path = "\(support)/\(dir)"
                    var isDir: ObjCBool = false
                    if fm.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue {
                        results.append(.make(label: dir.replacingOccurrences(of: "-", with: " "), provider: .claude, appPath: claudeApp, dataDir: path))
                    }
                }
            }
        }

        if fm.fileExists(atPath: codexApp) {
            let candidates = [
                ("Codex - Current", "\(support)/Codex"),
                ("Codex - OpenAI", "\(support)/com.openai.codex")
            ]
            for candidate in candidates where fm.fileExists(atPath: candidate.1) {
                results.append(.make(label: candidate.0, provider: .codex, appPath: codexApp, dataDir: candidate.1))
            }
        }

        if results.isEmpty {
            results = [
                .make(label: "Claude - Personal", provider: .claude, appPath: claudeApp, dataDir: "\(support)/Claude-Personal"),
                .make(label: "Codex - Personal", provider: .codex, appPath: codexApp, dataDir: "\(support)/Codex-Personal")
            ]
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

final class UsageStore {
    static let shared = UsageStore()
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    private init() {
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
    }

    func events() -> [UsageEvent] {
        Paths.shared.ensureSupportDirectory()
        guard let data = try? Data(contentsOf: Paths.shared.eventsURL),
              let loaded = try? decoder.decode([UsageEvent].self, from: data) else {
            return []
        }
        return loaded
    }

    func add(profile: LaunchProfile, units: Double, note: String) {
        var all = events()
        all.append(UsageEvent(id: UUID().uuidString, profileId: profile.id, provider: profile.provider, date: Date(), units: units, note: note))
        save(all)
    }

    func usage(profile: LaunchProfile, interval: TimeInterval) -> Double {
        let cutoff = Date().addingTimeInterval(-interval)
        return events()
            .filter { $0.profileId == profile.id && $0.date >= cutoff }
            .reduce(0) { $0 + $1.units }
    }

    func prune() {
        let cutoff = Date().addingTimeInterval(-60 * 60 * 24 * 30)
        save(events().filter { $0.date >= cutoff })
    }

    private func save(_ events: [UsageEvent]) {
        Paths.shared.ensureSupportDirectory()
        if let data = try? encoder.encode(events) {
            try? data.write(to: Paths.shared.eventsURL, options: .atomic)
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
        UsageStore.shared.add(profile: profile, units: 1, note: "Launched \(profile.label)")
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
    private let fiveHourField = NSTextField()
    private let weeklyField = NSTextField()
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
        addRow(to: form, label: "5-hour budget units", control: fiveHourField)
        addRow(to: form, label: "Weekly budget units", control: weeklyField)
        form.addArrangedSubview(launchAtLogin)

        statusLabel.textColor = .secondaryLabelColor
        form.addArrangedSubview(statusLabel)

        let addButton = NSButton(title: "Add", target: self, action: #selector(addProfile))
        let removeButton = NSButton(title: "Remove", target: self, action: #selector(removeProfile))
        let inferButton = NSButton(title: "Infer Existing", target: self, action: #selector(inferExisting))
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
        fiveHourField.stringValue = String(format: "%.0f", profile.fiveHourBudget)
        weeklyField.stringValue = String(format: "%.0f", profile.weeklyBudget)
        statusLabel.stringValue = "Quota is a local estimate until a provider quota adapter is connected."
    }

    private func writeSelection() {
        let row = table.selectedRow
        guard row >= 0, row < config.profiles.count else { return }
        config.profiles[row].label = labelField.stringValue
        config.profiles[row].provider = Provider(rawValue: providerPopup.titleOfSelectedItem ?? "Claude") ?? .claude
        config.profiles[row].appPath = appPathField.stringValue
        config.profiles[row].dataDir = dataDirField.stringValue
        config.profiles[row].fiveHourBudget = max(1, Double(fiveHourField.stringValue) ?? 100)
        config.profiles[row].weeklyBudget = max(1, Double(weeklyField.stringValue) ?? 100)
    }

    @objc private func addProfile() {
        writeSelection()
        let support = FileManager.default.homeDirectoryForCurrentUser.path + "/Library/Application Support"
        config.profiles.append(.make(label: "Claude - New", provider: .claude, appPath: "/Applications/Claude.app", dataDir: "\(support)/Claude-New"))
        table.reloadData()
        table.selectRowIndexes(IndexSet(integer: config.profiles.count - 1), byExtendingSelection: false)
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
        var existing = Set(config.profiles.map { "\($0.provider.rawValue)|\($0.dataDir)" })
        for profile in inferred {
            let key = "\(profile.provider.rawValue)|\(profile.dataDir)"
            if !existing.contains(key) {
                existing.insert(key)
                config.profiles.append(profile)
            }
        }
        table.reloadData()
        statusLabel.stringValue = "Inferred \(inferred.count) existing profile candidates."
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
        UsageStore.shared.prune()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "LLM"
        rebuildMenu()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.rebuildMenu()
        }
    }

    private func rebuildMenu() {
        let menu = NSMenu()

        let title = NSMenuItem(title: "Subscription Windows", action: nil, keyEquivalent: "")
        title.isEnabled = false
        menu.addItem(title)

        if config.profiles.isEmpty {
            let empty = NSMenuItem(title: "No profiles configured", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        } else {
            for profile in config.profiles {
                let summary = usageSummary(for: profile)
                let item = NSMenuItem(title: "\(profile.label): \(summary)", action: nil, keyEquivalent: "")
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

        if !config.profiles.isEmpty {
            menu.addItem(NSMenuItem.separator())
            for profile in config.profiles {
                let item = NSMenuItem(title: "Mark +10% \(profile.label)", action: #selector(markUsage(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = profile.id
                menu.addItem(item)
            }
        }

        menu.addItem(NSMenuItem.separator())
        let note = NSMenuItem(title: "Usage shown is a local estimate", action: nil, keyEquivalent: "")
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

    private func usageSummary(for profile: LaunchProfile) -> String {
        let five = UsageStore.shared.usage(profile: profile, interval: 60 * 60 * 5)
        let week = UsageStore.shared.usage(profile: profile, interval: 60 * 60 * 24 * 7)
        return "5h \(percent(five, profile.fiveHourBudget)) / week \(percent(week, profile.weeklyBudget))"
    }

    private func percent(_ used: Double, _ budget: Double) -> String {
        let value = min(999, max(0, used / max(1, budget) * 100))
        return String(format: "%.0f%%", value)
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

    @objc private func markUsage(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              let profile = config.profiles.first(where: { $0.id == id }) else {
            return
        }
        UsageStore.shared.add(profile: profile, units: 10, note: "Manual usage marker")
        rebuildMenu()
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

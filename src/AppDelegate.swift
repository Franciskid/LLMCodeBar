import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var config = ConfigStore.shared.loadCached()
    private var settingsWindow: SettingsWindowController?
    private var refreshTimer: Timer?
    private var refreshInFlight = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        updateStatusIcon()
        rebuildMenu()
        refreshAllAsync()
        scheduleRefreshTimer()
    }

    private func scheduleRefreshTimer() {
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: config.refreshInterval, repeats: true) { [weak self] _ in
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
                    isRunning: runningIDs.contains(profile.id),
                    showSparklines: config.showsSparklines)
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
        let percent = ProfileFormatting.menuBarPercent(in: config.profiles, selectedID: config.menuBarProfileID)
        button.image = MenuBarIcon.make(usagePercent: percent, isRefreshing: refreshInFlight)

        if config.showsPercentInMenuBar, let percent {
            button.imagePosition = .imageLeading
            button.attributedTitle = NSAttributedString(
                string: " \(Int(percent.rounded()))%",
                attributes: [
                    .foregroundColor: MenuBarIcon.statusColor(for: percent),
                    .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold),
                ])
        } else {
            button.imagePosition = .imageOnly
            button.attributedTitle = NSAttributedString(string: "")
            button.title = ""
        }
        button.toolTip = "LLMCodeBar"
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
            self.scheduleRefreshTimer()
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
            UsageHistoryStore.shared.record(profiles: refreshed.profiles)
            SessionKickstarter.runIfNeeded(profiles: refreshed.profiles, allowKeychain: refreshed.allowsCookieKeychain)

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
        alert.messageText = "LLMCodeBar"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.runModal()
    }
}


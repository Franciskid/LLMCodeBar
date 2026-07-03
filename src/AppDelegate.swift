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
            let rows = config.profiles.map { profile in
                ProfileMenuItemView(
                    profile: profile,
                    target: self,
                    action: #selector(openProfileButton(_:)),
                    isRefreshing: refreshInFlight,
                    isRunning: runningIDs.contains(profile.id),
                    showSparklines: config.showsSparklines)
            }

            if rows.count > Self.maxVisibleAccounts {
                // Cap the account list at maxVisibleAccounts rows tall; the rest scroll,
                // so many accounts never grow the menu past a comfortable height.
                let item = NSMenuItem()
                item.view = Self.makeScrollingAccountsView(rows: rows, visibleCount: Self.maxVisibleAccounts)
                menu.addItem(item)
            } else {
                for row in rows {
                    let item = NSMenuItem()
                    item.view = row
                    menu.addItem(item)
                }
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

    /// Above this many accounts, the list becomes a fixed-height scroll region.
    private static let maxVisibleAccounts = 3

    /// Packs the account rows into a scroll view capped at the height of the first
    /// `visibleCount` rows, so the menu shows that many at full size and scrolls the rest.
    private static func makeScrollingAccountsView(rows: [ProfileMenuItemView], visibleCount: Int) -> NSView {
        let rowWidth: CGFloat = 320
        let visibleHeight = rows.prefix(visibleCount).reduce(CGFloat(0)) { $0 + $1.frame.height }

        let stack = NSStackView(views: rows)
        stack.orientation = .vertical
        stack.spacing = 0
        stack.alignment = .leading
        stack.translatesAutoresizingMaskIntoConstraints = false
        for row in rows {
            row.translatesAutoresizingMaskIntoConstraints = false
            row.heightAnchor.constraint(equalToConstant: row.frame.height).isActive = true
            row.widthAnchor.constraint(equalToConstant: rowWidth).isActive = true
        }

        let container = FlippedView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)

        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: rowWidth, height: visibleHeight))
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.documentView = container

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),

            container.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            container.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            container.widthAnchor.constraint(equalToConstant: rowWidth),
        ])

        return scroll
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
        // Immediate apply: each settings edit mutates the live config, saves, and
        // updates the menu. No network refresh per keystroke, and nothing to "reset".
        settingsWindow = SettingsWindowController(config: config) { [weak self] mutate in
            guard let self else { return }
            mutate(&self.config)
            ConfigStore.shared.save(self.config)
            self.scheduleRefreshTimer()
            self.updateStatusIcon()
            self.rebuildMenu()
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
            // Auto-start idle 5h sessions (e.g. right after login); if one is started,
            // refresh again shortly so the menu reflects the now-running session.
            SessionKickstarter.runIfNeeded(profiles: refreshed.profiles, allowKeychain: refreshed.allowsCookieKeychain) { [weak self] in
                DispatchQueue.main.asyncAfter(deadline: .now() + 15) { self?.refreshAllAsync() }
            }

            DispatchQueue.main.async {
                guard let self else { return }
                self.config = refreshed
                self.refreshInFlight = false
                // Note: we deliberately don't reload the open Settings window here.
                // It applies edits immediately, so reloading it would just fight the
                // user and make controls appear to reset.
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


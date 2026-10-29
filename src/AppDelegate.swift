import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var config = ConfigStore.shared.loadCached()
    private var settingsWindow: SettingsWindowController?
    private var transferWindow: TransferWindowController?
    /// The account cards in the current menu, so a switch flipped on one card can update
    /// the others without rebuilding the open menu.
    private var menuRows: [ProfileMenuItemView] = []
    private var refreshTimer: Timer?
    private var refreshInFlight = false
    private var updateTimer: Timer?
    private var updateInFlight = false
    /// A newer release we've found but not installed yet.
    private var pendingUpdate: AppRelease?
    /// Windows that were handed back sessions while running. Claude reads its session
    /// list only at launch, so until it restarts the history is there but unlisted.
    private var pendingRestarts: [String: (count: Int, since: Date)] = [:]
    /// A Claude release staged on disk that Claude can't install by itself while we keep
    /// more than one of its windows open (see ClaudeUpdateCoordinator).
    private var claudeUpdate: ClaudeUpdateCoordinator.Plan?
    /// Set while we're closing and reopening Claude, so the menu says what's happening
    /// and a second click can't start it twice.
    private var claudeUpdateStatus: String?
    /// The staged version we've already mentioned unprompted, so it's offered once.
    private var offeredClaudeUpdate: String?
    /// When Claude last closed each profile's window for an update that we put back, so
    /// one closing is never answered with two launches.
    private var reopenedClosings: [String: TimeInterval] = [:]

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        updateStatusIcon()
        rebuildMenu()
        refreshAllAsync()
        scheduleRefreshTimer()
        scheduleUpdateChecks()
        watchClaudeInstances()
    }

    // MARK: claude:// links

    /// Every `claude://` link macOS hands us, forwarded to the right Claude window.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.scheme?.caseInsensitiveCompare(ClaudeLinkRouter.scheme) == .orderedSame {
            ClaudeLinkRouter.route(url)
        }
    }

    /// Claude claims `claude://` back every time it launches, so take it again once the
    /// new instance has settled - and keep track of which window is in front, so a chat
    /// link opens where you were working. When one goes, see whether Claude closed it for
    /// an update it can't install.
    private func watchClaudeInstances() {
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.bundleIdentifier == ClaudeLinkRouter.claudeBundleID else { return }
            for delay in [3.0, 12.0] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { self?.syncClaudeLinkHandler() }
            }
        }
        center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            ClaudeLinkRouter.noteActivation(of: app)
        }
        center.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.bundleIdentifier == ClaudeLinkRouter.claudeBundleID else { return }
            // Let its helpers finish going, so the data directory is free to open again.
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { self?.reopenWindowsClosedForUpdate() }
        }
        syncClaudeLinkHandler()
    }

    private func syncClaudeLinkHandler() {
        if config.routesClaudeLinks {
            ClaudeLinkRouter.claimScheme()
        } else {
            ClaudeLinkRouter.releaseScheme()
        }
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
            let empty = NSMenuItem(title: refreshInFlight ? "Finding Claude and ChatGPT accounts..." : "No Claude/ChatGPT accounts found", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        } else {
            let runningIDs = RunningProfileDetector.runningProfileIDs(config.profiles)
            let menuBarIDs = config.showsPercentInMenuBar ? config.menuBarProfileIDList : []
            let rows = config.profiles.map { profile in
                ProfileMenuItemView(
                    profile: profile,
                    target: self,
                    action: #selector(openProfileButton(_:)),
                    isRefreshing: refreshInFlight,
                    isRunning: runningIDs.contains(profile.id),
                    showSparklines: config.showsSparklines,
                    warning: warning(for: profile),
                    inMenuBar: menuBarIDs.contains(profile.id),
                    onMenuBarToggle: { [weak self] id, on in self?.setMenuBar(id, shown: on) })
            }
            menuRows = rows

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

        // Sessions were handed back to a window that was already running, and Claude
        // only reads them at launch.
        for (id, pending) in pendingRestarts.sorted(by: { $0.value.since < $1.value.since }) {
            guard let profile = config.profiles.first(where: { $0.id == id }) else { continue }
            let item = NSMenuItem(
                title: "Restart \(ProfileFormatting.title(for: profile)) to show \(pending.count) restored session\(pending.count == 1 ? "" : "s")",
                action: #selector(restartPendingProfile(_:)),
                keyEquivalent: "")
            item.target = self
            item.representedObject = id
            item.isEnabled = true
            menu.addItem(item)
        }

        // Only worth offering when there's somewhere to move things to: a second Claude
        // account, or Claude and ChatGPT side by side.
        let signedIn = config.profiles.filter { $0.isPendingLogin != true }
        let claudeCount = signedIn.filter { $0.provider == .claude }.count
        if claudeCount >= 2 || (claudeCount >= 1 && signedIn.contains { $0.provider == .codex }) {
            let transfer = NSMenuItem(title: "Transfer session...", action: #selector(showTransfer), keyEquivalent: "t")
            transfer.target = self
            transfer.isEnabled = true
            menu.addItem(transfer)
        }

        // Claude staged a release that its own updater can't install, because that
        // updater waits for every window of the bundle to quit and we keep more open.
        if let plan = claudeUpdate {
            let item = NSMenuItem(
                title: claudeUpdateStatus ?? "Install Claude \(plan.update.version)...",
                action: #selector(finishClaudeUpdate),
                keyEquivalent: "")
            item.target = self
            item.isEnabled = claudeUpdateStatus == nil
            menu.addItem(item)
        }

        if let pendingUpdate {
            let title = updateInFlight
                ? "Updating to \(pendingUpdate.version)..."
                : "Update to \(pendingUpdate.version)"
            let item = NSMenuItem(title: title, action: #selector(installPendingUpdate), keyEquivalent: "")
            item.target = self
            item.isEnabled = !updateInFlight
            menu.addItem(item)
        }

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

    /// Flipped from the switch on an account card, with the menu still open. Applies the
    /// same rule as Settings - at most two accounts, the newest one bumps the oldest -
    /// and updates the menu bar and the other cards in place instead of rebuilding the
    /// menu under the cursor.
    private func setMenuBar(_ id: String, shown: Bool) {
        var ids = config.showsPercentInMenuBar ? config.menuBarProfileIDList : []
        if shown {
            if !ids.contains(id) { ids.append(id) }
            if ids.count > 2 { ids.removeFirst(ids.count - 2) }
        } else {
            ids.removeAll { $0 == id }
        }
        config.menuBarProfileIDs = ids
        config.menuBarProfileID = ids.first
        config.showPercentInMenuBar = !ids.isEmpty
        ConfigStore.shared.save(config)
        updateStatusIcon()
        settingsWindow?.syncConfig(config)

        for row in menuRows {
            guard let toggle = row.menuBarPin, let rowID = row.identifier?.rawValue else { continue }
            toggle.setOn(ids.contains(rowID), animated: true)
        }
    }

    /// Flags a Claude window that is signed in to the same account as another one -
    /// normally a re-login that landed in the wrong window. Both rows stay visible, and
    /// the history has already been mirrored into both.
    private func warning(for profile: LaunchProfile) -> String? {
        guard profile.provider == .claude,
              let account = profile.accountUUID?.lowercased(),
              profile.identityVerified == true else { return nil }
        let sharing = config.profiles.contains { other in
            other.id != profile.id &&
                other.provider == .claude &&
                other.identityVerified == true &&
                other.accountUUID?.lowercased() == account
        }
        return sharing ? "Also signed in to this account in another Claude window" : nil
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

    // MARK: Transferring a chat or Code session to another account

    @objc private func showTransfer() {
        transferWindow = TransferWindowController(profiles: config.profiles, allowKeychain: config.allowsCookieKeychain)
        transferWindow?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func updateStatusIcon() {
        guard let button = statusItem?.button else { return }

        // When showing percentages, draw up to two stacked rows (app icon + 5h %) so
        // it's clear which account each number belongs to. Otherwise show the glyph.
        let badgeRows: [MenuBarBadge.Row] = config.menuBarProfileIDList.compactMap { id in
            guard let profile = config.profiles.first(where: { $0.id == id }),
                  let percent = ProfileFormatting.primaryUsagePercent(for: profile) else { return nil }
            let icon = NSWorkspace.shared.icon(forFile: Launcher.expanding(profile.appPath))
            return MenuBarBadge.Row(icon: icon, percent: percent)
        }

        if config.showsPercentInMenuBar, !badgeRows.isEmpty {
            button.image = MenuBarBadge.image(rows: badgeRows)
        } else {
            let percent = ProfileFormatting.menuBarPercent(in: config.profiles, selectedID: config.menuBarProfileID)
            button.image = MenuBarIcon.make(usagePercent: percent, isRefreshing: refreshInFlight)
        }
        button.imagePosition = .imageOnly
        button.attributedTitle = NSAttributedString(string: "")
        button.title = ""
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
        settingsWindow = SettingsWindowController(
            config: config,
            onChange: { [weak self] mutate in
                guard let self else { return }
                mutate(&self.config)
                ConfigStore.shared.save(self.config)
                self.scheduleRefreshTimer()
                self.updateStatusIcon()
                self.rebuildMenu()
            },
            onCheckForUpdates: { [weak self] report in
                self?.checkForUpdates(userInitiated: true, report: report)
            })
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
            // Keep every account's Code history present in every Claude window, so a
            // sign-in landing in a different window than usual never hides it.
            let restored = ClaudeSessionMirror.sync(refreshed.profiles)
            // Auto-start idle 5h sessions (e.g. right after login); if one is started,
            // refresh again shortly so the menu reflects the now-running session.
            SessionKickstarter.runIfNeeded(profiles: refreshed.profiles, allowKeychain: refreshed.allowsCookieKeychain) { [weak self] in
                DispatchQueue.main.asyncAfter(deadline: .now() + 15) { self?.refreshAllAsync() }
            }

            DispatchQueue.main.async {
                guard let self else { return }
                self.config = refreshed
                self.refreshInFlight = false
                self.noteRestoredSessions(restored)
                self.refreshClaudeUpdatePlan()
                self.syncClaudeLinkHandler()
                // Note: we deliberately don't reload the open Settings window here.
                // It applies edits immediately, so reloading it would just fight the
                // user and make controls appear to reset.
                self.updateStatusIcon()
                self.rebuildMenu()
                // An update found while the app was busy goes in at the next quiet moment.
                if let pending = self.pendingUpdate, self.shouldInstallAutomatically(userInitiated: false) {
                    self.installUpdate(pending, userInitiated: false)
                }
            }
        }
    }

    // MARK: History handed back to a running window

    /// A running Claude lists only the sessions it found when it launched. So when the
    /// mirror hands a window history it was missing, offer to restart that window -
    /// that is the whole difference between the sessions being on disk and being there.
    private func noteRestoredSessions(_ restored: [String: Int]) {
        let running = RunningProfileDetector.snapshot(config.profiles)

        // Forget windows that have since restarted, or closed - a closed one will pick
        // the sessions up by itself the next time it opens.
        for (id, pending) in pendingRestarts {
            guard let instance = running[id] else {
                pendingRestarts[id] = nil
                continue
            }
            if let launched = instance.launchDate, launched > pending.since {
                pendingRestarts[id] = nil
            }
        }

        var firstNew: String?
        for (id, count) in restored where count > 0 && running[id] != nil {
            if pendingRestarts[id] == nil, firstNew == nil { firstNew = id }
            pendingRestarts[id] = (count: (pendingRestarts[id]?.count ?? 0) + count, since: Date())
        }

        rebuildMenu()
        if let id = firstNew, let profile = config.profiles.first(where: { $0.id == id }) {
            offerRestart(profile)
        }
    }

    private func offerRestart(_ profile: LaunchProfile) {
        let count = pendingRestarts[profile.id]?.count ?? 0
        let alert = NSAlert()
        alert.messageText = "\(count) session\(count == 1 ? "" : "s") restored for \(ProfileFormatting.title(for: profile))"
        alert.informativeText = """
        This Claude window is signed in to an account whose Code history was left in your other Claude window, so LLMCodeBar copied it across. Nothing was moved or deleted.

        Claude only reads its session list when it starts, so restart this window to see them.
        """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Restart Claude")
        alert.addButton(withTitle: "Later")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        restartClaude(profile)
    }

    private func restartClaude(_ profile: LaunchProfile) {
        pendingRestarts[profile.id] = nil
        rebuildMenu()
        CodeSessionTransfer.restart(profile) { [weak self] stopped in
            guard let self else { return }
            if !stopped {
                self.showError("Could not close \(ProfileFormatting.title(for: profile)). Quit that Claude window yourself and open it again to see the restored sessions.")
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) { self.refreshAllAsync() }
        }
    }

    @objc private func restartPendingProfile(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              let profile = config.profiles.first(where: { $0.id == id }) else { return }
        restartClaude(profile)
    }

    // MARK: Claude's own stalled update

    /// Claude's updater waits for every window of its bundle to quit before it installs
    /// anything, and we are the reason there is always another one. Claude answers that
    /// by quitting a window by itself twice per release and coming back on the old
    /// version, which is where the windows that "crash" after a couple of hours go. So
    /// notice the staged release and let the user land it on purpose instead.
    private func refreshClaudeUpdatePlan() {
        guard config.offersClaudeUpdates else {
            claudeUpdate = nil
            return
        }
        // Mid-install the windows are coming and going; don't read anything into that.
        guard claudeUpdateStatus == nil else { return }
        // Catches a closing the termination notice missed - LLMCodeBar restarting, say.
        reopenWindowsClosedForUpdate()
        let plan = ClaudeUpdateCoordinator.plan(for: config.profiles)
        claudeUpdate = plan

        // Bring it up unprompted only once per release, and only when nothing is running
        // in any window. Otherwise it waits in the menu for a moment the user picks.
        guard let plan, plan.isQuiet, offeredClaudeUpdate != plan.update.version else { return }
        offeredClaudeUpdate = plan.update.version
        offerClaudeUpdate(plan)
    }

    /// Claude closes a window by itself to install an update once it has sat idle and out
    /// of focus for ten minutes, expecting to come straight back on the new version. With
    /// another window open the install can't start, so it doesn't come back - which is
    /// the window that "crashes" every so often. Put it back right away, behind whatever
    /// the user is doing, and tell Claude this release already failed for it so it doesn't
    /// happen a second time. Claude only does this to a window with no session running,
    /// so nothing is lost in it.
    private func reopenWindowsClosedForUpdate() {
        guard config.offersClaudeUpdates, claudeUpdateStatus == nil else { return }
        let profiles = config.profiles
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let found = ClaudeUpdateCoordinator.strandedWindows(in: profiles) else { return }
            DispatchQueue.main.async {
                guard let self, self.claudeUpdateStatus == nil else { return }
                let due = found.windows.filter { self.reopenedClosings[$0.profile.id] != $0.closedAt }
                for (index, window) in due.enumerated() {
                    self.reopenedClosings[window.profile.id] = window.closedAt
                    ClaudeUpdateCoordinator.recordFailedInstall(found.update, for: window.profile)
                    // One at a time, as the coordinator reopens them: Claude windows
                    // starting together race over the bundle's shared state.
                    DispatchQueue.main.asyncAfter(deadline: .now() + Double(index) * 3) {
                        try? Launcher.launch(window.profile, quietly: true)
                    }
                }
            }
        }
    }

    @objc private func finishClaudeUpdate() {
        // Read it again - what's running changes between opening the menu and clicking.
        guard let plan = ClaudeUpdateCoordinator.plan(for: config.profiles) else {
            claudeUpdate = nil
            rebuildMenu()
            showError("Claude's update isn't waiting to install any more. Claude will stage the next one on its own.")
            return
        }
        claudeUpdate = plan
        offerClaudeUpdate(plan)
    }

    private func offerClaudeUpdate(_ plan: ClaudeUpdateCoordinator.Plan) {
        let windows = plan.windows.count == 1 ? "it" : "them"
        let alert = NSAlert()
        alert.messageText = "Install Claude \(plan.update.version)?"
        alert.informativeText = """
        Claude downloaded \(plan.update.version) but can't install it. Its updater waits for every Claude window to quit first, and you keep more than one open, so instead it quits a window on its own twice per release and comes back on \(plan.update.installedVersion).

        \(claudeUpdateCost(plan))

        LLMCodeBar will close \(windows), let the update install, and open \(windows) again.
        """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Install and Reopen")
        alert.addButton(withTitle: "Not Now")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        applyClaudeUpdate(plan)
    }

    /// What closing the windows costs at this moment, window by window, so the choice is
    /// made with the running sessions in view instead of after the fact.
    private func claudeUpdateCost(_ plan: ClaudeUpdateCoordinator.Plan) -> String {
        var lines: [String] = []
        for window in plan.windows {
            let name = ProfileFormatting.title(for: window.profile)
            let count = window.sessions
            if count == 0 {
                lines.append("\(name): nothing running.")
                continue
            }
            let sessions = "\(count) Code session\(count == 1 ? "" : "s") open"
            switch window.activity {
            case .working:
                lines.append("\(name): \(sessions), and one is working right now.")
            case .idle:
                lines.append("\(name): \(sessions), idle.")
            case .unknown:
                lines.append("\(name): \(sessions).")
            }
        }
        if plan.sessions > 0 {
            lines.append("The sessions keep their history and come back in the list - an answer still being written is the part that's lost.")
        }
        return lines.joined(separator: "\n")
    }

    private func applyClaudeUpdate(_ plan: ClaudeUpdateCoordinator.Plan) {
        claudeUpdateStatus = "Closing Claude..."
        rebuildMenu()
        ClaudeUpdateCoordinator.apply(plan, progress: { [weak self] text in
            self?.claudeUpdateStatus = text
            self?.rebuildMenu()
        }, completion: { [weak self] outcome in
            guard let self else { return }
            self.claudeUpdateStatus = nil
            self.claudeUpdate = nil
            switch outcome {
            case .installed(let version):
                self.offeredClaudeUpdate = nil
                self.showNotice("Claude \(version) is installed, and your windows are open again.")
            case .windowRefused(let name):
                self.showError("\(name) wouldn't close, so Claude is still on \(plan.update.installedVersion) and any window that did close has been opened again. Try again once that window is able to quit.")
            case .notInstalled:
                self.showError("Claude's windows were closed and opened again, but the update didn't install. Claude will stage it again on its own.")
            }
            // The windows just restarted either way, so read the new state rather than
            // trusting what we had.
            DispatchQueue.main.asyncAfter(deadline: .now() + 10) { self.refreshAllAsync() }
        })
    }

    // MARK: Staying up to date

    private func scheduleUpdateChecks() {
        // Once shortly after launch (out of the way of the first usage refresh), then
        // every few hours for as long as the app is running.
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in
            self?.checkForUpdates(userInitiated: false)
        }
        updateTimer?.invalidate()
        updateTimer = Timer.scheduledTimer(withTimeInterval: Updater.checkInterval, repeats: true) { [weak self] _ in
            self?.checkForUpdates(userInitiated: false)
        }
    }

    /// Asks GitHub for the newest release. `report` receives progress and results for
    /// the Settings window; background checks pass none and stay silent.
    private func checkForUpdates(userInitiated: Bool, report: ((String) -> Void)? = nil) {
        guard !updateInFlight else { return }
        // Keeps a restart from re-checking straight away. The minute of slack is so a
        // scheduled check is never rejected for firing a moment early.
        if !userInitiated, let last = config.lastUpdateCheckAt,
           Date().timeIntervalSince(last) < Updater.checkInterval - 60 {
            return
        }

        updateInFlight = true
        report?("Checking for updates...")

        DispatchQueue.global(qos: .utility).async { [weak self] in
            let outcome = Result { try Updater.availableUpdate() }
            DispatchQueue.main.async {
                guard let self else { return }
                self.updateInFlight = false
                self.config.lastUpdateCheckAt = Date()
                ConfigStore.shared.save(self.config)

                switch outcome {
                case .success(let release):
                    guard let release else {
                        self.pendingUpdate = nil
                        self.rebuildMenu()
                        report?("LLMCodeBar \(Updater.currentVersion) is up to date.")
                        return
                    }
                    self.pendingUpdate = release
                    self.rebuildMenu()
                    if self.shouldInstallAutomatically(userInitiated: userInitiated) {
                        self.installUpdate(release, userInitiated: userInitiated, report: report)
                    } else {
                        report?("LLMCodeBar \(release.version) is available.")
                    }
                case .failure(let error):
                    report?("Update check failed: \(error.localizedDescription)")
                }
            }
        }
    }

    /// Restarting mid-transfer would abandon it, and mid-refresh would throw away the
    /// results, so hold the update until the app is idle. A user-initiated check is
    /// allowed to interrupt an open Settings window - they asked for it.
    private func shouldInstallAutomatically(userInitiated: Bool) -> Bool {
        guard config.autoUpdates else { return false }
        if refreshInFlight || transferWindow?.window?.isVisible == true { return false }
        if !userInitiated, settingsWindow?.window?.isVisible == true { return false }
        return true
    }

    @objc private func installPendingUpdate() {
        guard let pendingUpdate else { return }
        installUpdate(pendingUpdate, userInitiated: true)
    }

    /// Downloads and verifies the release, then hands the swap to a detached script
    /// and quits - the script waits for us to exit, replaces the bundle, and relaunches.
    private func installUpdate(_ release: AppRelease, userInitiated: Bool, report: ((String) -> Void)? = nil) {
        guard !updateInFlight else { return }
        updateInFlight = true
        report?("Downloading LLMCodeBar \(release.version)...")
        rebuildMenu()

        DispatchQueue.global(qos: .utility).async { [weak self] in
            let staged = Result { try Updater.stage(release) }
            DispatchQueue.main.async {
                guard let self else {
                    if case .success(let staged) = staged { Updater.discard(staged) }
                    return
                }
                do {
                    let staged = try staged.get()
                    do {
                        try Updater.install(staged)
                    } catch {
                        Updater.discard(staged)
                        throw error
                    }
                    NSApp.terminate(nil)
                } catch {
                    self.updateInFlight = false
                    self.rebuildMenu()
                    let message = "Could not install LLMCodeBar \(release.version): \(error.localizedDescription)"
                    if let report {
                        report(message)
                    } else if userInitiated {
                        self.showError(message)
                    }
                }
            }
        }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private func showNotice(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "LLMCodeBar"
        alert.informativeText = message
        alert.alertStyle = .informational
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    private func showError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "LLMCodeBar"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.runModal()
    }
}


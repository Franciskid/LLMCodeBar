import AppKit

final class SettingsWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    private var config: AppConfig
    /// Applies an edit to the app's live config (and this window's copy). Immediate
    /// apply means there's no unsaved state to lose, so nothing "resets".
    private let onChange: (@escaping (inout AppConfig) -> Void) -> Void

    private let table = NSTableView()

    // Per-account controls.
    private let accountTitle = NSTextField(labelWithString: "")
    private let accountSubtitle = NSTextField(labelWithString: "")
    private let menuBarAccount = NSButton(checkboxWithTitle: "Show this account's 5h % in the menu bar", target: nil, action: nil)
    private let autoStartSession = NSButton(checkboxWithTitle: "Auto-start 5h session for this account", target: nil, action: nil)
    private let startSessionNow = NSButton(title: "Start 5h session now", target: nil, action: nil)
    private let removeButton = NSButton(title: "Remove account", target: nil, action: nil)
    private let labelField = NSTextField()
    private let appPathField = NSTextField()
    private let dataDirField = NSTextField()
    private let providerPopup = NSPopUpButton()
    private let advancedToggle = NSButton()
    private let advancedStack = NSStackView()

    // App-wide (General) controls.
    private let launchAtLogin = NSButton(checkboxWithTitle: "Launch LLMCodeBar at login", target: nil, action: nil)
    private let refreshIntervalPopup = NSPopUpButton()
    private let showSparklines = NSButton(checkboxWithTitle: "Show 7-day trend sparklines", target: nil, action: nil)
    private let autoApproveCookies = NSButton(checkboxWithTitle: "Auto-approve cookie access", target: nil, action: nil)

    private let statusLabel = NSTextField(labelWithString: "")

    private let refreshOptions: [(title: String, seconds: Int)] = [
        ("30 sec", 30), ("1 min", 60), ("2 min", 120), ("5 min", 300), ("10 min", 600), ("15 min", 900), ("30 min", 1800),
    ]

    init(config: AppConfig, onChange: @escaping (@escaping (inout AppConfig) -> Void) -> Void) {
        self.config = config
        self.onChange = onChange
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 436),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false)
        window.title = "LLMCodeBar Settings"
        window.center()
        super.init(window: window)
        buildUI()
        loadSelection()
    }

    required init?(coder: NSCoder) { nil }

    // MARK: Account list

    func numberOfRows(in tableView: NSTableView) -> Int { config.profiles.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = NSTableCellView()
        let text = NSTextField(labelWithString: config.profiles[row].label)
        text.translatesAutoresizingMaskIntoConstraints = false
        text.lineBreakMode = .byTruncatingTail
        cell.addSubview(text)
        NSLayoutConstraint.activate([
            text.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
            text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
            text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) { loadSelection() }

    // MARK: Immediate apply

    private func commit(_ mutate: @escaping (inout AppConfig) -> Void) {
        mutate(&config)
        onChange(mutate)
    }

    private var selectedID: String? {
        let row = table.selectedRow
        guard row >= 0, row < config.profiles.count else { return nil }
        return config.profiles[row].id
    }

    // MARK: UI

    private func buildUI() {
        guard let content = window?.contentView else { return }

        // Left: account list + add / rescan.
        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        table.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("profile")))
        table.headerView = nil
        table.delegate = self
        table.dataSource = self
        table.rowHeight = 28
        scroll.documentView = table

        let listTitle = NSTextField(labelWithString: "Accounts")
        listTitle.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        let addAccountButton = NSButton(title: "+", target: self, action: #selector(addAccount))
        addAccountButton.bezelStyle = .rounded
        addAccountButton.toolTip = "Add a Claude or Codex account"
        addAccountButton.widthAnchor.constraint(equalToConstant: 32).isActive = true
        let listHeader = NSStackView(views: [listTitle, addAccountButton])
        listHeader.orientation = .horizontal
        listHeader.spacing = 8
        listTitle.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let rescan = NSButton(title: "Rescan for accounts", target: self, action: #selector(rescanAccounts))
        rescan.bezelStyle = .rounded
        rescan.controlSize = .small

        removeButton.title = "Remove selected account"
        removeButton.target = self
        removeButton.action = #selector(removeAccount)
        removeButton.bezelStyle = .rounded
        removeButton.controlSize = .small
        if #available(macOS 11.0, *) { removeButton.hasDestructiveAction = true }

        let leftPane = NSStackView(views: [listHeader, scroll, rescan, removeButton])
        leftPane.translatesAutoresizingMaskIntoConstraints = false
        leftPane.orientation = .vertical
        leftPane.spacing = 8
        leftPane.alignment = .leading
        leftPane.setCustomSpacing(16, after: rescan)
        scroll.widthAnchor.constraint(equalTo: leftPane.widthAnchor).isActive = true

        // Right: account section + General section.
        let form = NSStackView()
        form.translatesAutoresizingMaskIntoConstraints = false
        form.orientation = .vertical
        form.spacing = 10
        form.alignment = .leading

        buildAccountSection(into: form)
        form.addArrangedSubview(divider())
        buildGeneralSection(into: form)

        statusLabel.textColor = .secondaryLabelColor
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.lineBreakMode = .byWordWrapping
        statusLabel.usesSingleLineMode = false
        statusLabel.cell?.wraps = true
        statusLabel.maximumNumberOfLines = 3
        statusLabel.preferredMaxLayoutWidth = 420
        form.setCustomSpacing(14, after: form.arrangedSubviews.last!)
        form.addArrangedSubview(statusLabel)

        content.addSubview(leftPane)
        content.addSubview(form)
        NSLayoutConstraint.activate([
            leftPane.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            leftPane.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            leftPane.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
            leftPane.widthAnchor.constraint(equalToConstant: 220),
            form.leadingAnchor.constraint(equalTo: leftPane.trailingAnchor, constant: 20),
            form.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            form.topAnchor.constraint(equalTo: content.topAnchor, constant: 18),
        ])

        if !config.profiles.isEmpty {
            table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }
    }

    private func buildAccountSection(into form: NSStackView) {
        accountTitle.font = .systemFont(ofSize: 15, weight: .semibold)
        accountSubtitle.font = .systemFont(ofSize: 12)
        accountSubtitle.textColor = .secondaryLabelColor
        let header = NSStackView(views: [accountTitle, accountSubtitle])
        header.orientation = .vertical
        header.alignment = .leading
        header.spacing = 1

        menuBarAccount.target = self
        menuBarAccount.action = #selector(menuBarAccountChanged)
        menuBarAccount.toolTip = "Show this account's 5h session % in the menu bar, with its app icon. You can show up to 2 accounts, stacked one above the other."

        autoStartSession.target = self
        autoStartSession.action = #selector(autoStartChanged)
        autoStartSession.toolTip = "When the 5h window is idle or has reset, LLMCodeBar sends one tiny \"hi\" on the cheapest model to start it. For Claude it uses a throwaway chat that's deleted after. Only fires when the session isn't already running. Codex is experimental."
        startSessionNow.target = self
        startSessionNow.action = #selector(startSessionNowTapped)
        startSessionNow.bezelStyle = .rounded
        let autoStartRow = NSStackView(views: [autoStartSession, startSessionNow])
        autoStartRow.orientation = .horizontal
        autoStartRow.spacing = 10

        let autoStartHelp = helpLabel("Starts the 5h window when it's idle by sending a tiny \"hi\" on the cheapest model. Only acts when the session isn't already running. Codex is experimental.")

        // Advanced (label / paths), collapsed.
        advancedStack.orientation = .vertical
        advancedStack.spacing = 8
        providerPopup.addItems(withTitles: Provider.allCases.map(\.rawValue))
        for field in [labelField, appPathField, dataDirField] { field.delegate = self }
        providerPopup.target = self
        providerPopup.action = #selector(providerChanged)
        addRow(to: advancedStack, label: "Label", control: labelField)
        addRow(to: advancedStack, label: "Provider", control: providerPopup)
        addRow(to: advancedStack, label: "App path", control: appPathField)
        addRow(to: advancedStack, label: "Profile folder", control: dataDirField)
        advancedStack.isHidden = true

        advancedToggle.bezelStyle = .disclosure
        advancedToggle.setButtonType(.pushOnPushOff)
        advancedToggle.title = ""
        advancedToggle.target = self
        advancedToggle.action = #selector(toggleAdvanced)
        let advancedLabel = NSTextField(labelWithString: "Advanced")
        advancedLabel.textColor = .secondaryLabelColor
        let advancedHeader = NSStackView(views: [advancedToggle, advancedLabel])
        advancedHeader.orientation = .horizontal
        advancedHeader.spacing = 4

        form.addArrangedSubview(header)
        form.setCustomSpacing(12, after: header)
        form.addArrangedSubview(menuBarAccount)
        form.addArrangedSubview(autoStartRow)
        form.addArrangedSubview(autoStartHelp)
        form.addArrangedSubview(advancedHeader)
        form.addArrangedSubview(advancedStack)
    }

    private func buildGeneralSection(into form: NSStackView) {
        let title = NSTextField(labelWithString: "General")
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.toolTip = "Applies to LLMCodeBar, not to any single account."

        launchAtLogin.state = (config.launchAtLogin || AutostartManager.isEnabled) ? .on : .off
        launchAtLogin.toolTip = "Start LLMCodeBar itself when you log in to your Mac. (Not the Claude or Codex apps.)"
        launchAtLogin.target = self
        launchAtLogin.action = #selector(launchAtLoginChanged)

        refreshIntervalPopup.addItems(withTitles: refreshOptions.map(\.title))
        let current = Int(config.refreshInterval)
        let closest = refreshOptions.enumerated().min(by: { abs($0.element.seconds - current) < abs($1.element.seconds - current) })
        refreshIntervalPopup.selectItem(at: closest?.offset ?? 1)
        refreshIntervalPopup.target = self
        refreshIntervalPopup.action = #selector(refreshIntervalChanged)
        let refreshLabel = NSTextField(labelWithString: "Refresh every")
        let refreshRow = NSStackView(views: [refreshLabel, refreshIntervalPopup])
        refreshRow.orientation = .horizontal
        refreshRow.spacing = 8
        refreshIntervalPopup.widthAnchor.constraint(greaterThanOrEqualToConstant: 120).isActive = true

        showSparklines.state = config.showsSparklines ? .on : .off
        showSparklines.target = self
        showSparklines.action = #selector(sparklinesChanged)

        autoApproveCookies.state = config.allowsCookieKeychain ? .on : .off
        autoApproveCookies.toolTip = "Reads the encrypted cookie store for live usage. macOS asks to approve keychain access once (click \"Always Allow\"). Uncheck to never prompt; usage then updates only while Claude/Codex is open."
        autoApproveCookies.target = self
        autoApproveCookies.action = #selector(cookiesChanged)
        let cookiesHelp = helpLabel("Approve the keychain once (\"Always Allow\") instead of every launch. Uncheck to never prompt.")

        form.setCustomSpacing(12, after: form.arrangedSubviews.last!)
        form.addArrangedSubview(title)
        form.addArrangedSubview(launchAtLogin)
        form.addArrangedSubview(refreshRow)
        form.addArrangedSubview(showSparklines)
        form.addArrangedSubview(autoApproveCookies)
        form.addArrangedSubview(cookiesHelp)
    }

    private func divider() -> NSView {
        let box = NSBox()
        box.boxType = .separator
        box.translatesAutoresizingMaskIntoConstraints = false
        box.widthAnchor.constraint(equalToConstant: 440).isActive = true
        return box
    }

    private func helpLabel(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 10.5)
        label.textColor = .tertiaryLabelColor
        label.maximumNumberOfLines = 3
        label.preferredMaxLayoutWidth = 430
        label.isSelectable = false
        return label
    }

    private func addRow(to stack: NSStackView, label: String, control: NSView) {
        let labelView = NSTextField(labelWithString: label)
        labelView.alignment = .right
        labelView.widthAnchor.constraint(equalToConstant: 110).isActive = true
        control.translatesAutoresizingMaskIntoConstraints = false
        control.widthAnchor.constraint(greaterThanOrEqualToConstant: 300).isActive = true
        let row = NSStackView(views: [labelView, control])
        row.orientation = .horizontal
        row.spacing = 8
        stack.addArrangedSubview(row)
    }

    // MARK: Populate account section

    private func loadSelection() {
        let row = table.selectedRow
        guard row >= 0, row < config.profiles.count else {
            clearAccountSection()
            return
        }
        let profile = config.profiles[row]
        let accountControls = [menuBarAccount, autoStartSession, startSessionNow, removeButton, advancedToggle, providerPopup, labelField, appPathField, dataDirField]
        accountControls.forEach { $0.isEnabled = true }

        labelField.stringValue = profile.label
        providerPopup.selectItem(withTitle: profile.provider.rawValue)
        appPathField.stringValue = profile.appPath
        dataDirField.stringValue = profile.dataDir

        menuBarAccount.state = (config.menuBarProfileIDList.contains(profile.id) && config.showsPercentInMenuBar) ? .on : .off

        let signedIn = profile.signedIn == true
        autoStartSession.isEnabled = signedIn
        autoStartSession.state = (signedIn && profile.autoStartsSession) ? .on : .off

        let sessionRunning = profile.usage != nil && !SessionKickstarter.isSessionIdle(profile)
        startSessionNow.isEnabled = signedIn && !sessionRunning
        startSessionNow.toolTip = sessionRunning
            ? "The 5-hour session is already running, nothing to start."
            : "Send a tiny \"hi\" now to start the 5-hour window."

        if profile.isPendingLogin == true {
            accountTitle.stringValue = "Connect \(profile.provider.rawValue)"
            accountSubtitle.stringValue = "Sign in when the window opens"
        } else {
            accountTitle.stringValue = profile.accountEmail ?? profile.accountName ?? "\(profile.provider.rawValue) account"
            accountSubtitle.stringValue = [profile.provider.rawValue, profile.usage?.accountPlan ?? profile.accountPlan]
                .compactMap { $0 }.joined(separator: "  ·  ")
        }
        statusLabel.stringValue = ""
    }

    private func clearAccountSection() {
        accountTitle.stringValue = "No account selected"
        accountSubtitle.stringValue = "Add one with the + button"
        [menuBarAccount, autoStartSession, startSessionNow, removeButton, advancedToggle, providerPopup, labelField, appPathField, dataDirField].forEach { $0.isEnabled = false }
        menuBarAccount.state = .off
        autoStartSession.state = .off
    }

    // MARK: Account actions

    @objc private func menuBarAccountChanged() {
        guard let id = selectedID else { return }
        let on = menuBarAccount.state == .on
        commit { cfg in
            var ids = cfg.menuBarProfileIDList
            if on {
                if !ids.contains(id) { ids.append(id) }
                // Cap at 2: keep the newly checked account and drop the oldest.
                if ids.count > 2 { ids.removeFirst(ids.count - 2) }
            } else {
                ids.removeAll { $0 == id }
            }
            cfg.menuBarProfileIDs = ids
            cfg.menuBarProfileID = ids.first
            cfg.showPercentInMenuBar = !ids.isEmpty
        }
    }

    @objc private func autoStartChanged() {
        guard let id = selectedID else { return }
        let on = autoStartSession.state == .on
        commit { cfg in
            if let i = cfg.profiles.firstIndex(where: { $0.id == id }) {
                cfg.profiles[i].autoStartSession = on
            }
        }
    }

    @objc private func providerChanged() {
        guard let id = selectedID else { return }
        let provider = Provider(rawValue: providerPopup.titleOfSelectedItem ?? "Claude") ?? .claude
        commit { cfg in
            if let i = cfg.profiles.firstIndex(where: { $0.id == id }) { cfg.profiles[i].provider = provider }
        }
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard let id = selectedID, let field = notification.object as? NSTextField else { return }
        let label = labelField.stringValue, appPath = appPathField.stringValue, dataDir = dataDirField.stringValue
        _ = field
        commit { cfg in
            if let i = cfg.profiles.firstIndex(where: { $0.id == id }) {
                cfg.profiles[i].label = label
                cfg.profiles[i].appPath = appPath
                cfg.profiles[i].dataDir = dataDir
            }
        }
        table.reloadData()
        restoreSelection(id: id)
    }

    @objc private func startSessionNowTapped() {
        let row = table.selectedRow
        guard row >= 0, row < config.profiles.count else { return }
        let profile = config.profiles[row]
        let allowKeychain = config.allowsCookieKeychain
        statusLabel.stringValue = "Starting a 5h session for \(profile.accountEmail ?? profile.label)…"
        startSessionNow.isEnabled = false
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let message = SessionKickstarter.startSession(for: profile, allowKeychain: allowKeychain)
            DispatchQueue.main.async {
                self?.statusLabel.stringValue = message
                self?.startSessionNow.isEnabled = profile.signedIn == true
            }
        }
    }

    @objc private func removeAccount() {
        let row = table.selectedRow
        guard let id = selectedID, row >= 0, row < config.profiles.count else { return }
        let profile = config.profiles[row]

        let alert = NSAlert()
        alert.messageText = "Remove \(profile.accountEmail ?? profile.label) from LLMCodeBar?"
        alert.informativeText = "This just takes the account off this list. Your Claude/Codex login and its data are not touched, and you can add it back with Rescan."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        commit { cfg in cfg.profiles.removeAll { $0.id == id } }
        table.reloadData()
        if !config.profiles.isEmpty {
            table.selectRowIndexes(IndexSet(integer: min(row, config.profiles.count - 1)), byExtendingSelection: false)
        } else {
            loadSelection()
        }
    }

    @objc private func addAccount() {
        let alert = NSAlert()
        alert.messageText = "Add Account"
        alert.informativeText = "Choose the app to open in a new isolated profile, then sign in. LLMCodeBar detects the account automatically."
        alert.addButton(withTitle: "Open Login Window")
        alert.addButton(withTitle: "Cancel")
        let picker = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 240, height: 28))
        picker.addItems(withTitles: Provider.allCases.map(\.rawValue))
        alert.accessoryView = picker
        guard alert.runModal() == .alertFirstButtonReturn,
              let provider = Provider(rawValue: picker.titleOfSelectedItem ?? "") else { return }

        let profile = ConfigStore.shared.createPendingProfile(provider: provider)
        commit { $0.profiles.append(profile) }
        table.reloadData()
        table.selectRowIndexes(IndexSet(integer: config.profiles.count - 1), byExtendingSelection: false)
        do {
            try Launcher.launch(profile)
            statusLabel.stringValue = "Opened \(provider.rawValue). Sign in there, then hit \"Rescan for accounts\"."
        } catch {
            statusLabel.stringValue = "Could not open login window: \(error.localizedDescription)"
        }
    }

    @objc private func rescanAccounts() {
        let keepID = selectedID
        commit { cfg in cfg.profiles = ConfigStore.shared.inferProfiles(existing: cfg.profiles) }
        table.reloadData()
        restoreSelection(id: keepID)
        statusLabel.stringValue = "Found \(config.profiles.count) connected account(s)."
    }

    @objc private func toggleAdvanced() {
        let show = advancedToggle.state == .on
        advancedStack.isHidden = !show
        guard let window = window else { return }
        let delta: CGFloat = 140
        var frame = window.frame
        frame.size.height += show ? delta : -delta
        frame.origin.y -= show ? delta : -delta
        window.setFrame(frame, display: true, animate: true)
    }

    // MARK: General actions

    @objc private func launchAtLoginChanged() {
        let on = launchAtLogin.state == .on
        commit { $0.launchAtLogin = on }
    }

    @objc private func refreshIntervalChanged() {
        let index = refreshIntervalPopup.indexOfSelectedItem
        guard refreshOptions.indices.contains(index) else { return }
        let seconds = refreshOptions[index].seconds
        commit { $0.refreshIntervalSeconds = seconds }
    }

    @objc private func sparklinesChanged() {
        let on = showSparklines.state == .on
        commit { $0.showSparklines = on }
    }

    @objc private func cookiesChanged() {
        let on = autoApproveCookies.state == .on
        commit { $0.autoApproveCookieAccess = on }
    }

    // MARK: Selection helpers

    private func restoreSelection(id: String?) {
        guard !config.profiles.isEmpty else { loadSelection(); return }
        if let id, let row = config.profiles.firstIndex(where: { $0.id == id }) {
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        } else {
            table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }
    }
}

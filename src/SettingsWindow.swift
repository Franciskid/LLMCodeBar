import AppKit

final class SettingsWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    private var config: AppConfig
    private let onSave: (AppConfig) -> Void
    private let table = NSTableView()
    private let labelField = NSTextField()
    private let appPathField = NSTextField()
    private let dataDirField = NSTextField()
    private let providerPopup = NSPopUpButton()
    private let launchAtLogin = NSButton(checkboxWithTitle: "Launch at login", target: nil, action: nil)
    private let autoApproveCookies = NSButton(checkboxWithTitle: "Auto-approve cookie access", target: nil, action: nil)
    private let showSparklines = NSButton(checkboxWithTitle: "Show 7-day trend sparklines", target: nil, action: nil)
    private let menuBarAccount = NSButton(checkboxWithTitle: "Show this account's 5h % in the menu bar", target: nil, action: nil)
    private let autoStartSession = NSButton(checkboxWithTitle: "Auto-start 5h session for this account", target: nil, action: nil)
    private let startSessionNow = NSButton(title: "Start 5h session now", target: nil, action: nil)
    private let refreshIntervalPopup = NSPopUpButton()
    private let statusLabel = NSTextField(labelWithString: "")
    private let accountTitle = NSTextField(labelWithString: "")
    private let accountSubtitle = NSTextField(labelWithString: "")
    private let advancedToggle = NSButton()
    private let advancedStack = NSStackView()

    private let refreshOptions: [(title: String, seconds: Int)] = [
        ("30 sec", 30), ("1 min", 60), ("2 min", 120), ("5 min", 300), ("10 min", 600), ("15 min", 900), ("30 min", 1800),
    ]

    init(config: AppConfig, onSave: @escaping (AppConfig) -> Void) {
        self.config = config
        self.onSave = onSave
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 432),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "LLMCodeBar Settings"
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
        autoApproveCookies.state = config.allowsCookieKeychain ? .on : .off
        autoApproveCookies.toolTip = "Reads the encrypted cookie store to fetch live usage. macOS asks to approve keychain access once - click \"Always Allow\". Uncheck to never prompt; usage then updates only while Claude/Codex is open."

        let cookiesHelp = NSTextField(wrappingLabelWithString: "Approve keychain access once (\"Always Allow\") instead of every launch. Uncheck to never prompt.")
        cookiesHelp.font = .systemFont(ofSize: 10.5)
        cookiesHelp.textColor = .tertiaryLabelColor
        cookiesHelp.maximumNumberOfLines = 2
        cookiesHelp.preferredMaxLayoutWidth = 360
        cookiesHelp.isSelectable = false

        refreshIntervalPopup.addItems(withTitles: refreshOptions.map(\.title))
        let currentSeconds = Int(config.refreshInterval)
        let closest = refreshOptions.enumerated().min(by: { abs($0.element.seconds - currentSeconds) < abs($1.element.seconds - currentSeconds) })
        refreshIntervalPopup.selectItem(at: closest?.offset ?? 1)
        showSparklines.state = config.showsSparklines ? .on : .off

        autoStartSession.toolTip = "When the 5h window is idle or has reset, the app sends one tiny \"hi\" on the cheapest model to start the 5-hour window. For Claude it uses a throwaway chat that's deleted afterwards. Only fires when the session isn't already running. Codex support is experimental."
        let autoStartHelp = NSTextField(wrappingLabelWithString: "Starts the 5h window when it's idle/reset by sending a tiny \"hi\" on the cheapest model. Only acts when the session isn't already running - use \"Start 5h session now\" to test it immediately. Codex is experimental.")
        autoStartHelp.font = .systemFont(ofSize: 10.5)
        autoStartHelp.textColor = .tertiaryLabelColor
        autoStartHelp.maximumNumberOfLines = 2
        autoStartHelp.preferredMaxLayoutWidth = 360
        autoStartHelp.isSelectable = false

        let form = NSStackView()
        form.translatesAutoresizingMaskIntoConstraints = false
        form.orientation = .vertical
        form.spacing = 10

        // Account header.
        accountTitle.font = .systemFont(ofSize: 15, weight: .semibold)
        accountSubtitle.font = .systemFont(ofSize: 12)
        accountSubtitle.textColor = .secondaryLabelColor
        let header = NSStackView(views: [accountTitle, accountSubtitle])
        header.orientation = .vertical
        header.alignment = .leading
        header.spacing = 1

        // Advanced path/label fields, collapsed by default so the pane stays clean.
        advancedStack.orientation = .vertical
        advancedStack.spacing = 10
        addRow(to: advancedStack, label: "Label", control: labelField)
        addRow(to: advancedStack, label: "Provider", control: providerPopup)
        addRow(to: advancedStack, label: "App path", control: appPathField)
        addRow(to: advancedStack, label: "Profile data folder", control: dataDirField)
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
        form.setCustomSpacing(14, after: header)
        addRow(to: form, label: "Refresh every", control: refreshIntervalPopup)
        form.addArrangedSubview(launchAtLogin)
        form.addArrangedSubview(menuBarAccount)
        form.addArrangedSubview(showSparklines)
        form.addArrangedSubview(autoApproveCookies)
        form.addArrangedSubview(cookiesHelp)
        form.setCustomSpacing(2, after: autoApproveCookies)

        startSessionNow.target = self
        startSessionNow.action = #selector(startSessionNowTapped)
        startSessionNow.bezelStyle = .rounded
        let autoStartRow = NSStackView(views: [autoStartSession, startSessionNow])
        autoStartRow.orientation = .horizontal
        autoStartRow.spacing = 10
        form.addArrangedSubview(autoStartRow)
        form.addArrangedSubview(autoStartHelp)
        form.setCustomSpacing(2, after: autoStartRow)

        form.addArrangedSubview(advancedHeader)
        form.addArrangedSubview(advancedStack)
        form.setCustomSpacing(14, after: advancedStack)

        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byWordWrapping
        statusLabel.usesSingleLineMode = false
        statusLabel.cell?.wraps = true
        statusLabel.cell?.isScrollable = false
        statusLabel.maximumNumberOfLines = 4
        statusLabel.preferredMaxLayoutWidth = 380
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
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
        // The menu-bar % is a single exclusive choice: checked only on the account
        // currently designated (and only while the percentage is enabled).
        menuBarAccount.state = (config.menuBarProfileID == profile.id && config.showsPercentInMenuBar) ? .on : .off

        let signedIn = profile.signedIn == true
        autoStartSession.isEnabled = signedIn
        autoStartSession.state = (signedIn && profile.autoStartsSession) ? .on : .off

        // The manual trigger is pointless while the 5h window is already running.
        let sessionActive = profile.usage != nil && !SessionKickstarter.isSessionIdle(profile)
        startSessionNow.isEnabled = signedIn && !sessionActive
        startSessionNow.toolTip = sessionActive
            ? "The 5-hour session is already running - there's nothing to start."
            : "Send a tiny “hi” now to start the 5-hour window."

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

    @objc private func toggleAdvanced() {
        let show = advancedToggle.state == .on
        advancedStack.isHidden = !show
        guard let window = window else { return }
        let delta: CGFloat = 152
        var frame = window.frame
        frame.size.height += show ? delta : -delta
        frame.origin.y -= show ? delta : -delta // keep the top edge fixed
        window.setFrame(frame, display: true, animate: true)
    }

    private func writeSelection() {
        let row = table.selectedRow
        guard row >= 0, row < config.profiles.count else { return }
        config.profiles[row].label = labelField.stringValue
        config.profiles[row].provider = Provider(rawValue: providerPopup.titleOfSelectedItem ?? "Claude") ?? .claude
        config.profiles[row].appPath = appPathField.stringValue
        config.profiles[row].dataDir = dataDirField.stringValue
        config.profiles[row].autoStartSession = autoStartSession.isEnabled && autoStartSession.state == .on
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
                self?.startSessionNow.isEnabled = profile.provider == .claude && profile.signedIn == true
            }
        }
    }

    @objc private func addAccount() {
        writeSelection()

        let alert = NSAlert()
        alert.messageText = "Add Account"
        alert.informativeText = "Choose the app to open in a new isolated profile, then sign in there. LLMCodeBar will detect the account automatically."
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
        // The menu-bar % is one global choice. Checking it on the selected account
        // makes it THE menu-bar account (auto-disabling every other account) and
        // turns the percentage on; unchecking it clears the percentage.
        let selectedID = selectedProfileID()
        if menuBarAccount.state == .on {
            config.menuBarProfileID = selectedID
            config.showPercentInMenuBar = true
        } else if config.menuBarProfileID == selectedID {
            config.menuBarProfileID = nil
            config.showPercentInMenuBar = false
        }
        config.launchAtLogin = launchAtLogin.state == .on
        config.autoApproveCookieAccess = autoApproveCookies.state == .on
        config.showSparklines = showSparklines.state == .on
        let index = refreshIntervalPopup.indexOfSelectedItem
        if refreshOptions.indices.contains(index) {
            config.refreshIntervalSeconds = refreshOptions[index].seconds
        }
        onSave(config)
        // Reload the list but keep the account the user was editing selected -
        // reloadData clears the selection, which otherwise snaps back to row 0.
        table.reloadData()
        restoreSelection(id: selectedID, provider: nil)
        statusLabel.stringValue = "Saved."
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


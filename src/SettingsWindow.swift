import AppKit

final class SettingsWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    private var config: AppConfig
    /// Applies an edit to the app's live config (and this window's copy). Immediate
    /// apply means there's no unsaved state to lose, so nothing "resets".
    private let onChange: (@escaping (inout AppConfig) -> Void) -> Void
    /// Runs a check against GitHub, reporting progress back into `statusLabel`.
    private let onCheckForUpdates: (@escaping (String) -> Void) -> Void

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
    private let iconLabelField = NSTextField()
    private let iconLabelDefault = NSTextField(labelWithString: "")

    // Menu-bar layout controls.
    private let gridPicker = MenuBarGridPicker()
    private let gridLabel = NSTextField(labelWithString: "")
    private let orderPopup = NSPopUpButton()
    private let showIconLabels = NSButton(checkboxWithTitle: "Show a label on each app icon", target: nil, action: nil)
    private let previewImage = NSImageView()
    private let previewEmpty = NSTextField(labelWithString: "Nothing pinned yet")
    private let capacityHelp = NSTextField(labelWithString: "")
    private let showWeekly = NSButton(checkboxWithTitle: "Weekly %", target: nil, action: nil)
    private let resetTimesPopup = NSPopUpButton()
    private let arrangePopup = NSPopUpButton()

    private let accountPage = NSStackView()
    private let generalPage = NSStackView()
    private let pages = NSTabView()
    private let menuBarPage = NSStackView()
    private let showLabels = NSButton(checkboxWithTitle: "Show limit labels and percentages", target: nil, action: nil)
    private let showSession = NSButton(checkboxWithTitle: "Show session (5 hour) limit", target: nil, action: nil)
    private let showWeeklyLimits = NSButton(checkboxWithTitle: "Show weekly (7 day) limits", target: nil, action: nil)
    private let showResets = NSButton(checkboxWithTitle: "Show reset times", target: nil, action: nil)
    private let resetAlerts = NSPopUpButton()

    // App-wide (General) controls.
    private let launchAtLogin = NSButton(checkboxWithTitle: "Launch LLMCodeBar at login", target: nil, action: nil)
    private let refreshIntervalPopup = NSPopUpButton()
    private let showSparklines = NSButton(checkboxWithTitle: "Show 7-day trend sparklines", target: nil, action: nil)
    private let autoApproveCookies = NSButton(checkboxWithTitle: "Auto-approve cookie access", target: nil, action: nil)
    private let autoUpdate = NSButton(checkboxWithTitle: "Install updates automatically", target: nil, action: nil)
    private let routeClaudeLinks = NSButton(checkboxWithTitle: "Send Claude sign-in links to the right window", target: nil, action: nil)
    private let offerClaudeUpdates = NSButton(checkboxWithTitle: "Handle Claude's updates", target: nil, action: nil)
    private let checkForUpdatesButton = NSButton(title: "Check Now", target: nil, action: nil)

    private let statusLabel = NSTextField(labelWithString: "")

    private let refreshOptions: [(title: String, seconds: Int)] = [
        ("30 sec", 30), ("1 min", 60), ("2 min", 120), ("5 min", 300), ("10 min", 600), ("15 min", 900), ("30 min", 1800),
    ]

    init(config: AppConfig,
         onChange: @escaping (@escaping (inout AppConfig) -> Void) -> Void,
         onCheckForUpdates: @escaping (@escaping (String) -> Void) -> Void) {
        self.config = config
        self.onChange = onChange
        self.onCheckForUpdates = onCheckForUpdates
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 960, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false)
        window.title = "LLMCodeBar Settings"
        window.minSize = NSSize(width: 900, height: 580)
        window.center()
        super.init(window: window)
        buildUI()
        loadSelection()
        pages.selectTabViewItem(at: 0)
    }

    required init?(coder: NSCoder) { nil }

    // MARK: Account list

    func numberOfRows(in tableView: NSTableView) -> Int { config.profiles.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = NSTableCellView()
        let profile = config.profiles[row]
        let text = NSTextField(labelWithString: profile.label)
        text.translatesAutoresizingMaskIntoConstraints = false
        text.lineBreakMode = .byTruncatingTail
        text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        cell.addSubview(text)
        NSLayoutConstraint.activate([
            text.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
            text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        // Its place in the menu-bar grid, when it's pinned there.
        let pinned = config.showsPercentInMenuBar ? config.menuBarProfileIDList : []
        if let place = pinned.firstIndex(of: profile.id) {
            let badge = NSTextField(labelWithString: "\(place + 1)")
            badge.font = .systemFont(ofSize: 10, weight: .bold)
            badge.textColor = .controlAccentColor
            badge.alignment = .center
            badge.wantsLayer = true
            badge.layer?.cornerRadius = 8
            badge.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.15).cgColor
            badge.toolTip = "Place \(place + 1) in the menu bar"
            badge.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(badge)
            NSLayoutConstraint.activate([
                badge.widthAnchor.constraint(equalToConstant: 16),
                badge.heightAnchor.constraint(equalToConstant: 16),
                badge.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
                badge.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                text.trailingAnchor.constraint(lessThanOrEqualTo: badge.leadingAnchor, constant: -6),
            ])
        } else {
            text.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -8).isActive = true
        }
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) { loadSelection(); pages.selectTabViewItem(at: 2) }

    // MARK: Immediate apply

    /// Picks up a change made outside this window (the menu's account switches), so the
    /// checkboxes don't show a stale state.
    func syncConfig(_ newConfig: AppConfig) {
        config.menuBarProfileIDs = newConfig.menuBarProfileIDs
        config.menuBarProfileID = newConfig.menuBarProfileID
        config.showPercentInMenuBar = newConfig.showPercentInMenuBar
        let id = selectedID
        table.reloadData()
        if let id { restoreSelection(id: id) }
        loadSelection()
        refreshMenuBarSection()
    }

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
        addAccountButton.toolTip = "Add a Claude or ChatGPT account"
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

        // Each destination owns a complete page; account selection opens Account.
        pages.translatesAutoresizingMaskIntoConstraints = false
        for (title, page) in [("General", generalPage), ("Menu bar", menuBarPage), ("Account", accountPage)] {
            page.orientation = .vertical
            page.alignment = .leading
            page.spacing = 12
            page.translatesAutoresizingMaskIntoConstraints = false
            let item = NSTabViewItem(identifier: title)
            item.label = title
            let scroll = NSScrollView()
            scroll.hasVerticalScroller = true
            scroll.drawsBackground = false
            let document = FlippedView()
            document.translatesAutoresizingMaskIntoConstraints = false
            document.addSubview(page)
            scroll.documentView = document
            item.view = scroll
            pages.addTabViewItem(item)
            NSLayoutConstraint.activate([
                document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
                page.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 20),
                page.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -20),
                page.topAnchor.constraint(equalTo: document.topAnchor, constant: 20),
                page.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -20),
            ])
        }
        buildGeneralSection(into: generalPage)
        buildMenuBarSection(into: menuBarPage)
        buildAccountSection(into: accountPage)

        statusLabel.textColor = .secondaryLabelColor
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(leftPane)
        content.addSubview(pages)
        content.addSubview(statusLabel)
        NSLayoutConstraint.activate([
            leftPane.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            leftPane.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            leftPane.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
            leftPane.widthAnchor.constraint(equalToConstant: 220),
            pages.leadingAnchor.constraint(equalTo: leftPane.trailingAnchor, constant: 20),
            pages.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            pages.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            pages.bottomAnchor.constraint(equalTo: statusLabel.topAnchor, constant: -12),
            statusLabel.leadingAnchor.constraint(equalTo: pages.leadingAnchor, constant: 8),
            statusLabel.trailingAnchor.constraint(equalTo: pages.trailingAnchor, constant: -8),
            statusLabel.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
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
        menuBarAccount.toolTip = "Show this account's 5h session % in the menu bar, with its app icon. How many fit, and how they're laid out, is set on the Menu bar page."

        iconLabelField.delegate = self
        iconLabelField.placeholderString = ""
        iconLabelField.toolTip = "Up to 3 characters, drawn on this account's app icon in the menu bar when \"Show a label on each app icon\" is on. Leave it empty for the first 2 characters of the email."
        iconLabelField.widthAnchor.constraint(equalToConstant: 56).isActive = true
        iconLabelDefault.font = .systemFont(ofSize: 11)
        iconLabelDefault.textColor = .tertiaryLabelColor
        let iconLabelRow = NSStackView(views: [NSTextField(labelWithString: "Icon label"), iconLabelField, iconLabelDefault])
        iconLabelRow.orientation = .horizontal
        iconLabelRow.spacing = 8

        autoStartSession.target = self
        autoStartSession.action = #selector(autoStartChanged)
        autoStartSession.toolTip = "When the 5h window is idle or has reset, LLMCodeBar sends one tiny \"hi\" on the cheapest model to start it. For Claude it uses a throwaway chat that's deleted after. Only fires when the session isn't already running. ChatGPT is experimental."
        startSessionNow.target = self
        startSessionNow.action = #selector(startSessionNowTapped)
        startSessionNow.bezelStyle = .rounded
        let autoStartRow = NSStackView(views: [autoStartSession, startSessionNow])
        autoStartRow.orientation = .horizontal
        autoStartRow.spacing = 10

        let autoStartHelp = helpLabel("Starts the 5h window when it's idle by sending a tiny \"hi\" on the cheapest model. Only acts when the session isn't already running. ChatGPT is experimental.")

        // Advanced (label / paths), collapsed.
        advancedStack.orientation = .vertical
        advancedStack.spacing = 8
        providerPopup.addItems(withTitles: Provider.allCases.map(\.displayName))
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
        form.addArrangedSubview(sectionHeading("Menu bar identity"))
        form.addArrangedSubview(menuBarAccount)
        form.addArrangedSubview(iconLabelRow)
        form.addArrangedSubview(sectionHeading("Usage display"))
        for control in [showSparklines, showLabels, showSession, showWeeklyLimits, showResets] {
            control.target = self
            control.action = #selector(displayChanged)
            form.addArrangedSubview(control)
        }
        resetAlerts.addItems(withTitles: ["Off", "5 minutes before", "15 minutes before", "30 minutes before", "1 hour before"])
        resetAlerts.target = self
        resetAlerts.action = #selector(displayChanged)
        let alertRow = NSStackView(views: [NSTextField(labelWithString: "Reset reminder"), resetAlerts])
        alertRow.spacing = 8
        form.addArrangedSubview(sectionHeading("Reset reminders"))
        form.addArrangedSubview(alertRow)
        form.addArrangedSubview(sectionHeading("Session start"))
        form.addArrangedSubview(autoStartRow)
        form.addArrangedSubview(autoStartHelp)
        form.addArrangedSubview(advancedHeader)
        form.addArrangedSubview(advancedStack)
    }

    private func buildMenuBarSection(into form: NSStackView) {
        let title = NSTextField(labelWithString: "Menu bar")
        title.font = .systemFont(ofSize: 13, weight: .semibold)

        gridPicker.toolTip = "How many rows and columns of accounts the menu bar shows, up to 3 by 3."
        gridPicker.onHover = { [weak self] size in self?.showGridLabel(size) }
        gridPicker.onPick = { [weak self] rows, columns in self?.gridPicked(rows: rows, columns: columns) }
        gridLabel.font = .systemFont(ofSize: 11)
        gridLabel.textColor = .secondaryLabelColor
        orderPopup.addItems(withTitles: ["Down each column, then the next column", "Along the top row, then the next row"])
        orderPopup.target = self
        orderPopup.action = #selector(orderChanged)
        orderPopup.toolTip = "Which way the pinned accounts fill the grid, in the order you pinned them."
        capacityHelp.font = .systemFont(ofSize: 10.5)
        capacityHelp.textColor = .tertiaryLabelColor
        // The size, the fill order and the capacity sit beside the picker to keep the
        // window short enough for a laptop screen.
        let gridSide = NSStackView(views: [gridLabel, orderPopup, capacityHelp])
        gridSide.orientation = .vertical
        gridSide.alignment = .leading
        gridSide.spacing = 5
        let layoutLabel = NSTextField(labelWithString: "Layout")
        let layoutRow = NSStackView(views: [layoutLabel, gridPicker, gridSide])
        layoutRow.orientation = .horizontal
        layoutRow.alignment = .top
        layoutRow.spacing = 8

        showWeekly.target = self
        showWeekly.action = #selector(oneRowDetailsChanged)
        showWeekly.toolTip = "Also show each account's weekly usage %."
        resetTimesPopup.addItems(withTitles: MenuBarResetTimes.allCases.map(\.title))
        resetTimesPopup.target = self
        resetTimesPopup.action = #selector(oneRowDetailsChanged)
        resetTimesPopup.toolTip = "How long until the 5h and weekly limits reset, in one unit: 3d, then 4h, then 7m."
        arrangePopup.addItems(withTitles: ["Stacked: 5h above weekly", "Side by side"])
        arrangePopup.target = self
        arrangePopup.action = #selector(oneRowDetailsChanged)
        let oneRowRow = NSStackView(views: [NSTextField(labelWithString: "On one row"), showWeekly,
                                            NSTextField(labelWithString: "Time to reset"), resetTimesPopup])
        oneRowRow.orientation = .horizontal
        oneRowRow.spacing = 8
        oneRowRow.setCustomSpacing(16, after: showWeekly)
        let arrangeRow = NSStackView(views: [NSTextField(labelWithString: "Arrange"), arrangePopup])
        arrangeRow.orientation = .horizontal
        arrangeRow.spacing = 8
        let oneRowHelp = helpLabel("When the accounts fit on one row (a 1-row layout, or one account pinned). With 2 or 3 rows only the 5h % fits.")

        showIconLabels.target = self
        showIconLabels.action = #selector(showIconLabelsChanged)
        showIconLabels.toolTip = "Draws a short label (set on the Account page) on each app icon in the menu bar, so two accounts of the same app can be told apart."
        let labelsHelp = helpLabel("Each account's label is set on its Account page. Left empty, it's the first 2 characters of the email.")

        previewImage.imageScaling = .scaleNone
        previewEmpty.font = .systemFont(ofSize: 11)
        previewEmpty.textColor = .tertiaryLabelColor
        let previewBox = AppearanceAwareStack(views: [previewImage, previewEmpty])
        previewBox.orientation = .horizontal
        previewBox.edgeInsets = NSEdgeInsets(top: 3, left: 8, bottom: 3, right: 8)
        previewBox.heightAnchor.constraint(equalToConstant: 28).isActive = true
        let previewRow = NSStackView(views: [NSTextField(labelWithString: "Preview"), previewBox])
        previewRow.orientation = .horizontal
        previewRow.spacing = 8

        form.addArrangedSubview(title)
        form.addArrangedSubview(layoutRow)
        form.addArrangedSubview(oneRowRow)
        form.addArrangedSubview(arrangeRow)
        form.addArrangedSubview(oneRowHelp)
        form.addArrangedSubview(showIconLabels)
        form.addArrangedSubview(labelsHelp)
        form.addArrangedSubview(previewRow)
        refreshMenuBarSection()
    }

    /// Puts the menu-bar section in step with `config`.
    private func refreshMenuBarSection() {
        gridPicker.rows = config.menuBarGridRows
        gridPicker.columns = config.menuBarGridColumns
        showGridLabel(nil)
        orderPopup.selectItem(at: config.fillsMenuBarRowsFirst ? 1 : 0)
        orderPopup.isEnabled = config.menuBarGridRows > 1 && config.menuBarGridColumns > 1
        showIconLabels.state = config.showsMenuBarLabels ? .on : .off
        iconLabelField.isEnabled = selectedID != nil && config.showsMenuBarLabels
        showWeekly.state = config.showsMenuBarWeekly ? .on : .off
        resetTimesPopup.selectItem(at: MenuBarResetTimes.allCases.firstIndex(of: config.menuBarResets) ?? 0)
        arrangePopup.selectItem(at: config.menuBarDetailsSideBySide ? 1 : 0)
        // Stacked or side by side only matters when there's a weekly line to place.
        arrangePopup.isEnabled = config.showsMenuBarWeekly || config.menuBarResets.showsWeekly
        let capacity = config.menuBarCapacity
        capacityHelp.stringValue = capacity == 1
            ? "Pinning another account replaces it."
            : "When full, pinning another unpins the oldest."
        let image = config.showsPercentInMenuBar ? MenuBarBadge.image(for: config) : nil
        previewImage.image = image
        previewImage.isHidden = image == nil
        previewEmpty.isHidden = image != nil
    }

    private func showGridLabel(_ size: (rows: Int, columns: Int)?) {
        let rows = size?.rows ?? config.menuBarGridRows
        let columns = size?.columns ?? config.menuBarGridColumns
        let count = rows * columns
        gridLabel.stringValue = "\(rows) row\(rows == 1 ? "" : "s") × \(columns) column\(columns == 1 ? "" : "s") · up to \(count) account\(count == 1 ? "" : "s")"
            + (size == nil ? "" : " (click to use)")
    }

    private func gridPicked(rows: Int, columns: Int) {
        var unpinned: [String] = []
        commit { cfg in unpinned = cfg.setMenuBarGrid(rows: rows, columns: columns) }
        reloadAccountList()
        refreshMenuBarSection()
        statusLabel.stringValue = unpinned.isEmpty ? "" :
            "Unpinned \(names(unpinned)) from the menu bar: \(unpinned.count == 1 ? "it no longer fits" : "they no longer fit") in \(rows) × \(columns)."
    }

    @objc private func orderChanged() {
        let rowsFirst = orderPopup.indexOfSelectedItem == 1
        commit { cfg in cfg.menuBarFillRowsFirst = rowsFirst }
        refreshMenuBarSection()
    }

    @objc private func oneRowDetailsChanged() {
        let weekly = showWeekly.state == .on
        let resets = MenuBarResetTimes.allCases[max(0, resetTimesPopup.indexOfSelectedItem)]
        let sideBySide = arrangePopup.indexOfSelectedItem == 1
        commit { cfg in
            cfg.menuBarShowWeekly = weekly
            cfg.menuBarResetTimes = resets
            cfg.menuBarSideBySide = sideBySide
        }
        refreshMenuBarSection()
    }

    @objc private func showIconLabelsChanged() {
        let on = showIconLabels.state == .on
        commit { cfg in cfg.showMenuBarLabels = on }
        refreshMenuBarSection()
    }

    private func names(_ ids: [String]) -> String {
        ids.compactMap { id in config.profiles.first { $0.id == id }?.label }.joined(separator: " and ")
    }

    /// Redraws the account list (its menu-bar place numbers) keeping the selection.
    private func reloadAccountList() {
        let id = selectedID
        table.reloadData()
        if let id { restoreSelection(id: id) }
    }

    private func buildGeneralSection(into form: NSStackView) {
        let title = NSTextField(labelWithString: "General")
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.toolTip = "Applies to LLMCodeBar, not to any single account."

        launchAtLogin.state = (config.launchAtLogin || AutostartManager.isEnabled) ? .on : .off
        launchAtLogin.toolTip = "Start LLMCodeBar itself when you log in to your Mac. (Not the Claude or ChatGPT apps.)"
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

        autoApproveCookies.state = config.allowsCookieKeychain ? .on : .off
        autoApproveCookies.toolTip = "Reads the encrypted cookie store for live usage. macOS asks to approve keychain access once (click \"Always Allow\"). Uncheck to never prompt; usage then updates only while Claude/ChatGPT is open."
        autoApproveCookies.target = self
        autoApproveCookies.action = #selector(cookiesChanged)
        let cookiesHelp = helpLabel("Approve the keychain once (\"Always Allow\") instead of every launch. Uncheck to never prompt.")

        autoUpdate.state = config.autoUpdates ? .on : .off
        autoUpdate.toolTip = "Download new releases in the background and restart LLMCodeBar to apply them. Turn off to be offered the update in the menu instead."
        autoUpdate.target = self
        autoUpdate.action = #selector(autoUpdateChanged)

        routeClaudeLinks.state = config.routesClaudeLinks ? .on : .off
        routeClaudeLinks.toolTip = "Holds the claude:// link type so a sign-in returns to the window that started it. With two Claude windows open, macOS otherwise hands the sign-in to whichever it likes and it silently fails."
        routeClaudeLinks.target = self
        routeClaudeLinks.action = #selector(routeClaudeLinksChanged)
        let routeHelp = helpLabel("Claude then signs in inside its own window instead of sending you to the browser.")

        offerClaudeUpdates.state = config.offersClaudeUpdates ? .on : .off
        offerClaudeUpdates.toolTip = "Claude installs an update by quitting a window once it's been idle for a while, and with more than one window open the install can't start, so that window just stays closed. With this on, LLMCodeBar opens it again straight away and offers a close-install-reopen that actually lands the update."
        offerClaudeUpdates.target = self
        offerClaudeUpdates.action = #selector(offerClaudeUpdatesChanged)
        let claudeUpdateHelp = helpLabel("A window Claude closes for an update comes straight back, and nothing closes without your click.")

        let versionLabel = NSTextField(labelWithString: "Version \(Updater.currentVersion)")
        versionLabel.textColor = .secondaryLabelColor
        checkForUpdatesButton.bezelStyle = .rounded
        checkForUpdatesButton.controlSize = .small
        checkForUpdatesButton.target = self
        checkForUpdatesButton.action = #selector(checkForUpdatesNow)
        let versionRow = NSStackView(views: [versionLabel, checkForUpdatesButton])
        versionRow.orientation = .horizontal
        versionRow.spacing = 8

        form.addArrangedSubview(title)
        form.addArrangedSubview(launchAtLogin)
        form.addArrangedSubview(refreshRow)
        form.addArrangedSubview(sectionHeading("Account access"))
        form.addArrangedSubview(autoApproveCookies)
        form.addArrangedSubview(cookiesHelp)
        form.addArrangedSubview(sectionHeading("Updates"))
        form.addArrangedSubview(autoUpdate)
        form.addArrangedSubview(sectionHeading("Claude windows"))
        form.addArrangedSubview(routeClaudeLinks)
        form.addArrangedSubview(routeHelp)
        form.addArrangedSubview(offerClaudeUpdates)
        form.addArrangedSubview(claudeUpdateHelp)
        form.addArrangedSubview(versionRow)
    }

    private func sectionHeading(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 12, weight: .semibold)
        label.textColor = .secondaryLabelColor
        return label
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
        showSparklines.state = (profile.showSparklines ?? config.showsSparklines) ? .on : .off
        showLabels.state = (profile.showLabels ?? true) ? .on : .off
        showSession.state = (profile.showSessionWindow ?? true) ? .on : .off
        showWeeklyLimits.state = (profile.showWeeklyWindows ?? true) ? .on : .off
        showResets.state = (profile.showResetTimes ?? true) ? .on : .off
        resetAlerts.selectItem(at: [0, 5, 15, 30, 60].firstIndex(of: profile.resetAlertMinutes ?? 0) ?? 0)
        let accountControls = [showSparklines, showLabels, showSession, showWeeklyLimits, showResets, resetAlerts, menuBarAccount, autoStartSession, startSessionNow, removeButton, advancedToggle, providerPopup, labelField, appPathField, dataDirField]
        accountControls.forEach { $0.isEnabled = true }

        labelField.stringValue = profile.label
        providerPopup.selectItem(withTitle: profile.provider.displayName)
        appPathField.stringValue = profile.appPath
        dataDirField.stringValue = profile.dataDir

        menuBarAccount.state = (config.menuBarProfileIDList.contains(profile.id) && config.showsPercentInMenuBar) ? .on : .off
        iconLabelField.stringValue = profile.menuBarLabel ?? ""
        iconLabelField.placeholderString = profile.defaultMenuBarLabel
        iconLabelField.isEnabled = config.showsMenuBarLabels
        iconLabelDefault.stringValue = config.showsMenuBarLabels
            ? (profile.defaultMenuBarLabel.isEmpty ? "No email yet" : "Empty = \(profile.defaultMenuBarLabel), the first 2 characters of the email")
            : "Turn on \"Show a label on each app icon\" below to use it"

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
            accountSubtitle.stringValue = [profile.provider.displayName, profile.usage?.accountPlan ?? profile.accountPlan]
                .compactMap { $0 }.joined(separator: "  ·  ")
        }
        statusLabel.stringValue = ""
    }

    private func clearAccountSection() {
        accountTitle.stringValue = "No account selected"
        accountSubtitle.stringValue = "Add one with the + button"
        [showSparklines, showLabels, showSession, showWeeklyLimits, showResets, resetAlerts, menuBarAccount, autoStartSession, startSessionNow, removeButton, advancedToggle, providerPopup, labelField, appPathField, dataDirField, iconLabelField].forEach { $0.isEnabled = false }
        menuBarAccount.state = .off
        iconLabelField.stringValue = ""
        iconLabelDefault.stringValue = ""
        autoStartSession.state = .off
    }

    @objc private func displayChanged() {
        guard let id = selectedID else { return }
        let values = [showSparklines, showLabels, showSession, showWeeklyLimits, showResets].map { $0.state == .on }
        let minutes = [0, 5, 15, 30, 60][max(0, resetAlerts.indexOfSelectedItem)]
        commit { cfg in
            guard let i = cfg.profiles.firstIndex(where: { $0.id == id }) else { return }
            cfg.profiles[i].showSparklines = values[0]
            cfg.profiles[i].showLabels = values[1]
            cfg.profiles[i].showSessionWindow = values[2]
            cfg.profiles[i].showWeeklyWindows = values[3]
            cfg.profiles[i].showResetTimes = values[4]
            cfg.profiles[i].resetAlertMinutes = minutes
        }
        if minutes > 0 { ResetReminder.requestAuthorization(profiles: config.profiles) }
    }

    // MARK: Account actions

    @objc private func menuBarAccountChanged() {
        guard let id = selectedID else { return }
        let on = menuBarAccount.state == .on
        var bumped: [String] = []
        commit { cfg in bumped = cfg.setMenuBar(id, shown: on) }
        reloadAccountList()
        refreshMenuBarSection()
        statusLabel.stringValue = bumped.isEmpty ? "" :
            "Unpinned \(names(bumped)) to make room: the menu bar holds \(config.menuBarCapacity)."
    }

    /// Keeps the icon label to 3 characters and applies it as it's typed.
    func controlTextDidChange(_ notification: Notification) {
        guard (notification.object as? NSTextField) === iconLabelField, let id = selectedID else { return }
        if iconLabelField.stringValue.count > 3 {
            iconLabelField.stringValue = String(iconLabelField.stringValue.prefix(3))
        }
        let text = iconLabelField.stringValue.trimmingCharacters(in: .whitespaces)
        commit { cfg in
            if let i = cfg.profiles.firstIndex(where: { $0.id == id }) {
                cfg.profiles[i].menuBarLabel = text.isEmpty ? nil : text
            }
        }
        refreshMenuBarSection()
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
        let provider = Provider.named(providerPopup.titleOfSelectedItem ?? "Claude") ?? .claude
        commit { cfg in
            if let i = cfg.profiles.firstIndex(where: { $0.id == id }) { cfg.profiles[i].provider = provider }
        }
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard let id = selectedID, let field = notification.object as? NSTextField else { return }
        if field === iconLabelField { return }
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
        alert.informativeText = "This just takes the account off this list. Your Claude/ChatGPT login and its data are not touched, and you can add it back with Rescan."
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
        picker.addItems(withTitles: Provider.allCases.map(\.displayName))
        alert.accessoryView = picker
        guard alert.runModal() == .alertFirstButtonReturn,
              let provider = Provider.named(picker.titleOfSelectedItem ?? "") else { return }

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

    @objc private func cookiesChanged() {
        let on = autoApproveCookies.state == .on
        commit { $0.autoApproveCookieAccess = on }
    }

    @objc private func offerClaudeUpdatesChanged() {
        let on = offerClaudeUpdates.state == .on
        commit { $0.offerClaudeUpdates = on }
    }

    @objc private func autoUpdateChanged() {
        let on = autoUpdate.state == .on
        commit { $0.autoUpdate = on }
    }

    @objc private func routeClaudeLinksChanged() {
        let on = routeClaudeLinks.state == .on
        commit { $0.routeClaudeLinks = on }
        // Hand the link type over (or back) straight away rather than at the next refresh.
        if on {
            ClaudeLinkRouter.claimScheme()
        } else {
            ClaudeLinkRouter.releaseScheme()
        }
    }

    @objc private func checkForUpdatesNow() {
        checkForUpdatesButton.isEnabled = false
        onCheckForUpdates { [weak self] message in
            guard let self else { return }
            self.statusLabel.stringValue = message
            self.checkForUpdatesButton.isEnabled = true
        }
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

/// A rounded, bordered box whose layer colors follow light/dark mode (a layer's
/// CGColor is fixed when set, so it's re-resolved whenever the appearance changes).
final class AppearanceAwareStack: NSStackView {
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyColors()
    }

    private func applyColors() {
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.borderWidth = 1
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.borderColor = NSColor.separatorColor.cgColor
            layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        }
    }
}

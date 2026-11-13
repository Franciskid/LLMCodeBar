import AppKit
import UserNotifications

final class SettingsWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate, NSWindowDelegate {
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

    private let generalNavigation = SettingsNavigationButton(title: "General", target: nil, action: nil)
    private let menuBarNavigation = SettingsNavigationButton(title: "Menu bar", target: nil, action: nil)
    private let accountPicker = NSSegmentedControl(labels: ["Display", "Sessions", "Advanced"], trackingMode: .selectOne, target: nil, action: nil)
    private let accountSections = NSTabView()
    private var accountSectionHeight: NSLayoutConstraint?
    private let displayPage = NSStackView()
    private let sessionsPage = NSStackView()
    private let manualInventory = NSStackView()
    private let notificationStatus = NSTextField(labelWithString: "")
    private let accountNotificationStatus = NSTextField(labelWithString: "")
    private let accountPage = NSStackView()
    private let generalPage = NSStackView()
    private let pages = NSTabView()
    private let menuBarPage = NSStackView()
    private let showLabels = NSButton(checkboxWithTitle: "Show limit labels and percentages", target: nil, action: nil)
    private let showSession = NSButton(checkboxWithTitle: "Show session (5 hour) limit", target: nil, action: nil)
    private let showWeeklyLimits = NSButton(checkboxWithTitle: "Show weekly (7 day) limits", target: nil, action: nil)
    private let showResets = NSButton(checkboxWithTitle: "Show automatic reset times", target: nil, action: nil)
    private let resetAlerts = NSPopUpButton()
    private let showManualResets = NSButton(checkboxWithTitle: "Show available manual resets and their expiry", target: nil, action: nil)

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
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 650),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false)
        window.title = "LLMCodeBar Settings"
        window.minSize = NSSize(width: 760, height: 600)
        window.center()
        super.init(window: window)
        buildUI()
        window.delegate = self
        loadSelection()
        navigate(to: 0)
    }

    required init?(coder: NSCoder) { nil }

    func windowDidBecomeKey(_ notification: Notification) { refreshNotificationPermission() }

    // MARK: Account list

    func numberOfRows(in tableView: NSTableView) -> Int { config.profiles.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let profile = config.profiles[row]
        let cell = NSTableCellView()
        let icon = NSImageView(image: NSWorkspace.shared.icon(forFile: Launcher.expanding(profile.appPath)))
        let title = NSTextField(labelWithString: "\(profile.provider.displayName) · \(profile.menuBarLabelText)")
        title.font = .systemFont(ofSize: 12, weight: .medium)
        let subtitle = NSTextField(labelWithString: profile.accountEmail?.components(separatedBy: "@").first ?? profile.accountName ?? "Connect account")
        subtitle.font = .systemFont(ofSize: 10)
        subtitle.textColor = .secondaryLabelColor
        subtitle.lineBreakMode = .byTruncatingMiddle
        let text = NSStackView(views: [title, subtitle])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 2
        for view in [icon, text] { view.translatesAutoresizingMaskIntoConstraints = false; cell.addSubview(view) }
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 5),
            icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 22), icon.heightAnchor.constraint(equalToConstant: 22),
            text.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
            text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -5),
            text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            subtitle.widthAnchor.constraint(lessThanOrEqualTo: text.widthAnchor),
        ])
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        loadSelection()
        if table.selectedRow >= 0 { navigate(to: 2) }
    }

    private func navigate(to index: Int) {
        pages.selectTabViewItem(at: index)
        generalNavigation.state = index == 0 ? .on : .off
        menuBarNavigation.state = index == 1 ? .on : .off
        for button in [generalNavigation, menuBarNavigation] {
            button.contentTintColor = button.state == .on ? .controlAccentColor : .labelColor
        }
        if index != 2 { table.deselectAll(nil) }
        refreshNotificationPermission()
    }

    @objc private func showGeneral() { navigate(to: 0) }
    @objc private func showMenuBar() { navigate(to: 1) }
    @objc private func accountSectionChanged() {
        accountSections.selectTabViewItem(at: max(0, accountPicker.selectedSegment))
        resizeAccountSection()
    }

    private func resizeAccountSection() {
        let page = [displayPage, sessionsPage, advancedStack][max(0, accountPicker.selectedSegment)]
        accountSectionHeight?.constant = max(220, page.fittingSize.height + 5)
    }

    // MARK: Immediate apply

    /// Picks up a change made outside this window (the menu's account switches), so the
    /// checkboxes don't show a stale state.
    func syncConfig(_ newConfig: AppConfig) {
        config.menuBarProfileIDs = newConfig.menuBarProfileIDs
        config.menuBarProfileID = newConfig.menuBarProfileID
        config.showPercentInMenuBar = newConfig.showPercentInMenuBar
        let index = pages.indexOfTabViewItem(pages.selectedTabViewItem!)
        let id = selectedID
        table.reloadData()
        if let id { restoreSelection(id: id) }
        loadSelection()
        refreshMenuBarSection()
        navigate(to: index)
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
        let sidebar = NSVisualEffectView()
        sidebar.material = .sidebar
        sidebar.blendingMode = .behindWindow
        sidebar.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(sidebar)
        for (button, selector) in [(generalNavigation, #selector(showGeneral)), (menuBarNavigation, #selector(showMenuBar))] {
            button.target = self; button.action = selector
            button.setButtonType(.toggle)
            button.bezelStyle = .recessed
            button.alignment = .left
            button.font = .systemFont(ofSize: 12, weight: .medium)
        }
        let caption = sectionHeading("Accounts")
        table.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("profile")))
        table.headerView = nil
        table.delegate = self; table.dataSource = self
        table.rowHeight = 46
        table.style = .sourceList
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.documentView = table
        let add = NSButton(title: "+ Add", target: self, action: #selector(addAccount))
        let rescan = NSButton(title: "Rescan", target: self, action: #selector(rescanAccounts))
        for button in [add, rescan] { button.bezelStyle = .rounded; button.controlSize = .small }
        let footer = NSStackView(views: [add, rescan]); footer.spacing = 6
        let navigation = NSStackView(views: [generalNavigation, menuBarNavigation, caption, scroll, footer])
        navigation.orientation = .vertical; navigation.alignment = .leading; navigation.spacing = 6
        navigation.setCustomSpacing(22, after: menuBarNavigation)
        navigation.translatesAutoresizingMaskIntoConstraints = false
        sidebar.addSubview(navigation)
        for view in [generalNavigation, menuBarNavigation, scroll] {
            view.widthAnchor.constraint(equalTo: navigation.widthAnchor).isActive = true
        }
        pages.tabViewType = .noTabsNoBorder
        pages.translatesAutoresizingMaskIntoConstraints = false
        for (title, page) in [("General", generalPage), ("Menu bar", menuBarPage), ("Account", accountPage)] {
            configure(page)
            let item = NSTabViewItem(identifier: title); item.label = title
            let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.drawsBackground = false
            let document = FlippedView(); document.translatesAutoresizingMaskIntoConstraints = false
            document.addSubview(page); scroll.documentView = document; item.view = scroll
            pages.addTabViewItem(item)
            NSLayoutConstraint.activate([
                document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
                page.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 26),
                page.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -26),
                page.topAnchor.constraint(equalTo: document.topAnchor, constant: 24),
                page.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -20),
            ])
        }
        buildGeneralSection(into: generalPage)
        buildMenuBarSection(into: menuBarPage)
        buildAccountSection(into: accountPage)
        statusLabel.textColor = .secondaryLabelColor; statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(pages); content.addSubview(statusLabel)
        NSLayoutConstraint.activate([
            sidebar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            sidebar.topAnchor.constraint(equalTo: content.topAnchor),
            sidebar.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            sidebar.widthAnchor.constraint(equalToConstant: 190),
            navigation.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 12),
            navigation.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -12),
            navigation.topAnchor.constraint(equalTo: sidebar.topAnchor, constant: 18),
            navigation.bottomAnchor.constraint(equalTo: sidebar.bottomAnchor, constant: -18),
            pages.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            pages.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            pages.topAnchor.constraint(equalTo: content.topAnchor),
            pages.bottomAnchor.constraint(equalTo: statusLabel.topAnchor, constant: -4),
            statusLabel.leadingAnchor.constraint(equalTo: pages.leadingAnchor, constant: 26),
            statusLabel.trailingAnchor.constraint(equalTo: pages.trailingAnchor, constant: -26),
            statusLabel.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -10),
        ])
        if !config.profiles.isEmpty { table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false) }
    }

    private func configure(_ stack: NSStackView) {
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
    }

    private func heading(_ title: String, subtitle: String, into form: NSStackView) {
        let label = NSTextField(labelWithString: title); label.font = .systemFont(ofSize: 22, weight: .semibold)
        form.addArrangedSubview(label); form.setCustomSpacing(5, after: label)
        let detail = helpLabel(subtitle); form.addArrangedSubview(detail); form.setCustomSpacing(18, after: detail)
    }

    private func preference(_ title: String, control: NSView, into form: NSStackView, id: String? = nil) {
        if let id { control.identifier = NSUserInterfaceItemIdentifier(id) }
        if let button = control as? NSButton,
           [menuBarAccount, autoStartSession, showIconLabels, showWeekly, showLabels, showSession, showWeeklyLimits, showResets, showManualResets, launchAtLogin, showSparklines, autoApproveCookies, autoUpdate, routeClaudeLinks, offerClaudeUpdates].contains(where: { $0 === button }) {
            button.title = ""; button.setAccessibilityLabel(title)
        }
        let label = NSTextField(labelWithString: title); label.font = .systemFont(ofSize: 12)
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let spacer = NSView()
        let row = NSStackView(views: [label, spacer, control]); row.spacing = 12; row.alignment = .centerY
        control.setContentHuggingPriority(.required, for: .horizontal)
        control.setContentCompressionResistancePriority(.required, for: .horizontal)
        row.edgeInsets = NSEdgeInsets(top: 8, left: 0, bottom: 8, right: 0)
        form.addArrangedSubview(row)
        row.widthAnchor.constraint(equalTo: form.widthAnchor).isActive = true
        let line = NSBox(); line.boxType = .separator
        form.addArrangedSubview(line); line.widthAnchor.constraint(equalTo: form.widthAnchor).isActive = true
    }

    private func section(_ title: String, into form: NSStackView) {
        let container = FlippedView()
        let label = sectionHeading(title); label.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(label); form.addArrangedSubview(container)
        NSLayoutConstraint.activate([
            container.widthAnchor.constraint(equalTo: form.widthAnchor), container.heightAnchor.constraint(equalToConstant: 32),
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor), label.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -3),
        ])
    }

    private func buildAccountSection(into form: NSStackView) {
        accountTitle.font = .systemFont(ofSize: 22, weight: .semibold)
        accountSubtitle.font = .systemFont(ofSize: 11); accountSubtitle.textColor = .secondaryLabelColor
        form.addArrangedSubview(accountTitle); form.setCustomSpacing(5, after: accountTitle)
        form.addArrangedSubview(accountSubtitle); form.setCustomSpacing(18, after: accountSubtitle)
        accountPicker.selectedSegment = 0; accountPicker.target = self; accountPicker.action = #selector(accountSectionChanged)
        accountPicker.segmentStyle = .rounded
        form.addArrangedSubview(accountPicker); form.setCustomSpacing(14, after: accountPicker)
        accountPicker.widthAnchor.constraint(equalTo: form.widthAnchor).isActive = true
        accountSections.tabViewType = .noTabsNoBorder
        for (title, page) in [("Display", displayPage), ("Sessions", sessionsPage), ("Advanced", advancedStack)] {
            configure(page)
            let item = NSTabViewItem(identifier: title); item.label = title
            let container = FlippedView(); container.addSubview(page); item.view = container
            NSLayoutConstraint.activate([
                page.leadingAnchor.constraint(equalTo: container.leadingAnchor), page.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                page.topAnchor.constraint(equalTo: container.topAnchor),
                page.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor),
            ])
            accountSections.addTabViewItem(item)
        }
        accountSections.translatesAutoresizingMaskIntoConstraints = false
        form.addArrangedSubview(accountSections)
        accountSections.widthAnchor.constraint(equalTo: form.widthAnchor).isActive = true
        accountSectionHeight = accountSections.heightAnchor.constraint(equalToConstant: 470)
        accountSectionHeight?.isActive = true
        menuBarAccount.target = self; menuBarAccount.action = #selector(menuBarAccountChanged)
        preference("Pin in menu bar", control: menuBarAccount, into: displayPage, id: "menuBarAccount")
        iconLabelField.delegate = self
        iconLabelField.widthAnchor.constraint(equalToConstant: 56).isActive = true
        iconLabelField.toolTip = "Up to 3 characters. Leave empty for the first two characters of the email."
        preference("Icon label", control: iconLabelField, into: displayPage, id: "iconLabel")
        for (title, control, id) in [("Session bar", showSession, "showSession"), ("Weekly bar", showWeeklyLimits, "showWeeklyLimits"),
                                      ("Trendlines", showSparklines, "showSparklines"), ("Labels", showLabels, "showLabels"),
                                      ("Automatic reset times", showResets, "showResets")] {
            control.target = self; control.action = #selector(displayChanged(_:))
            preference(title, control: control, into: displayPage, id: id)
        }
        section("Manual resets", into: displayPage)
        showManualResets.target = self; showManualResets.action = #selector(displayChanged(_:))
        preference("Show in menu", control: showManualResets, into: displayPage, id: "showManualResets")
        configure(manualInventory); manualInventory.spacing = 4
        displayPage.addArrangedSubview(manualInventory)
        manualInventory.widthAnchor.constraint(equalTo: displayPage.widthAnchor).isActive = true
        resetAlerts.addItems(withTitles: ["Off", "1 hour before", "6 hours before", "24 hours before", "3 days before"])
        resetAlerts.target = self; resetAlerts.action = #selector(displayChanged(_:))
        resetAlerts.toolTip = "Notify before an unused manual reset reaches its redemption deadline."
        preference("Expiry notification", control: resetAlerts, into: displayPage, id: "resetAlerts")
        accountNotificationStatus.font = .systemFont(ofSize: 10); accountNotificationStatus.textColor = .secondaryLabelColor
        displayPage.addArrangedSubview(accountNotificationStatus)

        autoStartSession.target = self; autoStartSession.action = #selector(autoStartChanged)
        preference("Auto-start 5h session", control: autoStartSession, into: sessionsPage, id: "autoStartSession")
        startSessionNow.target = self; startSessionNow.action = #selector(startSessionNowTapped); startSessionNow.bezelStyle = .rounded
        preference("Start a new session", control: startSessionNow, into: sessionsPage, id: "startSessionNow")
        sessionsPage.addArrangedSubview(helpLabel("Starts an idle 5h session with a tiny message on the cheapest model. ChatGPT is experimental."))
        providerPopup.addItems(withTitles: Provider.allCases.map(\.displayName)); providerPopup.target = self; providerPopup.action = #selector(providerChanged)
        for field in [labelField, appPathField, dataDirField] {
            field.delegate = self; field.widthAnchor.constraint(equalToConstant: 310).isActive = true
        }
        preference("Label", control: labelField, into: advancedStack)
        preference("Provider", control: providerPopup, into: advancedStack)
        preference("App path", control: appPathField, into: advancedStack)
        preference("Profile folder", control: dataDirField, into: advancedStack)
        removeButton.title = "Remove account…"; removeButton.bezelStyle = .rounded
        removeButton.target = self; removeButton.action = #selector(removeAccount)
        preference("Account", control: removeButton, into: advancedStack)
    }

    private func buildMenuBarSection(into form: NSStackView) {
        heading("Menu bar", subtitle: "Grid and default layout", into: form)
        gridPicker.toolTip = "Choose up to 3 rows and 3 columns."
        gridPicker.onHover = { [weak self] size in self?.showGridLabel(size) }
        gridPicker.onPick = { [weak self] rows, columns in self?.gridPicked(rows: rows, columns: columns) }
        preference("Layout", control: gridPicker, into: form)
        gridLabel.font = .systemFont(ofSize: 11); gridLabel.textColor = .secondaryLabelColor
        form.addArrangedSubview(gridLabel); form.setCustomSpacing(8, after: gridLabel)
        orderPopup.addItems(withTitles: ["Down each column", "Across each row"])
        orderPopup.target = self; orderPopup.action = #selector(orderChanged)
        preference("Fill order", control: orderPopup, into: form)
        showIconLabels.target = self; showIconLabels.action = #selector(showIconLabelsChanged)
        preference("Icon labels", control: showIconLabels, into: form, id: "showIconLabels")
        showWeekly.target = self; showWeekly.action = #selector(oneRowDetailsChanged)
        preference("Weekly usage", control: showWeekly, into: form, id: "showWeekly")
        resetTimesPopup.addItems(withTitles: MenuBarResetTimes.allCases.map(\.title))
        resetTimesPopup.target = self; resetTimesPopup.action = #selector(oneRowDetailsChanged)
        preference("Quota countdowns", control: resetTimesPopup, into: form)
        arrangePopup.addItems(withTitles: ["Stacked", "Side by side"]); arrangePopup.target = self; arrangePopup.action = #selector(oneRowDetailsChanged)
        preference("Arrangement", control: arrangePopup, into: form)
        form.addArrangedSubview(helpLabel("Weekly usage and countdowns appear when the accounts fit on one row."))
        section("Preview", into: form)
        previewImage.imageScaling = .scaleNone
        previewEmpty.font = .systemFont(ofSize: 11); previewEmpty.textColor = .secondaryLabelColor
        let preview = AppearanceAwareStack(views: [previewImage, previewEmpty])
        preview.orientation = .horizontal; preview.edgeInsets = NSEdgeInsets(top: 6, left: 8, bottom: 6, right: 8)
        form.addArrangedSubview(preview)
        capacityHelp.font = .systemFont(ofSize: 10); capacityHelp.textColor = .secondaryLabelColor
        form.addArrangedSubview(capacityHelp)
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
        iconLabelField.isEnabled = selectedID != nil
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
        heading("General", subtitle: "App preferences", into: form)
        section("Startup & refresh", into: form)
        launchAtLogin.state = (config.launchAtLogin || AutostartManager.isEnabled) ? .on : .off
        launchAtLogin.target = self; launchAtLogin.action = #selector(launchAtLoginChanged)
        preference("Launch at login", control: launchAtLogin, into: form)
        refreshIntervalPopup.addItems(withTitles: refreshOptions.map(\.title))
        let current = Int(config.refreshInterval)
        refreshIntervalPopup.selectItem(at: refreshOptions.enumerated().min { abs($0.element.seconds - current) < abs($1.element.seconds - current) }?.offset ?? 1)
        refreshIntervalPopup.target = self; refreshIntervalPopup.action = #selector(refreshIntervalChanged)
        preference("Refresh every", control: refreshIntervalPopup, into: form)
        section("Updates", into: form)
        autoUpdate.state = config.autoUpdates ? .on : .off; autoUpdate.target = self; autoUpdate.action = #selector(autoUpdateChanged)
        preference("Install updates automatically", control: autoUpdate, into: form)
        checkForUpdatesButton.bezelStyle = .rounded; checkForUpdatesButton.target = self; checkForUpdatesButton.action = #selector(checkForUpdatesNow)
        preference("Version \(Updater.currentVersion)", control: checkForUpdatesButton, into: form)
        section("Access & Claude windows", into: form)
        autoApproveCookies.state = config.allowsCookieKeychain ? .on : .off; autoApproveCookies.target = self; autoApproveCookies.action = #selector(cookiesChanged)
        autoApproveCookies.toolTip = "Approve Claude cookie-store access once through the macOS keychain. Turn off to read live cookies only while Claude is open."
        preference("Auto-approve cookie access", control: autoApproveCookies, into: form)
        routeClaudeLinks.state = config.routesClaudeLinks ? .on : .off; routeClaudeLinks.target = self; routeClaudeLinks.action = #selector(routeClaudeLinksChanged)
        preference("Route Claude sign-in links", control: routeClaudeLinks, into: form)
        offerClaudeUpdates.state = config.offersClaudeUpdates ? .on : .off; offerClaudeUpdates.target = self; offerClaudeUpdates.action = #selector(offerClaudeUpdatesChanged)
        preference("Handle Claude updates", control: offerClaudeUpdates, into: form)
        section("Notifications", into: form)
        let settings = NSButton(title: "System settings…", target: self, action: #selector(openNotificationSettings)); settings.bezelStyle = .rounded
        preference("macOS permission", control: settings, into: form)
        notificationStatus.font = .systemFont(ofSize: 11); notificationStatus.textColor = .secondaryLabelColor
        form.addArrangedSubview(notificationStatus)
        form.addArrangedSubview(helpLabel("Configure manual-reset expiry notifications on each account's Display page."))
    }

    @objc private func openNotificationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") { NSWorkspace.shared.open(url) }
    }

    private func refreshNotificationPermission() {
        guard Bundle.main.bundleIdentifier == "fr.fraserv.llmusagebar" else { return }
        UNUserNotificationCenter.current().getNotificationSettings { [weak self] settings in
            DispatchQueue.main.async {
                let text: String
                switch settings.authorizationStatus {
                case .authorized, .provisional, .ephemeral: text = "Notifications allowed by macOS."
                case .denied: text = "Enable LLMCodeBar in System Settings → Notifications."
                default: text = "Permission is requested when you enable an expiry notification."
                }
                self?.notificationStatus.stringValue = text
                self?.accountNotificationStatus.stringValue = text
            }
        }
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
        showManualResets.state = (profile.showManualResets ?? true) ? .on : .off
        resetAlerts.selectItem(at: [0, 1, 6, 24, 72].firstIndex(of: profile.manualResetExpiryAlertHours ?? 0) ?? 0)
        let accountControls = [showManualResets, showSparklines, showLabels, showSession, showWeeklyLimits, showResets, resetAlerts, menuBarAccount, autoStartSession, startSessionNow, removeButton, providerPopup, labelField, appPathField, dataDirField]
        accountControls.forEach { $0.isEnabled = true }

        labelField.stringValue = profile.label
        providerPopup.selectItem(withTitle: profile.provider.displayName)
        appPathField.stringValue = profile.appPath
        dataDirField.stringValue = profile.dataDir

        menuBarAccount.state = (config.menuBarProfileIDList.contains(profile.id) && config.showsPercentInMenuBar) ? .on : .off
        iconLabelField.stringValue = profile.menuBarLabel ?? ""
        iconLabelField.placeholderString = profile.defaultMenuBarLabel
        iconLabelField.isEnabled = true
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
            accountTitle.stringValue = "\(profile.provider.displayName) · \(profile.menuBarLabelText)"
            accountSubtitle.stringValue = [profile.accountEmail ?? profile.accountName, profile.usage?.accountPlan ?? profile.accountPlan]
                .compactMap { $0 }.joined(separator: "  ·  ")
        }
        for view in manualInventory.arrangedSubviews { manualInventory.removeArrangedSubview(view); view.removeFromSuperview() }
        if let inventory = profile.usage?.manualResets {
            for group in inventory.allowances where group.unexpired(at: Date()) {
                let dates = group.expiresAt.map { ManualResetInventory.dateText($0) } ?? "—"
                let label = NSTextField(labelWithString: dates); label.textColor = .secondaryLabelColor; label.font = .systemFont(ofSize: 11)
                let kind = NSTextField(labelWithString: "\(group.count) \(group.kind)")
                kind.font = .systemFont(ofSize: 11)
                let row = NSStackView(views: [kind, NSView(), label]); row.spacing = 8
                manualInventory.addArrangedSubview(row)
                row.widthAnchor.constraint(equalTo: manualInventory.widthAnchor).isActive = true
                row.heightAnchor.constraint(greaterThanOrEqualToConstant: 18).isActive = true
            }
        }
        if manualInventory.arrangedSubviews.isEmpty {
            manualInventory.addArrangedSubview(helpLabel(profile.usage?.manualResets?.error != nil ? "Inventory unavailable" : "No manual resets available"))
        }
        resizeAccountSection()
        statusLabel.stringValue = ""
    }

    private func clearAccountSection() {
        accountTitle.stringValue = "No account selected"
        accountSubtitle.stringValue = "Add one with the + button"
        [showManualResets, showSparklines, showLabels, showSession, showWeeklyLimits, showResets, resetAlerts, menuBarAccount, autoStartSession, startSessionNow, removeButton, providerPopup, labelField, appPathField, dataDirField, iconLabelField].forEach { $0.isEnabled = false }
        menuBarAccount.state = .off
        iconLabelField.stringValue = ""
        iconLabelDefault.stringValue = ""
        autoStartSession.state = .off
    }

    @objc private func displayChanged(_ sender: NSControl) {
        guard let id = selectedID else { return }
        let values = [showSparklines, showLabels, showSession, showWeeklyLimits, showResets].map { $0.state == .on }
        let hours = [0, 1, 6, 24, 72][max(0, resetAlerts.indexOfSelectedItem)]
        let manual = showManualResets.state == .on
        commit { cfg in
            guard let i = cfg.profiles.firstIndex(where: { $0.id == id }) else { return }
            cfg.profiles[i].showSparklines = values[0]
            cfg.profiles[i].showLabels = values[1]
            cfg.profiles[i].showSessionWindow = values[2]
            cfg.profiles[i].showWeeklyWindows = values[3]
            cfg.profiles[i].showResetTimes = values[4]
            cfg.profiles[i].showManualResets = manual
            cfg.profiles[i].manualResetExpiryAlertHours = hours
        }
        if hours > 0, sender === resetAlerts, Bundle.main.bundleIdentifier == "fr.fraserv.llmusagebar" {
            ResetReminder.requestAuthorization { [weak self] in
                guard let self else { return }
                ResetReminder.sync(self.config.profiles)
                self.refreshNotificationPermission()
            }
        }
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

/// Native sidebar navigation, with the same quiet selected state as the approved mock.
private final class SettingsNavigationButton: NSButton {
    override var intrinsicContentSize: NSSize { NSSize(width: 160, height: 32) }
    override func draw(_ dirtyRect: NSRect) {
        if state == .on {
            NSColor.controlAccentColor.withAlphaComponent(0.14).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
        }
        let text = NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: state == .on ? NSColor.controlAccentColor : NSColor.labelColor,
        ])
        text.draw(at: NSPoint(x: 10, y: (bounds.height - text.size().height) / 2))
    }
}

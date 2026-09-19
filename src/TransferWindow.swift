import AppKit

/// The window behind "Transfer session...": everything an account has that can be moved,
/// in one searchable list, with the accounts to move it between on top.
///
/// A menu was the wrong shape for this. Chats and Code sessions both run into the
/// hundreds, they need searching rather than scrolling, and picking the wrong destination
/// costs real usage - so it's worth a window that shows what you're moving, where it's
/// going, and how much room the destination actually has left.
final class TransferWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    /// One thing that can be moved. Code sessions and chats travel very differently, but
    /// they sit in the same list because "what was I working on" doesn't distinguish them.
    enum Item {
        case code(CodeSessionTransfer.Session)
        case chat(ChatTransfer.ChatSummary)

        var title: String {
            switch self {
            case let .code(session): return session.displayTitle
            case let .chat(chat): return chat.displayName
            }
        }

        var date: Date? {
            switch self {
            case let .code(session): return session.lastActivityAt
            case let .chat(chat): return chat.updatedAt
            }
        }

        var isCode: Bool {
            if case .code = self { return true }
            return false
        }

        /// The line under the title: what kind of thing this is, and where it lives.
        var detail: String {
            var parts = [isCode ? "Code session" : "Chat"]
            if case let .code(session) = self, !session.projectName.isEmpty {
                parts.append(session.projectName)
            }
            let age = ProfileFormatting.ago(date)
            if !age.isEmpty {
                parts.append(age)
            }
            return parts.joined(separator: "  ·  ")
        }
    }

    private let allowKeychain: Bool
    private var profiles: [LaunchProfile]

    private let sourcePopup = NSPopUpButton()
    private let destinationPopup = NSPopUpButton()
    private let swapButton = NSButton()
    private let searchField = NSSearchField()
    private let kindFilter = NSSegmentedControl(labels: ["All", "Code", "Chats"], trackingMode: .selectOne, target: nil, action: nil)
    private let table = NSTableView()
    private let emptyLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private let spinner = NSProgressIndicator()
    private let transferButton = NSButton()

    private var items: [Item] = []
    private var visibleItems: [Item] = []
    /// Bumped on every reload so a slow chat fetch can't overwrite a newer selection.
    private var loadToken = 0
    private var isTransferring = false

    init(profiles: [LaunchProfile], allowKeychain: Bool) {
        self.profiles = profiles.filter { $0.provider == .claude && $0.isPendingLogin != true }
        self.allowKeychain = allowKeychain

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false)
        window.title = "Transfer a session"
        window.minSize = NSSize(width: 620, height: 460)
        window.center()
        super.init(window: window)

        buildUI()
        selectDefaultAccounts()
        reload()
    }

    required init?(coder: NSCoder) { nil }

    // MARK: Accounts

    private var source: LaunchProfile? {
        let index = sourcePopup.indexOfSelectedItem
        return profiles.indices.contains(index) ? profiles[index] : nil
    }

    private var destination: LaunchProfile? {
        guard let source else { return nil }
        let others = profiles.filter { $0.id != source.id }
        let index = destinationPopup.indexOfSelectedItem
        return others.indices.contains(index) ? others[index] : nil
    }

    /// Accounts read better with their remaining session usage attached - it's the number
    /// you're transferring *because of*.
    private func accountTitle(_ profile: LaunchProfile) -> String {
        let name = ChatTransfer.accountLabel(profile)
        guard let percent = ProfileFormatting.primaryUsagePercent(for: profile) else { return name }
        return "\(name)  —  \(Int(percent.rounded()))% of session used"
    }

    /// Start from the account that's most used up, since that's the one you're leaving.
    private func selectDefaultAccounts() {
        sourcePopup.removeAllItems()
        for profile in profiles {
            sourcePopup.addItem(withTitle: accountTitle(profile))
        }
        let busiest = profiles.enumerated().max { left, right in
            (ProfileFormatting.primaryUsagePercent(for: left.element) ?? -1)
                < (ProfileFormatting.primaryUsagePercent(for: right.element) ?? -1)
        }
        sourcePopup.selectItem(at: busiest?.offset ?? 0)
        rebuildDestinations()
    }

    private func rebuildDestinations() {
        guard let source else { return }
        destinationPopup.removeAllItems()
        for profile in profiles where profile.id != source.id {
            destinationPopup.addItem(withTitle: accountTitle(profile))
        }
        // Default to whichever destination has the most room left.
        let others = profiles.filter { $0.id != source.id }
        let freest = others.enumerated().min { left, right in
            (ProfileFormatting.primaryUsagePercent(for: left.element) ?? 101)
                < (ProfileFormatting.primaryUsagePercent(for: right.element) ?? 101)
        }
        destinationPopup.selectItem(at: freest?.offset ?? 0)
    }

    // MARK: Loading

    @objc private func sourceChanged() {
        rebuildDestinations()
        reload()
    }

    @objc private func swapAccounts() {
        guard let source, let destination else { return }
        if let index = profiles.firstIndex(where: { $0.id == destination.id }) {
            sourcePopup.selectItem(at: index)
            rebuildDestinations()
            let others = profiles.filter { $0.id != destination.id }
            if let back = others.firstIndex(where: { $0.id == source.id }) {
                destinationPopup.selectItem(at: back)
            }
        }
        reload()
    }

    private func reload() {
        guard let source else { return }
        loadToken += 1
        let token = loadToken

        // Code sessions come off the disk, so they're on screen immediately.
        items = CodeSessionTransfer.sessions(for: source, orgID: source.organizationUUID, limit: 200).map(Item.code)
        applyFilter()

        spinner.startAnimation(nil)
        setStatus("Loading chats from \(ChatTransfer.accountLabel(source))...")
        let allowKeychain = self.allowKeychain
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let chats = try? ChatTransfer.recentChats(for: source, allowKeychain: allowKeychain, limit: 100)
            DispatchQueue.main.async {
                guard let self, self.loadToken == token else { return }
                self.spinner.stopAnimation(nil)
                if let chats {
                    self.items += chats.map(Item.chat)
                    self.applyFilter()
                    self.showSummary()
                } else {
                    self.setStatus("Couldn't load chats - open Claude for that account, or check Settings.")
                }
            }
        }
    }

    @objc private func applyFilter() {
        let query = searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let kind = kindFilter.selectedSegment

        visibleItems = items.filter { item in
            switch kind {
            case 1 where !item.isCode: return false
            case 2 where item.isCode: return false
            default: break
            }
            guard !query.isEmpty else { return true }
            return item.title.lowercased().contains(query) || item.detail.lowercased().contains(query)
        }
        // Newest first, whichever kind it is.
        visibleItems.sort { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }

        table.reloadData()
        emptyLabel.isHidden = !visibleItems.isEmpty
        emptyLabel.stringValue = items.isEmpty ? "Nothing to transfer from this account yet." : "Nothing matches “\(searchField.stringValue)”."
        updateTransferButton()
    }

    func controlTextDidChange(_ notification: Notification) { applyFilter() }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { visibleItems.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard visibleItems.indices.contains(row) else { return nil }
        return ItemRowView(item: visibleItems[row])
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat { 46 }

    func tableViewSelectionDidChange(_ notification: Notification) { updateTransferButton() }

    private var selectedItem: Item? {
        let row = table.selectedRow
        return visibleItems.indices.contains(row) ? visibleItems[row] : nil
    }

    private func updateTransferButton() {
        guard !isTransferring else { return }
        let item = selectedItem
        transferButton.isEnabled = item != nil && destination != nil
        if let item, let destination {
            transferButton.title = item.isCode ? "Move to \(ChatTransfer.accountLabel(destination))" : "Copy to \(ChatTransfer.accountLabel(destination))"
        } else {
            transferButton.title = "Transfer"
        }
    }

    // MARK: Transferring

    @objc private func performTransfer() {
        guard let item = selectedItem, let source, let destination, !isTransferring else { return }
        isTransferring = true
        transferButton.isEnabled = false
        spinner.startAnimation(nil)

        switch item {
        case let .code(session):
            setStatus("Moving “\(session.displayTitle)”...")
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let outcome = Result {
                    try CodeSessionTransfer.transfer(session: session, to: destination, destinationOrgID: destination.organizationUUID)
                }
                DispatchQueue.main.async {
                    self?.finishCodeTransfer(outcome, named: session.displayTitle, destination: destination)
                }
            }

        case let .chat(chat):
            setStatus("Copying “\(chat.displayName)” - this sends the transcript, so give it a moment...")
            let allowKeychain = self.allowKeychain
            let profiles = self.profiles
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let outcome = Result {
                    try ChatTransfer.transfer(chat: chat, from: source, to: destination, allowKeychain: allowKeychain)
                }
                DispatchQueue.main.async {
                    self?.finishChatTransfer(outcome, destination: destination, profiles: profiles)
                }
            }
        }
    }

    private func finishCodeTransfer(_ outcome: Result<URL, Error>, named name: String, destination: LaunchProfile) {
        spinner.stopAnimation(nil)
        isTransferring = false
        updateTransferButton()

        guard case .success = outcome else {
            if case let .failure(error) = outcome {
                setStatus("Couldn't move it: \(error.localizedDescription)", isError: true)
            }
            return
        }

        let account = ChatTransfer.accountLabel(destination)
        guard CodeSessionTransfer.needsRestartToAppear(destination) else {
            setStatus("Moved “\(name)” to \(account) - opening Claude there.")
            try? Launcher.launch(destination)
            return
        }

        let alert = NSAlert()
        alert.messageText = "“\(name)” is now in \(account)"
        alert.informativeText = """
        Claude only reads its Code list when it starts, so \(account)'s window has to \
        restart before the session appears. Anything running in that window will stop.
        """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Restart Claude")
        alert.addButton(withTitle: "Later")
        guard alert.runModal() == .alertFirstButtonReturn else {
            setStatus("Moved “\(name)” to \(account) - restart that Claude to see it.")
            return
        }

        setStatus("Restarting \(account)...")
        spinner.startAnimation(nil)
        CodeSessionTransfer.restart(destination) { [weak self] restarted in
            self?.spinner.stopAnimation(nil)
            self?.setStatus(restarted
                ? "Moved “\(name)” to \(account) - it's in Code there now."
                : "Moved it, but couldn't restart \(account). Quit that Claude and reopen it.",
                isError: !restarted)
        }
    }

    private func finishChatTransfer(_ outcome: Result<ChatTransfer.TransferResult, Error>, destination: LaunchProfile, profiles: [LaunchProfile]) {
        spinner.stopAnimation(nil)
        isTransferring = false
        updateTransferButton()

        switch outcome {
        case let .success(result):
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(result.url, forType: .string)
            var message = "Copied “\(result.chatName)” to \(ChatTransfer.accountLabel(destination)) - link copied to the clipboard."
            if result.truncated {
                message += " Older messages were trimmed to fit."
            }
            setStatus(message)

            DispatchQueue.global(qos: .userInitiated).async {
                let wasRunning = RunningProfileDetector.runningApplication(for: destination) != nil
                let canDeepLink = ClaudeDeepLink.canTarget(destination, among: profiles)
                DispatchQueue.main.async {
                    try? Launcher.launch(destination)
                    guard canDeepLink else { return }
                    DispatchQueue.main.asyncAfter(deadline: .now() + (wasRunning ? 0.4 : 3.5)) {
                        ClaudeDeepLink.open(conversationUUID: result.conversationUUID)
                    }
                }
            }

        case let .failure(error):
            setStatus("Couldn't copy it: \(error.localizedDescription)", isError: true)
        }
    }

    /// What the idle status line says: how much there is to choose from.
    private func showSummary() {
        let code = items.filter(\.isCode).count
        let chats = items.count - code
        setStatus("\(code) Code session\(code == 1 ? "" : "s")  ·  \(chats) chat\(chats == 1 ? "" : "s")")
    }

    private func setStatus(_ text: String, isError: Bool = false) {
        statusLabel.stringValue = text
        statusLabel.textColor = isError ? .systemRed : .secondaryLabelColor
    }

    // MARK: UI

    private func buildUI() {
        guard let content = window?.contentView else { return }

        let heading = NSTextField(labelWithString: "Move a Code session or a chat to another Claude account")
        heading.font = .systemFont(ofSize: 13, weight: .semibold)

        let explainer = NSTextField(wrappingLabelWithString: "A Code session moves whole and costs nothing - both accounts end up on the same transcript. A chat is copied: the destination gets the conversation attached and one reply to pick it up, which uses a little of that account's quota.")
        explainer.font = .systemFont(ofSize: 11)
        explainer.textColor = .secondaryLabelColor

        let fromLabel = NSTextField(labelWithString: "From")
        fromLabel.font = .systemFont(ofSize: 11, weight: .medium)
        fromLabel.textColor = .secondaryLabelColor
        let toLabel = NSTextField(labelWithString: "To")
        toLabel.font = .systemFont(ofSize: 11, weight: .medium)
        toLabel.textColor = .secondaryLabelColor

        sourcePopup.target = self
        sourcePopup.action = #selector(sourceChanged)
        destinationPopup.target = self
        destinationPopup.action = #selector(destinationChanged)

        swapButton.title = "⇄"
        swapButton.bezelStyle = .rounded
        swapButton.target = self
        swapButton.action = #selector(swapAccounts)
        swapButton.toolTip = "Swap the two accounts"
        swapButton.widthAnchor.constraint(equalToConstant: 36).isActive = true

        let accountRow = NSStackView(views: [fromLabel, sourcePopup, swapButton, toLabel, destinationPopup])
        accountRow.orientation = .horizontal
        accountRow.spacing = 8
        accountRow.alignment = .centerY
        sourcePopup.setContentHuggingPriority(.defaultLow, for: .horizontal)
        destinationPopup.setContentHuggingPriority(.defaultLow, for: .horizontal)
        sourcePopup.widthAnchor.constraint(equalTo: destinationPopup.widthAnchor).isActive = true

        searchField.placeholderString = "Search sessions and chats"
        searchField.delegate = self
        kindFilter.selectedSegment = 0
        kindFilter.target = self
        kindFilter.action = #selector(applyFilter)
        kindFilter.segmentStyle = .rounded

        let filterRow = NSStackView(views: [searchField, kindFilter])
        filterRow.orientation = .horizontal
        filterRow.spacing = 10
        searchField.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("item"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.headerView = nil
        table.delegate = self
        table.dataSource = self
        table.rowHeight = 46
        table.style = .inset
        table.doubleAction = #selector(performTransfer)
        table.target = self
        scroll.documentView = table

        emptyLabel.font = .systemFont(ofSize: 12)
        emptyLabel.textColor = .tertiaryLabelColor
        emptyLabel.alignment = .center
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        emptyLabel.isHidden = true

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.translatesAutoresizingMaskIntoConstraints = false

        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        transferButton.title = "Transfer"
        transferButton.bezelStyle = .rounded
        transferButton.keyEquivalent = "\r"
        transferButton.target = self
        transferButton.action = #selector(performTransfer)
        transferButton.isEnabled = false

        let stack = NSStackView(views: [heading, explainer, accountRow, filterRow])
        stack.orientation = .vertical
        stack.spacing = 10
        stack.alignment = .leading
        stack.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        transferButton.translatesAutoresizingMaskIntoConstraints = false

        content.addSubview(stack)
        content.addSubview(scroll)
        content.addSubview(spinner)
        content.addSubview(statusLabel)
        content.addSubview(transferButton)
        scroll.addSubview(emptyLabel)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 18),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),

            accountRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            filterRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            explainer.widthAnchor.constraint(equalTo: stack.widthAnchor),

            scroll.topAnchor.constraint(equalTo: stack.bottomAnchor, constant: 12),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            scroll.bottomAnchor.constraint(equalTo: transferButton.topAnchor, constant: -12),

            emptyLabel.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            emptyLabel.topAnchor.constraint(equalTo: scroll.topAnchor, constant: 28),

            // Status on the left, the action on the right - the button shouldn't drift
            // toward the middle just because the status line is empty.
            transferButton.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            transferButton.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),

            spinner.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            spinner.centerYAnchor.constraint(equalTo: transferButton.centerYAnchor),
            spinner.widthAnchor.constraint(equalToConstant: 16),

            statusLabel.leadingAnchor.constraint(equalTo: spinner.trailingAnchor, constant: 8),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: transferButton.leadingAnchor, constant: -12),
            statusLabel.centerYAnchor.constraint(equalTo: transferButton.centerYAnchor),
        ])
    }

    @objc private func destinationChanged() { updateTransferButton() }
}

/// One row: what it is, what it was called, and when you last touched it.
private final class ItemRowView: NSTableCellView {
    init(item: TransferWindowController.Item) {
        super.init(frame: .zero)

        let badge = NSImageView()
        badge.translatesAutoresizingMaskIntoConstraints = false
        let symbol = item.isCode ? "chevron.left.forwardslash.chevron.right" : "bubble.left.and.bubble.right"
        badge.image = NSImage(systemSymbolName: symbol, accessibilityDescription: item.isCode ? "Code session" : "Chat")
        badge.contentTintColor = item.isCode ? .systemGreen : .systemBlue
        badge.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)

        let title = NSTextField(labelWithString: item.title)
        title.translatesAutoresizingMaskIntoConstraints = false
        title.font = .systemFont(ofSize: 13, weight: .medium)
        title.lineBreakMode = .byTruncatingTail

        let detail = NSTextField(labelWithString: item.detail)
        detail.translatesAutoresizingMaskIntoConstraints = false
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = .secondaryLabelColor
        detail.lineBreakMode = .byTruncatingTail

        addSubview(badge)
        addSubview(title)
        addSubview(detail)

        NSLayoutConstraint.activate([
            badge.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            badge.centerYAnchor.constraint(equalTo: centerYAnchor),
            badge.widthAnchor.constraint(equalToConstant: 20),

            title.leadingAnchor.constraint(equalTo: badge.trailingAnchor, constant: 10),
            title.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            title.topAnchor.constraint(equalTo: topAnchor, constant: 6),

            detail.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            detail.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            detail.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 2),
        ])
    }

    required init?(coder: NSCoder) { nil }
}

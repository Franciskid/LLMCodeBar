import AppKit

/// What LLMCodeBar did in the background and what went wrong, kept on disk so a problem
/// that happened overnight is still there to read (and to paste into a bug report).
///
/// Plain text, one line per entry, in `activity.log` next to the config. It's trimmed to
/// the most recent entries so it never grows without bound.
final class ActivityLog {
    static let shared = ActivityLog()
    static let didChange = Notification.Name("LLMCodeBar.ActivityLog.didChange")

    enum Level: String {
        case info, error
    }

    struct Entry {
        var date: Date
        var level: Level
        var source: String
        var message: String
    }

    let url = Paths.shared.appSupport.appendingPathComponent("activity.log")
    private let queue = DispatchQueue(label: "fr.fraserv.llmusagebar.activity-log")
    private let maxEntries = 2000
    private var entries: [Entry] = []
    private var loaded = false
    /// Errors logged since the log window was last opened, for the menu's reminder.
    private(set) var unseenErrors = 0

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()

    func info(_ source: String, _ message: String) { add(.info, source, message) }
    func error(_ source: String, _ message: String) { add(.error, source, message) }

    private func add(_ level: Level, _ source: String, _ message: String) {
        let entry = Entry(date: Date(), level: level, source: source, message: message)
        queue.async {
            self.loadIfNeeded()
            self.entries.append(entry)
            if level == .error { self.unseenErrors += 1 }
            if self.entries.count > self.maxEntries + 200 {
                self.entries.removeFirst(self.entries.count - self.maxEntries)
                self.rewrite()
            } else {
                self.append(entry)
            }
            DispatchQueue.main.async { NotificationCenter.default.post(name: Self.didChange, object: nil) }
        }
    }

    func snapshot() -> [Entry] {
        queue.sync {
            loadIfNeeded()
            return entries
        }
    }

    func markSeen() {
        queue.sync { unseenErrors = 0 }
    }

    func clear() {
        queue.sync {
            entries = []
            unseenErrors = 0
            loaded = true
            try? FileManager.default.removeItem(at: url)
        }
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }

    static func line(for entry: Entry) -> String {
        let message = entry.message.replacingOccurrences(of: "\n", with: " ")
        return "\(formatter.string(from: entry.date)) [\(entry.level.rawValue)] \(entry.source): \(message)"
    }

    // MARK: Disk

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        entries = text.split(separator: "\n").suffix(maxEntries).compactMap(Self.parse)
    }

    private static func parse(_ line: Substring) -> Entry? {
        // "yyyy-MM-dd HH:mm:ss [level] source: message"
        let parts = line.split(separator: " ", maxSplits: 3)
        guard parts.count == 4,
              let date = formatter.date(from: "\(parts[0]) \(parts[1])"),
              let level = Level(rawValue: String(parts[2].dropFirst().dropLast())) else { return nil }
        let rest = parts[3]
        guard let colon = rest.range(of: ": ") else { return nil }
        return Entry(date: date, level: level, source: String(rest[..<colon.lowerBound]), message: String(rest[colon.upperBound...]))
    }

    private func append(_ entry: Entry) {
        Paths.shared.ensureSupportDirectory()
        let data = Data((Self.line(for: entry) + "\n").utf8)
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url, options: .atomic)
        }
    }

    private func rewrite() {
        let text = entries.map(Self.line(for:)).joined(separator: "\n") + "\n"
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }
}

/// Reusable Activity Log panel used both in the standalone popup window and inside Settings.
final class ActivityLogView: NSView {
    private let textView = NSTextView()
    private let errorsOnly = NSButton(checkboxWithTitle: "Errors only", target: nil, action: nil)
    private let onClose: (() -> Void)?
    private var observer: NSObjectProtocol?

    init(onClose: (() -> Void)?) {
        self.onClose = onClose
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        buildUI()
        reload()
        observer = NotificationCenter.default.addObserver(forName: ActivityLog.didChange, object: nil, queue: .main) { [weak self] _ in
            self?.reload()
        }
    }

    required init?(coder: NSCoder) { nil }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    private func buildUI() {
        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        textView.isEditable = false
        textView.isRichText = true
        textView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        textView.textContainerInset = NSSize(width: 6, height: 6)
        textView.autoresizingMask = [.width]
        textView.isVerticallyResizable = true
        textView.textContainer?.widthTracksTextView = true
        scroll.documentView = textView

        errorsOnly.target = self
        errorsOnly.action = #selector(reload)
        let reveal = NSButton(title: "Show in Finder", target: self, action: #selector(revealFile))
        let copy = NSButton(title: "Copy All", target: self, action: #selector(copyAll))
        let clear = NSButton(title: "Clear", target: self, action: #selector(clearLog))
        clear.identifier = NSUserInterfaceItemIdentifier("activityLogClear")

        var barViews: [NSView] = [errorsOnly, {
            let spacer = NSView()
            spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
            return spacer
        }(), reveal, copy, clear]

        if onClose != nil {
            let close = NSButton(title: "Close", target: self, action: #selector(closeTapped))
            close.identifier = NSUserInterfaceItemIdentifier("activityLogClose")
            close.keyEquivalent = "\u{1b}"
            close.bezelStyle = .rounded
            barViews.append(close)
        }
        for button in [reveal, copy, clear] { button.bezelStyle = .rounded }

        let bar = NSStackView(views: barViews)
        bar.identifier = NSUserInterfaceItemIdentifier("activityLogBar")
        bar.translatesAutoresizingMaskIntoConstraints = false
        bar.orientation = .horizontal
        bar.spacing = 8

        addSubview(scroll)
        addSubview(bar)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            bar.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 10),
            bar.leadingAnchor.constraint(equalTo: leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: trailingAnchor),
            bar.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    private var visibleEntries: [ActivityLog.Entry] {
        let entries = ActivityLog.shared.snapshot()
        return errorsOnly.state == .on ? entries.filter { $0.level == .error } : entries
    }

    @objc func reload() {
        let entries = visibleEntries
        let text = NSMutableAttributedString()
        let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        for entry in entries {
            let color: NSColor = entry.level == .error ? .systemRed : .labelColor
            text.append(NSAttributedString(string: ActivityLog.line(for: entry) + "\n", attributes: [.font: font, .foregroundColor: color]))
        }
        if entries.isEmpty {
            text.append(NSAttributedString(string: "Nothing logged yet.", attributes: [.font: font, .foregroundColor: NSColor.secondaryLabelColor]))
        }
        textView.textStorage?.setAttributedString(text)
        textView.scrollToEndOfDocument(nil)
        if window?.isVisible == true { ActivityLog.shared.markSeen() }
    }

    @objc private func copyAll() {
        let text = visibleEntries.map(ActivityLog.line(for:)).joined(separator: "\n")
        let header = "LLMCodeBar \(Updater.currentVersion), macOS \(ProcessInfo.processInfo.operatingSystemVersionString)\n"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(header + text, forType: .string)
    }

    @objc private func revealFile() {
        if FileManager.default.fileExists(atPath: ActivityLog.shared.url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([ActivityLog.shared.url])
        } else {
            NSWorkspace.shared.open(Paths.shared.appSupport)
        }
    }

    @objc private func clearLog() {
        ActivityLog.shared.clear()
    }

    @objc private func closeTapped() {
        onClose?()
    }
}

/// The Activity Log window: every entry, newest at the bottom, with errors in red.
final class ActivityLogWindowController: NSWindowController {
    private var logView: ActivityLogView?

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 460),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false)
        window.title = "LLMCodeBar Activity Log"
        window.minSize = NSSize(width: 480, height: 260)
        window.center()
        super.init(window: window)
        buildUI()
    }

    required init?(coder: NSCoder) { nil }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        ActivityLog.shared.markSeen()
        logView?.reload()
    }

    private func buildUI() {
        guard let content = window?.contentView else { return }
        let view = ActivityLogView(onClose: { [weak self] in self?.close() })
        logView = view
        content.addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            view.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            view.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            view.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12),
        ])
    }
}

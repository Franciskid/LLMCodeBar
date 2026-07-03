import AppKit

enum MenuBarIcon {
    static func make(usagePercent: Double?, isRefreshing: Bool) -> NSImage {
        let size = NSSize(width: 24, height: 18)
        let image = NSImage(size: size)
        image.lockFocus()
        defer { image.unlockFocus() }

        let accent = isRefreshing ? NSColor.systemBlue : color(for: usagePercent)
        let stroke = NSColor.labelColor.withAlphaComponent(0.72)
        let softAccent = accent.withAlphaComponent(0.22)
        let center = NSPoint(x: 12, y: 9)
        let nodes = [
            NSPoint(x: 5, y: 5),
            NSPoint(x: 5, y: 13),
            NSPoint(x: 12, y: 15),
            NSPoint(x: 19, y: 12),
            NSPoint(x: 18, y: 5),
            center
        ]

        let glow = NSBezierPath(ovalIn: NSRect(x: 6, y: 3, width: 12, height: 12))
        softAccent.setFill()
        glow.fill()

        stroke.setStroke()
        let links = NSBezierPath()
        links.lineWidth = 1.25
        links.move(to: nodes[0])
        links.line(to: center)
        links.line(to: nodes[2])
        links.move(to: nodes[1])
        links.line(to: center)
        links.line(to: nodes[3])
        links.move(to: nodes[4])
        links.line(to: center)
        links.stroke()

        NSColor.labelColor.withAlphaComponent(0.20).setStroke()
        let ringRect = NSRect(x: center.x - 5.2, y: center.y - 5.2, width: 10.4, height: 10.4)
        let ring = NSBezierPath(ovalIn: ringRect)
        ring.lineWidth = 1.3
        ring.stroke()

        if let usagePercent {
            let remaining = max(0, min(1, (100 - usagePercent) / 100))
            accent.setStroke()
            let arc = NSBezierPath()
            arc.lineWidth = 1.8
            arc.appendArc(
                withCenter: center,
                radius: 5.2,
                startAngle: 90,
                endAngle: 90 - CGFloat(360 * remaining),
                clockwise: true)
            arc.stroke()
        }

        for node in nodes.dropLast() {
            NSColor.labelColor.withAlphaComponent(0.82).setFill()
            NSBezierPath(ovalIn: NSRect(x: node.x - 1.35, y: node.y - 1.35, width: 2.7, height: 2.7)).fill()
        }

        accent.setFill()
        NSBezierPath(ovalIn: NSRect(x: center.x - 2.35, y: center.y - 2.35, width: 4.7, height: 4.7)).fill()

        image.isTemplate = false
        return image
    }

    private static func color(for usagePercent: Double?) -> NSColor {
        statusColor(for: usagePercent)
    }

    static func statusColor(for usagePercent: Double?) -> NSColor {
        guard let usagePercent else { return .systemTeal }
        if usagePercent >= 90 { return .systemRed }
        if usagePercent >= 70 { return .systemOrange }
        return .systemGreen
    }
}

/// Renders the menu-bar status image as up to two stacked rows, each showing an
/// account's app icon (Claude/Codex) followed by its 5h % so you can tell them apart.
enum MenuBarBadge {
    struct Row {
        let icon: NSImage
        let percent: Double
    }

    static func image(rows: [Row]) -> NSImage {
        let visible = Array(rows.prefix(2))
        let twoUp = visible.count >= 2

        let font = NSFont.monospacedDigitSystemFont(ofSize: twoUp ? 9.5 : 11.5, weight: .semibold)
        let iconSize: CGFloat = twoUp ? 11 : 15
        let rowHeight: CGFloat = twoUp ? 11 : 18
        let gap: CGFloat = 2.5
        let totalHeight = rowHeight * CGFloat(max(1, visible.count))

        let texts: [NSAttributedString] = visible.map { row in
            NSAttributedString(
                string: "\(Int(row.percent.rounded()))%",
                attributes: [.font: font, .foregroundColor: MenuBarIcon.statusColor(for: row.percent)])
        }
        let contentWidth = texts.reduce(CGFloat(0)) { max($0, iconSize + gap + $1.size().width) }

        let image = NSImage(size: NSSize(width: ceil(contentWidth), height: totalHeight))
        image.lockFocus()
        defer { image.unlockFocus() }

        for (i, row) in visible.enumerated() {
            // Row 0 sits at the top (menu-bar images use a bottom-left origin).
            let rowMidY = totalHeight - (CGFloat(i) + 0.5) * rowHeight
            let iconRect = NSRect(x: 0, y: rowMidY - iconSize / 2, width: iconSize, height: iconSize)
            row.icon.draw(in: iconRect, from: .zero, operation: .sourceOver, fraction: 1)

            let textSize = texts[i].size()
            texts[i].draw(at: NSPoint(x: iconSize + gap, y: rowMidY - textSize.height / 2))
        }

        image.isTemplate = false
        return image
    }
}

final class UsageBarView: NSView {
    var usedPercent: Double? {
        didSet { needsDisplay = true }
    }
    var accentColor: NSColor = .systemGreen {
        didSet { needsDisplay = true }
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: 80, height: 7)
    }

    override func draw(_ dirtyRect: NSRect) {
        // Inset by half the border width so the 1pt stroke isn't clipped at the edges.
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let radius = rect.height / 2
        let track = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)

        // Track background.
        NSColor.tertiaryLabelColor.withAlphaComponent(0.18).setFill()
        track.fill()

        // Fill, clipped to the rounded track so it never spills past the border.
        if let usedPercent {
            let percent = max(0, min(1, usedPercent / 100))
            if percent > 0 {
                NSGraphicsContext.saveGraphicsState()
                track.addClip()
                // Keep a sliver visible even for tiny percentages.
                let fillWidth = max(rect.height, rect.width * CGFloat(percent))
                let fillRect = NSRect(x: rect.minX, y: rect.minY, width: fillWidth, height: rect.height)
                accentColor.setFill()
                NSBezierPath(roundedRect: fillRect, xRadius: radius, yRadius: radius).fill()
                NSGraphicsContext.restoreGraphicsState()
            }
        }

        // Defined border so the full length of the bar (and where it ends) is always visible.
        NSColor.separatorColor.setStroke()
        track.lineWidth = 1
        track.stroke()
    }
}

/// Top-left origin container so scrolled content flows first-row-first (natural
/// downward scrolling), used as the document view of the scrollable account list.
final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

final class StatusDotView: NSView {
    var isRunning = false {
        didSet { needsDisplay = true }
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: 8, height: 8)
    }

    override func draw(_ dirtyRect: NSRect) {
        let color = isRunning ? NSColor.systemGreen : NSColor.tertiaryLabelColor.withAlphaComponent(0.5)
        color.setFill()
        NSBezierPath(ovalIn: bounds.insetBy(dx: 1, dy: 1)).fill()
    }
}

/// Maps a used-percent (0-100) onto a smooth green → yellow → red gradient.
enum UsageGradient {
    static func color(for percent: Double) -> NSColor {
        let t = max(0, min(1, percent / 100))
        let green = NSColor(srgbRed: 0.30, green: 0.80, blue: 0.38, alpha: 1)
        let yellow = NSColor(srgbRed: 0.98, green: 0.78, blue: 0.20, alpha: 1)
        let red = NSColor(srgbRed: 0.94, green: 0.26, blue: 0.24, alpha: 1)
        return t < 0.5 ? lerp(green, yellow, CGFloat(t / 0.5)) : lerp(yellow, red, CGFloat((t - 0.5) / 0.5))
    }

    private static func lerp(_ a: NSColor, _ b: NSColor, _ t: CGFloat) -> NSColor {
        NSColor(
            srgbRed: a.redComponent + (b.redComponent - a.redComponent) * t,
            green: a.greenComponent + (b.greenComponent - a.greenComponent) * t,
            blue: a.blueComponent + (b.blueComponent - a.blueComponent) * t,
            alpha: 1)
    }
}

/// Compact trend line of used-percent over time. Auto-scales to the data range so
/// movement is visible even when usage stays low, and colors each segment by how
/// close its value is to 100% (green → yellow → red).
final class SparklineView: NSView {
    private let values: [Double]

    init(values: [Double]) {
        self.values = values
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
    }

    required init?(coder: NSCoder) { nil }

    override var intrinsicContentSize: NSSize { NSSize(width: 80, height: 14) }

    override func draw(_ dirtyRect: NSRect) {
        guard values.count >= 2 else { return }
        let rect = bounds.insetBy(dx: 1, dy: 2)

        let lo = values.min() ?? 0
        let hi = values.max() ?? 100
        let span = max(1, hi - lo)
        let n = values.count

        func point(_ i: Int) -> NSPoint {
            let x = rect.minX + rect.width * CGFloat(i) / CGFloat(n - 1)
            let frac = (values[i] - lo) / span
            let y = rect.minY + rect.height * CGFloat(max(0, min(1, frac)))
            return NSPoint(x: x, y: y)
        }

        NSColor.separatorColor.withAlphaComponent(0.45).setStroke()
        let baseline = NSBezierPath()
        baseline.move(to: NSPoint(x: rect.minX, y: rect.minY))
        baseline.line(to: NSPoint(x: rect.maxX, y: rect.minY))
        baseline.lineWidth = 0.5
        baseline.stroke()

        // Color each segment by the average value of its endpoints, so the line
        // fades toward red as usage climbs toward 100%.
        for i in 1..<n {
            let segment = NSBezierPath()
            segment.move(to: point(i - 1))
            segment.line(to: point(i))
            segment.lineWidth = 1.6
            segment.lineCapStyle = .round
            UsageGradient.color(for: (values[i - 1] + values[i]) / 2).setStroke()
            segment.stroke()
        }

        let last = point(n - 1)
        UsageGradient.color(for: values[n - 1]).setFill()
        NSBezierPath(ovalIn: NSRect(x: last.x - 1.8, y: last.y - 1.8, width: 3.6, height: 3.6)).fill()
    }
}

final class QuotaWindowView: NSView {
    init(window: UsageWindow, history: [Double] = [], showSparkline: Bool = false) {
        super.init(frame: NSRect(x: 0, y: 0, width: 300, height: 30))
        translatesAutoresizingMaskIntoConstraints = false

        let title = NSTextField(labelWithString: ProfileFormatting.windowTitle(window.title))
        title.translatesAutoresizingMaskIntoConstraints = false
        title.font = .systemFont(ofSize: 11.5, weight: .semibold)
        title.textColor = .labelColor

        let used = NSTextField(labelWithString: ProfileFormatting.usedText(for: window))
        used.translatesAutoresizingMaskIntoConstraints = false
        used.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        used.textColor = .secondaryLabelColor

        let reset = NSTextField(labelWithString: ProfileFormatting.resetText(for: window))
        reset.translatesAutoresizingMaskIntoConstraints = false
        reset.font = .monospacedDigitSystemFont(ofSize: 10.5, weight: .medium)
        reset.textColor = .secondaryLabelColor
        reset.alignment = .right

        let bar = UsageBarView()
        bar.translatesAutoresizingMaskIntoConstraints = false
        bar.usedPercent = window.usedPercent
        bar.accentColor = Self.color(for: window.usedPercent)

        addSubview(title)
        addSubview(used)
        addSubview(bar)
        addSubview(reset)

        var constraints: [NSLayoutConstraint] = [
            title.leadingAnchor.constraint(equalTo: leadingAnchor),
            title.topAnchor.constraint(equalTo: topAnchor),
            title.trailingAnchor.constraint(lessThanOrEqualTo: used.leadingAnchor, constant: -8),

            used.trailingAnchor.constraint(equalTo: trailingAnchor),
            used.firstBaselineAnchor.constraint(equalTo: title.firstBaselineAnchor),

            bar.leadingAnchor.constraint(equalTo: leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: reset.leadingAnchor, constant: -10),
            bar.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 5),
            bar.heightAnchor.constraint(equalToConstant: 7),

            reset.trailingAnchor.constraint(equalTo: trailingAnchor),
            reset.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            reset.widthAnchor.constraint(equalToConstant: 62),
        ]

        if showSparkline, history.count >= 2 {
            let spark = SparklineView(values: history)
            addSubview(spark)
            constraints += [
                spark.leadingAnchor.constraint(equalTo: leadingAnchor),
                spark.trailingAnchor.constraint(equalTo: bar.trailingAnchor),
                spark.topAnchor.constraint(equalTo: bar.bottomAnchor, constant: 4),
                spark.heightAnchor.constraint(equalToConstant: 14),
                spark.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor),
            ]
        } else {
            constraints.append(bar.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor))
        }

        NSLayoutConstraint.activate(constraints)
    }

    private static func color(for usedPercent: Double) -> NSColor {
        if usedPercent >= 90 { return .systemRed }
        if usedPercent >= 70 { return .systemOrange }
        return .systemGreen
    }

    required init?(coder: NSCoder) {
        nil
    }
}

final class ProfileMenuItemView: NSView {
    private let profileID: String
    private weak var actionTarget: AnyObject?
    private let action: Selector
    private var trackingArea: NSTrackingArea?
    private var isHovering = false {
        didSet { needsDisplay = true }
    }

    init(profile: LaunchProfile, target: AnyObject, action: Selector, isRefreshing: Bool, isRunning: Bool, showSparklines: Bool = false) {
        self.profileID = profile.id
        self.actionTarget = target
        self.action = action
        let windowCount = max(1, min(2, profile.usage?.windows.count ?? 0))
        let rowHeight = showSparklines ? 52 : 35
        super.init(frame: NSRect(x: 0, y: 0, width: 320, height: CGFloat(58 + windowCount * rowHeight)))
        identifier = NSUserInterfaceItemIdentifier(profileID)
        wantsLayer = true

        let appIcon = NSWorkspace.shared.icon(forFile: Launcher.expanding(profile.appPath))
        appIcon.size = NSSize(width: 28, height: 28)
        let icon = NSImageView(image: appIcon)
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.imageScaling = .scaleProportionallyUpOrDown

        let title = NSTextField(labelWithString: ProfileFormatting.title(for: profile))
        title.translatesAutoresizingMaskIntoConstraints = false
        title.font = .systemFont(ofSize: 13.5, weight: .semibold)
        title.lineBreakMode = .byTruncatingMiddle

        var subtitleText = ProfileFormatting.subtitle(for: profile)
        if profile.usageStale == true {
            subtitleText += "  ·  stale · \(ProfileFormatting.updatedAgo(for: profile))"
        }
        let subtitle = NSTextField(labelWithString: subtitleText)
        subtitle.translatesAutoresizingMaskIntoConstraints = false
        subtitle.font = .systemFont(ofSize: 11.5, weight: .medium)
        subtitle.textColor = profile.usageStale == true ? .systemOrange : .secondaryLabelColor
        subtitle.lineBreakMode = .byTruncatingTail

        let dot = StatusDotView()
        dot.translatesAutoresizingMaskIntoConstraints = false
        dot.isRunning = isRunning

        let running = NSTextField(labelWithString: isRunning ? "Open" : "Closed")
        running.translatesAutoresizingMaskIntoConstraints = false
        running.font = .systemFont(ofSize: 10.5, weight: .medium)
        running.textColor = isRunning ? .systemGreen : .tertiaryLabelColor

        let statusStack = NSStackView(views: [dot, running])
        statusStack.translatesAutoresizingMaskIntoConstraints = false
        statusStack.orientation = .horizontal
        statusStack.spacing = 5
        statusStack.alignment = .centerY

        let quotaViews: [NSView]
        if let windows = profile.usage?.windows, !windows.isEmpty {
            quotaViews = windows.prefix(2).map { window in
                let series = showSparklines
                    ? UsageHistoryStore.shared.series(profileID: profile.id, window: window.title)
                    : []
                return QuotaWindowView(window: window, history: series, showSparkline: showSparklines)
            }
        } else {
            let label = NSTextField(labelWithString: ProfileFormatting.usageLines(for: profile, isRefreshing: isRefreshing).first ?? "Usage unavailable")
            label.translatesAutoresizingMaskIntoConstraints = false
            label.font = .systemFont(ofSize: 11, weight: .medium)
            label.textColor = .secondaryLabelColor
            quotaViews = [label]
        }

        let quotaStack = NSStackView(views: quotaViews)
        quotaStack.translatesAutoresizingMaskIntoConstraints = false
        quotaStack.orientation = .vertical
        quotaStack.spacing = 5
        quotaStack.alignment = .leading

        addSubview(icon)
        addSubview(title)
        addSubview(subtitle)
        addSubview(statusStack)
        addSubview(quotaStack)

        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            icon.topAnchor.constraint(equalTo: topAnchor, constant: 14),
            icon.widthAnchor.constraint(equalToConstant: 28),
            icon.heightAnchor.constraint(equalToConstant: 28),

            statusStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            statusStack.topAnchor.constraint(equalTo: topAnchor, constant: 16),

            title.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 12),
            title.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            title.trailingAnchor.constraint(equalTo: statusStack.leadingAnchor, constant: -10),

            subtitle.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            subtitle.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 2),
            subtitle.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),

            quotaStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            quotaStack.topAnchor.constraint(equalTo: subtitle.bottomAnchor, constant: 8),
            quotaStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            quotaStack.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -10)
        ])

        // Stretch each quota row to the full stack width so bars start at the far
        // left and the reset time sits flush right (no dead space on either side).
        for quotaView in quotaViews {
            quotaView.widthAnchor.constraint(equalTo: quotaStack.widthAnchor).isActive = true
        }
    }

    override func updateTrackingAreas() {
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) {
        isHovering = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovering = false
    }

    override func mouseDown(with event: NSEvent) {
        performOpen(self)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard isHovering else { return }
        NSColor.controlAccentColor.withAlphaComponent(0.12).setFill()
        let rect = bounds.insetBy(dx: 8, dy: 5)
        NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8).fill()
    }

    @objc private func performOpen(_ sender: Any?) {
        _ = (actionTarget as? NSObject)?.perform(action, with: self)
    }

    required init?(coder: NSCoder) {
        nil
    }
}


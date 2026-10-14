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
/// account's app icon (Claude/ChatGPT) followed by its 5h % so you can tell them apart.
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

    /// The card's menu-bar pin, when it has one - the menu unpins other cards in place
    /// when a third account bumps one out of the menu bar.
    private(set) var menuBarPin: MenuBarPinView?

    init(profile: LaunchProfile, target: AnyObject, action: Selector, isRefreshing: Bool, isRunning: Bool, showSparklines: Bool = false, warning: String? = nil, inMenuBar: Bool? = nil, onMenuBarToggle: ((String, Bool) -> Void)? = nil) {
        self.profileID = profile.id
        self.actionTarget = target
        self.action = action
        let windowCount = max(1, min(2, profile.usage?.windows.count ?? 0))
        let rowHeight = showSparklines ? 52 : 35
        // The pin and auto-start line only make sense for an account that's signed in.
        let showsControls = inMenuBar != nil && profile.isPendingLogin != true
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
        if let warning {
            subtitleText = "⚠︎ \(warning)"
        }
        let subtitle = NSTextField(labelWithString: subtitleText)
        subtitle.translatesAutoresizingMaskIntoConstraints = false
        subtitle.font = .systemFont(ofSize: 11.5, weight: .medium)
        subtitle.textColor = (profile.usageStale == true || warning != nil) ? .systemOrange : .secondaryLabelColor
        subtitle.lineBreakMode = .byTruncatingTail

        let dot = StatusDotView()
        dot.translatesAutoresizingMaskIntoConstraints = false
        dot.isRunning = isRunning

        let running = NSTextField(labelWithString: isRunning ? "Open" : "Closed")
        running.translatesAutoresizingMaskIntoConstraints = false
        running.font = .systemFont(ofSize: 10.5, weight: .medium)
        running.textColor = isRunning ? .systemGreen : .tertiaryLabelColor

        var statusViews: [NSView] = [dot, running]
        if showsControls {
            let pin = MenuBarPinView(isOn: inMenuBar ?? false)
            let id = profile.id
            pin.onToggle = { on in onMenuBarToggle?(id, on) }
            menuBarPin = pin
            statusViews.append(pin)
        }
        let statusStack = NSStackView(views: statusViews)
        statusStack.translatesAutoresizingMaskIntoConstraints = false
        statusStack.orientation = .horizontal
        statusStack.spacing = 5
        statusStack.alignment = .centerY
        statusStack.setHuggingPriority(.required, for: .horizontal)

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

        // Auto-start reads as one more fact about the account, on the subtitle's line.
        var subtitleTrailing = subtitle.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16)
        if showsControls {
            let autoStart = AutoStartLabel(isOn: profile.autoStartsSession)
            addSubview(autoStart)
            NSLayoutConstraint.activate([
                autoStart.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
                autoStart.centerYAnchor.constraint(equalTo: subtitle.centerYAnchor),
            ])
            subtitleTrailing = subtitle.trailingAnchor.constraint(lessThanOrEqualTo: autoStart.leadingAnchor, constant: -8)
        }

        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            icon.topAnchor.constraint(equalTo: topAnchor, constant: 14),
            icon.widthAnchor.constraint(equalToConstant: 28),
            icon.heightAnchor.constraint(equalToConstant: 28),

            statusStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: showsControls ? -12 : -16),
            statusStack.centerYAnchor.constraint(equalTo: title.centerYAnchor),

            title.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 12),
            title.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            title.trailingAnchor.constraint(lessThanOrEqualTo: statusStack.leadingAnchor, constant: -10),

            subtitle.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            subtitle.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 2),
            subtitleTrailing,

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

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

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


// MARK: - Account card controls

/// A pin in the card's header: whether this account's 5h % sits in the menu bar.
///
/// Pinned, it's filled in the accent color; unpinned, it's a faint outline that firms up
/// under the cursor. Flipping it plays one short spring - the pin drops in when pinned
/// and lifts away when unpinned - and nothing moves after that. It takes its click for
/// itself, so the card underneath doesn't open the app.
final class MenuBarPinView: NSView {
    private(set) var isOn: Bool
    var onToggle: ((Bool) -> Void)?

    private let symbol = CALayer()
    private var trackingArea: NSTrackingArea?
    private var isHovering = false {
        didSet { applyAppearance(animated: true) }
    }

    init(isOn: Bool) {
        self.isOn = isOn
        super.init(frame: NSRect(x: 0, y: 0, width: 22, height: 22))
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 6
        symbol.contentsGravity = .resizeAspect
        layer?.addSublayer(symbol)
        setAccessibilityRole(.checkBox)
        setAccessibilityLabel("Show in menu bar")
        updateToolTip()
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 22),
            heightAnchor.constraint(equalToConstant: 22),
        ])
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        symbol.frame = bounds.insetBy(dx: 4, dy: 4)
        CATransaction.commit()
        applyAppearance(animated: false)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyAppearance(animated: false)
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        applyAppearance(animated: false)
    }

    func setOn(_ on: Bool, animated: Bool) {
        guard on != isOn else { return }
        isOn = on
        setAccessibilityValue(on)
        updateToolTip()
        applyAppearance(animated: animated)
        guard animated else { return }

        // Pinning drops the pin in from slightly above with a little overshoot;
        // unpinning lifts it and lets it settle back. One shot, then still.
        let drop = CASpringAnimation(keyPath: "transform")
        let start = on
            ? CATransform3DScale(CATransform3DMakeTranslation(0, 3, 0), 1.3, 1.3, 1)
            : CATransform3DMakeTranslation(0, 2.5, 0)
        drop.fromValue = NSValue(caTransform3D: start)
        drop.toValue = NSValue(caTransform3D: CATransform3DIdentity)
        drop.damping = 12
        drop.stiffness = 300
        drop.mass = 0.7
        drop.duration = drop.settlingDuration
        symbol.add(drop, forKey: "drop")
    }

    private func updateToolTip() {
        toolTip = isOn ? "Shown in the menu bar - click to hide" : "Show this account's 5h % in the menu bar"
    }

    private func applyAppearance(animated: Bool) {
        let tint: NSColor = isOn ? .controlAccentColor : (isHovering ? .secondaryLabelColor : .tertiaryLabelColor)
        let image = Self.render(isOn ? "pin.fill" : "pin", tint: tint, size: symbol.bounds.size,
                                scale: window?.backingScaleFactor ?? 2, appearance: effectiveAppearance)

        CATransaction.begin()
        CATransaction.setDisableActions(!animated)
        CATransaction.setAnimationDuration(0.18)
        symbol.contents = image
        var hover = NSColor.clear.cgColor
        effectiveAppearance.performAsCurrentDrawingAppearance {
            hover = NSColor.labelColor.withAlphaComponent(isHovering ? 0.08 : 0).cgColor
        }
        layer?.backgroundColor = hover
        CATransaction.commit()
    }

    /// Layers take a bitmap, not a template symbol, so tint and rasterize it here for
    /// the current appearance and screen scale.
    private static func render(_ name: String, tint: NSColor, size: NSSize, scale: CGFloat, appearance: NSAppearance) -> CGImage? {
        guard size.width > 0,
              let base = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: size.height, weight: .semibold)),
              let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else {
            return nil
        }
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        appearance.performAsCurrentDrawingAppearance {
            let aspect = base.size.width / max(base.size.height, 1)
            let height = size.height
            let width = min(size.width, height * aspect)
            let rect = NSRect(x: (size.width - width) / 2, y: 0, width: width, height: height)
            base.draw(in: rect)
            tint.set()
            rect.fill(using: .sourceAtop)
        }
        NSGraphicsContext.restoreGraphicsState()
        return rep.cgImage
    }

    override func updateTrackingAreas() {
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) { isHovering = true }
    override func mouseExited(with event: NSEvent) { isHovering = false }

    /// A menu is never the key window, so the first click has to count.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Flips on mouse-down, the same moment the card reacts to its own clicks, and keeps
    /// the click so the card doesn't open the app.
    override func mouseDown(with event: NSEvent) {
        setOn(!isOn, animated: true)
        onToggle?(isOn)
    }

    override func accessibilityPerformPress() -> Bool {
        setOn(!isOn, animated: true)
        onToggle?(isOn)
        return true
    }
}

/// The account's 5h auto-start setting, written like the rest of the card's details:
/// a small bolt and a word, in the subtitle's type. It's status, not a control - that
/// lives in Settings - so clicks fall through to the card and open the app.
final class AutoStartLabel: NSStackView {
    init(isOn: Bool) {
        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: isOn ? "bolt.fill" : "bolt.slash", accessibilityDescription: nil)
        icon.symbolConfiguration = .init(pointSize: 9, weight: .semibold)
        icon.contentTintColor = isOn ? .systemYellow : .quaternaryLabelColor

        let label = NSTextField(labelWithString: isOn ? "Auto-start" : "Auto-start off")
        label.font = .systemFont(ofSize: 11, weight: .medium)
        label.textColor = isOn ? .secondaryLabelColor : .tertiaryLabelColor

        super.init(frame: .zero)
        setViews([icon, label], in: .leading)
        orientation = .horizontal
        spacing = 3
        alignment = .centerY
        translatesAutoresizingMaskIntoConstraints = false
        setContentCompressionResistancePriority(.required, for: .horizontal)
        toolTip = isOn
            ? "LLMCodeBar starts this account's 5h window when it's idle. Change it in Settings."
            : "The 5h window starts on your first message. Turn on auto-start in Settings."
    }

    required init?(coder: NSCoder) { nil }

    /// Let clicks reach the card underneath.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

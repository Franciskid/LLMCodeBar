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

/// Renders the menu-bar status image: pinned accounts laid out in a grid of up to
/// 3 rows by 3 columns, each cell an app icon (Claude/ChatGPT) followed by its 5h %,
/// optionally with a short label on the icon so two accounts of one app can be told apart.
enum MenuBarBadge {
    struct Row {
        let icon: NSImage
        let percent: Double
        var label: String? = nil
        var weekPercent: Double? = nil
        var fiveHourResetsAt: Date? = nil
        var weekResetsAt: Date? = nil
    }

    struct Layout {
        var rows = 2
        var columns = 1
        var fillsRowsFirst = false
        var showsLabels = false
        /// Only used when the accounts fit on one row.
        var showsWeekly = false
        var resets: MenuBarResetTimes = .none
        var sideBySide = false
    }

    /// Sizes for a grid that uses 1, 2 or 3 rows of the 22pt menu-bar item.
    private struct Metrics {
        let font: CGFloat, icon: CGFloat, rowHeight: CGFloat, gap: CGFloat, columnGap: CGFloat
        let pillFont: CGFloat, pillHeight: CGFloat, pillDrop: CGFloat

        static func forRows(_ rows: Int) -> Metrics {
            switch rows {
            case 1: return Metrics(font: 11.5, icon: 15, rowHeight: 18, gap: 2.5, columnGap: 6, pillFont: 7.6, pillHeight: 8.2, pillDrop: 0.8)
            case 2: return Metrics(font: 9.5, icon: 11, rowHeight: 11, gap: 2.5, columnGap: 6, pillFont: 5.8, pillHeight: 6.2, pillDrop: 0.4)
            default: return Metrics(font: 7.4, icon: 22.0 / 3, rowHeight: 22.0 / 3, gap: 1.5, columnGap: 5, pillFont: 4.4, pillHeight: 4.7, pillDrop: 0.2)
            }
        }

        /// One row with the 5h line above the weekly line, next to a bigger icon.
        static let stacked = Metrics(font: 9, icon: 17, rowHeight: 22, gap: 2.5, columnGap: 8, pillFont: 7.6, pillHeight: 8.2, pillDrop: 0.8)
        /// One row with everything on a single line.
        static let sideBySide = Metrics(font: 11.5, icon: 15, rowHeight: 18, gap: 2.5, columnGap: 8, pillFont: 7.6, pillHeight: 8.2, pillDrop: 0.8)
    }

    /// The badge for the accounts pinned in `config`, or nil when none has usage yet.
    static func image(for config: AppConfig) -> NSImage? {
        let cells: [Row] = config.menuBarProfileIDList.compactMap { id in
            guard let profile = config.profiles.first(where: { $0.id == id }),
                  let percent = ProfileFormatting.primaryUsagePercent(for: profile) else { return nil }
            let icon = NSWorkspace.shared.icon(forFile: Launcher.expanding(profile.appPath))
            return Row(icon: icon, percent: percent, label: profile.menuBarLabelText,
                       weekPercent: profile.usage?.weeklyWindow?.usedPercent,
                       fiveHourResetsAt: profile.usage?.fiveHourWindow?.resetsAt,
                       weekResetsAt: profile.usage?.weeklyWindow?.resetsAt)
        }
        guard !cells.isEmpty else { return nil }
        return image(rows: cells, layout: Layout(
            rows: config.menuBarGridRows, columns: config.menuBarGridColumns,
            fillsRowsFirst: config.fillsMenuBarRowsFirst, showsLabels: config.showsMenuBarLabels,
            showsWeekly: config.showsMenuBarWeekly, resets: config.menuBarResets,
            sideBySide: config.menuBarDetailsSideBySide))
    }

    /// Time left before a reset, in its largest unit only: "3d", "4h", "7m". Nil once
    /// the reset has passed (an idle window has nothing to count down to).
    static func countdown(to date: Date?, now: Date = Date()) -> String? {
        guard let date else { return nil }
        let seconds = date.timeIntervalSince(now)
        guard seconds > 0 else { return nil }
        if seconds >= 86_400 { return "\(Int(seconds / 86_400))d" }
        if seconds >= 3_600 { return "\(Int(seconds / 3_600))h" }
        return "\(max(1, Int(seconds / 60)))m"
    }

    /// Where each of `count` cells goes: down each column first, or along each row first.
    static func positions(count: Int, layout: Layout) -> [(row: Int, column: Int)] {
        guard count > 1 else { return count == 1 ? [(0, 0)] : [] }
        if layout.fillsRowsFirst {
            let perRow = min(layout.columns, count)
            return (0..<count).map { ($0 / perRow, $0 % perRow) }
        }
        let perColumn = min(layout.rows, count)
        return (0..<count).map { ($0 % perColumn, $0 / perColumn) }
    }

    /// What one cell says: the 5h line and, when stacked, the weekly line under it.
    /// Each line is a percent and a countdown, drawn as two columns so the countdowns
    /// line up whatever the width of the percent above or below them.
    private struct CellText {
        struct Line { var percent: NSAttributedString?; var countdown: NSAttributedString? }
        let lines: [Line]
        let space: CGFloat

        var percentWidth: CGFloat { lines.map { $0.percent?.size().width ?? 0 }.max() ?? 0 }
        var countdownWidth: CGFloat { lines.map { $0.countdown?.size().width ?? 0 }.max() ?? 0 }
        var countdownX: CGFloat { percentWidth > 0 ? percentWidth + space : 0 }
        var width: CGFloat { countdownWidth > 0 ? countdownX + countdownWidth : percentWidth }
    }

    static func image(rows cells: [Row], layout: Layout = Layout(), now: Date = Date()) -> NSImage {
        let visible = Array(cells.prefix(layout.rows * layout.columns))
        let pos = positions(count: visible.count, layout: layout)
        let usedRows = (pos.map(\.row).max() ?? 0) + 1
        let usedColumns = (pos.map(\.column).max() ?? 0) + 1

        // The weekly % and reset countdowns only fit when everything is on one row.
        func details(_ row: Row) -> (five: String?, week: String?, weekly: Double?) {
            guard usedRows == 1 else { return (nil, nil, nil) }
            return (layout.resets.showsFiveHour ? countdown(to: row.fiveHourResetsAt, now: now) : nil,
                    layout.resets.showsWeekly ? countdown(to: row.weekResetsAt, now: now) : nil,
                    layout.showsWeekly ? row.weekPercent : nil)
        }
        let hasWeeklyLine = visible.contains { let d = details($0); return d.weekly != nil || d.week != nil }
        let hasDetails = visible.contains { let d = details($0); return d.five != nil || d.weekly != nil || d.week != nil }
        let stacked = hasWeeklyLine && !layout.sideBySide
        let m: Metrics = stacked ? .stacked : (hasDetails ? .sideBySide : .forRows(usedRows))
        let totalHeight = usedRows == 1 && !stacked ? m.rowHeight : 22

        let font = NSFont.monospacedDigitSystemFont(ofSize: m.font, weight: .semibold)
        let dimFont = NSFont.monospacedDigitSystemFont(ofSize: m.font - (stacked ? 0.5 : 1.5), weight: .medium)
        func percent(_ value: Double) -> NSAttributedString {
            NSAttributedString(string: "\(Int(value.rounded()))%",
                               attributes: [.font: font, .foregroundColor: MenuBarIcon.statusColor(for: value)])
        }
        func dim(_ text: String) -> NSAttributedString {
            NSAttributedString(string: text, attributes: [.font: dimFont, .foregroundColor: NSColor.secondaryLabelColor])
        }
        let space = dim(" ").size().width
        let texts: [CellText] = visible.map { row in
            let d = details(row)
            let five = CellText.Line(percent: percent(row.percent), countdown: d.five.map(dim))
            var weekly: CellText.Line?
            if d.weekly != nil || d.week != nil {
                weekly = CellText.Line(percent: d.weekly.map(percent), countdown: d.week.map(dim))
            }
            if stacked { return CellText(lines: [five] + (weekly.map { [$0] } ?? []), space: space) }
            // Side by side: everything on one line, so there's nothing to align.
            let line = NSMutableAttributedString(attributedString: five.percent!)
            if let c = five.countdown { line.append(dim(" ")); line.append(c) }
            if let weekly {
                line.append(dim(" · "))
                if let p = weekly.percent { line.append(p) }
                if let c = weekly.countdown {
                    if weekly.percent != nil { line.append(dim(" ")) }
                    line.append(c)
                }
            }
            return CellText(lines: [CellText.Line(percent: line, countdown: nil)], space: space)
        }
        func textWidth(_ t: CellText) -> CGFloat { t.width }

        var columnWidths = [CGFloat](repeating: 0, count: usedColumns)
        for (i, p) in pos.enumerated() {
            columnWidths[p.column] = max(columnWidths[p.column], m.icon + m.gap + textWidth(texts[i]))
        }
        let width = columnWidths.reduce(0, +) + m.columnGap * CGFloat(usedColumns - 1)

        // Drawn on demand, so the grey countdowns follow the menu bar's light or dark look.
        let image = NSImage(size: NSSize(width: max(1, ceil(width)), height: totalHeight), flipped: false) { _ in
            for (i, p) in pos.enumerated() {
                let x = columnWidths.prefix(p.column).reduce(0, +) + m.columnGap * CGFloat(p.column)
                // Row 0 sits at the top (menu-bar images use a bottom-left origin).
                let rowMidY = totalHeight - (CGFloat(p.row) + 0.5) * m.rowHeight
                let iconRect = NSRect(x: x, y: rowMidY - m.icon / 2, width: m.icon, height: m.icon)
                visible[i].icon.draw(in: iconRect, from: .zero, operation: .sourceOver, fraction: 1)
                if layout.showsLabels, let label = visible[i].label, !label.isEmpty {
                    drawLabel(label, on: iconRect, metrics: m)
                }
                let textX = x + m.icon + m.gap
                let text = texts[i]
                let offsets: [CGFloat] = text.lines.count > 1 ? [5.5, -5.5] : [0]
                for (line, offset) in zip(text.lines, offsets) {
                    for (part, partX) in [(line.percent, textX), (line.countdown, textX + text.countdownX)] {
                        guard let part else { continue }
                        part.draw(at: NSPoint(x: partX, y: rowMidY + offset - part.size().height / 2))
                    }
                }
            }
            return true
        }
        image.isTemplate = false
        return image
    }

    /// A white capsule across the bottom of the icon, like T3 Code's dock badge.
    private static func drawLabel(_ text: String, on icon: NSRect, metrics m: Metrics) {
        let string = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: m.pillFont, weight: .heavy),
            .foregroundColor: NSColor(white: 0.22, alpha: 1),
            .kern: 0.1,
        ])
        let textSize = string.size()
        let height = m.pillHeight
        let width = max(height + 1, textSize.width + m.pillFont * 0.45)
        let rect = NSRect(x: icon.midX - width / 2, y: max(0, icon.minY - m.pillDrop), width: width, height: height)
        let path = NSBezierPath(roundedRect: rect, xRadius: height / 2, yRadius: height / 2)
        NSColor.white.setFill()
        path.fill()
        NSColor(white: 0, alpha: 0.28).setStroke()
        path.lineWidth = 0.5
        path.stroke()
        string.draw(at: NSPoint(x: rect.midX - textSize.width / 2, y: rect.midY - textSize.height / 2 + m.pillFont * 0.03))
    }
}

/// The 3 x 3 grid in Settings for picking the menu-bar layout: hover shows the size
/// you'd get, a click picks it.
final class MenuBarGridPicker: NSView {
    var rows = 2 { didSet { needsDisplay = true } }
    var columns = 1 { didSet { needsDisplay = true } }
    var isEnabled = true { didSet { needsDisplay = true } }
    /// The size under the mouse, or nil when the mouse leaves.
    var onHover: ((rows: Int, columns: Int)?) -> Void = { _ in }
    var onPick: (_ rows: Int, _ columns: Int) -> Void = { _, _ in }

    private var hover: (rows: Int, columns: Int)?
    private let cell = NSSize(width: 18, height: 14)
    private let spacing: CGFloat = 3
    private let inset: CGFloat = 4
    private var maxRows: Int { AppConfig.maxMenuBarRows }
    private var maxColumns: Int { AppConfig.maxMenuBarColumns }

    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize {
        NSSize(width: inset * 2 + CGFloat(maxColumns) * cell.width + CGFloat(maxColumns - 1) * spacing,
               height: inset * 2 + CGFloat(maxRows) * cell.height + CGFloat(maxRows - 1) * spacing)
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    private func size(at point: NSPoint) -> (rows: Int, columns: Int) {
        let column = Int((point.x - inset + spacing / 2) / (cell.width + spacing)) + 1
        let row = Int((point.y - inset + spacing / 2) / (cell.height + spacing)) + 1
        return (min(maxRows, max(1, row)), min(maxColumns, max(1, column)))
    }

    override func mouseMoved(with event: NSEvent) {
        guard isEnabled else { return }
        let s = size(at: convert(event.locationInWindow, from: nil))
        if hover?.rows != s.rows || hover?.columns != s.columns {
            hover = s
            needsDisplay = true
            onHover(s)
        }
    }

    override func mouseExited(with event: NSEvent) {
        hover = nil
        needsDisplay = true
        onHover(nil)
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        let s = size(at: convert(event.locationInWindow, from: nil))
        rows = s.rows
        columns = s.columns
        onPick(s.rows, s.columns)
    }

    override func draw(_ dirtyRect: NSRect) {
        let frame = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6)
        NSColor.controlBackgroundColor.setFill()
        frame.fill()
        NSColor.separatorColor.setStroke()
        frame.stroke()

        let accent = NSColor.controlAccentColor.withAlphaComponent(isEnabled ? 1 : 0.4)
        for r in 1...maxRows {
            for c in 1...maxColumns {
                let rect = NSRect(x: inset + CGFloat(c - 1) * (cell.width + spacing),
                                  y: inset + CGFloat(r - 1) * (cell.height + spacing),
                                  width: cell.width, height: cell.height).insetBy(dx: 0.5, dy: 0.5)
                let path = NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3)
                let chosen = r <= rows && c <= columns
                let hovered = hover.map { r <= $0.rows && c <= $0.columns } ?? false
                if chosen {
                    accent.setFill()
                    path.fill()
                } else if hovered {
                    accent.withAlphaComponent(0.22).setFill()
                    path.fill()
                }
                (chosen || hovered ? accent : NSColor.tertiaryLabelColor).setStroke()
                path.lineWidth = 1
                path.stroke()
            }
        }
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
    init(window: UsageWindow, history: [Double] = [], showSparkline: Bool = false, showLabels: Bool = true, showResets: Bool = true) {
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

        let reset = NSTextField(labelWithString: "Resets " + ProfileFormatting.resetText(for: window))
        reset.translatesAutoresizingMaskIntoConstraints = false
        reset.font = .monospacedDigitSystemFont(ofSize: 10.5, weight: .medium)
        reset.textColor = .secondaryLabelColor
        reset.alignment = .right

        let bar = UsageBarView()
        bar.translatesAutoresizingMaskIntoConstraints = false
        bar.usedPercent = window.usedPercent
        bar.accentColor = Self.color(for: window.usedPercent)

        title.isHidden = !showLabels
        used.isHidden = !showLabels
        reset.isHidden = !showResets
        reset.toolTip = window.resetsAt.map { "Resets " + DateFormatter.localizedString(from: $0, dateStyle: .medium, timeStyle: .short) }
        reset.setContentCompressionResistancePriority(showResets ? .required : .defaultLow, for: .horizontal)
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
            reset.widthAnchor.constraint(equalToConstant: showResets ? 120 : 0),
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
        let showSparklines = profile.showSparklines ?? showSparklines
        let windowCount = max(1, profile.visibleWindows().count)
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
        if profile.usage?.windows.isEmpty == false {
            quotaViews = profile.visibleWindows().map { window in
                let series = showSparklines
                    ? UsageHistoryStore.shared.series(profileID: profile.id, window: window.title)
                    : []
                return QuotaWindowView(window: window, history: series, showSparkline: showSparklines, showLabels: profile.showLabels ?? true, showResets: profile.showResetTimes ?? true)
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

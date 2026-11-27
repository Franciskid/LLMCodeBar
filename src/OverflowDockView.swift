import AppKit
import QuartzCore

/// Compact representation of an account card used by the scrolled-out overflow dock.
struct OverflowAccountSummary {
    let profileID: String
    let providerName: String
    let shortName: String
    let badgeLabel: String
    let appIcon: NSImage
    let primaryPercent: Double?
    let secondaryPercent: Double?
    let isMonthlyOnly: Bool
    let tooltip: String
}

/// App icon with the account's short white-capsule label across its bottom edge,
/// matching the menu bar badge style so multiple accounts of one app stay distinct.
final class BadgedAppIconView: NSView {
    static let size = NSSize(width: 22, height: 22)

    private let icon: NSImage
    private let badgeLabel: String

    init(icon: NSImage, badgeLabel: String) {
        self.icon = icon
        self.badgeLabel = badgeLabel
        super.init(frame: NSRect(origin: .zero, size: Self.size))
    }

    required init?(coder: NSCoder) { nil }

    override var intrinsicContentSize: NSSize { Self.size }

    override func draw(_ dirtyRect: NSRect) {
        let iconRect = NSRect(x: 2, y: 3, width: 18, height: 18)
        icon.draw(in: iconRect, from: .zero, operation: .sourceOver, fraction: 1)

        guard !badgeLabel.isEmpty else { return }
        let pillFont: CGFloat = 7.2
        let text = NSAttributedString(string: badgeLabel, attributes: [
            .font: NSFont.systemFont(ofSize: pillFont, weight: .heavy),
            .foregroundColor: NSColor(white: 0.22, alpha: 1),
            .kern: 0.1,
        ])
        let textSize = text.size()
        let pillHeight: CGFloat = 8.8
        let pillWidth = max(pillHeight + 3, textSize.width + 4.5)
        let pillRect = NSRect(
            x: max(0.5, min(bounds.width - pillWidth - 0.5, iconRect.midX - pillWidth / 2)),
            y: 0.5,
            width: pillWidth,
            height: pillHeight
        )
        let pill = NSBezierPath(roundedRect: pillRect, xRadius: pillHeight / 2, yRadius: pillHeight / 2)
        NSColor.white.setFill()
        pill.fill()
        NSColor(white: 0, alpha: 0.28).setStroke()
        pill.lineWidth = 0.5
        pill.stroke()
        text.draw(at: NSPoint(
            x: pillRect.midX - textSize.width / 2,
            y: pillRect.midY - textSize.height / 2 + 0.2
        ))
    }
}

/// Concentric circular gauge: outer ring for the 5h session limit and inner ring for
/// the 7d weekly limit, or a single bold ring for monthly-only accounts (Mistral).
final class ConcentricRingView: NSView {
    static let size = NSSize(width: 24, height: 24)

    private let primaryPercent: Double?
    private let secondaryPercent: Double?
    private let isMonthlyOnly: Bool

    init(primaryPercent: Double?, secondaryPercent: Double?, isMonthlyOnly: Bool) {
        self.primaryPercent = primaryPercent
        self.secondaryPercent = secondaryPercent
        self.isMonthlyOnly = isMonthlyOnly
        super.init(frame: NSRect(origin: .zero, size: Self.size))
    }

    required init?(coder: NSCoder) { nil }

    override var intrinsicContentSize: NSSize { Self.size }

    override func draw(_ dirtyRect: NSRect) {
        let center = NSPoint(x: bounds.midX, y: bounds.midY)
        guard let primaryPercent else {
            drawRing(center: center, radius: 8.2, lineWidth: 2.4, percent: nil)
            return
        }
        if !isMonthlyOnly, let secondaryPercent {
            drawRing(center: center, radius: 9.2, lineWidth: 2.5, percent: primaryPercent)
            drawRing(center: center, radius: 5.3, lineWidth: 2.3, percent: secondaryPercent)
        } else {
            drawRing(center: center, radius: 8.2, lineWidth: 3.1, percent: primaryPercent)
        }
    }

    private func drawRing(center: NSPoint, radius: CGFloat, lineWidth: CGFloat, percent: Double?) {
        let trackRect = NSRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
        let track = NSBezierPath(ovalIn: trackRect)
        track.lineWidth = lineWidth
        NSColor.labelColor.withAlphaComponent(0.14).setStroke()
        track.stroke()

        guard let percent, percent > 0.1 else { return }
        let color = QuotaWindowView.color(for: percent)
        color.setStroke()
        if percent >= 99.5 {
            let full = NSBezierPath(ovalIn: trackRect)
            full.lineWidth = lineWidth
            full.stroke()
            return
        }
        let frac = max(0.025, min(1.0, percent / 100.0))
        let arc = NSBezierPath()
        arc.lineWidth = lineWidth
        arc.lineCapStyle = .round
        arc.appendArc(
            withCenter: center,
            radius: radius,
            startAngle: 90,
            endAngle: 90 - CGFloat(360.0 * frac),
            clockwise: true
        )
        arc.stroke()
    }
}

/// One compact account chip inside the bottom overflow dock: app icon + label pill,
/// concentric 5h/7d ring, and stacked percentage readout. Clicking scrolls to that card.
final class CompressedAccountChipView: NSView {
    static let height: CGFloat = 32

    override var isFlipped: Bool { true }

    let profileID: String
    let naturalWidth: CGFloat
    var onSelect: (() -> Void)?

    private var trackingArea: NSTrackingArea?
    private var isHovering = false {
        didSet {
            guard isHovering != oldValue else { return }
            applyChrome()
        }
    }

    init(summary: OverflowAccountSummary, onSelect: (() -> Void)? = nil) {
        self.profileID = summary.profileID
        self.onSelect = onSelect

        let topText: String
        let topColor: NSColor
        let bottomText: String?
        let bottomColor: NSColor

        if let p1 = summary.primaryPercent {
            topText = "\(Int(p1.rounded()))%"
            topColor = Self.textColor(for: p1, primary: true)
            if !summary.isMonthlyOnly, let p2 = summary.secondaryPercent {
                bottomText = "\(Int(p2.rounded()))%"
                bottomColor = Self.textColor(for: p2, primary: false)
            } else {
                bottomText = summary.isMonthlyOnly ? "1m" : "5h"
                bottomColor = .tertiaryLabelColor
            }
        } else {
            topText = "–"
            topColor = .tertiaryLabelColor
            bottomText = nil
            bottomColor = .tertiaryLabelColor
        }

        let topFont = NSFont.monospacedDigitSystemFont(ofSize: 9.5, weight: .semibold)
        let bottomFont = NSFont.monospacedDigitSystemFont(ofSize: 8.5, weight: .medium)
        let topW = ceil((topText as NSString).size(withAttributes: [.font: topFont]).width)
        let botW = bottomText.map { ceil(($0 as NSString).size(withAttributes: [.font: bottomFont]).width) } ?? 0
        let textColWidth = max(18, max(topW, botW))

        let leftPad: CGFloat = 6
        let iconGap: CGFloat = 5
        let ringGap: CGFloat = 4
        let rightPad: CGFloat = 7
        let width = leftPad + BadgedAppIconView.size.width + iconGap + ConcentricRingView.size.width + ringGap + textColWidth + rightPad
        self.naturalWidth = width

        super.init(frame: NSRect(x: 0, y: 0, width: width, height: Self.height))
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.borderWidth = 0.5
        toolTip = summary.tooltip
        setAccessibilityRole(.button)
        setAccessibilityLabel("\(summary.providerName) \(summary.shortName)")

        let iconView = BadgedAppIconView(icon: summary.appIcon, badgeLabel: summary.badgeLabel)
        iconView.frame = NSRect(
            x: leftPad,
            y: (Self.height - BadgedAppIconView.size.height) / 2,
            width: BadgedAppIconView.size.width,
            height: BadgedAppIconView.size.height
        )
        addSubview(iconView)

        let ringX = iconView.frame.maxX + iconGap
        let ringView = ConcentricRingView(
            primaryPercent: summary.primaryPercent,
            secondaryPercent: summary.secondaryPercent,
            isMonthlyOnly: summary.isMonthlyOnly
        )
        ringView.frame = NSRect(
            x: ringX,
            y: (Self.height - ConcentricRingView.size.height) / 2,
            width: ConcentricRingView.size.width,
            height: ConcentricRingView.size.height
        )
        addSubview(ringView)

        let textX = ringView.frame.maxX + ringGap
        if let bottomText {
            let topLabel = Self.makeLabel(topText, font: topFont, color: topColor)
            topLabel.frame = NSRect(x: textX, y: 4, width: textColWidth, height: 12)
            addSubview(topLabel)

            let bottomLabel = Self.makeLabel(bottomText, font: bottomFont, color: bottomColor)
            bottomLabel.frame = NSRect(x: textX, y: 16, width: textColWidth, height: 11)
            addSubview(bottomLabel)
        } else {
            let label = Self.makeLabel(topText, font: topFont, color: topColor)
            label.frame = NSRect(x: textX, y: (Self.height - 12) / 2, width: textColWidth, height: 12)
            addSubview(label)
        }

        applyChrome()
    }

    required init?(coder: NSCoder) { nil }

    private static func makeLabel(_ text: String, font: NSFont, color: NSColor) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = font
        label.textColor = color
        label.alignment = .left
        label.lineBreakMode = .byClipping
        return label
    }

    private static func textColor(for percent: Double, primary: Bool) -> NSColor {
        if percent >= 99.5 { return .systemRed }
        if percent >= min(QuotaWindowView.warnAt, 95) { return .systemOrange }
        return primary ? .labelColor : .secondaryLabelColor
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyChrome()
    }

    private func applyChrome() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(isHovering ? 0.11 : 0.055).cgColor
            layer?.borderColor = (isHovering
                ? NSColor.controlAccentColor.withAlphaComponent(0.45)
                : NSColor.separatorColor.withAlphaComponent(0.6)).cgColor
        }
        CATransaction.commit()
    }

    override func updateTrackingAreas() {
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) { isHovering = true }
    override func mouseExited(with event: NSEvent) { isHovering = false }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        onSelect?()
        keepRestOfClick(event)
    }

    override func accessibilityPerformPress() -> Bool {
        onSelect?()
        return true
    }
}

/// Fixed-height horizontal dock below the scrollable accounts list. Every account's
/// compact chip is pre-built once and scrubbed smoothly 1:1 with the native scroll
/// offset as cards enter or leave the visible viewport — zero view churn during scroll.
final class OverflowDockView: NSView {
    static let width: CGFloat = 320
    static let height: CGFloat = 46
    private static let horizontalInset: CGFloat = 12
    private static let chipGap: CGFloat = 6

    override var isFlipped: Bool { true }

    private struct Slot {
        let clip: ClipView
        let chip: CompressedAccountChipView
        let fullWidth: CGFloat
    }

    private let separator = NSBox()
    private var slots: [Slot] = []
    private(set) var visibilities: [CGFloat] = []
    var onSelectIndex: ((Int) -> Void)?

    init(summaries: [OverflowAccountSummary]) {
        super.init(frame: NSRect(x: 0, y: 0, width: Self.width, height: Self.height))
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        layer?.masksToBounds = true

        separator.boxType = .separator
        separator.frame = NSRect(
            x: Self.horizontalInset,
            y: 0,
            width: Self.width - Self.horizontalInset * 2,
            height: 1
        )
        addSubview(separator)

        var built: [Slot] = []
        for (index, summary) in summaries.enumerated() {
            let clip = ClipView(frame: .zero)
            clip.isHidden = true
            let chip = CompressedAccountChipView(summary: summary) { [weak self] in
                self?.onSelectIndex?(index)
            }
            chip.frame = NSRect(x: 0, y: 0, width: chip.naturalWidth, height: CompressedAccountChipView.height)
            clip.addSubview(chip)
            addSubview(clip)
            built.append(Slot(clip: clip, chip: chip, fullWidth: chip.naturalWidth))
        }
        self.slots = built
        self.visibilities = Array(repeating: -1, count: built.count)
    }

    required init?(coder: NSCoder) { nil }

    /// Smoothstep chip visibility (0 = card is in view, 1 = card is scrolled out of view).
    /// Ramps smoothly as a card goes from 35% hidden to 85% hidden so half-scrolling feels
    /// natural with no sudden pop or forced snapping.
    static func visibility(forCardRect cardRect: NSRect, inVisibleRect visibleRect: NSRect) -> CGFloat {
        guard cardRect.height > 0 else { return 0 }
        let overlap = max(0, min(cardRect.maxY, visibleRect.maxY) - max(cardRect.minY, visibleRect.minY))
        let hiddenFrac = 1 - (overlap / cardRect.height)
        let raw = min(1, max(0, (hiddenFrac - 0.35) / (0.85 - 0.35)))
        return raw * raw * (3 - 2 * raw)
    }

    /// Scrubs pre-mounted chips to match each card's current hidden visibility [0...1].
    func update(visibilities next: [CGFloat]) {
        guard next.count == slots.count else { return }
        var changed = false
        for i in 0..<next.count {
            if abs(next[i] - visibilities[i]) > 0.0005 {
                changed = true
                break
            }
        }
        guard changed else { return }
        visibilities = next

        let availableWidth = Self.width - Self.horizontalInset * 2
        var activeWidths: CGFloat = 0
        var activeGapWeight: CGFloat = 0
        var lastActiveT: CGFloat = 0
        for (slot, t) in zip(slots, next) where t > 0.002 {
            activeWidths += slot.fullWidth * t
            activeGapWeight += t
            lastActiveT = t
        }
        let totalGap = max(0, activeGapWeight - lastActiveT) * Self.chipGap
        let desiredTotal = activeWidths + totalGap
        let scaleFit: CGFloat = desiredTotal > availableWidth && desiredTotal > 0
            ? availableWidth / desiredTotal
            : 1.0

        let chipY = (Self.height - CompressedAccountChipView.height) / 2 + 0.5
        let cy = CompressedAccountChipView.height / 2

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        var x = Self.horizontalInset
        for (slot, t) in zip(slots, next) {
            if t <= 0.002 {
                if !slot.clip.isHidden { slot.clip.isHidden = true }
                continue
            }
            if slot.clip.isHidden { slot.clip.isHidden = false }
            let w = slot.fullWidth * t * scaleFit
            slot.clip.frame = NSRect(x: x, y: chipY, width: w, height: CompressedAccountChipView.height)

            let s = (0.88 + 0.12 * t) * scaleFit
            let ty = (1 - t) * 4
            var transform = CATransform3DIdentity
            transform = CATransform3DTranslate(transform, 0, cy + ty, 0)
            transform = CATransform3DScale(transform, s, s, 1)
            transform = CATransform3DTranslate(transform, 0, -cy, 0)
            slot.chip.layer?.transform = transform
            slot.chip.layer?.opacity = Float(t)

            x += w + Self.chipGap * t * scaleFit
        }
        CATransaction.commit()
    }
}

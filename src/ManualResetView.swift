import AppKit

/// The approved inline reset layout: one caption and compact, date-only chips.
final class ManualResetView: NSView {
    private let contentHeight: CGFloat
    override var intrinsicContentSize: NSSize { NSSize(width: 288, height: contentHeight) }

    init(inventory: ManualResetInventory?, width: CGFloat = 288, now: Date = Date()) {
        let caption = NSTextField(labelWithString: inventory?.error != nil ? "Manual resets · cached" : "Manual resets")
        caption.font = .systemFont(ofSize: 10.5, weight: .medium)
        caption.textColor = .secondaryLabelColor
        var chips: [ResetChip] = []
        if let inventory {
            let held = inventory.allowances.filter { $0.unexpired(at: now) }
            let groups = Dictionary(grouping: held) { grant in
                grant.kind + (grant.startsAt.map { $0 > now ? ".\($0.timeIntervalSince1970)" : "" } ?? "")
            }.values.sorted {
                ($0.compactMap(\.expiresAt).min() ?? .distantFuture) < ($1.compactMap(\.expiresAt).min() ?? .distantFuture)
            }
            for group in groups {
                let sorted = group.sorted { ($0.expiresAt ?? .distantFuture) < ($1.expiresAt ?? .distantFuture) }
                let count = sorted.reduce(0) { $0 + $1.count }
                let dates = sorted.map { $0.expiresAt.map { ManualResetInventory.dateText($0, now: now) } ?? "—" }.joined(separator: " · ")
                var title = "\(sorted[0].kind) ×\(count)"
                if let starts = sorted[0].startsAt, starts > now { title += " from \(ManualResetInventory.dateText(starts, now: now))" }
                chips.append(ResetChip(title: title, dates: dates, maxWidth: width))
            }
            if chips.isEmpty { caption.stringValue = inventory.error == nil ? "Manual resets · none available" : "Manual resets · unavailable" }
        } else { caption.stringValue = "Manual resets · not refreshed yet" }
        var x: CGFloat = 0, y: CGFloat = 18, lineHeight: CGFloat = 0
        for chip in chips {
            if x > 0 && x + chip.frame.width > width { x = 0; y += lineHeight + 5; lineHeight = 0 }
            chip.setFrameOrigin(NSPoint(x: x, y: y))
            x += chip.frame.width + 5; lineHeight = max(lineHeight, chip.frame.height)
        }
        contentHeight = chips.isEmpty ? 14 : y + lineHeight
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: contentHeight))
        translatesAutoresizingMaskIntoConstraints = false
        caption.frame = NSRect(x: 0, y: 0, width: width, height: 14)
        addSubview(caption)
        chips.forEach(addSubview)
        toolTip = inventory?.error
        heightAnchor.constraint(equalToConstant: contentHeight).isActive = true
    }
    override var isFlipped: Bool { true }
    required init?(coder: NSCoder) { nil }
}

private final class ResetChip: NSView {
    init(title: String, dates: String, maxWidth: CGFloat) {
        let text = NSMutableAttributedString(string: title + "  ", attributes: [.font: NSFont.systemFont(ofSize: 10.5, weight: .medium), .foregroundColor: NSColor.labelColor])
        text.append(NSAttributedString(string: dates, attributes: [.font: NSFont.systemFont(ofSize: 10.5), .foregroundColor: NSColor.secondaryLabelColor]))
        let width = min(maxWidth, ceil(text.size().width) + 14)
        let textHeight = ceil(text.boundingRect(with: NSSize(width: width - 14, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading]).height)
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: max(22, textHeight + 8)))
        let field = NSTextField(wrappingLabelWithString: "")
        field.attributedStringValue = text
        field.frame = NSRect(x: 5, y: 3, width: width - 10, height: frame.height - 6)
        field.maximumNumberOfLines = 0
        addSubview(field)
        setAccessibilityElement(true); setAccessibilityRole(.staticText); setAccessibilityValue(title + ", " + dates)
    }
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.quaternaryLabelColor.withAlphaComponent(0.15).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 4, yRadius: 4).fill()
    }
    required init?(coder: NSCoder) { nil }
}

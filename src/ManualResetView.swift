import AppKit

/// An account's manual resets on one quiet line under its limits: a reset symbol, then
/// each kind with its count and expiry dates ("Fable ×1 17 Nov   Full ×1 10 Dec").
/// It wraps onto a second line only when it has to. With nothing to show it's empty,
/// and the card leaves it out.
final class ManualResetView: NSView {
    private let contentHeight: CGFloat
    /// No resets held (or none read yet): the card shows no line at all.
    let isEmpty: Bool
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: contentHeight) }

    private static let symbolWidth: CGFloat = 16

    /// `indent` lines the symbol up with where the limit bars start.
    init(inventory: ManualResetInventory?, width: CGFloat = 288, indent: CGFloat = 0, now: Date = Date()) {
        var groups: [(title: String, dates: String)] = []
        if let inventory {
            let held = inventory.allowances.filter { $0.unexpired(at: now) }
            let byKind = Dictionary(grouping: held) { grant in
                grant.kind + (grant.startsAt.map { $0 > now ? ".\($0.timeIntervalSince1970)" : "" } ?? "")
            }.values.sorted {
                ($0.compactMap(\.expiresAt).min() ?? .distantFuture) < ($1.compactMap(\.expiresAt).min() ?? .distantFuture)
            }
            for group in byKind {
                let sorted = group.sorted { ($0.expiresAt ?? .distantFuture) < ($1.expiresAt ?? .distantFuture) }
                let count = sorted.reduce(0) { $0 + $1.count }
                let dates = sorted.map { $0.expiresAt.map { ManualResetInventory.dateText($0, now: now) } ?? "no expiry" }.joined(separator: " · ")
                var title = "\(sorted[0].kind) ×\(count)"
                if let starts = sorted[0].startsAt, starts > now { title += " from \(ManualResetInventory.dateText(starts, now: now))" }
                groups.append((title, dates))
            }
        }
        isEmpty = groups.isEmpty

        let text = NSMutableAttributedString()
        let font = NSFont.systemFont(ofSize: 11)
        for (index, group) in groups.enumerated() {
            if index > 0 { text.append(NSAttributedString(string: "    ", attributes: [.font: font])) }
            text.append(NSAttributedString(string: group.title, attributes: [.font: NSFont.systemFont(ofSize: 11, weight: .medium), .foregroundColor: NSColor.labelColor]))
            text.append(NSAttributedString(string: " " + group.dates, attributes: [.font: font, .foregroundColor: NSColor.secondaryLabelColor]))
        }
        if inventory?.error != nil, !groups.isEmpty {
            text.append(NSAttributedString(string: "  · cached", attributes: [.font: font, .foregroundColor: NSColor.tertiaryLabelColor]))
        }
        let textWidth = max(40, width - indent - Self.symbolWidth)
        let textHeight = groups.isEmpty ? 0 : ceil(text.boundingRect(with: NSSize(width: textWidth - 4, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading]).height)
        contentHeight = groups.isEmpty ? 0 : max(15, textHeight + 1)
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: contentHeight))
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: contentHeight).isActive = true
        widthAnchor.constraint(equalToConstant: width).isActive = true
        guard !groups.isEmpty else { return }

        let symbol = NSImageView(image: NSImage(systemSymbolName: "arrow.counterclockwise", accessibilityDescription: "Manual resets") ?? NSImage())
        symbol.symbolConfiguration = .init(pointSize: 9.5, weight: .semibold)
        symbol.contentTintColor = .secondaryLabelColor
        symbol.frame = NSRect(x: indent, y: 1, width: 11, height: 13)

        let field = NSTextField(wrappingLabelWithString: "")
        field.attributedStringValue = text
        field.maximumNumberOfLines = 0
        field.frame = NSRect(x: indent + Self.symbolWidth - 2, y: 0, width: textWidth, height: contentHeight)
        addSubview(symbol)
        addSubview(field)

        toolTip = "Manual resets you can use, with when they expire" + (inventory?.error.map { "\nCouldn't refresh: \($0)" } ?? "")
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel("Manual resets")
        setAccessibilityValue(groups.map { "\($0.title), \($0.dates)" }.joined(separator: "; "))
    }

    override var isFlipped: Bool { true }
    required init?(coder: NSCoder) { nil }
}

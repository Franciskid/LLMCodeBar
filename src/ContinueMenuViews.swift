import AppKit
import QuartzCore

// The "Continue after limits" part of the menu: a checkbox row with a gear and a
// chevron, and under it the sessions list, which opens inside the menu itself. While it
// opens, the account cards above fold into one line each, so the list pushes the menu up
// as much as down.
//
// Every change sets the final layout once, inside one Core Animation transaction, and the
// render server moves the views there: nothing is laid out or drawn per frame on the main
// thread, so the animation stays smooth whatever else the app is doing. The one thing that
// follows by hand is the menu's own height (MenuTopView), on the same curve.

// MARK: - Motion

final class MenuMotion {
    static let duration: CFTimeInterval = 0.42
    private static let curve = (x1: 0.2, y1: 0.9, x2: 0.25, y2: 1.0)
    static let timing = CAMediaTimingFunction(controlPoints: Float(curve.x1), Float(curve.y1), Float(curve.x2), Float(curve.y2))

    static var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    private var layoutHandlers: [(Bool) -> Void] = []

    /// Runs after every change, inside the same animation, told whether it animates.
    func onLayout(_ handler: @escaping (Bool) -> Void) { layoutHandlers.append(handler) }

    /// Applies `changes` (new frames and opacities) and animates the views to them.
    func transition(animated: Bool = true, _ changes: () -> Void) {
        if animated && !Self.reduceMotion {
            let outer = !Self.animating
            if outer { Self.finishShrinking() }
            Self.animating = true
            NSAnimationContext.runAnimationGroup { context in
                context.duration = Self.duration
                context.timingFunction = Self.timing
                context.allowsImplicitAnimation = true
                changes()
                layoutHandlers.forEach { $0(true) }
            }
            if outer { Self.animating = false }
        } else {
            NSAnimationContext.beginGrouping()
            NSAnimationContext.current.duration = 0
            NSAnimationContext.current.allowsImplicitAnimation = false
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            changes()
            layoutHandlers.forEach { $0(false) }
            CATransaction.commit()
            NSAnimationContext.endGrouping()
        }
    }

    /// Changes that happen at once even inside a transition: new text, new icons,
    /// views being added. Only sizes and positions should move.
    static func instantly(_ changes: () -> Void) {
        let was = animating
        animating = false
        NSAnimationContext.beginGrouping()
        NSAnimationContext.current.duration = 0
        NSAnimationContext.current.allowsImplicitAnimation = false
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        changes()
        CATransaction.commit()
        NSAnimationContext.endGrouping()
        animating = was
    }

    // MARK: Shrinking

    /// Inside an animated transition.
    private static var animating = false
    /// Views shrinking: what their frame will be once the animation is over.
    private static var shrinking: [ObjectIdentifier: (view: NSView, frame: NSRect)] = [:]
    private static var finishTimer: Timer?

    /// Sets a view's frame. A view that shrinks while animating keeps its height until
    /// the animation is over and only its layer gets smaller: AppKit stops drawing
    /// whatever lies outside a view's frame, so a folding card would lose its bars and
    /// graphs at the first frame instead of watching them fold away.
    static func place(_ view: NSView, _ frame: NSRect) {
        let id = ObjectIdentifier(view)
        if finalFrame(of: view) == frame { return }
        guard animating, frame.height < view.frame.height - 0.25, let layer = view.layer else {
            if shrinking.removeValue(forKey: id) != nil { layer(of: view)?.removeAnimation(forKey: "shrink") }
            if view.frame != frame { view.frame = frame }
            return
        }
        shrinking[id] = (view, frame)
        let model = NSRect(origin: frame.origin, size: NSSize(width: frame.width, height: view.frame.height))
        if view.frame != model { view.frame = model }
        let from = layer.presentation()?.bounds ?? layer.bounds
        let to = CGRect(origin: layer.bounds.origin, size: CGSize(width: layer.bounds.width, height: frame.height))
        let shrink = CABasicAnimation(keyPath: "bounds")
        shrink.fromValue = NSValue(rect: from)
        shrink.toValue = NSValue(rect: to)
        shrink.duration = duration
        shrink.timingFunction = timing
        shrink.fillMode = .forwards
        shrink.isRemovedOnCompletion = false
        layer.add(shrink, forKey: "shrink")
        finishTimer?.invalidate()
        let timer = Timer(timeInterval: duration + 0.03, repeats: false) { _ in finishShrinking() }
        RunLoop.main.add(timer, forMode: .common)
        finishTimer = timer
    }

    /// The frame a view is on its way to.
    static func finalFrame(of view: NSView) -> NSRect {
        shrinking[ObjectIdentifier(view)]?.frame ?? view.frame
    }

    /// Gives every shrinking view its final frame.
    static func finishShrinking() {
        finishTimer?.invalidate()
        finishTimer = nil
        let done = shrinking.values
        shrinking = [:]
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (view, frame) in done {
            view.frame = frame
            view.layer?.removeAnimation(forKey: "shrink")
        }
        CATransaction.commit()
    }

    private static func layer(of view: NSView) -> CALayer? { view.layer }

    /// How far along the curve the animation is at `t` (0 to 1 of its duration), for
    /// what follows it by hand.
    static func progress(_ t: Double) -> Double {
        let t = min(1, max(0, t))
        let (x1, y1, x2, y2) = curve
        func bezier(_ u: Double, _ a: Double, _ b: Double) -> Double {
            let v = 1 - u
            return 3 * v * v * u * a + 3 * v * u * u * b + u * u * u
        }
        // Find u where the curve's x is t, then read its y.
        var low = 0.0, high = 1.0, u = t
        for _ in 0..<30 {
            let x = bezier(u, x1, x2)
            if abs(x - t) < 1e-5 { break }
            if x < t { low = u } else { high = u }
            u = (low + high) / 2
        }
        return bezier(u, y1, y2)
    }
}

private func clamp01(_ value: CGFloat) -> CGFloat { min(1, max(0, value)) }

extension NSView {
    /// Our menu controls act on mouse-down, so they answer at once. But the menu fires
    /// whatever item is under the pointer when the button comes back up, and a click that
    /// opens or folds something moves other items under it (Activity Log, say) before the
    /// release. So the control keeps the rest of its own click: it takes the drags and the
    /// release here, and the menu never sees them.
    func keepRestOfClick(_ event: NSEvent) {
        guard event.type == .leftMouseDown, let window else { return }
        let held = NSEvent.pressedMouseButtons & 1 != 0
        // Released already: the mouse-up is waiting in the queue, take it if it's there.
        let until = held ? Date(timeIntervalSinceNow: 30) : Date()
        while let next = window.nextEvent(matching: [.leftMouseUp, .leftMouseDragged],
                                          until: until, inMode: .eventTracking, dequeue: true) {
            if next.type == .leftMouseUp { return }
        }
    }
}

/// Rounded to the screen's pixels, so a spring's tiny last steps don't move anything.
private func pixel(_ value: CGFloat) -> CGFloat {
    let scale = NSScreen.main?.backingScaleFactor ?? 2
    return (value * scale).rounded() / scale
}

/// A frame set only when it changes (setting even the same frame makes AppKit lay out
/// and redisplay), and shrunk the way MenuMotion.place says.
private func setFrame(of view: NSView, _ frame: NSRect) {
    MenuMotion.place(view, frame)
}
private func lerp(_ a: CGFloat, _ b: CGFloat, _ t: CGFloat) -> CGFloat { a + (b - a) * t }

/// A container that hides whatever overflows it - the way a folding part disappears.
final class ClipView: NSView {
    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        layer?.masksToBounds = true
    }

    required init?(coder: NSCoder) { nil }
}

// MARK: - The top of the menu

/// The account cards and the "Continue after limits" panel in one menu item. The menu
/// window takes its size from this view: the children animate to their new frames on
/// the render server, and this view's height follows them, frame by frame, on the same
/// curve, so the menu's bottom edge moves with them and nothing else is redone.
final class MenuTopView: NSView {
    override var isFlipped: Bool { true }
    private let accounts: AccountsFoldView?
    private let panel: ContinuePanelView
    private static let separatorHeight: CGFloat = 11
    /// The separator a menu would draw between the cards and the panel.
    private let separator = NSBox()
    private var heightTimer: Timer?

    /// `motion` is the one both were made with, so this lays out after them.
    init(accounts: AccountsFoldView?, panel: ContinuePanelView, motion: MenuMotion) {
        self.accounts = accounts
        self.panel = panel
        super.init(frame: NSRect(x: 0, y: 0, width: ContinuePanelView.width, height: 100))
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        autoresizesSubviews = false
        if let accounts { addSubview(accounts) }
        separator.boxType = .separator
        separator.isHidden = accounts == nil
        addSubview(separator)
        addSubview(panel)
        motion.onLayout { [weak self] animated in self?.layoutChildren(animated: animated) }
        layoutChildren(animated: false)
    }

    required init?(coder: NSCoder) { nil }

    deinit { heightTimer?.invalidate() }

    private func layoutChildren(animated: Bool) {
        var y: CGFloat = 0
        if let accounts {
            let height = MenuMotion.finalFrame(of: accounts).height
            setFrame(of: accounts, NSRect(origin: .zero, size: NSSize(width: ContinuePanelView.width, height: height)))
            y = height + Self.separatorHeight
            setFrame(of: separator, NSRect(x: 14, y: height + 5, width: ContinuePanelView.width - 28, height: 1))
        }
        let panelHeight = MenuMotion.finalFrame(of: panel).height
        setFrame(of: panel, NSRect(origin: NSPoint(x: 0, y: y), size: NSSize(width: ContinuePanelView.width, height: panelHeight)))
        follow(to: y + panelHeight, animated: animated)
    }

    /// Moves this view's height to `target` along the animation's curve.
    private func follow(to target: CGFloat, animated: Bool) {
        heightTimer?.invalidate()
        heightTimer = nil
        let from = frame.height
        guard animated, abs(from - target) > 0.5, !MenuMotion.reduceMotion else {
            setHeight(target)
            return
        }
        let start = CACurrentMediaTime()
        let timer = Timer(timeInterval: 1.0 / 120, repeats: true) { [weak self] timer in
            guard let self else { return timer.invalidate() }
            let t = (CACurrentMediaTime() - start) / MenuMotion.duration
            self.setHeight(from + (target - from) * CGFloat(MenuMotion.progress(t)))
            if t >= 1 {
                self.setHeight(target)
                timer.invalidate()
                self.heightTimer = nil
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        heightTimer = timer
    }

    private func setHeight(_ height: CGFloat) {
        let height = pixel(height)
        guard frame.height != height else { return }
        // Outside any animation: the menu reads the size straight away.
        NSAnimationContext.beginGrouping()
        NSAnimationContext.current.duration = 0
        NSAnimationContext.current.allowsImplicitAnimation = false
        setFrameSize(NSSize(width: ContinuePanelView.width, height: height))
        NSAnimationContext.endGrouping()
    }
}

// MARK: - Accounts

/// The account cards, under their app headers, in one menu item so they can fold into a
/// line each. More than `maxFullCards` cards scroll.
final class AccountsFoldView: NSView {
    override var isFlipped: Bool { true }

    private struct Entry {
        var clip: ClipView
        var content: NSView
        var full: CGFloat
        var folded: CGFloat
        var shift: CGFloat
    }

    private let motion: MenuMotion
    private var folded = false
    private var entries: [Entry] = []
    private let document = FlippedView()
    private var scroll: NSScrollView?
    private let fullCap: CGFloat
    private static let width: CGFloat = 320

    init(views: [NSView], maxFullCards: Int = 3, motion: MenuMotion = MenuMotion()) {
        self.motion = motion
        var fullCap: CGFloat = 0
        var cards = 0
        var all: [Entry] = []
        for view in views {
            let full = view.frame.height
            let isCard = view is ProfileMenuItemView
            if isCard { cards += 1 }
            if cards <= maxFullCards { fullCap += full }
            let clip = ClipView(frame: NSRect(x: 0, y: 0, width: Self.width, height: full))
            view.frame = NSRect(x: 0, y: 0, width: Self.width, height: full)
            clip.addSubview(view)
            all.append(Entry(clip: clip, content: view, full: full,
                             folded: isCard ? ProfileMenuItemView.foldedHeight : 20,
                             shift: isCard ? ProfileMenuItemView.foldedShift : 3))
        }
        self.fullCap = cards > maxFullCards ? fullCap : .greatestFiniteMagnitude
        self.entries = all
        super.init(frame: NSRect(x: 0, y: 0, width: Self.width, height: all.reduce(0) { $0 + $1.full }))
        for entry in all { document.addSubview(entry.clip) }
        if cards > maxFullCards {
            let scroll = NSScrollView(frame: bounds)
            scroll.hasVerticalScroller = true
            scroll.autohidesScrollers = true
            scroll.scrollerStyle = .overlay
            scroll.drawsBackground = false
            scroll.borderType = .noBorder
            scroll.documentView = document
            addSubview(scroll)
            self.scroll = scroll
        } else {
            addSubview(document)
        }
        // While the cards fold, nothing in them changes: they move and fade. Their
        // contents are only drawn again when they ask (a hover, a pin), not every time
        // a frame moves, which would redraw every graph on every step of the fold.
        Self.drawOnlyWhenAsked(self)
        layoutForState()
    }

    required init?(coder: NSCoder) { nil }

    private static func drawOnlyWhenAsked(_ view: NSView) {
        view.wantsLayer = true
        view.layerContentsRedrawPolicy = .onSetNeedsDisplay
        view.subviews.forEach(drawOnlyWhenAsked)
    }

    var isFolded: Bool { folded }

    func setFolded(_ folded: Bool, animated: Bool = true) {
        guard folded != self.folded else { return }
        motion.transition(animated: animated) {
            self.folded = folded
            self.layoutForState()
        }
    }

    /// The cards as they end up: clipped to their header line and slid up inside the
    /// clip when folded, the limit lines faded out and the mini bars in.
    private func layoutForState() {
        let p: CGFloat = folded ? 1 : 0
        var y: CGFloat = 0
        for entry in entries {
            let height = pixel(lerp(entry.full, entry.folded, p))
            // The card slides up inside its clip; the card itself never moves.
            let shift = pixel(entry.shift * p)
            if entry.clip.bounds.origin.y != shift { entry.clip.setBoundsOrigin(NSPoint(x: 0, y: shift)) }
            setFrame(of: entry.clip, NSRect(x: 0, y: y, width: Self.width, height: height))
            (entry.content as? ProfileMenuItemView)?.applyFold(p)
            y += height
        }
        setFrame(of: document, NSRect(x: 0, y: 0, width: Self.width, height: y))
        let cap = lerp(fullCap, max(fullCap * 0.6, 8 * ProfileMenuItemView.foldedHeight), p)
        let visible = pixel(min(y, cap))
        if let scroll { setFrame(of: scroll, NSRect(x: 0, y: 0, width: Self.width, height: visible)) }
        setFrame(of: self, NSRect(origin: frame.origin, size: NSSize(width: Self.width, height: visible)))
    }
}

/// Two small bars, the 5h and weekly limits, for a folded card's line.
final class MiniBarsView: NSView {
    private let values: [(Double, NSColor)]

    init(windows: [UsageWindow]) {
        values = windows.prefix(2).map { window in
            let full = window.usedPercent >= 99.5
            return (window.usedPercent, full ? .systemRed : window.usedPercent >= 90 ? .systemOrange : (window.title == "5h" ? .systemGreen : .controlAccentColor))
        }
        super.init(frame: NSRect(x: 0, y: 0, width: 73, height: 8))
        translatesAutoresizingMaskIntoConstraints = false
    }

    required init?(coder: NSCoder) { nil }

    override var intrinsicContentSize: NSSize { NSSize(width: CGFloat(values.count) * 34 + CGFloat(max(0, values.count - 1)) * 5, height: 8) }

    override func draw(_ dirtyRect: NSRect) {
        for (index, (percent, color)) in values.enumerated() {
            let track = NSRect(x: CGFloat(index) * 39, y: 2, width: 34, height: 4)
            NSColor.labelColor.withAlphaComponent(0.13).setFill()
            NSBezierPath(roundedRect: track, xRadius: 2, yRadius: 2).fill()
            let width = max(3, track.width * CGFloat(min(100, max(0, percent)) / 100))
            color.setFill()
            NSBezierPath(roundedRect: NSRect(x: track.minX, y: track.minY, width: width, height: 4), xRadius: 2, yRadius: 2).fill()
        }
    }
}

// MARK: - Small controls

/// A label that acts on a click, for "Use defaults", "Open in Claude", "Try again".
final class MenuLink: NSTextField {
    var onClick: (() -> Void)?
    private var area: NSTrackingArea?

    convenience init(_ title: String, size: CGFloat = 11, onClick: @escaping () -> Void) {
        self.init(labelWithString: title)
        font = .systemFont(ofSize: size, weight: .medium)
        textColor = .linkColor
        self.onClick = onClick
        sizeToFit()
    }

    override func updateTrackingAreas() {
        if let area { removeTrackingArea(area) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        self.area = area
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) { textColor = .linkColor.withAlphaComponent(0.75) }
    override func mouseExited(with event: NSEvent) { textColor = .linkColor }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { onClick?(); keepRestOfClick(event) }
    override func hitTest(_ point: NSPoint) -> NSView? { frame.contains(point) ? self : nil }
}

/// A square button with an SF Symbol that can turn (the chevron).
final class MenuIconButton: NSView {
    var onClick: (() -> Void)?
    private(set) var isTurned = false

    /// Turns the symbol half a turn (the chevron pointing up), with a little bounce. The
    /// layer turns on the render server; nothing is drawn again.
    func setTurned(_ turned: Bool, animated: Bool) {
        guard turned != isTurned else { return }
        isTurned = turned
        let angle: CGFloat = turned ? -.pi : 0
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let from = (symbol.presentation() ?? symbol).value(forKeyPath: "transform.rotation.z") as? CGFloat ?? 0
        symbol.setAffineTransform(CGAffineTransform(rotationAngle: angle))
        if animated && !MenuMotion.reduceMotion {
            let spin = CASpringAnimation(keyPath: "transform.rotation.z")
            spin.fromValue = from
            spin.toValue = angle
            spin.mass = 1
            spin.stiffness = 320
            spin.damping = 20
            spin.duration = spin.settlingDuration
            symbol.add(spin, forKey: "turn")
        }
        CATransaction.commit()
    }
    private let image: NSImage?
    private let symbol = CALayer()
    private var hovering = false { didSet { applyLook() } }
    private var area: NSTrackingArea?

    init(symbol name: String, label: String) {
        image = NSImage(systemSymbolName: name, accessibilityDescription: label)?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .semibold))
        super.init(frame: NSRect(x: 0, y: 0, width: 24, height: 24))
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.addSublayer(symbol)
        toolTip = label
        setAccessibilityRole(.button)
        setAccessibilityLabel(label)
        applyLook()
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        placeSymbol()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        placeSymbol()
    }

    private func placeSymbol() {
        guard let image else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        symbol.bounds = CGRect(origin: .zero, size: image.size)
        symbol.position = CGPoint(x: bounds.midX, y: bounds.midY)
        CATransaction.commit()
    }

    override func viewDidChangeEffectiveAppearance() { applyLook() }
    override func viewDidChangeBackingProperties() { applyLook() }

    /// The tinted symbol, rendered once per look (hover, light or dark), not per frame.
    private func applyLook() {
        guard let image else { return }
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let tint = self.hovering ? NSColor.labelColor : NSColor.secondaryLabelColor
            let tinted = NSImage(size: image.size, flipped: false) { rect in
                image.draw(in: rect)
                tint.set()
                rect.fill(using: .sourceAtop)
                return true
            }
            var rect = CGRect(origin: .zero, size: image.size)
            let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(image.size.width * scale), pixelsHigh: Int(image.size.height * scale),
                                       bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
            rep?.size = image.size
            if let rep, let context = NSGraphicsContext(bitmapImageRep: rep) {
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = context
                tinted.draw(in: rect)
                NSGraphicsContext.restoreGraphicsState()
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                self.symbol.contents = rep.cgImage
                self.symbol.contentsScale = scale
                self.layer?.backgroundColor = self.hovering ? NSColor.labelColor.withAlphaComponent(0.09).cgColor : nil
                CATransaction.commit()
            }
            rect = .zero
        }
        placeSymbol()
    }

    override func updateTrackingAreas() {
        if let area { removeTrackingArea(area) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        self.area = area
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { onClick?(); keepRestOfClick(event) }
    override func accessibilityPerformPress() -> Bool { onClick?(); return true }
}

/// The checkbox, like the mockup: an accent square whose tick springs in. Layers only.
final class MenuCheckbox: NSView {
    private let box = CALayer()
    private let tick = CAShapeLayer()
    private(set) var isOn = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        setAccessibilityRole(.checkBox)
        box.frame = bounds.insetBy(dx: 0.75, dy: 0.75)
        box.cornerRadius = 4
        layer?.addSublayer(box)
        let w = bounds.width
        let path = CGMutablePath()
        path.move(to: CGPoint(x: w * 0.25, y: w * 0.50))
        path.addLine(to: CGPoint(x: w * 0.43, y: w * 0.31))
        path.addLine(to: CGPoint(x: w * 0.76, y: w * 0.70))
        tick.frame = bounds
        tick.path = path
        tick.fillColor = nil
        tick.strokeColor = NSColor.white.cgColor
        tick.lineWidth = 2
        tick.lineCap = .round
        tick.lineJoin = .round
        layer?.addSublayer(tick)
        paint()
    }

    required init?(coder: NSCoder) { nil }

    func setOn(_ on: Bool, animated: Bool) {
        guard on != isOn else { return }
        isOn = on
        CATransaction.begin()
        CATransaction.setDisableActions(!animated || MenuMotion.reduceMotion)
        CATransaction.setAnimationDuration(0.2)
        paint()
        CATransaction.commit()
        guard animated, !MenuMotion.reduceMotion else { return }
        let pop = CASpringAnimation(keyPath: "transform.scale")
        pop.fromValue = on ? 0.2 : 1
        pop.toValue = on ? 1 : 0.2
        pop.stiffness = 420
        pop.damping = 16
        pop.duration = pop.settlingDuration
        tick.add(pop, forKey: "pop")
    }

    private func paint() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            self.box.backgroundColor = self.isOn ? NSColor.controlAccentColor.cgColor : nil
            self.box.borderWidth = self.isOn ? 0 : 1.5
            self.box.borderColor = NSColor.labelColor.withAlphaComponent(0.35).cgColor
        }
        tick.opacity = isOn ? 1 : 0
    }

    override func viewDidChangeEffectiveAppearance() { paint() }
}

/// A rounded pill: the status chip ("working", "waiting for reset") or the count.
final class MenuPill: NSView {
    private let label = NSTextField(labelWithString: "")
    private let dot = CALayer()
    private let ring = CAShapeLayer()
    private var color: NSColor = .secondaryLabelColor
    private var mark: Mark = .none

    enum Mark { case none, pulse, spin }

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 40, height: 16))
        wantsLayer = true
        layer?.cornerRadius = 8
        label.font = .systemFont(ofSize: 10.5, weight: .medium)
        addSubview(label)
        layer?.addSublayer(dot)
        layer?.addSublayer(ring)
        dot.cornerRadius = 3
        ring.fillColor = nil
        ring.lineWidth = 1.5
        ring.lineCap = .round
    }

    required init?(coder: NSCoder) { nil }

    func set(_ text: String, color: NSColor, mark: Mark = .none) {
        self.color = color
        label.stringValue = text
        label.textColor = color
        label.sizeToFit()
        let lead: CGFloat = mark == .none ? 7 : 17
        label.frame.origin = NSPoint(x: lead, y: (16 - label.frame.height) / 2)
        setFrameSize(NSSize(width: ceil(lead + label.frame.width + 7), height: 16))
        if mark != self.mark {
            self.mark = mark
            dot.removeAllAnimations()
            ring.removeAllAnimations()
        }
        effectiveAppearance.performAsCurrentDrawingAppearance {
            self.layer?.backgroundColor = color.withAlphaComponent(0.16).cgColor
            self.dot.backgroundColor = color.cgColor
            self.ring.strokeColor = color.cgColor
        }
        dot.isHidden = mark != .pulse
        ring.isHidden = mark != .spin
        dot.frame = CGRect(x: 7, y: 5, width: 6, height: 6)
        ring.frame = CGRect(x: 6.5, y: 3.5, width: 9, height: 9)
        ring.path = CGPath(ellipseIn: CGRect(x: 0.75, y: 0.75, width: 7.5, height: 7.5), transform: nil)
        ring.strokeEnd = 0.75
        if mark == .pulse, dot.animation(forKey: "pulse") == nil {
            let pulse = CABasicAnimation(keyPath: "opacity")
            pulse.fromValue = 1
            pulse.toValue = 0.3
            pulse.duration = 0.8
            pulse.autoreverses = true
            pulse.repeatCount = .infinity
            pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            dot.add(pulse, forKey: "pulse")
        }
        if mark == .spin, ring.animation(forKey: "spin") == nil {
            let spin = CABasicAnimation(keyPath: "transform.rotation.z")
            spin.fromValue = 0
            spin.toValue = -2 * Double.pi
            spin.duration = 0.8
            spin.repeatCount = .infinity
            ring.add(spin, forKey: "spin")
        }
        setAccessibilityLabel(text)
    }

    override func viewDidChangeEffectiveAppearance() {
        set(label.stringValue, color: color, mark: mark)
    }
}

func menuLabel(_ text: String, size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor = .labelColor) -> NSTextField {
    let label = NSTextField(labelWithString: text)
    label.font = .systemFont(ofSize: size, weight: weight)
    label.textColor = color
    label.lineBreakMode = .byTruncatingTail
    label.maximumNumberOfLines = 1
    label.cell?.truncatesLastVisibleLine = true
    return label
}

private func appIcon(_ path: String, size: CGFloat) -> NSImageView {
    let image = NSWorkspace.shared.icon(forFile: Launcher.expanding(path))
    image.size = NSSize(width: size, height: size)
    let view = NSImageView(image: image)
    view.imageScaling = .scaleProportionallyUpOrDown
    view.frame = NSRect(x: 0, y: 0, width: size, height: size)
    return view
}

private func symbolView(_ name: String, size: CGFloat, color: NSColor) -> NSImageView {
    let view = NSImageView(image: NSImage(systemSymbolName: name, accessibilityDescription: nil)?
        .withSymbolConfiguration(.init(pointSize: size, weight: .semibold)) ?? NSImage())
    view.contentTintColor = color
    view.frame = NSRect(x: 0, y: 0, width: size + 2, height: size + 2)
    return view
}

private extension KeepGoing.SessionInfo.Icon {
    var symbol: String? {
        switch self {
        case .here: return "arrow.clockwise"
        case .move: return "arrow.right"
        case .leave: return "nosign"
        case .warning: return "exclamationmark.triangle.fill"
        case .decide: return "checkmark"
        case .around: return "arrow.turn.down.right"
        case .wait: return "clock"
        case .lock: return "lock"
        case .none: return nil
        }
    }
}

private extension KeepGoing.SessionInfo.State {
    var color: NSColor {
        switch self {
        case .working: return .systemGreen
        case .waitingForReset: return .systemOrange
        case .moving, .sending: return .systemPurple
        case .needsYou: return .systemRed
        case .askingYou: return .systemBlue
        case .waitingForYou: return .systemOrange
        case .idle, .off: return .secondaryLabelColor
        }
    }

    var mark: MenuPill.Mark {
        switch self {
        case .working: return .pulse
        case .moving, .sending: return .spin
        default: return .none
        }
    }
}

// MARK: - The panel

/// What a session follows unless it has its own choices.
struct ContinueDefaults: Equatable {
    var plan: KeepGoing.Plan
    var message: String
    /// "Answer for me when I'm away" is on.
    var answering: Bool = false
    var answer: KeepGoing.Answer = .decide
    var awayMinutes: Int = 10

    init(plan: KeepGoing.Plan, message: String, answering: Bool = false, answer: KeepGoing.Answer = .decide, awayMinutes: Int = 10) {
        (self.plan, self.message, self.answering, self.answer, self.awayMinutes) = (plan, message, answering, answer, awayMinutes)
    }

    init(_ config: AppConfig) {
        self.init(plan: config.continuePlan, message: config.continueMessage, answering: config.answersWhenAway,
                  answer: config.defaultAnswer, awayMinutes: config.awayAfter)
    }
}

/// The checkbox row and, under it, the sessions list. One menu item.
final class ContinuePanelView: NSView, NSTextFieldDelegate {
    struct Handlers {
        var toggle: (Bool) -> Void = { _ in }
        var openSettings: () -> Void = {}
        /// The list opened or closed: the account cards fold to match.
        var expanded: (Bool) -> Void = { _ in }
        var change: (String, KeepGoing.Override) -> Void = { _, _ in }
        var act: (String) -> Void = { _ in }
        var open: (String) -> Void = { _ in }
        /// "Answer for me when I'm away" ticked or unticked.
        var toggleAnswering: (Bool) -> Void = { _ in }
        var answerNow: (String, KeepGoing.Answer) -> Void = { _, _ in }
    }

    override var isFlipped: Bool { true }
    static let width: CGFloat = 320
    /// The "Continue after limits" row, then the "Answer for me when I'm away" row.
    private static let rowHeight: CGFloat = 30
    private static let headerHeight: CGFloat = 56
    private static let captionHeight: CGFloat = 24

    private let handlers: Handlers
    private var enabled: Bool
    private var defaults: ContinueDefaults
    private var sessions: [KeepGoing.SessionInfo]

    private let motion: MenuMotion
    private(set) var isOpen = false

    private let checkbox = MenuCheckbox(frame: NSRect(x: 16, y: 7.5, width: 15, height: 15))
    private let title = menuLabel("Continue after limits", size: 13)
    private let count = MenuPill()
    private let gear = MenuIconButton(symbol: "gearshape", label: "Settings for continuing after limits")
    private let chevron = MenuIconButton(symbol: "chevron.down", label: "Show sessions")
    private let answerCheckbox = MenuCheckbox(frame: NSRect(x: 16, y: 30 + 4.5, width: 15, height: 15))
    private let answerTitle = menuLabel("Answer for me when I'm away", size: 13)
    private let asking = MenuPill()
    private let list = ClipView(frame: .zero)
    private let captionLeft = menuLabel("Sessions from the last 3 hours", size: 11, color: .secondaryLabelColor)
    private let captionRight = menuLabel("", size: 11, color: .secondaryLabelColor)
    private let empty = menuLabel("No Claude Code sessions in the last 3 hours.", size: 12, color: .secondaryLabelColor)
    private var rows: [SessionRowView] = []
    private var openKey: String?
    /// The header row under the pointer: 0, 1, or none.
    private var hovering: Int? { didSet { if hovering != oldValue { paintHover() } } }
    private let hoverBackground = NSView()
    private var area: NSTrackingArea?

    init(enabled: Bool, sessions: [KeepGoing.SessionInfo], defaults: ContinueDefaults, handlers: Handlers, motion: MenuMotion = MenuMotion()) {
        self.motion = motion
        self.enabled = enabled
        self.sessions = sessions
        self.defaults = defaults
        self.handlers = handlers
        super.init(frame: NSRect(x: 0, y: 0, width: Self.width, height: Self.headerHeight))
        checkbox.setOn(enabled, animated: false)
        checkbox.setAccessibilityLabel("Continue after limits")
        answerCheckbox.setOn(defaults.answering, animated: false)
        answerCheckbox.setAccessibilityLabel("Answer for me when I'm away")
        // Painted with layers only, so the panel growing never repaints it.
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        hoverBackground.wantsLayer = true
        hoverBackground.layer?.cornerRadius = 6
        hoverBackground.isHidden = true
        addSubview(hoverBackground)
        addSubview(checkbox)
        addSubview(title)
        addSubview(count)
        addSubview(answerCheckbox)
        addSubview(answerTitle)
        addSubview(asking)
        gear.onClick = { [weak self] in self?.handlers.openSettings() }
        chevron.onClick = { [weak self] in self?.setOpen(!(self?.isOpen ?? false)) }
        addSubview(gear)
        addSubview(chevron)
        addSubview(list)
        list.addSubview(captionLeft)
        list.addSubview(captionRight)
        list.addSubview(empty)
        update(enabled: enabled, sessions: sessions, defaults: defaults, animated: false)
    }

    required init?(coder: NSCoder) { nil }

    func setOpen(_ open: Bool, animated: Bool = true) {
        guard open != isOpen else { return }
        chevron.setTurned(open, animated: animated)
        chevron.toolTip = open ? "Hide sessions" : "Show sessions"
        chevron.setAccessibilityLabel(chevron.toolTip)
        motion.transition(animated: animated) {
            isOpen = open
            if !open { setRowOpen(nil, animated: animated) }
            handlers.expanded(open)
            layoutForState()
        }
        if open && animated { slideRowsIn() }
    }

    /// Each row fades and slides in a moment after the one above it.
    private func slideRowsIn() {
        guard !MenuMotion.reduceMotion else { return }
        let now = CACurrentMediaTime()
        for (index, row) in rows.enumerated() {
            guard let layer = row.layer else { continue }
            let begin = now + 0.06 + Double(index) * 0.045
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0
            fade.toValue = 1
            let slide = CABasicAnimation(keyPath: "transform.translation.y")
            slide.fromValue = -8
            slide.toValue = 0
            for animation in [fade, slide] {
                animation.beginTime = begin
                animation.duration = 0.34
                animation.fillMode = .backwards
                animation.timingFunction = MenuMotion.timing
                layer.add(animation, forKey: animation.keyPath)
            }
        }
    }

    /// New state from KeepGoing, applied in place so an open menu keeps its rows, open
    /// options and the message being typed.
    func update(enabled: Bool, sessions: [KeepGoing.SessionInfo], defaults: ContinueDefaults, animated: Bool = true) {
        let animated = animated && window != nil
        self.enabled = enabled
        self.sessions = sessions
        self.defaults = defaults
        checkbox.setOn(enabled, animated: animated)
        checkbox.setAccessibilityValue(enabled)
        answerCheckbox.setOn(defaults.answering, animated: animated)
        answerCheckbox.setAccessibilityValue(defaults.answering)
        count.set("\(sessions.count)", color: .secondaryLabelColor)
        count.isHidden = sessions.isEmpty
        let askingCount = sessions.filter { $0.state == .askingYou }.count
        let waitingCount = sessions.filter { $0.state == .waitingForYou }.count
        asking.set("\(askingCount) asking", color: .systemBlue)
        asking.isHidden = askingCount == 0
        let busy = sessions.filter { $0.state == .working }.count
        let waitingOnYou = [askingCount > 0 ? "\(askingCount) asking" : nil, waitingCount > 0 ? "\(waitingCount) waiting" : nil].compactMap { $0 }
        captionRight.stringValue = !waitingOnYou.isEmpty ? waitingOnYou.joined(separator: " · ") : busy == 0 ? "" : "\(busy) working"
        empty.isHidden = !sessions.isEmpty

        motion.transition(animated: animated) {
            var kept: [SessionRowView] = []
            for info in sessions {
                if let row = rows.first(where: { $0.info.key == info.key }) {
                    row.update(info, defaults: defaults)
                    kept.append(row)
                } else {
                    // A new row appears where it belongs, it doesn't fly in.
                    MenuMotion.instantly {
                        let row = SessionRowView(info: info, defaults: defaults, panel: self)
                        list.addSubview(row)
                        kept.append(row)
                    }
                }
            }
            for row in rows where !kept.contains(where: { $0 === row }) { row.removeFromSuperview() }
            rows = kept
            if let openKey, !rows.contains(where: { $0.info.key == openKey }) { self.openKey = nil }
            MenuMotion.instantly { layoutStatic() }
            layoutForState()
        }
    }

    fileprivate func toggleRow(_ key: String) {
        motion.transition {
            setRowOpen(openKey == key ? nil : key, animated: true)
            layoutForState()
        }
    }

    /// A row's content changed size (its options gained the account list, say).
    fileprivate func rowChanged() {
        motion.transition { layoutForState() }
    }

    private func setRowOpen(_ key: String?, animated: Bool) {
        openKey = key
        for row in rows { row.setOpen(row.info.key == key) }
        if key == nil { window?.makeFirstResponder(nil) }
    }

    fileprivate func change(_ key: String, _ override: KeepGoing.Override) { handlers.change(key, override) }
    fileprivate func act(_ key: String) { handlers.act(key) }
    fileprivate func open(_ key: String) { handlers.open(key) }
    fileprivate func answerNow(_ key: String, _ answer: KeepGoing.Answer) { handlers.answerNow(key, answer) }

    /// What only changes with new content: measured once per update, not per frame.
    private func layoutStatic() {
        title.sizeToFit()
        title.frame.origin = NSPoint(x: 39, y: (Self.rowHeight - title.frame.height) / 2)
        chevron.frame.origin = NSPoint(x: Self.width - 12 - 24, y: 3)
        gear.frame.origin = NSPoint(x: chevron.frame.minX - 2 - 24, y: 3)
        count.frame.origin = NSPoint(x: gear.frame.minX - 6 - count.frame.width, y: 7)
        answerTitle.sizeToFit()
        answerTitle.frame.origin = NSPoint(x: 39, y: Self.rowHeight + (24 - answerTitle.frame.height) / 2)
        asking.frame.origin = NSPoint(x: answerTitle.frame.maxX + 8, y: Self.rowHeight + 4)
        captionLeft.sizeToFit()
        captionRight.sizeToFit()
        captionLeft.frame.origin = NSPoint(x: 16, y: 6)
        captionRight.frame.origin = NSPoint(x: Self.width - 16 - captionRight.frame.width, y: 6)
        empty.sizeToFit()
        empty.frame.origin = NSPoint(x: 16, y: Self.captionHeight + 4)
    }

    /// Where everything ends up for the current state. Inside a transition, the views
    /// animate there.
    private func layoutForState() {
        let p: CGFloat = isOpen ? 1 : 0
        count.alphaValue = 1 - p
        var y = Self.captionHeight + (rows.isEmpty ? 28 : 0)
        for row in rows {
            let place = {
                row.layoutForState()
                setFrame(of: row, NSRect(x: 8, y: y, width: Self.width - 16, height: row.targetHeight))
                row.alphaValue = p
            }
            // A row seen for the first time starts where it belongs.
            if row.isPlaced { place() } else { MenuMotion.instantly(place) }
            row.isPlaced = true
            y += row.targetHeight + 2
        }
        captionLeft.alphaValue = p
        captionRight.alphaValue = p
        let listHeight = pixel((y + 6) * p)
        setFrame(of: list, NSRect(x: 0, y: Self.headerHeight, width: Self.width, height: listHeight))
        setFrame(of: self, NSRect(origin: frame.origin, size: NSSize(width: Self.width, height: Self.headerHeight + listHeight)))
    }

    // Each header row toggles its checkbox, like a menu item.
    override func updateTrackingAreas() {
        if let area { removeTrackingArea(area) }
        let area = NSTrackingArea(rect: NSRect(x: 0, y: 0, width: Self.width, height: Self.headerHeight),
                                  options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways], owner: self)
        addTrackingArea(area)
        self.area = area
        super.updateTrackingAreas()
    }

    /// Which header row a point toggles: the first stops short of the gear.
    private func headerRow(at point: NSPoint) -> Int? {
        if point.y < Self.rowHeight { return point.x < gear.frame.minX - 4 ? 0 : nil }
        return point.y < Self.headerHeight ? 1 : nil
    }

    override func mouseEntered(with event: NSEvent) { hovering = headerRow(at: convert(event.locationInWindow, from: nil)) }
    override func mouseMoved(with event: NSEvent) { hovering = headerRow(at: convert(event.locationInWindow, from: nil)) }
    override func mouseExited(with event: NSEvent) { hovering = nil }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        switch headerRow(at: convert(event.locationInWindow, from: nil)) {
        case 0: handlers.toggle(!enabled)
        case 1: handlers.toggleAnswering(!defaults.answering)
        default: return
        }
        keepRestOfClick(event)
    }

    private func paintHover() {
        hoverBackground.frame = hovering == 1
            ? NSRect(x: 8, y: Self.rowHeight - 1, width: Self.width - 16, height: 26)
            : NSRect(x: 8, y: 2, width: gear.frame.minX - 12, height: Self.rowHeight - 4)
        hoverBackground.isHidden = hovering == nil
        effectiveAppearance.performAsCurrentDrawingAppearance {
            self.hoverBackground.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.06).cgColor
        }
    }

    override func viewDidChangeEffectiveAppearance() { paintHover() }
}

// MARK: - A session

/// One session: its name and status, its account, and what happens at its limit. A click
/// opens its options under it.
final class SessionRowView: NSView, NSTextFieldDelegate {
    override var isFlipped: Bool { true }
    private(set) var info: KeepGoing.SessionInfo
    private var defaults: ContinueDefaults
    private weak var panel: ContinuePanelView?

    /// The always-visible part: title, account, the question when it's asking you, and
    /// the plan line (one to three lines).
    private var tapHeight: CGFloat { 43 + questionHeight + planHeight + 6 }
    private let questionBox = QuestionBoxView()
    private var questionHeight: CGFloat = 0
    private var width: CGFloat { ContinuePanelView.width - 16 }

    private let titleLabel = menuLabel("", size: 13, weight: .medium)
    private let status = MenuPill()
    private let chevron = MenuIconButton(symbol: "chevron.down", label: "Options for this session")
    private var accountIcon = NSImageView()
    private let accountLabel = menuLabel("", size: 11.5, color: .secondaryLabelColor)
    private var planIcon = NSImageView()
    private let planLabel: NSTextField = {
        let label = NSTextField(wrappingLabelWithString: "")
        label.maximumNumberOfLines = 3
        label.isSelectable = false
        label.usesSingleLineMode = false
        label.lineBreakMode = .byWordWrapping
        label.cell?.wraps = true
        label.cell?.isScrollable = false
        return label
    }()
    private var planHeight: CGFloat = 16
    private let options = ClipView(frame: .zero)
    private var optionsHeight: CGFloat = 0
    private var hovering = false { didSet { paintBackground() } }
    private var isOpen = false
    private var area: NSTrackingArea?

    // Options.
    private let nowLabel = menuLabel("ANSWER NOW, WITHOUT WAITING", size: 10, weight: .semibold, color: .secondaryLabelColor)
    private var nowButtons: [MenuPillButton] = []
    private let answerLabel = menuLabel("", size: 10, weight: .semibold, color: .secondaryLabelColor)
    private var answerChoices: [ChoiceView] = []
    private let limitSummary = menuLabel("", size: 11, color: .secondaryLabelColor)
    private var changeLink: MenuLink!
    /// With answering on, the limit choices fold into one line until "change".
    private var showsLimitChoices = false
    private let whenLabel = menuLabel("WHEN IT REACHES ITS LIMIT", size: 10, weight: .semibold, color: .secondaryLabelColor)
    private var choices: [ChoiceView] = []
    private var targetRows: [TargetRowView] = []
    private let messageLabel = menuLabel("MESSAGE IT SENDS", size: 10, weight: .semibold, color: .secondaryLabelColor)
    private let messageField = MenuTextField()
    private let footer = menuLabel("", size: 11, color: .secondaryLabelColor)
    private var useDefaults: MenuLink!
    private var actionLink: MenuLink!
    private var openLink: MenuLink!

    init(info: KeepGoing.SessionInfo, defaults: ContinueDefaults, panel: ContinuePanelView) {
        self.info = info
        self.defaults = defaults
        self.panel = panel
        super.init(frame: NSRect(x: 0, y: 0, width: ContinuePanelView.width - 16, height: 64))
        wantsLayer = true
        // Its background is the layer's colour: the row grows as its options open, and
        // that shouldn't repaint it.
        layerContentsRedrawPolicy = .never
        layer?.cornerRadius = 9
        for view in [titleLabel, status, chevron, accountLabel, questionBox, planLabel, options] as [NSView] { addSubview(view) }
        chevron.onClick = { [weak self] in self.map { $0.panel?.toggleRow($0.info.key) } }

        options.addSubview(nowLabel)
        for how in [KeepGoing.Answer.decide, .around] {
            let button = MenuPillButton(how == .decide ? "Decide for me" : "Do what you can") { [weak self] in
                self.map { $0.panel?.answerNow($0.info.key, how) }
            }
            nowButtons.append(button)
            options.addSubview(button)
        }
        options.addSubview(answerLabel)
        for (how, symbol) in [(KeepGoing.Answer.decide, "checkmark"), (.around, "arrow.turn.down.right"), (.wait, "clock")] {
            let choice = ChoiceView(symbol: symbol, title: how.title)
            choice.onClick = { [weak self] in self?.pickAnswer(how) }
            answerChoices.append(choice)
            options.addSubview(choice)
        }
        options.addSubview(limitSummary)
        changeLink = MenuLink("change") { [weak self] in
            guard let self else { return }
            self.showsLimitChoices = true
            self.apply()
        }
        options.addSubview(changeLink)
        options.addSubview(whenLabel)
        for (plan, symbol, name) in [(KeepGoing.Plan.continueHere, "arrow.clockwise", "Continue here"),
                                     (.move, "arrow.right", "Move to another account"),
                                     (.leave, "nosign", "Leave it")] {
            let choice = ChoiceView(symbol: symbol, title: name)
            choice.onClick = { [weak self] in self?.pick(plan) }
            choices.append(choice)
            options.addSubview(choice)
        }
        options.addSubview(messageLabel)
        messageField.font = .systemFont(ofSize: 12)
        messageField.placeholderString = defaults.message
        messageField.delegate = self
        messageField.focusRingType = .none
        messageField.bezelStyle = .roundedBezel
        options.addSubview(messageField)
        options.addSubview(footer)
        useDefaults = MenuLink("Use defaults") { [weak self] in self?.resetToDefaults() }
        actionLink = MenuLink("Try again") { [weak self] in self.map { $0.panel?.act($0.info.key) } }
        openLink = MenuLink("Open in Claude") { [weak self] in self.map { $0.panel?.open($0.info.key) } }
        for link in [useDefaults, actionLink, openLink] as [NSView] { options.addSubview(link) }
        apply()
    }

    required init?(coder: NSCoder) { nil }

    /// Laid out in the list at least once.
    var isPlaced = false

    /// Its height once settled: the top part, plus the options when open.
    var targetHeight: CGFloat { pixel(tapHeight + (isOpen ? optionsHeight : 0)) }

    func update(_ info: KeepGoing.SessionInfo, defaults: ContinueDefaults) {
        guard info != self.info || defaults != self.defaults else { return }
        self.info = info
        self.defaults = defaults
        apply()
    }

    func setOpen(_ open: Bool) {
        guard open != isOpen else { return }
        isOpen = open
        if !open, showsLimitChoices {
            showsLimitChoices = false
            MenuMotion.instantly { applyContent() }
        }
        chevron.setTurned(open, animated: window != nil)
        paintBackground()
    }

    private func paintBackground() {
        let alpha: CGFloat = isOpen ? 0.065 : hovering ? 0.06 : 0
        effectiveAppearance.performAsCurrentDrawingAppearance {
            self.layer?.backgroundColor = alpha > 0 ? NSColor.labelColor.withAlphaComponent(alpha).cgColor : nil
        }
    }

    override func viewDidChangeEffectiveAppearance() { paintBackground() }

    private func apply() {
        let before = targetHeight
        MenuMotion.instantly { applyContent() }
        // Grown or shrunk while showing: the panel moves the rows below.
        if targetHeight != before, superview != nil { panel?.rowChanged() }
    }

    private func applyContent() {
        titleLabel.stringValue = info.title
        titleLabel.toolTip = info.title
        status.set(info.state.label, color: info.state.color, mark: info.state.mark)

        accountIcon.removeFromSuperview()
        accountIcon = appIcon(info.accountAppPath, size: 12)
        addSubview(accountIcon)
        accountLabel.stringValue = [info.accountName, info.movedNote].compactMap { $0 }.joined(separator: " · ")

        planIcon.removeFromSuperview()
        let tone: NSColor = info.planTone == .alert ? .systemRed : info.planTone == .muted ? .secondaryLabelColor : .labelColor
        if let symbol = info.planIcon.symbol {
            planIcon = symbolView(symbol, size: 9.5, color: info.planIcon == .warning ? .systemRed : .secondaryLabelColor)
            addSubview(planIcon)
        } else {
            planIcon = NSImageView()
        }
        // The whole line, marker included, wrapping rather than cut off.
        let wrapping = NSMutableParagraphStyle()
        wrapping.lineBreakMode = .byWordWrapping
        let line = NSMutableAttributedString(string: info.planText, attributes: [.foregroundColor: tone, .font: NSFont.systemFont(ofSize: 11.5), .paragraphStyle: wrapping])
        if let marker = info.marker {
            line.append(NSAttributedString(string: " · \(marker)", attributes: [
                .foregroundColor: marker == "custom" ? NSColor.linkColor : NSColor.secondaryLabelColor,
                .font: NSFont.systemFont(ofSize: 11.5),
                .paragraphStyle: wrapping,
            ]))
        }
        planLabel.attributedStringValue = line
        planHeight = max(16, ceil(planLabel.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: width - 37, height: 1000)).height ?? 16))
        planLabel.toolTip = info.planText

        // What it's asking, word for word.
        questionBox.isHidden = info.question == nil
        questionHeight = info.question.map { questionBox.set($0, width: width - 18) + 6 } ?? 0

        // Answering: now, or when you're away.
        let answering = defaults.answering
        let canAnswer = info.canAnswerNow && info.state == .askingYou
        nowLabel.isHidden = !canAnswer
        nowButtons.forEach { $0.isHidden = !canAnswer }
        answerLabel.stringValue = "WHEN IT ASKS YOU AND YOU'RE AWAY \(defaults.awayMinutes) MIN"
        answerLabel.isHidden = !answering
        let answerDetails: [KeepGoing.Answer: String] = [
            .decide: "Goes with what it would recommend",
            .around: "Leaves this for you, does the rest",
            .wait: "Nothing is sent, you get a notification",
        ]
        for (choice, how) in zip(answerChoices, KeepGoing.Answer.allCases) {
            choice.isHidden = !answering
            choice.set(detail: answerDetails[how] ?? "", selected: info.answer == how, isDefault: defaults.answer == how)
        }
        let limitFolded = answering && !showsLimitChoices
        limitSummary.isHidden = !limitFolded
        changeLink.isHidden = !limitFolded
        limitSummary.stringValue = info.limitSummary
        limitSummary.toolTip = info.limitSummary
        for view in [whenLabel, messageLabel, messageField] as [NSView] { view.isHidden = limitFolded }
        choices.forEach { $0.isHidden = limitFolded }

        // Options.
        let accountsLeft = info.targets.isEmpty ? "No other account to move to" : "Right away, to an account with room"
        let details: [KeepGoing.Plan: String] = [
            .continueHere: "After the reset, in the same window",
            .move: accountsLeft,
            .leave: "Nothing happens at its limit",
        ]
        for (choice, plan) in zip(choices, KeepGoing.Plan.allCases) {
            choice.set(detail: details[plan] ?? "", selected: info.plan == plan, isDefault: defaults.plan == plan)
        }
        targetRows.forEach { $0.removeFromSuperview() }
        targetRows = []
        if info.plan == .move, !info.targets.isEmpty, !limitFolded {
            let any = TargetRowView(name: "Any account with room", detail: "in ring order", good: nil, appPath: nil, selected: info.chosenTarget == nil)
            any.onClick = { [weak self] in self?.pickTarget(nil) }
            targetRows.append(any)
            for target in info.targets {
                // A ChatGPT account says so: same address as a Claude one, different app,
                // and there the message is yours to send.
                let name = target.isChatGPT ? "\(target.name) · ChatGPT \(target.plan)" : "\(target.name) \(target.plan)"
                let detail = target.isChatGPT ? (target.hasRoom ? "you send it" : target.room) : target.room
                let row = TargetRowView(name: name, detail: detail, good: target.isChatGPT && target.hasRoom ? nil : target.hasRoom, appPath: target.appPath, selected: info.chosenTarget == target.id)
                if target.isChatGPT { row.toolTip = "Imports the session into ChatGPT and opens it there. LLMCodeBar doesn't type into ChatGPT, so you send the message. \(target.room)." }
                row.onClick = { [weak self] in self?.pickTarget(target.id) }
                targetRows.append(row)
            }
            targetRows.forEach { options.addSubview($0) }
        }
        if messageField.currentEditor() == nil {
            messageField.stringValue = info.message == defaults.message ? "" : info.message
        }
        messageField.placeholderString = defaults.message
        footer.stringValue = info.isCustom ? "Custom ·" : "Using your defaults"
        useDefaults.isHidden = !info.isCustom
        actionLink.isHidden = info.action == nil
        actionLink.stringValue = info.action ?? ""
        actionLink.sizeToFit()

        optionsHeight = layoutOptions()
        layoutContents()
    }

    /// Lays out the options and returns their height.
    @discardableResult
    private func layoutOptions() -> CGFloat {
        let inner = width - 16
        var y: CGFloat = 2
        if !nowLabel.isHidden {
            nowLabel.sizeToFit()
            nowLabel.frame.origin = NSPoint(x: 10, y: y)
            y += 17
            var x: CGFloat = 8
            for button in nowButtons {
                button.frame.origin = NSPoint(x: x, y: y)
                x += button.frame.width + 6
            }
            y += 30
        }
        if !answerLabel.isHidden {
            answerLabel.sizeToFit()
            answerLabel.frame.origin = NSPoint(x: 10, y: y)
            y += 16
            for choice in answerChoices {
                choice.frame = NSRect(x: 8, y: y, width: inner, height: 38)
                choice.layoutContents()
                y += 40
            }
            y += 6
        }
        if !limitSummary.isHidden {
            changeLink.sizeToFit()
            limitSummary.frame = NSRect(x: 10, y: y, width: inner - changeLink.frame.width - 10, height: 16)
            limitSummary.sizeToFit()
            limitSummary.frame.size.width = min(limitSummary.frame.width, inner - changeLink.frame.width - 10)
            changeLink.frame.origin = NSPoint(x: limitSummary.frame.maxX + 5, y: y)
            y += 24
        } else {
            whenLabel.sizeToFit()
            whenLabel.frame.origin = NSPoint(x: 10, y: y)
            y += 16
            for choice in choices {
                choice.frame = NSRect(x: 8, y: y, width: inner, height: 38)
                choice.layoutContents()
                y += 40
                if choice === choices[1], !targetRows.isEmpty {
                    for row in targetRows {
                        row.frame = NSRect(x: 38, y: y, width: inner - 30, height: 22)
                        row.layoutContents()
                        y += 24
                    }
                    y += 2
                }
            }
            y += 6
            messageLabel.sizeToFit()
            messageLabel.frame.origin = NSPoint(x: 10, y: y)
            y += 16
            messageField.frame = NSRect(x: 8, y: y, width: inner, height: 22)
            y += 30
        }
        footer.sizeToFit()
        footer.frame.origin = NSPoint(x: 10, y: y)
        useDefaults.frame.origin = NSPoint(x: footer.frame.maxX + 3, y: y)
        openLink.frame.origin = NSPoint(x: 8 + inner - openLink.frame.width, y: y)
        actionLink.frame.origin = NSPoint(x: openLink.frame.minX - 12 - actionLink.frame.width, y: y)
        y += 24
        return y
    }

    /// The fixed parts of the row, when its content changes.
    func layoutContents() {
        let chevronX = width - 6 - 20
        chevron.frame = NSRect(x: chevronX, y: 6, width: 20, height: 20)
        status.frame.origin = NSPoint(x: chevronX - 4 - status.frame.width, y: 8)
        titleLabel.frame = NSRect(x: 10, y: 7, width: status.frame.minX - 16, height: 17)
        accountIcon.frame.origin = NSPoint(x: 10, y: 28)
        accountLabel.frame = NSRect(x: 27, y: 26, width: width - 37, height: 16)
        questionBox.frame = NSRect(x: 9, y: 45, width: width - 18, height: max(0, questionHeight - 6))
        planIcon.frame.origin = NSPoint(x: 9, y: 44 + questionHeight)
        planLabel.frame = NSRect(x: 27, y: 43 + questionHeight, width: width - 37, height: planHeight)
    }

    /// The options, shown or folded away, for the current state.
    func layoutForState() {
        setFrame(of: options, NSRect(x: 0, y: tapHeight, width: width, height: isOpen ? optionsHeight : 0))
        options.alphaValue = isOpen ? 1 : 0
    }

    private func pick(_ plan: KeepGoing.Plan) {
        var override = currentOverride()
        override.plan = plan == defaults.plan ? nil : plan
        if plan != .move { override.target = nil }
        panel?.change(info.key, override)
    }

    private func pickAnswer(_ how: KeepGoing.Answer) {
        var override = currentOverride()
        override.answer = how == defaults.answer ? nil : how
        panel?.change(info.key, override)
    }

    private func pickTarget(_ id: String?) {
        var override = currentOverride()
        override.plan = info.plan == defaults.plan ? nil : info.plan
        override.target = id
        panel?.change(info.key, override)
    }

    private func resetToDefaults() {
        messageField.stringValue = ""
        window?.makeFirstResponder(nil)
        panel?.change(info.key, KeepGoing.Override())
    }

    /// The choices this session has now, from what the line shows.
    private func currentOverride() -> KeepGoing.Override {
        let message = messageField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return KeepGoing.Override(
            plan: info.plan == defaults.plan ? nil : info.plan,
            target: info.plan == .move ? info.chosenTarget : nil,
            message: message.isEmpty || message == defaults.message ? nil : message,
            answer: info.answer == defaults.answer ? nil : info.answer)
    }

    func controlTextDidChange(_ obj: Notification) {
        var override = currentOverride()
        override.plan = info.plan == defaults.plan ? nil : info.plan
        panel?.change(info.key, override)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.insertNewline(_:)) || selector == #selector(NSResponder.cancelOperation(_:)) {
            window?.makeFirstResponder(nil)
            return true
        }
        return false
    }

    // Clicking the top part opens or closes the options.
    override func updateTrackingAreas() {
        if let area { removeTrackingArea(area) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        self.area = area
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard point.y < tapHeight else { return }
        panel?.toggleRow(info.key)
        keepRestOfClick(event)
    }

}

/// What a session asks you, quoted, with its options under it. Layers only.
final class QuestionBoxView: NSView {
    override var isFlipped: Bool { true }
    private let bar = CALayer()
    private let text: NSTextField = {
        let label = NSTextField(wrappingLabelWithString: "")
        label.maximumNumberOfLines = 3
        label.isSelectable = false
        label.cell?.wraps = true
        label.cell?.truncatesLastVisibleLine = true
        return label
    }()
    private let options = menuLabel("", size: 11, color: .secondaryLabelColor)
    private var kind: KeepGoing.Question.Kind = .card

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        layer?.cornerRadius = 7
        layer?.masksToBounds = true
        layer?.addSublayer(bar)
        addSubview(text)
        addSubview(options)
        paint()
    }

    required init?(coder: NSCoder) { nil }

    /// Fills it in and returns its height for `width`.
    func set(_ question: KeepGoing.Question, width: CGFloat) -> CGFloat {
        kind = question.kind
        let lead: String
        switch question.kind {
        case .card, .plan: lead = ""
        case .nextStep: lead = "At the end of its turn: "
        case .text: lead = "Ended its turn with: "
        }
        let line = NSMutableAttributedString(string: lead, attributes: [.font: NSFont.systemFont(ofSize: 11.5), .foregroundColor: NSColor.secondaryLabelColor])
        line.append(NSAttributedString(string: "“\(question.text)”", attributes: [.font: NSFont.systemFont(ofSize: 11.5), .foregroundColor: NSColor.labelColor]))
        text.attributedStringValue = line
        text.toolTip = question.text
        let textHeight = ceil(text.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: width - 18, height: 1000)).height ?? 15)
        text.frame = NSRect(x: 10, y: 5, width: width - 18, height: textHeight)
        options.stringValue = question.options.joined(separator: " · ")
        options.isHidden = question.options.isEmpty
        options.frame = NSRect(x: 10, y: text.frame.maxY + 1, width: width - 18, height: 15)
        paint()
        return 5 + textHeight + (options.isHidden ? 0 : 16) + 5
    }

    override func layout() {
        super.layout()
        bar.frame = CGRect(x: 0, y: 0, width: 2, height: bounds.height)
    }

    private func paint() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            self.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.06).cgColor
            self.bar.backgroundColor = (self.kind == .plan ? NSColor.systemOrange : NSColor.systemBlue).cgColor
        }
    }

    override func viewDidChangeEffectiveAppearance() { paint() }
}

/// A small rounded button, for "Decide for me" and "Do what you can". Layers only.
final class MenuPillButton: NSView {
    var onClick: (() -> Void)?
    private let label: NSTextField
    private var hovering = false { didSet { paint() } }
    private var area: NSTrackingArea?

    init(_ title: String, onClick: @escaping () -> Void) {
        self.onClick = onClick
        label = menuLabel(title, size: 11.5)
        label.sizeToFit()
        super.init(frame: NSRect(x: 0, y: 0, width: ceil(label.frame.width) + 20, height: 22))
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        layer?.cornerRadius = 7
        label.frame.origin = NSPoint(x: 10, y: (22 - label.frame.height) / 2)
        addSubview(label)
        setAccessibilityRole(.button)
        setAccessibilityLabel(title)
        paint()
    }

    required init?(coder: NSCoder) { nil }

    private func paint() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            self.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(self.hovering ? 0.16 : 0.09).cgColor
        }
    }

    override func viewDidChangeEffectiveAppearance() { paint() }

    override func updateTrackingAreas() {
        if let area { removeTrackingArea(area) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        self.area = area
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { onClick?(); keepRestOfClick(event) }
    override func accessibilityPerformPress() -> Bool { onClick?(); return true }
}

/// The message field. A click in an open menu has to make it the first responder itself.
final class MenuTextField: NSTextField {
    /// Only a click focuses it. Otherwise the menu, when it opens, hands focus to the
    /// first text field it finds - a hidden session's - which takes a quarter of a
    /// second and sends typing into a field nobody can see.
    private var clicked = false

    override var acceptsFirstResponder: Bool { clicked }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        clicked = true
        if currentEditor() == nil { window?.makeFirstResponder(self) }
        super.mouseDown(with: event)
    }

    override func textDidEndEditing(_ notification: Notification) {
        super.textDidEndEditing(notification)
        clicked = false
    }

    /// What a click does, without the click's own tracking (for scripted checks).
    func focusLikeAClick() {
        clicked = true
        window?.makeFirstResponder(self)
    }
}

/// One of the three plans in a session's options.
final class ChoiceView: NSView {
    override var isFlipped: Bool { true }
    var onClick: (() -> Void)?
    private let icon: NSImageView
    private let iconBox = NSView()
    private let title: NSTextField
    private let detail = menuLabel("", size: 11, color: .secondaryLabelColor)
    private let badge = menuLabel("default", size: 9.5, weight: .medium, color: .secondaryLabelColor)
    private var selected = false
    private var hovering = false { didSet { needsDisplay = true } }
    private var area: NSTrackingArea?

    init(symbol: String, title text: String) {
        icon = symbolView(symbol, size: 10, color: .secondaryLabelColor)
        title = menuLabel(text, size: 12, weight: .medium)
        super.init(frame: .zero)
        iconBox.wantsLayer = true
        iconBox.layer?.cornerRadius = 6
        iconBox.addSubview(icon)
        for view in [iconBox, title, detail, badge] { addSubview(view) }
        setAccessibilityRole(.radioButton)
        setAccessibilityLabel(text)
    }

    required init?(coder: NSCoder) { nil }

    func set(detail text: String, selected: Bool, isDefault: Bool) {
        self.selected = selected
        detail.stringValue = text
        badge.isHidden = !isDefault
        setAccessibilityValue(selected)
        icon.contentTintColor = selected ? .white : .secondaryLabelColor
        effectiveAppearance.performAsCurrentDrawingAppearance {
            self.iconBox.layer?.backgroundColor = (selected ? NSColor.controlAccentColor : NSColor.labelColor.withAlphaComponent(0.09)).cgColor
        }
        needsDisplay = true
    }

    func layoutContents() {
        iconBox.frame = NSRect(x: 8, y: 8, width: 22, height: 22)
        icon.frame.origin = NSPoint(x: (22 - icon.frame.width) / 2, y: (22 - icon.frame.height) / 2)
        title.sizeToFit()
        title.frame.origin = NSPoint(x: 38, y: 4)
        badge.sizeToFit()
        badge.frame.origin = NSPoint(x: title.frame.maxX + 6, y: 6)
        detail.frame = NSRect(x: 38, y: 19, width: bounds.width - 46, height: 15)
    }

    override func updateTrackingAreas() {
        if let area { removeTrackingArea(area) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        self.area = area
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { onClick?(); keepRestOfClick(event) }
    override func accessibilityPerformPress() -> Bool { onClick?(); return true }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 8, yRadius: 8)
        if selected {
            NSColor.controlAccentColor.withAlphaComponent(0.14).setFill()
            path.fill()
            NSColor.controlAccentColor.withAlphaComponent(0.6).setStroke()
            path.lineWidth = 1
            path.stroke()
        } else if hovering {
            NSColor.labelColor.withAlphaComponent(0.06).setFill()
            path.fill()
        }
    }
}

/// An account a "move" can go to, with whether it has room.
final class TargetRowView: NSView {
    override var isFlipped: Bool { true }
    var onClick: (() -> Void)?
    private let icon: NSImageView?
    private let name: NSTextField
    private let detail: NSTextField
    private let selected: Bool
    private var hovering = false { didSet { needsDisplay = true } }
    private var area: NSTrackingArea?

    init(name text: String, detail info: String, good: Bool?, appPath: String?, selected: Bool) {
        icon = appPath.map { appIcon($0, size: 11) }
        name = menuLabel(text, size: 11.5)
        detail = menuLabel(info, size: 10.5, color: good == nil ? .secondaryLabelColor : good! ? .systemGreen : .systemOrange)
        self.selected = selected
        super.init(frame: .zero)
        if let icon { addSubview(icon) }
        addSubview(name)
        addSubview(detail)
        setAccessibilityRole(.radioButton)
        setAccessibilityLabel("\(text), \(info)")
        setAccessibilityValue(selected)
    }

    required init?(coder: NSCoder) { nil }

    func layoutContents() {
        icon?.frame.origin = NSPoint(x: 7, y: 5.5)
        detail.sizeToFit()
        detail.frame.origin = NSPoint(x: bounds.width - 7 - detail.frame.width, y: 4)
        let left: CGFloat = icon == nil ? 8 : 23
        name.frame = NSRect(x: left, y: 3, width: detail.frame.minX - left - 6, height: 16)
    }

    override func updateTrackingAreas() {
        if let area { removeTrackingArea(area) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        self.area = area
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { onClick?(); keepRestOfClick(event) }
    override func accessibilityPerformPress() -> Bool { onClick?(); return true }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6)
        NSColor.black.withAlphaComponent(hovering ? 0.22 : 0.14).setFill()
        path.fill()
        if selected {
            NSColor.controlAccentColor.withAlphaComponent(0.7).setStroke()
            path.lineWidth = 1
            path.stroke()
        }
    }
}

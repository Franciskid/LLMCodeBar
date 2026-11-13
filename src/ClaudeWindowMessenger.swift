import AppKit
import ApplicationServices

/// Sends a message into a Claude Code session in its own Claude window, the way you
/// would: the session opens, the message goes in its reply box, and Send is pressed. It
/// all happens in the window you can see, so you can watch the turn and stop it.
///
/// It goes through the Accessibility interface rather than the keyboard. The reply box
/// is filled and the Send button pressed directly, so it works with the window in the
/// background and never types into whatever app you're using. Claude is an Electron app,
/// which only builds its accessibility tree when asked (`AXManualAccessibility`).
///
/// Claude has no way in from outside other than this: its links can open a session or
/// pre-fill a new one, but not send into an existing one, and it refuses to start with
/// remote debugging.
enum ClaudeWindowMessenger {
    enum Failure: Error {
        case notTrusted, noWindow, noReplyBox, draftInTheWay, couldNotFill, notDelivered

        var explanation: String {
            switch self {
            case .notTrusted:
                return "LLMCodeBar needs Accessibility access to send it (System Settings > Privacy & Security > Accessibility)."
            case .noWindow:
                return "its Claude window isn't open."
            case .noReplyBox:
                return "the session didn't open in its Claude window."
            case .draftInTheWay:
                return "its reply box has an unsent draft, which LLMCodeBar won't overwrite."
            case .couldNotFill:
                return "Claude didn't accept the message in its reply box."
            case .notDelivered:
                return "the message didn't reach the session."
            }
        }
    }

    /// The Send button's label. Claude's interface is translated, so a few languages.
    private static let sendLabels: Set<String> = [
        "send message", "send", "envoyer le message", "envoyer", "nachricht senden", "senden",
        "enviar mensaje", "enviar mensagem", "enviar", "invia messaggio", "invia",
        "bericht verzenden", "verzenden", "メッセージを送信", "送信", "메시지 보내기", "发送消息", "發送訊息",
    ]

    /// Opens `link` (a `claude://` link to the session) in `app`'s window, puts `text` in
    /// the reply box and sends it. `delivered` says whether the session's transcript shows
    /// the message; it's polled to confirm it arrived. Blocks for up to about a minute, so
    /// call it off the main thread.
    static func send(_ text: String, opening link: URL, in app: NSRunningApplication, delivered: () -> Bool) -> Result<Void, Failure> {
        guard AXIsProcessTrusted() else { return .failure(.notTrusted) }
        guard !app.isTerminated else { return .failure(.noWindow) }

        let pid = app.processIdentifier
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, 3)
        AXUIElementSetAttributeValue(application, "AXManualAccessibility" as CFString, kCFBooleanTrue)

        if Thread.isMainThread {
            _ = ClaudeLinkRouter.deliver(link, to: pid)
        } else {
            MainThread.sync { _ = ClaudeLinkRouter.deliver(link, to: pid) }
        }

        // Give the window time to switch to the session, then wait for its reply box.
        Thread.sleep(forTimeInterval: 3)
        var replyBox: AXUIElement?
        for _ in 0..<12 {
            if let found = Self.replyBox(in: application) {
                replyBox = found
                break
            }
            Thread.sleep(forTimeInterval: 1.5)
        }
        guard let replyBox else {
            return .failure(windows(of: application).isEmpty ? .noWindow : .noReplyBox)
        }

        let existing = (string(replyBox, kAXValueAttribute) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !existing.isEmpty, existing != string(replyBox, "AXPlaceholderValue") {
            return .failure(.draftInTheWay)
        }

        AXUIElementSetAttributeValue(replyBox, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        if !fill(replyBox, with: text) { return .failure(.couldNotFill) }
        Thread.sleep(forTimeInterval: 0.6)

        if let button = sendButton(near: replyBox, in: application) {
            AXUIElementPerformAction(button, kAXPressAction as CFString)
        } else {
            // No Send button found under a known label: press Return in the reply box,
            // which sends in Claude Code. Posted to Claude itself, not to the frontmost app.
            let source = CGEventSource(stateID: .hidSystemState)
            for down in [true, false] {
                CGEvent(keyboardEventSource: source, virtualKey: 36, keyDown: down)?.postToPid(pid)
            }
        }

        for _ in 0..<20 {
            Thread.sleep(forTimeInterval: 1.5)
            if delivered() { return .success(()) }
        }
        return .failure(.notDelivered)
    }

    /// Asks macOS to show its Accessibility prompt for LLMCodeBar, when it isn't trusted yet.
    @discardableResult
    static func requestAccessIfNeeded() -> Bool {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    /// What LLMCodeBar can see in a Claude window, for checking this works on a Mac
    /// without sending anything: `LLMCodeBar --probe-claude-window <pid>`.
    static func probe(pid: pid_t) -> String {
        guard requestAccessIfNeeded() else { return "Accessibility: not allowed" }
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, 3)
        AXUIElementSetAttributeValue(application, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        Thread.sleep(forTimeInterval: 1.5)
        var lines = ["Accessibility: allowed", "Windows: \(windows(of: application).count)"]
        guard let box = replyBox(in: application) else {
            var roles: [String: Int] = [:]
            var texty: [String] = []
            for window in windows(of: application).prefix(1) {
                visit(window, budget: 20000) { element, role in
                    roles[role, default: 0] += 1
                    let editable = (value(element, "AXEditable") as? Bool) == true
                    if role.contains("Text") || role == "AXButton" || role == "AXHeading" || editable || role == "AXComboBox" {
                        texty.append("[\(String((string(element, kAXValueAttribute) ?? string(element, kAXTitleAttribute) ?? "").prefix(80)))] " + "\(role) sub=\(string(element, kAXSubroleAttribute) ?? "-") editable=\(editable) settable=\(isSettable(element, kAXValueAttribute)) focusable=\(isSettable(element, kAXFocusedAttribute)) ph=\(string(element, "AXPlaceholderValue") ?? "-") desc=\(string(element, kAXDescriptionAttribute) ?? "-") y=\(position(of: element)?.y ?? -1)")
                    }
                }
            }
            lines.append("Reply box: not found")
            lines.append("Roles: " + roles.sorted { $0.value > $1.value }.map { "\($0.key)=\($0.value)" }.joined(separator: " "))
            lines += texty.suffix(30)
            return lines.joined(separator: "\n")
        }
        lines.append("Reply box: \(string(box, kAXRoleAttribute) ?? "?") placeholder=\(string(box, "AXPlaceholderValue") ?? "-") value=\((string(box, kAXValueAttribute) ?? "").prefix(40))")
        if let button = sendButton(near: box, in: application) {
            lines.append("Send button: \(string(button, kAXDescriptionAttribute) ?? string(button, kAXTitleAttribute) ?? "?")")
        } else {
            var labels: [String] = []
            for window in windows(of: application).prefix(1) {
                visit(window, budget: 8000) { element, role in
                    guard role == kAXButtonRole as String else { return }
                    let label = string(element, kAXDescriptionAttribute) ?? string(element, kAXTitleAttribute) ?? ""
                    if !label.isEmpty { labels.append(label) }
                }
            }
            lines.append("Send button: not found. Buttons: \(labels.suffix(25).joined(separator: ", "))")
        }
        lines.append("Reply box enabled=\(String(describing: value(box, kAXEnabledAttribute))) y=\(position(of: box)?.y ?? -1)")
        // Everything you could type in or press near the bottom of the window, to see what
        // a question card offers while it's open.
        for window in windows(of: application).prefix(1) {
            visit(window, budget: 20000) { element, role in
                let editable = (value(element, "AXEditable") as? Bool) == true
                guard role == kAXButtonRole as String || role == kAXTextAreaRole as String || role == kAXTextFieldRole as String
                        || role == "AXRadioButton" || role == "AXCheckBox" || editable else { return }
                let label = string(element, kAXDescriptionAttribute) ?? string(element, kAXTitleAttribute) ?? ""
                lines.append("  \(role) [\(label.prefix(60))] value=[\((string(element, kAXValueAttribute) ?? "").prefix(50))] ph=\(string(element, "AXPlaceholderValue") ?? "-") editable=\(editable) enabled=\(String(describing: value(element, kAXEnabledAttribute))) y=\(Int(position(of: element)?.y ?? -1))")
            }
        }
        return lines.joined(separator: "\n")
    }

    // MARK: Finding things in the window

    private static func windows(of application: AXUIElement) -> [AXUIElement] {
        var result: [AXUIElement] = []
        if let focused = element(application, kAXFocusedWindowAttribute) { result.append(focused) }
        for window in (value(application, kAXWindowsAttribute) as? [AXUIElement]) ?? [] where !result.contains(where: { CFEqual($0, window) }) {
            result.append(window)
        }
        return result
    }

    /// The session's reply box: the editable text area lowest in the window, which is
    /// where Claude Code keeps it. Searched in the focused window first, the one the link
    /// just brought up.
    private static func replyBox(in application: AXUIElement) -> AXUIElement? {
        for window in windows(of: application) {
            var candidates: [(element: AXUIElement, y: CGFloat)] = []
            var prompts: [(element: AXUIElement, y: CGFloat)] = []
            visit(window, budget: 20000) { element, role in
                guard role == kAXTextAreaRole as String || role == kAXTextFieldRole as String else { return }
                guard isSettable(element, kAXValueAttribute) else { return }
                if role == kAXTextFieldRole as String, (string(element, kAXSubroleAttribute) ?? "") == "AXSearchField" { return }
                let y = position(of: element)?.y ?? 0
                candidates.append((element, y))
                // Claude labels its composer "Prompt" in every language. A page open in the
                // window's browser pane can have text boxes lower down, so the label wins.
                if string(element, kAXDescriptionAttribute)?.lowercased() == "prompt" { prompts.append((element, y)) }
            }
            if let prompt = prompts.max(by: { $0.y < $1.y }) { return prompt.element }
            if let lowest = candidates.max(by: { $0.y < $1.y }) { return lowest.element }
        }
        return nil
    }

    private static func sendButton(near replyBox: AXUIElement, in application: AXUIElement) -> AXUIElement? {
        let boxY = position(of: replyBox)?.y ?? 0
        for window in windows(of: application) {
            var found: AXUIElement?
            visit(window, budget: 8000) { element, role in
                guard found == nil, role == kAXButtonRole as String else { return }
                let labels = [string(element, kAXDescriptionAttribute), string(element, kAXTitleAttribute), string(element, kAXHelpAttribute)]
                    .compactMap { $0?.lowercased().trimmingCharacters(in: .whitespaces) }
                guard labels.contains(where: sendLabels.contains) else { return }
                if (value(element, kAXEnabledAttribute) as? Bool) == false { return }
                // The composer's own button sits level with or just below the reply box.
                if let y = position(of: element)?.y, y < boxY - 200 { return }
                found = element
            }
            if let found { return found }
        }
        return nil
    }

    /// Sets the reply box's text, then reads it back: Claude's editor has to take it.
    private static func fill(_ box: AXUIElement, with text: String) -> Bool {
        let accepted: () -> Bool = { (string(box, kAXValueAttribute) ?? "").contains(text) }
        AXUIElementSetAttributeValue(box, kAXValueAttribute as CFString, text as CFString)
        Thread.sleep(forTimeInterval: 0.4)
        if accepted() { return true }
        AXUIElementSetAttributeValue(box, kAXSelectedTextAttribute as CFString, text as CFString)
        Thread.sleep(forTimeInterval: 0.4)
        return accepted()
    }

    // MARK: Accessibility helpers

    private static func visit(_ root: AXUIElement, budget: Int, _ body: (AXUIElement, String) -> Void) {
        var stack = [root]
        var remaining = budget
        while let element = stack.popLast(), remaining > 0 {
            remaining -= 1
            body(element, string(element, kAXRoleAttribute) ?? "")
            if let children = value(element, kAXChildrenAttribute) as? [AXUIElement] {
                stack.append(contentsOf: children.reversed())
            }
        }
    }

    private static func value(_ element: AXUIElement, _ attribute: String) -> AnyObject? {
        var result: AnyObject?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &result) == .success else { return nil }
        return result
    }

    private static func element(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        guard let result = value(element, attribute), CFGetTypeID(result) == AXUIElementGetTypeID() else { return nil }
        return (result as! AXUIElement)
    }

    private static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        value(element, attribute) as? String
    }

    private static func isSettable(_ element: AXUIElement, _ attribute: String) -> Bool {
        var settable: DarwinBoolean = false
        return AXUIElementIsAttributeSettable(element, attribute as CFString, &settable) == .success && settable.boolValue
    }

    private static func position(of element: AXUIElement) -> CGPoint? {
        guard let raw = value(element, kAXPositionAttribute), CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        return AXValueGetValue(raw as! AXValue, .cgPoint, &point) ? point : nil
    }
}

import AppKit

/// Routes `claude://` links to the right Claude window.
///
/// Signing in with Google opens the system browser, which hands the result back as
/// `claude://login/app-google-auth?code=…&hop_nonce=…`. macOS delivers that URL to *one*
/// instance of whichever app handles the scheme, and with two Claude windows open it is
/// routinely the wrong one: it rejects the code ("Google sign-in code does not answer a
/// sign-in this app started") and the sign-in appears to do nothing. A deep link cannot
/// be aimed at an instance - Claude has no second-instance handler - so holding the
/// scheme ourselves is the only place to fix it. That buys two things:
///
///  * Claude checks whether it owns `claude://` at the moment you start a sign-in. When
///    it doesn't, it keeps its built-in ASWebAuthentication sheet, whose result returns
///    straight to the window that opened it. The browser detour disappears entirely.
///  * Any link that still arrives here is forwarded. A sign-in callback goes to *every*
///    window, because only the one that started that sign-in accepts its nonce - the
///    others already ignore it by design. Anything else goes to the window used last.
///
/// Claude re-claims the scheme on every launch, so we take it back after each launch and
/// on every refresh. Turning the setting off hands it back for good.
enum ClaudeLinkRouter {
    static let scheme = "claude"
    static let claudeBundleID = "com.anthropic.claudefordesktop"

    /// When each Claude instance was last brought to the front, so a chat link opens in
    /// the window you were actually using.
    private static var lastActivated: [pid_t: Date] = [:]

    static var holdsScheme: Bool {
        guard let handler = NSWorkspace.shared.urlForApplication(toOpen: probeURL),
              let bundleID = Bundle(url: handler)?.bundleIdentifier else {
            return false
        }
        return bundleID == Bundle.main.bundleIdentifier
    }

    private static var probeURL: URL {
        URL(string: "\(scheme)://claude.ai/")!
    }

    /// Takes the scheme unless we already hold it. Cheap enough to call on every refresh.
    static func claimScheme() {
        guard !holdsScheme else { return }
        NSWorkspace.shared.setDefaultApplication(at: Bundle.main.bundleURL, toOpenURLsWithScheme: scheme) { _ in }
    }

    /// Gives `claude://` back to Claude.
    static func releaseScheme() {
        guard holdsScheme, let claude = claudeApplicationURL else { return }
        NSWorkspace.shared.setDefaultApplication(at: claude, toOpenURLsWithScheme: scheme) { _ in }
    }

    static func noteActivation(of application: NSRunningApplication) {
        guard application.bundleIdentifier == claudeBundleID else { return }
        lastActivated[application.processIdentifier] = Date()
    }

    // MARK: Forwarding

    static func route(_ url: URL) {
        let instances = NSRunningApplication.runningApplications(withBundleIdentifier: claudeBundleID)
            .filter { !$0.isTerminated && $0.processIdentifier > 0 }

        guard !instances.isEmpty else {
            open(url, with: claudeApplicationURL)
            return
        }
        // One window can't be the wrong one, and going through LaunchServices avoids
        // asking for permission to send it events.
        guard instances.count > 1 else {
            open(url, with: instances[0].bundleURL ?? claudeApplicationURL)
            return
        }

        if isSignInCallback(url) {
            var delivered = false
            for instance in instances {
                delivered = deliver(url, to: instance.processIdentifier) || delivered
            }
            if !delivered {
                // Without permission to send Apple events we can only hand it to
                // LaunchServices, which is where this started - but no worse.
                open(url, with: instances[0].bundleURL ?? claudeApplicationURL)
            }
            return
        }

        let target = instances.max {
            (lastActivated[$0.processIdentifier] ?? .distantPast) < (lastActivated[$1.processIdentifier] ?? .distantPast)
        } ?? instances[0]
        if !deliver(url, to: target.processIdentifier) {
            open(url, with: target.bundleURL ?? claudeApplicationURL)
        }
    }

    /// The callback from a sign-in started in the system browser, e.g.
    /// `claude://login/app-google-auth?code=…`.
    private static func isSignInCallback(_ url: URL) -> Bool {
        (url.host ?? "").caseInsensitiveCompare("login") == .orderedSame
    }

    /// Hands the URL to one specific instance. LaunchServices can only address an
    /// application, never an instance of it, so this is a `GURL` Apple event aimed at a
    /// process - the same event LaunchServices would send. Returns false when macOS
    /// hasn't been allowed to let us send it (the user declines the automation prompt).
    @discardableResult
    private static func deliver(_ url: URL, to pid: pid_t) -> Bool {
        // 'GURL'/'GURL' with a '----' direct object: the open-location event, spelled
        // out here so this doesn't have to pull in Carbon for four constants.
        let getURLClass = AEEventClass(0x4755524C)
        let directObject = AEKeyword(0x2D2D2D2D)
        let event = NSAppleEventDescriptor(
            eventClass: getURLClass,
            eventID: AEEventID(0x4755524C),
            targetDescriptor: NSAppleEventDescriptor(processIdentifier: pid),
            returnID: AEReturnID(-1),        // kAutoGenerateReturnID
            transactionID: AETransactionID(0))  // kAnyTransactionID
        event.setParam(NSAppleEventDescriptor(string: url.absoluteString), forKeyword: directObject)
        do {
            try event.sendEvent(options: .noReply, timeout: 5)
            return true
        } catch {
            return false
        }
    }

    private static func open(_ url: URL, with application: URL?) {
        guard let application else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.open([url], withApplicationAt: application, configuration: configuration)
    }

    private static var claudeApplicationURL: URL? {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: claudeBundleID) {
            return url
        }
        let fallback = URL(fileURLWithPath: "/Applications/Claude.app")
        return FileManager.default.fileExists(atPath: fallback.path) ? fallback : nil
    }
}

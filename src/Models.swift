import Foundation

enum Provider: String, Codable, CaseIterable {
    case claude = "Claude"
    case codex = "Codex"

    /// User-facing name. OpenAI's Codex desktop app is now the ChatGPT app, so we show
    /// "ChatGPT" while keeping the stored rawValue "Codex" for config, keychain, and
    /// dedup-key stability across the rename.
    var displayName: String {
        switch self {
        case .claude: return "Claude"
        case .codex: return "ChatGPT"
        }
    }

    /// Resolve a provider from either its display name ("ChatGPT") or stored rawValue.
    static func named(_ name: String) -> Provider? {
        allCases.first { $0.displayName == name || $0.rawValue == name }
    }
}

struct UsageWindow: Codable {
    var title: String
    var usedPercent: Double
    var remainingPercent: Double
    var resetsAt: Date?

    /// The 5h and weekly limits.
    var isPrimary: Bool { title == "5h" || title == "Week" }

    var displayText: String {
        let remaining = Int(remainingPercent.rounded())
        if let resetsAt {
            return "\(remaining)% left - resets \(Self.shortResetFormatter.string(from: resetsAt))"
        }
        return "\(remaining)% left"
    }

    private static let shortResetFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE HH:mm"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()
}

struct UsageInfo: Codable {
    var source: String
    var status: String?
    var windows: [UsageWindow]
    var creditsRemaining: Double?
    var accountEmail: String?
    var accountPlan: String?
    var updatedAt: Date

    var manualResets: ManualResetInventory?

    var primaryPercentUsed: Double? {
        windows.first?.usedPercent
    }

    /// The 5-hour session window (the first one when nothing is titled "5h").
    var fiveHourWindow: UsageWindow? {
        windows.first { $0.title == "5h" } ?? windows.first
    }

    /// The all-models weekly window, if the provider reports one.
    var weeklyWindow: UsageWindow? {
        windows.first { $0.title == "Week" }
    }

    var summaryLine: String {
        if let status, windows.isEmpty, creditsRemaining == nil {
            return status
        }

        var parts = windows.prefix(2).map { "\($0.title): \($0.displayText)" }
        if let creditsRemaining {
            parts.append(String(format: "%.0f credits", creditsRemaining))
        }
        if parts.isEmpty, let status {
            parts.append(status)
        }
        return parts.isEmpty ? "Usage unavailable" : parts.joined(separator: "  ")
    }
}

struct QuotaProofReport: Codable {
    var generatedAt: String
    var profiles: [QuotaProof]
}

struct QuotaProof: Codable {
    var provider: Provider
    var email: String?
    var plan: String?
    var endpoint: String
    var httpStatus: Int?
    var status: String?
    var parserMatchesProvider: Bool
    var windows: [QuotaWindowProof]
    var creditsRemaining: Double?
}

struct QuotaWindowProof: Codable {
    var title: String
    var providerUsedPercent: Double?
    var parsedUsedPercent: Double?
    var providerRemainingPercent: Double?
    var parsedRemainingPercent: Double?
    var providerReset: String?
    var parsedReset: String?
    var matches: Bool
}

struct LaunchProfile: Codable, Identifiable {
    var id: String
    var label: String
    var provider: Provider
    var appPath: String
    var dataDir: String
    var accountName: String?
    var accountEmail: String?
    var signedIn: Bool?
    var accountPlan: String?
    var quotaSummary: String?
    var quotaSource: String?
    var billingType: String?
    var accountUUID: String?
    /// The Claude organization this account is signed in to. Recorded on refresh because
    /// the desktop app files Code sessions under `<account uuid>/<org uuid>`, and finding
    /// them shouldn't need a network round trip.
    var organizationUUID: String?
    var isUserAdded: Bool?
    var isPendingLogin: Bool?
    var createdAt: Date?
    var scanSignature: String?
    var scanUpdatedAt: Date?
    var usage: UsageInfo?
    /// Set when the most recent refresh failed but we kept the last good `usage`.
    var usageStale: Bool?
    /// Human-readable reason the last refresh failed (for the stale indicator).
    var refreshError: String?
    /// Opt-in: automatically start a fresh 5h session for this account when the
    /// current window is idle or has reset (sends one tiny cheap prompt).
    var autoStartSession: Bool?
    /// Rate-limit guard so auto-start never fires more than once per window.
    var lastSessionKickAt: Date?
    /// Set once Claude's own server has told us who this window is signed in as. From
    /// then on the account uuid, email and name come from the server on every refresh,
    /// and the local-cache scan (which keeps whoever *used* to own the data directory)
    /// may no longer override them.
    var identityVerified: Bool?
    /// The account this window was signed in as before its most recent switch, and
    /// when the switch was noticed - what lets the menu say "was X, now Y".
    var previousAccountUUID: String?
    var accountChangedAt: Date?

    var showSparklines: Bool?
    var showLabels: Bool?
    var showSessionWindow: Bool?
    var showWeeklyWindows: Bool?
    var showResetTimes: Bool?
    var resetAlertMinutes: Int? // Legacy automatic-window reminder; no longer scheduled.
    var showManualResets: Bool?
    var manualResetExpiryAlertHours: Int?

    func visibleWindows() -> [UsageWindow] {
        (usage?.windows ?? []).filter {
            $0.title == "5h" ? (showSessionWindow ?? true) : (showWeeklyWindows ?? true)
        }
    }

    var autoStartsSession: Bool { autoStartSession ?? false }

    /// What the user typed for this account's label on its menu-bar icon (up to 3
    /// characters). Empty or nil means `defaultMenuBarLabel`.
    var menuBarLabel: String?

    /// The first 2 characters of the email (or of the name when there's no email).
    var defaultMenuBarLabel: String {
        String((accountEmail ?? accountName ?? "").prefix(2))
    }

    /// The label drawn on this account's icon in the menu bar.
    var menuBarLabelText: String {
        let custom = (menuBarLabel ?? "").trimmingCharacters(in: .whitespaces)
        return custom.isEmpty ? defaultMenuBarLabel : String(custom.prefix(3))
    }

    static func make(provider: Provider, appPath: String, dataDir: String, identity: AccountIdentity, isUserAdded: Bool = false) -> LaunchProfile {
        let account = identity.displayName ?? identity.email ?? "Signed-in account"
        return LaunchProfile(
            id: UUID().uuidString,
            label: "\(provider.displayName) - \(account)",
            provider: provider,
            appPath: appPath,
            dataDir: dataDir,
            accountName: identity.displayName,
            accountEmail: identity.email,
            signedIn: identity.isSignedIn,
            accountPlan: identity.planName,
            quotaSummary: identity.quotaSummary,
            quotaSource: identity.quotaSource,
            billingType: identity.billingType,
            accountUUID: identity.accountUUID,
            isUserAdded: isUserAdded,
            isPendingLogin: false,
            createdAt: Date(),
            scanSignature: nil,
            scanUpdatedAt: nil,
            usage: nil
        )
    }

    static func pending(provider: Provider, appPath: String, dataDir: String) -> LaunchProfile {
        LaunchProfile(
            id: UUID().uuidString,
            label: "\(provider.displayName) - Connect account",
            provider: provider,
            appPath: appPath,
            dataDir: dataDir,
            accountName: nil,
            accountEmail: nil,
            signedIn: false,
            accountPlan: nil,
            quotaSummary: nil,
            quotaSource: nil,
            billingType: nil,
            accountUUID: nil,
            isUserAdded: true,
            isPendingLogin: true,
            createdAt: Date(),
            scanSignature: nil,
            scanUpdatedAt: nil,
            usage: nil
        )
    }

    mutating func apply(identity: AccountIdentity) {
        signedIn = identity.isSignedIn
        if identityVerified == true {
            // The server already said who this is. The local scan reads caches that
            // outlive a sign-in to another account, so it only gets to fill in plan
            // details here, never the identity itself.
            applyPlan(identity)
            isPendingLogin = false
            return
        }
        // Email and name are sticky: the local store occasionally surfaces a stray
        // address/name, and the account's identity shouldn't flip between scans. Keep
        // the first real values until the account is removed and re-added.
        if (accountEmail?.isEmpty ?? true), let newEmail = identity.email {
            accountEmail = newEmail
        }
        if (accountName?.isEmpty ?? true), let newName = identity.displayName {
            accountName = newName
        }
        let account = accountName ?? accountEmail ?? "Signed-in account"
        label = "\(provider.displayName) - \(account)"
        applyPlan(identity)
        if let identityAccountUUID = identity.accountUUID {
            accountUUID = identityAccountUUID
        }
        isPendingLogin = false
    }

    private mutating func applyPlan(_ identity: AccountIdentity) {
        if let planName = identity.planName {
            // Never let a noisy "Free" reading downgrade a plan we already know is paid;
            // the local billing cache flips, so paid is sticky until removed/re-added.
            let newIsFree = planName.caseInsensitiveCompare("Free") == .orderedSame
            let currentIsPaid = ["pro", "max", "team", "plus"].contains((accountPlan ?? "").lowercased())
            if !(newIsFree && currentIsPaid) {
                accountPlan = planName
            }
        }
        quotaSummary = identity.quotaSummary
        quotaSource = identity.quotaSource
        if let identityBillingType = identity.billingType {
            billingType = identityBillingType
        }
    }

    /// Records who Claude's server says this window is signed in as. Unlike the local
    /// scan this is authoritative, so it replaces whatever was there - including the
    /// "sticky" email - and notes the switch when the account itself changed.
    mutating func apply(serverAccount account: ClaudeServerAccount) {
        let newUUID = account.uuid.lowercased()
        if let oldUUID = accountUUID?.lowercased(), !oldUUID.isEmpty, oldUUID != newUUID {
            previousAccountUUID = oldUUID
            accountChangedAt = Date()
        }
        accountUUID = newUUID
        if let email = account.email { accountEmail = email }
        accountName = account.name
        signedIn = true
        isPendingLogin = false
        identityVerified = true
        label = "\(provider.rawValue) - \(accountEmail ?? accountName ?? "Signed-in account")"
    }
}

/// The signed-in Claude account as reported by claude.ai itself.
struct ClaudeServerAccount {
    var uuid: String
    var email: String?
    var name: String?
}

struct AccountIdentity {
    var displayName: String?
    var email: String?
    var isSignedIn: Bool
    var planName: String?
    var quotaSummary: String?
    var quotaSource: String?
    var billingType: String?
    var accountUUID: String?

    var hasUsableLabel: Bool {
        displayName != nil || email != nil || isSignedIn
    }
}

/// Which reset countdowns a one-row menu bar shows next to the percentages.
enum MenuBarResetTimes: String, Codable, CaseIterable {
    case both, fiveHour, weekly, none

    var title: String {
        switch self {
        case .both: return "5h and weekly"
        case .fiveHour: return "5h only"
        case .weekly: return "Weekly only"
        case .none: return "None"
        }
    }

    var showsFiveHour: Bool { self == .both || self == .fiveHour }
    var showsWeekly: Bool { self == .both || self == .weekly }
}

struct AppConfig: Codable {
    var launchAtLogin: Bool
    var autoApproveCookieAccess: Bool?
    var configVersion: Int?
    var profiles: [LaunchProfile]
    var refreshIntervalMinutes: Int?
    var refreshIntervalSeconds: Int?
    var showPercentInMenuBar: Bool?
    var showSparklines: Bool?
    /// Legacy single-account menu-bar selection. Superseded by `menuBarProfileIDs`,
    /// kept for backward compatibility and as the fallback icon's target.
    var menuBarProfileID: String?
    /// Accounts whose 5h % is shown in the menu bar, each with its app icon, in the
    /// order they were pinned (which is their order in the grid).
    var menuBarProfileIDs: [String]?
    /// The menu-bar grid: 1-3 rows by 1-3 columns. Defaults to 2 x 1, the old layout.
    var menuBarRows: Int?
    var menuBarColumns: Int?
    /// Fill the top row first instead of going down each column first.
    var menuBarFillRowsFirst: Bool?
    /// Draw each account's label (`LaunchProfile.menuBarLabelText`) on its icon.
    var showMenuBarLabels: Bool?
    /// When the accounts sit on one row: also show the weekly %, which reset countdowns
    /// to show, and whether those sit stacked (5h above weekly) or side by side.
    var menuBarShowWeekly: Bool?
    var menuBarResetTimes: MenuBarResetTimes?
    var menuBarSideBySide: Bool?
    /// Download and install new GitHub releases in the background, restarting the app
    /// once the swap is done. Defaults to on for configs written before this existed.
    var autoUpdate: Bool?
    /// When the background updater last asked GitHub, so a restart doesn't re-check.
    var lastUpdateCheckAt: Date?
    /// Take over `claude://` links so a sign-in lands in the Claude window that started
    /// it (see ClaudeLinkRouter). Defaults to on.
    var routeClaudeLinks: Bool?
    /// Look after Claude updates its own updater can't apply while several Claude windows
    /// are open (see ClaudeUpdateCoordinator): put back a window Claude closes for one,
    /// and offer to finish it. Defaults to on. Closing a window is always the user's click.
    var offerClaudeUpdates: Bool?

    /// Notify when a 5h or weekly limit passes this percentage (and again at 100%).
    /// 0 turns those notifications off. Defaults to 90.
    var notifyAtPercent: Int?
    /// Notify when a limit that was used up has reset. Defaults to on.
    var notifyOnLimitReset: Bool?
    /// "Continue after limits": sessions that reach a limit are continued as planned
    /// (see KeepGoing). Defaults to off.
    var keepWorkGoing: Bool?
    /// The ring's order, as profile ids. Accounts missing from it follow in their usual
    /// order, so a new account joins at the end.
    var relayOrder: [String]?
    /// What happens to a session at its limit unless it has its own plan
    /// (`KeepGoing.Plan` raw value). Defaults to continuing it after the reset.
    var keepGoingPlan: String?
    /// The message that continues a session. Defaults to "continue".
    var keepGoingMessage: String?
    /// "Answer for me when I'm away": a session waiting on your answer gets one, typed
    /// in its window, once you've been away long enough. Defaults to off.
    var answerWhenAway: Bool?
    /// Minutes without a key or a click that count as away. Defaults to 10.
    var awayMinutes: Int?
    /// The answer unless a session has its own (`KeepGoing.Answer` raw value).
    var awayAnswer: String?
    var decideMessage: String?
    var aroundMessage: String?
    /// Also answer turns that just end on a "?". Defaults to off: often an offer.
    var answerTextQuestions: Bool?

    var notificationThreshold: Int { notifyAtPercent ?? 90 }
    var notifiesOnLimitReset: Bool { notifyOnLimitReset ?? true }
    var keepsWorkGoing: Bool { keepWorkGoing ?? false }
    var answersWhenAway: Bool { answerWhenAway ?? false }
    var awayAfter: Int { max(1, awayMinutes ?? 10) }
    var answersTextQuestions: Bool { answerTextQuestions ?? false }

    /// Every account, in ring order.
    var relayRing: [LaunchProfile] {
        let order = relayOrder ?? []
        let ranked = order.compactMap { id in profiles.first { $0.id == id } }
        return ranked + profiles.filter { !order.contains($0.id) }
    }

    static let maxMenuBarRows = 3
    static let maxMenuBarColumns = 3

    var menuBarGridRows: Int { min(Self.maxMenuBarRows, max(1, menuBarRows ?? 2)) }
    var menuBarGridColumns: Int { min(Self.maxMenuBarColumns, max(1, menuBarColumns ?? 1)) }
    /// How many accounts fit in the menu bar.
    var menuBarCapacity: Int { menuBarGridRows * menuBarGridColumns }
    var fillsMenuBarRowsFirst: Bool { menuBarFillRowsFirst ?? false }
    var showsMenuBarLabels: Bool { showMenuBarLabels ?? false }
    var showsMenuBarWeekly: Bool { menuBarShowWeekly ?? true }
    var menuBarResets: MenuBarResetTimes { menuBarResetTimes ?? .both }
    var menuBarDetailsSideBySide: Bool { menuBarSideBySide ?? false }

    /// The effective menu-bar accounts (up to the grid's size), falling back to the
    /// legacy single ID.
    var menuBarProfileIDList: [String] {
        if let ids = menuBarProfileIDs, !ids.isEmpty {
            return Array(ids.prefix(menuBarCapacity))
        }
        if let single = menuBarProfileID {
            return [single]
        }
        return []
    }

    /// Whether the app may read the encrypted cookie store via the keychain.
    /// Defaults to `true` for configs written before this option existed.
    var allowsCookieKeychain: Bool { autoApproveCookieAccess ?? true }

    var showsSparklines: Bool { showSparklines ?? true }

    var autoUpdates: Bool { autoUpdate ?? true }

    var routesClaudeLinks: Bool { routeClaudeLinks ?? true }

    var offersClaudeUpdates: Bool { offerClaudeUpdates ?? true }

    /// How often the background refresh timer fires. Clamped to [30s, 1h].
    var refreshInterval: TimeInterval {
        if let seconds = refreshIntervalSeconds {
            return TimeInterval(min(3600, max(30, seconds)))
        }
        let minutes = min(120, max(1, refreshIntervalMinutes ?? 2))
        return TimeInterval(minutes * 60)
    }

    var showsPercentInMenuBar: Bool { showPercentInMenuBar ?? false }

    /// Pins or unpins an account in the menu bar. When the grid is full, the account
    /// pinned longest ago makes room. Returns the ids that were unpinned to make room.
    @discardableResult
    mutating func setMenuBar(_ id: String, shown: Bool) -> [String] {
        var ids = showsPercentInMenuBar ? menuBarProfileIDList : []
        var bumped: [String] = []
        if shown {
            if !ids.contains(id) { ids.append(id) }
            if ids.count > menuBarCapacity {
                bumped = Array(ids.prefix(ids.count - menuBarCapacity))
                ids.removeFirst(ids.count - menuBarCapacity)
            }
        } else {
            ids.removeAll { $0 == id }
        }
        menuBarProfileIDs = ids
        menuBarProfileID = ids.first
        showPercentInMenuBar = !ids.isEmpty
        return bumped
    }

    /// Resizes the menu-bar grid. Accounts in cells that no longer exist are unpinned,
    /// from the last cell back. Returns the ids that were unpinned.
    @discardableResult
    mutating func setMenuBarGrid(rows: Int, columns: Int) -> [String] {
        let ids = showsPercentInMenuBar ? (menuBarProfileIDs ?? menuBarProfileID.map { [$0] } ?? []) : []
        menuBarRows = min(Self.maxMenuBarRows, max(1, rows))
        menuBarColumns = min(Self.maxMenuBarColumns, max(1, columns))
        guard ids.count > menuBarCapacity else { return [] }
        let kept = Array(ids.prefix(menuBarCapacity))
        menuBarProfileIDs = kept
        menuBarProfileID = kept.first
        showPercentInMenuBar = !kept.isEmpty
        return Array(ids.dropFirst(menuBarCapacity))
    }
}


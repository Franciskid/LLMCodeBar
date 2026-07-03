import Foundation

enum Provider: String, Codable, CaseIterable {
    case claude = "Claude"
    case codex = "Codex"
}

struct UsageWindow: Codable {
    var title: String
    var usedPercent: Double
    var remainingPercent: Double
    var resetsAt: Date?

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

    var primaryPercentUsed: Double? {
        windows.first?.usedPercent
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

    var autoStartsSession: Bool { autoStartSession ?? false }

    static func make(provider: Provider, appPath: String, dataDir: String, identity: AccountIdentity, isUserAdded: Bool = false) -> LaunchProfile {
        let account = identity.displayName ?? identity.email ?? "Signed-in account"
        return LaunchProfile(
            id: UUID().uuidString,
            label: "\(provider.rawValue) - \(account)",
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
            label: "\(provider.rawValue) - Connect account",
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
        let account = identity.displayName ?? identity.email ?? "Signed-in account"
        label = "\(provider.rawValue) - \(account)"
        accountName = identity.displayName
        accountEmail = identity.email
        signedIn = identity.isSignedIn
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
        if let identityAccountUUID = identity.accountUUID {
            accountUUID = identityAccountUUID
        }
        isPendingLogin = false
    }
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

struct AppConfig: Codable {
    var launchAtLogin: Bool
    var autoApproveCookieAccess: Bool?
    var configVersion: Int?
    var profiles: [LaunchProfile]
    var refreshIntervalMinutes: Int?
    var refreshIntervalSeconds: Int?
    var showPercentInMenuBar: Bool?
    var showSparklines: Bool?
    /// Which account drives the menu-bar icon/percentage. Nil = first account.
    var menuBarProfileID: String?

    /// Whether the app may read the encrypted cookie store via the keychain.
    /// Defaults to `true` for configs written before this option existed.
    var allowsCookieKeychain: Bool { autoApproveCookieAccess ?? true }

    var showsSparklines: Bool { showSparklines ?? true }

    /// How often the background refresh timer fires. Clamped to [30s, 1h].
    var refreshInterval: TimeInterval {
        if let seconds = refreshIntervalSeconds {
            return TimeInterval(min(3600, max(30, seconds)))
        }
        let minutes = min(120, max(1, refreshIntervalMinutes ?? 2))
        return TimeInterval(minutes * 60)
    }

    var showsPercentInMenuBar: Bool { showPercentInMenuBar ?? false }
}


import Foundation

enum ProfileFormatting {
    static func title(for profile: LaunchProfile) -> String {
        if profile.isPendingLogin == true {
            return "Connect account"
        }
        if let email = profile.accountEmail {
            return email
        }
        if let name = profile.accountName {
            return name
        }
        return profile.signedIn == true ? "Signed-in account" : "Not signed in"
    }

    static func subtitle(for profile: LaunchProfile) -> String {
        var parts = [profile.provider.rawValue]
        if let plan = profile.usage?.accountPlan ?? profile.accountPlan {
            parts.append(plan)
        } else if profile.signedIn == true {
            parts.append("Subscription unknown")
        }
        return parts.joined(separator: " · ")
    }

    static func detail(for profile: LaunchProfile, isRefreshing: Bool) -> String {
        if let usage = profile.usage {
            return usage.summaryLine
        }
        if profile.isPendingLogin == true {
            return "Waiting for login in the isolated profile"
        }
        return isRefreshing ? "Checking account and quota..." : "Usage not refreshed yet"
    }

    static func usageLines(for profile: LaunchProfile, isRefreshing: Bool) -> [String] {
        if let usage = profile.usage {
            var lines = usage.windows.prefix(3).map { window in
                "\(window.title): \(window.displayText.replacingOccurrences(of: " - ", with: " · "))"
            }
            if let creditsRemaining = usage.creditsRemaining {
                lines.append(String(format: "Credits: %.0f", creditsRemaining))
            }
            if lines.isEmpty, let status = usage.status {
                lines.append(status)
            }
            return lines.isEmpty ? ["Usage unavailable"] : lines
        }
        if profile.isPendingLogin == true {
            return ["Waiting for login in the isolated profile"]
        }
        return [isRefreshing ? "Checking account and quota..." : "Usage not refreshed yet"]
    }

    static func windowTitle(_ title: String) -> String {
        switch title {
        case "5h": return "Session"
        case "Week": return "Weekly"
        case "Sonnet week": return "Sonnet"
        default: return title
        }
    }

    static func usedText(for window: UsageWindow) -> String {
        "\(Int(window.usedPercent.rounded()))% used"
    }

    static func resetText(for window: UsageWindow) -> String {
        guard let resetsAt = window.resetsAt else { return "-" }
        // A weekly window resets days from now, so a bare "20:00" is meaningless.
        // Show the weekday whenever the reset isn't today.
        if Calendar.current.isDate(resetsAt, inSameDayAs: Date()) {
            return resetClockFormatter.string(from: resetsAt)
        }
        return resetDayFormatter.string(from: resetsAt)
    }

    static func primaryUsagePercent(for profile: LaunchProfile) -> Double? {
        profile.usage?.primaryPercentUsed
    }

    static func bestUsagePercent(in profiles: [LaunchProfile]) -> Double? {
        profiles
            .filter { !isFreePlan($0.usage?.accountPlan ?? $0.accountPlan) }
            .compactMap(primaryUsagePercent(for:))
            .max()
    }

    /// The 5h (Session) usage that drives the menu-bar icon: the account the user
    /// designated, or the first signed-in account if none is set.
    static func menuBarPercent(in profiles: [LaunchProfile], selectedID: String?) -> Double? {
        if let selectedID, let selected = profiles.first(where: { $0.id == selectedID }) {
            return primaryUsagePercent(for: selected)
        }
        return profiles.first { $0.isPendingLogin != true }.flatMap(primaryUsagePercent(for:))
    }

    static func isFreePlan(_ plan: String?) -> Bool {
        plan?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "free"
    }

    static func providerSymbol(for provider: Provider) -> String {
        switch provider {
        case .claude: return "sparkles"
        case .codex: return "terminal"
        }
    }

    /// Compact, locale-stable age of the last successful reading, e.g. "6m ago".
    static func updatedAgo(for profile: LaunchProfile) -> String {
        guard let updatedAt = profile.usage?.updatedAt else { return "" }
        let seconds = max(0, Int(Date().timeIntervalSince(updatedAt)))
        if seconds < 60 { return "just now" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m ago" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)h ago" }
        return "\(hours / 24)d ago"
    }

    private static let resetClockFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        formatter.timeZone = .current
        return formatter
    }()

    private static let resetDayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE HH:mm"
        formatter.timeZone = .current
        return formatter
    }()
}


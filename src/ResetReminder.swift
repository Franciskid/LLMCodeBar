import Foundation
import UserNotifications

/// Warn about the redemption deadline of a saved manual reset, never quota-window timers.
enum ResetReminder {
    struct Plan {
        var id: String
        var receiptKey: String
        var expiry: Date
        var delay: TimeInterval
        var body: String
    }

    static func plans(_ profile: LaunchProfile, now: Date = Date()) -> [Plan] {
        guard let hours = profile.manualResetExpiryAlertHours, hours > 0,
              profile.usageStale != true, let inventory = profile.usage?.manualResets,
              inventory.error == nil else { return [] }
        return inventory.allowances.compactMap { allowance in
            guard allowance.count > 0, let expiry = allowance.expiresAt, expiry > now else { return nil }
            let fireAt = max(expiry.addingTimeInterval(-Double(hours * 3600)), allowance.startsAt ?? .distantPast)
            guard fireAt < expiry else { return nil }
            let key = "manual-reset.\(profile.id).\(allowance.key)"
            return Plan(id: "\(key).\(hours)", receiptKey: key, expiry: expiry,
                delay: max(1, fireAt.timeIntervalSince(now)),
                body: "\(profile.accountEmail ?? profile.label): \(allowance.count) \(allowance.kind) manual reset\(allowance.count == 1 ? "" : "s") expire\(allowance.count == 1 ? "s" : "") \(ManualResetInventory.dateText(expiry)).")
        }
    }

    static func requestAuthorization(profiles: [LaunchProfile]) {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            if granted { sync(profiles) }
        }
    }

    static func sync(_ profiles: [LaunchProfile], now: Date = Date()) {
        let center = UNUserNotificationCenter.current()
        center.getPendingNotificationRequests { requests in
            var wanted = Set<String>()
            let pending = Set(requests.map(\.identifier))
            for profile in profiles {
                for plan in plans(profile, now: now) {
                    wanted.insert(plan.id)
                    if pending.contains(plan.id) { continue }
                    let epoch = Int(plan.expiry.timeIntervalSince1970)
                    if plan.delay <= 1, UserDefaults.standard.integer(forKey: plan.receiptKey) == epoch { continue }
                    let content = UNMutableNotificationContent()
                    content.title = "\(profile.provider.displayName) manual reset expires soon"
                    content.body = plan.body
                    content.sound = .default
                    center.add(UNNotificationRequest(identifier: plan.id, content: content,
                        trigger: UNTimeIntervalNotificationTrigger(timeInterval: plan.delay, repeats: false))) { error in
                            if error == nil { UserDefaults.standard.set(epoch, forKey: plan.receiptKey) }
                        }
                }
            }
            // Also clear the automatic quota reminders mistakenly added in v0.7.0.
            center.removePendingNotificationRequests(withIdentifiers: requests.filter {
                ($0.identifier.hasPrefix("reset.") || $0.identifier.hasPrefix("manual-reset.")) && !wanted.contains($0.identifier)
            }.map(\.identifier))
        }
    }
}

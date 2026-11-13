import Foundation
import UserNotifications

/// Warn about the redemption deadline of a saved manual reset, never quota-window timers.
enum ResetReminder {
    private static var generation = 0
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
            return Plan(id: "\(key).\(hours).\(allowance.count)", receiptKey: key, expiry: expiry,
                delay: max(1, fireAt.timeIntervalSince(now)),
                body: "\(profile.accountEmail ?? profile.label): \(allowance.count) \(allowance.kind) manual reset\(allowance.count == 1 ? "" : "s") expire\(allowance.count == 1 ? "s" : "") \(ManualResetInventory.dateText(expiry)).")
        }
    }

    static func requestAuthorization(completion: @escaping () -> Void) {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in
            DispatchQueue.main.async { completion() }
        }
    }

    static func sync(_ profiles: [LaunchProfile], now: Date = Date()) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { sync(profiles, now: now) }
            return
        }
        generation += 1
        let revision = generation
        let center = UNUserNotificationCenter.current()
        center.getPendingNotificationRequests { requests in
            DispatchQueue.main.async {
                guard revision == generation else { return }
                var wanted = Set<String>()
                let pending = Set(requests.map(\.identifier))
                for profile in profiles {
                    // Turning notifications off also clears the scheduling receipt so
                    // enabling them again inside the lead time can notify promptly.
                    if (profile.manualResetExpiryAlertHours ?? 0) == 0 {
                        let prefix = "manual-reset.\(profile.id)."
                        for key in UserDefaults.standard.dictionaryRepresentation().keys where key.hasPrefix(prefix) {
                            UserDefaults.standard.removeObject(forKey: key)
                        }
                    }
                    for plan in plans(profile, now: now) {
                        wanted.insert(plan.id)
                        let epoch = Int(plan.expiry.timeIntervalSince1970)
                        if pending.contains(plan.id) {
                            UserDefaults.standard.set(epoch, forKey: plan.receiptKey)
                            continue
                        }
                        if requests.contains(where: { $0.identifier != plan.id && $0.identifier.hasPrefix(plan.receiptKey + ".") }) {
                            UserDefaults.standard.removeObject(forKey: plan.receiptKey)
                        }
                        if plan.delay <= 1, UserDefaults.standard.integer(forKey: plan.receiptKey) == epoch { continue }
                        let content = UNMutableNotificationContent()
                        content.title = "\(profile.provider.displayName) manual reset expires soon"
                        content.body = plan.body
                        content.sound = .default
                        center.add(UNNotificationRequest(identifier: plan.id, content: content,
                            trigger: UNTimeIntervalNotificationTrigger(timeInterval: plan.delay, repeats: false))) { error in
                                DispatchQueue.main.async {
                                    if error == nil, revision == generation { UserDefaults.standard.set(epoch, forKey: plan.receiptKey) }
                                }
                            }
                    }
                }
                center.removePendingNotificationRequests(withIdentifiers: requests.filter {
                    ($0.identifier.hasPrefix("reset.") || $0.identifier.hasPrefix("manual-reset.")) && !wanted.contains($0.identifier)
                }.map(\.identifier))
            }
        }
    }
}

import Foundation
import UserNotifications

/// Schedule against the provider's reset date, independently of the polling interval.
enum ResetReminder {
    static func delay(reset: Date, minutes: Int, now: Date) -> TimeInterval? {
        guard minutes > 0, reset > now else { return nil }
        return max(1, reset.timeIntervalSince(now) - Double(minutes * 60))
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
            for profile in profiles where profile.usageStale != true {
                guard let minutes = profile.resetAlertMinutes, minutes > 0 else { continue }
                for window in profile.usage?.windows ?? [] {
                    guard let reset = window.resetsAt else { continue }
                    guard let delay = delay(reset: reset, minutes: minutes, now: now) else { continue }
                    let id = "reset.\(profile.id).\(window.title).\(Int(reset.timeIntervalSince1970)).\(minutes)"
                    wanted.insert(id)
                    if pending.contains(id) { continue }
                    // An opt-in inside the lead time fires once, not on every poll.
                    let key = "reset.imminent.\(profile.id).\(window.title)"
                    let epoch = Int(reset.timeIntervalSince1970)
                    if delay <= 1 {
                        guard UserDefaults.standard.integer(forKey: key) != epoch else { continue }
                    }
                    let content = UNMutableNotificationContent()
                    content.title = "\(profile.provider.displayName) limit resets soon"
                    content.body = "\(profile.accountEmail ?? profile.label): \(ProfileFormatting.windowTitle(window.title)) resets at \(ProfileFormatting.resetText(for: window))."
                    content.sound = .default
                    center.add(UNNotificationRequest(identifier: id, content: content,
                        trigger: UNTimeIntervalNotificationTrigger(timeInterval: max(1, delay), repeats: false))) { error in
                            if error == nil { UserDefaults.standard.set(epoch, forKey: key) }
                        }
                }
            }
            center.removePendingNotificationRequests(withIdentifiers: requests.filter { $0.identifier.hasPrefix("reset.") && !wanted.contains($0.identifier) }.map(\.identifier))
        }
    }
}

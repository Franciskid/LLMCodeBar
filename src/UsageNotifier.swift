import AppKit
import UserNotifications

/// macOS notifications for the 5h and weekly limits: once when one passes the chosen
/// percentage, once when it's used up, and once when a used-up limit has reset.
///
/// Each limit is notified at most once per level per window - the window is told apart
/// by its reset time, so the next 5h window starts fresh.
final class UsageNotifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = UsageNotifier()

    /// Only these limits notify; the rest are informational.
    static let watchedWindows: Set<String> = ["5h", "Week"]

    private let defaultsKey = "notifiedUsageLevels"
    private var authorized: Bool?

    func start() {
        // A notification center needs a real app bundle; the CLI modes have none.
        guard Bundle.main.bundleIdentifier != nil else { return }
        UNUserNotificationCenter.current().delegate = self
        // Before a limit (the 90% warning): pick this session's plan.
        let ask = [
            UNNotificationAction(identifier: "plan." + KeepGoing.Plan.continueHere.rawValue, title: "Continue here after the reset", options: []),
            UNNotificationAction(identifier: "plan." + KeepGoing.Plan.move.rawValue, title: "Move to another account", options: []),
            UNNotificationAction(identifier: "plan." + KeepGoing.Plan.leave.rawValue, title: "Don't continue", options: []),
        ]
        // At a limit: change what happens this time.
        let limit = [
            UNNotificationAction(identifier: Self.moveNow, title: "Move now", options: []),
            UNNotificationAction(identifier: Self.dontContinue, title: "Don't continue", options: []),
        ]
        let limitStay = [UNNotificationAction(identifier: Self.dontContinue, title: "Don't continue", options: [])]
        let failed = [UNNotificationAction(identifier: Self.tryAgain, title: "Try again", options: [])]
        // A session asks you something: answer it from here, or click to open it.
        let question = [
            UNNotificationAction(identifier: "answer." + KeepGoing.Answer.decide.rawValue, title: KeepGoing.Answer.decide.title, options: []),
            UNNotificationAction(identifier: "answer." + KeepGoing.Answer.around.rawValue, title: KeepGoing.Answer.around.title, options: []),
        ]
        UNUserNotificationCenter.current().setNotificationCategories([
            UNNotificationCategory(identifier: Self.questionCategory, actions: question, intentIdentifiers: [], options: []),
            UNNotificationCategory(identifier: Self.waitingCategory, actions: [], intentIdentifiers: [], options: []),
            UNNotificationCategory(identifier: Self.keepGoingCategory, actions: ask, intentIdentifiers: [], options: []),
            UNNotificationCategory(identifier: Self.limitCategory, actions: limit, intentIdentifiers: [], options: []),
            UNNotificationCategory(identifier: Self.limitStayCategory, actions: limitStay, intentIdentifiers: [], options: []),
            UNNotificationCategory(identifier: Self.failedCategory, actions: failed, intentIdentifiers: [], options: []),
        ])
    }

    static let keepGoingCategory = "keepgoing.ask"
    static let limitCategory = "keepgoing.limit"
    static let limitStayCategory = "keepgoing.limit-stay"
    static let failedCategory = "keepgoing.failed"
    static let questionCategory = "keepgoing.question"
    static let waitingCategory = "keepgoing.waiting"
    static let moveNow = "keepgoing.move-now"
    static let dontContinue = "keepgoing.leave"
    static let tryAgain = "keepgoing.retry"

    /// A session reached its limit: what happens next, with a way to change it.
    func postLimitReached(key: String, title: String, body: String, canMove: Bool, canLeave: Bool) {
        post(title: title, body: body, id: "keepgoing-limit|\(key)", sessionKey: key,
             category: canMove ? Self.limitCategory : canLeave ? Self.limitStayCategory : nil)
    }

    /// Continuing a session didn't work: why, with "Try again".
    func postNeedsYou(key: String, title: String, reason: String) {
        post(title: "“\(title)” needs you", body: "\(reason). Nothing was sent. Open it in Claude, or try again.",
             id: "keepgoing-failed|\(key)", sessionKey: key, category: Self.failedCategory)
    }

    /// A session is asking you something (or waits for its plan to be approved).
    /// Clicking it opens the session; a question can be answered from here.
    func postQuestion(key: String, title: String, body: String, canAnswer: Bool) {
        post(title: title, body: body, id: "keepgoing-question|\(key)", sessionKey: key,
             category: canAnswer ? Self.questionCategory : Self.waitingCategory)
    }

    /// What Keep Going did, good or bad.
    func postKeepGoing(title: String, body: String) {
        post(title: title, body: body, id: "keepgoing-result|\(UUID().uuidString)", log: false)
    }

    /// Asks macOS once; afterwards it remembers the answer.
    func requestPermissionIfNeeded() {
        guard Bundle.main.bundleIdentifier != nil, authorized == nil else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
            DispatchQueue.main.async {
                self.authorized = granted
                if let error {
                    ActivityLog.shared.error("Notifications", "macOS refused notifications: \(error.localizedDescription)")
                } else if !granted {
                    ActivityLog.shared.info("Notifications", "Notifications are turned off for LLMCodeBar in System Settings.")
                }
            }
        }
    }

    /// Compares each account's limits before and after a refresh.
    func process(old: [LaunchProfile], new: [LaunchProfile], config: AppConfig) {
        let threshold = config.notificationThreshold
        guard threshold > 0 || config.notifiesOnLimitReset else { return }
        var notified = UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: Int] ?? [:]
        let before = UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: Int] ?? [:]

        for profile in new where profile.usageStale != true {
            guard let windows = profile.usage?.windows else { continue }
            let account = ProfileFormatting.title(for: profile)
            let app = profile.provider.displayName
            let previous = old.first { $0.id == profile.id }?.usage?.windows ?? []

            for window in windows where Self.watchedWindows.contains(window.title) {
                let name = ProfileFormatting.windowTitle(window.title).lowercased()
                let key = "\(profile.id)|\(window.title)|\(Int(window.resetsAt?.timeIntervalSince1970 ?? 0) / 60)"
                let level = notified[key] ?? 0
                let used = window.usedPercent

                if threshold > 0, used >= 99.5, level < 100 {
                    notified[key] = 100
                    post(title: "\(app) \(name) limit reached",
                         body: "\(account) has used all of its \(name) limit\(resetText(window)).",
                         id: key)
                } else if threshold > 0, used >= Double(threshold), level < threshold {
                    notified[key] = threshold
                    // When something is running on this account, offer to decide now what
                    // happens to it when the limit runs out.
                    let active = config.keepsWorkGoing ? KeepGoing.activeSession(on: profile) : nil
                    let about = active.map { " “\($0.title)” is running here: choose what happens to it at the limit." } ?? ""
                    post(title: "\(app) \(name) limit at \(Int(used.rounded()))%",
                         body: "\(account) has \(Int(window.remainingPercent.rounded()))% of its \(name) limit left\(resetText(window)).\(about)",
                         id: key,
                         sessionKey: active?.key)
                }

                // A limit that was used up and now isn't: it reset.
                if config.notifiesOnLimitReset,
                   let earlier = previous.first(where: { $0.title == window.title }),
                   earlier.usedPercent >= 99.5, used < 50 {
                    post(title: "\(app) \(name) limit has reset",
                         body: "\(account) can be used again.",
                         id: "\(key)|reset")
                }
            }
        }

        // Forget windows that have long since ended.
        let cutoff = Int(Date().addingTimeInterval(-8 * 86_400).timeIntervalSince1970) / 60
        notified = notified.filter { key, _ in
            guard let minutes = key.split(separator: "|").last.flatMap({ Int($0) }) else { return false }
            return minutes == 0 || minutes > cutoff
        }
        if notified != before {
            UserDefaults.standard.set(notified, forKey: defaultsKey)
        }
    }

    private func resetText(_ window: UsageWindow) -> String {
        guard let reset = window.resetsAt, reset > Date() else { return "" }
        let formatter = DateFormatter()
        formatter.dateFormat = Calendar.current.isDateInToday(reset) ? "HH:mm" : "EEE HH:mm"
        return ", resets \(formatter.string(from: reset))"
    }

    private func post(title: String, body: String, id: String, sessionKey: String? = nil, category: String? = UsageNotifier.keepGoingCategory, log: Bool = true) {
        if log { ActivityLog.shared.info("Notifications", "\(title). \(body)") }
        guard Bundle.main.bundleIdentifier != nil else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        if let sessionKey {
            if let category { content.categoryIdentifier = category }
            content.userInfo = ["sessionKey": sessionKey]
        }
        let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                ActivityLog.shared.error("Notifications", "Couldn't show “\(title)”: \(error.localizedDescription)")
            }
        }
    }

    // Shown even while LLMCodeBar is the active app (it has no windows most of the time,
    // but Settings or the transfer window may be in front).
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        defer { completionHandler() }
        guard let key = response.notification.request.content.userInfo["sessionKey"] as? String else { return }
        switch response.actionIdentifier {
        case Self.moveNow:
            KeepGoing.shared.choose(.move, forThisLimitOf: key)
        case Self.dontContinue:
            KeepGoing.shared.choose(.leave, forThisLimitOf: key)
        case Self.tryAgain:
            KeepGoing.shared.retry(key)
        case let id where id.hasPrefix("plan."):
            guard let plan = KeepGoing.Plan(rawValue: String(id.dropFirst(5))) else { return }
            KeepGoing.shared.setPlan(plan, for: key)
        case let id where id.hasPrefix("answer."):
            guard let answer = KeepGoing.Answer(rawValue: String(id.dropFirst(7))) else { return }
            KeepGoing.shared.answerNow(key, how: answer)
        case UNNotificationDefaultActionIdentifier:
            let category = response.notification.request.content.categoryIdentifier
            if category == Self.questionCategory || category == Self.waitingCategory { KeepGoing.shared.open(key) }
        default:
            return
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}

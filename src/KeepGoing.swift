import AppKit
import ApplicationServices

/// Continues Claude Code sessions past a usage limit, in their own Claude window.
///
/// It watches the Claude Code sessions of the last few hours. When one reaches its limit
/// - its transcript ends with Claude Code's own "You've hit your limit" (`rate_limit`)
/// line - it does what was decided for that session:
///
/// - **Continue here**: wait for the account's reset, then send the message ("continue"
///   by default) in the same window. A timer wakes at the reset itself.
/// - **Move**: hand the session to the chosen account, or the next one in the ring with
///   room, and send the message there right away. When every account is full it waits
///   for whichever comes back first and continues there.
/// - **Leave it**.
///
/// The defaults come from Settings; any session can have its own plan, target and
/// message, chosen in the menu. Nothing ever runs out of sight: the message is typed in
/// the session's own window (see `ClaudeWindowMessenger`), and when that can't be done
/// the session shows "needs you" and a notification says why.
///
/// Codex threads aren't continued - there's no Codex window to send into - you get a
/// notification when one can carry on.
final class KeepGoing {
    static let shared = KeepGoing()

    /// What happens to a session at its limit. The raw values are the old names, so
    /// choices saved by earlier versions still read.
    enum Plan: String, Codable, CaseIterable {
        case continueHere = "waitForReset"
        case move = "moveOn"
        case leave
    }

    /// A session's own choices; nil fields follow the defaults.
    struct Override: Codable, Equatable {
        var plan: Plan?
        /// The account a "move" goes to, as a profile id. Nil: any account with room.
        var target: String?
        var message: String?
        /// What it's told when it asks you and you're away.
        var answer: Answer?

        var isEmpty: Bool { plan == nil && target == nil && message == nil && answer == nil }
    }

    /// What a session is told when it asks you something and you're away.
    enum Answer: String, Codable, CaseIterable {
        case decide, around, wait

        var title: String {
            switch self {
            case .decide: return "Decide for me"
            case .around: return "Do what you can without it"
            case .wait: return "Wait for me"
            }
        }

        static let decideMessage = "I'm away for a while. Go with what you'd recommend and keep going. Leave anything that can't be undone for me."
        static let aroundMessage = "I'm away for a while. Leave this question for me and carry on with whatever doesn't depend on it."
    }

    /// A session waiting on you, as its transcript shows it.
    struct Question: Equatable {
        enum Kind: Equatable {
            /// A question card (AskUserQuestion) with nothing answered yet.
            case card
            /// The desktop app's next-step box asked something at the end of the turn.
            case nextStep
            /// The turn just ended on a "?".
            case text
            /// A plan waiting for approval: never answered for you.
            case plan
        }
        var kind: Kind
        var text: String
        var options: [String] = []
        /// The asking line's uuid, so each question is answered once.
        var marker: String
        var askedAt: Date
    }

    /// Whether you're at the Mac: how long since the last key or click, and the lock.
    struct Presence: Equatable {
        var idle: TimeInterval
        var locked: Bool

        static let here = Presence(idle: 0, locked: false)

        static func now() -> Presence {
            let any = CGEventType(rawValue: ~0) ?? .null
            let idle = CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: any)
            let session = CGSessionCopyCurrentDictionary() as? [String: Any]
            return Presence(idle: idle, locked: session?["CGSSessionScreenIsLocked"] as? Bool ?? false)
        }

        func isAway(after minutes: Int) -> Bool { locked || idle >= TimeInterval(minutes * 60) }
    }

    /// One session as the menu shows it: every word is decided here, so the scenario
    /// harness can check them.
    struct SessionInfo: Equatable {
        enum State: String, Equatable {
            case working, idle, waitingForReset, moving, sending, needsYou, off, askingYou, waitingForYou

            var label: String {
                switch self {
                case .working: return "working"
                case .idle: return "idle"
                case .waitingForReset: return "waiting for reset"
                case .moving: return "moving"
                case .sending: return "sending"
                case .needsYou: return "needs you"
                case .off: return "off"
                case .askingYou: return "asking you"
                case .waitingForYou: return "waiting for you"
                }
            }
        }
        enum Icon: Equatable { case here, move, leave, warning, none, decide, around, wait, lock }
        enum Tone: Equatable { case normal, muted, alert }
        struct Target: Equatable {
            var id: String
            var name: String
            var plan: String
            var room: String
            var hasRoom: Bool
            var appPath: String
            /// A ChatGPT account: the session is imported and opened there, and you
            /// send the message yourself.
            var isChatGPT: Bool
        }

        var key: String
        var title: String
        var accountID: String
        var accountName: String
        var accountAppPath: String
        /// "moved from franciskid97 at 23:41"
        var movedNote: String?
        var state: State
        var planText: String
        var planIcon: Icon
        var planTone: Tone
        /// "default" or "custom" after the plan line; nil when it doesn't apply.
        var marker: String?
        /// The plan, target and message in force, for the options.
        var plan: Plan
        var chosenTarget: String?
        var targets: [Target]
        var message: String
        var isCustom: Bool
        /// A button for this session: "Try again", "Continue now".
        var action: String?
        /// What it's asking you, while it waits on you.
        var question: Question?
        /// The answer in force for this session.
        var answer: Answer = .decide
        /// It's asking something an answer can be typed for (not a plan approval).
        var canAnswerNow: Bool = false
        /// What happens at its limit, in one line, for the options.
        var limitSummary: String = ""
    }

    /// A session found on disk.
    struct Observed {
        var key: String
        var title: String
        var profileID: String
        var localID: String
        var cliSessionID: String?
        /// When its transcript last changed.
        var modified: Date
        /// The limit line's uuid, when the transcript ends with one.
        var limitMarker: String?
        /// What it's waiting on you for, if anything.
        var question: Question? = nil
    }

    /// Something to do after an assessment.
    enum Action: Equatable {
        case send(key: String, to: String, moved: Bool, message: String)
        case notifyLimit(key: String, title: String, body: String, canMove: Bool, canLeave: Bool)
        case answer(key: String, to: String, how: Answer, message: String)
        case notifyQuestion(key: String, title: String, body: String, canAnswer: Bool)
    }

    struct Assessment {
        var sessions: [SessionInfo]
        var actions: [Action]
        /// The earliest reset a session is waiting for.
        var wakeAt: Date?
    }

    struct Running: Equatable {
        var moving: Bool
        var to: String
        /// Set when what's being sent is an answer to a question.
        var answering: Answer? = nil
    }

    struct Store: Codable {
        struct Failed: Codable, Equatable { var marker: String; var reason: String }
        struct Moved: Codable, Equatable {
            var from: String
            var to: String
            var at: Date
            /// The ChatGPT thread it became, when it moved to ChatGPT.
            var thread: String?
        }
        struct OneOff: Codable, Equatable { var marker: String; var plan: Plan }
        struct Answered: Codable, Equatable { var marker: String; var how: Answer; var at: Date }

        var overrides: [String: Override] = [:]
        /// The limit each session was last acted on for, so each is acted on once.
        var handled: [String: String] = [:]
        /// Limits reached before this was turned on: left alone unless asked.
        var before: [String: String] = [:]
        var failed: [String: Failed] = [:]
        var moved: [String: Moved] = [:]
        /// A choice from a notification, for that one limit.
        var oneOff: [String: OneOff] = [:]
        var notified: [String: String] = [:]
        var moves: [Date] = []
        /// The last question answered for each session, so each is answered once.
        var answered: [String: Answered] = [:]
        /// When answers went out, per session, for the hourly cap.
        var answers: [String: [Date]] = [:]
        var answerFailed: [String: Failed] = [:]
        /// The question each session was last notified about.
        var asked: [String: String] = [:]
        /// Set once this version has looked at the sessions. Limits it finds the first
        /// time are left alone, like limits from before it was turned on.
        var version: Int?

        init() {}

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            overrides = try c.decodeIfPresent([String: Override].self, forKey: .overrides) ?? [:]
            handled = try c.decodeIfPresent([String: String].self, forKey: .handled) ?? [:]
            before = try c.decodeIfPresent([String: String].self, forKey: .before) ?? [:]
            failed = try c.decodeIfPresent([String: Failed].self, forKey: .failed) ?? [:]
            moved = try c.decodeIfPresent([String: Moved].self, forKey: .moved) ?? [:]
            oneOff = try c.decodeIfPresent([String: OneOff].self, forKey: .oneOff) ?? [:]
            notified = try c.decodeIfPresent([String: String].self, forKey: .notified) ?? [:]
            moves = try c.decodeIfPresent([Date].self, forKey: .moves) ?? []
            version = try c.decodeIfPresent(Int.self, forKey: .version)
            answered = try c.decodeIfPresent([String: Answered].self, forKey: .answered) ?? [:]
            answers = try c.decodeIfPresent([String: [Date]].self, forKey: .answers) ?? [:]
            answerFailed = try c.decodeIfPresent([String: Failed].self, forKey: .answerFailed) ?? [:]
            asked = try c.decodeIfPresent([String: String].self, forKey: .asked) ?? [:]
        }
    }

    /// The menu's view of every session. Read and written on the main queue.
    private(set) var sessions: [SessionInfo] = []
    /// Called on the main queue when `sessions` changes.
    var onStatusChanged: (() -> Void)?
    /// Called on the main queue at a reset a session waits for, so usage is fetched again.
    var onWantsRefresh: (() -> Void)?

    private let queue = DispatchQueue(label: "fr.fraserv.llmusagebar.keep-going")
    private var running: [String: Running] = [:]
    private var config: AppConfig?
    private var wakeTimer: DispatchSourceTimer?
    private var wakeAt: Date?
    private var pollTimer: DispatchSourceTimer?
    private var endCache: [String: (modified: Date, marker: String?, question: Question?)] = [:]
    private let storeURL = Paths.shared.appSupport.appendingPathComponent("keep_going.json")

    /// A limit counts as used up past this, so nothing is moved onto an account that's
    /// about to run out too.
    static let fullAt = 90.0
    /// More moves than this in 12 hours means something is wrong; moving pauses.
    static let maxMoves = 8
    /// How far back the menu lists sessions.
    static let listedFor: TimeInterval = 3 * 3600
    /// A transcript that changed this recently is a session at work.
    static let workingFor: TimeInterval = 120
    /// A session gets at most this many answers an hour, in case it keeps asking.
    static let maxAnswers = 3
    /// A question counts once it's been open this long: you may be answering it already.
    static let questionSettles: TimeInterval = 60

    // MARK: Choices

    func setOverride(_ override: Override, for key: String) {
        queue.async {
            var store = self.load()
            store.overrides[key] = override.isEmpty ? nil : override
            self.save(store)
            self.evaluateNow()
        }
    }

    /// A plan picked from the 90% notification; the session's target and message stay.
    func setPlan(_ plan: Plan, for key: String) {
        queue.async {
            var store = self.load()
            var override = store.overrides[key] ?? Override()
            override.plan = plan
            store.overrides[key] = override
            self.save(store)
            self.evaluateNow()
        }
    }

    /// A notification's button: this limit only.
    func choose(_ plan: Plan, forThisLimitOf key: String) {
        queue.async {
            var store = self.load()
            guard let marker = store.notified[key] else { return }
            store.oneOff[key] = Store.OneOff(marker: marker, plan: plan)
            self.save(store)
            ActivityLog.shared.info("Continue after limits", plan == .leave ? "Won't continue \(key) at this limit." : "Moving \(key) now.")
            self.evaluateNow()
        }
    }

    /// "Try again" after a failure, or "Continue now" for a limit reached before this
    /// was turned on.
    func retry(_ key: String) {
        queue.async {
            var store = self.load()
            // A session moved to ChatGPT: its button opens it there.
            if let moved = store.moved[key], let thread = moved.thread, store.handled[key] != nil, store.failed[key] == nil,
               let target = self.config?.profiles.first(where: { $0.id == moved.to }) {
                MainThread.async { CodexSessionTransfer.openThread(thread, in: target) }
                return
            }
            // An answer that didn't go through: you clicked, so you're here; send it now.
            if store.answerFailed[key] != nil {
                let how = store.answered[key]?.how ?? self.config?.defaultAnswer ?? .decide
                store.answerFailed[key] = nil
                store.answered[key] = nil
                self.save(store)
                self.answer(key, how: how)
                return
            }
            store.failed[key] = nil
            store.handled[key] = nil
            store.before[key] = nil
            self.save(store)
            self.evaluateNow()
        }
    }

    /// "Answer now" in the menu or a notification: sends the answer without waiting for
    /// you to be away.
    func answerNow(_ key: String, how: Answer) {
        queue.async { self.answer(key, how: how) }
    }

    private func answer(_ key: String, how: Answer) {
        guard let config, running[key] == nil,
              let item = observe(config: config, store: load()).first(where: { $0.key == key }),
              let question = item.question, question.kind != .plan,
              let profile = config.profiles.first(where: { $0.id == item.profileID }) else { return }
        var store = load()
        store.answered[key] = Store.Answered(marker: question.marker, how: how, at: Date())
        store.answers[key, default: []].append(Date())
        store.answerFailed[key] = nil
        save(store)
        start(item, on: profile, moved: false, message: config.answerMessage(how), config: config, answering: how)
        evaluateNow()
    }

    /// Turning it on only covers limits reached from then on. Turning it off stops
    /// everything planned; each session's own choices are kept for next time.
    func setEnabled(_ enabled: Bool, config: AppConfig) {
        queue.async {
            self.config = config
            var store = self.load()
            if enabled {
                for item in self.observe(config: config, store: store) {
                    if let marker = item.limitMarker { store.before[item.key] = marker }
                }
                for (key, marker) in self.codexLimits(config: config) { store.handled[key] = marker }
            }
            store.oneOff = [:]
            self.save(store)
            self.schedulePolling(enabled || config.answersWhenAway)
            self.evaluateNow()
        }
    }

    /// Opens the session in its account's Claude window, starting the window if needed.
    func open(_ key: String) {
        queue.async {
            guard let config = self.config,
                  let item = self.observe(config: config, store: self.load()).first(where: { $0.key == key }),
                  let profile = config.profiles.first(where: { $0.id == item.profileID }),
                  let link = URL(string: "claude://code/continue?session=\(item.localID)") else { return }
            MainThread.async {
                if let app = RunningProfileDetector.runningApplication(for: profile) {
                    _ = ClaudeLinkRouter.deliver(link, to: app.processIdentifier)
                    app.activate()
                } else {
                    try? Launcher.launch(profile)
                }
            }
        }
    }

    // MARK: Evaluating

    /// Runs after each refresh and whenever the menu opens.
    func evaluate(config: AppConfig) {
        queue.async {
            self.config = config
            self.schedulePolling(config.keepsWorkGoing || config.answersWhenAway)
            self.evaluateNow()
        }
    }

    private func evaluateNow() {
        guard let config else { return }
        var store = load()
        let observed = observe(config: config, store: store)
        if store.version == nil {
            for item in observed { if let marker = item.limitMarker { store.before[item.key] = marker } }
            store.version = 2
        }
        let assessment = Self.assess(observed, config: config, store: &store, running: running, now: Date(), presence: .now())

        for action in assessment.actions {
            switch action {
            case let .send(key, to, moved, message):
                guard let item = observed.first(where: { $0.key == key }),
                      let target = config.profiles.first(where: { $0.id == to }) else { continue }
                if moved { store.moves.append(Date()) }
                start(item, on: target, moved: moved, message: message, config: config)
            case let .notifyLimit(key, title, body, canMove, canLeave):
                UsageNotifier.shared.postLimitReached(key: key, title: title, body: body, canMove: canMove, canLeave: canLeave)
            case let .answer(key, to, how, message):
                guard let item = observed.first(where: { $0.key == key }),
                      let target = config.profiles.first(where: { $0.id == to }) else { continue }
                start(item, on: target, moved: false, message: message, config: config, answering: how)
            case let .notifyQuestion(key, title, body, canAnswer):
                UsageNotifier.shared.postQuestion(key: key, title: title, body: body, canAnswer: canAnswer)
            }
        }
        if Self.moveCount(store.moves, now: Date()) >= Self.maxMoves, store.notified["cap"] == nil {
            store.notified["cap"] = "1"
            ActivityLog.shared.error("Continue after limits", "Moving paused: \(Self.maxMoves) moves in 12 hours is more than a night should need.")
        } else if Self.moveCount(store.moves, now: Date()) < Self.maxMoves {
            store.notified["cap"] = nil
        }
        if config.keepsWorkGoing { continueCodex(config: config, store: &store) }
        save(store)
        scheduleWake(assessment.wakeAt)

        let sessions = assessment.sessions
        MainThread.async {
            guard sessions != self.sessions else { return }
            self.sessions = sessions
            self.onStatusChanged?()
        }
    }

    /// What the menu would show and what would be done right now, without doing any of
    /// it or saving anything: `--continue-dry-run`.
    func dryRun(config: AppConfig) -> String {
        var store = load()
        let observed = observe(config: config, store: store)
        let presence = Presence.now()
        let assessment = Self.assess(observed, config: config, store: &store, running: [:], now: Date(), presence: presence)
        var lines = ["Continue after limits is \(config.keepsWorkGoing ? "on" : "off"). Default: \(config.continuePlan), “\(config.continueMessage)”.",
                     "Answer for me when I'm away is \(config.answersWhenAway ? "on" : "off"): \(config.defaultAnswer.title) after \(config.awayAfter) min. You've been idle \(Int(presence.idle)) s\(presence.locked ? ", screen locked" : "").", ""]
        for info in assessment.sessions {
            lines.append("[\(info.state.label)] \(info.title) · \(info.accountName)\(info.movedNote.map { " · " + $0 } ?? "")")
            if let question = info.question { lines.append("    asks: “\(question.text)”\(question.options.isEmpty ? "" : " (" + question.options.joined(separator: " · ") + ")")") }
            lines.append("    \(info.planText)\(info.marker.map { " · " + $0 } ?? "")\(info.action.map { "  [\($0)]" } ?? "")")
        }
        if assessment.sessions.isEmpty { lines.append("No Claude Code sessions in the last 3 hours.") }
        for action in assessment.actions {
            switch action {
            case let .send(key, to, moved, message): lines.append("would send “\(message)” for \(key) in \(to)'s window\(moved ? " after moving it" : "")")
            case let .notifyLimit(_, title, body, _, _): lines.append("would notify: \(title). \(body)")
            case let .answer(key, to, how, message): lines.append("would answer \(key) in \(to)'s window (\(how.title)): “\(message)”")
            case let .notifyQuestion(_, title, body, _): lines.append("would notify: \(title). \(body)")
            }
        }
        if let wake = assessment.wakeAt { lines.append("would wake at \(wake)") }
        return lines.joined(separator: "\n")
    }

    // MARK: Deciding (pure, so the harness can run every situation)

    static func assess(_ observed: [Observed], config: AppConfig, store: inout Store, running: [String: Running], now: Date, presence: Presence = .here) -> Assessment {
        let enabled = config.keepsWorkGoing
        let answering = config.answersWhenAway
        let awayAfter = config.awayAfter
        let defaultPlan = config.continuePlan
        let defaultMessage = config.continueMessage
        let claude = config.relayRing.filter { $0.provider == .claude && $0.isPendingLogin != true }
        // ChatGPT accounts can be picked for one session, never chosen automatically:
        // there LLMCodeBar can open the session but not type in it.
        let chatGPT = config.profiles.filter { $0.provider == .codex && $0.isPendingLogin != true }
        let byID = Dictionary(config.profiles.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let paused = moveCount(store.moves, now: now) >= maxMoves

        var infos: [SessionInfo] = []
        var actions: [Action] = []
        var wake: Date?

        for item in observed {
            guard let profile = byID[item.profileID] else { continue }
            let override = store.overrides[item.key] ?? Override()
            let marker = item.limitMarker
            var plan = override.plan ?? defaultPlan
            if let marker, let oneOff = store.oneOff[item.key], oneOff.marker == marker { plan = oneOff.plan }
            let message = override.message ?? defaultMessage
            let isCustom = !override.isEmpty
            let says = message == "continue" ? "" : " · says “\(message)”"
            let name = shortName(profile)
            let others = claude.filter { $0.id != profile.id }
            let targets = (others + chatGPT).map { other -> SessionInfo.Target in
                let room = roomInfo(other, now: now)
                let used = Int((other.usage?.windows.filter(\.isPrimary).map(\.usedPercent).max() ?? 0).rounded())
                let text = room.hasRoom ? "\(used)% used · has room" : room.backAt.map { "full until \(clock($0, now: now))" } ?? "no usage yet"
                return SessionInfo.Target(id: other.id, name: shortName(other), plan: other.usage?.accountPlan ?? other.accountPlan ?? "", room: text, hasRoom: room.hasRoom, appPath: other.appPath, isChatGPT: other.provider == .codex)
            }
            var info = SessionInfo(
                key: item.key, title: item.title, accountID: profile.id, accountName: name, accountAppPath: profile.appPath,
                movedNote: store.moved[item.key].flatMap { moved in
                    guard moved.to == profile.id, now.timeIntervalSince(moved.at) < 24 * 3600 else { return nil }
                    return "moved from \(byID[moved.from].map(shortName) ?? "another account") at \(clock(moved.at, now: now))"
                },
                state: now.timeIntervalSince(item.modified) < workingFor ? .working : .idle,
                planText: "", planIcon: .here, planTone: .normal, marker: isCustom ? "custom" : "default",
                plan: plan, chosenTarget: override.target, targets: targets, message: message, isCustom: isCustom, action: nil)

            // Where a move goes: the chosen account if it has room, else the next one in
            // the ring after this session's own.
            let ringAfter: [LaunchProfile] = {
                guard let index = claude.firstIndex(where: { $0.id == profile.id }) else { return others }
                return Array(claude[(index + 1)...] + claude[..<index])
            }()
            var candidates = ringAfter
            if let chosen = override.target, let picked = candidates.firstIndex(where: { $0.id == chosen }) {
                candidates.insert(candidates.remove(at: picked), at: 0)
            } else if let chosen = override.target, let gpt = chatGPT.first(where: { $0.id == chosen }) {
                candidates.insert(gpt, at: 0)
            }
            let roomy = candidates.first { roomInfo($0, now: now).hasRoom }

            func describeAhead() {
                switch plan {
                case .continueHere:
                    (info.planIcon, info.planText) = (.here, "At its limit: continues here after the reset\(says)")
                case .move:
                    if paused {
                        (info.planIcon, info.planText) = (.move, "At its limit: moving is paused, continues here after the reset\(says)")
                    } else if let roomy {
                        let chosenFull = override.target != nil && override.target != roomy.id
                        (info.planIcon, info.planText) = (.move, "At its limit: moves to \(place(roomy))\(chosenFull ? " (yours is full)" : "")\(roomy.provider == .codex ? ", where you send “\(message)”" : says)")
                    } else if let (first, back) = candidates.compactMap({ account in roomInfo(account, now: now).backAt.map { (account, $0) } }).min(by: { $0.1 < $1.1 }) {
                        (info.planIcon, info.planText) = (.move, "At its limit: moves to \(place(first)), back at \(clock(back, now: now))\(says)")
                    } else {
                        (info.planIcon, info.planText) = (.move, "At its limit: moves to the first account back\(says)")
                    }
                case .leave:
                    (info.planIcon, info.planText, info.planTone) = (.leave, "At its limit: left as it is", .muted)
                }
            }

            describeAhead()
            info.limitSummary = enabled ? info.planText : "At its limit: nothing happens while “Continue after limits” is off"
            info.planText = ""
            info.planIcon = .here
            info.planTone = .normal
            info.answer = override.answer ?? config.defaultAnswer
            let customAnswer = override.answer != nil

            // An answer on its way.
            if let run = running[item.key], let how = run.answering {
                (info.state, info.planIcon, info.planText, info.marker) = (.sending, how.icon, "Answering in \(name)'s window: “\(how.title)”…", nil)
                infos.append(info)
                continue
            }

            // Waiting on you.
            if let question = item.question, running[item.key] == nil {
                info.question = question
                info.marker = nil
                let settled = now.timeIntervalSince(question.askedAt) >= questionSettles
                if question.kind == .plan {
                    (info.state, info.planIcon, info.planText, info.planTone) = (.waitingForYou, .lock, "Its plan waits for your approval. Never answered for you", .muted)
                    if answering, settled, store.asked[item.key] != question.marker {
                        store.asked[item.key] = question.marker
                        actions.append(.notifyQuestion(key: item.key, title: "“\(item.title)” waits for you", body: "Its plan is ready for you to approve, on \(name).", canAnswer: false))
                    }
                    infos.append(info)
                    continue
                }
                info.state = .askingYou
                info.canAnswerNow = true
                let how = info.answer
                let recent = (store.answers[item.key] ?? []).filter { $0 > now.addingTimeInterval(-3600) }
                var answerNow = false
                if let failed = store.answerFailed[item.key], failed.marker == question.marker {
                    (info.state, info.planIcon, info.planText, info.planTone, info.action) = (.needsYou, .warning, failed.reason, .alert, "Try again")
                } else if store.answered[item.key]?.marker == question.marker {
                    (info.planIcon, info.planText, info.planTone) = (.none, "Answered, waiting for it to show", .muted)
                } else if !answering {
                    (info.planIcon, info.planText, info.planTone) = (.wait, "Waits for you · answering for you is off", .muted)
                } else if question.kind == .text && !config.answersTextQuestions {
                    (info.planIcon, info.planText, info.planTone) = (.wait, "Shown only: turns that end on a question aren't answered (Settings)", .muted)
                } else if how == .wait {
                    (info.planIcon, info.planText, info.marker) = (.wait, "Waits for you · you get a notification", customAnswer ? "custom" : "default")
                } else if recent.count >= maxAnswers {
                    (info.planIcon, info.planText) = (.wait, "Answered \(maxAnswers) times this hour, so this one waits for you")
                } else if settled && presence.isAway(after: awayAfter) {
                    answerNow = true
                } else {
                    let idleMinutes = Int(presence.idle / 60)
                    info.planIcon = how.icon
                    info.planText = idleMinutes >= 1
                        ? "If you stay away \(max(1, awayAfter - idleMinutes)) more min: \(how.title)"
                        : "If you're away \(awayAfter) min: \(how.title)"
                    info.marker = customAnswer ? "custom" : "default"
                }
                if answerNow {
                    store.answered[item.key] = Store.Answered(marker: question.marker, how: how, at: now)
                    store.answers[item.key] = recent + [now]
                    actions.append(.answer(key: item.key, to: profile.id, how: how, message: config.answerMessage(how)))
                    (info.state, info.planIcon, info.planText) = (.sending, how.icon, "You're away · answering in \(name)'s window: “\(how.title)”…")
                } else if answering, settled, store.asked[item.key] != question.marker, store.answered[item.key]?.marker != question.marker {
                    store.asked[item.key] = question.marker
                    actions.append(.notifyQuestion(key: item.key, title: "“\(item.title)” is asking you", body: "\(question.text) · \(name)", canAnswer: info.state == .askingYou))
                }
                infos.append(info)
                continue
            }

            // Answered a while ago: its line says so for an hour, until it stops again.
            let answeredNote: String? = store.answered[item.key].flatMap { done in
                guard item.limitMarker == nil, now.timeIntervalSince(done.at) < 3600 else { return nil }
                return "Answered at \(clock(done.at, now: now)): \(done.how.title)"
            }

            if !enabled {
                (info.state, info.planIcon, info.planText, info.planTone, info.marker) = (.off, .none, "Nothing happens while this is off", .muted, nil)
                if let answeredNote, let how = store.answered[item.key]?.how {
                    info.state = now.timeIntervalSince(item.modified) < workingFor ? .working : .idle
                    (info.planIcon, info.planText, info.planTone) = (how.icon, answeredNote, .normal)
                }
                infos.append(info)
                continue
            }

            if let run = running[item.key] {
                let target = byID[run.to].map(shortName) ?? "another account"
                if run.moving, let gpt = byID[run.to], gpt.provider == .codex {
                    (info.state, info.planIcon, info.planText) = (.moving, .move, "Opening it in \(place(gpt))…")
                } else if run.moving {
                    (info.state, info.planIcon, info.planText) = (.moving, .move, "Opening it on \(target), sending “\(message)”…")
                } else {
                    (info.state, info.planIcon, info.planText) = (.sending, .here, "Sending “\(message)” in \(target)'s window…")
                }
                info.marker = nil
                infos.append(info)
                continue
            }

            guard let marker else {
                describeAhead()
                if let answeredNote, let how = store.answered[item.key]?.how {
                    (info.planIcon, info.planText, info.planTone, info.marker) = (how.icon, answeredNote, .normal, nil)
                }
                infos.append(info)
                continue
            }

            // At its limit.
            if let failed = store.failed[item.key], failed.marker == marker {
                (info.state, info.planIcon, info.planText, info.planTone, info.marker, info.action) = (.needsYou, .warning, failed.reason, .alert, nil, "Try again")
                infos.append(info)
                continue
            }
            if store.before[item.key] == marker {
                (info.state, info.planIcon, info.planText, info.planTone, info.marker, info.action) = (.idle, .none, "Reached its limit before this was on", .muted, nil, "Continue now")
                infos.append(info)
                continue
            }
            if store.handled[item.key] == marker, let moved = store.moved[item.key], moved.thread != nil, let gpt = byID[moved.to] {
                (info.state, info.planIcon, info.planText, info.planTone, info.marker, info.action) =
                    (.needsYou, .move, "Moved to \(place(gpt)) at \(clock(moved.at, now: now)) · send “\(message)” there", .normal, nil, "Open in ChatGPT")
                infos.append(info)
                continue
            }
            if store.handled[item.key] == marker {
                (info.state, info.planIcon, info.planText, info.planTone, info.marker) = (.idle, .none, "Sent “\(message)”, waiting for it to show", .muted, nil)
                infos.append(info)
                continue
            }

            let here = roomInfo(profile, now: now)
            var limitBody = ""
            var canMove = false
            switch plan {
            case .leave:
                (info.state, info.planIcon, info.planText, info.planTone) = (.idle, .leave, "Reached its limit · left as it is", .muted)
                limitBody = "Left as it is, as you chose."

            case .continueHere:
                if here.hasRoom {
                    store.handled[item.key] = marker
                    actions.append(.send(key: item.key, to: profile.id, moved: false, message: message))
                    (info.state, info.planIcon, info.planText, info.marker) = (.sending, .here, "Sending “\(message)” in \(name)'s window…", nil)
                } else {
                    let back = here.backAt
                    wake = earliest(wake, back)
                    info.state = .waitingForReset
                    info.planIcon = .here
                    info.planText = back.map { "Continues here at \(clock($0, now: now)) · \(relative($0))\(says)" } ?? "Continues here after the reset\(says)"
                    limitBody = back.map { "It continues here at \(clock($0, now: now)), \(relative($0)), with “\(message)”." } ?? "It continues here after the reset, with “\(message)”."
                    canMove = roomy != nil && !paused
                }

            case .move:
                if paused {
                    (info.state, info.planIcon, info.planText, info.planTone, info.marker) = (.needsYou, .warning, "Moving paused after \(maxMoves) moves in 12 hours", .alert, nil)
                    limitBody = "Moving is paused after \(maxMoves) moves in 12 hours. Pick “continue here” for it in the menu."
                } else if let roomy {
                    store.handled[item.key] = marker
                    actions.append(.send(key: item.key, to: roomy.id, moved: true, message: message))
                    (info.state, info.planIcon, info.planText, info.marker) = (.moving, .move, roomy.provider == .codex ? "Opening it in \(place(roomy))…" : "Opening it on \(shortName(roomy)), sending “\(message)”…", nil)
                } else if here.hasRoom {
                    // Its own account came back first.
                    store.handled[item.key] = marker
                    actions.append(.send(key: item.key, to: profile.id, moved: false, message: message))
                    (info.state, info.planIcon, info.planText, info.marker) = (.sending, .here, "Sending “\(message)” in \(name)'s window…", nil)
                } else {
                    let first = ([profile] + candidates)
                        .compactMap { account in roomInfo(account, now: now).backAt.map { (account, $0) } }
                        .min { $0.1 < $1.1 }
                    wake = earliest(wake, first?.1)
                    info.state = .waitingForReset
                    info.planIcon = .move
                    if let (account, back) = first {
                        let place = account.id == profile.id ? "here" : account.provider == .codex ? "in \(Self.place(account))" : "on \(shortName(account))"
                        info.planText = "No account has room · continues \(place) at \(clock(back, now: now))\(says)"
                        limitBody = "No account has room. It continues \(place) at \(clock(back, now: now)), \(relative(back))."
                    } else {
                        info.planText = "No account has room · continues at the first reset\(says)"
                        limitBody = "No account has room. It continues at the first reset."
                    }
                }
            }

            if !limitBody.isEmpty, store.notified[item.key] != marker {
                store.notified[item.key] = marker
                actions.append(.notifyLimit(key: item.key, title: "“\(item.title)” reached its limit on \(name)", body: limitBody, canMove: canMove, canLeave: plan != .leave))
            }
            infos.append(info)
        }

        // Sessions that need something first, then the ones at work, then the rest.
        let rank: [SessionInfo.State: Int] = [.askingYou: 0, .needsYou: 0, .waitingForYou: 1, .moving: 1, .sending: 1, .waitingForReset: 2, .working: 3, .idle: 4, .off: 4]
        let order = Dictionary(observed.enumerated().map { ($1.key, $0) }, uniquingKeysWith: { first, _ in first })
        infos.sort { (rank[$0.state] ?? 9, order[$0.key] ?? 0) < (rank[$1.state] ?? 9, order[$1.key] ?? 0) }
        return Assessment(sessions: infos, actions: actions, wakeAt: wake)
    }

    /// Whether an account can take work now, and when it's back if not. A limit whose
    /// reset time has passed counts as reset, even before the next refresh says so.
    static func roomInfo(_ profile: LaunchProfile, now: Date) -> (hasRoom: Bool, backAt: Date?) {
        guard profile.isPendingLogin != true, let windows = profile.usage?.windows, !windows.isEmpty else { return (false, nil) }
        if profile.provider == .claude && profile.identityVerified != true { return (false, nil) }
        let full = windows.filter { $0.isPrimary && $0.usedPercent >= fullAt && ($0.resetsAt.map { $0 > now } ?? true) }
        if full.isEmpty { return (profile.usageStale != true, nil) }
        return (false, full.compactMap(\.resetsAt).max())
    }

    /// Where a session goes, as the lines say it: "franciskid95", "franciskid97's ChatGPT".
    static func place(_ profile: LaunchProfile) -> String {
        profile.provider == .codex ? "\(shortName(profile))'s ChatGPT" : shortName(profile)
    }

    /// The part of the address before the @, as the cards show it.
    static func shortName(_ profile: LaunchProfile) -> String {
        let title = ProfileFormatting.title(for: profile)
        return profile.accountEmail == nil ? title : String(title.split(separator: "@").first ?? Substring(title))
    }

    static func clock(_ date: Date, now: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        // Within the next 20 hours a time can't be mistaken for another day's; past
        // that, or in the past, it says the day.
        let soon = date > now.addingTimeInterval(-20 * 3600) && date < now.addingTimeInterval(20 * 3600)
        formatter.dateFormat = soon || Calendar.current.isDate(date, inSameDayAs: now) ? "HH:mm" : "EEE HH:mm"
        return formatter.string(from: date)
    }

    /// "in 49 min", "in 3h 10m", "tomorrow", "in 2 days".
    static func relative(_ date: Date) -> String {
        let hours = date.timeIntervalSinceNow / 3600
        if hours < 24 { return ProfileFormatting.backIn(date) }
        let days = Calendar.current.dateComponents([.day], from: Calendar.current.startOfDay(for: Date()), to: Calendar.current.startOfDay(for: date)).day ?? 2
        return days <= 1 ? "tomorrow" : "in \(days) days"
    }

    private static func earliest(_ a: Date?, _ b: Date?) -> Date? {
        switch (a, b) {
        case let (a?, b?): return min(a, b)
        default: return a ?? b
        }
    }

    static func moveCount(_ moves: [Date], now: Date) -> Int {
        moves.filter { $0 > now.addingTimeInterval(-12 * 3600) }.count
    }

    // MARK: Timers

    /// Wakes at the reset a session is waiting for (plus a few seconds for the server),
    /// fetching usage again and continuing it.
    private func scheduleWake(_ date: Date?) {
        guard date != wakeAt else { return }
        wakeTimer?.cancel()
        wakeTimer = nil
        wakeAt = date
        guard let date else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + max(1, date.timeIntervalSinceNow + 20))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.wakeAt = nil
            MainThread.async { self.onWantsRefresh?() }
            self.evaluateNow()
        }
        timer.resume()
        wakeTimer = timer
    }

    /// Looks at the transcripts every 30 seconds while this is on, so a limit is seen
    /// when it happens rather than at the next refresh.
    private func schedulePolling(_ on: Bool) {
        if !on {
            pollTimer?.cancel()
            pollTimer = nil
            return
        }
        guard pollTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 30, repeating: 30)
        timer.setEventHandler { [weak self] in self?.evaluateNow() }
        timer.resume()
        pollTimer = timer
    }

    // MARK: Finding sessions

    /// The Claude Code sessions of the last few hours, and older ones still at a limit,
    /// one per transcript: a session handed between accounts belongs to the one it moved
    /// to last.
    private func observe(config: AppConfig, store: Store) -> [Observed] {
        let now = Date()
        var found: [String: (Observed, Date)] = [:]

        for profile in config.profiles where profile.provider == .claude && profile.identityVerified == true {
            for session in CodeSessionTransfer.sessions(for: profile, orgID: profile.organizationUUID, limit: 25) {
                guard let transcript = session.transcriptURL,
                      let modified = (try? transcript.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
                      now.timeIntervalSince(modified) < 36 * 3600 else { continue }
                let (marker, question) = endOf(transcript, modified: modified)
                guard now.timeIntervalSince(modified) < Self.listedFor || marker != nil else { continue }
                let metadata = (try? Data(contentsOf: session.fileURL))
                    .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
                let cliSessionID = metadata["cliSessionId"] as? String
                let key = "code:\(cliSessionID ?? session.id)"
                let item = Observed(key: key, title: session.displayTitle, profileID: profile.id, localID: session.id,
                                    cliSessionID: cliSessionID, modified: modified, limitMarker: marker, question: question)
                let activity = session.lastActivityAt ?? .distantPast
                if let existing = found[key] {
                    let movedHere = store.moved[key]?.to == profile.id
                    let movedThere = store.moved[key]?.to == existing.0.profileID
                    if movedThere || (!movedHere && existing.1 >= activity) { continue }
                }
                found[key] = (item, activity)
            }
        }
        return found.values.map(\.0).sorted { $0.modified > $1.modified }.prefix(8).map { $0 }
    }

    /// How a transcript ends: at a limit (the limit line's uuid), or waiting on you.
    private func endOf(_ transcript: URL, modified: Date) -> (String?, Question?) {
        if let cached = endCache[transcript.path], cached.modified == modified { return (cached.marker, cached.question) }
        let lines = Self.conversationTail(of: transcript)
        let line = lines.last
        let marker = line?["type"] as? String == "assistant" && line?["error"] as? String == "rate_limit" ? line?["uuid"] as? String : nil
        let question = marker == nil ? Self.pendingQuestion(in: lines) : nil
        endCache[transcript.path] = (modified, marker, question)
        return (marker, question)
    }

    /// The user and assistant lines at the end of a transcript, oldest first, without
    /// the ones from subagents.
    static func conversationTail(of url: URL) -> [[String: Any]] {
        tailLines(of: url).compactMap { line in
            guard let json = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let type = json["type"] as? String, type == "user" || type == "assistant",
                  json["isSidechain"] as? Bool != true else { return nil }
            return json
        }
    }

    /// What a session is waiting on you for, from the end of its transcript: a question
    /// card nobody answered, a plan to approve, the next-step box's question, or a turn
    /// that ended on a "?". Nil when it's working, done, or you spoke last.
    static func pendingQuestion(in lines: [[String: Any]]) -> Question? {
        guard let last = lines.last, last["type"] as? String == "assistant", last["error"] == nil,
              last["isApiErrorMessage"] as? Bool != true,
              let message = last["message"] as? [String: Any],
              let content = message["content"] as? [[String: Any]] else { return nil }
        let marker = last["uuid"] as? String ?? ""
        let askedAt = (last["timestamp"] as? String).flatMap(parseTimestamp) ?? .distantPast

        if let use = content.last(where: { $0["type"] as? String == "tool_use" }) {
            let input = use["input"] as? [String: Any] ?? [:]
            switch use["name"] as? String {
            case "AskUserQuestion":
                let questions = input["questions"] as? [[String: Any]] ?? []
                guard let first = questions.first, let text = first["question"] as? String else { return nil }
                let options = (first["options"] as? [[String: Any]] ?? []).compactMap { $0["label"] as? String }
                let more = questions.count > 1 ? " (and \(questions.count - 1) more)" : ""
                return Question(kind: .card, text: text + more, options: options, marker: marker, askedAt: askedAt)
            case "ExitPlanMode":
                let title = (input["plan"] as? String ?? "").split(separator: "\n")
                    .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "#*").union(.whitespaces)) }
                    .first { !$0.isEmpty }
                return Question(kind: .plan, text: "Plan: \(title.map { String($0.prefix(120)) } ?? "ready")", marker: marker, askedAt: askedAt)
            default:
                return nil
            }
        }

        // The turn is over. Did it end by asking you something?
        guard message["stop_reason"] as? String == "end_turn" else { return nil }
        for line in lines.reversed() {
            let blocks = (line["message"] as? [String: Any])?["content"]
            if line["type"] as? String == "user" {
                // Back to the last thing you said: that's where this turn started.
                if blocks is String { break }
                if let blocks = blocks as? [[String: Any]], blocks.contains(where: { $0["type"] as? String == "text" }) { break }
                continue
            }
            for block in blocks as? [[String: Any]] ?? [] where block["type"] as? String == "tool_use" {
                guard (block["name"] as? String)?.hasSuffix("wrap_up") == true,
                      let input = block["input"] as? [String: Any],
                      let ask = (input["ask"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !ask.isEmpty else { continue }
                let options = (input["actions"] as? [[String: Any]] ?? []).compactMap { $0["label"] as? String }
                return Question(kind: .nextStep, text: ask, options: options, marker: marker, askedAt: askedAt)
            }
        }
        let text = content.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined(separator: "\n")
        return endingQuestion(text).map { Question(kind: .text, text: $0, marker: marker, askedAt: askedAt) }
    }

    /// The last sentence of a message, when the message ends on a question.
    static func endingQuestion(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: CharacterSet(charactersIn: "*_`) ").union(.whitespacesAndNewlines))
        guard trimmed.hasSuffix("?") else { return nil }
        let paragraph = trimmed.components(separatedBy: "\n").last { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? trimmed
        var sentence = Substring(paragraph)
        for separator in [". ", "! ", ": ", "? "] {
            let body = sentence.dropLast()
            if let range = body.range(of: separator, options: .backwards) { sentence = sentence[range.upperBound...] }
        }
        let clean = sentence.trimmingCharacters(in: CharacterSet(charactersIn: "*_`#-> ").union(.whitespaces))
        return clean.isEmpty ? nil : String(clean.prefix(200))
    }

    private static func parseTimestamp(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }

    /// The session being worked on in an account right now (active in the last ten
    /// minutes), so the 90% notification can ask about it before its limit.
    static func activeSession(on profile: LaunchProfile) -> (key: String, title: String)? {
        let recent = Date().addingTimeInterval(-10 * 60)
        guard profile.provider == .claude,
              let session = CodeSessionTransfer.sessions(for: profile, orgID: profile.organizationUUID, limit: 3)
                .first(where: { ($0.lastActivityAt ?? .distantPast) > recent }) else { return nil }
        let metadata = (try? Data(contentsOf: session.fileURL))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        return ("code:\(metadata["cliSessionId"] as? String ?? session.id)", session.displayTitle)
    }

    /// The last user or assistant line of a Claude Code transcript, read from its end.
    static func lastConversationLine(in url: URL) -> [String: Any]? {
        for line in tailLines(of: url).reversed() {
            guard let json = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let type = json["type"] as? String, type == "user" || type == "assistant" else { continue }
            return json
        }
        return nil
    }

    private static func tailLines(of url: URL, bytes: UInt64 = 512 * 1024) -> [String] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let start = size > bytes ? size - bytes : 0
        try? handle.seek(toOffset: start)
        let data = (try? handle.readToEnd()) ?? Data()
        var lines = String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init)
        if start > 0, !lines.isEmpty { lines.removeFirst() } // cut mid-line
        return lines
    }

    // MARK: Codex

    private func codexLimits(config: AppConfig) -> [(String, String)] {
        let recent = Date().addingTimeInterval(-36 * 3600)
        return config.profiles.filter { $0.provider == .codex }.flatMap { profile in
            CodexSessionTransfer.recentRollouts(for: profile, since: recent).compactMap { thread in
                Self.codexLimitStop(in: thread.rollout).map { ("codex:\(thread.id)", $0) }
            }
        }
    }

    /// Codex has no window LLMCodeBar can type into, and running the turn out of sight
    /// is exactly what this mustn't do. So it only says when a thread can carry on.
    private func continueCodex(config: AppConfig, store: inout Store) {
        let recent = Date().addingTimeInterval(-36 * 3600)
        for profile in config.profiles where profile.provider == .codex && Self.roomInfo(profile, now: Date()).hasRoom {
            for thread in CodexSessionTransfer.recentRollouts(for: profile, since: recent) {
                let key = "codex:\(thread.id)"
                guard let marker = Self.codexLimitStop(in: thread.rollout), store.handled[key] != marker else { continue }
                store.handled[key] = marker
                UsageNotifier.shared.postKeepGoing(
                    title: "“\(thread.title)” can carry on",
                    body: "\(ProfileFormatting.title(for: profile)) has room again. Open it in ChatGPT and send “continue”.")
            }
        }
    }

    /// The failed turn's id when a Codex thread's last turn stopped at the usage limit.
    static func codexLimitStop(in rollout: URL) -> String? {
        for line in tailLines(of: rollout).reversed() {
            guard let json = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  json["type"] as? String == "event_msg",
                  let payload = json["payload"] as? [String: Any] else { continue }
            switch payload["type"] as? String {
            case "task_complete":
                let error = payload["error"].flatMap { try? JSONSerialization.data(withJSONObject: $0) }.map { String(decoding: $0, as: UTF8.self) } ?? ""
                return error.contains("usage_limit_exceeded") || error.contains("usageLimitExceeded")
                    ? (payload["turn_id"] as? String ?? json["timestamp"] as? String)
                    : nil
            case "task_started", "user_message":
                return nil
            default:
                continue
            }
        }
        return nil
    }

    // MARK: Continuing

    private func start(_ item: Observed, on target: LaunchProfile, moved: Bool, message: String, config: AppConfig, answering: Answer? = nil) {
        guard let from = config.profiles.first(where: { $0.id == item.profileID }),
              let session = CodeSessionTransfer.sessions(for: from, orgID: from.organizationUUID, limit: 25).first(where: { $0.id == item.localID }) else {
            fail(item, reason: "Couldn't find the session on disk any more.", answering: answering)
            return
        }
        running[item.key] = Running(moving: moved, to: target.id, answering: answering)
        if target.provider == .codex {
            DispatchQueue.global(qos: .utility).async {
                let outcome = Result { try CodexSessionTransfer.importClaudeSession(session, into: target) }
                self.queue.async { self.finishInChatGPT(item, from: from, on: target, message: message, outcome: outcome) }
            }
            return
        }
        DispatchQueue.global(qos: .utility).async {
            let outcome = self.continueInWindow(item, session: session, from: from, on: target, moved: moved, message: message)
            self.queue.async { self.finish(item, from: from, on: target, moved: moved, message: message, failure: outcome, answering: answering) }
        }
    }

    /// Opens the session in the account's Claude window - starting that window if it's
    /// closed - and sends the message there. Nil when it arrived.
    private func continueInWindow(_ item: Observed, session: CodeSessionTransfer.Session, from: LaunchProfile, on target: LaunchProfile, moved: Bool, message: String) -> String? {
        guard let transcript = session.transcriptURL else { return "Its transcript is no longer on disk." }
        let started = Date()
        let before = Self.lastTurns(beside: transcript)

        var app = RunningProfileDetector.runningApplication(for: target)
        let link: URL?
        if moved, app != nil, let cliSessionID = item.cliSessionID {
            // A running window reads its session list once, at launch. Claude's resume
            // link makes it adopt this session now, from the transcript both share.
            link = URL(string: "claude://resume?session=\(cliSessionID)")
        } else {
            if moved {
                do {
                    try CodeSessionTransfer.transfer(session: session, to: target, destinationOrgID: target.organizationUUID)
                } catch {
                    return "Couldn't move it to \(Self.shortName(target)): \(error.localizedDescription)"
                }
            }
            if app == nil {
                MainThread.sync { try? Launcher.launch(target) }
                app = Self.waitForWindow(of: target, seconds: 90)
                Thread.sleep(forTimeInterval: 8) // it loads its sessions after the window shows
            }
            link = URL(string: "claude://code/continue?session=\(session.id)")
        }
        guard let app, let link else { return "Couldn't open \(Self.shortName(target))'s Claude window." }

        let result = ClaudeWindowMessenger.send(message, opening: link, in: app) {
            Self.hasNewTurn(beside: transcript, since: started, before: before)
        }
        switch result {
        case .success: return nil
        case let .failure(failure): return failure.shortReason
        }
    }

    private static func waitForWindow(of profile: LaunchProfile, seconds: TimeInterval) -> NSRunningApplication? {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if let app = RunningProfileDetector.runningApplication(for: profile), app.isFinishedLaunching {
                return app
            }
            Thread.sleep(forTimeInterval: 1)
        }
        return nil
    }

    /// The last conversation line of every transcript in the session's project folder.
    /// The message counts as arrived when one of them gains a turn that isn't the limit
    /// error - the session's own, or a new one if the window started a fresh file for it.
    private static func lastTurns(beside transcript: URL) -> [String: String] {
        let folder = transcript.deletingLastPathComponent()
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        var result: [String: String] = [:]
        for file in files where file.pathExtension == "jsonl" {
            result[file.lastPathComponent] = lastConversationLine(in: file)?["uuid"] as? String ?? ""
        }
        return result
    }

    private static func hasNewTurn(beside transcript: URL, since started: Date, before: [String: String]) -> Bool {
        let folder = transcript.deletingLastPathComponent()
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for file in files where file.pathExtension == "jsonl" {
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            guard modified >= started.addingTimeInterval(-1),
                  let line = lastConversationLine(in: file),
                  let uuid = line["uuid"] as? String, uuid != before[file.lastPathComponent],
                  line["error"] as? String != "rate_limit" else { continue }
            return true
        }
        return false
    }

    private func fail(_ item: Observed, reason: String, answering: Answer? = nil) {
        var store = load()
        if answering != nil, let question = item.question {
            store.answerFailed[item.key] = Store.Failed(marker: question.marker, reason: reason)
        } else if let marker = item.limitMarker {
            store.failed[item.key] = Store.Failed(marker: marker, reason: reason)
        }
        save(store)
        ActivityLog.shared.error(answering != nil ? "Answer when away" : "Continue after limits", "“\(item.title)”: \(reason)")
        UsageNotifier.shared.postNeedsYou(key: item.key, title: item.title, reason: reason)
    }

    /// Moved to ChatGPT: it's open there, and the message is yours to send, since
    /// LLMCodeBar doesn't type into ChatGPT.
    private func finishInChatGPT(_ item: Observed, from: LaunchProfile, on target: LaunchProfile, message: String, outcome: Result<String, Error>) {
        running[item.key] = nil
        switch outcome {
        case let .failure(error):
            fail(item, reason: "Couldn't move it to \(Self.place(target)): \(error.localizedDescription)")
        case let .success(thread):
            var store = load()
            store.moved[item.key] = Store.Moved(from: from.id, to: target.id, at: Date(), thread: thread)
            save(store)
            MainThread.async { CodexSessionTransfer.openThread(thread, in: target) }
            let text = "It's open in \(Self.place(target)). Send “\(message)” there: LLMCodeBar doesn't type into ChatGPT."
            ActivityLog.shared.info("Continue after limits", "“\(item.title)” moved from \(Self.shortName(from)) to \(Self.place(target)).")
            UsageNotifier.shared.postKeepGoing(title: "“\(item.title)” moved to ChatGPT", body: text)
        }
        evaluateNow()
    }

    private func finish(_ item: Observed, from: LaunchProfile, on target: LaunchProfile, moved: Bool, message: String, failure: String?, answering: Answer? = nil) {
        running[item.key] = nil
        if let failure {
            fail(item, reason: failure.replacingOccurrences(of: "Couldn't send", with: answering != nil ? "Couldn't answer" : "Couldn't send"), answering: answering)
        } else if let how = answering {
            let account = Self.shortName(target)
            let asked = item.question.map { " to “\($0.text)”" } ?? ""
            ActivityLog.shared.info("Answer when away", "“\(item.title)”: answered\(asked) in \(account)'s window with \(how.title): “\(message)”")
            UsageNotifier.shared.postKeepGoing(title: "Answered “\(item.title)”", body: "\(how.title), in \(account)'s window: “\(message)”")
        } else {
            var store = load()
            if moved { store.moved[item.key] = Store.Moved(from: from.id, to: target.id, at: Date()) }
            save(store)
            let account = Self.shortName(target)
            let text = moved
                ? "Moved from \(Self.shortName(from)) and sent “\(message)” in \(account)'s window."
                : "Sent “\(message)” in \(account)'s window."
            ActivityLog.shared.info("Continue after limits", "“\(item.title)”: \(text)")
            UsageNotifier.shared.postKeepGoing(title: moved ? "“\(item.title)” moved to \(account)" : "“\(item.title)” continued", body: text)
        }
        evaluateNow()
    }

    // MARK: Store

    private func load() -> Store {
        (try? Data(contentsOf: storeURL)).flatMap { try? JSONDecoder().decode(Store.self, from: $0) } ?? Store()
    }

    private func save(_ store: Store) {
        Paths.shared.ensureSupportDirectory()
        if let data = try? JSONEncoder().encode(store) {
            try? data.write(to: storeURL, options: .atomic)
        }
    }
}

extension ClaudeWindowMessenger.Failure {
    /// The reason in a few words, for a session's line in the menu.
    var shortReason: String {
        switch self {
        case .notTrusted: return "Couldn't send: LLMCodeBar needs Accessibility access"
        case .noWindow: return "Couldn't send: its Claude window isn't open"
        case .noReplyBox: return "Couldn't send: the session didn't open in its window"
        case .draftInTheWay: return "Couldn't send: an unsent draft is in its reply box"
        case .couldNotFill: return "Couldn't send: Claude didn't take the message"
        case .notDelivered: return "Couldn't send: the message didn't reach the session"
        }
    }
}

extension KeepGoing.Answer {
    var icon: KeepGoing.SessionInfo.Icon {
        switch self {
        case .decide: return .decide
        case .around: return .around
        case .wait: return .wait
        }
    }
}

extension AppConfig {
    /// What a session is told when it asks you and you're away, unless it has its own.
    var defaultAnswer: KeepGoing.Answer { awayAnswer.flatMap(KeepGoing.Answer.init(rawValue:)) ?? .decide }

    func answerMessage(_ answer: KeepGoing.Answer) -> String {
        let custom = (answer == .decide ? decideMessage : aroundMessage)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !custom.isEmpty { return custom }
        return answer == .decide ? KeepGoing.Answer.decideMessage : KeepGoing.Answer.aroundMessage
    }

    /// What happens to a session at its limit unless it has its own plan.
    var continuePlan: KeepGoing.Plan { keepGoingPlan.flatMap(KeepGoing.Plan.init(rawValue:)) ?? .continueHere }
    /// What's sent to continue a session.
    var continueMessage: String {
        let text = keepGoingMessage?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return text.isEmpty ? "continue" : text
    }
}

/// Gets work onto the main thread even while a menu is open. During menu tracking the
/// main dispatch queue isn't drained, so `DispatchQueue.main.async` would wait until the
/// menu closes; the main run loop's common modes include menu tracking.
enum MainThread {
    static func async(_ block: @escaping () -> Void) {
        RunLoop.main.perform(inModes: [.common], block: block)
        CFRunLoopWakeUp(CFRunLoopGetMain())
    }

    static func sync(_ block: @escaping () -> Void) {
        if Thread.isMainThread { block(); return }
        let done = DispatchSemaphore(value: 0)
        async {
            block()
            done.signal()
        }
        done.wait()
    }
}

import AppKit

// Every situation a session can be in with "Continue after limits", run through the
// same decision code the app uses (KeepGoing.assess): what its line in the menu says,
// and what LLMCodeBar does. Run with scripts/test.sh.

let now = Date()

func profile(_ id: String, email: String, five: Double, fiveReset: TimeInterval, week: Double = 30, weekReset: TimeInterval = 3 * 86400, provider: String = "Claude") -> LaunchProfile {
    let json: [String: Any] = [
        "id": id, "label": id, "provider": provider, "appPath": "/Applications/Claude.app", "dataDir": "/tmp/\(id)",
        "accountEmail": email, "identityVerified": true, "accountPlan": "Pro",
        "usage": ["source": "test", "updatedAt": now.timeIntervalSinceReferenceDate, "accountPlan": "Pro",
                  "windows": [["title": "5h", "usedPercent": five, "remainingPercent": 100 - five, "resetsAt": now.addingTimeInterval(fiveReset).timeIntervalSinceReferenceDate],
                              ["title": "Week", "usedPercent": week, "remainingPercent": 100 - week, "resetsAt": now.addingTimeInterval(weekReset).timeIntervalSinceReferenceDate]]],
    ]
    return try! JSONDecoder().decode(LaunchProfile.self, from: JSONSerialization.data(withJSONObject: json))
}

func config(_ profiles: [LaunchProfile], on: Bool = true, plan: KeepGoing.Plan? = nil, message: String? = nil) -> AppConfig {
    var c = AppConfig(launchAtLogin: false, autoApproveCookieAccess: true, configVersion: nil, profiles: profiles)
    c.keepWorkGoing = on
    c.keepGoingPlan = plan?.rawValue
    c.keepGoingMessage = message
    c.relayOrder = profiles.map(\.id)
    return c
}

func session(_ key: String = "code:s1", title: String = "Investigate document saving", on: String, limit: String? = nil, ago: TimeInterval = 30) -> KeepGoing.Observed {
    KeepGoing.Observed(key: key, title: title, profileID: on, localID: "local_" + key, cliSessionID: key, modified: now.addingTimeInterval(-ago), limitMarker: limit)
}

func store(_ edit: (inout KeepGoing.Store) -> Void) -> KeepGoing.Store {
    var store = KeepGoing.Store()
    edit(&store)
    return store
}

var failures = 0

func check(_ name: String, _ ok: Bool, _ detail: String) {
    print("\(ok ? "PASS" : "FAIL")  \(name)\n      \(detail)")
    if !ok { failures += 1 }
}

func run(_ name: String, _ observed: [KeepGoing.Observed], _ cfg: AppConfig, store: KeepGoing.Store = .init(), running: [String: KeepGoing.Running] = [:],
         expect: (KeepGoing.SessionInfo, [KeepGoing.Action], Date?, KeepGoing.Store) -> Bool) {
    var store = store
    let a = KeepGoing.assess(observed, config: cfg, store: &store, running: running, now: now)
    let s = a.sessions[0]
    let line = "[\(s.state.label)] \(s.title) · \(s.accountName)\(s.movedNote.map { " · " + $0 } ?? "")\n      \(s.planText)\(s.marker.map { " · " + $0 } ?? "")\(s.action.map { "   [\($0)]" } ?? "")"
    let acts = a.actions.map { action -> String in
        switch action {
        case let .send(_, to, moved, message): return "sends “\(message)” in \(to)'s window\(moved ? ", after moving it there" : "")"
        case let .notifyLimit(_, title, body, canMove, canLeave): return "notification: \(title). \(body)\(canMove ? " [Move now]" : "")\(canLeave ? " [Don't continue]" : "")"
        case let .answer(_, to, how, message): return "answers in \(to)'s window (\(how.title)): “\(message)”"
        case let .notifyQuestion(_, title, body, _): return "notification: \(title). \(body)"
        }
    }
    let wake = a.wakeAt.map { "\n      → wakes in \(Int(($0.timeIntervalSince(now) / 60).rounded())) min" } ?? ""
    check(name, expect(s, a.actions, a.wakeAt, store), line + acts.map { "\n      → " + $0 }.joined() + wake)
}

func isNotify(_ action: KeepGoing.Action, move: Bool? = nil, leave: Bool? = nil) -> Bool {
    guard case let .notifyLimit(_, _, _, canMove, canLeave) = action else { return false }
    return (move == nil || move == canMove) && (leave == nil || leave == canLeave)
}

let p95 = profile("95", email: "franciskid95@gmail.com", five: 50, fiveReset: 3600)
let p95full = profile("95", email: "franciskid95@gmail.com", five: 100, fiveReset: 90 * 60)
let p97 = profile("97", email: "franciskid97@gmail.com", five: 20, fiveReset: 3600)
let p97full = profile("97", email: "franciskid97@gmail.com", five: 100, fiveReset: 49 * 60)
let gpt = profile("g", email: "franciskid97@gmail.com", five: 0, fiveReset: 3600, provider: "Codex")

run("Working, will continue here", [session(on: "95")], config([p95, p97full, gpt])) { s, a, w, _ in
    s.state == .working && s.planText == "At its limit: continues here after the reset" && s.marker == "default" && a.isEmpty && w == nil
}
run("Working, will move to 97, which is full", [session(on: "95")], config([p95, p97full]),
    store: store { $0.overrides["code:s1"] = .init(plan: .move, target: "97") }) { s, a, _, _ in
    s.planText.hasPrefix("At its limit: moves to franciskid97, back at ") && s.marker == "custom" && s.chosenTarget == "97" && a.isEmpty
}
run("Working, will move, 97 has room", [session(on: "95")], config([p95, p97]),
    store: store { $0.overrides["code:s1"] = .init(plan: .move) }) { s, _, _, _ in
    s.planText == "At its limit: moves to franciskid97"
}
run("Waiting for its own reset", [session(on: "97", limit: "L1", ago: 600)], config([p95, p97full])) { s, a, w, _ in
    s.state == .waitingForReset && s.planText.hasPrefix("Continues here at ") && s.planText.hasSuffix("in 49 min")
        && w != nil && a.count == 1 && isNotify(a[0], move: true, leave: true)
}
run("Waiting, notified only once", [session(on: "97", limit: "L1", ago: 600)], config([p95, p97full]),
    store: store { $0.notified["code:s1"] = "L1" }) { _, a, _, _ in a.isEmpty }
run("At its limit with plan “move”, 95 has room", [session(on: "97", limit: "L1")], config([p95, p97full], plan: .move)) { s, a, _, st in
    s.state == .moving && a == [.send(key: "code:s1", to: "95", moved: true, message: "continue")] && st.handled["code:s1"] == "L1"
}
run("Moving (a few seconds)", [session(on: "97", limit: "L1")], config([p95, p97full], plan: .move), running: ["code:s1": .init(moving: true, to: "95")]) { s, a, _, _ in
    s.state == .moving && s.planText == "Opening it on franciskid95, sending “continue”…" && a.isEmpty
}
run("Sending in its own window", [session(on: "97", limit: "L1")], config([p95, p97]), running: ["code:s1": .init(moving: false, to: "97")]) { s, _, _, _ in
    s.state == .sending && s.planText == "Sending “continue” in franciskid97's window…"
}
run("Moved earlier, working again", [session(on: "95")], config([p95, p97full], plan: .move),
    store: store { $0.moved["code:s1"] = .init(from: "97", to: "95", at: now.addingTimeInterval(-1200)) }) { s, _, _, _ in
    s.state == .working && (s.movedNote ?? "").hasPrefix("moved from franciskid97 at ") && s.planText.hasPrefix("At its limit: moves to franciskid97, back at ")
}
run("Every account is full, its own is back first", [session(on: "97", limit: "L1")], config([p95full, p97full], plan: .move)) { s, a, w, _ in
    s.state == .waitingForReset && s.planText.hasPrefix("No account has room · continues here at ") && w != nil && a.count == 1
}
run("Every account is full, the other is back first", [session(on: "97", limit: "L1")],
    config([profile("95", email: "franciskid95@gmail.com", five: 100, fiveReset: 20 * 60), p97full], plan: .move)) { s, _, w, _ in
    s.planText.hasPrefix("No account has room · continues on franciskid95 at ") && w.map { abs($0.timeIntervalSince(now) - 1200) < 2 } == true
}
run("Weekly limit", [session(on: "97", limit: "L1")],
    config([p95, profile("97", email: "franciskid97@gmail.com", five: 10, fiveReset: 3600, week: 100, weekReset: 2 * 86400 + 600)])) { s, _, _, _ in
    s.state == .waitingForReset && s.planText.range(of: #"^Continues here at [A-Z][a-z]{2} \d\d:\d\d"#, options: .regularExpression) != nil
}
run("Reset time passed, usage not refreshed yet", [session(on: "97", limit: "L1")],
    config([p95, profile("97", email: "franciskid97@gmail.com", five: 100, fiveReset: -30)])) { s, a, _, _ in
    s.state == .sending && a == [.send(key: "code:s1", to: "97", moved: false, message: "continue")]
}
run("Needs you: a draft was in the reply box", [session(on: "97", limit: "L1")], config([p95, p97]),
    store: store {
        $0.handled["code:s1"] = "L1"
        $0.failed["code:s1"] = .init(marker: "L1", reason: "Couldn't send: an unsent draft is in its reply box")
    }) { s, a, _, _ in
    s.state == .needsYou && s.planTone == .alert && s.action == "Try again" && a.isEmpty
}
run("Leave it, at its limit", [session(on: "97", limit: "L1")], config([p95, p97full]),
    store: store { $0.overrides["code:s1"] = .init(plan: .leave) }) { s, a, _, _ in
    s.state == .idle && s.planText == "Reached its limit · left as it is" && a.count == 1 && isNotify(a[0], move: false, leave: false)
}
run("Leave it, before its limit", [session(on: "95", ago: 3000)], config([p95, p97]),
    store: store { $0.overrides["code:s1"] = .init(plan: .leave) }) { s, _, _, _ in
    s.state == .idle && s.planText == "At its limit: left as it is" && s.marker == "custom"
}
run("You picked it up yourself", [session(on: "97", limit: nil)], config([p95, p97full]),
    store: store { $0.notified["code:s1"] = "L1" }) { s, a, _, _ in
    s.state == .working && a.isEmpty
}
run("Turned off", [session(on: "95")], config([p95, p97], on: false)) { s, a, _, _ in
    s.state == .off && s.planText == "Nothing happens while this is off" && s.marker == nil && a.isEmpty
}
run("Turned off, at a limit", [session(on: "97", limit: "L1")], config([p95, p97], on: false)) { s, a, _, _ in
    s.state == .off && a.isEmpty
}
run("Too many moves", [session(on: "97", limit: "L1")], config([p95, p97full], plan: .move),
    store: store { $0.moves = (0..<8).map { now.addingTimeInterval(TimeInterval(-$0 * 600)) } }) { s, a, _, _ in
    s.state == .needsYou && s.planText == "Moving paused after 8 moves in 12 hours" && !a.contains { if case .send = $0 { return true }; return false }
}
run("Reached its limit before this was on", [session(on: "97", limit: "L1")], config([p95, p97]),
    store: store { $0.before["code:s1"] = "L1" }) { s, a, _, _ in
    s.state == .idle && s.action == "Continue now" && a.isEmpty
}
run("Continue here, and its account has room", [session(on: "95", limit: "L1")], config([p95, p97])) { s, a, _, _ in
    s.state == .sending && a == [.send(key: "code:s1", to: "95", moved: false, message: "continue")]
}
run("Its own message", [session(on: "97", limit: "L1")], config([p95, p97full]),
    store: store { $0.overrides["code:s1"] = .init(message: "keep going with the tests") }) { s, _, _, _ in
    s.planText.hasSuffix(" · says “keep going with the tests”") && s.marker == "custom"
}
run("Notification “Move now”, for this limit", [session(on: "97", limit: "L1")], config([p95, p97full]),
    store: store {
        $0.notified["code:s1"] = "L1"
        $0.oneOff["code:s1"] = .init(marker: "L1", plan: .move)
    }) { s, a, _, _ in
    s.state == .moving && a == [.send(key: "code:s1", to: "95", moved: true, message: "continue")]
}
run("A notification's choice ends with its limit", [session(on: "97", limit: "L2")], config([p95, p97full]),
    store: store { $0.oneOff["code:s1"] = .init(marker: "L1", plan: .move) }) { s, _, _, _ in
    s.state == .waitingForReset
}
run("Default from Settings is “move”", [session(on: "95")], config([p95, p97], plan: .move)) { s, _, _, _ in
    s.plan == .move && s.marker == "default" && s.planText == "At its limit: moves to franciskid97"
}
run("Default message from Settings", [session(on: "97", limit: "L1")], config([p95, p97full], message: "go on")) { s, _, _, _ in
    s.message == "go on" && s.marker == "default"
}
run("Targets: the other Claude account, then ChatGPT", [session(on: "95")], config([p95, p97full, gpt])) { s, _, _, _ in
    s.targets.count == 2 && s.targets[0].room.hasPrefix("full until ") && !s.targets[0].hasRoom && s.targets[1].isChatGPT && s.targets[1].hasRoom
}
run("Picked ChatGPT, before its limit", [session(on: "95")], config([p95, p97full, gpt]),
    store: store { $0.overrides["code:s1"] = .init(plan: .move, target: "g") }) { s, _, _, _ in
    s.planText == "At its limit: moves to franciskid97's ChatGPT, where you send “continue”" && s.chosenTarget == "g"
}
run("Picked ChatGPT, at its limit", [session(on: "97", limit: "L1")], config([p95, p97full, gpt]),
    store: store { $0.overrides["code:s1"] = .init(plan: .move, target: "g") }) { s, a, _, _ in
    s.state == .moving && s.planText == "Opening it in franciskid97's ChatGPT…" && a == [.send(key: "code:s1", to: "g", moved: true, message: "continue")]
}
run("Moved to ChatGPT: yours to send", [session(on: "97", limit: "L1")], config([p95, p97full, gpt]),
    store: store {
        $0.overrides["code:s1"] = .init(plan: .move, target: "g")
        $0.handled["code:s1"] = "L1"
        $0.moved["code:s1"] = .init(from: "97", to: "g", at: now.addingTimeInterval(-300), thread: "t1")
    }) { s, a, _, _ in
    s.state == .needsYou && s.planText.hasPrefix("Moved to franciskid97's ChatGPT at ") && s.action == "Open in ChatGPT" && a.isEmpty
}
run("“Any account” never picks ChatGPT", [session(on: "97", limit: "L1")], config([p95full, p97full, gpt], plan: .move)) { s, a, _, _ in
    s.state == .waitingForReset && !a.contains { if case .send = $0 { return true }; return false }
}

// Auto-start: once per 5h window. ChatGPT's usage stays at 0% after the "hi", so its
// last start is what counts.
let gptIdle = profile("g", email: "franciskid97@gmail.com", five: 0, fiveReset: 5 * 3600, provider: "Codex")
check("ChatGPT auto-start: not again 30 min later", !SessionKickstarter.shouldKick(gptIdle, lastKick: now.addingTimeInterval(-31 * 60), now: now), "last start 31 min ago")
check("ChatGPT auto-start: not again 4h later", !SessionKickstarter.shouldKick(gptIdle, lastKick: now.addingTimeInterval(-4 * 3600), now: now), "last start 4h ago")
check("ChatGPT auto-start: again once the window is over", SessionKickstarter.shouldKick(gptIdle, lastKick: now.addingTimeInterval(-5.1 * 3600), now: now), "last start 5h 6m ago")
check("ChatGPT auto-start: first time", SessionKickstarter.shouldKick(gptIdle, lastKick: nil, now: now), "never started")
let claudeIdle = profile("95", email: "franciskid95@gmail.com", five: 0, fiveReset: -60)
check("Claude auto-start: after its reset, 40 min on", SessionKickstarter.shouldKick(claudeIdle, lastKick: now.addingTimeInterval(-40 * 60), now: now), "reset passed, last start 40 min ago")
check("Claude auto-start: not while its window runs", !SessionKickstarter.shouldKick(p95, lastKick: nil, now: now), "50% used, reset ahead")

var sorting = KeepGoing.Store()
let order = KeepGoing.assess([session("code:a", title: "A idle", on: "95", ago: 3000),
                              session("code:b", title: "B waiting", on: "97", limit: "L"),
                              session("code:c", title: "C working", on: "95")],
                             config: config([p95, p97full]), store: &sorting, running: [:], now: now).sessions.map(\.title)
check("Order: waiting first, then working, then idle", order == ["B waiting", "C working", "A idle"], order.joined(separator: ", "))

print(failures == 0 ? "\nAll scenarios pass." : "\n\(failures) failing.")
exit(failures == 0 ? 0 : 1)

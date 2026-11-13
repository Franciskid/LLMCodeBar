import AppKit

// "Answer for me when I'm away": how a session waiting on you is found in its transcript,
// and what LLMCodeBar does about it while you're at the Mac or away, through the same
// code the app uses (KeepGoing.pendingQuestion and KeepGoing.assess). Run with
// scripts/test.sh.

let now = Date()
var failures = 0

func check(_ name: String, _ ok: Bool, _ detail: String) {
    print("\(ok ? "PASS" : "FAIL")  \(name)\n      \(detail)")
    if !ok { failures += 1 }
}

// MARK: Transcript lines

func stamp(_ ago: TimeInterval) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: now.addingTimeInterval(-ago))
}

func you(_ text: String) -> [String: Any] {
    ["type": "user", "uuid": UUID().uuidString, "timestamp": stamp(600), "message": ["role": "user", "content": text]]
}

func result(_ id: String = "t1") -> [String: Any] {
    ["type": "user", "uuid": UUID().uuidString, "timestamp": stamp(300), "message": ["role": "user", "content": [["type": "tool_result", "tool_use_id": id, "content": "ok"]]]]
}

func tool(_ name: String, _ input: [String: Any], uuid: String = "Q1", ago: TimeInterval = 300) -> [String: Any] {
    ["type": "assistant", "uuid": uuid, "timestamp": stamp(ago),
     "message": ["role": "assistant", "stop_reason": "tool_use", "content": [["type": "tool_use", "id": "t1", "name": name, "input": input]]]]
}

func says(_ text: String, uuid: String = "Q1", ago: TimeInterval = 300, ended: Bool = true) -> [String: Any] {
    var message: [String: Any] = ["role": "assistant", "content": [["type": "text", "text": text]]]
    if ended { message["stop_reason"] = "end_turn" }
    return ["type": "assistant", "uuid": uuid, "timestamp": stamp(ago), "message": message]
}

let card = tool("AskUserQuestion", ["questions": [["question": "Which language should the CV be in?", "header": "Language",
                                                   "options": [["label": "French"], ["label": "English"], ["label": "Both versions"]]]]])
let wrapUp = tool("mcp__ccd_turn__wrap_up", ["recap": "Done.", "ask": "Commit this to the feature branch?", "actions": [["label": "Commit"], ["label": "Not now"]]], uuid: "W")

func detect(_ name: String, _ lines: [[String: Any]], _ expect: (KeepGoing.Question?) -> Bool) {
    let q = KeepGoing.pendingQuestion(in: lines)
    let shown = q.map { "\($0.kind): “\($0.text)”\($0.options.isEmpty ? "" : " [" + $0.options.joined(separator: " · ") + "]")" } ?? "nothing waiting on you"
    check(name, expect(q), shown)
}

detect("Question card, not answered", [you("make my CV"), card]) { $0?.kind == .card && $0?.text == "Which language should the CV be in?" && $0?.options == ["French", "English", "Both versions"] && $0?.marker == "Q1" }
detect("Question card, answered", [you("make my CV"), card, result(), says("Writing it in French.", uuid: "A")]) { $0 == nil }
detect("Two questions on one card", [you("go"), tool("AskUserQuestion", ["questions": [["question": "Which language?", "options": []], ["question": "Which format?", "options": []]]])]) { $0?.text == "Which language? (and 1 more)" }
detect("Plan waiting for approval", [you("plan it"), tool("ExitPlanMode", ["plan": "# Add a subtitle dialog\n\n1. ..."])]) { $0?.kind == .plan && $0?.text == "Plan: Add a subtitle dialog" }
detect("Next-step box question", [you("fix it"), wrapUp, result(), says("I fixed it and it's installed.")]) { $0?.kind == .nextStep && $0?.text == "Commit this to the feature branch?" && $0?.options == ["Commit", "Not now"] && $0?.marker == "Q1" }
detect("Next-step box from an earlier turn", [you("fix it"), wrapUp, result(), says("I fixed it.", uuid: "A"), you("yes"), says("Committed.")]) { $0 == nil }
detect("Turn ending on a question", [you("fix it"), says("I fixed the bug.\n\nWant me to also add tests?")]) { $0?.kind == .text && $0?.text == "Want me to also add tests?" }
detect("Question in bold at the end", [you("fix it"), says("Done. **Should I commit it?**")]) { $0?.kind == .text && $0?.text == "Should I commit it?" }
detect("Turn ending on a statement", [you("fix it"), says("It's fixed and committed.")]) { $0 == nil }
detect("Still writing (turn not over)", [you("fix it"), says("Looking at the code? Let me", ended: false)]) { $0 == nil }
detect("Running a command", [you("fix it"), tool("Bash", ["command": "make"])]) { $0 == nil }
detect("You spoke last", [you("fix it"), says("Done?"), you("thanks")]) { $0 == nil }
detect("At a usage limit", [you("fix it"), ["type": "assistant", "uuid": "L", "error": "rate_limit", "timestamp": stamp(60), "message": ["role": "assistant", "content": [["type": "text", "text": "You've hit your limit. Want more?"]]]]]) { $0 == nil }

// MARK: What happens

func profile(_ id: String, email: String) -> LaunchProfile {
    let json: [String: Any] = [
        "id": id, "label": id, "provider": "Claude", "appPath": "/Applications/Claude.app", "dataDir": "/tmp/\(id)",
        "accountEmail": email, "identityVerified": true, "accountPlan": "Pro",
        "usage": ["source": "test", "updatedAt": now.timeIntervalSinceReferenceDate, "accountPlan": "Pro",
                  "windows": [["title": "5h", "usedPercent": 30, "remainingPercent": 70, "resetsAt": now.addingTimeInterval(3600).timeIntervalSinceReferenceDate],
                              ["title": "Week", "usedPercent": 30, "remainingPercent": 70, "resetsAt": now.addingTimeInterval(86400).timeIntervalSinceReferenceDate]]],
    ]
    return try! JSONDecoder().decode(LaunchProfile.self, from: JSONSerialization.data(withJSONObject: json))
}

let p97 = profile("97", email: "franciskid97@gmail.com")
let p95 = profile("95", email: "franciskid95@gmail.com")

func config(answering: Bool = true, limits: Bool = true, minutes: Int? = nil, answer: KeepGoing.Answer? = nil, texts: Bool = false, decide: String? = nil) -> AppConfig {
    var c = AppConfig(launchAtLogin: false, autoApproveCookieAccess: true, configVersion: nil, profiles: [p97, p95])
    c.keepWorkGoing = limits
    c.relayOrder = ["97", "95"]
    c.answerWhenAway = answering
    c.awayMinutes = minutes
    c.awayAnswer = answer?.rawValue
    c.answerTextQuestions = texts
    c.decideMessage = decide
    return c
}

func asking(_ kind: KeepGoing.Question.Kind = .card, text: String = "Which language should the CV be in?", ago: TimeInterval = 300, marker: String = "Q1") -> KeepGoing.Observed {
    var item = KeepGoing.Observed(key: "code:cv", title: "Build the CV", profileID: "97", localID: "local_cv", cliSessionID: "cv", modified: now.addingTimeInterval(-ago), limitMarker: nil)
    item.question = KeepGoing.Question(kind: kind, text: text, options: kind == .card ? ["French", "English"] : [], marker: marker, askedAt: now.addingTimeInterval(-ago))
    return item
}

let away = KeepGoing.Presence(idle: 720.0, locked: false)
let here = KeepGoing.Presence.here

func run(_ name: String, _ observed: [KeepGoing.Observed], _ cfg: AppConfig = config(), presence: KeepGoing.Presence = here,
         store: KeepGoing.Store = .init(), running: [String: KeepGoing.Running] = [:],
         expect: (KeepGoing.SessionInfo, [KeepGoing.Action], KeepGoing.Store) -> Bool) {
    var store = store
    let a = KeepGoing.assess(observed, config: cfg, store: &store, running: running, now: now, presence: presence)
    let s = a.sessions[0]
    let q = s.question.map { "\n      “\($0.text)”" } ?? ""
    let line = "[\(s.state.label)] \(s.title) · \(s.accountName)\(q)\n      \(s.planText)\(s.marker.map { " · " + $0 } ?? "")\(s.action.map { "   [\($0)]" } ?? "")"
    let acts = a.actions.map { action -> String in
        switch action {
        case let .answer(_, to, how, message): return "answers in \(to)'s window (\(how.title)): “\(message)”"
        case let .notifyQuestion(_, title, body, canAnswer): return "notification: \(title). \(body)\(canAnswer ? " [Decide for me] [Do what you can]" : "")"
        case let .send(_, to, _, message): return "sends “\(message)” in \(to)'s window"
        case let .notifyLimit(_, title, _, _, _): return "notification: \(title)"
        }
    }
    check(name, expect(s, a.actions, store), line + acts.map { "\n      → " + $0 }.joined())
}

func answers(_ actions: [KeepGoing.Action], _ how: KeepGoing.Answer? = nil) -> Bool {
    actions.contains { if case let .answer(_, _, h, _) = $0 { return how == nil || h == how }; return false }
}
func notifies(_ actions: [KeepGoing.Action]) -> Bool {
    actions.contains { if case .notifyQuestion = $0 { return true }; return false }
}

run("Asking, you're at the Mac", [asking()]) { s, a, st in
    s.state == .askingYou && s.planText == "If you're away 10 min: Decide for me" && s.marker == "default" && !answers(a) && notifies(a) && st.asked["code:cv"] == "Q1"
}
run("Asking, notified once only", [asking()], store: { var s = KeepGoing.Store(); s.asked["code:cv"] = "Q1"; return s }()) { _, a, _ in
    a.isEmpty
}
run("Just asked: you may be answering it", [asking(ago: 20)]) { s, a, _ in
    s.state == .askingYou && a.isEmpty
}
run("Idle 4 min: counts down", [asking()], presence: .init(idle: 250.0, locked: false)) { s, a, _ in
    s.planText == "If you stay away 6 more min: Decide for me" && !answers(a)
}
run("Away 12 min: answers “Decide for me”", [asking()], presence: away) { s, a, st in
    s.state == .sending && s.planText.hasPrefix("You're away · answering in franciskid97's window") && answers(a, .decide) && !notifies(a)
        && st.answered["code:cv"]?.marker == "Q1" && st.answers["code:cv"]?.count == 1
}
run("Away: uses your own “decide” message", [asking()], config(decide: "Pick what you think is best."), presence: away) { _, a, _ in
    a.contains { if case let .answer(_, _, _, message) = $0 { return message == "Pick what you think is best." }; return false }
}
run("Away, but it asked 20 s ago: waits a moment", [asking(ago: 20)], presence: away) { s, a, _ in
    s.state == .askingYou && a.isEmpty
}
run("Screen locked counts as away", [asking()], presence: .init(idle: 5, locked: true)) { _, a, _ in
    answers(a)
}
run("Away 25 min with a 30 min setting: not yet", [asking()], config(minutes: 30), presence: .init(idle: 1500.0, locked: false)) { s, a, _ in
    s.planText == "If you stay away 5 more min: Decide for me" && !answers(a)
}
run("This session: do what you can without it", [asking()], presence: away,
    store: { var s = KeepGoing.Store(); s.overrides["code:cv"] = .init(answer: .around); return s }()) { s, a, _ in
    answers(a, .around) && a.contains { if case let .answer(_, _, _, m) = $0 { return m == KeepGoing.Answer.aroundMessage }; return false }
}
run("This session: wait for me", [asking()], presence: away,
    store: { var s = KeepGoing.Store(); s.overrides["code:cv"] = .init(answer: .wait); return s }()) { s, a, _ in
    s.state == .askingYou && s.planText == "Waits for you · you get a notification" && s.marker == "custom" && !answers(a) && notifies(a)
}
run("Default “wait for me” in Settings", [asking()], config(answer: .wait), presence: away) { s, a, _ in
    s.marker == "default" && !answers(a)
}
run("Already answered, waiting for it to show", [asking()], presence: away,
    store: { var s = KeepGoing.Store(); s.answered["code:cv"] = .init(marker: "Q1", how: .decide, at: now.addingTimeInterval(-20)); return s }()) { s, a, _ in
    s.planText == "Answered, waiting for it to show" && a.isEmpty
}
run("Asks again after its answer: answered again", [asking(marker: "Q2")], presence: away,
    store: { var s = KeepGoing.Store(); s.answered["code:cv"] = .init(marker: "Q1", how: .decide, at: now.addingTimeInterval(-600)); s.answers["code:cv"] = [now.addingTimeInterval(-600)]; return s }()) { _, a, st in
    answers(a) && st.answers["code:cv"]?.count == 2
}
run("Third answer this hour is the last", [asking(marker: "Q4")], presence: away,
    store: { var s = KeepGoing.Store(); s.answers["code:cv"] = [now.addingTimeInterval(-3000), now.addingTimeInterval(-1200), now.addingTimeInterval(-300)]; return s }()) { s, a, _ in
    s.planText == "Answered 3 times this hour, so this one waits for you" && !answers(a) && notifies(a)
}
run("Answers from over an hour ago don't count", [asking(marker: "Q4")], presence: away,
    store: { var s = KeepGoing.Store(); s.answers["code:cv"] = [now.addingTimeInterval(-4000), now.addingTimeInterval(-3700), now.addingTimeInterval(-300)]; return s }()) { _, a, _ in
    answers(a)
}
run("Plan approval: never answered", [asking(.plan, text: "Plan: Add a subtitle dialog")], presence: away) { s, a, _ in
    s.state == .waitingForYou && s.planText == "Its plan waits for your approval. Never answered for you" && !s.canAnswerNow && !answers(a)
        && a.contains { if case let .notifyQuestion(_, _, _, canAnswer) = $0 { return !canAnswer }; return false }
}
run("Next-step box question: answered when away", [asking(.nextStep, text: "Commit this to the feature branch?")], presence: away) { _, a, _ in
    answers(a)
}
run("Turn ending on “?”: shown, not answered", [asking(.text, text: "Want me to also add tests?")], presence: away) { s, a, _ in
    s.state == .askingYou && s.planText == "Shown only: turns that end on a question aren't answered (Settings)" && !answers(a)
}
run("Turn ending on “?”, ticked in Settings: answered", [asking(.text, text: "Want me to also add tests?")], config(texts: true), presence: away) { _, a, _ in
    answers(a)
}
run("Answering off: listed, nothing sent, no notification", [asking()], config(answering: false), presence: away) { s, a, _ in
    s.state == .askingYou && s.planText == "Waits for you · answering for you is off" && s.canAnswerNow && a.isEmpty
}
run("Continue after limits off, answering on: still answered", [asking()], config(limits: false), presence: away) { s, a, _ in
    answers(a) && s.limitSummary == "At its limit: nothing happens while “Continue after limits” is off"
}
run("The answer couldn't be typed", [asking()], presence: away,
    store: { var s = KeepGoing.Store(); s.answered["code:cv"] = .init(marker: "Q1", how: .decide, at: now.addingTimeInterval(-60)); s.answerFailed["code:cv"] = .init(marker: "Q1", reason: "Couldn't answer: an unsent draft is in its reply box"); return s }()) { s, a, _ in
    s.state == .needsYou && s.planText == "Couldn't answer: an unsent draft is in its reply box" && s.action == "Try again" && a.isEmpty
}
run("Answer on its way", [asking()], running: ["code:cv": .init(moving: false, to: "97", answering: .decide)]) { s, a, _ in
    s.state == .sending && s.planText == "Answering in franciskid97's window: “Decide for me”…" && a.isEmpty
}
run("Answered 20 min ago, working again", [KeepGoing.Observed(key: "code:cv", title: "Build the CV", profileID: "97", localID: "l", cliSessionID: "cv", modified: now.addingTimeInterval(-30), limitMarker: nil)],
    store: { var s = KeepGoing.Store(); s.answered["code:cv"] = .init(marker: "Q1", how: .decide, at: now.addingTimeInterval(-1200)); return s }()) { s, a, _ in
    s.state == .working && s.planText.hasPrefix("Answered at ") && s.planText.hasSuffix(": Decide for me") && s.limitSummary == "At its limit: continues here after the reset" && a.isEmpty
}
run("Answered 2 hours ago: back to its limit plan", [KeepGoing.Observed(key: "code:cv", title: "Build the CV", profileID: "97", localID: "l", cliSessionID: "cv", modified: now.addingTimeInterval(-30), limitMarker: nil)],
    store: { var s = KeepGoing.Store(); s.answered["code:cv"] = .init(marker: "Q1", how: .decide, at: now.addingTimeInterval(-7200)); return s }()) { s, _, _ in
    s.planText == "At its limit: continues here after the reset"
}

var sorting = KeepGoing.Store()
let order = KeepGoing.assess([KeepGoing.Observed(key: "code:w", title: "Working one", profileID: "95", localID: "w", cliSessionID: "w", modified: now, limitMarker: nil),
                              asking()], config: config(), store: &sorting, running: [:], now: now).sessions.map(\.title)
check("Order: asking you first", order == ["Build the CV", "Working one"], order.joined(separator: ", "))

print(failures == 0 ? "\nAll question scenarios pass." : "\n\(failures) failing.")
exit(failures == 0 ? 0 : 1)

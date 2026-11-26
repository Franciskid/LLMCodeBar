import AppKit
import CryptoKit
import SQLite3

func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { fatalError(message) }
}
let app = NSApplication.shared
var profile = LaunchProfile.pending(provider: .claude, appPath: "/Applications/Claude.app", dataDir: "/tmp/test-profile")
profile.isPendingLogin = false
profile.signedIn = true
profile.usage = UsageInfo(source: "fixture", windows: [
    UsageWindow(title: "5h", usedPercent: 42, remainingPercent: 58, resetsAt: Date().addingTimeInterval(3600)),
    UsageWindow(title: "Week", usedPercent: 25, remainingPercent: 75, resetsAt: Date().addingTimeInterval(172800)),
    UsageWindow(title: "Sonnet week", usedPercent: 5, remainingPercent: 95, resetsAt: nil)
], updatedAt: Date())
check(profile.visibleWindows().count == 3, "all available windows visible")
profile.showSessionWindow = false
check(profile.visibleWindows().count == 2, "session can be hidden independently")
profile.showWeeklyWindows = false
check(profile.visibleWindows().isEmpty, "all bars can be hidden")
profile.showSessionWindow = true
profile.showWeeklyWindows = true
profile.showResetTimes = false
profile.resetAlertMinutes = 15
let encoded = try JSONEncoder().encode(profile)
let decoded = try JSONDecoder().decode(LaunchProfile.self, from: encoded)
check(decoded.showResetTimes == false && decoded.resetAlertMinutes == 15, "per-account settings persist")
var legacy = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
for key in ["showResetTimes", "showLabels", "showSessionWindow", "showWeeklyWindows", "showSparklines", "resetAlertMinutes"] { legacy.removeValue(forKey: key) }
let old = try JSONDecoder().decode(LaunchProfile.self, from: JSONSerialization.data(withJSONObject: legacy))
check(old.visibleWindows().count == 3 && old.showResetTimes == nil, "legacy config keeps default visible limits")
profile.showResetTimes = true
let card = ProfileMenuItemView(profile: profile, target: app, action: #selector(NSApplication.stop(_:)), isRefreshing: false, isRunning: false, showSparklines: false)
let host = NSWindow(contentRect: card.frame, styleMask: [.borderless], backing: .buffered, defer: false)
host.contentView = card
card.layoutSubtreeIfNeeded()
func descendants(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + descendants($0) } }
let quotas = descendants(card).compactMap { $0 as? QuotaWindowView }
check(quotas.count == 3, "Sonnet weekly limit is not silently dropped")
for quota in quotas {
    quota.layoutSubtreeIfNeeded()
    check(quota.frame.width > 250, "quota row has usable width")
    let labels = descendants(quota).compactMap { $0 as? NSTextField }
    check(labels.last!.frame.width >= 61, "reset date has reserved width")
    check(labels.last!.frame.maxX <= quota.bounds.maxX + 3, "reset fits in row")
}
profile.accountEmail = "personal95@example.com"
profile.menuBarLabel = "95"
profile.accountPlan = "Pro"
profile.usage?.manualResets = ManualResetInventory(allowances: [
    ManualResetAllowance(kind: "Fable", count: 1, expiresAt: Date().addingTimeInterval(4 * 86400), startsAt: nil),
    ManualResetAllowance(kind: "Full", count: 1, expiresAt: Date().addingTimeInterval(27 * 86400), startsAt: nil)
], fetchedAt: Date())
var secondProfile = profile
secondProfile.id = "second-account"
secondProfile.accountEmail = "work97@example.com"
secondProfile.menuBarLabel = "97"
secondProfile.manualResetExpiryAlertHours = 6
var editedConfig = AppConfig(launchAtLogin: false, profiles: [profile, secondProfile])
editedConfig.menuBarRows = 1; editedConfig.menuBarColumns = 3; editedConfig.showMenuBarLabels = true
let settings = SettingsWindowController(config: editedConfig, onChange: { mutate in mutate(&editedConfig) }, onCheckForUpdates: { _ in })
settings.window!.contentView!.layoutSubtreeIfNeeded()
check(settings.window!.frame.height < 700, "settings stays compact")
let pages = descendants(settings.window!.contentView!).compactMap { $0 as? NSTabView }.first!
check(pages.tabViewItems.map(\.label) == ["General", "Menu bar", "Account", "Continue after limits"], "General, menu-bar, account and continue controls each have a page")
check(pages.selectedTabViewItem?.label == "General", "General opens independently")
pages.selectTabViewItem(at: 1)
settings.window!.contentView!.layoutSubtreeIfNeeded()
let menuControls = descendants(pages.tabViewItems[1].view!)
check(menuControls.contains { $0 is MenuBarGridPicker }, "menu-bar grid picker is preserved")
check(menuControls.contains { $0.identifier?.rawValue == "showIconLabels" }, "icon label toggle is preserved")
check(menuControls.contains { $0.identifier?.rawValue == "showWeekly" }, "weekly menu-bar setting is preserved")
check(menuControls.compactMap { $0 as? NSPopUpButton }.contains { $0.itemTitles.contains("Side by side") }, "arrangement control is preserved")
pages.selectTabViewItem(at: 2)
settings.window!.contentView!.layoutSubtreeIfNeeded()
check(descendants(pages.tabViewItems[2].view!).contains { $0.identifier?.rawValue == "showResets" }, "account reset toggle is preserved")
let accountTable = descendants(settings.window!.contentView!).compactMap { $0 as? NSTableView }.first!
accountTable.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
let accountView = pages.tabViewItems[2].view!
let notificationPicker = descendants(accountView).compactMap { $0 as? NSPopUpButton }.first { $0.identifier?.rawValue == "resetAlerts" }!
notificationPicker.selectItem(at: 3)
_ = notificationPicker.target?.perform(notificationPicker.action!, with: notificationPicker)
check(editedConfig.profiles[0].manualResetExpiryAlertHours == 24, "notification lead time saves for selected account")
check(editedConfig.profiles[1].manualResetExpiryAlertHours == 6, "another account's notification setting is preserved")
notificationPicker.selectItem(at: 0)
_ = notificationPicker.target?.perform(notificationPicker.action!, with: notificationPicker)
check(editedConfig.profiles[0].manualResetExpiryAlertHours == 0 && ResetReminder.plans(editedConfig.profiles[0]).isEmpty, "Off disables selected account notifications")
check(editedConfig.menuBarGridRows == 1 && editedConfig.menuBarGridColumns == 3 && editedConfig.showsMenuBarLabels, "notification edits preserve restored menu-bar preferences")
// The Claude Code login row belongs to Claude accounts only, and the Sessions help text is shown whole.
var sessionsCodex = secondProfile
sessionsCodex.provider = .codex
sessionsCodex.id = "codex-account"
var sessionsConfig = AppConfig(launchAtLogin: false, profiles: [profile, sessionsCodex])
let sessionsSettings = SettingsWindowController(config: sessionsConfig, onChange: { mutate in mutate(&sessionsConfig) }, onCheckForUpdates: { _ in })
let sessionsTabs = descendants(sessionsSettings.window!.contentView!).compactMap { $0 as? NSTabView }.first!
sessionsTabs.selectTabViewItem(at: 2)
let sessionsAccountView = sessionsTabs.tabViewItems[2].view!
let sessionsPicker = descendants(sessionsAccountView).compactMap { $0 as? NSSegmentedControl }.first { (control: NSSegmentedControl) in control.segmentCount == 3 }!
sessionsPicker.selectedSegment = 1
_ = sessionsPicker.target?.perform(sessionsPicker.action!, with: sessionsPicker)
let sessionsTable = descendants(sessionsSettings.window!.contentView!).compactMap { $0 as? NSTableView }.first!
let loginButton = descendants(sessionsAccountView).first { $0.identifier?.rawValue == "claudeCodeLogin" }!
for (row, claude) in [(1, false), (0, true), (1, false), (0, true)] {
    sessionsTable.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
    sessionsSettings.window!.contentView!.layoutSubtreeIfNeeded()
    let loginRow = loginButton.superview!
    check(loginRow.isHidden == !claude, "Claude Code login row \(claude ? "shows for Claude" : "is hidden for ChatGPT")")
    if claude { check(loginRow.frame.width > 300, "Claude Code login row keeps its width after being hidden") }
}
let sessionsHelpText = descendants(sessionsAccountView).compactMap { $0 as? NSTextField }.first { $0.stringValue.hasPrefix("Sends a tiny message") }!
check(sessionsHelpText.frame.height >= sessionsHelpText.intrinsicContentSize.height - 1, "Sessions help text isn't cut off")
try snapshot(sessionsAccountView, "settings-sessions")
settings.select(sectionNamed: "continue")
check(pages.selectedTabViewItem?.label == "Continue after limits", "the menu's gear opens the continue page")
let continueControls = descendants(pages.tabViewItems[3].view!)
for id in ["keepGoing", "continuePlan", "continueMessage", "answerAway", "awayMinutes", "awayAnswer", "answerTextQuestions"] {
    check(continueControls.contains { $0.identifier?.rawValue == id }, "continue setting \(id) is restored")
}
let planPicker = continueControls.compactMap { $0 as? NSPopUpButton }.first { $0.identifier?.rawValue == "continuePlan" }!
planPicker.selectItem(at: 1)
_ = planPicker.target?.perform(planPicker.action!, with: planPicker)
check(editedConfig.continuePlan == .move && editedConfig.menuBarGridColumns == 3, "the continue plan saves without touching other settings")
let general = descendants(pages.tabViewItems[0].view!).compactMap { $0 as? NSPopUpButton }
check(general.contains { $0.itemTitles.contains("95%") }, "limit notification threshold is restored")
func snapshot(_ view: NSView, _ name: String) throws {
    view.layoutSubtreeIfNeeded()
    let folder = URL(fileURLWithPath: ".build/design-proof")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    if let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let composite = NSImage(size: view.bounds.size)
        composite.lockFocus()
        NSColor.windowBackgroundColor.setFill()
        NSBezierPath(rect: NSRect(origin: .zero, size: view.bounds.size)).fill()
        let overlay = NSImage(size: view.bounds.size)
        overlay.addRepresentation(bitmap)
        overlay.draw(in: NSRect(origin: .zero, size: view.bounds.size), from: .zero, operation: .sourceOver, fraction: 1)
        composite.unlockFocus()
        if let tiff = composite.tiffRepresentation, let opaque = NSBitmapImageRep(data: tiff), let png = opaque.representation(using: .png, properties: [:]) {
            try png.write(to: folder.appendingPathComponent(name + ".png"))
        }
    }
}
settings.window!.appearance = NSAppearance(named: .aqua)
for index in 0...3 {
    if index == 2 { accountTable.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false) }
    pages.selectTabViewItem(at: index)
    try snapshot(settings.window!.contentView!, ["general", "menu-bar", "account", "continue"][index])
}

// Updates install only with the project's own Ed25519 signature (no Apple account).
let testKey = Curve25519.Signing.PrivateKey()
let testPublic = testKey.publicKey.rawRepresentation.base64EncodedString()
let image = Data("LLMCodeBar.dmg bytes".utf8)
let goodSignature = try testKey.signature(for: image).base64EncodedString()
check(Updater.isValidSignature(goodSignature + "\n", for: image, publicKey: testPublic), "a release signed with the key installs")
check(!Updater.isValidSignature(goodSignature, for: image + Data([0]), publicKey: testPublic), "a changed image is refused")
check(!Updater.isValidSignature(goodSignature, for: image), "a release signed with another key is refused")
check(!Updater.isValidSignature("not base64", for: image, publicKey: testPublic), "a garbled signature is refused")
check(Data(base64Encoded: Updater.signingPublicKey)?.count == 32, "the built-in public key is an Ed25519 key")

var gridConfig = AppConfig(launchAtLogin: false, profiles: [profile])
gridConfig.setMenuBarGrid(rows: 3, columns: 3)
for i in 0..<9 { gridConfig.setMenuBar("account-\(i)", shown: true) }
check(gridConfig.menuBarProfileIDList.count == 9, "nine-account grid capacity is preserved")
gridConfig.menuBarResetTimes = .both
gridConfig.menuBarSideBySide = true
gridConfig.showMenuBarLabels = true
let roundTrip = try JSONDecoder().decode(AppConfig.self, from: JSONEncoder().encode(gridConfig))
check(roundTrip.menuBarCapacity == 9 && roundTrip.menuBarResets == .both && roundTrip.menuBarDetailsSideBySide && roundTrip.showsMenuBarLabels, "all recovered menu-bar options persist")

let fixture = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".sqlite")
defer { try? FileManager.default.removeItem(at: fixture) }
var db: OpaquePointer?
sqlite3_open(fixture.path, &db)
let sql = """
CREATE TABLE projection_projects(project_id TEXT, workspace_root TEXT);
CREATE TABLE orchestration_v2_projection_threads(thread_id TEXT, title TEXT, project_id TEXT, payload_json TEXT, updated_at TEXT, deleted_at TEXT, archived_at TEXT);
CREATE TABLE orchestration_v2_projection_messages(message_id TEXT, thread_id TEXT, role TEXT, payload_json TEXT, created_at TEXT, streaming INTEGER);
INSERT INTO projection_projects VALUES('p','/tmp');
INSERT INTO orchestration_v2_projection_threads VALUES('t','Test T3','p','{}','2026-11-13T12:00:00Z',NULL,NULL);
INSERT INTO orchestration_v2_projection_messages VALUES('a','t','user','{"text":"Keep unicode café and requirements","createdAt":"2026-11-13T12:00:00Z"}','2026-11-13T12:00:00Z',0);
INSERT INTO orchestration_v2_projection_messages VALUES('b','t','assistant','{"text":"Completed response"}','2026-11-13T12:01:00Z',0);
INSERT INTO orchestration_v2_projection_messages VALUES('c','t','assistant','{"text":"Partial live reply"}','2026-11-13T12:02:00Z',1);
"""
check(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK, "fixture schema created")
sqlite3_close(db)
let threads = try T3SessionTransfer.threads(database: fixture)
check(threads.count == 1 && threads[0].cwd == "/tmp", "T3 lists local project threads")
let (transcriptID, transcript) = try T3SessionTransfer.transcript(threads[0], database: fixture)
let text = String(data: transcript, encoding: .utf8)!
check(text.contains("café") && text.contains("Completed response") && !text.contains("Partial live reply"), "T3 copies completed conversation text")
check(text.contains("T3 Code"), "T3 provenance is preserved")
// Any conversation can start a T3 thread: the history goes in as its first message.
let handoffFolder = FileManager.default.temporaryDirectory.appendingPathComponent("LLMCodeBar-t3-" + UUID().uuidString)
try FileManager.default.createDirectory(at: handoffFolder, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: handoffFolder) }
let claudeLines = [
    #"{"type":"user","message":{"role":"user","content":"Fix the login bug<system-reminder>ignore me</system-reminder>"},"timestamp":"2026-11-13T12:00:00Z"}"#,
    #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Looking at auth.swift"},{"type":"tool_use","name":"Read","input":{}}]}}"#,
    #"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","content":"file text"}]}}"#,
    #"{"type":"user","isSidechain":true,"message":{"role":"user","content":"side chain"}}"#,
    #"{"type":"user","message":{"role":"user","content":"<command-name>/clear</command-name>"}}"#,
    #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Fixed: the token expired early."}]}}"#,
]
let claudeFile = handoffFolder.appendingPathComponent("s.jsonl")
try claudeLines.joined(separator: "\n").write(to: claudeFile, atomically: true, encoding: .utf8)
let claudeSteps = try T3SessionTransfer.claudeCodeSteps(transcript: claudeFile)
let stepText = claudeSteps.map { step -> String in
    switch step { case let .user(t, _): return "U:" + t; case let .agent(t, _): return "A:" + t; case let .note(t, _): return "N:" + t; case let .command(c, _, _, _): return "C:" + c }
}
check(stepText == ["U:Fix the login bug", "A:Looking at auth.swift", "N:Used Read", "A:Fixed: the token expired early."], "Claude Code transcripts keep what was said, not tool results or injected text: \(stepText)")
let handoff = T3SessionTransfer.Handoff(title: "Login bug", cwd: handoffFolder.path, source: "Claude Code", steps: claudeSteps)
let firstMessage = T3SessionTransfer.handoffMessage(handoff)
check(firstMessage.contains("moved here from Claude Code") && firstMessage.contains("## User\n\nFix the login bug") && firstMessage.contains("Don't change anything yet"), "the T3 thread's first message frames the history")
let long = T3SessionTransfer.Handoff(title: "Long", cwd: handoffFolder.path, source: "Codex",
    steps: [.user("The original ask", nil)] + (0..<400).map { .agent("Reply \($0) " + String(repeating: "x", count: 400), nil) })
let longMessage = T3SessionTransfer.handoffMessage(long)
check(longMessage.utf8.count <= 64_000 && longMessage.contains("The original ask") && longMessage.contains("Reply 399") && longMessage.contains("left out here to fit"), "a long history keeps its first message and its end, under T3's limit")

// The t3 command: a folder T3 doesn't know yet becomes a project, then the thread starts.
let fakeT3 = handoffFolder.appendingPathComponent("t3")
let calls = handoffFolder.appendingPathComponent("calls.txt")
try """
#!/bin/sh
echo "$@" >> '\(calls.path)'
case "$1 $2" in
  "project add") touch '\(handoffFolder.path)/added'; exit 0 ;;
  "thread start")
    cat > '\(handoffFolder.path)/stdin.txt'
    if [ -f '\(handoffFolder.path)/added' ]; then echo '{"threadId":"thread-123"}'; exit 0; fi
    echo "No T3 Code project matches '$3'. Pass a project id or a path inside a project." >&2; exit 1 ;;
esac
exit 3
""".write(to: fakeT3, atomically: true, encoding: .utf8)
try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeT3.path)
let realCLI = T3SessionTransfer.cliPath
T3SessionTransfer.cliPath = fakeT3.path
let started = try T3SessionTransfer.start(handoff)
T3SessionTransfer.cliPath = realCLI
let callLog = try String(contentsOf: calls, encoding: .utf8)
check(started.threadID == "thread-123" && started.projectPath == handoffFolder.path, "the new thread's id comes back")
check(callLog.contains("project add \(handoffFolder.path)") && callLog.contains("--title Login bug --json"), "an unknown folder is added as a T3 project first: \(callLog)")
let sentToT3 = try String(contentsOf: handoffFolder.appendingPathComponent("stdin.txt"), encoding: .utf8)
check(sentToT3 == firstMessage, "the history reaches T3 on stdin, whole")
check(T3SessionTransfer.CLIFailure(message: "connect ECONNREFUSED 127.0.0.1").errorDescription == "T3 Code isn't running. Open it, then try again.", "a closed T3 is explained")

// Validate the real installed schema too, without exporting or changing any account.
let localThreads = FileManager.default.fileExists(atPath: T3SessionTransfer.database.path) ? try T3SessionTransfer.threads() : []
print("Passed: config migration, per-account filters, reset row layout, compact settings, T3 fixture export. Local T3 schema: \(localThreads.count) threads readable.")

let now = Date()
let expiry = now.addingTimeInterval(172800)
let iso = ISO8601DateFormatter().string(from: expiry)
let claudeGrants: [String: Any] = ["cedar_ember": ["eligible": true, "grants": [
    ["type": "full", "resets_left": 1, "ends_at": iso, "paused": false],
    ["type": "full", "resets_left": 2, "ends_at": iso, "gives_back_weekly": true, "label": "Fable launch"],
    ["type": "full", "resets_left": 0, "ends_at": iso],
    ["type": "full", "resets_left": 3, "ends_at": iso, "paused": true],
    ["type": "full", "resets_left": 1, "ends_at": "2020-01-01T00:00:00Z"]
]]]
let grants = ManualResets.claude(claudeGrants, now: now)!
check(grants.availableCount(at: now) == 3 && grants.allowances.count == 2, "manual Claude counts exclude spent, paused, and expired grants")
check(grants.allowances.contains { $0.kind == "Fable" && $0.count == 2 }, "Fable grants stay separate from full resets")
let codexGrants: [String: Any] = ["credits": [
    ["reset_type": "codex_rate_limits", "status": "available", "expires_at": iso],
    ["reset_type": "codex_rate_limits", "status": "redeemed", "expires_at": iso],
    ["reset_type": "codex_rate_limits", "status": "available", "expires_at": NSNull()]
]]
check(ManualResets.codex(codexGrants, now: now)!.availableCount(at: now) == 2, "Codex banked-reset inventory is distinct from quota usage")
let appServerLimits: [String: Any] = [
    "rateLimits": [
        "primary": ["usedPercent": 2, "windowDurationMins": 300, "resetsAt": 1795726170],
        "secondary": ["usedPercent": 84, "windowDurationMins": 10080, "resetsAt": 1795803859],
        "credits": ["hasCredits": false, "unlimited": false, "balance": "0"],
        "planType": "plus",
    ],
    "rateLimitResetCredits": ["availableCount": 2, "credits": [
        ["id": "a", "resetType": "codexRateLimits", "status": "available", "grantedAt": 1, "expiresAt": Int(now.timeIntervalSince1970) + 86400],
        ["id": "b", "resetType": "codexRateLimits", "status": "available", "grantedAt": 1, "expiresAt": NSNull()],
    ]],
]
let reshaped = UsageRefresher.codexUsageJSON(fromAppServer: appServerLimits)
let reshapedLimit = reshaped.usage["rate_limit"] as? [String: Any]
check((reshapedLimit?["primary_window"] as? [String: Any])?["limit_window_seconds"] as? Double == 18000
      && (reshapedLimit?["secondary_window"] as? [String: Any])?["used_percent"] as? Double == 84
      && reshaped.usage["plan_type"] as? String == "plus", "Codex CLI rate limits map onto the usage parser's fields")
check(reshaped.resets.flatMap { ManualResets.codex($0, now: now) }?.availableCount(at: now) == 2, "Codex CLI reset credits are counted")
let dateOnly = ManualResetInventory.dateText(ManualResets.date("2026-11-17T07:59:00Z")!, now: ManualResets.date("2026-11-13T12:00:00Z")!, locale: Locale(identifier: "fr_FR"))
check(dateOnly.contains("17") && dateOnly.contains("nov") && !dateOnly.contains(":") && !dateOnly.contains("2026"), "manual reset dates omit hour and current year")
let chipView = ManualResetView(inventory: grants)
check(chipView.intrinsicContentSize.height < 65, "inline reset chips remain compact")
let chipTexts = descendants(chipView).compactMap { ($0 as? NSTextField)?.stringValue }.joined(separator: " ")
check(chipTexts.contains("Fable ×2") && chipTexts.contains("Full ×1") && !chipTexts.contains("expires"), "chips show type and count without expiry boilerplate")
try snapshot(chipView, "manual-resets")
let threeResets = ManualResetInventory(allowances: (1...3).map {
    ManualResetAllowance(kind: "Full", count: 1, expiresAt: now.addingTimeInterval(Double($0 * 86400)), startsAt: nil)
}, fetchedAt: now)
let threeView = ManualResetView(inventory: threeResets)
let threeText = descendants(threeView).compactMap { ($0 as? NSTextField)?.stringValue }.joined(separator: " ")
check(threeText.contains("Full ×3"), "multiple full resets share one inline chip")
for grant in threeResets.allowances { check(threeText.contains(ManualResetInventory.dateText(grant.expiresAt!)), "every grouped reset deadline stays visible") }

profile.usage?.manualResets = grants
profile.manualResetExpiryAlertHours = 24
let plans = ResetReminder.plans(profile, now: now)
check(plans.count == 2 && plans.allSatisfy { abs($0.delay - 86400) < 2 }, "expiry alerts follow grant deadlines")
profile.usage?.manualResets = nil
check(ResetReminder.plans(profile, now: now).isEmpty, "5h and weekly timers never generate manual reset alerts")

// Gemini / Antigravity: provider naming, quota parsing, cheapest model picking,
// protobuf summary decoding, trajectory step extraction, and handoff framing.
check(Provider.gemini.displayName == "Gemini", "Gemini display name")
check(Provider.named("Gemini") == .gemini && Provider.named("Antigravity") == .gemini, "Gemini and Antigravity resolve to .gemini")

let geminiNow = ISO8601DateFormatter().date(from: "2026-11-23T10:44:46Z")!
let geminiUserStatus: [String: Any] = [
    "userStatus": [
        "name": "Sample User",
        "email": "work97@example.com",
        "planStatus": ["planInfo": ["teamsTier": "TEAMS_TIER_PRO", "planName": "Pro"]],
        "cascadeModelConfigData": [
            "clientModelConfigs": [
                ["label": "Claude Opus 5.5 (High)", "modelOrAlias": ["model": "MODEL_PLACEHOLDER_M402"], "quotaInfo": ["remainingFraction": 1.0]],
                ["label": "Gemini 4 Neon (High)", "modelOrAlias": ["model": "MODEL_PLACEHOLDER_M500"], "quotaInfo": ["remainingFraction": 0.82]],
                ["label": "Gemini 3.8 Flash (High)", "modelOrAlias": ["model": "MODEL_PLACEHOLDER_M318"], "quotaInfo": ["remainingFraction": 0.82]],
                ["label": "Gemini 3.8 Flash (Low)", "modelOrAlias": ["model": "MODEL_PLACEHOLDER_M320"], "quotaInfo": ["remainingFraction": 0.82, "resetTime": "2026-11-23T13:30:25Z"]],
                ["label": "GPT-OSS 120B (Medium)", "modelOrAlias": ["model": "MODEL_OPENAI_GPT_OSS_120B_MEDIUM"], "quotaInfo": ["remainingFraction": 1.0]],
            ],
        ],
    ],
]
let geminiQuotaSummary: [String: Any] = [
    "response": [
        "groups": [
            [
                "displayName": "Gemini Models",
                "buckets": [
                    ["bucketId": "gemini-weekly", "window": "weekly", "remainingFraction": 0.95, "description": "Used 5%", "resetTime": "2026-11-30T08:30:25Z"],
                    ["bucketId": "gemini-5h", "window": "5h", "remainingFraction": 0.82, "description": "Used 18%", "resetTime": "2026-11-23T13:30:25Z"],
                ],
            ],
            [
                "displayName": "Claude and GPT models",
                "buckets": [
                    ["bucketId": "3p-5h", "window": "5h", "remainingFraction": 1.0, "resetTime": "2026-11-23T15:44:46Z"],
                ],
            ],
        ],
    ],
]
let geminiSnap = GeminiLanguageServer.parseUsageSnapshot(userStatusJSON: geminiUserStatus, quotaSummaryJSON: geminiQuotaSummary, now: geminiNow)
check(geminiSnap.account.email == "work97@example.com" && geminiSnap.account.plan == "Pro", "Gemini account & plan parse")
check(geminiSnap.windows.map(\.title) == ["5h", "Week"], "Gemini orders 5h then Week and omits unused 3P bucket: \(geminiSnap.windows.map(\.title))")
check(abs(geminiSnap.windows[0].usedPercent - 18) < 0.01 && geminiSnap.windows[0].resetsAt != nil, "Gemini active 5h usage & reset time parse")
let cheapestGemini = GeminiLanguageServer.cheapestGeminiModels(from: geminiSnap.models)
check(cheapestGemini.first?.id == "MODEL_PLACEHOLDER_M320", "cheapest Gemini model prefers Flash (Low) over Pro/Opus/GPT: \(cheapestGemini.map(\.label))")

// Idle 5h window: remainingFraction == 1, no description, placeholder resetTime == now + 5h -> resetsAt cleared!
let idleSummary: [String: Any] = [
    "response": [
        "groups": [[
            "displayName": "Gemini Models",
            "buckets": [
                ["bucketId": "gemini-5h", "window": "5h", "remainingFraction": 1.0, "resetTime": "2026-11-23T15:44:46Z"],
            ],
        ]],
    ],
]
let idleSnap = GeminiLanguageServer.parseUsageSnapshot(userStatusJSON: geminiUserStatus, quotaSummaryJSON: idleSummary, now: geminiNow)
check(idleSnap.windows.count == 1 && idleSnap.windows[0].resetsAt == nil && idleSnap.windows[0].usedPercent == 0, "idle Gemini 5h placeholder reset time is cleared")

// Trajectory step extraction
let sampleTrajectory: [String: Any] = [
    "steps": [
        ["type": "CORTEX_STEP_TYPE_USER_INPUT", "userInput": ["items": [["text": "Fix the build"]]], "metadata": ["createdAt": "2026-11-23T10:00:00Z"]],
        ["type": "CORTEX_STEP_TYPE_PLANNER_RESPONSE", "plannerResponse": ["response": "Checking build script now."]],
        ["type": "CORTEX_STEP_TYPE_RUN_COMMAND", "runCommand": ["commandLine": "./scripts/build.sh", "combinedOutput": ["full": "Built ok"], "exitCode": 0]],
        ["type": "CORTEX_STEP_TYPE_NOTIFY_USER", "notifyUser": ["notificationContent": "Build passes."]],
    ],
]
let parsedGeminiSteps = GeminiConversationHistory.parseSteps(from: sampleTrajectory)
check(parsedGeminiSteps.count == 4, "Gemini trajectory parses user, planner, command, and notify steps")
let (geminiPrompt, geminiTruncated) = GeminiSessionTransfer.handoffPrompt(title: "Build fix", sourceLabel: "Claude Code", steps: parsedGeminiSteps)
check(!geminiTruncated && geminiPrompt.contains("Fix the build") && geminiPrompt.contains("./scripts/build.sh") && geminiPrompt.contains("Build passes."), "Gemini handoff prompt carries conversation context")

// Validate real local Antigravity summaries if present on this machine.
let localGeminiConversations = GeminiSessionTransfer.conversations()
print("Passed: Gemini quota parsing, cheapest model selection, idle 5h detection, trajectory extraction. Local Antigravity conversations readable: \(localGeminiConversations.count).")

// Mistral / Vibe: provider naming, monthly budget parsing, reset formatting, no 5h session kick,
// and Vibe unified session journal extraction.
check(Provider.mistral.displayName == "Mistral", "Mistral display name")
check(Provider.named("Mistral") == .mistral && Provider.named("Vibe") == .mistral && Provider.named("Le Chat") == .mistral, "Mistral, Vibe and Le Chat resolve to .mistral")

let mistralSessionJSON: [String: Any] = [
    "user": ["id": "user-123", "email": "work97@example.com", "firstName": "Sam", "lastName": "Lee"],
    "organization": ["id": "org-1", "name": "Personal", "orgTier": "B"],
]
let mistralBudgetJSON: [String: Any] = [
    "usage_percentage": 24.5,
    "initial_budget": 20.0,
    "currency": "USD",
    "payg_enabled": false,
    "reset_at": "2026-12-01T00:00:00Z",
]
let mistralSnap = MistralAuthStore.parseUsageSnapshot(
    sessionJSON: mistralSessionJSON,
    budgetJSON: mistralBudgetJSON,
    idTokenClaims: nil,
    whoamiPlan: "INDIVIDUAL",
    whoamiHasPaidVibe: true)
check(mistralSnap.account.email == "work97@example.com" && mistralSnap.account.plan == "Pro", "Mistral account & plan parse")
check(mistralSnap.windows.count == 1 && mistralSnap.windows[0].title == "Month" && mistralSnap.windows[0].isPrimary, "Mistral emits primary Month window")
check(abs(mistralSnap.windows[0].usedPercent - 24.5) < 0.01 && mistralSnap.windows[0].detail == "$4.90 / $20", "Mistral budget percentage and dollar detail parse: \(mistralSnap.windows[0].detail ?? "nil")")
check(QuotaWindowView.shortTitle("Month") == "1m" && ProfileFormatting.windowTitle("Month") == "Monthly", "Month window titles format cleanly")
check(UsageNotifier.watchedWindows.contains("Month"), "UsageNotifier watches Month window")

var mistralProfile = LaunchProfile.pending(provider: .mistral, appPath: MistralAuthStore.defaultAppPath, dataDir: MistralAuthStore.defaultDataDir)
mistralProfile.isPendingLogin = false
mistralProfile.signedIn = true
mistralProfile.usage = UsageInfo(source: "mistral-trpc", status: nil, windows: mistralSnap.windows, creditsRemaining: nil, accountEmail: mistralSnap.account.email, accountPlan: mistralSnap.account.plan, updatedAt: now)
check(!SessionKickstarter.isSessionIdle(mistralProfile), "Mistral monthly budget never triggers 5h session auto-start")
check(mistralProfile.visibleWindows().map(\.title) == ["Month"], "Mistral Month window stays visible")

let sampleVibeJournal: [String] = [
    #"{"type":"projection_delta","payload":{"delta":[{"entry":{"type":"message","id":"m1","role":"user","createdAt":1795432815838,"content":[{"type":"text","text":"<t3_code_instructions>ignored</t3_code_instructions>\nCheck the API limits"}]}}]}}"#,
    #"{"type":"projection_delta","payload":{"delta":[{"entry":{"type":"message","id":"m2","role":"assistant","createdAt":1795432820160,"content":[{"type":"text","text":"Checking billing.budget now."}]}}]}}"#,
    #"{"type":"projection_delta","payload":{"delta":[{"entry":{"type":"message","id":"m2","role":"assistant","createdAt":1795432825000,"content":[{"type":"text","text":"Checking billing.budget now. Done."}]}}]}}"#,
]
let parsedVibeSteps = MistralSessionTransfer.parseJournalLines(sampleVibeJournal)
check(parsedVibeSteps.count == 2, "Vibe journal parser deduplicates updated message IDs and keeps 2 turns: got \(parsedVibeSteps.count)")
if case let .user(uText, _) = parsedVibeSteps[0], case let .agent(aText, _) = parsedVibeSteps[1] {
    check(uText == "Check the API limits" && aText == "Checking billing.budget now. Done.", "Vibe journal strips wrapper tags and keeps final assistant text")
} else {
    check(false, "Vibe journal turn roles mismatch")
}
let localVibeSessions = MistralSessionTransfer.sessions(limit: 20)
print("Passed: Mistral monthly budget parsing, no-5h-kick guard, and Vibe journal extraction. Local Vibe sessions readable: \(localVibeSessions.count).")

if CommandLine.arguments.contains("--test-codex-import") {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("LLMCodeBar-integration-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let home = folder.appendingPathComponent("CodexHome")
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    try Data("{}".utf8).write(to: home.appendingPathComponent("auth.json"))
    var destination = LaunchProfile.pending(provider: .codex, appPath: "/Applications/ChatGPT.app", dataDir: folder.path)
    destination.isPendingLogin = false
    let projectFolder = CodeSessionTransfer.projectsDirectory.appendingPathComponent(ClaudeTranscriptWriter.projectSlug(for: "/tmp"))
    try FileManager.default.createDirectory(at: projectFolder, withIntermediateDirectories: true)

    let transcriptURL = projectFolder.appendingPathComponent(transcriptID + ".jsonl")
    defer { try? FileManager.default.removeItem(at: transcriptURL) }
    try transcript.write(to: transcriptURL)
    let session = CodeSessionTransfer.Session(id: transcriptID, title: "T3 transfer integration test", cwd: "/tmp", fileURL: transcriptURL, transcriptURL: transcriptURL)
    let id = try CodexSessionTransfer.importClaudeSession(session, into: destination)
    check(!id.isEmpty, "Codex importer returns a thread")
    print("Passed: T3-format transcript imported through installed Codex into an isolated test home.")
}
if CommandLine.arguments.contains("--test-gemini-live") {
    let defaultDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Antigravity").path
    var geminiProfile = LaunchProfile.pending(provider: .gemini, appPath: GeminiLanguageServer.defaultAppPath, dataDir: defaultDir)
    geminiProfile.isPendingLogin = false
    let snapshot = try GeminiLanguageServer.fetchUsage(for: geminiProfile)
    check(snapshot.account.email != nil, "live Gemini account email fetched via Antigravity")
    check(!snapshot.windows.isEmpty, "live Gemini quota windows fetched via Antigravity")
    print("Passed live Gemini fetch: \(snapshot.account.email ?? "-") (\(snapshot.account.plan ?? "-")) windows=\(snapshot.windows.map { "\($0.title):\(Int($0.usedPercent.rounded()))%" })")
    if let first = localGeminiConversations.first {
        let history = try GeminiSessionTransfer.readHistory(of: first, from: geminiProfile)
        check(!history.steps.isEmpty, "live Gemini conversation trajectory readable via Antigravity")
        print("Passed live Gemini conversation read: “\(first.displayTitle)” (\(history.steps.count) steps)")
    }
}
if CommandLine.arguments.contains("--test-mistral-live") {
    var profile = LaunchProfile.pending(provider: .mistral, appPath: MistralAuthStore.defaultAppPath, dataDir: MistralAuthStore.defaultDataDir)
    profile.isPendingLogin = false
    let snapshot = try MistralAuthStore.fetchUsage(for: profile, allowKeychain: true)
    check(snapshot.account.email != nil, "live Mistral account email fetched")
    check(!snapshot.windows.isEmpty, "live Mistral monthly budget fetched")
    print("Passed live Mistral fetch: \(snapshot.account.email ?? "-") (\(snapshot.account.plan ?? "-")) windows=\(snapshot.windows.map { "\($0.title):\(Int($0.usedPercent.rounded()))% (\($0.detail ?? "-"))" })")
    if let first = localVibeSessions.first {
        let history = try MistralSessionTransfer.readHistory(of: first)
        check(!history.steps.isEmpty, "live Vibe session journal readable")
        print("Passed live Vibe session read: “\(first.displayTitle)” (\(history.steps.count) steps)")
    }
}
if CommandLine.arguments.contains("--test-cli-usage-live") {
    // Read-only: usage through each provider's own CLI. Nothing is sent to a model.
    let config = ConfigStore.shared.load()
    if let codex = config.profiles.first(where: { $0.provider == .codex }) {
        let response = try CodexSessionTransfer.rateLimits(for: codex)
        let usage = UsageRefresher.codexUsageJSON(fromAppServer: response).usage
        check(usage["rate_limit"] != nil, "live ChatGPT usage read through codex app-server")
        print("Passed live Codex CLI usage: \((usage["rate_limit"] as? [String: Any]).map { "\($0)" } ?? "-")")
    }
    if let mistral = config.profiles.first(where: { $0.provider == .mistral }) {
        let snapshot = MistralAuthStore.fetchUsageThroughCLI(for: mistral)
        check(snapshot != nil && !(snapshot?.windows.isEmpty ?? true), "live Mistral budget read through the Vibe CLI")
        print("Passed live Vibe CLI usage: \(snapshot?.account.plan ?? "-") windows=\(snapshot?.windows.map { "\($0.title):\(Int($0.usedPercent.rounded()))%" } ?? [])")
    }
    for claude in config.profiles where claude.provider == .claude {
        let login = ClaudeCodeCLI.login(for: claude)
        print("Claude Code login for \(claude.accountEmail ?? claude.label): \(login?.displayPath ?? "none (falls back to claude.ai)")")
    }
}
if let index = CommandLine.arguments.firstIndex(of: "--test-claude-code-start"), index + 1 < CommandLine.arguments.count {
    // Sends one "hi" on Haiku with the given Claude Code config folder.
    let dir = CommandLine.arguments[index + 1]
    guard let login = ClaudeCodeCLI.status(configDir: dir) else { fatalError("No Claude subscription login in \(dir)") }
    let model = try ClaudeCodeCLI.sendThrowawayHi(login: login)
    print("Passed Claude Code 5h start: \(login.displayPath) on \(model)")
}
if CommandLine.arguments.contains("--test-codex-start") {
    // Sends one "hi" in an ephemeral Codex thread on the first ChatGPT account.
    let config = ConfigStore.shared.load()
    guard let codex = config.profiles.first(where: { $0.provider == .codex }) else { fatalError("No ChatGPT account") }
    let models = Array(SessionKickstarter.cheapestCodexModels(for: codex).prefix(3))
    let model = try CodexSessionTransfer.sendThrowawayHi(for: codex, models: models)
    print("Passed Codex CLI 5h start on \(model) (candidates: \(models))")
}

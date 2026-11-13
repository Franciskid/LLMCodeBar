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

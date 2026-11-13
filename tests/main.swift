import AppKit
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
let settings = SettingsWindowController(config: AppConfig(launchAtLogin: false, profiles: [profile]), onChange: { _ in }, onCheckForUpdates: { _ in })
settings.window!.contentView!.layoutSubtreeIfNeeded()
check(settings.window!.frame.height < 700, "settings stays compact")
let pages = descendants(settings.window!.contentView!).compactMap { $0 as? NSTabView }.first!
check(pages.tabViewItems.map(\.label) == ["General", "Menu bar", "Account"], "General, menu-bar, and account controls each have a page")
check(pages.selectedTabViewItem?.label == "General", "General opens independently")
pages.selectTabViewItem(at: 1)
settings.window!.contentView!.layoutSubtreeIfNeeded()
let menuControls = descendants(pages.tabViewItems[1].view!)
check(menuControls.contains { $0 is MenuBarGridPicker }, "menu-bar grid picker is preserved")
check(menuControls.contains { ($0 as? NSButton)?.title == "Show a label on each app icon" }, "icon label toggle is preserved")
check(menuControls.contains { ($0 as? NSButton)?.title == "Weekly %" }, "weekly menu-bar setting is preserved")
check(menuControls.compactMap { $0 as? NSPopUpButton }.contains { $0.itemTitles.contains("Side by side") }, "arrangement control is preserved")
pages.selectTabViewItem(at: 2)
settings.window!.contentView!.layoutSubtreeIfNeeded()
check(descendants(pages.tabViewItems[2].view!).contains { ($0 as? NSButton)?.title == "Show automatic reset times" }, "account reset toggle is preserved")
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

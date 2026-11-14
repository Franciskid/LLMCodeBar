import AppKit
import QuartzCore

let app = NSApplication.shared
let status = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
var profile = LaunchProfile.pending(provider: .claude, appPath: "/Applications/Claude.app", dataDir: "/tmp/memory-profile")
profile.usage = UsageInfo(source: "fixture", windows: [UsageWindow(title: "5h", usedPercent: 42, remainingPercent: 58, resetsAt: nil)], updatedAt: Date())
let config = AppConfig(launchAtLogin: false, profiles: [profile])
struct RetiredViews {
    weak var card: ProfileMenuItemView?
    weak var fold: AccountsFoldView?
    weak var panel: ContinuePanelView?
}
var retired: [RetiredViews] = []
var iterations = 0
let timer = Timer.scheduledTimer(withTimeInterval: 0.01, repeats: true) { timer in
    autoreleasepool {
        let card = ProfileMenuItemView(profile: profile, target: app, action: #selector(NSApplication.stop(_:)), isRefreshing: false, isRunning: false, showSparklines: true, inMenuBar: true)
        let motion = MenuMotion()
        let fold = AccountsFoldView(views: [card], motion: motion)
        let panel = ContinuePanelView(enabled: false, sessions: [], defaults: ContinueDefaults(config), handlers: .init(), motion: motion)
        let top = MenuTopView(accounts: fold, panel: panel, motion: motion)
        let menu = NSMenu()
        let item = NSMenuItem()
        item.view = top
        menu.addItem(item)
        status.menu = menu
        retired.append(RetiredViews(card: card, fold: fold, panel: panel))
        iterations += 1
        if iterations >= 100 { timer.invalidate(); status.menu = nil }
    }
}
while timer.isValid { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
RunLoop.main.run(until: Date().addingTimeInterval(0.5))
let cards = retired.filter { $0.card != nil }.count
let folds = retired.filter { $0.fold != nil }.count
let panels = retired.filter { $0.panel != nil }.count
print("After 100 menu replacements: \(cards) cards, \(folds) folds, \(panels) panels retained")
NSStatusBar.system.removeStatusItem(status)
precondition(cards == 0 && folds == 0 && panels == 0, "Retired menu views must be released")

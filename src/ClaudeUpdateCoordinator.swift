import AppKit

/// Finishes the Claude update that a second Claude window makes impossible.
///
/// Claude updates itself with Squirrel. When a release is staged the app starts
/// `ShipIt`, which waits - through `runningApplicationsWithBundleIdentifier:` - for
/// *every* process of the Claude bundle id to exit before it touches the bundle in
/// /Applications. One window quitting is not enough, because the other windows are the
/// same bundle id. ShipIt then waits indefinitely (there is no timeout; a stuck one can
/// sit there for weeks) and the install never begins.
///
/// Claude's own handling of that is worse than a no-op. It quits a window to clear the
/// way, comes back on the old version, and records the failure per data directory as
/// `updaterFailedInstall`, retrying twice per release. So every Claude release costs
/// each window up to two unannounced quits - mid-conversation, with no warning - and
/// the update still doesn't land.
///
/// Running several windows off one bundle is this app's doing, so finishing the update
/// is this app's job: quit every Claude window at a moment the user chose, let the
/// waiting ShipIt do the swap, then open every window again.
enum ClaudeUpdateCoordinator {
    /// How recently a transcript must have been written for its session to count as
    /// mid-turn.
    private static let workingWithin: TimeInterval = 90
    /// How long a window gets to quit on its own before we give up and put things back.
    private static let quitTimeout: TimeInterval = 30
    /// How long ShipIt gets to swap the bundle once the last window is gone.
    private static let installTimeout: TimeInterval = 180

    /// A release sitting on disk with a ShipIt already waiting to install it.
    struct StagedUpdate {
        let version: String
        let installedVersion: String
        let shipIt: pid_t
    }

    /// What a window's sessions are up to. `unknown` is a real answer and not a
    /// stand-in for idle: a session started fresh carries no `--resume`, so there is no
    /// id to look its transcript up by, and saying "idle" about it would be a guess
    /// dressed up as a fact right where the user is deciding what to close.
    enum Activity {
        case working
        case idle
        case unknown
    }

    /// A running Claude window that has to close for the swap to happen.
    struct Window {
        let profile: LaunchProfile
        let app: NSRunningApplication
        /// Claude Code sessions running in this window.
        let sessions: Int
        let activity: Activity

        var isWorking: Bool { activity == .working }
    }

    struct Plan {
        let update: StagedUpdate
        let windows: [Window]

        var sessions: Int { windows.reduce(0) { $0 + $1.sessions } }
        var working: [Window] { windows.filter(\.isWorking) }
        /// Nothing is running in any window, so this is a free moment to offer it.
        var isQuiet: Bool { sessions == 0 }
    }

    // MARK: Working out whether there is anything to do

    /// The windows that would have to close, and the update that would land if they did.
    /// `nil` whenever there is nothing staged, nothing waiting to install it, or no
    /// Claude window open - in which case there is nothing for us to coordinate.
    static func plan(for profiles: [LaunchProfile]) -> Plan? {
        let claude = profiles.filter { $0.provider == .claude }
        guard let appPath = claude.first.map({ Launcher.expanding($0.appPath) }) else { return nil }

        let processes = ProcessTable()
        guard let update = stagedUpdate(appPath: appPath, processes: processes) else { return nil }

        let running = RunningProfileDetector.snapshot(claude)
        guard !running.isEmpty else { return nil }

        let transcripts = Transcripts()
        let windows: [Window] = claude.compactMap { profile in
            guard let app = running[profile.id] else { return nil }
            let found = sessions(of: app, processes: processes, transcripts: transcripts)
            return Window(profile: profile, app: app, sessions: found.count, activity: found.activity)
        }
        guard !windows.isEmpty else { return nil }
        return Plan(update: update, windows: windows)
    }

    /// Squirrel keeps one state file per app, named after its ShipIt job label. It names
    /// the bundle it is going to replace and the one it will put there - but a staged
    /// bundle on its own installs nothing, so a ShipIt actually sitting there waiting is
    /// part of what makes this real.
    private static func stagedUpdate(appPath: String, processes: ProcessTable) -> StagedUpdate? {
        guard let bundleID = Launcher.bundleIdentifier(for: appPath),
              let installed = version(ofBundleAt: appPath) else { return nil }

        let state = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/\(bundleID).ShipIt/ShipItState.plist")
        guard let fields = readState(at: state),
              let target = (fields["targetBundleURL"] as? String).flatMap(URL.init(string:)),
              // Only ever act on an install aimed at the bundle our windows run from.
              standardized(target.path) == standardized(appPath),
              let staged = (fields["updateBundleURL"] as? String).flatMap(URL.init(string:)),
              let stagedVersion = version(ofBundleAt: staged.path),
              stagedVersion != installed,
              let shipIt = waitingShipIt(label: "\(bundleID).ShipIt", processes: processes)
        else { return nil }

        return StagedUpdate(version: stagedVersion, installedVersion: installed, shipIt: shipIt)
    }

    /// Named `.plist`, but current Squirrel writes JSON into it. Read it either way
    /// rather than depending on which one this build of Claude shipped with.
    private static func readState(at url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] { return json }
        return (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
    }

    /// The ShipIt waiting on *our* app, told apart from other apps' stuck ShipIts by the
    /// job label it was started with - several of them sit in the process table at once.
    private static func waitingShipIt(label: String, processes: ProcessTable) -> pid_t? {
        for pid in processes.allPIDs {
            guard let arguments = ProcessArguments.arguments(forPID: pid),
                  let executable = arguments.first,
                  executable.hasSuffix("/Squirrel.framework/Resources/ShipIt"),
                  arguments.dropFirst().contains(label) else { continue }
            return pid
        }
        return nil
    }

    // MARK: What is running in a window

    /// The Claude Code sessions running in one window, and whether any is mid-turn.
    ///
    /// The sessions are the window's own child processes, so which window owns one is
    /// never a guess - unlike anything based on paths or environments, which every
    /// child inherits. Whether a session is *working* comes from its transcript: Claude
    /// Code appends to `~/.claude/projects/<slug>/<id>.jsonl` as the turn runs, so a
    /// file written seconds ago means a turn in flight. CPU would not answer it - a
    /// session waiting on the model sits at practically zero.
    ///
    /// A session started fresh carries no `--resume`, so there is no id to look up; that
    /// window reports `unknown` rather than being called idle. Either way the count is
    /// exact, and the count is the thing the user is shown before anything closes.
    private static func sessions(of app: NSRunningApplication, processes: ProcessTable, transcripts: Transcripts) -> (count: Int, activity: Activity) {
        var count = 0
        var working = false
        var unmapped = false
        // Claude wraps each session in a `disclaimer` helper, so the CLI itself is a
        // grandchild of the window.
        for pid in processes.descendants(of: app.processIdentifier, depth: 2) {
            guard let arguments = ProcessArguments.arguments(forPID: pid),
                  let executable = arguments.first,
                  executable.contains("/claude-code/"),
                  executable.hasSuffix("/claude") else { continue }
            count += 1
            guard let session = resumedSession(in: arguments),
                  let written = transcripts.lastWrite(forSession: session) else {
                unmapped = true
                continue
            }
            if Date().timeIntervalSince(written) < workingWithin { working = true }
        }

        if working { return (count, .working) }
        if unmapped { return (count, .unknown) }
        return (count, .idle)
    }

    /// Accepts either the `--resume=<id>` or the space-separated spelling.
    private static func resumedSession(in arguments: [String]) -> String? {
        let flag = "--resume"
        for (index, argument) in arguments.enumerated() {
            if argument.hasPrefix("\(flag)=") {
                return String(argument.dropFirst(flag.count + 1))
            }
            if argument == flag, arguments.indices.contains(index + 1) {
                return arguments[index + 1]
            }
        }
        return nil
    }

    /// Finds a session's transcript without walking every project folder's contents:
    /// the folders are listed once, then a session id is one `stat` per folder.
    private struct Transcripts {
        private let folders: [URL]

        init() {
            let root = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".claude/projects", isDirectory: true)
            let found = (try? FileManager.default.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles])) ?? []
            folders = found.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
        }

        func lastWrite(forSession id: String) -> Date? {
            for folder in folders {
                let file = folder.appendingPathComponent("\(id).jsonl")
                if let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate {
                    return modified
                }
            }
            return nil
        }
    }

    // MARK: Doing it

    enum Outcome {
        /// The bundle was swapped and every window is open again.
        case installed(version: String)
        /// A window would not close, so the update was left alone. Anything that did
        /// close has been opened again.
        case windowRefused(String)
        /// Windows closed and reopened, but the swap didn't happen.
        case notInstalled
    }

    /// Quits every window in the plan, waits for ShipIt to swap the bundle, then opens
    /// them all again.
    ///
    /// Nothing here is forced. Windows get an ordinary quit, so Claude runs its own
    /// shutdown and its sessions end up on disk the way they would any other time.
    ///
    /// Both ways this can go wrong end with the user's windows back: a window that
    /// refuses to close leaves the update alone and reopens the ones that did close,
    /// and a swap that never happens reopens everything anyway. The one outcome never
    /// worth leaving behind is no windows at all.
    static func apply(_ plan: Plan, progress: @escaping (String) -> Void, completion: @escaping (Outcome) -> Void) {
        let appPath = Launcher.expanding(plan.windows[0].profile.appPath)
        let wanted = plan.update.version
        let report = { (text: String) in DispatchQueue.main.async { progress(text) } }
        let finish = { (outcome: Outcome) in DispatchQueue.main.async { completion(outcome) } }

        report("Closing \(plan.windows.count == 1 ? "1 window" : "\(plan.windows.count) windows")...")
        DispatchQueue.main.async {
            for window in plan.windows { window.app.terminate() }
        }

        DispatchQueue.global(qos: .userInitiated).async {
            if let stubborn = waitForQuit(plan.windows) {
                // The others were asked to quit at the same time and some will have
                // gone, so put those back: one window that won't close must never cost
                // the user the ones that did.
                report("Reopening...")
                relaunch(plan.windows.filter(\.app.isTerminated).map(\.profile))
                finish(.windowRefused(ProfileFormatting.title(for: stubborn.profile)))
                return
            }

            report("Installing Claude \(wanted)...")
            let installed = waitForInstall(appPath: appPath, version: wanted)

            report("Reopening...")
            relaunch(plan.windows.map(\.profile))
            finish(installed ? .installed(version: wanted) : .notInstalled)
        }
    }

    /// Returns the first window that was still up when we ran out of patience.
    private static func waitForQuit(_ windows: [Window]) -> Window? {
        let deadline = Date().addingTimeInterval(quitTimeout)
        while Date() < deadline {
            if windows.allSatisfy(\.app.isTerminated) { return nil }
            Thread.sleep(forTimeInterval: 0.25)
        }
        return windows.first { !$0.app.isTerminated }
    }

    /// ShipIt only starts once the last window is gone, and the swap itself takes a
    /// moment, so watch the bundle rather than the clock. Read the Info.plist straight
    /// from disk each time - `Bundle` caches what it read, which would hide the swap.
    private static func waitForInstall(appPath: String, version wanted: String) -> Bool {
        let deadline = Date().addingTimeInterval(installTimeout)
        while Date() < deadline {
            if version(ofBundleAt: appPath) == wanted { return true }
            Thread.sleep(forTimeInterval: 0.5)
        }
        return false
    }

    /// Opened one at a time: two Claude instances starting together race over the
    /// bundle's shared state, and the first one up is the one that claims `claude://`.
    private static func relaunch(_ profiles: [LaunchProfile]) {
        for (index, profile) in profiles.enumerated() {
            if index > 0 { Thread.sleep(forTimeInterval: 3) }
            DispatchQueue.main.async { try? Launcher.launch(profile) }
        }
    }

    // MARK: Small shared helpers

    private static func version(ofBundleAt path: String) -> String? {
        let info = URL(fileURLWithPath: path, isDirectory: true)
            .appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: info),
              let fields = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
        else { return nil }
        return fields["CFBundleShortVersionString"] as? String
    }

    private static func standardized(_ path: String) -> String {
        URL(fileURLWithPath: Launcher.expanding(path)).standardizedFileURL.path
    }
}

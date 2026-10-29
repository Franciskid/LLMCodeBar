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
/// Claude's own handling of that is worse than a no-op. Once a window has sat idle and
/// out of focus for ten minutes it quits it to install, expecting to come straight back
/// on the new version - and with another window open nothing brings it back at all. It
/// records the failure per data directory as `updaterFailedInstall` and tries twice per
/// release, so every Claude release can cost each window two disappearances that last
/// until someone notices, and the update still doesn't land.
///
/// Running several windows off one bundle is this app's doing, so finishing the update
/// is this app's job: quit every Claude window at a moment the user chose, let the
/// waiting ShipIt do the swap, then open every window again. Until then, put back any
/// window Claude closes for it, and use Claude's own failure count to stop it happening
/// twice.
enum ClaudeUpdateCoordinator {
    /// How recently a transcript must have been written for its session to count as
    /// mid-turn.
    private static let workingWithin: TimeInterval = 90
    /// How long a window gets to quit on its own before we give up and put things back.
    private static let quitTimeout: TimeInterval = 30
    /// How long ShipIt gets to swap the bundle once the last window is gone.
    private static let installTimeout: TimeInterval = 180
    /// How long ShipIt gets to finish up after the swap - opening Claude itself, when the
    /// update asked it to - before we look at what it left running.
    private static let installerExitTimeout: TimeInterval = 30

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
        /// Asked of the kernel - see `processIsGone`.
        var hasQuit: Bool { ClaudeUpdateCoordinator.processIsGone(app.processIdentifier) }
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
    ///
    /// Nor one window too many: ShipIt can open Claude itself once it's done, and that
    /// window only stays when it's one the user had.
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
                relaunch(plan.windows.filter(\.hasQuit).map(\.profile))
                finish(.windowRefused(ProfileFormatting.title(for: stubborn.profile)))
                return
            }

            report("Installing Claude \(wanted)...")
            let installed = waitForInstall(appPath: appPath, version: wanted)
            if installed {
                // ShipIt may open Claude itself on its way out, so let it finish before
                // judging which windows are ours.
                waitForExit(plan.update.shipIt, timeout: installerExitTimeout)
                closeInstallerWindow(keeping: plan.windows.map(\.profile), appPath: appPath)
            }

            report("Reopening...")
            relaunch(plan.windows.map(\.profile))
            finish(installed ? .installed(version: wanted) : .notInstalled)
        }
    }

    /// Returns the first window that was still up when we ran out of patience.
    private static func waitForQuit(_ windows: [Window]) -> Window? {
        let deadline = Date().addingTimeInterval(quitTimeout)
        while Date() < deadline {
            if windows.allSatisfy(\.hasQuit) { return nil }
            Thread.sleep(forTimeInterval: 0.25)
        }
        return windows.first { !$0.hasQuit }
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

    /// What ShipIt leaves behind. When the update was staged with
    /// `launchAfterInstallation` it opens Claude once the swap is done - plainly, with no
    /// `--user-data-dir`, so into the default data directory whether or not that was one
    /// of the windows we closed. When it was, that window already is one of the user's
    /// and `relaunch` just brings it forward. When it wasn't, it's a window they never
    /// had open, so close it - but only while it's empty: anything with a session in it
    /// stays.
    private static func closeInstallerWindow(keeping profiles: [LaunchProfile], appPath: String) {
        guard let bundleID = Launcher.bundleIdentifier(for: appPath) else { return }
        let ours = Set(profiles.map { standardized($0.dataDir) })
        // ShipIt is gone by now, but the app it opened can take a moment to register.
        Thread.sleep(forTimeInterval: 2)
        let processes = ProcessTable()
        let transcripts = Transcripts()
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: bundleID) {
            let pid = app.processIdentifier
            guard pid > 0, !processIsGone(pid),
                  let dataDir = RunningProfileDetector.dataDir(of: app, appPath: appPath, processes: processes),
                  !ours.contains(dataDir),
                  sessions(of: app, processes: processes, transcripts: transcripts).count == 0
            else { continue }
            DispatchQueue.main.async { app.terminate() }
        }
    }

    /// Bounded, because a ShipIt that hangs after installing isn't worth holding the
    /// user's windows back for.
    private static func waitForExit(_ pid: pid_t, timeout: TimeInterval) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline, !processIsGone(pid) {
            Thread.sleep(forTimeInterval: 0.25)
        }
    }

    // MARK: Windows Claude closes by itself

    /// How long after Claude closes a window for an update it still counts as one to put
    /// back. Past that the user has had time to notice it's gone and leave it that way.
    private static let reopenWithin: TimeInterval = 10 * 60

    /// A window Claude closed to install an update that can't install.
    struct StrandedWindow {
        let profile: LaunchProfile
        /// When Claude closed it, from its own marker - so one closing gets one reopen.
        let closedAt: TimeInterval
    }

    /// Windows Claude closed by itself for an update that can't land, and that update.
    ///
    /// Before its update quit Claude writes `stealth-relaunch` into the window's data
    /// directory, to pick up where it was once it's back. An ordinary quit writes the same
    /// file marked `navOnly`, plus `userQuit` when it was the user's, so a window someone
    /// closed on purpose never shows up here. The next launch consumes the file either way.
    ///
    /// Stranded only while there's a plan: the update is staged, its ShipIt waiting, and
    /// another Claude window still up - so the install can't start and nothing else will
    /// reopen it. With every window gone it's ShipIt's turn, and we stay out of its way.
    static func strandedWindows(in profiles: [LaunchProfile]) -> (update: StagedUpdate, windows: [StrandedWindow])? {
        guard let plan = plan(for: profiles) else { return nil }
        let open = Set(plan.windows.map(\.profile.id))
        let stranded: [StrandedWindow] = profiles.compactMap { profile in
            guard profile.provider == .claude, !open.contains(profile.id),
                  let closedAt = closedForUpdate(dataDir: profile.dataDir) else { return nil }
            return StrandedWindow(profile: profile, closedAt: closedAt)
        }
        return stranded.isEmpty ? nil : (plan.update, stranded)
    }

    /// When Claude closed this data directory's window for an update, if it did lately.
    private static func closedForUpdate(dataDir: String) -> TimeInterval? {
        let marker = URL(fileURLWithPath: Launcher.expanding(dataDir), isDirectory: true)
            .appendingPathComponent("stealth-relaunch")
        guard let data = try? Data(contentsOf: marker),
              let fields = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              fields["navOnly"] as? Bool != true,
              fields["userQuit"] as? Bool != true,
              let milliseconds = fields["ts"] as? Double else { return nil }
        let closedAt = milliseconds / 1000
        let age = Date().timeIntervalSince1970 - closedAt
        return age >= 0 && age < reopenWithin ? closedAt : nil
    }

    /// Tells Claude, while this window is closed, that the update has already failed to
    /// install for it once.
    ///
    /// Claude counts failed installs per data directory and stops closing a window for a
    /// release once the count reaches two. It adds one itself when the window opens again,
    /// so recording the first here makes this closing the only one instead of the first of
    /// two. A count Claude already keeps for this release is left alone.
    ///
    /// Only while the window is closed: Claude reads this once at launch, keeps its own
    /// copy, and rewrites the file as it goes. The file also holds Claude's sign-in, so
    /// it's replaced whole and keeps its permissions.
    static func recordFailedInstall(_ update: StagedUpdate, for profile: LaunchProfile) {
        guard !RunningProfileDetector.isRunning(profile),
              let target = releaseNumber(update.version) else { return }
        let file = URL(fileURLWithPath: Launcher.expanding(profile.dataDir), isDirectory: true)
            .appendingPathComponent("config.json")
        guard let data = try? Data(contentsOf: file),
              var settings = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }

        if let counted = settings["updaterFailedInstall"] as? [String: Any],
           counted["appVersion"] as? String == update.installedVersion,
           counted["targetVersion"] as? String == target,
           counted["attempts"] as? Int ?? 0 >= 1 { return }

        settings["updaterFailedInstall"] = ["appVersion": update.installedVersion, "targetVersion": target, "attempts": 1]
        guard let updated = try? JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .withoutEscapingSlashes]) else { return }
        replace(file, with: updated)
    }

    /// Claude keys its failure count by the bare `x.y.z` in a version.
    private static func releaseNumber(_ version: String) -> String? {
        version.range(of: #"\d+\.\d+\.\d+"#, options: .regularExpression).map { String(version[$0]) }
    }

    /// Written beside the file and renamed over it, so a failure halfway leaves the old
    /// one, and created with the old one's permissions instead of wider ones for a moment.
    private static func replace(_ file: URL, with data: Data) {
        let mode = ((try? FileManager.default.attributesOfItem(atPath: file.path))?[.posixPermissions] as? NSNumber)?.uint16Value ?? 0o600
        let temporary = file.deletingLastPathComponent().appendingPathComponent(".\(file.lastPathComponent).llmcodebar")
        unlink(temporary.path)
        let descriptor = Darwin.open(temporary.path, O_WRONLY | O_CREAT | O_EXCL, mode_t(mode))
        guard descriptor >= 0 else { return }
        let written = data.withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress, $0.count) }
        let flushed = fsync(descriptor) == 0
        Darwin.close(descriptor)
        guard written == data.count, flushed, rename(temporary.path, file.path) == 0 else {
            unlink(temporary.path)
            return
        }
    }

    // MARK: Small shared helpers

    /// Whether a process has exited, asked of the kernel. `NSRunningApplication.isTerminated`
    /// only changes when the main run loop delivers the news - measured to stay false for
    /// good without one - and a quit nobody notices turns into "that window refused" and
    /// reopens nothing.
    private static func processIsGone(_ pid: pid_t) -> Bool {
        kill(pid, 0) != 0 && errno == ESRCH
    }

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

import AppKit

/// A published build on the project's GitHub releases page.
struct AppRelease {
    var version: String
    var tag: String
    var downloadURL: URL
    var notes: String?
}

/// A downloaded release, mounted and checked over, ready to be swapped in.
struct StagedUpdate {
    var release: AppRelease
    /// The `.app` inside the mounted disk image.
    var sourceApp: String
    var mountPoint: String
    var imagePath: String
    /// The bundle it will replace - the one we're running from.
    var destination: String
}

enum UpdateError: LocalizedError {
    case checkFailed(Int)
    case malformedRelease
    case noDownloadableAsset(String)
    case downloadFailed(Int)
    case mountFailed
    case appMissingFromImage
    case unexpectedBundle(String)
    case versionMismatch(expected: String, found: String)
    case destinationNotWritable(String)

    var errorDescription: String? {
        switch self {
        case .checkFailed(let status):
            return "GitHub returned HTTP \(status) when checking for updates."
        case .malformedRelease:
            return "Could not read the latest release from GitHub."
        case .noDownloadableAsset(let tag):
            return "Release \(tag) has no .dmg to download."
        case .downloadFailed(let status):
            return "Downloading the update failed with HTTP \(status)."
        case .mountFailed:
            return "Could not mount the downloaded disk image."
        case .appMissingFromImage:
            return "The downloaded disk image has no LLMCodeBar.app in it."
        case .unexpectedBundle(let identifier):
            return "The downloaded app has bundle id \(identifier), which isn't LLMCodeBar."
        case .versionMismatch(let expected, let found):
            return "The release says \(expected) but the app inside is \(found)."
        case .destinationNotWritable(let path):
            return "No permission to replace \(path). Move LLMCodeBar to /Applications, or update it by hand."
        }
    }
}

/// Keeps the app current with the latest GitHub release: check the newest tag,
/// download its disk image, swap the installed bundle, and relaunch.
///
/// The swap runs from a detached shell script rather than in-process, because the
/// bundle being replaced is the one we're executing from. The script waits for this
/// process to exit, copies the new app off the image into a staging path, and only
/// then moves it into place - so a download or copy that fails leaves the working
/// installation exactly where it was.
enum Updater {
    static let repository = "Franciskid/LLMCodeBar"

    static var currentVersion: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "0.0.0"
    }

    /// How long to leave between background checks.
    static let checkInterval: TimeInterval = 6 * 60 * 60

    // MARK: Checking

    /// The newest release when it's newer than this build, otherwise nil.
    static func availableUpdate() throws -> AppRelease? {
        let release = try latestRelease()
        return isNewer(release.version, than: currentVersion) ? release : nil
    }

    static func latestRelease() throws -> AppRelease {
        guard let url = URL(string: "https://api.github.com/repos/\(repository)/releases/latest") else {
            throw UpdateError.malformedRelease
        }
        let response = try SimpleHTTP.get(url, headers: [
            "Accept": "application/vnd.github+json",
            // GitHub rejects API requests that don't identify themselves.
            "User-Agent": "LLMCodeBar/\(currentVersion)"
        ], timeout: 20)

        guard response.statusCode == 200 else { throw UpdateError.checkFailed(response.statusCode) }
        guard let json = try? JSONSerialization.jsonObject(with: response.data) as? [String: Any],
              let tag = json["tag_name"] as? String else {
            throw UpdateError.malformedRelease
        }

        let assets = json["assets"] as? [[String: Any]] ?? []
        let image = assets.first { ($0["name"] as? String)?.lowercased().hasSuffix(".dmg") == true }
        guard let urlString = image?["browser_download_url"] as? String,
              let downloadURL = URL(string: urlString) else {
            throw UpdateError.noDownloadableAsset(tag)
        }

        let notes = (json["body"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return AppRelease(version: normalizedVersion(tag), tag: tag, downloadURL: downloadURL, notes: notes)
    }

    // MARK: Installing

    /// Downloads and mounts a release, checking it really is a newer LLMCodeBar and
    /// that we can write over the installed copy. Everything that can fail happens
    /// here, while the app is still running normally and can report an error.
    static func stage(_ release: AppRelease) throws -> StagedUpdate {
        let response = try SimpleHTTP.get(release.downloadURL, headers: [
            "Accept": "application/octet-stream",
            "User-Agent": "LLMCodeBar/\(currentVersion)"
        ], timeout: 300)
        guard response.statusCode == 200, !response.data.isEmpty else {
            throw UpdateError.downloadFailed(response.statusCode)
        }

        let imagePath = FileManager.default.temporaryDirectory
            .appendingPathComponent("LLMCodeBar-\(release.version)-\(UUID().uuidString.prefix(8)).dmg")
        try response.data.write(to: imagePath, options: .atomic)

        let mountPoint: String
        do {
            mountPoint = try mount(imagePath.path)
        } catch {
            try? FileManager.default.removeItem(at: imagePath)
            throw error
        }

        do {
            let sourceApp = try validatedApp(inMount: mountPoint, expecting: release.version)
            let destination = Bundle.main.bundlePath
            let parent = (destination as NSString).deletingLastPathComponent
            guard FileManager.default.isWritableFile(atPath: parent) else {
                throw UpdateError.destinationNotWritable(destination)
            }
            return StagedUpdate(
                release: release,
                sourceApp: sourceApp,
                mountPoint: mountPoint,
                imagePath: imagePath.path,
                destination: destination)
        } catch {
            unmount(mountPoint)
            try? FileManager.default.removeItem(at: imagePath)
            throw error
        }
    }

    /// Hands the swap to a detached script and returns. The caller quits immediately
    /// afterwards; the script waits for that before touching anything.
    static func install(_ staged: StagedUpdate) throws {
        let scriptPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("llmcodebar-update-\(UUID().uuidString.prefix(8)).sh")
        try swapScript(for: staged).write(to: scriptPath, atomically: true, encoding: .utf8)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [scriptPath.path]
        try process.run()
    }

    /// Throws away a staged update we've decided not to install.
    static func discard(_ staged: StagedUpdate) {
        unmount(staged.mountPoint)
        try? FileManager.default.removeItem(atPath: staged.imagePath)
    }

    private static func swapScript(for staged: StagedUpdate) -> String {
        """
        #!/bin/sh
        # Replaces the installed LLMCodeBar with a freshly downloaded one and relaunches
        # it. Started by the app itself, which quits right after - so the first thing
        # here is to wait for that process to go away.
        set -u

        PID=\(quoted(String(ProcessInfo.processInfo.processIdentifier)))
        SRC=\(quoted(staged.sourceApp))
        DEST=\(quoted(staged.destination))
        MOUNT=\(quoted(staged.mountPoint))
        DMG=\(quoted(staged.imagePath))
        STAGING="$DEST.staging-$$"
        BACKUP="$DEST.previous-$$"

        cleanup() {
          /usr/bin/hdiutil detach -quiet -force "$MOUNT" >/dev/null 2>&1
          /bin/rm -f "$DMG"
          /bin/rm -rf "$STAGING"
        }

        waited=0
        while /bin/kill -0 "$PID" 2>/dev/null && [ "$waited" -lt 200 ]; do
          /bin/sleep 0.1
          waited=$((waited + 1))
        done

        # Copy off the image first: if this fails, the installed app is still untouched.
        /bin/rm -rf "$STAGING"
        if ! /usr/bin/ditto "$SRC" "$STAGING"; then
          cleanup
          /usr/bin/open "$DEST"
          exit 1
        fi

        /bin/rm -rf "$BACKUP"
        /bin/mv "$DEST" "$BACKUP" 2>/dev/null
        if ! /bin/mv "$STAGING" "$DEST"; then
          # Put the old one back rather than leaving nothing installed.
          [ -d "$BACKUP" ] && /bin/mv "$BACKUP" "$DEST"
          cleanup
          /usr/bin/open "$DEST"
          exit 1
        fi

        /bin/rm -rf "$BACKUP"
        /usr/bin/xattr -dr com.apple.quarantine "$DEST" >/dev/null 2>&1
        cleanup
        /usr/bin/open "$DEST"
        /bin/rm -f "$0"
        """
    }

    // MARK: Disk image handling

    private static func mount(_ imagePath: String) throws -> String {
        let output = try ProcessRunner.run(
            "/usr/bin/hdiutil",
            arguments: ["attach", imagePath, "-nobrowse", "-readonly", "-noverify", "-plist"],
            timeout: 120)

        guard let data = output.data(using: .utf8),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let entities = plist["system-entities"] as? [[String: Any]],
              let mountPoint = entities.compactMap({ $0["mount-point"] as? String }).first else {
            throw UpdateError.mountFailed
        }
        return mountPoint
    }

    private static func unmount(_ mountPoint: String) {
        _ = try? ProcessRunner.run(
            "/usr/bin/hdiutil",
            arguments: ["detach", mountPoint, "-quiet", "-force"],
            timeout: 60)
    }

    /// Makes sure the image really contains the LLMCodeBar we expect, so a mislabelled
    /// or swapped-out asset can't be installed over the running app.
    private static func validatedApp(inMount mountPoint: String, expecting version: String) throws -> String {
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: mountPoint)) ?? []
        guard let name = contents.first(where: { $0.hasSuffix(".app") }) else {
            throw UpdateError.appMissingFromImage
        }
        let appPath = (mountPoint as NSString).appendingPathComponent(name)

        guard let bundle = Bundle(path: appPath), let identifier = bundle.bundleIdentifier else {
            throw UpdateError.appMissingFromImage
        }
        guard identifier == Bundle.main.bundleIdentifier else {
            throw UpdateError.unexpectedBundle(identifier)
        }
        let found = (bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? ""
        guard normalizedVersion(found) == version else {
            throw UpdateError.versionMismatch(expected: version, found: found.isEmpty ? "unknown" : found)
        }
        return appPath
    }

    // MARK: Versions

    static func isNewer(_ candidate: String, than current: String) -> Bool {
        let left = numbers(in: candidate)
        let right = numbers(in: current)
        for index in 0..<max(left.count, right.count) {
            let a = index < left.count ? left[index] : 0
            let b = index < right.count ? right[index] : 0
            if a != b { return a > b }
        }
        return false
    }

    /// "v0.3.0" and "0.3.0" are the same release.
    static func normalizedVersion(_ tag: String) -> String {
        numbers(in: tag).map(String.init).joined(separator: ".")
    }

    private static func numbers(in version: String) -> [Int] {
        version
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .drop { $0 == "v" || $0 == "V" }
            .split(separator: ".")
            .map { Int($0.prefix(while: \.isNumber)) ?? 0 }
    }

    private static func quoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

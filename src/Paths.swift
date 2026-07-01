import Foundation

final class Paths {
    static let shared = Paths()

    let appSupport: URL
    let configURL: URL
    let historyURL: URL
    let profilesURL: URL
    let launchAgentURL: URL

    private init() {
        let fm = FileManager.default
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        appSupport = support.appendingPathComponent("LLM Usage Bar", isDirectory: true)
        configURL = appSupport.appendingPathComponent("config.json")
        historyURL = appSupport.appendingPathComponent("usage_events.json")
        profilesURL = appSupport.appendingPathComponent("Profiles", isDirectory: true)
        launchAgentURL = fm.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/fr.fraserv.llmusagebar.plist")
    }

    func ensureSupportDirectory() {
        try? FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: profilesURL, withIntermediateDirectories: true)
    }
}


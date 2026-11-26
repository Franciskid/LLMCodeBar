import Foundation
import Security
import SQLite3

/// Who a Gemini / Antigravity account is signed in as, as reported by Antigravity's
/// own language server (`GetUserStatus`) or cached locally.
struct GeminiAccountInfo: Codable, Equatable {
    var email: String?
    var name: String?
    var plan: String?
}

/// One model entry returned by Antigravity's `GetUserStatus`.
struct GeminiQuotaModel: Equatable {
    var id: String
    var label: String
    var remainingFraction: Double?
    var resetsAt: Date?
}

/// Everything a single refresh via Antigravity's `language_server` returns.
struct GeminiUsageSnapshot {
    var account: GeminiAccountInfo
    var windows: [UsageWindow]
    var models: [GeminiQuotaModel]
    var proofWindows: [QuotaWindowProof]
}

/// Multi-account credential vault and Keychain coordinator for Antigravity / Gemini.
///
/// Antigravity's `language_server` always stores its active Google OAuth token in a
/// single macOS Keychain slot (`service = "gemini", account = "antigravity"`). To run
/// several Gemini accounts side by side without losing logins or racing across refreshes,
/// LLMCodeBar keeps a per-profile copy in its own Keychain service
/// (`LLMCodeBar.Gemini.Account`) and serializes access to the live Antigravity slot.
///
/// Single-account setups never touch or rewrite the live slot — we only swap when
/// talking to a different Gemini account than the one currently active in Keychain.
enum GeminiAuthStore {
    private static let liveService = "gemini"
    private static let liveAccount = "antigravity"
    private static let vaultService = "LLMCodeBar.Gemini.Account"

    private static let lock = NSRecursiveLock()
    private static let metadataURL = Paths.shared.appSupport.appendingPathComponent("gemini_vault.json")

    private struct VaultMetadata: Codable {
        var activeVaultKey: String?
        var accountsByKey: [String: GeminiAccountInfo] = [:]
    }

    static func vaultKey(for dataDir: String) -> String {
        URL(fileURLWithPath: Launcher.expanding(dataDir)).standardizedFileURL.path
    }

    static func hasLiveCredential() -> Bool {
        readLiveCredential() != nil
    }

    static func hasVaultedCredential(for dataDir: String) -> Bool {
        readVaultCredential(forKey: vaultKey(for: dataDir)) != nil
    }

    /// Fast local account lookup for `AccountResolver` / `ConfigStore.inferProfiles`
    /// without spawning `language_server`.
    static func cachedAccountInfo(dataDir: String) -> GeminiAccountInfo? {
        let key = vaultKey(for: dataDir)
        let metadata = loadMetadata()
        if let cached = metadata.accountsByKey[key], cached.email != nil || cached.name != nil {
            return cached
        }
        // For the default Antigravity profile, fall back to Antigravity's local VS Code
        // state DB (`antigravityAuthStatus`) or `~/.gemini/google_accounts.json` if present.
        let defaultDir = vaultKey(for: "~/Library/Application Support/Antigravity")
        if key == defaultDir {
            if let dbInfo = readStateDBAccountInfo(dataDir: dataDir) {
                return dbInfo
            }
            if let cliEmail = readGoogleAccountsJSONEmail() {
                return GeminiAccountInfo(email: cliEmail, name: nil, plan: nil)
            }
        }
        return nil
    }

    /// Records the authoritative identity returned by Antigravity's `GetUserStatus`.
    static func recordAccountInfo(_ info: GeminiAccountInfo, for dataDir: String) {
        lock.lock()
        defer { lock.unlock() }
        var metadata = loadMetadata()
        let key = vaultKey(for: dataDir)
        metadata.accountsByKey[key] = info
        saveMetadata(metadata)
    }

    /// Runs `body` with `profile`'s Antigravity credential active in the live Keychain slot,
    /// then captures any refreshed token back into `profile`'s vault and restores the
    /// previous live credential if we had to swap.
    static func withActivatedProfile<T>(_ profile: LaunchProfile, _ body: () throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }

        let targetKey = vaultKey(for: profile.dataDir)
        var metadata = loadMetadata()
        let previousLive = readLiveCredential()
        let vaulted = readVaultCredential(forKey: targetKey)

        // Decide whether we need to swap the live slot.
        var swapped = false
        if let vaulted, vaulted != previousLive {
            // Preserve whatever was live into its owner's vault before swapping so a
            // refreshed token from Antigravity or T3 Code is never lost.
            if let previousLive, let previousOwner = metadata.activeVaultKey, previousOwner != targetKey {
                saveVaultCredential(previousLive, forKey: previousOwner)
            }
            try writeLiveCredential(vaulted)
            swapped = true
        } else if vaulted == nil {
            // This profile has no vaulted credential yet (first scan or pending sign-in).
            // Refuse to steal the live Keychain slot if it still holds another profile's
            // already-vaulted credential, so a pending profile never impersonates an
            // existing account before the user finishes signing in.
            guard let previousLive else {
                throw error("Not signed in to Antigravity. Open Gemini from the menu to sign in.")
            }
            if let activeOwner = metadata.activeVaultKey,
               activeOwner != targetKey,
               let ownerVaulted = readVaultCredential(forKey: activeOwner),
               ownerVaulted == previousLive {
                throw error("Waiting for sign-in in Antigravity.")
            }
            if metadata.activeVaultKey == nil {
                metadata.activeVaultKey = targetKey
                saveMetadata(metadata)
            }
        }

        defer {
            if let currentAfter = readLiveCredential() {
                if swapped || metadata.activeVaultKey == targetKey {
                    saveVaultCredential(currentAfter, forKey: targetKey)
                }
            }
            if swapped {
                if let previousLive {
                    try? writeLiveCredential(previousLive)
                } else {
                    deleteLiveCredential()
                }
            }
        }

        return try body()
    }

    /// Snapshots the currently live Antigravity credential into `profile`'s vault when
    /// `profile` is confirmed to own it (for example after a fresh sign-in or first refresh).
    static func snapshotLiveCredential(for profile: LaunchProfile, confirmedAccount: GeminiAccountInfo) {
        lock.lock()
        defer { lock.unlock() }

        let key = vaultKey(for: profile.dataDir)
        var metadata = loadMetadata()
        metadata.accountsByKey[key] = confirmedAccount
        if let live = readLiveCredential() {
            // Only claim the live slot if it isn't already known to belong to another email.
            if let ownerKey = metadata.activeVaultKey,
               ownerKey != key,
               let ownerEmail = metadata.accountsByKey[ownerKey]?.email?.lowercased(),
               let newEmail = confirmedAccount.email?.lowercased(),
               ownerEmail == newEmail {
                // Same email as another profile; still store a copy for this profile.
                saveVaultCredential(live, forKey: key)
            } else {
                saveVaultCredential(live, forKey: key)
                metadata.activeVaultKey = key
            }
        }
        saveMetadata(metadata)
    }

    /// Saves the currently active Antigravity account's credential into its vault and clears
    /// the live slot so opening Antigravity for a newly added Gemini profile lands on the
    /// Google sign-in screen instead of reusing the previous account.
    static func prepareForNewAccountLogin(existingProfiles: [LaunchProfile]) {
        lock.lock()
        defer { lock.unlock() }

        var metadata = loadMetadata()
        if let live = readLiveCredential() {
            let ownerKey: String? = metadata.activeVaultKey ?? existingProfiles
                .first { $0.provider == .gemini && $0.isPendingLogin != true }
                .map { vaultKey(for: $0.dataDir) }
            if let ownerKey {
                saveVaultCredential(live, forKey: ownerKey)
            }
        }
        metadata.activeVaultKey = nil
        saveMetadata(metadata)
        deleteLiveCredential()
    }

    /// Activates `profile`'s vaulted credential into the live Keychain slot before
    /// launching `Antigravity.app` so the app opens signed into that account.
    static func activateForAppLaunch(_ profile: LaunchProfile, allProfiles: [LaunchProfile] = []) {
        lock.lock()
        defer { lock.unlock() }

        if profile.isPendingLogin == true {
            prepareForNewAccountLogin(existingProfiles: allProfiles)
            return
        }

        let targetKey = vaultKey(for: profile.dataDir)
        var metadata = loadMetadata()
        guard let targetToken = readVaultCredential(forKey: targetKey) else {
            // No vaulted token yet — leave whatever is live untouched.
            return
        }
        if let currentLive = readLiveCredential(), currentLive != targetToken {
            if let previousOwner = metadata.activeVaultKey, previousOwner != targetKey {
                saveVaultCredential(currentLive, forKey: previousOwner)
            }
            try? writeLiveCredential(targetToken)
        } else if readLiveCredential() == nil {
            try? writeLiveCredential(targetToken)
        }
        metadata.activeVaultKey = targetKey
        saveMetadata(metadata)
    }

    // MARK: Live Keychain (`service = "gemini", account = "antigravity"`)

    /// Uses `/usr/bin/security` so macOS Keychain ACLs match the tool `zalando/go-keyring`
    /// inside Antigravity uses, avoiding extra password prompts.
    static func readLiveCredential() -> Data? {
        if let output = try? ProcessRunner.run(
            "/usr/bin/security",
            arguments: ["find-generic-password", "-s", liveService, "-a", liveAccount, "-w"],
            timeout: 4) {
            let trimmed = output.trimmingCharacters(in: .newlines)
            if !trimmed.isEmpty {
                return Data(trimmed.utf8)
            }
        }
        return nil
    }

    /// Writes the live credential via `/usr/bin/security -i` (stdin) using `-X <hex>`,
    /// so the token never appears on argv and arbitrary bytes never need shell escaping.
    static func writeLiveCredential(_ data: Data) throws {
        let hex = data.map { String(format: "%02x", $0) }.joined()
        let command = "add-generic-password -U -s \(liveService) -a \(liveAccount) -X \(hex)\n"
        try runSecurityInteractive(command)
    }

    static func deleteLiveCredential() {
        _ = try? ProcessRunner.run(
            "/usr/bin/security",
            arguments: ["delete-generic-password", "-s", liveService, "-a", liveAccount],
            timeout: 4)
    }

    private static func runSecurityInteractive(_ script: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["-i"]
        let stdin = Pipe()
        let stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = FileHandle.nullDevice
        process.standardError = stderr
        try process.run()
        if let payload = script.data(using: .utf8) {
            try stdin.fileHandleForWriting.write(contentsOf: payload)
        }
        try? stdin.fileHandleForWriting.close()
        let deadline = Date().addingTimeInterval(5)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        if process.isRunning {
            process.terminate()
            throw error("Timed out updating Antigravity Keychain credentials.")
        }
        guard process.terminationStatus == 0 else {
            let message = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw error("Couldn't update Antigravity Keychain credentials: \(message.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
    }

    // MARK: Per-profile Keychain vault (`LLMCodeBar.Gemini.Account`)

    private static func readVaultCredential(forKey key: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: vaultService,
            kSecAttrAccount as String: key,
            kSecReturnData as String: kCFBooleanTrue as Any,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data, !data.isEmpty else {
            return nil
        }
        return data
    }

    private static func saveVaultCredential(_ data: Data, forKey key: String) {
        let identity: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: vaultService,
            kSecAttrAccount as String: key,
        ]
        let update: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(identity as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var add = identity
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            SecItemAdd(add as CFDictionary, nil)
        }
    }

    // MARK: Local metadata cache (non-secret email/name/plan & active owner pointer)

    private static func loadMetadata() -> VaultMetadata {
        guard let data = try? Data(contentsOf: metadataURL),
              let decoded = try? JSONDecoder().decode(VaultMetadata.self, from: data) else {
            return VaultMetadata()
        }
        return decoded
    }

    private static func saveMetadata(_ metadata: VaultMetadata) {
        Paths.shared.ensureSupportDirectory()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(metadata) {
            try? data.write(to: metadataURL, options: .atomic)
        }
    }

    /// Reads non-secret account name/email from Antigravity's `state.vscdb` if present.
    private static func readStateDBAccountInfo(dataDir: String) -> GeminiAccountInfo? {
        let dbURL = URL(fileURLWithPath: Launcher.expanding(dataDir), isDirectory: true)
            .appendingPathComponent("User/globalStorage/state.vscdb")
        guard FileManager.default.fileExists(atPath: dbURL.path) else { return nil }
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbURL.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
            sqlite3_close(db)
            return nil
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 1000)
        var stmt: OpaquePointer?
        let sql = "SELECT value FROM ItemTable WHERE key = 'antigravityAuthStatus' LIMIT 1"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return nil }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW,
              let raw = sqlite3_column_text(stmt, 0).map({ String(cString: $0) }),
              let data = raw.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let email = (json["email"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let name = (json["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (email?.isEmpty == false) || (name?.isEmpty == false) else { return nil }
        return GeminiAccountInfo(email: email?.isEmpty == true ? nil : email, name: name?.isEmpty == true ? nil : name, plan: nil)
    }

    private static func readGoogleAccountsJSONEmail() -> String? {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".gemini/google_accounts.json")
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let active = (json["active"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !active.isEmpty else {
            return nil
        }
        return active
    }

    private static func error(_ message: String) -> NSError {
        NSError(domain: "LLMUsageBar.GeminiAuth", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

// MARK: - Antigravity language_server client

/// Short-lived local client for Google Antigravity's official `language_server` binary
/// bundled inside `/Applications/Antigravity.app`.
///
/// All quota checks, 5-hour session starts, and conversation reads/transfers run through
/// Antigravity itself — never through direct raw API calls — so accounts behave identically
/// to using the Antigravity desktop app.
final class GeminiLanguageServer: NSObject, URLSessionDelegate {
    private let process = Process()
    private let output = Pipe()
    private let csrfToken = UUID().uuidString.lowercased()
    private let portLock = NSLock()
    private let portReady = DispatchSemaphore(value: 0)
    private var port: Int?
    private var scheme = "https"
    private var lineBuffer = Data()
    private var recentLogs: [String] = []
    private lazy var session: URLSession = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: nil)

    static let defaultAppPath = "/Applications/Antigravity.app"

    /// Locates the `language_server` binary inside the Antigravity app bundle.
    static func executable(for appPath: String = defaultAppPath) -> URL? {
        let expanded = Launcher.expanding(appPath)
        let candidates = [
            "\(expanded)/Contents/Resources/bin/language_server",
            "\(defaultAppPath)/Contents/Resources/bin/language_server",
        ]
        return candidates
            .first { FileManager.default.isExecutableFile(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
    }

    static func appVersion(for appPath: String = defaultAppPath) -> String {
        let url = URL(fileURLWithPath: Launcher.expanding(appPath))
        if let version = Bundle(url: url)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String, !version.isEmpty {
            return version
        }
        return "2.8.1"
    }

    init(appPath: String = defaultAppPath, geminiDir: String? = nil, appDataDir: String = "antigravity") throws {
        super.init()
        guard let binary = Self.executable(for: appPath) else {
            throw Self.error("Antigravity isn't installed at \(Launcher.expanding(appPath)). Install Antigravity, then try again.")
        }

        var args = [
            "--standalone",
            "--override_ide_name", "antigravity",
            "--subclient_type", "hub",
            "--override_ide_version", Self.appVersion(for: appPath),
            "--override_user_agent_name", "antigravity",
            "--https_server_port", "0",
            "--csrf_token", csrfToken,
            "--app_data_dir", appDataDir,
            "--api_server_url", "https://generativelanguage.googleapis.com",
            "--cloud_code_endpoint", "https://daily-cloudcode-pa.googleapis.com",
        ]
        if let geminiDir, !geminiDir.isEmpty {
            args += ["--gemini_dir", geminiDir]
        }

        process.executableURL = binary
        process.arguments = args
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = output

        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            self?.consume(handle.availableData)
        }
        try process.run()

        // Wait up to 10 seconds for the server to print its listening port.
        let waitResult = portReady.wait(timeout: .now() + 10)
        portLock.lock()
        let boundPort = port
        portLock.unlock()
        guard waitResult == .success, boundPort != nil else {
            stop()
            throw Self.error("Antigravity didn't start its local server in time.")
        }
    }

    deinit {
        stop()
    }

    func stop() {
        output.fileHandleForReading.readabilityHandler = nil
        session.invalidateAndCancel()
        if process.isRunning {
            process.terminate()
        }
    }

    /// Waits briefly for `language_server` to finish loading the Keychain token on boot.
    func waitForAuth(timeout: TimeInterval = 4.0) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let response = try? rpc("HasAuthToken"),
               response["hasToken"] as? Bool == true {
                return true
            }
            Thread.sleep(forTimeInterval: 0.15)
        }
        return false
    }

    func rpc(_ method: String, body: [String: Any] = [:], timeout: TimeInterval = 20) throws -> [String: Any] {
        portLock.lock()
        let boundPort = port
        let proto = scheme
        portLock.unlock()
        guard let boundPort else {
            throw Self.error("Antigravity server isn't listening.")
        }
        let url = URL(string: "\(proto)://127.0.0.1:\(boundPort)/exa.language_server_pb.LanguageServerService/\(method)")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
        request.setValue(csrfToken, forHTTPHeaderField: "X-Codeium-Csrf-Token")

        let semaphore = DispatchSemaphore(value: 0)
        var outcome: Result<(Int, Data), Error>!
        session.dataTask(with: request) { data, response, error in
            defer { semaphore.signal() }
            if let error {
                outcome = .failure(error)
                return
            }
            guard let http = response as? HTTPURLResponse else {
                outcome = .failure(Self.error("Invalid response from Antigravity."))
                return
            }
            outcome = .success((http.statusCode, data ?? Data()))
        }.resume()
        semaphore.wait()

        let (status, data) = try outcome.get()
        guard (200...299).contains(status) else {
            let detail = Self.conciseError(data)
            throw Self.error(detail.isEmpty ? "Antigravity \(method) failed (HTTP \(status))." : detail)
        }
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    // MARK: High-level operations

    /// Fetches account identity, quota windows, and available models through Antigravity.
    static func fetchUsage(for profile: LaunchProfile) throws -> GeminiUsageSnapshot {
        try GeminiAuthStore.withActivatedProfile(profile) {
            let server = try GeminiLanguageServer(appPath: profile.appPath)
            defer { server.stop() }
            guard server.waitForAuth() else {
                throw Self.error("Not signed in to Antigravity. Open Gemini from the menu to sign in.")
            }
            let statusJSON = try server.rpc("GetUserStatus", timeout: 20)
            let summaryJSON = try? server.rpc("RetrieveUserQuotaSummary", timeout: 20)
            let snapshot = parseUsageSnapshot(userStatusJSON: statusJSON, quotaSummaryJSON: summaryJSON, now: Date())
            if snapshot.account.email != nil || snapshot.account.name != nil {
                GeminiAuthStore.snapshotLiveCredential(for: profile, confirmedAccount: snapshot.account)
            }
            return snapshot
        }
    }

    /// Starts a throwaway cascade in Antigravity on the cheapest Gemini model, sends one
    /// tiny prompt ("hi"), waits for the reply, and deletes the cascade so the sidebar stays clean.
    static func kickFiveHourSession(for profile: LaunchProfile) throws -> String {
        try GeminiAuthStore.withActivatedProfile(profile) {
            let server = try GeminiLanguageServer(appPath: profile.appPath)
            defer { server.stop() }
            guard server.waitForAuth() else {
                throw Self.error("Not signed in to Antigravity.")
            }

            let statusJSON = try server.rpc("GetUserStatus", timeout: 20)
            let snapshot = parseUsageSnapshot(userStatusJSON: statusJSON, quotaSummaryJSON: nil, now: Date())
            let candidates = cheapestGeminiModels(from: snapshot.models)
            let chosen = candidates.first

            var startBody: [String: Any] = [
                "source": "CORTEX_TRAJECTORY_SOURCE_CASCADE_CLIENT",
            ]
            if let chosen {
                startBody["requestedModel"] = chosen.id
            }

            let started = try server.rpc("StartCascade", body: startBody, timeout: 15)
            guard let cascadeID = started["cascadeId"] as? String, !cascadeID.isEmpty else {
                throw Self.error("Antigravity didn't return a conversation id.")
            }
            defer {
                _ = try? server.rpc("DeleteCascadeTrajectory", body: ["cascadeId": cascadeID], timeout: 10)
            }

            var messageBody: [String: Any] = [
                "cascadeId": cascadeID,
                "items": [["text": "hi"]],
            ]
            if let chosen {
                messageBody["cascadeConfig"] = [
                    "plannerConfig": [
                        "requestedModel": ["model": chosen.id],
                    ],
                ]
            }
            _ = try server.rpc("SendUserCascadeMessage", body: messageBody, timeout: 25)

            // Wait for the planner response to finish (or fail) so the 5h window is
            // guaranteed to have started before we clean up the throwaway conversation.
            let deadline = Date().addingTimeInterval(35)
            while Date() < deadline {
                Thread.sleep(forTimeInterval: 0.75)
                if let trajectory = try? server.rpc("GetCascadeTrajectory", body: ["cascadeId": cascadeID], timeout: 10),
                   let steps = (trajectory["trajectory"] as? [String: Any])?["steps"] as? [[String: Any]] {
                    if let errorStep = steps.first(where: { $0["type"] as? String == "CORTEX_STEP_TYPE_ERROR_MESSAGE" }) {
                        let message = ((errorStep["errorMessage"] as? [String: Any])?["error"] as? [String: Any])?["userErrorMessage"] as? String
                            ?? "Antigravity returned an error."
                        throw Self.error(message)
                    }
                    let done = steps.contains { step in
                        let type = step["type"] as? String
                        let status = step["status"] as? String
                        return (type == "CORTEX_STEP_TYPE_PLANNER_RESPONSE" || type == "CORTEX_STEP_TYPE_NOTIFY_USER")
                            && status == "CORTEX_STEP_STATUS_DONE"
                    }
                    if done { break }
                }
            }

            return "Started a Gemini 5h session - sent “hi” via Antigravity on \(chosen?.label ?? "the default model")."
        }
    }

    // MARK: Pure parsing & model selection (unit-tested)

    /// Parses Antigravity's `GetUserStatus` + `RetrieveUserQuotaSummary` JSON into
    /// normalized account info, primary 5h / weekly `UsageWindow`s, and model list.
    static func parseUsageSnapshot(
        userStatusJSON: [String: Any],
        quotaSummaryJSON: [String: Any]?,
        now: Date = Date()
    ) -> GeminiUsageSnapshot {
        let userStatus = (userStatusJSON["userStatus"] as? [String: Any]) ?? userStatusJSON
        let email = (userStatus["email"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let name = (userStatus["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let planInfo = (userStatus["planStatus"] as? [String: Any])?["planInfo"] as? [String: Any]
        let rawPlan = (planInfo?["planName"] as? String) ?? displayTier(planInfo?["teamsTier"] as? String)
        let account = GeminiAccountInfo(
            email: email?.isEmpty == true ? nil : email,
            name: name?.isEmpty == true ? nil : name,
            plan: rawPlan?.isEmpty == true ? nil : rawPlan)

        let modelConfigs = ((userStatus["cascadeModelConfigData"] as? [String: Any])?["clientModelConfigs"] as? [[String: Any]]) ?? []
        let models: [GeminiQuotaModel] = modelConfigs.compactMap { entry in
            guard let label = entry["label"] as? String,
                  let id = (entry["modelOrAlias"] as? [String: Any])?["model"] as? String,
                  !id.isEmpty else { return nil }
            let quota = entry["quotaInfo"] as? [String: Any]
            let remaining = flexibleDouble(quota?["remainingFraction"])
            let reset = (quota?["resetTime"] as? String).flatMap(parseISODate)
            return GeminiQuotaModel(id: id, label: label, remainingFraction: remaining, resetsAt: reset)
        }

        var windows: [UsageWindow] = []
        var proofWindows: [QuotaWindowProof] = []

        if let summaryRoot = (quotaSummaryJSON?["response"] as? [String: Any]) ?? quotaSummaryJSON {
            let groups = (summaryRoot["groups"] as? [[String: Any]]) ?? []
            let allBuckets: [[String: Any]] = groups.isEmpty
                ? ((summaryRoot["buckets"] as? [[String: Any]]) ?? [])
                : groups.flatMap { ($0["buckets"] as? [[String: Any]]) ?? [] }

            var geminiFiveHour: (UsageWindow, QuotaWindowProof)?
            var geminiWeekly: (UsageWindow, QuotaWindowProof)?
            var extras: [(UsageWindow, QuotaWindowProof)] = []

            for bucket in allBuckets {
                if bucket["disabled"] as? Bool == true { continue }
                guard let bucketID = bucket["bucketId"] as? String,
                      let remaining = flexibleDouble(bucket["remainingFraction"]) else { continue }
                let clampedRemaining = max(0, min(1, remaining))
                let remainingPct = clampedRemaining * 100
                let usedPct = (1 - clampedRemaining) * 100
                let windowKind = (bucket["window"] as? String)?.lowercased() ?? ""
                let rawReset = bucket["resetTime"] as? String
                let description = (bucket["description"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                let parsedReset = normalizedResetTime(
                    rawReset: rawReset,
                    remainingFraction: clampedRemaining,
                    hasDescription: description?.isEmpty == false,
                    windowKind: windowKind,
                    now: now)

                let isGemini = bucketID.hasPrefix("gemini-")
                let isThreeP = bucketID.hasPrefix("3p-")

                if isGemini && windowKind == "5h" && geminiFiveHour == nil {
                    let window = UsageWindow(title: "5h", usedPercent: usedPct, remainingPercent: remainingPct, resetsAt: parsedReset)
                    let proof = makeProof(title: "5h", used: usedPct, remaining: remainingPct, rawReset: rawReset, parsedReset: parsedReset)
                    geminiFiveHour = (window, proof)
                } else if isGemini && windowKind == "weekly" && geminiWeekly == nil {
                    let window = UsageWindow(title: "Week", usedPercent: usedPct, remainingPercent: remainingPct, resetsAt: parsedReset)
                    let proof = makeProof(title: "Week", used: usedPct, remaining: remainingPct, rawReset: rawReset, parsedReset: parsedReset)
                    geminiWeekly = (window, proof)
                } else if isThreeP && usedPct > 0.5 {
                    let title = windowKind == "5h" ? "3P 5h" : windowKind == "weekly" ? "3P week" : bucketID
                    let window = UsageWindow(title: title, usedPercent: usedPct, remainingPercent: remainingPct, resetsAt: parsedReset)
                    let proof = makeProof(title: title, used: usedPct, remaining: remainingPct, rawReset: rawReset, parsedReset: parsedReset)
                    extras.append((window, proof))
                }
            }

            if let five = geminiFiveHour {
                windows.append(five.0)
                proofWindows.append(five.1)
            }
            if let week = geminiWeekly {
                windows.append(week.0)
                proofWindows.append(week.1)
            }
            for extra in extras {
                windows.append(extra.0)
                proofWindows.append(extra.1)
            }
        }

        // Fallback for older accounts whose summary endpoint returns no buckets: derive
        // the 5h Gemini quota from the Gemini entries in `clientModelConfigs`.
        if windows.isEmpty {
            let geminiModels = models.filter { $0.label.lowercased().contains("gemini") && $0.remainingFraction != nil }
            if let worst = geminiModels.min(by: { ($0.remainingFraction ?? 1) < ($1.remainingFraction ?? 1) }),
               let remaining = worst.remainingFraction {
                let clamped = max(0, min(1, remaining))
                let used = (1 - clamped) * 100
                let reset = normalizedResetTime(
                    rawReset: worst.resetsAt.flatMap(isoString),
                    remainingFraction: clamped,
                    hasDescription: clamped < 0.999,
                    windowKind: "5h",
                    now: now)
                let window = UsageWindow(title: "5h", usedPercent: used, remainingPercent: clamped * 100, resetsAt: reset)
                windows.append(window)
                proofWindows.append(makeProof(title: "5h", used: used, remaining: clamped * 100, rawReset: worst.resetsAt.flatMap(isoString), parsedReset: reset))
            }
        }

        return GeminiUsageSnapshot(account: account, windows: windows, models: models, proofWindows: proofWindows)
    }

    /// Antigravity returns a placeholder `resetTime = now + windowLength` when a bucket
    /// hasn't been used yet (`remainingFraction == 1` and no description). Clear that
    /// placeholder so idle windows display `-` and `SessionKickstarter` knows the 5h
    /// clock isn't running yet.
    static func normalizedResetTime(
        rawReset: String?,
        remainingFraction: Double,
        hasDescription: Bool,
        windowKind: String,
        now: Date
    ) -> Date? {
        guard let rawReset, let date = parseISODate(rawReset) else { return nil }
        let expectedDuration: TimeInterval? = windowKind == "5h" ? 5 * 3600 : windowKind == "weekly" ? 7 * 86_400 : nil
        if remainingFraction >= 0.999, !hasDescription, let expectedDuration {
            let delta = abs(date.timeIntervalSince(now) - expectedDuration)
            if delta <= 120 {
                return nil
            }
        }
        return date
    }

    /// Ranks the account's Gemini models cheapest first for auto-starting the 5h window.
    /// Excludes 3P Claude/GPT models so the Gemini 5h bucket is the one that starts.
    static func cheapestGeminiModels(from models: [GeminiQuotaModel]) -> [GeminiQuotaModel] {
        let geminiOnly = models.filter {
            let lower = $0.label.lowercased()
            return lower.contains("gemini") && !lower.contains("claude") && !lower.contains("gpt")
        }
        return geminiOnly.enumerated().sorted { left, right in
            let lRank = modelCostRank(left.element.label)
            let rRank = modelCostRank(right.element.label)
            if lRank != rRank { return lRank < rRank }
            return left.offset < right.offset
        }.map(\.element)
    }

    private static func modelCostRank(_ label: String) -> Int {
        let lower = label.lowercased()
        let family: Int
        if lower.contains("flash-lite") || lower.contains("flash lite") {
            family = 0
        } else if lower.contains("flash") {
            family = 1
        } else if lower.contains("argon") || lower.contains("hydrogen") {
            family = 2
        } else if lower.contains("pro") || lower.contains("neon") {
            family = 3
        } else {
            family = 4
        }

        let effort: Int
        if lower.contains("(low)") {
            effort = 0
        } else if lower.contains("(medium)") {
            effort = 1
        } else if lower.contains("(high)") {
            effort = 2
        } else if lower.contains("(xhigh)") || lower.contains("(max)") {
            effort = 3
        } else {
            effort = 1
        }
        return family * 10 + effort
    }

    private static func displayTier(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        let lower = raw.lowercased()
        if lower.contains("ultra") || lower.contains("ultimate") { return "Ultra" }
        if lower.contains("pro") { return "Pro" }
        if lower.contains("enterprise") { return "Enterprise" }
        if lower.contains("teams") { return "Team" }
        if lower.contains("free") { return "Free" }
        return nil
    }

    private static func makeProof(title: String, used: Double, remaining: Double, rawReset: String?, parsedReset: Date?) -> QuotaWindowProof {
        QuotaWindowProof(
            title: title,
            providerUsedPercent: used,
            parsedUsedPercent: max(0, min(100, used)),
            providerRemainingPercent: remaining,
            parsedRemainingPercent: max(0, min(100, remaining)),
            providerReset: rawReset,
            parsedReset: parsedReset.flatMap(isoString),
            matches: rawReset == nil || parsedReset != nil || used <= 0.01)
    }

    // MARK: URLSessionDelegate (trust local self-signed TLS cert on 127.0.0.1 only)

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           let trust = challenge.protectionSpace.serverTrust,
           challenge.protectionSpace.host == "127.0.0.1" || challenge.protectionSpace.host == "localhost" {
            completionHandler(.useCredential, URLCredential(trust: trust))
            return
        }
        completionHandler(.performDefaultHandling, nil)
    }

    // MARK: Output parsing

    private func consume(_ chunk: Data) {
        guard !chunk.isEmpty else { return }
        portLock.lock()
        lineBuffer.append(chunk)
        var signaled = false
        while let newline = lineBuffer.firstIndex(of: 0x0A) {
            let lineData = lineBuffer[lineBuffer.startIndex..<newline]
            lineBuffer.removeSubrange(lineBuffer.startIndex...newline)
            let line = String(decoding: lineData, as: UTF8.self)
            recentLogs.append(line)
            if recentLogs.count > 40 { recentLogs.removeFirst() }
            if port == nil, let parsed = Self.parseListeningPort(in: line) {
                port = parsed.port
                scheme = parsed.scheme
                signaled = true
            }
        }
        portLock.unlock()
        if signaled { portReady.signal() }
    }

    static func parseListeningPort(in line: String) -> (port: Int, scheme: String)? {
        guard let regex = try? NSRegularExpression(pattern: #"listening on \w+ port at (\d+) for HTTP(S)?\b"#, options: [.caseInsensitive]) else {
            return nil
        }
        let range = NSRange(line.startIndex..<line.endIndex, in: line)
        guard let match = regex.firstMatch(in: line, range: range),
              let portRange = Range(match.range(at: 1), in: line),
              let port = Int(line[portRange]) else {
            return nil
        }
        let isHTTPS = match.range(at: 2).location != NSNotFound
        return (port, isHTTPS ? "https" : "http")
    }

    private static func flexibleDouble(_ value: Any?) -> Double? {
        if let value = value as? Double { return value }
        if let value = value as? Int { return Double(value) }
        if let value = value as? NSNumber { return value.doubleValue }
        if let value = value as? String { return Double(value.trimmingCharacters(in: .whitespacesAndNewlines)) }
        return nil
    }

    private static func parseISODate(_ raw: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return fractional.date(from: raw) ?? plain.date(from: raw)
    }

    private static func isoString(_ date: Date) -> String? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private static func conciseError(_ data: Data) -> String {
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let message = json["message"] as? String {
            return message
        }
        return (String(data: data.prefix(160), encoding: .utf8) ?? "").replacingOccurrences(of: "\n", with: " ")
    }

    private static func error(_ message: String) -> NSError {
        NSError(domain: "LLMUsageBar.Gemini", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

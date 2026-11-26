import Foundation
import Security

struct MistralAccountInfo: Codable, Equatable {
    var email: String?
    var name: String?
    var plan: String?
    var userID: String?
    var organizationID: String?
    var organizationName: String?
}

struct MistralOidcTokens {
    var accessToken: String
    var refreshToken: String?
    var idToken: String?
    var expiresAt: Date?
    var rawDict: [String: Any]
}

struct MistralUsageSnapshot {
    var account: MistralAccountInfo
    var windows: [UsageWindow]
    var proofWindows: [QuotaWindowProof]
    var paygEnabled: Bool
    var status: String?
    /// True when the official Vibe CLI read it, rather than chat.mistral.ai.
    var viaCLI = false
}

/// Reads Mistral (Vibe / Le Chat desktop) OIDC credentials from its Electron user-data
/// `config.json` (decrypted via Electron's `le-chat-desktop Safe Storage` key cached in
/// `SafeStorageKeyCache`), refreshes expired OIDC access tokens via `auth.mistral.ai`, and
/// queries `chat.mistral.ai/api/trpc` for account info (`user.session`) and monthly budget
/// usage (`billing.budget`).
enum MistralAuthStore {
    static let defaultAppPath = "/Applications/Vibe.app"
    static let defaultDataDir = "~/Library/Application Support/le-chat-desktop"
    static let bundleIdentifier = "ai.mistral.lechat.desktop"

    static let oidcClientID = "88df79e3-3a98-4624-92fe-c607ecf06f1d"
    static let oidcTokenEndpoint = URL(string: "https://auth.mistral.ai/oauth2/token")!
    static let trpcBaseURL = "https://chat.mistral.ai/api/trpc"
    static let safeStorageServices = ["le-chat-desktop Safe Storage"]

    private static let tokenVaultService = "LLMCodeBar.Mistral.Tokens"
    private static let cacheLock = NSLock()

    // MARK: Account cache (no keychain required)

    private static var accountCacheURL: URL {
        Paths.shared.appSupport.appendingPathComponent("mistral-account-cache.json")
    }

    static func normalizedDataDir(_ dataDir: String) -> String {
        URL(fileURLWithPath: Launcher.expanding(dataDir)).standardizedFileURL.path
    }

    static func hasLocalConfig(dataDir: String) -> Bool {
        let configURL = URL(fileURLWithPath: Launcher.expanding(dataDir), isDirectory: true)
            .appendingPathComponent("config.json")
        guard let data = try? Data(contentsOf: configURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return false
        }
        return json["authOidcTokens"] != nil
    }

    static func cachedAccountInfo(dataDir: String) -> MistralAccountInfo? {
        cacheLock.lock()
        let cached: MistralAccountInfo? = {
            guard let data = try? Data(contentsOf: accountCacheURL),
                  let map = try? JSONDecoder().decode([String: MistralAccountInfo].self, from: data) else {
                return nil
            }
            return map[normalizedDataDir(dataDir)]
        }()
        cacheLock.unlock()

        if let cached { return cached }

        // Fall back to ~/.vibe/whoami_cache.json for the default le-chat-desktop profile
        // so first-time discovery knows the plan and signed-in state without touching Keychain.
        let isDefault = normalizedDataDir(dataDir) == normalizedDataDir(defaultDataDir)
        let hasConfig = hasLocalConfig(dataDir: dataDir)
        if isDefault, let whoami = readWhoamiCache() {
            return MistralAccountInfo(
                email: nil,
                name: nil,
                plan: displayPlan(raw: whoami.planName, hasPaidVibe: whoami.hasPaidVibe),
                userID: nil,
                organizationID: whoami.customerID,
                organizationName: nil)
        }
        if hasConfig {
            return MistralAccountInfo(email: nil, name: nil, plan: nil, userID: nil, organizationID: nil, organizationName: nil)
        }
        return nil
    }

    static func saveAccountInfo(_ info: MistralAccountInfo, for dataDir: String) {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        Paths.shared.ensureSupportDirectory()
        var map: [String: MistralAccountInfo] = [:]
        if let data = try? Data(contentsOf: accountCacheURL),
           let decoded = try? JSONDecoder().decode([String: MistralAccountInfo].self, from: data) {
            map = decoded
        }
        map[normalizedDataDir(dataDir)] = info
        if let encoded = try? JSONEncoder().encode(map) {
            try? encoded.write(to: accountCacheURL, options: .atomic)
        }
    }

    // MARK: Live usage fetch

    private enum BearerScheme: CaseIterable {
        case oidcIDTokenPrefixed
        case rawIDToken
        case oauthAccessTokenPrefixed
        case rawAccessToken

        func headerValue(for tokens: MistralOidcTokens) -> String? {
            switch self {
            case .oidcIDTokenPrefixed:
                guard let id = tokens.idToken, !id.isEmpty else { return nil }
                return "Bearer oidc_id_token:\(id)"
            case .rawIDToken:
                guard let id = tokens.idToken, !id.isEmpty else { return nil }
                return "Bearer \(id)"
            case .oauthAccessTokenPrefixed:
                return "Bearer oauth_access_token:\(tokens.accessToken)"
            case .rawAccessToken:
                return "Bearer \(tokens.accessToken)"
            }
        }
    }

    private static var preferredBearerScheme: BearerScheme?

    static func fetchUsage(for profile: LaunchProfile, allowKeychain: Bool) throws -> MistralUsageSnapshot {
        if let snapshot = fetchUsageThroughCLI(for: profile) {
            return snapshot
        }
        return try fetchUsageOnWeb(for: profile, allowKeychain: allowKeychain)
    }

    /// The account and budget as the official Vibe CLI reads them. Used whenever the CLI
    /// is installed and signed in to this same account (or the account's email isn't
    /// known yet and this is the default Vibe profile); otherwise nil.
    static func fetchUsageThroughCLI(for profile: LaunchProfile) -> MistralUsageSnapshot? {
        guard VibeCLI.executable() != nil, let cli = try? VibeCLI.readAccount() else { return nil }
        if let known = profile.accountEmail?.lowercased(), !known.isEmpty {
            guard cli.email == known else { return nil }
        } else if normalizedDataDir(profile.dataDir) != normalizedDataDir(defaultDataDir) {
            return nil
        }
        var budget: [String: Any]?
        if let percent = cli.usagePercent {
            budget = ["usage_percentage": percent, "payg_enabled": cli.paygEnabled]
            if let reset = cli.resetAt { budget?["reset_at"] = reset }
        }
        var user: [String: Any] = [:]
        user["email"] = cli.email
        user["firstName"] = cli.firstName
        user["lastName"] = cli.lastName
        user["id"] = cli.userID
        var organization: [String: Any] = [:]
        organization["id"] = cli.organizationID
        organization["name"] = cli.organizationName
        var snapshot = parseUsageSnapshot(
            sessionJSON: ["user": user, "organization": organization],
            budgetJSON: budget,
            idTokenClaims: nil)
        if let plan = cli.planTitle { snapshot.account.plan = plan }
        snapshot.viaCLI = true
        if snapshot.account.email != nil || snapshot.account.name != nil || snapshot.account.plan != nil {
            saveAccountInfo(snapshot.account, for: profile.dataDir)
        }
        return snapshot
    }

    /// The old route: chat.mistral.ai's web endpoints with the Vibe desktop app's login.
    /// Kept only for accounts the Vibe CLI isn't signed in to.
    static func fetchUsageOnWeb(for profile: LaunchProfile, allowKeychain: Bool) throws -> MistralUsageSnapshot {
        let dataDir = profile.dataDir
        var (tokens, passphrase) = try loadTokens(dataDir: dataDir, allowKeychain: allowKeychain)

        // Proactively refresh if either the access token or ID token is expired (or within 60s).
        if isTokenExpired(tokens), tokens.refreshToken != nil {
            if let refreshed = try? refreshTokens(tokens, dataDir: dataDir, passphrase: passphrase) {
                tokens = refreshed
            }
        }

        var (scheme, sessionResponse) = try authenticatedTRPCQuery(
            "user.session",
            tokens: tokens,
            extraHeaders: [:])

        if isUnauthorized(sessionResponse), tokens.refreshToken != nil {
            tokens = try refreshTokens(tokens, dataDir: dataDir, passphrase: passphrase)
            (scheme, sessionResponse) = try authenticatedTRPCQuery(
                "user.session",
                tokens: tokens,
                extraHeaders: [:])
        }

        let sessionData = unwrapTRPCResult(sessionResponse.data)
        let sessionDict = sessionData as? [String: Any]

        var budgetHeaders: [String: String] = [:]
        if let orgID = nonEmpty((sessionDict?["organization"] as? [String: Any])?["id"] as? String) {
            budgetHeaders["x-external-organization-id"] = orgID
        }
        if let wsID = nonEmpty((sessionDict?["workspace"] as? [String: Any])?["id"] as? String) {
            budgetHeaders["x-external-workspace-id"] = wsID
        }

        var budgetResponse: HTTPResponse
        if let scheme, let auth = scheme.headerValue(for: tokens) {
            budgetResponse = try trpcQuery("billing.budget", authorizationHeader: auth, extraHeaders: budgetHeaders)
            if isUnauthorized(budgetResponse), tokens.refreshToken != nil {
                tokens = try refreshTokens(tokens, dataDir: dataDir, passphrase: passphrase)
                if let freshAuth = scheme.headerValue(for: tokens) {
                    budgetResponse = try trpcQuery("billing.budget", authorizationHeader: freshAuth, extraHeaders: budgetHeaders)
                }
            }
        } else {
            (_, budgetResponse) = try authenticatedTRPCQuery("billing.budget", tokens: tokens, extraHeaders: budgetHeaders)
        }

        let budgetData = unwrapTRPCResult(budgetResponse.data)

        if sessionData == nil && budgetData == nil {
            let statusCode = budgetResponse.statusCode != 200 ? budgetResponse.statusCode : sessionResponse.statusCode
            let message = trpcErrorMessage(budgetResponse.data) ?? trpcErrorMessage(sessionResponse.data) ?? "HTTP \(statusCode)"
            throw error("Mistral usage unavailable (\(message))")
        }

        let idClaims = tokens.idToken.flatMap(decodeJWTClaims)
        let whoami = normalizedDataDir(dataDir) == normalizedDataDir(defaultDataDir) ? readWhoamiCache() : nil
        let snapshot = parseUsageSnapshot(
            sessionJSON: sessionDict,
            budgetJSON: budgetData as? [String: Any],
            idTokenClaims: idClaims,
            whoamiPlan: whoami?.planName,
            whoamiHasPaidVibe: whoami?.hasPaidVibe)

        if snapshot.account.email != nil || snapshot.account.name != nil || snapshot.account.plan != nil {
            saveAccountInfo(snapshot.account, for: dataDir)
        }
        return snapshot
    }

    private static func isTokenExpired(_ tokens: MistralOidcTokens, skew: TimeInterval = 60) -> Bool {
        let cutoff = Date().addingTimeInterval(skew)
        if let expiresAt = tokens.expiresAt, expiresAt <= cutoff {
            return true
        }
        if let idToken = tokens.idToken,
           let claims = decodeJWTClaims(idToken),
           let exp = flexibleDouble(claims["exp"]),
           Date(timeIntervalSince1970: exp) <= cutoff {
            return true
        }
        return false
    }

    private static func authenticatedTRPCQuery(
        _ procedure: String,
        tokens: MistralOidcTokens,
        extraHeaders: [String: String]
    ) throws -> (BearerScheme?, HTTPResponse) {
        var order = BearerScheme.allCases
        if let preferred = preferredBearerScheme, let idx = order.firstIndex(of: preferred) {
            order.remove(at: idx)
            order.insert(preferred, at: 0)
        }
        var lastResponse: HTTPResponse?
        for scheme in order {
            guard let auth = scheme.headerValue(for: tokens) else { continue }
            let response = try trpcQuery(procedure, authorizationHeader: auth, extraHeaders: extraHeaders)
            lastResponse = response
            if !isUnauthorized(response) {
                preferredBearerScheme = scheme
                return (scheme, response)
            }
        }
        if let lastResponse {
            return (nil, lastResponse)
        }
        throw error("No usable Mistral OIDC token available.")
    }

    // MARK: Pure parsing (unit-tested)

    static func parseUsageSnapshot(
        sessionJSON: [String: Any]?,
        budgetJSON: [String: Any]?,
        idTokenClaims: [String: Any]?,
        whoamiPlan: String? = nil,
        whoamiHasPaidVibe: Bool? = nil,
        now: Date = Date()
    ) -> MistralUsageSnapshot {
        let user = sessionJSON?["user"] as? [String: Any]
        let org = sessionJSON?["organization"] as? [String: Any]

        let email = nonEmpty(user?["email"] as? String)
            ?? nonEmpty(idTokenClaims?["email"] as? String)

        let firstName = nonEmpty(user?["firstName"] as? String)
        let lastName = nonEmpty(user?["lastName"] as? String)
        let combinedName = [firstName, lastName].compactMap { $0 }.joined(separator: " ")
        let name = nonEmpty(user?["name"] as? String)
            ?? nonEmpty(combinedName)
            ?? nonEmpty(idTokenClaims?["name"] as? String)

        let userID = nonEmpty(user?["id"] as? String)
            ?? nonEmpty(idTokenClaims?["sub"] as? String)
        let orgID = nonEmpty(org?["id"] as? String)
        let orgName = nonEmpty(org?["name"] as? String)
        let orgTier = nonEmpty(org?["orgTier"] as? String)

        let initialBudget = flexibleDouble(budgetJSON?["initial_budget"])
        let rawPercent = flexibleDouble(budgetJSON?["usage_percentage"])
        let currency = nonEmpty(budgetJSON?["currency"] as? String)
        let paygEnabled = (budgetJSON?["payg_enabled"] as? Bool) ?? false
        let resetRaw = budgetJSON?["reset_at"]
        let resetsAt = parseDateValue(resetRaw)

        let plan = resolvePlan(
            orgTier: orgTier,
            planPartner: nonEmpty(org?["leChatPlanPartner"] as? String),
            whoamiPlan: whoamiPlan,
            whoamiHasPaidVibe: whoamiHasPaidVibe,
            initialBudget: initialBudget)

        var windows: [UsageWindow] = []
        var proofWindows: [QuotaWindowProof] = []
        if let rawPercent {
            let used = clampPercent(rawPercent)
            let remaining = clampPercent(100 - rawPercent)
            let budgetDetail = formatBudgetDetail(
                usagePercent: rawPercent,
                initialBudget: initialBudget,
                currency: currency,
                paygEnabled: paygEnabled)
            windows.append(UsageWindow(
                title: "Month",
                usedPercent: used,
                remainingPercent: remaining,
                resetsAt: resetsAt,
                detail: budgetDetail))
            let providerReset: String? = (resetRaw as? String) ?? flexibleDouble(resetRaw).map { String(format: "%.0f", $0) }
            let parsedReset = resetsAt.map(isoString)
            proofWindows.append(QuotaWindowProof(
                title: "Month",
                providerUsedPercent: rawPercent,
                parsedUsedPercent: used,
                providerRemainingPercent: remaining,
                parsedRemainingPercent: remaining,
                providerReset: providerReset,
                parsedReset: parsedReset,
                matches: abs(clampPercent(rawPercent) - used) < 0.0001 && (providerReset == nil || parsedReset != nil)))
        }

        let account = MistralAccountInfo(
            email: email?.lowercased(),
            name: name,
            plan: plan,
            userID: userID,
            organizationID: orgID,
            organizationName: orgName)
        let status: String? = windows.isEmpty ? "No monthly Vibe budget reported" : nil
        return MistralUsageSnapshot(
            account: account,
            windows: windows,
            proofWindows: proofWindows,
            paygEnabled: paygEnabled,
            status: status)
    }

    static func formatBudgetDetail(
        usagePercent: Double,
        initialBudget: Double?,
        currency: String?,
        paygEnabled: Bool
    ) -> String? {
        guard let initialBudget, initialBudget > 0 else {
            return paygEnabled && usagePercent >= 100 ? "PAYG" : nil
        }
        let spent = max(0, initialBudget * (usagePercent / 100.0))
        let spentText = formatCurrency(spent, code: currency)
        let totalText = formatCurrency(initialBudget, code: currency)
        let suffix = (paygEnabled && usagePercent >= 100) ? " · PAYG" : ""
        return "\(spentText) / \(totalText)\(suffix)"
    }

    static func formatCurrency(_ amount: Double, code: String?) -> String {
        let symbol: String
        switch (code ?? "USD").uppercased() {
        case "USD": symbol = "$"
        case "EUR": symbol = "€"
        case "GBP": symbol = "£"
        default: symbol = "\((code ?? "").uppercased()) "
        }
        let rounded = (amount * 100).rounded() / 100
        if abs(rounded - rounded.rounded()) < 0.005 {
            return "\(symbol)\(Int(rounded.rounded()))"
        }
        return String(format: "%@%.2f", symbol, rounded)
    }

    static func unwrapTRPCResult(_ data: Data) -> Any? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) else { return nil }
        let entry: [String: Any]?
        if let array = obj as? [[String: Any]] {
            entry = array.first
        } else if let dict = obj as? [String: Any] {
            entry = dict
        } else {
            entry = nil
        }
        guard let result = entry?["result"] as? [String: Any],
              let payload = result["data"] else {
            return nil
        }
        if let payloadDict = payload as? [String: Any], payloadDict.keys.contains("json") {
            let inner = payloadDict["json"]
            return inner is NSNull ? nil : inner
        }
        return payload is NSNull ? nil : payload
    }

    static func trpcErrorMessage(_ data: Data) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) else { return nil }
        let entry = (obj as? [[String: Any]])?.first ?? (obj as? [String: Any])
        guard let err = entry?["error"] as? [String: Any] else { return nil }
        let json = (err["json"] as? [String: Any]) ?? err
        return json["message"] as? String
    }

    // MARK: Token I/O & OIDC refresh

    static func loadTokens(dataDir: String, allowKeychain: Bool) throws -> (MistralOidcTokens, String?) {
        let configURL = URL(fileURLWithPath: Launcher.expanding(dataDir), isDirectory: true)
            .appendingPathComponent("config.json")
        guard FileManager.default.fileExists(atPath: configURL.path) else {
            throw error("Sign in to Mistral Vibe to read usage.")
        }
        guard let data = try? Data(contentsOf: configURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entry = json["authOidcTokens"] as? [String: Any] else {
            throw error("Not signed in to Mistral Vibe.")
        }

        let kind = (entry["kind"] as? String)?.lowercased() ?? "plain"
        var usedPassphrase: String?
        let fileTokens: MistralOidcTokens

        if kind == "encrypted" {
            guard let base64 = entry["value"] as? String,
                  let encrypted = Data(base64Encoded: base64) else {
                throw error("Mistral OIDC token payload could not be decoded.")
            }
            let (service, passphrase) = try ElectronCookieReader.safeStoragePassphrase(
                forServices: safeStorageServices,
                allowKeychain: allowKeychain)
            guard let decrypted = ElectronCookieReader.decryptSafeStorage(encrypted, passphrase: passphrase) else {
                SafeStorageKeyCache.invalidate(for: service)
                throw error("Could not decrypt Mistral Vibe session tokens.")
            }
            usedPassphrase = passphrase
            fileTokens = try parseOidcTokens(from: decrypted)
        } else if let value = entry["value"] as? [String: Any] {
            fileTokens = try parseOidcTokens(fromDict: value)
        } else if let rawString = entry["value"] as? String, let rawData = rawString.data(using: .utf8) {
            fileTokens = try parseOidcTokens(from: rawData)
        } else {
            throw error("Unsupported Mistral OIDC token format.")
        }

        // Prefer our vaulted refreshed token if it is strictly fresher than Vibe's config.json.
        if let vaulted = loadVaultedTokens(for: dataDir) {
            let fileExp = fileTokens.expiresAt ?? .distantPast
            let vaultExp = vaulted.expiresAt ?? .distantPast
            if vaultExp > fileExp {
                return (vaulted, usedPassphrase)
            }
        }
        return (fileTokens, usedPassphrase)
    }

    static func refreshTokens(_ current: MistralOidcTokens, dataDir: String, passphrase: String?) throws -> MistralOidcTokens {
        guard let refreshToken = current.refreshToken, !refreshToken.isEmpty else {
            throw error("Mistral session expired. Open Vibe to sign in again.")
        }
        let form = [
            "grant_type=refresh_token",
            "client_id=\(urlFormEncode(oidcClientID))",
            "refresh_token=\(urlFormEncode(refreshToken))",
        ].joined(separator: "&")

        var request = URLRequest(url: oidcTokenEndpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("LLMCodeBar", forHTTPHeaderField: "User-Agent")
        request.httpBody = Data(form.utf8)

        let semaphore = DispatchSemaphore(value: 0)
        var outData: Data?
        var outResponse: URLResponse?
        var outError: Error?
        URLSession.shared.dataTask(with: request) { d, r, e in
            outData = d; outResponse = r; outError = e
            semaphore.signal()
        }.resume()
        _ = semaphore.wait(timeout: .now() + 18)

        if let outError { throw outError }
        let status = (outResponse as? HTTPURLResponse)?.statusCode ?? 0
        guard (200...299).contains(status),
              let outData,
              let json = try? JSONSerialization.jsonObject(with: outData) as? [String: Any],
              let newAccess = nonEmpty(json["access_token"] as? String) else {
            throw error("Mistral token refresh failed (HTTP \(status)). Open Vibe to sign in again.")
        }

        let newRefresh = nonEmpty(json["refresh_token"] as? String) ?? refreshToken
        let newID = nonEmpty(json["id_token"] as? String) ?? current.idToken
        let expiresIn = flexibleDouble(json["expires_in"])
        let newExpiresAt = expiresIn.map { Date().addingTimeInterval($0) }

        var raw = current.rawDict
        // Preserve Vibe's exact structure & camelCase/snake_case keys when writing back.
        func updateTokenDict(_ dict: [String: Any], depth: Int = 0) -> ([String: Any], Bool) {
            var copy = dict
            if copy.keys.contains("accessToken") {
                copy["accessToken"] = newAccess
                copy["refreshToken"] = newRefresh
                if let newID { copy["idToken"] = newID }
                if let newExpiresAt { copy["expiresAt"] = Int64(newExpiresAt.timeIntervalSince1970 * 1000) }
                return (copy, true)
            }
            if copy.keys.contains("access_token") {
                copy["access_token"] = newAccess
                copy["refresh_token"] = newRefresh
                if let newID { copy["id_token"] = newID }
                if let newExpiresAt { copy["expires_at"] = Int64(newExpiresAt.timeIntervalSince1970 * 1000) }
                return (copy, true)
            }
            guard depth < 3 else { return (copy, false) }
            for (k, v) in copy {
                if let sub = v as? [String: Any] {
                    let (updatedSub, didUpdate) = updateTokenDict(sub, depth: depth + 1)
                    if didUpdate {
                        copy[k] = updatedSub
                        return (copy, true)
                    }
                }
            }
            return (copy, false)
        }
        let (updatedRaw, didUpdate) = updateTokenDict(raw)
        if didUpdate {
            raw = updatedRaw
        } else {
            raw["accessToken"] = newAccess
            raw["refreshToken"] = newRefresh
            if let newID { raw["idToken"] = newID }
            if let newExpiresAt { raw["expiresAt"] = Int64(newExpiresAt.timeIntervalSince1970 * 1000) }
        }

        let updated = MistralOidcTokens(
            accessToken: newAccess,
            refreshToken: newRefresh,
            idToken: newID,
            expiresAt: newExpiresAt,
            rawDict: raw)
        saveVaultedTokens(updated, for: dataDir)
        if let passphrase {
            persistTokensToVibeConfig(updated, dataDir: dataDir, passphrase: passphrase)
        }
        return updated
    }

    private static func persistTokensToVibeConfig(_ tokens: MistralOidcTokens, dataDir: String, passphrase: String) {
        let configURL = URL(fileURLWithPath: Launcher.expanding(dataDir), isDirectory: true)
            .appendingPathComponent("config.json")
        guard let existingData = try? Data(contentsOf: configURL),
              var config = try? JSONSerialization.jsonObject(with: existingData) as? [String: Any],
              let tokenData = try? JSONSerialization.data(withJSONObject: tokens.rawDict, options: []),
              let encrypted = ElectronCookieReader.encryptSafeStorage(tokenData, passphrase: passphrase) else {
            return
        }
        config["authOidcTokens"] = [
            "kind": "encrypted",
            "value": encrypted.base64EncodedString(),
        ]
        if let encoded = try? JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted]) {
            try? encoded.write(to: configURL, options: .atomic)
        }
    }

    private static func loadVaultedTokens(for dataDir: String) -> MistralOidcTokens? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: tokenVaultService,
            kSecAttrAccount as String: normalizedDataDir(dataDir),
            kSecReturnData as String: kCFBooleanTrue as Any,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else {
            return nil
        }
        return try? parseOidcTokens(from: data)
    }

    private static func saveVaultedTokens(_ tokens: MistralOidcTokens, for dataDir: String) {
        guard let data = try? JSONSerialization.data(withJSONObject: tokens.rawDict, options: []) else { return }
        let identity: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: tokenVaultService,
            kSecAttrAccount as String: normalizedDataDir(dataDir),
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

    // MARK: HTTP / tRPC helpers

    private static func trpcQuery(
        _ procedure: String,
        authorizationHeader: String,
        extraHeaders: [String: String] = [:]
    ) throws -> HTTPResponse {
        let input = #"{"0":{"json":null,"meta":{"values":["undefined"]}}}"#
        let encodedInput = input.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? input
        guard let url = URL(string: "\(trpcBaseURL)/\(procedure)?batch=1&input=\(encodedInput)") else {
            throw error("Invalid Mistral endpoint URL.")
        }
        var headers: [String: String] = [
            "Authorization": authorizationHeader,
            "Accept": "application/json",
            "Origin": "https://chat.mistral.ai",
            "Referer": "https://chat.mistral.ai/",
            "x-trpc-source": "nextjs-react",
            "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X) LLMCodeBar",
        ]
        for (k, v) in extraHeaders {
            headers[k] = v
        }
        return try SimpleHTTP.get(url, headers: headers, timeout: 15)
    }

    private static func isUnauthorized(_ response: HTTPResponse) -> Bool {
        if response.statusCode == 401 || response.statusCode == 403 { return true }
        guard let obj = try? JSONSerialization.jsonObject(with: response.data) else { return false }
        let entry = (obj as? [[String: Any]])?.first ?? (obj as? [String: Any])
        guard let err = entry?["error"] as? [String: Any] else { return false }
        let json = (err["json"] as? [String: Any]) ?? err
        let data = json["data"] as? [String: Any]
        if (data?["code"] as? String) == "UNAUTHORIZED" { return true }
        if (data?["httpStatus"] as? Int) == 401 { return true }
        return false
    }

    // MARK: Token & cache parsers

    static func parseOidcTokens(from data: Data) throws -> MistralOidcTokens {
        guard let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw error("Mistral OIDC tokens are not a JSON object.")
        }
        return try parseOidcTokens(fromDict: dict)
    }

    private static func parseOidcTokens(fromDict dict: [String: Any]) throws -> MistralOidcTokens {
        // Vibe may store tokens directly at the top level or wrapped inside a versioned
        // envelope (e.g. {"v":1,"tokens":{...}} or {"data":{...}}). Find the dict holding
        // the access token while keeping the full raw envelope for write-back.
        func findTokenDict(_ candidate: [String: Any], depth: Int = 0) -> [String: Any]? {
            if nonEmpty(candidate["accessToken"] as? String) != nil ||
                nonEmpty(candidate["access_token"] as? String) != nil {
                return candidate
            }
            guard depth < 3 else { return nil }
            for value in candidate.values {
                if let sub = value as? [String: Any], let found = findTokenDict(sub, depth: depth + 1) {
                    return found
                }
            }
            return nil
        }

        guard let tokenDict = findTokenDict(dict),
              let access = nonEmpty(tokenDict["accessToken"] as? String) ?? nonEmpty(tokenDict["access_token"] as? String) else {
            let keys = dict.keys.sorted().joined(separator: ",")
            throw error("Mistral access token missing (keys: \(keys)).")
        }
        let refresh = nonEmpty(tokenDict["refreshToken"] as? String) ?? nonEmpty(tokenDict["refresh_token"] as? String)
        let idToken = nonEmpty(tokenDict["idToken"] as? String) ?? nonEmpty(tokenDict["id_token"] as? String)
        let expiresAt = parseDateValue(
            tokenDict["expiresAt"]
                ?? tokenDict["expires_at"]
                ?? tokenDict["accessTokenExpiresAt"]
                ?? tokenDict["access_token_expires_at"])
        return MistralOidcTokens(
            accessToken: access,
            refreshToken: refresh,
            idToken: idToken,
            expiresAt: expiresAt,
            rawDict: dict)
    }

    private struct WhoamiCacheEntry {
        var planName: String?
        var hasPaidVibe: Bool
        var customerID: String?
        var storedAt: Double
    }

    private static func readWhoamiCache() -> WhoamiCacheEntry? {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".vibe/whoami_cache.json")
        guard let data = try? Data(contentsOf: url),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        var best: WhoamiCacheEntry?
        for (key, value) in dict {
            guard let entry = value as? [String: Any],
                  let payload = entry["payload"] as? [String: Any] else { continue }
            let storedAt = flexibleDouble(entry["stored_at_timestamp"]) ?? 0
            let paid = (payload["has_paid_vibe_entitlement"] as? Bool) ?? false
            let candidate = WhoamiCacheEntry(
                planName: nonEmpty(payload["plan_name"] as? String),
                hasPaidVibe: paid,
                customerID: nonEmpty(payload["customer_id"] as? String),
                storedAt: storedAt + (key.hasPrefix("oidc:") ? 10_000_000_000 : 0))
            if best == nil || candidate.storedAt > best!.storedAt {
                best = candidate
            }
        }
        return best
    }

    private static func resolvePlan(
        orgTier: String?,
        planPartner: String?,
        whoamiPlan: String?,
        whoamiHasPaidVibe: Bool?,
        initialBudget: Double?
    ) -> String? {
        if let tier = orgTier?.uppercased() {
            switch tier {
            case "E", "ENTERPRISE": return "Enterprise"
            case "TEAM", "T": return "Team"
            case "PRO", "P": return "Pro"
            default: break
            }
        }
        if let partner = planPartner, !partner.isEmpty {
            return partner
        }
        if let budget = initialBudget, budget > 0 {
            if let whoamiPlan, whoamiPlan.caseInsensitiveCompare("INDIVIDUAL") != .orderedSame {
                return displayPlan(raw: whoamiPlan, hasPaidVibe: true)
            }
            return "Pro"
        }
        if let whoamiPlan {
            return displayPlan(raw: whoamiPlan, hasPaidVibe: whoamiHasPaidVibe ?? false)
        }
        return nil
    }

    private static func displayPlan(raw: String?, hasPaidVibe: Bool) -> String? {
        guard let raw = nonEmpty(raw) else { return hasPaidVibe ? "Pro" : nil }
        switch raw.uppercased() {
        case "ENTERPRISE": return "Enterprise"
        case "TEAM": return "Team"
        case "PRO": return "Pro"
        case "INDIVIDUAL": return hasPaidVibe ? "Pro" : "Free"
        case "FREE": return "Free"
        default: return raw.capitalized
        }
    }

    static func decodeJWTClaims(_ jwt: String) -> [String: Any]? {
        let parts = jwt.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var base64 = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = base64.count % 4
        if remainder > 0 {
            base64 += String(repeating: "=", count: 4 - remainder)
        }
        guard let data = Data(base64Encoded: base64) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func parseDateValue(_ raw: Any?) -> Date? {
        if let str = raw as? String {
            let frac = ISO8601DateFormatter()
            frac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let plain = ISO8601DateFormatter()
            plain.formatOptions = [.withInternetDateTime]
            return frac.date(from: str) ?? plain.date(from: str)
        }
        if let num = flexibleDouble(raw), num > 0 {
            // Heuristic: > 1e11 is epoch milliseconds, otherwise epoch seconds.
            return Date(timeIntervalSince1970: num > 100_000_000_000 ? num / 1000.0 : num)
        }
        return nil
    }

    private static func isoString(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private static func flexibleDouble(_ value: Any?) -> Double? {
        if let d = value as? Double { return d }
        if let i = value as? Int { return Double(i) }
        if let i64 = value as? Int64 { return Double(i64) }
        if let s = value as? String { return Double(s.trimmingCharacters(in: .whitespacesAndNewlines)) }
        return nil
    }

    private static func clampPercent(_ value: Double) -> Double {
        max(0, min(100, value))
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    private static func urlFormEncode(_ string: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return string.addingPercentEncoding(withAllowedCharacters: allowed) ?? string
    }

    private static func error(_ message: String) -> NSError {
        NSError(domain: "LLMUsageBar.Mistral", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

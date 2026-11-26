import Foundation

enum UsageRefresher {
    static func refresh(_ config: AppConfig) -> AppConfig {
        var updated = config
        let profiles = updated.profiles
        var refreshed = Array<LaunchProfile?>(repeating: nil, count: profiles.count)
        let lock = NSLock()

        let allowKeychain = config.allowsCookieKeychain
        DispatchQueue.concurrentPerform(iterations: profiles.count) { index in
            var profile = profiles[index]
            switch profile.provider {
            case .claude:
                profile = refreshClaude(profile, allowKeychain: allowKeychain)
            case .codex:
                profile = refreshCodex(profile)
            case .gemini:
                profile = refreshGemini(profile)
            case .mistral:
                profile = refreshMistral(profile, allowKeychain: allowKeychain)
            }
            lock.lock()
            refreshed[index] = profile
            lock.unlock()
        }

        for index in refreshed.indices {
            if let profile = refreshed[index] {
                updated.profiles[index] = profile
            }
        }
        return updated
    }

    static func quotaProof(_ config: AppConfig) -> QuotaProofReport {
        QuotaProofReport(
            generatedAt: isoString(Date()) ?? "",
            profiles: config.profiles.map { profile in
                switch profile.provider {
                case .claude:
                    return claudeProof(profile)
                case .codex:
                    return codexProof(profile)
                case .gemini:
                    return geminiProof(profile)
                case .mistral:
                    return mistralProof(profile)
                }
            })
    }

    private static func claudeProof(_ profile: LaunchProfile) -> QuotaProof {
        let endpoint = "https://claude.ai/api/organizations/{org}/usage"
        do {
            let cookieHeader = try claudeCookieHeader(for: profile, allowKeychain: true)
            let orgID = try claudeOrganizationID(cookieHeader: cookieHeader)
            let response = try SimpleHTTP.get(
                URL(string: "https://claude.ai/api/organizations/\(orgID)/usage")!,
                headers: claudeHeaders(cookieHeader: cookieHeader))
            guard response.statusCode == 200,
                  let json = try JSONSerialization.jsonObject(with: response.data) as? [String: Any] else {
                return QuotaProof(
                    provider: profile.provider,
                    email: profile.accountEmail,
                    plan: profile.accountPlan,
                    endpoint: endpoint,
                    httpStatus: response.statusCode,
                    status: "Claude usage HTTP \(response.statusCode)",
                    parserMatchesProvider: false,
                    windows: [],
                    creditsRemaining: nil)
            }

            let windows = [
                claudeProofWindow(key: "five_hour", title: "5h", json: json),
                claudeProofWindow(key: "seven_day", title: "Week", json: json),
                claudeProofWindow(key: "seven_day_sonnet", title: "Sonnet week", json: json),
            ].compactMap { $0 }
            return QuotaProof(
                provider: profile.provider,
                email: profile.accountEmail,
                plan: profile.accountPlan,
                endpoint: endpoint,
                httpStatus: response.statusCode,
                status: windows.isEmpty ? "Claude usage unavailable" : nil,
                parserMatchesProvider: !windows.isEmpty && windows.allSatisfy(\.matches),
                windows: windows,
                creditsRemaining: nil)
        } catch {
            return QuotaProof(
                provider: profile.provider,
                email: profile.accountEmail,
                plan: profile.accountPlan,
                endpoint: endpoint,
                httpStatus: nil,
                status: error.localizedDescription,
                parserMatchesProvider: false,
                windows: [],
                creditsRemaining: nil)
        }
    }

    private static func codexProof(_ profile: LaunchProfile) -> QuotaProof {
        let endpoint = "codex app-server · account/rateLimits/read"
        let account = CodexAuthStore.accountInfo(dataDir: profile.dataDir)
        do {
            let json = try codexUsageJSON(profile: profile).usage
            let rateLimit = json["rate_limit"] as? [String: Any]
            let windows = [
                codexProofWindow(rateLimit?["primary_window"]),
                codexProofWindow(rateLimit?["secondary_window"]),
            ].compactMap { $0 }
            let credits = json["credits"] as? [String: Any]
            let balance = flexibleDouble(credits?["balance"])
            let plan = CodexAuthStore.displayPlan((json["plan_type"] as? String) ?? account?.plan)

            return QuotaProof(
                provider: profile.provider,
                email: account?.email ?? profile.accountEmail,
                plan: plan,
                endpoint: endpoint,
                httpStatus: nil,
                status: windows.isEmpty && balance == nil ? "ChatGPT usage unavailable" : nil,
                parserMatchesProvider: !windows.isEmpty && windows.allSatisfy(\.matches),
                windows: windows,
                creditsRemaining: balance)
        } catch {
            return QuotaProof(
                provider: profile.provider,
                email: account?.email ?? profile.accountEmail,
                plan: account?.plan ?? profile.accountPlan,
                endpoint: endpoint,
                httpStatus: nil,
                status: error.localizedDescription,
                parserMatchesProvider: false,
                windows: [],
                creditsRemaining: nil)
        }
    }

    /// Claude's session cookies. Prefers the live DevTools port of a running Claude
    /// window (no keychain, no prompt); only falls back to the encrypted cookie store
    /// when `allowKeychain` is set. Only Claude's own Safe Storage key can decrypt
    /// Claude's cookies, so we never probe other browsers' keychain items.
    static func claudeCookieHeader(for profile: LaunchProfile, allowKeychain: Bool) throws -> String {
        if let live = ClaudeCDPCookieReader.cookieHeader(from: profile.dataDir) {
            return live
        }
        guard allowKeychain else {
            throw NSError(
                domain: "LLMUsageBar.Claude",
                code: 4,
                userInfo: [NSLocalizedDescriptionKey: "Open Claude to refresh usage (cookie-store access is off in Settings)."])
        }
        return try ElectronCookieReader.cookieHeader(
            from: profile.dataDir,
            domains: ["claude.ai"],
            keychainServices: [
                "Claude Safe Storage",
                "Chromium Safe Storage",
            ])
    }

    private static func refreshClaude(_ profile: LaunchProfile, allowKeychain: Bool) -> LaunchProfile {
        var profile = profile
        do {
            let cookieHeader = try claudeCookieHeader(for: profile, allowKeychain: allowKeychain)
            // Ask who is actually signed in. A data directory keeps the previous
            // account's caches after a sign-in to another one, so guessing from local
            // files is exactly what mislabelled accounts and hid their history.
            if let account = try? claudeAccount(cookieHeader: cookieHeader) {
                profile.apply(serverAccount: account)
            }
            let orgID = try claudeOrganizationID(cookieHeader: cookieHeader)
            profile.organizationUUID = orgID
            let usage = try claudeUsage(cookieHeader: cookieHeader, orgID: orgID, profile: profile)
            profile.usage = usage
            profile.usageStale = false
            profile.refreshError = nil
            if let email = usage.accountEmail {
                profile.accountEmail = email
                profile.label = "\(profile.provider.rawValue) - \(email)"
                profile.signedIn = true
            }
            if let plan = usage.accountPlan {
                profile.accountPlan = plan
            }
        } catch {
            applyFailure(&profile, source: "claude-web", error: error)
        }
        return profile
    }

    /// Records a refresh failure without discarding the last good usage numbers.
    /// A transient error (network blip, app closed, keychain declined) keeps the
    /// previous windows and just marks them stale; only when we have nothing
    /// cached do we surface the error text in place of usage.
    private static func applyFailure(_ profile: inout LaunchProfile, source: String, error: Error) {
        let message = error.localizedDescription
        profile.refreshError = message
        if let existing = profile.usage, !existing.windows.isEmpty {
            profile.usageStale = true
        } else {
            profile.usageStale = false
            profile.usage = UsageInfo(
                source: source,
                status: message,
                windows: [],
                creditsRemaining: nil,
                accountEmail: profile.accountEmail,
                accountPlan: profile.accountPlan,
                updatedAt: Date())
        }
    }

    private static func refreshCodex(_ profile: LaunchProfile) -> LaunchProfile {
        var profile = profile
        let account = CodexAuthStore.accountInfo(dataDir: profile.dataDir)
        if let email = account?.email {
            profile.accountEmail = email
            profile.label = "\(profile.provider.rawValue) - \(email)"
            profile.signedIn = true
        }
        if let plan = account?.plan {
            profile.accountPlan = plan
        }
        if let accountID = account?.accountID {
            profile.accountUUID = accountID
        }

        do {
            let usage = try codexUsage(profile: profile)
            profile.usage = usage
            profile.usageStale = false
            profile.refreshError = nil
            if let email = usage.accountEmail {
                profile.accountEmail = email
                profile.label = "\(profile.provider.rawValue) - \(email)"
            }
            if let plan = usage.accountPlan {
                profile.accountPlan = plan
            }
        } catch {
            applyFailure(&profile, source: "codex-oauth", error: error)
        }
        return profile
    }

    private static func refreshGemini(_ profile: LaunchProfile) -> LaunchProfile {
        var profile = profile
        do {
            let snapshot = try GeminiLanguageServer.fetchUsage(for: profile)
            if let email = snapshot.account.email {
                profile.accountEmail = email
                profile.accountUUID = email.lowercased()
                profile.label = "\(profile.provider.displayName) - \(email)"
                profile.signedIn = true
                profile.isPendingLogin = false
                profile.identityVerified = true
            }
            if let name = snapshot.account.name {
                profile.accountName = name
                if profile.accountEmail == nil {
                    profile.label = "\(profile.provider.displayName) - \(name)"
                    profile.signedIn = true
                    profile.isPendingLogin = false
                }
            }
            if let plan = snapshot.account.plan {
                profile.accountPlan = plan
            }
            profile.usage = UsageInfo(
                source: "antigravity-ls",
                status: snapshot.windows.isEmpty ? "Gemini usage unavailable" : nil,
                windows: snapshot.windows,
                creditsRemaining: nil,
                accountEmail: snapshot.account.email ?? profile.accountEmail,
                accountPlan: snapshot.account.plan ?? profile.accountPlan,
                updatedAt: Date(),
                manualResets: nil)
            profile.usageStale = false
            profile.refreshError = nil
        } catch {
            applyFailure(&profile, source: "antigravity-ls", error: error)
        }
        return profile
    }

    private static func geminiProof(_ profile: LaunchProfile) -> QuotaProof {
        let endpoint = "antigravity://language_server/RetrieveUserQuotaSummary"
        do {
            let snapshot = try GeminiLanguageServer.fetchUsage(for: profile)
            return QuotaProof(
                provider: profile.provider,
                email: snapshot.account.email ?? profile.accountEmail,
                plan: snapshot.account.plan ?? profile.accountPlan,
                endpoint: endpoint,
                httpStatus: 200,
                status: snapshot.proofWindows.isEmpty ? "Gemini usage unavailable" : nil,
                parserMatchesProvider: !snapshot.proofWindows.isEmpty && snapshot.proofWindows.allSatisfy(\.matches),
                windows: snapshot.proofWindows,
                creditsRemaining: nil)
        } catch {
            return QuotaProof(
                provider: profile.provider,
                email: profile.accountEmail,
                plan: profile.accountPlan,
                endpoint: endpoint,
                httpStatus: nil,
                status: error.localizedDescription,
                parserMatchesProvider: false,
                windows: [],
                creditsRemaining: nil)
        }
    }

    private static func refreshMistral(_ profile: LaunchProfile, allowKeychain: Bool) -> LaunchProfile {
        var profile = profile
        do {
            let snapshot = try MistralAuthStore.fetchUsage(for: profile, allowKeychain: allowKeychain)
            if let email = snapshot.account.email {
                profile.accountEmail = email
                profile.accountUUID = snapshot.account.userID ?? email.lowercased()
                profile.label = "\(profile.provider.displayName) - \(email)"
                profile.signedIn = true
                profile.isPendingLogin = false
                profile.identityVerified = true
            } else if let name = snapshot.account.name {
                profile.accountName = name
                profile.label = "\(profile.provider.displayName) - \(name)"
                profile.signedIn = true
                profile.isPendingLogin = false
            }
            if let name = snapshot.account.name {
                profile.accountName = name
            }
            if let orgID = snapshot.account.organizationID {
                profile.organizationUUID = orgID
            }
            if let plan = snapshot.account.plan {
                profile.accountPlan = plan
            }
            profile.usage = UsageInfo(
                source: snapshot.viaCLI ? "vibe-cli" : "mistral-trpc",
                status: snapshot.status,
                windows: snapshot.windows,
                creditsRemaining: nil,
                accountEmail: snapshot.account.email ?? profile.accountEmail,
                accountPlan: snapshot.account.plan ?? profile.accountPlan,
                updatedAt: Date(),
                manualResets: nil)
            profile.usageStale = false
            profile.refreshError = nil
        } catch {
            applyFailure(&profile, source: "mistral-trpc", error: error)
        }
        return profile
    }

    private static func mistralProof(_ profile: LaunchProfile) -> QuotaProof {
        let endpoint = "https://chat.mistral.ai/api/trpc/billing.budget"
        do {
            let snapshot = try MistralAuthStore.fetchUsage(for: profile, allowKeychain: true)
            return QuotaProof(
                provider: profile.provider,
                email: snapshot.account.email ?? profile.accountEmail,
                plan: snapshot.account.plan ?? profile.accountPlan,
                endpoint: snapshot.viaCLI ? "vibe-app-server · account/read" : endpoint,
                httpStatus: 200,
                status: snapshot.status,
                parserMatchesProvider: !snapshot.proofWindows.isEmpty && snapshot.proofWindows.allSatisfy(\.matches),
                windows: snapshot.proofWindows,
                creditsRemaining: nil)
        } catch {
            return QuotaProof(
                provider: profile.provider,
                email: profile.accountEmail,
                plan: profile.accountPlan,
                endpoint: endpoint,
                httpStatus: nil,
                status: error.localizedDescription,
                parserMatchesProvider: false,
                windows: [],
                creditsRemaining: nil)
        }
    }

    static func claudeOrganizationID(cookieHeader: String) throws -> String {
        if let direct = cookieValue("lastActiveOrg", in: cookieHeader) {
            return direct
        }
        let response = try SimpleHTTP.get(
            URL(string: "https://claude.ai/api/bootstrap")!,
            headers: claudeHeaders(cookieHeader: cookieHeader))
        guard response.statusCode == 200,
              let json = try JSONSerialization.jsonObject(with: response.data) as? [String: Any],
              let account = json["account"] as? [String: Any],
              let org = account["lastActiveOrgId"] as? String else {
            throw NSError(domain: "LLMUsageBar.Claude", code: response.statusCode, userInfo: [NSLocalizedDescriptionKey: "Claude organization unavailable"])
        }
        return org
    }

    /// The account the cookies belong to, straight from claude.ai. `/api/account`
    /// returns the account object at the top level; `/api/bootstrap` wraps the same
    /// object in `account`, so either shape is accepted.
    static func claudeAccount(cookieHeader: String) throws -> ClaudeServerAccount {
        var lastStatus = 0
        for path in ["account", "bootstrap"] {
            let response = try SimpleHTTP.get(
                URL(string: "https://claude.ai/api/\(path)")!,
                headers: claudeHeaders(cookieHeader: cookieHeader))
            lastStatus = response.statusCode
            guard response.statusCode == 200,
                  let json = try? JSONSerialization.jsonObject(with: response.data) as? [String: Any] else {
                continue
            }
            let account = (json["account"] as? [String: Any]) ?? json
            guard let uuid = account["uuid"] as? String, !uuid.isEmpty else { continue }
            let email = (account["email_address"] as? String)?.lowercased()
            let name = [account["display_name"], account["full_name"]]
                .compactMap { ($0 as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first { !$0.isEmpty }
            return ClaudeServerAccount(uuid: uuid, email: email, name: name)
        }
        throw NSError(domain: "LLMUsageBar.Claude", code: lastStatus, userInfo: [NSLocalizedDescriptionKey: "Claude account unavailable (HTTP \(lastStatus))"])
    }

    private static func claudeUsage(cookieHeader: String, orgID: String, profile: LaunchProfile) throws -> UsageInfo {
        let response = try SimpleHTTP.get(
            URL(string: "https://claude.ai/api/organizations/\(orgID)/usage")!,
            headers: claudeHeaders(cookieHeader: cookieHeader))
        guard response.statusCode == 200,
              let json = try JSONSerialization.jsonObject(with: response.data) as? [String: Any] else {
            throw NSError(domain: "LLMUsageBar.Claude", code: response.statusCode, userInfo: [NSLocalizedDescriptionKey: "Claude usage HTTP \(response.statusCode)"])
        }

        var windows: [UsageWindow] = []
        appendClaudeWindow(key: "five_hour", title: "5h", json: json, windows: &windows)
        appendClaudeWindow(key: "seven_day", title: "Week", json: json, windows: &windows)
        appendClaudeWindow(key: "seven_day_sonnet", title: "Sonnet week", json: json, windows: &windows)

        var manualResets = ManualResets.claude(json)
        if manualResets == nil {
            // Ordinary usage omits grant inventory. This GET requests the manual reset program.
            if let response = try? SimpleHTTP.get(
                URL(string: "https://claude.ai/api/organizations/\(orgID)/usage?cedar_ember=1&skip_spend=1")!,
                headers: claudeHeaders(cookieHeader: cookieHeader)), response.statusCode == 200,
               let extra = try? JSONSerialization.jsonObject(with: response.data) as? [String: Any] {
                manualResets = ManualResets.claude(extra)
            }
        }
        manualResets = manualResets ?? ManualResets.unavailable(previous: profile.usage?.manualResets, message: "Could not read manual reset inventory")

        return UsageInfo(
            source: "claude-web",
            status: windows.isEmpty ? "Claude usage unavailable" : nil,
            windows: windows,
            creditsRemaining: nil,
            accountEmail: profile.accountEmail,
            accountPlan: profile.accountPlan,
            updatedAt: Date(),
            manualResets: manualResets)
    }

    private static func appendClaudeWindow(key: String, title: String, json: [String: Any], windows: inout [UsageWindow]) {
        guard let block = json[key] as? [String: Any],
              let used = flexibleDouble(block["utilization"]) else { return }
        windows.append(UsageWindow(
            title: title,
            usedPercent: max(0, min(100, used)),
            remainingPercent: max(0, min(100, 100 - used)),
            resetsAt: (block["resets_at"] as? String).flatMap(parseISODate)))
    }

    private static func claudeProofWindow(key: String, title: String, json: [String: Any]) -> QuotaWindowProof? {
        guard let block = json[key] as? [String: Any],
              let providerUsed = flexibleDouble(block["utilization"]) else { return nil }
        let parsedUsed = clampPercent(providerUsed)
        let parsedRemaining = clampPercent(100 - providerUsed)
        let providerReset = block["resets_at"] as? String
        let parsedReset = providerReset.flatMap(parseISODate).flatMap(isoString)
        return QuotaWindowProof(
            title: title,
            providerUsedPercent: providerUsed,
            parsedUsedPercent: parsedUsed,
            providerRemainingPercent: parsedRemaining,
            parsedRemainingPercent: parsedRemaining,
            providerReset: providerReset,
            parsedReset: parsedReset,
            matches: percentMatches(providerUsed, parsedUsed) && percentMatches(clampPercent(100 - providerUsed), parsedRemaining) && (providerReset == nil || parsedReset != nil))
    }

    static func claudeHeaders(cookieHeader: String) -> [String: String] {
        [
            "Cookie": cookieHeader,
            "Accept": "application/json",
            "Content-Type": "application/json",
            "Origin": "https://claude.ai",
            "Referer": "https://claude.ai",
            "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X) LLMUsageBar",
        ]
    }

    private static func codexUsage(profile: LaunchProfile) throws -> UsageInfo {
        let (json, resetJSON) = try codexUsageJSON(profile: profile)

        let account = CodexAuthStore.accountInfo(dataDir: profile.dataDir)
        let plan = CodexAuthStore.displayPlan((json["plan_type"] as? String) ?? account?.plan)
        let rateLimit = json["rate_limit"] as? [String: Any]
        var windows: [UsageWindow] = []
        // The window slots aren't fixed to 5h/weekly (a Plus account often reports only
        // a single weekly window in primary_window), so label each by its real duration.
        appendCodexWindow(rateLimit?["primary_window"], windows: &windows)
        appendCodexWindow(rateLimit?["secondary_window"], windows: &windows)

        let credits = json["credits"] as? [String: Any]
        let balance = flexibleDouble(credits?["balance"])

        let manualResets = resetJSON.flatMap { ManualResets.codex($0) }
            ?? ManualResets.unavailable(previous: profile.usage?.manualResets, message: "Could not read manual reset inventory")

        return UsageInfo(
            source: "codex-cli",
            status: windows.isEmpty && balance == nil ? "ChatGPT usage unavailable" : nil,
            windows: windows,
            creditsRemaining: balance,
            accountEmail: account?.email,
            accountPlan: plan,
            updatedAt: Date(),
            manualResets: manualResets)
    }

    /// ChatGPT usage as the official Codex CLI reads it (`account/rateLimits/read` on
    /// `codex app-server`), reshaped into the field names the parsers above use. Nothing
    /// here talks to ChatGPT directly: Codex makes the request and handles its own login.
    private static func codexUsageJSON(profile: LaunchProfile) throws -> (usage: [String: Any], resets: [String: Any]?) {
        guard CodexSessionTransfer.hasCLI(for: profile) else {
            throw NSError(domain: "LLMUsageBar.Codex", code: 1, userInfo: [NSLocalizedDescriptionKey: "Codex CLI not found. Install the ChatGPT app or run `brew install codex`."])
        }
        return codexUsageJSON(fromAppServer: try CodexSessionTransfer.rateLimits(for: profile))
    }

    static func codexUsageJSON(fromAppServer response: [String: Any]) -> (usage: [String: Any], resets: [String: Any]?) {
        let limits = (response["rateLimits"] as? [String: Any])
            ?? ((response["rateLimitsByLimitId"] as? [String: Any])?["codex"] as? [String: Any])
            ?? [:]
        func window(_ raw: Any?) -> [String: Any]? {
            guard let block = raw as? [String: Any], let used = flexibleDouble(block["usedPercent"]) else { return nil }
            var result: [String: Any] = ["used_percent": used]
            if let minutes = flexibleDouble(block["windowDurationMins"]) { result["limit_window_seconds"] = minutes * 60 }
            if let reset = flexibleDouble(block["resetsAt"]) { result["reset_at"] = reset }
            return result
        }
        var rateLimit: [String: Any] = [:]
        rateLimit["primary_window"] = window(limits["primary"])
        rateLimit["secondary_window"] = window(limits["secondary"])
        var usage: [String: Any] = ["rate_limit": rateLimit]
        if let plan = limits["planType"] as? String { usage["plan_type"] = plan }
        if let credits = limits["credits"] as? [String: Any] {
            usage["credits"] = ["balance": credits["balance"] ?? NSNull()]
        }

        var resets: [String: Any]?
        if let summary = response["rateLimitResetCredits"] as? [String: Any],
           let credits = summary["credits"] as? [[String: Any]] {
            resets = ["credits": credits.map { credit -> [String: Any] in
                var entry: [String: Any] = [
                    "status": credit["status"] ?? "",
                    "reset_type": credit["resetType"] as? String == "codexRateLimits" ? "codex_rate_limits" : (credit["resetType"] ?? ""),
                ]
                if let expiry = flexibleDouble(credit["expiresAt"]) {
                    entry["expires_at"] = isoString(Date(timeIntervalSince1970: expiry)) ?? NSNull()
                } else {
                    entry["expires_at"] = NSNull()
                }
                return entry
            }]
        }
        return (usage, resets)
    }

    private static func appendCodexWindow(_ raw: Any?, windows: inout [UsageWindow]) {
        guard let block = raw as? [String: Any],
              let used = flexibleDouble(block["used_percent"]) else { return }
        let title = codexWindowTitle(seconds: flexibleDouble(block["limit_window_seconds"]))
        // Avoid two windows colliding on the same label (e.g. two weekly slots).
        let unique = windows.contains(where: { $0.title == title }) ? "\(title) 2" : title
        let resetSeconds = flexibleDouble(block["reset_at"])
        windows.append(UsageWindow(
            title: unique,
            usedPercent: max(0, min(100, used)),
            remainingPercent: max(0, min(100, 100 - used)),
            resetsAt: resetSeconds.map { Date(timeIntervalSince1970: $0) }))
    }

    /// Labels a ChatGPT rate window by how long it spans: ~5h session, ~daily, or weekly.
    private static func codexWindowTitle(seconds: Double?) -> String {
        guard let seconds, seconds > 0 else { return "5h" }
        switch seconds {
        case ..<64_800: return "5h"      // up to ~18h: the short "session" window (5h = 18000s)
        case ..<172_800: return "Daily"  // ~1 day (86400s)
        default: return "Week"           // multi-day (604800s = 7 days)
        }
    }

    private static func codexProofWindow(_ raw: Any?) -> QuotaWindowProof? {
        guard let block = raw as? [String: Any],
              let providerUsed = flexibleDouble(block["used_percent"]) else { return nil }
        let title = codexWindowTitle(seconds: flexibleDouble(block["limit_window_seconds"]))
        let parsedUsed = clampPercent(providerUsed)
        let parsedRemaining = clampPercent(100 - providerUsed)
        let resetSeconds = flexibleDouble(block["reset_at"])
        let parsedReset = resetSeconds.map { Date(timeIntervalSince1970: $0) }.flatMap(isoString)
        return QuotaWindowProof(
            title: title,
            providerUsedPercent: providerUsed,
            parsedUsedPercent: parsedUsed,
            providerRemainingPercent: parsedRemaining,
            parsedRemainingPercent: parsedRemaining,
            providerReset: resetSeconds.map { String(format: "%.0f", $0) },
            parsedReset: parsedReset,
            matches: percentMatches(providerUsed, parsedUsed) && percentMatches(clampPercent(100 - providerUsed), parsedRemaining) && (resetSeconds == nil || parsedReset != nil))
    }

    private static func cookieValue(_ name: String, in header: String) -> String? {
        header.split(separator: ";").compactMap { part -> String? in
            let pieces = part.trimmingCharacters(in: .whitespaces).split(separator: "=", maxSplits: 1)
            guard pieces.count == 2, pieces[0] == name else { return nil }
            return String(pieces[1])
        }.first
    }

    private static func flexibleDouble(_ value: Any?) -> Double? {
        if let value = value as? Double { return value }
        if let value = value as? Int { return Double(value) }
        if let value = value as? String { return Double(value.trimmingCharacters(in: .whitespacesAndNewlines)) }
        return nil
    }

    private static func clampPercent(_ value: Double) -> Double {
        max(0, min(100, value))
    }

    private static func percentMatches(_ provider: Double?, _ parsed: Double?) -> Bool {
        switch (provider, parsed) {
        case let (provider?, parsed?):
            return abs(clampPercent(provider) - parsed) < 0.0001
        case (nil, nil):
            return true
        default:
            return false
        }
    }

    private static func isoString(_ date: Date?) -> String? {
        guard let date else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private static func parseISODate(_ raw: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return fractional.date(from: raw) ?? plain.date(from: raw)
    }
}


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
        let endpoint = "https://chatgpt.com/backend-api/wham/usage"
        let account = CodexAuthStore.accountInfo(dataDir: profile.dataDir)
        do {
            var credentials = try CodexAuthStore.loadCredentials(dataDir: profile.dataDir)
            var response = try codexUsageResponse(credentials: credentials)
            if response.statusCode == 401 || response.statusCode == 403 {
                credentials = try CodexAuthStore.refreshCredentials(credentials)
                response = try codexUsageResponse(credentials: credentials)
            }
            guard (200...299).contains(response.statusCode),
                  let json = try JSONSerialization.jsonObject(with: response.data) as? [String: Any] else {
                return QuotaProof(
                    provider: profile.provider,
                    email: account?.email ?? profile.accountEmail,
                    plan: account?.plan ?? profile.accountPlan,
                    endpoint: endpoint,
                    httpStatus: response.statusCode,
                    status: "ChatGPT usage HTTP \(response.statusCode)",
                    parserMatchesProvider: false,
                    windows: [],
                    creditsRemaining: nil)
            }

            let rateLimit = json["rate_limit"] as? [String: Any]
            let windows = [
                codexProofWindow(rateLimit?["primary_window"], title: "5h"),
                codexProofWindow(rateLimit?["secondary_window"], title: "Week"),
            ].compactMap { $0 }
            let credits = json["credits"] as? [String: Any]
            let balance = flexibleDouble(credits?["balance"])
            let plan = CodexAuthStore.displayPlan((json["plan_type"] as? String) ?? account?.plan)

            return QuotaProof(
                provider: profile.provider,
                email: account?.email ?? profile.accountEmail,
                plan: plan,
                endpoint: endpoint,
                httpStatus: response.statusCode,
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
            let orgID = try claudeOrganizationID(cookieHeader: cookieHeader)
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

        return UsageInfo(
            source: "claude-web",
            status: windows.isEmpty ? "Claude usage unavailable" : nil,
            windows: windows,
            creditsRemaining: nil,
            accountEmail: profile.accountEmail,
            accountPlan: profile.accountPlan,
            updatedAt: Date())
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
        var credentials = try CodexAuthStore.loadCredentials(dataDir: profile.dataDir)
        var response = try codexUsageResponse(credentials: credentials)
        if response.statusCode == 401 || response.statusCode == 403 {
            credentials = try CodexAuthStore.refreshCredentials(credentials)
            response = try codexUsageResponse(credentials: credentials)
        }
        guard (200...299).contains(response.statusCode),
              let json = try JSONSerialization.jsonObject(with: response.data) as? [String: Any] else {
            throw NSError(domain: "LLMUsageBar.Codex", code: response.statusCode, userInfo: [NSLocalizedDescriptionKey: "ChatGPT usage HTTP \(response.statusCode)"])
        }

        let account = CodexAuthStore.accountInfo(dataDir: profile.dataDir)
        let plan = CodexAuthStore.displayPlan((json["plan_type"] as? String) ?? account?.plan)
        let rateLimit = json["rate_limit"] as? [String: Any]
        var windows: [UsageWindow] = []
        appendCodexWindow(rateLimit?["primary_window"], title: "5h", windows: &windows)
        appendCodexWindow(rateLimit?["secondary_window"], title: "Week", windows: &windows)

        let credits = json["credits"] as? [String: Any]
        let balance = flexibleDouble(credits?["balance"])

        return UsageInfo(
            source: "codex-oauth",
            status: windows.isEmpty && balance == nil ? "ChatGPT usage unavailable" : nil,
            windows: windows,
            creditsRemaining: balance,
            accountEmail: account?.email,
            accountPlan: plan,
            updatedAt: Date())
    }

    private static func codexUsageResponse(credentials: CodexCredentials) throws -> HTTPResponse {
        var headers = [
            "Authorization": "Bearer \(credentials.accessToken)",
            "Accept": "application/json",
            "User-Agent": "LLMUsageBar",
        ]
        if let accountID = credentials.accountID {
            headers["ChatGPT-Account-Id"] = accountID
        }
        return try SimpleHTTP.get(
            URL(string: "https://chatgpt.com/backend-api/wham/usage")!,
            headers: headers)
    }

    private static func appendCodexWindow(_ raw: Any?, title: String, windows: inout [UsageWindow]) {
        guard let block = raw as? [String: Any],
              let used = flexibleDouble(block["used_percent"]) else { return }
        let resetSeconds = flexibleDouble(block["reset_at"])
        windows.append(UsageWindow(
            title: title,
            usedPercent: max(0, min(100, used)),
            remainingPercent: max(0, min(100, 100 - used)),
            resetsAt: resetSeconds.map { Date(timeIntervalSince1970: $0) }))
    }

    private static func codexProofWindow(_ raw: Any?, title: String) -> QuotaWindowProof? {
        guard let block = raw as? [String: Any],
              let providerUsed = flexibleDouble(block["used_percent"]) else { return nil }
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


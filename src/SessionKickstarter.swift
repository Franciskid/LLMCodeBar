import Foundation

/// Opt-in automation that starts a fresh 5-hour usage window for selected accounts
/// by sending one tiny prompt on the cheapest model. This kicks off the session
/// counter so the window is "running" without the user having to open the app.
///
/// Notes / caveats:
/// - Claude uses its private web endpoints (the same ones the desktop app uses);
///   Codex uses the token-based backend the Codex CLI uses. Both are unofficial and
///   may change; failures are surfaced as text and never crash anything.
/// - It consumes a negligible amount of quota by design - that's what starts the window.
enum SessionKickstarter {
    private static let queue = DispatchQueue(label: "fr.fraserv.llmusagebar.session-kick")
    /// Never fire more than once per this interval per account.
    private static let minInterval: TimeInterval = 30 * 60
    /// The window a start opens. ChatGPT's usage can't be trusted to show that one is
    /// running (a "hi" leaves it at 0%), so after starting a ChatGPT window nothing is
    /// started again until it has had time to end.
    private static let windowLength: TimeInterval = 5 * 3600
    private static let kicksKey = "sessionKicks"

    /// When each account's window was last started, kept on disk so a restart of
    /// LLMCodeBar doesn't start another one.
    private static var lastKick: [String: Date] {
        get {
            let stored = UserDefaults.standard.dictionary(forKey: kicksKey) as? [String: Double] ?? [:]
            return stored.mapValues { Date(timeIntervalSince1970: $0) }
        }
        set {
            let recent = newValue.filter { Date().timeIntervalSince($0.value) < 24 * 3600 }
            UserDefaults.standard.set(recent.mapValues(\.timeIntervalSince1970), forKey: kicksKey)
        }
    }

    /// Used only when the account's own model list can't be read. Retired slugs return
    /// `model_not_available`, so we fall through until one is accepted; `nil` = the
    /// account default.
    private static let claudeFallbackModels: [String?] = [
        "claude-haiku-4-5-20251001",
        nil,
    ]
    private static let codexModelFallbacks = ["gpt-5.1-codex", "gpt-5-codex", "gpt-5"]

    /// How expensive a model family is, cheapest first. Anything unknown sorts last, so a
    /// new family never gets picked over a known cheap one.
    private static let claudeFamilies = ["haiku", "sonnet", "opus", "fable"]
    private static let codexTiers: [[String]] = [
        ["affordable", "efficient", "luna", "mini", "nano"],
        ["balanced", "terra"],
        ["workhorse", "sol"],
        ["frontier", "astra"],
    ]

    /// The account's own Claude models, cheapest first, from the same list claude.ai
    /// builds its model picker from. Retired ones (`inactive`) are skipped, and within a
    /// family the list's own order (newest first) is kept.
    static func cheapestClaudeModels(headers: [String: String]) -> [String] {
        guard let response = try? SimpleHTTP.get(URL(string: "https://claude.ai/api/bootstrap")!, headers: headers, timeout: 15),
              response.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: response.data) as? [String: Any],
              let memberships = (json["account"] as? [String: Any])?["memberships"] as? [[String: Any]] else {
            return []
        }
        let entries = memberships
            .compactMap { ($0["organization"] as? [String: Any])?["claude_ai_bootstrap_models_config"] as? [[String: Any]] }
            .first { !$0.isEmpty } ?? []
        let models = entries.enumerated().compactMap { index, entry -> (rank: Int, index: Int, model: String)? in
            guard let model = entry["model"] as? String, entry["inactive"] as? Bool != true else { return nil }
            let family = claudeFamilies.firstIndex { model.contains($0) } ?? claudeFamilies.count
            // "More models" entries are older ones; prefer the main picker's.
            let overflow = entry["overflow"] as? Bool == true ? 1 : 0
            return (family * 2 + overflow, index, model)
        }
        return models.sorted { ($0.rank, $0.index) < ($1.rank, $1.index) }.map(\.model)
    }

    /// The ChatGPT account's Codex models, cheapest first, judged from their names and
    /// descriptions (the list carries no prices).
    static func cheapestCodexModels(for profile: LaunchProfile) -> [String] {
        let models = CodexSessionTransfer.availableModels(for: profile)
        let ranked = models.enumerated().compactMap { index, entry -> (rank: Int, index: Int, model: String)? in
            guard let model = (entry["model"] as? String) ?? (entry["id"] as? String), entry["hidden"] as? Bool != true else { return nil }
            let text = "\(model) \(entry["displayName"] as? String ?? "") \(entry["description"] as? String ?? "")".lowercased()
            let tier = codexTiers.firstIndex { words in words.contains { text.contains($0) } } ?? codexTiers.count
            return (tier, index, model)
        }
        return ranked.sorted { ($0.rank, $0.index) < ($1.rank, $1.index) }.map(\.model)
    }

    // MARK: Auto (timer-driven)

    static func runIfNeeded(profiles: [LaunchProfile], allowKeychain: Bool, onSessionStarted: (() -> Void)? = nil) {
        let candidates = profiles.filter { $0.autoStartsSession }
        guard !candidates.isEmpty else { return }

        queue.async {
            var started = false
            for profile in candidates {
                guard shouldKick(profile) else { continue }
                lastKick[profile.id] = Date()
                let outcome = startSession(for: profile, allowKeychain: allowKeychain)
                let source = "Auto-start · \(ProfileFormatting.title(for: profile))"
                if outcome.hasPrefix("Started") {
                    started = true
                    ActivityLog.shared.info(source, outcome)
                } else {
                    ActivityLog.shared.error(source, outcome)
                }
            }
            if started { onSessionStarted?() }
        }
    }

    /// Whether the 5-hour clock is currently *not* running - i.e. the session is
    /// idle/reset/never-started, so there's something to start. Never acts on missing
    /// or stale data. Note this keys off whether the clock has started, not raw usage:
    /// a session that just started sits at ~0% but is running.
    static func isSessionIdle(_ profile: LaunchProfile) -> Bool {
        guard let usage = profile.usage, profile.usageStale != true else { return false }
        switch profile.provider {
        case .claude:
            guard let window = usage.windows.first(where: { $0.title == "5h" }) else {
                return true // no 5h window → session hasn't started
            }
            // Claude only reports a reset time once the window is running, so that's
            // the true "clock started" signal (usage may still be ~0% just after start).
            if let reset = window.resetsAt { return reset <= Date() }
            return window.usedPercent <= 0.5
        case .codex:
            // ChatGPT reports whatever rate window applies (a Plus account often shows
            // only the weekly limit), so use the 5h window if present, else the primary.
            let window = usage.windows.first { $0.title == "5h" } ?? usage.windows.first
            guard let window else { return true }
            if let reset = window.resetsAt, reset <= Date() { return true }
            return window.usedPercent <= 0.5
        }
    }

    static func shouldKick(_ profile: LaunchProfile, lastKick last: Date?, now: Date = Date()) -> Bool {
        if let last {
            let since = now.timeIntervalSince(last)
            if since < minInterval { return false }
            if profile.provider == .codex, since < windowLength { return false }
        }
        return isSessionIdle(profile)
    }

    private static func shouldKick(_ profile: LaunchProfile) -> Bool {
        shouldKick(profile, lastKick: lastKick[profile.id])
    }

    // MARK: Manual / shared

    /// Runs the full start-session flow and returns a human-readable result. Used by
    /// both the timer (auto) and the "Start 5h session now" button (manual test).
    @discardableResult
    static func startSession(for profile: LaunchProfile, allowKeychain: Bool) -> String {
        switch profile.provider {
        case .claude: return startClaudeSession(profile, allowKeychain: allowKeychain)
        case .codex: return startCodexSession(profile)
        }
    }

    // MARK: Claude

    private static func startClaudeSession(_ profile: LaunchProfile, allowKeychain: Bool) -> String {
        do {
            let cookieHeader = try UsageRefresher.claudeCookieHeader(for: profile, allowKeychain: allowKeychain)
            let orgID = try UsageRefresher.claudeOrganizationID(cookieHeader: cookieHeader)
            let headers = UsageRefresher.claudeHeaders(cookieHeader: cookieHeader)

            // 1. Create a throwaway conversation in the user's Claude account.
            let conversationUUID = UUID().uuidString.lowercased()
            let createURL = URL(string: "https://claude.ai/api/organizations/\(orgID)/chat_conversations")!
            let createResponse = try SimpleHTTP.send(
                createURL,
                method: "POST",
                jsonBody: ["uuid": conversationUUID, "name": ""],
                headers: headers)
            guard (200...299).contains(createResponse.statusCode) else {
                return "Couldn't start session - creating the chat failed (HTTP \(createResponse.statusCode))."
            }

            // 2. Send one minimal message - this is what starts the 5-hour window. A
            //    rejected model returns 403 before generating (nothing is sent), so we
            //    can safely try candidates until one is accepted.
            let completionURL = URL(string: "https://claude.ai/api/organizations/\(orgID)/chat_conversations/\(conversationUUID)/completion")!
            var completionHeaders = headers
            completionHeaders["Accept"] = "text/event-stream"

            let cheapest = cheapestClaudeModels(headers: headers)
            let candidates: [String?] = cheapest.isEmpty ? claudeFallbackModels : cheapest.prefix(3).map { $0 } + [nil]

            var lastStatus = 0
            var lastError = ""
            for model in candidates {
                var body: [String: Any] = [
                    "prompt": "hi",
                    "parent_message_uuid": "00000000-0000-4000-8000-000000000000",
                    "timezone": TimeZone.current.identifier,
                    "attachments": [],
                    "files": [],
                    "rendering_mode": "messages",
                ]
                if let model { body["model"] = model }

                let response = try SimpleHTTP.send(completionURL, method: "POST", jsonBody: body, headers: completionHeaders, timeout: 25)
                if (200...299).contains(response.statusCode) {
                    deleteClaudeConversation(orgID: orgID, uuid: conversationUUID, headers: headers)
                    return "Started a 5h session - sent “hi” on \(model ?? "the default model")."
                }
                lastStatus = response.statusCode
                lastError = conciseError(response.data)
                if !lastError.lowercased().contains("model") { break }
            }

            deleteClaudeConversation(orgID: orgID, uuid: conversationUUID, headers: headers)
            return "Chat created but the message failed (HTTP \(lastStatus)). \(lastError)"
        } catch {
            return "Failed to start session: \(error.localizedDescription)"
        }
    }

    private static func deleteClaudeConversation(orgID: String, uuid: String, headers: [String: String]) {
        let url = URL(string: "https://claude.ai/api/organizations/\(orgID)/chat_conversations/\(uuid)")!
        _ = try? SimpleHTTP.send(url, method: "DELETE", headers: headers, timeout: 8)
    }

    // MARK: Codex (experimental)

    /// Codex authenticates with the same bearer token the Codex CLI uses, so we can
    /// hit its `responses` backend directly (no browser bot-protection). Experimental:
    /// endpoint/model may need tweaks, so errors are surfaced verbatim.
    private static func startCodexSession(_ profile: LaunchProfile) -> String {
        do {
            var credentials = try CodexAuthStore.loadCredentials(dataDir: profile.dataDir)
            // Try the account's own configured model first; the ChatGPT backend rejects
            // any model it wasn't provisioned for.
            // The cheapest model the account offers, then the one it's set to use (which
            // it's certainly provisioned for), then names that used to work.
            var models = Array(cheapestCodexModels(for: profile).prefix(3))
            if let configured = CodexAuthStore.configuredModel(dataDir: profile.dataDir), !models.contains(configured) {
                models.append(configured)
            }
            models += codexModelFallbacks.filter { !models.contains($0) }
            var lastStatus = 0
            var lastError = ""
            for model in models {
                var response = try sendCodexMessage(model: model, credentials: credentials)
                if response.statusCode == 401 {
                    credentials = try CodexAuthStore.refreshCredentials(credentials)
                    response = try sendCodexMessage(model: model, credentials: credentials)
                }
                if (200...299).contains(response.statusCode) {
                    return "Started a ChatGPT 5h session - sent “hi” on \(model)."
                }
                lastStatus = response.statusCode
                lastError = conciseError(response.data)
                // Keep trying other models only on a model-availability error.
                if !lastError.lowercased().contains("model") { break }
            }
            return "Couldn't start ChatGPT session (HTTP \(lastStatus)). \(lastError)"
        } catch {
            return "Failed to start ChatGPT session: \(error.localizedDescription)"
        }
    }

    private static func sendCodexMessage(model: String, credentials: CodexCredentials) throws -> HTTPResponse {
        var headers = [
            "Authorization": "Bearer \(credentials.accessToken)",
            "Accept": "text/event-stream",
            "OpenAI-Beta": "responses=experimental",
            "originator": "codex_cli_rs",
            "session_id": UUID().uuidString,
            "User-Agent": "LLMUsageBar",
        ]
        if let accountID = credentials.accountID {
            headers["ChatGPT-Account-Id"] = accountID
        }
        let body: [String: Any] = [
            "model": model,
            "instructions": "",
            "input": [
                ["type": "message", "role": "user", "content": [["type": "input_text", "text": "hi"]]],
            ],
            "tools": [],
            "tool_choice": "auto",
            "parallel_tool_calls": false,
            "reasoning": ["effort": "low"],
            "store": false,
            "stream": true,
        ]
        return try SimpleHTTP.send(
            URL(string: "https://chatgpt.com/backend-api/codex/responses")!,
            method: "POST",
            jsonBody: body,
            headers: headers,
            timeout: 25)
    }

    // MARK: Helpers

    /// Pulls the human-readable `error.message` out of a provider's JSON error body,
    /// so the status line stays short instead of dumping the whole payload.
    private static func conciseError(_ data: Data) -> String {
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let error = json["error"] as? [String: Any], let message = error["message"] as? String {
                return message
            }
            if let message = json["detail"] as? String {
                return message
            }
        }
        let raw = String(data: data.prefix(120), encoding: .utf8) ?? ""
        return raw.replacingOccurrences(of: "\n", with: " ")
    }
}

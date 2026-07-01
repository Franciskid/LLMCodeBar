import Foundation

/// Opt-in automation that starts a fresh 5-hour usage window for selected accounts
/// by sending one tiny prompt on the cheapest model. This kicks off the session
/// counter so the window is "running" without the user having to open the app.
///
/// Notes / caveats:
/// - Claude uses its private web endpoints (the same ones the desktop app uses);
///   Codex uses the token-based backend the Codex CLI uses. Both are unofficial and
///   may change; failures are surfaced as text and never crash anything.
/// - It consumes a negligible amount of quota by design — that's what starts the window.
enum SessionKickstarter {
    private static let queue = DispatchQueue(label: "fr.fraserv.llmusagebar.session-kick")
    private static var lastKick: [String: Date] = [:]

    /// Never fire more than once per this interval per account (in-memory guard).
    private static let minInterval: TimeInterval = 30 * 60

    /// Claude models to try, cheapest first. `nil` = the account default. Retired
    /// slugs return `model_not_available`, so we fall through until one is accepted.
    private static let claudeModels: [String?] = [
        "claude-haiku-4-5-20251001",
        "claude-haiku-4-5",
        nil,
    ]

    /// Codex models to try, cheapest first.
    private static let codexModels = ["gpt-5-codex", "gpt-5"]

    // MARK: Auto (timer-driven)

    static func runIfNeeded(profiles: [LaunchProfile], allowKeychain: Bool) {
        let candidates = profiles.filter { $0.autoStartsSession }
        guard !candidates.isEmpty else { return }

        queue.async {
            for profile in candidates {
                guard shouldKick(profile) else { continue }
                lastKick[profile.id] = Date()
                _ = startSession(for: profile, allowKeychain: allowKeychain)
            }
        }
    }

    /// Whether the 5-hour clock is currently *not* running — i.e. the session is
    /// idle/reset/never-started, so there's something to start. Never acts on missing
    /// or stale data. Note this keys off whether the clock has started, not raw usage:
    /// a session that just started sits at ~0% but is running.
    static func isSessionIdle(_ profile: LaunchProfile) -> Bool {
        guard let usage = profile.usage, profile.usageStale != true else { return false }
        guard let window = usage.windows.first(where: { $0.title == "5h" }) else {
            return true // no 5h window → session hasn't started
        }
        switch profile.provider {
        case .claude:
            // Claude only reports a reset time once the window is running, so that's
            // the true "clock started" signal (usage may still be ~0% just after start).
            if let reset = window.resetsAt { return reset <= Date() }
            return window.usedPercent <= 0.5
        case .codex:
            // Codex's rate window always carries a reset time, so fall back to usage.
            if let reset = window.resetsAt, reset <= Date() { return true }
            return window.usedPercent <= 0.5
        }
    }

    private static func shouldKick(_ profile: LaunchProfile) -> Bool {
        if let last = lastKick[profile.id], Date().timeIntervalSince(last) < minInterval {
            return false
        }
        return isSessionIdle(profile)
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
                return "Couldn't start session — creating the chat failed (HTTP \(createResponse.statusCode))."
            }

            // 2. Send one minimal message — this is what starts the 5-hour window. A
            //    rejected model returns 403 before generating (nothing is sent), so we
            //    can safely try candidates until one is accepted.
            let completionURL = URL(string: "https://claude.ai/api/organizations/\(orgID)/chat_conversations/\(conversationUUID)/completion")!
            var completionHeaders = headers
            completionHeaders["Accept"] = "text/event-stream"

            var lastStatus = 0
            var lastError = ""
            for model in claudeModels {
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
                    return "Started a 5h session — sent “hi” on \(model ?? "the default model")."
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
            var lastStatus = 0
            var lastError = ""
            for model in codexModels {
                var response = try sendCodexMessage(model: model, credentials: credentials)
                if response.statusCode == 401 {
                    credentials = try CodexAuthStore.refreshCredentials(credentials)
                    response = try sendCodexMessage(model: model, credentials: credentials)
                }
                if (200...299).contains(response.statusCode) {
                    return "Started a Codex 5h session — sent “hi” on \(model)."
                }
                lastStatus = response.statusCode
                lastError = conciseError(response.data)
                // Keep trying other models only on a model-availability error.
                if !lastError.lowercased().contains("model") { break }
            }
            return "Couldn't start Codex session (HTTP \(lastStatus)). \(lastError)"
        } catch {
            return "Failed to start Codex session: \(error.localizedDescription)"
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

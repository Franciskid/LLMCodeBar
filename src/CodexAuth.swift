import Foundation

struct CodexAccountInfo {
    var email: String?
    var plan: String?
    var accountID: String?
}

struct CodexCredentials {
    var accessToken: String
    var refreshToken: String?
    var idToken: String?
    var accountID: String?
    var authURL: URL
}

enum CodexAuthStore {
    private static let refreshEndpoint = URL(string: "https://auth.openai.com/oauth/token")!
    private static let oauthClientID = "app_EMoamEEZ73f0CkXaXp7hrann"

    static func accountInfo(dataDir: String? = nil) -> CodexAccountInfo? {
        guard let credentials = try? loadCredentials(dataDir: dataDir) else { return nil }
        let payload = credentials.idToken.flatMap(parseJWT)
        let auth = payload?["https://api.openai.com/auth"] as? [String: Any]
        let profile = payload?["https://api.openai.com/profile"] as? [String: Any]
        let email = normalized((payload?["email"] as? String) ?? (profile?["email"] as? String))
        let plan = displayPlan(normalized((auth?["chatgpt_plan_type"] as? String) ?? (payload?["chatgpt_plan_type"] as? String)))
        let accountID = normalized(credentials.accountID ?? (auth?["chatgpt_account_id"] as? String))
        return CodexAccountInfo(email: email, plan: plan, accountID: accountID)
    }

    static func loadCredentials(dataDir: String? = nil) throws -> CodexCredentials {
        let authURL = authFileCandidates(dataDir: dataDir).first { FileManager.default.fileExists(atPath: $0.path) }
        guard let authURL else {
            throw NSError(domain: "LLMUsageBar.CodexAuth", code: 1, userInfo: [NSLocalizedDescriptionKey: "Codex auth.json not found"])
        }
        let data = try Data(contentsOf: authURL)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(domain: "LLMUsageBar.CodexAuth", code: 2, userInfo: [NSLocalizedDescriptionKey: "Codex auth.json is invalid"])
        }
        if let apiKey = normalized(json["OPENAI_API_KEY"] as? String) {
            return CodexCredentials(accessToken: apiKey, refreshToken: nil, idToken: nil, accountID: nil, authURL: authURL)
        }
        guard let tokens = json["tokens"] as? [String: Any],
              let access = normalized((tokens["access_token"] as? String) ?? (tokens["accessToken"] as? String)) else {
            throw NSError(domain: "LLMUsageBar.CodexAuth", code: 3, userInfo: [NSLocalizedDescriptionKey: "Codex auth.json has no access token"])
        }
        let idToken = normalized((tokens["id_token"] as? String) ?? (tokens["idToken"] as? String))
        let payload = idToken.flatMap(parseJWT)
        let auth = payload?["https://api.openai.com/auth"] as? [String: Any]
        let accountID = normalized((tokens["account_id"] as? String) ?? (tokens["accountId"] as? String)) ??
            normalized(auth?["chatgpt_account_id"] as? String)
        return CodexCredentials(
            accessToken: access,
            refreshToken: normalized((tokens["refresh_token"] as? String) ?? (tokens["refreshToken"] as? String)),
            idToken: idToken,
            accountID: accountID,
            authURL: authURL)
    }

    static func refreshCredentials(_ credentials: CodexCredentials) throws -> CodexCredentials {
        guard let refreshToken = credentials.refreshToken, !refreshToken.isEmpty else {
            return credentials
        }

        let response = try SimpleHTTP.postJSON(
            refreshEndpoint,
            body: [
                "client_id": oauthClientID,
                "grant_type": "refresh_token",
                "refresh_token": refreshToken,
                "scope": "openid profile email",
            ],
            headers: [:])
        guard response.statusCode == 200,
              let json = try JSONSerialization.jsonObject(with: response.data) as? [String: Any] else {
            throw NSError(domain: "LLMUsageBar.CodexAuth", code: response.statusCode, userInfo: [NSLocalizedDescriptionKey: "Codex token refresh HTTP \(response.statusCode)"])
        }

        let refreshed = CodexCredentials(
            accessToken: normalized(json["access_token"] as? String) ?? credentials.accessToken,
            refreshToken: normalized(json["refresh_token"] as? String) ?? credentials.refreshToken,
            idToken: normalized(json["id_token"] as? String) ?? credentials.idToken,
            accountID: credentials.accountID,
            authURL: credentials.authURL)
        try? saveCredentials(refreshed)
        return refreshed
    }

    private static func saveCredentials(_ credentials: CodexCredentials) throws {
        var json: [String: Any] = [:]
        if let data = try? Data(contentsOf: credentials.authURL),
           let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            json = existing
        }

        var tokens: [String: Any] = [
            "access_token": credentials.accessToken
        ]
        if let refreshToken = credentials.refreshToken {
            tokens["refresh_token"] = refreshToken
        }
        if let idToken = credentials.idToken {
            tokens["id_token"] = idToken
        }
        if let accountID = credentials.accountID {
            tokens["account_id"] = accountID
        }
        json["tokens"] = tokens
        json["last_refresh"] = ISO8601DateFormatter().string(from: Date())

        let data = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
        try FileManager.default.createDirectory(at: credentials.authURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: credentials.authURL, options: [.atomic])
    }

    static func parseJWT(_ token: String) -> [String: Any]? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var payload = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while payload.count % 4 != 0 {
            payload.append("=")
        }
        guard let data = Data(base64Encoded: payload),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return json
    }

    static func displayPlan(_ raw: String?) -> String? {
        guard let raw else { return nil }
        switch raw.lowercased() {
        case "plus": return "Plus"
        case "pro": return "Pro"
        case "team": return "Team"
        case "enterprise": return "Enterprise"
        case "free": return "Free"
        case "go": return "Go"
        default: return raw
        }
    }

    /// The model the user's Codex CLI is configured to use (from `config.toml`). ChatGPT
    /// accounts only accept the model provisioned for them, so the session-start flow
    /// tries this before any hardcoded fallback.
    static func configuredModel(dataDir: String? = nil) -> String? {
        for url in configFileCandidates(dataDir: dataDir) where FileManager.default.fileExists(atPath: url.path) {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            // TOML: `model = "gpt-5.6-luna"`, ignoring commented lines.
            if let model = firstCapture(pattern: #"(?m)^\s*model\s*=\s*"([^"]+)""#, in: text) {
                return model
            }
        }
        return nil
    }

    private static func configFileCandidates(dataDir: String?) -> [URL] {
        var urls: [URL] = []
        if let dataDir {
            let root = URL(fileURLWithPath: Launcher.expanding(dataDir), isDirectory: true)
            urls.append(root.appendingPathComponent("CodexHome/config.toml"))
            urls.append(root.appendingPathComponent("config.toml"))
        }
        if let codexHome = ProcessInfo.processInfo.environment["CODEX_HOME"], !codexHome.isEmpty {
            urls.append(URL(fileURLWithPath: codexHome, isDirectory: true).appendingPathComponent("config.toml"))
        }
        urls.append(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/config.toml"))
        return urls
    }

    private static func firstCapture(pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range), match.numberOfRanges > 1,
              let captureRange = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[captureRange])
    }

    private static func authFileCandidates(dataDir: String?) -> [URL] {
        var urls: [URL] = []
        if let dataDir {
            let root = URL(fileURLWithPath: Launcher.expanding(dataDir), isDirectory: true)
            urls.append(root.appendingPathComponent("CodexHome/auth.json"))
            urls.append(root.appendingPathComponent("auth.json"))
        }
        if let codexHome = ProcessInfo.processInfo.environment["CODEX_HOME"], !codexHome.isEmpty {
            urls.append(URL(fileURLWithPath: codexHome, isDirectory: true).appendingPathComponent("auth.json"))
        }
        urls.append(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/auth.json"))
        return urls
    }

    private static func normalized(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
}


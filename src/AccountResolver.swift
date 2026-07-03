import Foundation

enum AccountResolver {
    private static let maxReadableBytes = 1_500_000
    private static let maxFilesPerStore = 8
    private static let maxBlobFilesPerStore = 16

    static func signature(in dataDir: String) -> String {
        let root = URL(fileURLWithPath: Launcher.expanding(dataDir))
        return relevantFiles(under: root).map { file in
            let values = try? file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            let modified = values?.contentModificationDate?.timeIntervalSince1970 ?? 0
            return "\(file.path):\(values?.fileSize ?? 0):\(modified)"
        }.joined(separator: "|")
    }

    static func identity(in dataDir: String, provider: Provider) -> AccountIdentity? {
        if provider == .codex, let account = CodexAuthStore.accountInfo(dataDir: dataDir) {
            return AccountIdentity(
                displayName: nil,
                email: account.email,
                isSignedIn: true,
                planName: account.plan,
                quotaSummary: nil,
                quotaSource: nil,
                billingType: nil,
                accountUUID: account.accountID
            )
        }

        let root = URL(fileURLWithPath: Launcher.expanding(dataDir))
        let files = relevantFiles(under: root)
        var emails: [String] = []
        var names: [String] = []
        var billingTypes: [String] = []
        var accountUUIDs: [String] = []
        var planSignals: [String] = []
        var signedIn = false

        for file in files {
            guard let text = readableText(from: file) else { continue }
            if text.contains("@") {
                emails.append(contentsOf: extractEmails(from: text))
            }
            if containsAny(["displayName", "display_name", "fullName", "full_name", "name", "email_address", "userEmail", "user_email"], in: text) {
                names.append(contentsOf: extractNamedValues(from: text))
            }
            if text.contains("\"billing_type\"") {
                billingTypes.append(contentsOf: captureMatches(pattern: #""billing_type"\s*:\s*"([^"]+)""#, in: text))
                if text.range(of: #""billing_type"\s*:\s*null"#, options: [.regularExpression, .caseInsensitive]) != nil {
                    billingTypes.append("none")
                }
            }
            if text.contains("\"account_uuid\"") {
                accountUUIDs.append(contentsOf: captureMatches(pattern: #""account_uuid"\s*:\s*"([^"]+)""#, in: text))
            }
            if containsAny(["membership", "plan", "subscription", "billing_plan", "account_plan"], in: text) {
                planSignals.append(contentsOf: planSignalsFrom(text: text))
            }
            if text.contains("\"account_id\"") ||
                text.contains("\"last_signed_in_username\"") ||
                text.contains("\"email_address\"") ||
                text.contains("\"account_uuid\"") ||
                text.contains("sessionKey") ||
                text.contains("lastSignedIn") {
                signedIn = true
            }
        }

        let email = preferredEmail(from: emails, provider: provider)
        let name = preferredName(from: names, excluding: email, provider: provider)
        let displayName = (email == nil || (name?.contains(" ") == true)) ? name : nil
        // Local leveldb logs often keep a stale "billing_type": null (from before an
        // upgrade) alongside the current paid entry, and which one a scan happens to
        // read flips between runs. Always prefer a paid signal over "none".
        let billingType = billingTypes.first { $0 != "none" } ?? billingTypes.first
        let accountUUID = accountUUIDs.first
        let planName = planName(provider: provider, billingType: billingType, planSignals: planSignals)

        if email != nil || displayName != nil {
            return AccountIdentity(
                displayName: displayName,
                email: email,
                isSignedIn: true,
                planName: planName,
                quotaSummary: nil,
                quotaSource: nil,
                billingType: billingType,
                accountUUID: accountUUID
            )
        }

        if provider == .codex && signedIn {
            return AccountIdentity(
                displayName: nil,
                email: nil,
                isSignedIn: true,
                planName: planName,
                quotaSummary: nil,
                quotaSource: nil,
                billingType: billingType,
                accountUUID: accountUUID
            )
        }

        return nil
    }

    private static func relevantFiles(under root: URL) -> [URL] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: root.path) else { return [] }

        var files: [URL] = []
        let directNames = [
            "Preferences",
            "Secure Preferences",
            "Local State",
            "config.json",
            "bridge-state.json",
            "buddy-tokens.json",
            "Default/Preferences",
            "Default/Secure Preferences",
            "Default/Partitions/codex-browser-app/Preferences",
            "Default/Partitions/codex-browser-app/Secure Preferences"
        ]

        for name in directNames {
            let file = root.appendingPathComponent(name)
            if fm.fileExists(atPath: file.path), isReadableCandidate(file) {
                files.append(file)
            }
        }

        let storageDirs: [(path: String, recursive: Bool, allowExtensionless: Bool, limit: Int)] = [
            ("Local Storage/leveldb", false, false, maxFilesPerStore),
            ("Session Storage", false, false, maxFilesPerStore),
            ("IndexedDB/https_claude.ai_0.indexeddb.leveldb", false, false, maxFilesPerStore),
            ("IndexedDB/https_claude.ai_0.indexeddb.blob", true, true, maxBlobFilesPerStore),
            ("Default/Local Storage/leveldb", false, false, maxFilesPerStore),
            ("Default/Session Storage", false, false, maxFilesPerStore),
            ("Default/IndexedDB/https_claude.ai_0.indexeddb.leveldb", false, false, maxFilesPerStore),
            ("Default/IndexedDB/https_claude.ai_0.indexeddb.blob", true, true, maxBlobFilesPerStore),
            ("Default/IndexedDB/https_chatgpt.com_0.indexeddb.leveldb", false, false, maxFilesPerStore),
            ("Default/Partitions/codex-browser-app/Local Storage/leveldb", false, false, maxFilesPerStore),
            ("Default/Partitions/codex-browser-app/Session Storage", false, false, maxFilesPerStore),
            ("Default/Partitions/codex-browser-app/IndexedDB/https_chatgpt.com_0.indexeddb.leveldb", false, false, maxFilesPerStore)
        ]

        for storageDir in storageDirs {
            let dir = root.appendingPathComponent(storageDir.path)
            files.append(contentsOf: relevantStoreFiles(
                in: dir,
                recursive: storageDir.recursive,
                allowExtensionless: storageDir.allowExtensionless,
                limit: storageDir.limit
            ))
        }

        return Array(Set(files)).sorted {
            modificationDate($0) > modificationDate($1)
        }
    }

    private static func relevantStoreFiles(in dir: URL, recursive: Bool, allowExtensionless: Bool, limit: Int) -> [URL] {
        let fm = FileManager.default
        var files: [URL] = []
        if recursive {
            guard let enumerator = fm.enumerator(
                at: dir,
                includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles]
            ) else {
                return []
            }
            for case let file as URL in enumerator where isRelevantFile(file, allowExtensionless: allowExtensionless) && isReadableCandidate(file) {
                files.append(file)
            }
        } else if let entries = try? fm.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) {
            files = entries.filter { isRelevantFile($0, allowExtensionless: allowExtensionless) && isReadableCandidate($0) }
        }

        return Array(files.sorted {
            modificationDate($0) > modificationDate($1)
        }.prefix(limit))
    }

    private static func modificationDate(_ file: URL) -> Date {
        (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }

    private static func isRelevantFile(_ file: URL, allowExtensionless: Bool = false) -> Bool {
        let name = file.lastPathComponent
        let allowedNames = [
            "Preferences",
            "Secure Preferences",
            "Local State"
        ]
        if allowedNames.contains(name) { return true }
        if name.hasSuffix(".ldb") || name.hasSuffix(".log") { return true }
        return allowExtensionless && !name.contains(".")
    }

    private static func isReadableCandidate(_ file: URL) -> Bool {
        guard let values = try? file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
              values.isRegularFile == true,
              (values.fileSize ?? 0) <= maxReadableBytes else {
            return false
        }
        return true
    }

    private static func readableText(from file: URL) -> String? {
        guard isReadableCandidate(file),
              let data = try? Data(contentsOf: file) else {
            return nil
        }

        return normalizeStorageText(String(decoding: data, as: UTF8.self))
    }

    private static func normalizeStorageText(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\u{0}", with: "")
            .replacingOccurrences(of: "\\u0022", with: "\"")
            .replacingOccurrences(of: "\\\"", with: "\"")
    }

    private static func extractEmails(from text: String) -> [String] {
        matches(
            pattern: #"[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}"#,
            in: text,
            options: [.caseInsensitive]
        )
        .map { $0.lowercased() }
    }

    private static func extractNamedValues(from text: String) -> [String] {
        let patterns = [
            #""(?:displayName|display_name|fullName|full_name|full_name|name|email|email_address|userEmail|user_email)"\s*:\s*"([^"]{3,120})""#,
            #"(?:displayName|display_name|fullName|full_name|name|email|email_address|userEmail|user_email)\\?":\\?"([^"\\]{3,120})\\?""#
        ]
        return patterns.flatMap { pattern in
            captureMatches(pattern: pattern, in: text)
        }
    }

    private static func preferredEmail(from emails: [String], provider: Provider) -> String? {
        let blockedDomains = [
            "example.com",
            "example.org",
            "getsentry.com",
            "sentry.io",
            "openssl.org",
            "sourceware.org",
            "google.com",
            "gstatic.com",
            "googleapis.com",
            "cloudflare.com",
            "stripe.com",
            "intercom.io",
            "sentry.wixpress.com"
        ]
        // Service/no-reply mailboxes get cached in the local store alongside the real
        // account address; reject them so a stray one never becomes the sticky email.
        let blockedLocalParts: Set<String> = [
            "noreply", "no-reply", "no_reply", "donotreply", "do-not-reply",
            "support", "help", "hello", "contact", "info", "notifications",
            "notification", "team", "security", "privacy", "legal", "billing",
            "sales", "admin", "feedback", "abuse", "postmaster", "mailer-daemon"
        ]
        let filtered = emails.filter { email in
            let parts = email.split(separator: "@")
            guard parts.count == 2,
                  parts[0].count >= 2,
                  let domain = parts.last else { return false }
            let localPart = String(parts[0]).lowercased()
            if blockedLocalParts.contains(localPart) { return false }
            let domainText = String(domain)
            let domainParts = domainText.split(separator: ".")
            guard domainParts.count >= 2,
                  let tld = domainParts.last,
                  tld.count >= 2,
                  !["oa", "png", "jpg", "jpeg", "gif", "webp", "svg", "local"].contains(String(tld)) else {
                return false
            }
            if blockedDomains.contains(domainText) { return false }
            if email.contains("opengraph-image") { return false }
            return true
        }

        if provider == .claude {
            return filtered.first
        }
        let likelyAccountEmail = filtered.first { email in
            email.contains("openai") || email.contains("gmail") || email.contains("icloud") || email.contains("francois") || email.contains("francis")
        }
        return provider == .codex ? likelyAccountEmail : (likelyAccountEmail ?? filtered.first)
    }

    private static func preferredName(from names: [String], excluding email: String?, provider: Provider) -> String? {
        let blocked = Set([
            "Claude",
            "Codex",
            "Votre Codex",
            "Personne 1",
            "Personne 1",
            "Web Store",
            "Chromium PDF Viewer",
            "Anthropic",
            "Stable",
            "Auto",
            "All users",
            "Auto full",
            "Auto Stage3",
            "Auto Main Cohort",
            "M108 and Above"
        ])

        for rawName in names {
            let name = rawName
                .replacingOccurrences(of: #"\"#, with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty,
                  !blocked.contains(name),
                  name != email,
                  !name.contains("@"),
                  looksLikeHumanName(name),
                  name.count >= 3,
                  name.count <= 80 else {
                continue
            }
            return name
        }
        return nil
    }

    private static func planName(provider: Provider, billingType: String?, planSignals: [String]) -> String? {
        // Claude's local cache leaves stray plan tokens behind (upgrade/compare UI
        // mentions "max"/"pro" even for other tiers), so they can't be trusted. Use
        // only the billing type: paid → Pro, none → Free. We can't tell Pro from Max
        // locally, and per preference we default paid accounts to Pro.
        if provider == .claude {
            switch billingType {
            case "none": return "Free"
            case "stripe_subscription": return "Pro"
            default: return nil
            }
        }

        if let explicitPlan = planSignals.first(where: { ["max", "pro", "team", "plus", "free"].contains($0.lowercased()) }) {
            return displayPlan(explicitPlan)
        }
        return nil
    }

    private static func planSignalsFrom(text: String) -> [String] {
        var signals: [String] = []
        let patterns = [
            #""(?:plan|subscription_tier|tier|billing_plan|account_plan|membership)"\s*:\s*"(max|pro|team|plus|free)""#,
            #""(?:plan|subscription|membership)"[^"}]{0,140}"(max|pro|team|plus|free)""#,
            #"billing_type[^\n\r]{0,260}_?(max|pro|team|plus|free)"#,
            #"stripe_subscrip[^\n\r]{0,180}_?(max|pro|team|plus|free)"#,
            #""billing_type"\s*:\s*"([^"]+)""#
        ]

        for pattern in patterns {
            signals.append(contentsOf: captureMatches(pattern: pattern, in: text).map { $0.lowercased() })
        }

        return Array(Set(signals))
    }

    private static func displayPlan(_ raw: String) -> String {
        switch raw.lowercased() {
        case "max": return "Max"
        case "pro": return "Pro"
        case "team": return "Team"
        case "plus": return "Plus"
        case "free": return "Free"
        default: return raw
        }
    }

    private static func looksLikeHumanName(_ value: String) -> Bool {
        let letterCount = value.unicodeScalars.filter { CharacterSet.letters.contains($0) }.count
        guard letterCount >= 2 else { return false }
        if value.contains(".") || value.contains("_") || value.contains(",") || value.contains("\t") {
            return false
        }
        if value.rangeOfCharacter(from: .decimalDigits) != nil {
            return false
        }
        return value.range(
            of: #"^[\p{L}][\p{L} '\-]{1,78}$"#,
            options: [.regularExpression]
        ) != nil
    }

    private static func matches(pattern: String, in text: String, options: NSRegularExpression.Options = []) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, range: range).compactMap { result in
            guard let matchRange = Range(result.range, in: text) else { return nil }
            return String(text[matchRange])
        }
    }

    private static func captureMatches(pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, range: range).compactMap { result in
            guard result.numberOfRanges > 1,
                  let matchRange = Range(result.range(at: 1), in: text) else {
                return nil
            }
            return String(text[matchRange])
        }
    }

    private static func containsAny(_ needles: [String], in text: String) -> Bool {
        needles.contains { text.range(of: $0, options: [.caseInsensitive]) != nil }
    }
}


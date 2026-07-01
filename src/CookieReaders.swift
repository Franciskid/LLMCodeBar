import CommonCrypto
import Foundation
import Security

enum ElectronCookieReader {
    struct Cookie {
        var host: String
        var name: String
        var value: String
    }

    static func cookieHeader(from dataDir: String, domains: [String], keychainServices: [String]) throws -> String {
        let cookieURL = URL(fileURLWithPath: Launcher.expanding(dataDir)).appendingPathComponent("Cookies")
        guard FileManager.default.fileExists(atPath: cookieURL.path) else {
            throw NSError(domain: "LLMUsageBar.Cookies", code: 1, userInfo: [NSLocalizedDescriptionKey: "Cookie database not found"])
        }

        let domainPredicate = domains.map { "host_key like '%\($0.replacingOccurrences(of: "'", with: "''"))'" }.joined(separator: " or ")
        let sql = "select host_key,name,value,hex(encrypted_value) from cookies where \(domainPredicate) order by host_key,name;"
        let output = try ProcessRunner.run(
            "/usr/bin/sqlite3",
            arguments: ["-separator", "\t", cookieURL.path, sql],
            timeout: 5)

        func parse(with passphrase: String?) -> [Cookie] {
            output
                .split(whereSeparator: \.isNewline)
                .compactMap { line -> Cookie? in
                    let parts = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
                    guard parts.count >= 4 else { return nil }
                    let host = parts[0]
                    let name = parts[1]
                    let plain = parts[2]
                    let encryptedHex = parts[3]
                    let value: String?
                    if !plain.isEmpty {
                        value = plain
                    } else if let passphrase, let encrypted = Data(hexString: encryptedHex) {
                        value = decryptChromiumCookie(encrypted, passphrase: passphrase)
                    } else {
                        value = nil
                    }
                    guard let value, !value.isEmpty else { return nil }
                    return Cookie(host: host, name: name, value: value)
                }
        }

        // 1. Try keys we've already cached in *our own* keychain item. Reading an
        //    item this app created doesn't prompt, so warm launches stay silent.
        for service in keychainServices {
            guard let cached = SafeStorageKeyCache.cachedKey(for: service) else { continue }
            let cookies = parse(with: cached)
            if !cookies.isEmpty {
                return joined(cookies)
            }
            // Cached key no longer decrypts (rotated) — drop it and fall through.
            SafeStorageKeyCache.invalidate(for: service)
        }

        // 2. Fall back to the app's real Safe Storage key (may prompt once). Stop at
        //    the first match — probing every service would prompt for each browser.
        for service in keychainServices {
            guard let key = keychainPassword(service: service) else { continue }
            let cookies = parse(with: key)
            if !cookies.isEmpty {
                SafeStorageKeyCache.store(key: key, for: service)
                return joined(cookies)
            }
        }

        // 3. Plaintext cookies (no key needed).
        let plaintext = parse(with: nil)
        guard !plaintext.isEmpty else {
            throw NSError(domain: "LLMUsageBar.Cookies", code: 2, userInfo: [NSLocalizedDescriptionKey: "No readable cookies found"])
        }
        return joined(plaintext)
    }

    private static func joined(_ cookies: [Cookie]) -> String {
        cookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
    }

    private static func keychainPassword(service: String) -> String? {
        for account in keychainAccountCandidates(for: service) {
            if let password = modernKeychainPassword(service: service, account: account) {
                return password
            }
            if let password = legacyKeychainPassword(service: service, account: account) {
                return password
            }
        }
        return nil
    }

    private static func keychainAccountCandidates(for service: String) -> [String?] {
        let guessed = service
            .replacingOccurrences(of: " Safe Storage", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var candidates: [String?] = guessed.isEmpty ? [] : [guessed]
        candidates.append(nil)
        return candidates
    }

    private static func modernKeychainPassword(service: String, account: String?) -> String? {
        for useDataProtectionKeychain in [false, true] {
            var query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecReturnData as String: kCFBooleanTrue as Any,
                kSecMatchLimit as String: kSecMatchLimitOne,
            ]
            if useDataProtectionKeychain {
                query[kSecUseDataProtectionKeychain as String] = kCFBooleanTrue as Any
            }
            if let account {
                query[kSecAttrAccount as String] = account
            }

            var item: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &item)
            if status == errSecSuccess,
               let data = item as? Data,
               let password = String(data: data, encoding: .utf8),
               !password.isEmpty {
                return password
            }
        }
        return nil
    }

    private static func legacyKeychainPassword(service: String, account: String?) -> String? {
        var length: UInt32 = 0
        var passwordData: UnsafeMutableRawPointer?

        let status: OSStatus = service.withCString { servicePointer in
            if let account {
                return account.withCString { accountPointer in
                    SecKeychainFindGenericPassword(
                        nil,
                        UInt32(strlen(servicePointer)),
                        servicePointer,
                        UInt32(strlen(accountPointer)),
                        accountPointer,
                        &length,
                        &passwordData,
                        nil)
                }
            }

            return SecKeychainFindGenericPassword(
                nil,
                UInt32(strlen(servicePointer)),
                servicePointer,
                0,
                nil,
                &length,
                &passwordData,
                nil)
        }
        guard status == errSecSuccess, let passwordData else { return nil }
        defer { SecKeychainItemFreeContent(nil, passwordData) }
        return String(data: Data(bytes: passwordData, count: Int(length)), encoding: .utf8)
    }

    private static func decryptChromiumCookie(_ encrypted: Data, passphrase: String) -> String? {
        guard encrypted.count > 3 else { return nil }
        let prefix = String(data: encrypted.prefix(3), encoding: .utf8)
        let cipher = (prefix == "v10" || prefix == "v11") ? Data(encrypted.dropFirst(3)) : encrypted
        let salt = Array("saltysalt".utf8)
        let iv = Array(repeating: UInt8(ascii: " "), count: kCCBlockSizeAES128)
        var key = Array(repeating: UInt8(0), count: kCCKeySizeAES128)
        let derivationStatus = passphrase.withCString { password in
            CCKeyDerivationPBKDF(
                CCPBKDFAlgorithm(kCCPBKDF2),
                password,
                strlen(password),
                salt,
                salt.count,
                CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1),
                1003,
                &key,
                key.count)
        }
        guard derivationStatus == kCCSuccess else { return nil }

        var output = Array(repeating: UInt8(0), count: cipher.count + kCCBlockSizeAES128)
        let outputCapacity = output.count
        var outputLength = 0
        let cryptStatus = cipher.withUnsafeBytes { cipherBytes in
            key.withUnsafeBytes { keyBytes in
                iv.withUnsafeBytes { ivBytes in
                    output.withUnsafeMutableBytes { outputBytes in
                        CCCrypt(
                            CCOperation(kCCDecrypt),
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionPKCS7Padding),
                            keyBytes.baseAddress,
                            key.count,
                            ivBytes.baseAddress,
                            cipherBytes.baseAddress,
                            cipher.count,
                            outputBytes.baseAddress,
                            outputCapacity,
                            &outputLength)
                    }
                }
            }
        }
        guard cryptStatus == kCCSuccess else { return nil }
        let decrypted = Data(output.prefix(outputLength))
        if let text = readableCookieValue(from: decrypted) {
            return text
        }
        if decrypted.count > 32 {
            return readableCookieValue(from: Data(decrypted.dropFirst(32)))
        }
        return nil
    }

    private static func readableCookieValue(from data: Data) -> String? {
        guard let value = String(data: data, encoding: .utf8), !value.isEmpty else {
            return nil
        }
        let hasControlCharacters = value.unicodeScalars.contains { scalar in
            scalar.value < 0x20 || scalar.value == 0x7f
        }
        return hasControlCharacters ? nil : value
    }
}

/// Caches a browser's cookie-encryption ("Safe Storage") key inside this app's
/// own keychain item. macOS doesn't prompt when an app reads an item it created,
/// so after the first approval the key is fetched silently on later launches.
enum SafeStorageKeyCache {
    private static let cacheService = "LLM Usage Bar Cookie Key Cache"

    static func cachedKey(for sourceService: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: cacheService,
            kSecAttrAccount as String: sourceService,
            kSecReturnData as String: kCFBooleanTrue as Any,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let key = String(data: data, encoding: .utf8),
              !key.isEmpty else {
            return nil
        }
        return key
    }

    static func store(key: String, for sourceService: String) {
        guard let data = key.data(using: .utf8) else { return }
        let identity: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: cacheService,
            kSecAttrAccount as String: sourceService,
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

    static func invalidate(for sourceService: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: cacheService,
            kSecAttrAccount as String: sourceService,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

enum ClaudeCDPCookieReader {
    static func cookieHeader(from dataDir: String) -> String? {
        let portFile = URL(fileURLWithPath: Launcher.expanding(dataDir), isDirectory: true)
            .appendingPathComponent("DevToolsActivePort")
        guard let contents = try? String(contentsOf: portFile, encoding: .utf8),
              let portLine = contents.split(whereSeparator: \.isNewline).first,
              let port = Int(portLine) else {
            return nil
        }

        guard let targetsURL = URL(string: "http://127.0.0.1:\(port)/json"),
              let response = try? SimpleHTTP.get(targetsURL, headers: [:], timeout: 1),
              response.statusCode == 200,
              let targets = try? JSONSerialization.jsonObject(with: response.data) as? [[String: Any]] else {
            return nil
        }

        let webSocketURLString = targets.compactMap { target -> String? in
            guard let ws = target["webSocketDebuggerUrl"] as? String else { return nil }
            let url = (target["url"] as? String) ?? ""
            return url.contains("claude.ai") ? ws : nil
        }.first ?? targets.compactMap { $0["webSocketDebuggerUrl"] as? String }.first

        guard let webSocketURLString,
              let webSocketURL = URL(string: webSocketURLString),
              let cookies = fetchCookies(webSocketURL: webSocketURL) else {
            return nil
        }

        let claudeCookies = cookies.compactMap { cookie -> String? in
            guard let domain = cookie["domain"] as? String,
                  domain.contains("claude.ai"),
                  let name = cookie["name"] as? String,
                  let value = cookie["value"] as? String,
                  !value.isEmpty else {
                return nil
            }
            return "\(name)=\(value)"
        }

        return claudeCookies.isEmpty ? nil : claudeCookies.joined(separator: "; ")
    }

    private static func fetchCookies(webSocketURL: URL) -> [[String: Any]]? {
        let task = URLSession.shared.webSocketTask(with: webSocketURL)
        let semaphore = DispatchSemaphore(value: 0)
        var output: [[String: Any]]?

        task.resume()
        let message = #"{"id":1,"method":"Network.getAllCookies"}"#
        task.send(.string(message)) { error in
            if error != nil {
                semaphore.signal()
                return
            }

            task.receive { result in
                defer { semaphore.signal() }
                guard case let .success(message) = result else { return }

                let data: Data?
                switch message {
                case let .string(text):
                    data = text.data(using: .utf8)
                case let .data(raw):
                    data = raw
                @unknown default:
                    data = nil
                }

                guard let data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let result = json["result"] as? [String: Any],
                      let cookies = result["cookies"] as? [[String: Any]] else {
                    return
                }
                output = cookies
            }
        }

        _ = semaphore.wait(timeout: .now() + 2)
        task.cancel(with: .normalClosure, reason: nil)
        return output
    }
}

extension Data {
    init?(hexString: String) {
        let cleaned = hexString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleaned.count % 2 == 0 else { return nil }
        var bytes: [UInt8] = []
        var index = cleaned.startIndex
        while index < cleaned.endIndex {
            let next = cleaned.index(index, offsetBy: 2)
            guard let byte = UInt8(cleaned[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        self = Data(bytes)
    }
}


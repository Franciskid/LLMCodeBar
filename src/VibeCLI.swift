import Foundation

/// Reads the Mistral account and its monthly Vibe budget through the official Vibe CLI
/// (`vibe-app-server`, which ships with `mistral-vibe`). The CLI makes the requests with
/// its own login, against Mistral's public billing API, so LLMCodeBar calls nothing at
/// Mistral itself. Only a throwaway session is opened: it is never saved and no prompt
/// is sent, so reading usage costs nothing.
enum VibeCLI {
    struct Account {
        var email: String?
        var firstName: String?
        var lastName: String?
        var userID: String?
        var organizationID: String?
        var organizationName: String?
        var planTitle: String?
        var usagePercent: Double?
        var resetAt: String?
        var paygEnabled: Bool
    }

    static func executable() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            "/opt/homebrew/bin/vibe-app-server",
            "/usr/local/bin/vibe-app-server",
            "\(home)/.local/bin/vibe-app-server",
        ]
        return candidates
            .first { FileManager.default.isExecutableFile(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
    }

    static func readAccount() throws -> Account {
        guard let executable = executable() else {
            throw error("The Vibe CLI isn't installed. Run `brew install mistral-vibe`.")
        }
        let workdir = FileManager.default.temporaryDirectory.appendingPathComponent("LLMCodeBar-vibe", isDirectory: true)
        try? FileManager.default.createDirectory(at: workdir, withIntermediateDirectories: true)
        let server = try JSONRPCLineServer(executable: executable, cwd: workdir)
        defer { server.stop() }

        _ = try server.request("initialize", params: [
            "clientInfo": ["name": "llmcodebar", "title": "LLMCodeBar",
                           "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"],
        ], timeout: 30)
        server.notify("initialized", params: [:])
        let started = try server.request("session/start", params: [
            "kind": "ephemeral",
            "agentConfig": ["cwd": workdir.path],
        ], timeout: 60)
        guard let sessionID = ((started["state"] as? [String: Any])?["session"] as? [String: Any])?["id"] as? String else {
            throw error("The Vibe CLI didn't open a session.")
        }
        let accountJSON = try server.request("account/read", params: ["sessionId": sessionID], timeout: 30)
        let identityJSON = try? server.request("identity/read", params: ["sessionId": sessionID], timeout: 30)

        let account = accountJSON["account"] as? [String: Any] ?? [:]
        if let status = account["status"] as? String, status != "ready" {
            throw error("The Vibe CLI isn't signed in (\(status)). Run `vibe --setup`.")
        }
        let identity = identityJSON?["identity"] as? [String: Any]
        let plan = account["plan"] as? [String: Any]
        let budget = account["budget"] as? [String: Any]
        let organization = identity?["organization"] as? [String: Any]
        return Account(
            email: (identity?["email"] as? String)?.lowercased(),
            firstName: identity?["firstName"] as? String,
            lastName: identity?["lastName"] as? String,
            userID: identity?["id"] as? String,
            organizationID: organization?["id"] as? String,
            organizationName: organization?["name"] as? String,
            planTitle: (plan?["title"] as? String) ?? (plan?["name"] as? String),
            usagePercent: (budget?["usagePercentage"] as? NSNumber)?.doubleValue,
            resetAt: budget?["resetAt"] as? String,
            paygEnabled: budget?["paygEnabled"] as? Bool ?? false)
    }

    static func error(_ message: String) -> NSError {
        NSError(domain: "LLMUsageBar.VibeCLI", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

/// A short-lived JSON-RPC 2.0 server over stdio, one JSON message per line.
private final class JSONRPCLineServer {
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let lock = NSLock()
    private let arrived = DispatchSemaphore(value: 0)
    private var buffer = Data()
    private var replies: [Int: [String: Any]] = [:]
    private var nextID = 1

    init(executable: URL, cwd: URL) throws {
        process.executableURL = executable
        process.currentDirectoryURL = cwd
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            self?.receive(handle.availableData)
        }
        try process.run()
    }

    func stop() {
        output.fileHandleForReading.readabilityHandler = nil
        try? input.fileHandleForWriting.close()
        if process.isRunning { process.terminate() }
    }

    func request(_ method: String, params: [String: Any], timeout: TimeInterval) throws -> [String: Any] {
        let id = nextID
        nextID += 1
        try send(["jsonrpc": "2.0", "id": id, "method": method, "params": params])
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            lock.lock()
            if let reply = replies.removeValue(forKey: id) {
                lock.unlock()
                if let failure = reply["error"] as? [String: Any] {
                    throw VibeCLI.error("Vibe CLI \(method) failed: \(failure["message"] as? String ?? "unknown error")")
                }
                return (reply["result"] as? [String: Any]) ?? [:]
            }
            lock.unlock()
            guard process.isRunning else { throw VibeCLI.error("The Vibe CLI stopped before answering \(method).") }
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { throw VibeCLI.error("The Vibe CLI took too long to answer \(method).") }
            _ = arrived.wait(timeout: .now() + min(remaining, 1))
        }
    }

    func notify(_ method: String, params: [String: Any]) {
        try? send(["jsonrpc": "2.0", "method": method, "params": params])
    }

    private func send(_ message: [String: Any]) throws {
        var line = try JSONSerialization.data(withJSONObject: message)
        line.append(0x0A)
        try input.fileHandleForWriting.write(contentsOf: line)
    }

    private func receive(_ chunk: Data) {
        guard !chunk.isEmpty else { return }
        lock.lock()
        buffer.append(chunk)
        var parsed = 0
        var serverRequests: [Any] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)
            guard let message = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
            if message["method"] != nil {
                // The server asking the client something: LLMCodeBar has nothing to offer.
                if let id = message["id"] { serverRequests.append(id) }
                continue
            }
            if let id = (message["id"] as? NSNumber)?.intValue {
                replies[id] = message
                parsed += 1
            }
        }
        lock.unlock()
        for id in serverRequests {
            DispatchQueue.global(qos: .utility).async {
                try? self.send(["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "Not supported by LLMCodeBar"]])
            }
        }
        for _ in 0..<parsed { arrived.signal() }
    }
}

import Foundation

struct HTTPResponse {
    var statusCode: Int
    var data: Data
}

enum SimpleHTTP {
    static func get(_ url: URL, headers: [String: String], timeout: TimeInterval = 8) throws -> HTTPResponse {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = timeout
        headers.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
        return try perform(request)
    }

    static func postJSON(_ url: URL, body: [String: String], headers: [String: String], timeout: TimeInterval = 8) throws -> HTTPResponse {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        headers.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
        return try perform(request)
    }

    /// General request with an arbitrary JSON body (objects/arrays), for endpoints
    /// that need more than a flat string dictionary.
    static func send(_ url: URL, method: String, jsonBody: Any? = nil, headers: [String: String], timeout: TimeInterval = 12) throws -> HTTPResponse {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = timeout
        if let jsonBody {
            request.httpBody = try JSONSerialization.data(withJSONObject: jsonBody)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        headers.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
        return try perform(request)
    }

    private static func perform(_ request: URLRequest) throws -> HTTPResponse {
        let semaphore = DispatchSemaphore(value: 0)
        var output: Result<HTTPResponse, Error>!
        URLSession.shared.dataTask(with: request) { data, response, error in
            defer { semaphore.signal() }
            if let error {
                output = .failure(error)
                return
            }
            guard let http = response as? HTTPURLResponse else {
                output = .failure(NSError(domain: "LLMUsageBar.HTTP", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid HTTP response"]))
                return
            }
            output = .success(HTTPResponse(statusCode: http.statusCode, data: data ?? Data()))
        }.resume()
        semaphore.wait()
        return try output.get()
    }
}

enum ProcessRunner {
    static func run(_ executable: String, arguments: [String], environment: [String: String]? = nil, timeout: TimeInterval = 5) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let environment {
            process.environment = environment
        }

        let output = Pipe()
        let error = Pipe()
        process.standardOutput = output
        process.standardError = error
        try process.run()

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        if process.isRunning {
            process.terminate()
            throw NSError(domain: "LLMUsageBar.Process", code: -2, userInfo: [NSLocalizedDescriptionKey: "\(executable) timed out"])
        }

        let data = output.fileHandleForReading.readDataToEndOfFile()
        if process.terminationStatus != 0 {
            let stderr = String(data: error.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw NSError(domain: "LLMUsageBar.Process", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: stderr.isEmpty ? "\(executable) failed" : stderr])
        }
        return String(data: data, encoding: .utf8) ?? ""
    }
}


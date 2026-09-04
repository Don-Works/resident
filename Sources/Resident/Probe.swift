import Foundation

/// Blocking HTTP and subprocess helpers, used only from the sampling queue.
///
/// Every call carries a short timeout. A runtime that has wedged must slow Resident
/// down by at most that timeout, never hang the menu.
enum Probe {
    static func get(_ url: String, timeout: TimeInterval = 1.5) -> Data? {
        guard let url = URL(string: url) else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        request.cachePolicy = .reloadIgnoringLocalCacheData

        var result: Data?
        let done = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { data, response, _ in
            if let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) {
                result = data
            }
            done.signal()
        }.resume()

        _ = done.wait(timeout: .now() + timeout + 0.5)
        return result
    }

    @discardableResult
    static func post(_ url: String, json: [String: Any], timeout: TimeInterval = 3) -> Bool {
        guard let url = URL(string: url),
              let body = try? JSONSerialization.data(withJSONObject: json) else { return false }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var ok = false
        let done = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { _, response, _ in
            if let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) {
                ok = true
            }
            done.signal()
        }.resume()

        _ = done.wait(timeout: .now() + timeout + 0.5)
        return ok
    }

    static func json(_ url: String, timeout: TimeInterval = 1.5) -> Any? {
        guard let data = get(url, timeout: timeout) else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }

    /// Runs a command and returns stdout. Returns nil if it fails, is missing, or overruns.
    static func run(_ path: String, _ arguments: [String], timeout: TimeInterval = 15) -> String? {
        guard FileManager.default.isExecutableFile(atPath: path) else { return nil }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let out = Pipe()
        process.standardOutput = out
        process.standardError = Pipe()

        do { try process.run() } catch { return nil }

        let deadline = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: deadline)

        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        deadline.cancel()

        guard process.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// First existing path from a list of candidates.
    static func locate(_ candidates: [String]) -> String? {
        candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}

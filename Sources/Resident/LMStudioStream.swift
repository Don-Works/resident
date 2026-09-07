import Foundation

/// Live activity from `lms log stream`, the only channel LM Studio offers for throughput.
///
/// The stream announces each prediction as it starts and reports the runtime's own
/// statistics — tokens per second included — when it finishes. Nothing in the REST API
/// says either. It is one long-lived `lms` process rather than a spawn per sample: the
/// CLI takes seconds to connect, and a stream already open costs nothing per sample.
///
/// The process is Node and holds around 60 MB. That is the price of the number, and only
/// the menu bar app and `resident watch` pay it; one-shot commands read the cache those
/// leave behind. Prompt text passes through here and is discarded — only the model
/// identifier and the statistics are kept.
final class LMStudioStream {
    struct Reading: Codable {
        var tokensPerSecond: Double
        var at: Double
        var promptTokens: Int?
        var timeToFirstToken: Double?

        /// A prediction shorter than this says nothing about decode speed. Tokens over
        /// the window between the first token and the end is the rate, and a client
        /// killed a few tokens in leaves a window of milliseconds that turns eight
        /// tokens into "131 tok/s" — seen beside a real 13 on a 27B at 76K context.
        static let minimumTokens = 16.0
        static let minimumWindow: TimeInterval = 1.0
        /// Reasons that mean the prediction did not run its course.
        static let cutShort: Set<String> = ["userStopped", "modelUnloaded", "failed"]

        /// LM Studio's `tokensPerSecond` divides by the whole request, prompt processing
        /// included — an 85K-token context takes half a minute before the first token
        /// and drags a 19 tok/s decode down to 11. Generation time alone is the rate
        /// that says how fast the model runs; the prompt cost is kept alongside. A
        /// prediction cut short, or too short to measure, leaves the previous reading
        /// standing rather than replacing it with a number from a window too small to
        /// carry one.
        init?(stats: [String: Any], at: Double) {
            let predicted = (stats["predictedTokensCount"] as? Double) ?? 0
            let total = (stats["totalTimeSec"] as? Double) ?? 0
            let first = (stats["timeToFirstTokenSec"] as? Double) ?? 0
            let generating = total - first
            if let reason = stats["stopReason"] as? String, Self.cutShort.contains(reason) { return nil }
            guard predicted >= Self.minimumTokens, generating >= Self.minimumWindow else { return nil }
            let decode = (predicted - 1) / generating
            guard decode > 0 else { return nil }
            tokensPerSecond = decode
            self.at = at
            promptTokens = (stats["promptTokensCount"] as? Double).map(Int.init)
            timeToFirstToken = first > 0 ? first : nil
        }
    }

    struct State: Codable {
        /// Start times of predictions not yet finished, per model identifier.
        var started: [String: [Double]] = [:]
        var latest: [String: Reading] = [:]
        /// When the stream last saw a prediction end on each model. A slower source
        /// that says "generating" is only believed if it was asked after this.
        var finished: [String: Double] = [:]
        var ts: Double = 0

        func inFlight(_ id: String) -> Int { started[id]?.count ?? 0 }
    }

    /// Wall-clock cap on a prediction. Agent runs have been seen decoding for half an
    /// hour, so this is a backstop, not the normal way a stale start is cleared —
    /// `clearInFlight` is, on the word of `lms ps`.
    private static let longestPrediction: TimeInterval = 60 * 60
    /// A cached rate older than this is not worth showing.
    private static let cacheLifetime: TimeInterval = 10 * 60
    /// In-flight state from the cache is only trusted while the writer is clearly alive.
    private static let inFlightLifetime: TimeInterval = 120
    private static let relaunchDelay: TimeInterval = 15

    /// Whether this instance will run the stream itself, or only read the cache.
    private let live: Bool
    private var state = State()

    init(live: Bool) { self.live = live }
    private let lock = NSLock()
    private var process: Process?
    private var buffer = Data()
    private var lastLaunch: Date?
    private var stopped = false
    private var loadedFromDisk = false

    private static let directory: URL = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let directory = base.appendingPathComponent("co.revitt.resident", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }()
    private static let cachePath = directory.appendingPathComponent("lmstudio-stream.json").path
    private static let pidPath = directory.appendingPathComponent("lmstudio-stream.pid").path

    var isConnected: Bool {
        lock.lock()
        defer { lock.unlock() }
        return process?.isRunning == true
    }

    /// Starts the stream if it is not running. Called once per sample while LM Studio
    /// is present, so a runtime that comes and goes is followed without a timer.
    func ensureRunning() {
        lock.lock()
        defer { lock.unlock() }
        guard !stopped, process?.isRunning != true else { return }
        if let lastLaunch, Date().timeIntervalSince(lastLaunch) < Self.relaunchDelay { return }
        lastLaunch = Date()
        launch()
    }

    func stop() {
        lock.lock()
        stopped = true
        let running = process
        process = nil
        lock.unlock()
        running?.terminate()
        try? FileManager.default.removeItem(atPath: Self.pidPath)
    }

    /// Current knowledge, from the live stream or the cache a live process left behind.
    func snapshot() -> State {
        lock.lock()
        defer { lock.unlock() }
        if !loadedFromDisk { loadedFromDisk = true; loadCache() }
        let now = Date().timeIntervalSince1970
        var current = state
        for (id, starts) in current.started {
            let live = starts.filter { now - $0 <= Self.longestPrediction }
            current.started[id] = live.isEmpty ? nil : live
        }
        if process?.isRunning != true, now - current.ts > Self.inFlightLifetime {
            current.started = [:]
        }
        return current
    }

    // MARK: - Process

    private func launch() {
        guard let lms = Probe.locate([
            NSHomeDirectory() + "/.lmstudio/bin/lms",
            "/usr/local/bin/lms",
            "/opt/homebrew/bin/lms",
        ]) else { return }
        Self.reapOrphan()

        let process = Process()
        process.executableURL = URL(fileURLWithPath: lms)
        process.arguments = ["log", "stream", "--source", "model", "--stats", "--json"]
        process.standardError = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            self?.consume(handle.availableData)
        }
        process.terminationHandler = { [weak self] _ in
            pipe.fileHandleForReading.readabilityHandler = nil
            guard let self else { return }
            self.lock.lock()
            if self.process === process { self.process = nil }
            self.lock.unlock()
        }

        do { try process.run() } catch { return }
        self.process = process
        try? "\(process.processIdentifier)".write(toFile: Self.pidPath, atomically: true, encoding: .utf8)
    }

    /// A previous Resident that died without cleaning up leaves its `lms` behind, still
    /// holding a websocket and 60 MB. The pid file names it; kill it before starting
    /// another, after checking the pid still belongs to an `lms log stream`.
    private static func reapOrphan() {
        guard let text = try? String(contentsOfFile: pidPath, encoding: .utf8),
              let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)),
              pid > 1, pid != getpid() else { return }
        if let command = ProcessList.command(of: pid), command.contains("log stream") {
            kill(pid, SIGTERM)
        }
        try? FileManager.default.removeItem(atPath: pidPath)
    }

    // MARK: - Parsing

    private func consume(_ data: Data) {
        guard !data.isEmpty else { return }
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer.subdata(in: buffer.startIndex..<newline)
            buffer.removeSubrange(buffer.startIndex...newline)
            handle(line: line)
        }
    }

    private func handle(line: Data) {
        guard let root = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let event = root["data"] as? [String: Any],
              let type = event["type"] as? String,
              let id = event["modelIdentifier"] as? String else { return }
        let at = (root["timestamp"] as? Double).map { $0 / 1000 } ?? Date().timeIntervalSince1970

        lock.lock()
        defer { lock.unlock() }
        switch type {
        case "llm.prediction.input":
            state.started[id, default: []].append(at)
        case "llm.prediction.output":
            finish(id, at: at)
            if let stats = event["stats"] as? [String: Any],
               let reading = Reading(stats: stats, at: at) {
                state.latest[id] = reading
            }
        default:
            // Any other end-of-prediction event — cancelled, failed — still ends it.
            guard type.hasPrefix("llm.prediction.") else { return }
            finish(id, at: at)
        }
        state.ts = Date().timeIntervalSince1970
        saveCache()
    }

    private func finish(_ id: String, at: Double) {
        state.finished[id] = at
        guard var starts = state.started[id], !starts.isEmpty else { return }
        starts.removeFirst()
        state.started[id] = starts.isEmpty ? nil : starts
    }

    // MARK: - Cache

    /// Drops a model's in-flight starts. Called when another source — `lms ps`, polled
    /// after the start — says the model is idle, so the finish was never seen.
    func clearInFlight(_ id: String) {
        lock.lock()
        state.started[id] = nil
        lock.unlock()
    }

    private func loadCache() {
        guard let data = FileManager.default.contents(atPath: Self.cachePath),
              let cached = try? JSONDecoder().decode(State.self, from: data),
              Date().timeIntervalSince1970 - cached.ts <= Self.cacheLifetime else { return }
        state.latest = cached.latest
        state.ts = cached.ts
        // A live process learns what is in flight from its own stream. Only a one-shot
        // command, which has no stream, takes the writer's word for it.
        if !live { state.started = cached.started }
    }

    private func saveCache() {
        guard let data = try? JSONEncoder().encode(state) else { return }
        try? data.write(to: URL(fileURLWithPath: Self.cachePath), options: .atomic)
    }
}

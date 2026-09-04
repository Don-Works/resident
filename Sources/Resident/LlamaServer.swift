import Foundation

/// A bare `llama-server`, which has no model manager — one process, one model. It is
/// found by asking the usual ports whether they answer `/props`.
final class LlamaServer: ModelRuntime {
    let name = "llama.cpp"
    private let ports: [Int]

    /// The cumulative predicted-token counter from the last sample, per port, so a rate
    /// can be derived. Only the sampling queue touches this.
    private var previous: [Int: (tokens: Int, at: Date)] = [:]
    private var lastReading: [Int: (rate: Double, at: Date)] = [:]

    init(ports: [Int] = [8080, 8000, 8081]) { self.ports = ports }

    func isPresent() -> Bool { !liveEndpoints().isEmpty }

    func loadedModels() -> [LoadedModel] {
        liveEndpoints().compactMap { port, props in
            let path = (props["model_path"] as? String)
                ?? ((props["default_generation_settings"] as? [String: Any])?["model"] as? String)
            let identifier = path.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "model"
            let busy = self.busy(port: port)
            let reading = throughput(port: port)

            return LoadedModel(
                runtime: "\(name):\(port)",
                identifier: identifier,
                displayName: identifier,
                sizeBytes: path.flatMap(fileSize) ?? 0,
                quantisation: path.flatMap(quantisation),
                parameters: nil,
                architecture: nil,
                kind: nil,
                contextLength: props["n_ctx"] as? Int,
                maxContextLength: nil,
                activity: busy > 0 ? .generating : .loaded,
                timeToLive: nil,
                tokensPerSecond: reading?.rate,
                measuredAt: reading?.at.timeIntervalSince1970,
                inFlight: busy
            )
        }
    }

    /// llama-server holds its model for the life of the process, so releasing the memory
    /// means stopping the server — not something Resident will do behind your back.
    func unload(_ model: LoadedModel) -> String? {
        "llama-server holds one model for its lifetime; stop the server to release it"
    }

    private func liveEndpoints() -> [(port: Int, props: [String: Any])] {
        ports.compactMap { port in
            guard let props = Probe.json("http://localhost:\(port)/props", timeout: 0.4)
                    as? [String: Any] else { return nil }
            return (port, props)
        }
    }

    /// Slots mid-prediction. The endpoint is behind `--slots`; without it this is zero.
    private func busy(port: Int) -> Int {
        guard let slots = Probe.json("http://localhost:\(port)/slots", timeout: 0.4)
                as? [[String: Any]] else { return 0 }
        return slots.filter { ($0["is_processing"] as? Bool) == true }.count
    }

    /// Decode rate over the interval since the last sample, from the server's own
    /// `llamacpp:tokens_predicted_total` counter. The counter is behind `--metrics`;
    /// without it there is no measurement. When no tokens were produced in the interval
    /// the previous reading stands, so a finished burst is still reported with its time.
    private func throughput(port: Int) -> (rate: Double, at: Date)? {
        guard let text = Probe.get("http://localhost:\(port)/metrics", timeout: 0.4)
                .flatMap({ String(data: $0, encoding: .utf8) }),
              let total = Self.counter("llamacpp:tokens_predicted_total", in: text)
        else { return lastReading[port] }

        let now = Date()
        defer { previous[port] = (total, now) }
        guard let before = previous[port] else { return lastReading[port] }

        let elapsed = now.timeIntervalSince(before.at)
        let produced = total - before.tokens
        guard elapsed > 0.5, produced > 0 else { return lastReading[port] }
        let reading = (rate: Double(produced) / elapsed, at: now)
        lastReading[port] = reading
        return reading
    }

    /// One value from Prometheus text exposition: `name value` on a line of its own.
    static func counter(_ name: String, in text: String) -> Int? {
        for line in text.split(separator: "\n") where line.hasPrefix(name) {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 2, parts[0] == Substring(name),
                  let value = Double(parts[1]) else { continue }
            return Int(value)
        }
        return nil
    }

    private func fileSize(_ path: String) -> Int? {
        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        return (attributes?[.size] as? NSNumber)?.intValue
    }

    /// GGUF files name their quantisation in the filename, which is the only place a
    /// running llama-server exposes it.
    private func quantisation(_ path: String) -> String? {
        let name = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        let parts = name.split(separator: ".").map(String.init)
        return parts.last.flatMap { $0.uppercased().hasPrefix("Q") || $0.uppercased().hasPrefix("F")
            ? $0.uppercased() : nil }
    }
}

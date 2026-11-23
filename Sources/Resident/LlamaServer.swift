import Foundation

/// A bare `llama-server`, which has no model manager — one process, one model. It is
/// found by asking whether `/props` answers on the usual ports and on every port a
/// running `llama-server` process is listening on.
final class LlamaServer: ModelRuntime {
    let name = "llama.cpp"
    private let ports: [Int]
    private let discover: Bool

    /// The cumulative predicted-token counter from the last sample, per port, so a rate
    /// can be derived. Only the sampling queue touches this.
    private var previous: [Int: (tokens: Int, at: Date)] = [:]

    init(ports: [Int] = [8080, 8000, 8081], discover: Bool = true) {
        self.ports = ports
        self.discover = discover
    }

    static func isLlamaServer(_ arguments: [String]) -> Bool {
        arguments.first.map { URL(fileURLWithPath: $0).lastPathComponent == "llama-server" } ?? false
    }

    func isPresent() -> Bool { !liveEndpoints().isEmpty }

    func loadedModels() -> [LoadedModel] {
        liveEndpoints().map { port, props in
            let slots = Probe.json("http://localhost:\(port)/slots", timeout: 0.4) as? [[String: Any]]
            let size = (props["model_path"] as? String).flatMap(Self.fileSize) ?? 0
            return Self.model(props: props, slots: slots, port: port, size: size,
                              reading: throughput(port: port))
        }
    }

    static func model(props: [String: Any], slots: [[String: Any]]?, port: Int, size: Int,
                      reading: (rate: Double, at: Date)?) -> LoadedModel {
        let settings = props["default_generation_settings"] as? [String: Any]
        let path = (props["model_path"] as? String) ?? (settings?["model"] as? String)
        let identifier = path.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "model"
        // `/slots` is behind `--slots`; only a table that answered can say nothing is running.
        let busy = slots?.filter { ($0["is_processing"] as? Bool) == true }.count ?? 0
        let activity: LoadedModel.Activity = busy > 0 ? .generating : (slots == nil ? .loaded : .idle)
        // Current servers state the type, e.g. "IQ4_NL - 4.5 bpw"; older ones only the filename.
        let declared = (props["model_ftype"] as? String)?.split(separator: " ").first.map(String.init)

        return LoadedModel(
            runtime: "llama.cpp:\(port)",
            identifier: identifier,
            displayName: props["model_alias"] as? String ?? identifier,
            sizeBytes: size,
            quantisation: declared ?? path.flatMap(quantisation),
            parameters: nil,
            architecture: nil,
            kind: nil,
            contextLength: props["n_ctx"] as? Int ?? settings?["n_ctx"] as? Int,
            maxContextLength: nil,
            activity: activity,
            timeToLive: nil,
            tokensPerSecond: reading?.rate,
            measuredAt: reading?.at.timeIntervalSince1970,
            inFlight: busy,
            currentTokensPerSecond: reading?.rate
        )
    }

    /// llama-server holds its model for the life of the process, so releasing the memory
    /// means stopping the server — not something Resident will do behind your back.
    func unload(_ model: LoadedModel) -> String? {
        "llama-server holds one model for its lifetime; stop the server to release it"
    }

    private func liveEndpoints() -> [(port: Int, props: [String: Any])] {
        let discovered = discover ? ProcessList.servingPorts(where: Self.isLlamaServer) : []
        return Array(Set(ports + discovered)).sorted().compactMap { port in
            guard let props = Probe.json("http://localhost:\(port)/props", timeout: 0.4)
                    as? [String: Any] else { return nil }
            return (port, props)
        }
    }

    /// Decode rate over the interval since the last sample, from the server's own
    /// `llamacpp:tokens_predicted_total` counter. The counter is behind `--metrics`;
    /// without it there is no measurement. An idle interval reports zero; an unavailable measurement reports nil.
    private func throughput(port: Int) -> (rate: Double, at: Date)? {
        guard let text = Probe.get("http://localhost:\(port)/metrics", timeout: 0.4)
                .flatMap({ String(data: $0, encoding: .utf8) }),
              let total = Self.counter("llamacpp:tokens_predicted_total", in: text)
        else { previous[port] = nil; return nil }

        let now = Date()
        defer { previous[port] = (total, now) }
        guard let before = previous[port] else { previous[port] = nil; return nil }

        let elapsed = now.timeIntervalSince(before.at)
        let produced = total - before.tokens
        guard elapsed > 0.5, produced >= 0 else { return nil }
        let reading = (rate: Double(produced) / elapsed, at: now)
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

    private static func fileSize(_ path: String) -> Int? {
        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        return (attributes?[.size] as? NSNumber)?.intValue
    }

    /// GGUF files name their quantisation in the filename, which is the only place a
    /// running llama-server exposes it.
    private static func quantisation(_ path: String) -> String? {
        let name = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        let parts = name.split(separator: ".").map(String.init)
        return parts.last.flatMap { $0.uppercased().hasPrefix("Q") || $0.uppercased().hasPrefix("F")
            ? $0.uppercased() : nil }
    }
}

import Foundation

/// vLLM servers listed in `~/.config/resident/remotes.json` — rented GPU boxes, mostly.
///
/// vLLM publishes Prometheus counters on `/metrics` with no authentication even when
/// the API itself needs a key, and they are everything the menu wants: generated tokens
/// (a rate by difference between samples), prompt tokens, requests running and waiting,
/// KV cache fill. GPU utilisation is not among them; when the entry names a sidecar
/// that answers `/gpu`, that fills it in. Every number shown is one of those readings.
final class RemoteVLLM: ModelRuntime {
    let name = "vllm"
    private let load: () -> [Remote]

    /// Cumulative counters from the last sample, per remote and model, so rates can be
    /// derived. Only the sampling queue touches these.
    private var previous: [String: (generated: Int, prompt: Int, at: Date)] = [:]
    private var lastReading: [String: (rate: Double, prefill: Double?, at: Date)] = [:]
    private var previousPreemptions: [String: Int] = [:]

    init(load: @escaping () -> [Remote] = { Remotes.load() }) { self.load = load }

    func isPresent() -> Bool { !load().isEmpty }

    func loadedModels() -> [LoadedModel] {
        load().flatMap { models(for: $0) }
    }

    /// The box was rented by something else; releasing it means destroying it there.
    func unload(_ model: LoadedModel) -> String? {
        "runs on a remote box — stop it from whatever rented it, not from here"
    }

    // MARK: - One remote

    private func models(for remote: Remote) -> [LoadedModel] {
        // A box in another country with a 50 KB metrics page needs more than the
        // localhost timeout, and a box that has gone away must not cost more than this.
        guard let data = Probe.get(remote.metrics, timeout: 2.5),
              let text = String(data: data, encoding: .utf8) else { return [] }
        let metrics = Prometheus.parse(text)
        let gpu = gpuReading(remote)
        let now = Date()

        return metrics.modelNames.map { modelName in
            let key = "\(remote.host)/\(modelName)"
            let running = Int(metrics.value("vllm:num_requests_running", model: modelName) ?? 0)
            let waiting = Int(metrics.value("vllm:num_requests_waiting", model: modelName) ?? 0)
            let kv = metrics.value("vllm:kv_cache_usage_perc", model: modelName)
                ?? metrics.value("vllm:gpu_cache_usage_perc", model: modelName)
            let capacityWaits = Int(metrics.value("vllm:num_requests_waiting_by_reason", model: modelName,
                                                  where: ["reason": "capacity"]) ?? 0)
            let preemptions = metrics.value("vllm:num_preemptions_total", model: modelName).map { Int($0) }
            let thrashing = Self.isThrashing(preemptions: preemptions, before: previousPreemptions[key],
                                             waitingForCapacity: capacityWaits, kvCacheUsage: kv)
            if let preemptions { previousPreemptions[key] = preemptions }
            let reading = throughput(
                key: key, now: now,
                generated: Int(metrics.value("vllm:generation_tokens_total", model: modelName) ?? 0),
                prompt: Int(metrics.value("vllm:prompt_tokens_total", model: modelName) ?? 0)
            )

            return LoadedModel(
                runtime: "\(name)@\(remote.host)",
                identifier: modelName,
                displayName: modelName,
                sizeBytes: 0,
                quantisation: remote.quant,
                parameters: nil,
                architecture: nil,
                kind: nil,
                contextLength: remote.contextLength,
                maxContextLength: nil,
                activity: running > 0 ? .generating : .loaded,
                timeToLive: nil,
                tokensPerSecond: reading?.rate,
                measuredAt: reading?.at.timeIntervalSince1970,
                inFlight: running,
                remote: RemoteInfo(
                    name: remote.name,
                    provider: remote.providerName ?? "remote",
                    host: remote.host,
                    // The entry's short label ("H100 SXM") reads better in a menu row than
                    // the driver's full name; the sidecar's name fills in when there is none.
                    gpu: remote.gpu ?? gpu?.name,
                    gpuUtilisation: gpu?.utilisation,
                    gpuMemoryUsed: gpu?.memoryUsed,
                    gpuMemoryTotal: gpu?.memoryTotal,
                    kvCacheUsage: kv,
                    queued: waiting,
                    promptTokensPerSecond: reading?.prefill,
                    waitingForCapacity: capacityWaits,
                    preemptions: preemptions,
                    thrashing: thrashing
                )
            )
        }
    }

    /// Thrash: the box evicted a running request since the last sample (the preemption
    /// counter moved) and is still short of cache — requests parked for capacity, or the
    /// cache nearly full. One preemption with room to spare is a blip; this is the
    /// pattern where every turn recomputes 100K tokens of context somebody else evicted.
    static func isThrashing(preemptions: Int?, before: Int?, waitingForCapacity: Int,
                            kvCacheUsage: Double?) -> Bool {
        guard let preemptions, let before, preemptions > before else { return false }
        return waitingForCapacity > 0 || (kvCacheUsage ?? 0) >= 0.85
    }

    /// Decode and prefill rates over the interval since the last sample, from the
    /// server's own cumulative counters. When nothing was generated in the interval the
    /// previous reading stands, so a finished burst is still reported with its time.
    private func throughput(key: String, now: Date, generated: Int,
                            prompt: Int) -> (rate: Double, prefill: Double?, at: Date)? {
        defer { previous[key] = (generated, prompt, now) }
        guard let before = previous[key] else { return lastReading[key] }

        let elapsed = now.timeIntervalSince(before.at)
        let produced = generated - before.generated
        guard elapsed > 0.5, produced > 0 else { return lastReading[key] }
        let consumed = prompt - before.prompt
        let reading = (rate: Double(produced) / elapsed,
                       prefill: consumed > 0 ? Double(consumed) / elapsed : nil,
                       at: now)
        lastReading[key] = reading
        return reading
    }

    // MARK: - GPU sidecar

    private struct GPUReading {
        var name: String?
        var utilisation: Double?
        var memoryUsed: Int?
        var memoryTotal: Int?
    }

    /// `GET <ctl_url>/gpu` → `{"name": "...", "utilization": 0-100, "memory_used_mib": n,
    /// "memory_total_mib": n}`. Anything missing is simply not shown.
    private func gpuReading(_ remote: Remote) -> GPUReading? {
        guard let control = remote.controlURL else { return nil }
        var headers: [String: String] = [:]
        if let token = remote.token { headers["Authorization"] = "Bearer " + token }
        guard let data = Probe.get(control + "/gpu", timeout: 1.5, headers: headers),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        func number(_ key: String) -> Double? { (json[key] as? NSNumber)?.doubleValue }
        return GPUReading(
            name: json["name"] as? String,
            utilisation: number("utilization").map { min(max($0 / 100, 0), 1) },
            memoryUsed: number("memory_used_mib").map { Int($0) << 20 },
            memoryTotal: number("memory_total_mib").map { Int($0) << 20 }
        )
    }
}

/// The subset of Prometheus text exposition vLLM uses: `name{label="v",...} value`
/// and `name value`. Histograms and comments are skipped.
struct Prometheus {
    struct Sample: Equatable {
        var name: String
        var labels: [String: String]
        var value: Double
    }

    var samples: [Sample]

    static func parse(_ text: String) -> Prometheus {
        var samples: [Sample] = []
        for rawLine in text.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            guard let space = line.lastIndex(of: " "),
                  let value = Double(line[line.index(after: space)...]) else { continue }
            let head = String(line[..<space])
            if let brace = head.firstIndex(of: "{"), head.hasSuffix("}") {
                let name = String(head[..<brace])
                let inner = head[head.index(after: brace)..<head.index(before: head.endIndex)]
                samples.append(Sample(name: name, labels: labels(String(inner)), value: value))
            } else {
                samples.append(Sample(name: head, labels: [:], value: value))
            }
        }
        return Prometheus(samples: samples)
    }

    /// `a="1",b="x y"` → dictionary. Values are quoted; a comma inside a value is rare
    /// in vLLM's output and would only split that one label.
    private static func labels(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        for pair in text.split(separator: ",") {
            guard let equals = pair.firstIndex(of: "=") else { continue }
            let key = pair[..<equals].trimmingCharacters(in: .whitespaces)
            var value = pair[pair.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("\"") { value.removeFirst() }
            if value.hasSuffix("\"") { value.removeLast() }
            result[key] = value
        }
        return result
    }

    /// Every model vLLM is serving, from the `model_name` label on its counters.
    var modelNames: [String] {
        var seen: [String] = []
        for sample in samples where sample.name.hasPrefix("vllm:") {
            if let model = sample.labels["model_name"], !seen.contains(model) { seen.append(model) }
        }
        return seen
    }

    func value(_ name: String, model: String, where extra: [String: String] = [:]) -> Double? {
        samples.first { sample in
            sample.name == name && sample.labels["model_name"] == model
                && extra.allSatisfy { sample.labels[$0.key] == $0.value }
        }?.value
    }
}

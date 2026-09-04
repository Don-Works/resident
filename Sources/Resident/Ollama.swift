import Foundation

/// Ollama, via its running-models endpoint. `size_vram` is the number that matters on a
/// unified-memory Mac: it is what the GPU actually has resident.
final class Ollama: ModelRuntime {
    let name = "Ollama"
    private let base: String

    init(base: String = ProcessInfo.processInfo.environment["OLLAMA_HOST"].map {
        $0.hasPrefix("http") ? $0 : "http://" + $0
    } ?? "http://localhost:11434") {
        self.base = base
    }

    func isPresent() -> Bool { Probe.get(base + "/api/tags", timeout: 0.4) != nil }

    func loadedModels() -> [LoadedModel] {
        guard let root = Probe.json(base + "/api/ps") as? [String: Any],
              let models = root["models"] as? [[String: Any]] else { return [] }

        return models.compactMap { entry in
            guard let id = (entry["name"] ?? entry["model"]) as? String else { return nil }
            let details = entry["details"] as? [String: Any]
            // A model split between GPU and CPU decodes at the speed of the slower half,
            // so prefer the resident-on-GPU figure when Ollama reports one.
            let vram = entry["size_vram"] as? Int ?? 0
            let total = entry["size"] as? Int ?? 0

            return LoadedModel(
                runtime: name,
                identifier: id,
                displayName: id,
                sizeBytes: vram > 0 ? vram : total,
                quantisation: details?["quantization_level"] as? String,
                parameters: details?["parameter_size"] as? String,
                architecture: details?["family"] as? String,
                kind: nil,
                contextLength: entry["context_length"] as? Int,
                maxContextLength: nil,
                activity: .loaded,
                timeToLive: expiry(entry["expires_at"] as? String)
            )
        }
    }

    func unload(_ model: LoadedModel) -> String? {
        // keep_alive 0 is Ollama's documented "drop it now".
        let ok = Probe.post(base + "/api/generate",
                            json: ["model": model.identifier, "keep_alive": 0])
        return ok ? nil : "Ollama refused the unload request"
    }

    private func expiry(_ text: String?) -> TimeInterval? {
        guard let text else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = formatter.date(from: text) ?? ISO8601DateFormatter().date(from: text)
        guard let date else { return nil }
        let remaining = date.timeIntervalSinceNow
        return remaining > 0 ? remaining : nil
    }
}

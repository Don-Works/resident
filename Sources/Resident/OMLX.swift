import Foundation

/// oMLX reports loaded models individually, but its public activity count is server-wide.
final class OMLX: ModelRuntime {
    let name: String
    private let base: String

    init(port: Int = 8001) {
        name = "oMLX:\(port)"
        base = "http://127.0.0.1:\(port)"
    }

    func isPresent() -> Bool {
        guard let status = Probe.json(base + "/api/status", timeout: 0.4) as? [String: Any] else { return false }
        return status["models_loaded"] != nil && status["active_requests"] != nil
    }

    func loadedModels() -> [LoadedModel] {
        guard let status = Probe.json(base + "/api/status", timeout: 0.4) as? [String: Any],
              let models = Probe.json(base + "/v1/models/status", timeout: 0.4) as? [String: Any] else { return [] }
        return Self.parse(status: status, models: models, runtime: name)
    }

    static func parse(status: [String: Any], models: [String: Any], runtime: String) -> [LoadedModel] {
        guard let rows = models["models"] as? [[String: Any]] else { return [] }
        let active = status["active_requests"] as? Int
        return rows.compactMap { row in
            let loading = row["is_loading"] as? Bool == true
            guard row["loaded"] as? Bool == true || loading,
                  let id = row["id"] as? String else { return nil }
            let actual = row["actual_size"] as? Int
            return LoadedModel(runtime: runtime, identifier: id,
                displayName: row["model_alias"] as? String ?? id,
                sizeBytes: actual ?? row["estimated_size"] as? Int ?? 0,
                quantisation: nil, parameters: nil, architecture: row["config_model_type"] as? String,
                kind: row["model_type"] as? String,
                contextLength: row["max_context_window"] as? Int,
                maxContextLength: row["model_context_length"] as? Int,
                activity: loading ? .loading : (active == 0 ? .idle : .loaded), timeToLive: nil,
                sizeIsApproximate: true, runtimeInFlight: active)
        }
    }

    func unload(_ model: LoadedModel) -> String? {
        "release this model through oMLX; Resident only reads its status"
    }
}

import Foundation

/// oMLX reports loaded models individually, but its public activity count is server-wide.
/// Every running oMLX server is read, not only the default port: a second instance (a
/// benchmark, a scratch server) holds memory just the same.
final class OMLX: ModelRuntime {
    let name = "oMLX"
    private let ports: [Int]
    private let discovered: ServingPorts?

    init(ports: [Int] = [8001], discover: Bool = true) {
        self.ports = ports
        discovered = discover ? ServingPorts(matching: Self.isOMLX) : nil
    }

    /// oMLX renames its process `omlx-server`; launched another way it still says `omlx serve`.
    static func isOMLX(_ arguments: [String]) -> Bool {
        if arguments.first.map({ ($0 as NSString).lastPathComponent == "omlx-server" }) == true {
            return true
        }
        return zip(arguments, arguments.dropFirst()).contains {
            ($0.0 as NSString).lastPathComponent == "omlx" && $0.1 == "serve"
        }
    }

    func isPresent() -> Bool { !liveStatuses().isEmpty }

    func loadedModels() -> [LoadedModel] {
        liveStatuses().flatMap { port, status -> [LoadedModel] in
            guard let models = Probe.json("http://127.0.0.1:\(port)/v1/models/status", timeout: 0.4)
                    as? [String: Any] else { return [] }
            return Self.parse(status: status, models: models, runtime: "\(name):\(port)")
        }
    }

    private func liveStatuses() -> [(port: Int, status: [String: Any])] {
        return Array(Set(ports + (discovered?.current() ?? []))).sorted().compactMap { port in
            guard let status = Probe.json("http://127.0.0.1:\(port)/api/status", timeout: 0.4)
                    as? [String: Any],
                  status["models_loaded"] != nil, status["active_requests"] != nil else { return nil }
            return (port, status)
        }
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

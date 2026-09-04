import Foundation

/// One model currently occupying memory, however it got there.
struct LoadedModel: Codable, Sendable, Equatable {
    enum Activity: String, Codable, Sendable {
        case generating, idle, loaded

        var label: String {
            switch self {
            case .generating: return "generating"
            case .idle: return "idle"
            case .loaded: return "loaded"
            }
        }
    }

    /// Which runtime is holding it — the thing you would have to ask to let go.
    var runtime: String
    /// The identifier that runtime's own unload command expects.
    var identifier: String
    var displayName: String
    var sizeBytes: Int
    var quantisation: String?
    var parameters: String?
    var architecture: String?
    var kind: String?
    var contextLength: Int?
    var maxContextLength: Int?
    var activity: Activity
    /// Seconds until the runtime unloads it by itself, if it has been told to.
    var timeToLive: TimeInterval?
    var pid: pid_t?
    /// Set when the size is inferred from process memory rather than reported by the
    /// runtime, because that number includes the KV cache and runtime overhead.
    var sizeIsApproximate: Bool = false
    /// Decode rate the runtime itself reported for the most recent prediction it
    /// finished on this model. A measurement, unlike `decodeCeiling` — nil where the
    /// runtime offers none.
    var tokensPerSecond: Double?
    /// Unix time of that measurement.
    var measuredAt: Double?
    /// Predictions the runtime is serving on this model right now.
    var inFlight: Int = 0

    /// Runtimes disagree on the spelling — LM Studio says "embeddings", the index
    /// says "embedding" — and an embedding model has no decode loop to put a ceiling on.
    var isEmbedding: Bool { kind?.hasPrefix("embed") == true }

    /// Ceiling on decode speed set by memory bandwidth alone.
    ///
    /// Generating one token requires reading every active weight from DRAM once, so
    /// tokens/second cannot exceed bandwidth ÷ weight bytes no matter how fast the GPU
    /// is. For dense models this is the number that decides how the model feels. It is
    /// an upper bound and real throughput lands below it; a mixture-of-experts model
    /// reads only its active experts and will beat it.
    func decodeCeiling(peakBandwidth: Double?) -> Double? {
        guard let peakBandwidth, sizeBytes > 0, !isEmbedding else { return nil }
        return peakBandwidth / Double(sizeBytes)
    }

    /// Bandwidth this model would demand to sustain a given decode rate.
    func bandwidthDemand(tokensPerSecond: Double) -> Double {
        Double(sizeBytes) * tokensPerSecond
    }
}

extension Array where Element == LoadedModel {
    var totalBytes: Int { reduce(0) { $0 + $1.sizeBytes } }

    /// Models holding memory while doing nothing. These are the reclaim candidates.
    var idleModels: [LoadedModel] { filter { $0.activity != .generating } }

    /// Deterministic order: busiest first, then largest, so the menu does not reshuffle
    /// under the pointer while a sample lands.
    var ranked: [LoadedModel] {
        sorted {
            if ($0.activity == .generating) != ($1.activity == .generating) {
                return $0.activity == .generating
            }
            if $0.sizeBytes != $1.sizeBytes { return $0.sizeBytes > $1.sizeBytes }
            return $0.identifier < $1.identifier
        }
    }
}

/// A runtime Resident knows how to interrogate.
protocol ModelRuntime {
    /// Shown in the menu and in `resident status`.
    var name: String { get }
    /// Cheap check so an absent runtime costs nothing per sample.
    func isPresent() -> Bool
    func loadedModels() -> [LoadedModel]
    /// Asks the runtime to release one model. Returns nil on success, a reason on failure.
    func unload(_ model: LoadedModel) -> String?
    /// Fetches anything the runtime only reports slowly, and waits for it.
    func refreshDetail()
    /// Releases anything long-lived the runtime holds — a child process, a socket.
    func stop()
}

extension ModelRuntime {
    func refreshDetail() {}
    func stop() {}
}

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
    /// Decode rate of the most recent prediction the runtime finished on this model,
    /// from the runtime's own statistics: generated tokens over generation time, with
    /// prompt processing excluded. A measurement, unlike `decodeCeiling` — nil where
    /// the runtime offers none.
    var tokensPerSecond: Double?
    /// Unix time of that measurement.
    var measuredAt: Double?
    /// The prompt that prediction processed, and how long it took before the first
    /// token. A long context makes a request feel slow without the decode being slow.
    var promptTokens: Int?
    var timeToFirstToken: Double?
    /// Predictions the runtime is serving on this model right now.
    var inFlight: Int = 0
    /// Set when the model is served by a box elsewhere. Its weights are in that box's
    /// VRAM, so it takes no part in this machine's memory arithmetic.
    var remote: RemoteInfo? = nil

    var isRemote: Bool { remote != nil }

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

/// What a remote box reports about itself, alongside the model it serves. Every field
/// is one of the box's own readings; nothing is estimated.
struct RemoteInfo: Codable, Sendable, Equatable {
    /// The entry's name in remotes.json — what the provisioner called the box.
    var name: String
    /// Who owns the metal: an explicit label, or the registrable domain of a hostname.
    var provider: String
    var host: String
    var gpu: String?
    /// Fraction of the interval the card was busy, from the box's sidecar.
    var gpuUtilisation: Double?
    var gpuMemoryUsed: Int?
    var gpuMemoryTotal: Int?
    /// Fraction of the KV cache in use, from vLLM.
    var kvCacheUsage: Double?
    /// Requests queued behind the ones running.
    var queued: Int = 0
    /// Prompt tokens per second over the last interval — prefill speed.
    var promptTokensPerSecond: Double?
    /// Requests the box has parked because its KV cache is full.
    var waitingForCapacity: Int = 0
    /// vLLM's cumulative preemption counter: a running request evicted to make room.
    var preemptions: Int?
    /// True when preemptions rose since the last sample while requests wait for cache
    /// or the cache is nearly full — the box is recomputing contexts instead of serving.
    var thrashing: Bool = false
}

extension Array where Element == LoadedModel {
    /// Models holding this machine's memory. Remote boxes are excluded from every
    /// memory figure, because their weights are not here.
    var local: [LoadedModel] { filter { !$0.isRemote } }
    var remotes: [LoadedModel] { filter { $0.isRemote } }

    var totalBytes: Int { local.reduce(0) { $0 + $1.sizeBytes } }

    /// Models holding memory while doing nothing. These are the reclaim candidates.
    var idleModels: [LoadedModel] { local.filter { $0.activity != .generating } }

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

import Foundation

/// The plain-language answer, worked out before any percentage is shown.
///
/// A percentage cannot tell you whether the machine is doing the thing you want. Memory
/// at 80% is fine if it is all model weights and nothing is paging, and a disaster at
/// 60% if the weights no longer fit and macOS is swapping them. This computes what is
/// actually true and says it in a sentence.
struct Verdict {
    var level: Level = .ok
    var headline: String = "Nothing loaded"
    /// Facts, most useful first.
    var summary: [String] = []
    /// Things that are wrong, each with what to do about it.
    var warnings: [String] = []

    /// Unified memory a further model could actually claim.
    var headroom: Int = 0
    /// True when free memory, not the GPU ceiling, is what limits the headroom.
    var headroomLimitedByMemory = false
    /// Memory held by models that are not generating.
    var reclaimable: Int = 0
    var reclaimCandidates: [LoadedModel] = []
    /// A remote box is evicting running requests to fit contexts that exceed its cache.
    var thrashing: [LoadedModel] = []

    static func evaluate(sample: Sample, hardware: Hardware = .current,
                         thresholds: Thresholds = .default) -> Verdict {
        var verdict = Verdict()
        let models = sample.models.local
        let resident = models.totalBytes

        // The Metal ceiling is not the only limit. If the machine has already handed
        // its memory to something else, the GPU being *allowed* another 70 GB is no
        // help — loading into it just pages. Take whichever bound is tighter.
        let gpuHeadroom = max(hardware.workingSetLimit - resident, 0)
        let free = max(sample.memory.available, 0)
        verdict.headroom = min(gpuHeadroom, free)
        verdict.headroomLimitedByMemory = free < gpuHeadroom
        verdict.reclaimCandidates = models.idleModels
        verdict.reclaimable = verdict.reclaimCandidates.totalBytes
        verdict.thrashing = sample.models.remotes.filter { $0.remote?.thrashing == true }

        verdict.summary = summary(sample: sample, hardware: hardware,
                                  headroom: verdict.headroom,
                                  limitedByMemory: verdict.headroomLimitedByMemory)
        verdict.warnings = warnings(sample: sample, hardware: hardware, thresholds: thresholds,
                                    verdict: verdict)
        (verdict.level, verdict.headline) = headline(sample: sample, hardware: hardware,
                                                     thresholds: thresholds, verdict: verdict)
        return verdict
    }

    // MARK: - Pieces

    private static func summary(sample: Sample, hardware: Hardware, headroom: Int,
                                limitedByMemory: Bool) -> [String] {
        var lines: [String] = []
        let models = sample.models.local

        if models.isEmpty {
            lines.append("No models resident. \(Format.bytes(headroom)) available to load into.")
        } else {
            let count = models.count == 1 ? "1 model" : "\(models.count) models"
            lines.append("\(count) resident, holding \(Format.bytes(models.totalBytes)) "
                + "of \(Format.bytes(hardware.workingSetLimit)) the GPU may use")
            lines.append("Room for \(Format.bytes(headroom)) more"
                + (limitedByMemory
                    ? " — free memory, not the GPU ceiling, is the binding limit"
                    : (biggest(models).map {
                        " — the largest loaded is \(Format.bytes($0.sizeBytes))" } ?? "")))
        }

        // Weights are not the whole cost. The gap between them and what the GPU has
        // resident is the KV cache and runtime overhead, and at a long context window
        // that gap can exceed the model itself.
        let overhead = sample.gpuResidentBytes - models.totalBytes
        if !models.isEmpty, overhead > 512 << 20 {
            lines.append("GPU has \(Format.bytes(sample.gpuResidentBytes)) allocated — "
                + "\(Format.bytes(overhead)) beyond the weights, which is KV cache and "
                + "runtime overhead")
        }

        if let measured = throughput(sample: sample) {
            lines.append(measured)
        }

        lines.append(contentsOf: remoteLines(sample.models.remotes))
        return lines
    }

    /// One line per remote box, every figure the box's own: decode and prefill rates
    /// from vLLM's counters, queue depth and KV fill from the same page, and GPU busy
    /// time from the sidecar where there is one.
    static func remoteLines(_ remotes: [LoadedModel]) -> [String] {
        remotes.map { model in
            let info = model.remote!
            var head = "☁ \(model.displayName) on \(info.provider)"
            if let gpu = info.gpu { head += " (\(gpu))" }
            if let rate = model.tokensPerSecond {
                head += model.activity == .generating
                    ? " is decoding at \(Format.tokens(rate))"
                    : " last decoded at \(Format.tokens(rate))"
            } else {
                head += model.activity == .generating ? " is generating" : " is serving, idle"
            }
            var facts: [String] = []
            if model.inFlight > 0 || info.queued > 0 {
                facts.append("\(model.inFlight) running" + (info.queued > 0 ? ", \(info.queued) queued" : ""))
            }
            // The counter rate is the box's total. Several agents share it, so say what
            // each one is getting.
            if model.inFlight > 1, let rate = model.tokensPerSecond {
                facts.append("\(Format.tokens(rate / Double(model.inFlight))) each")
            }
            if let prefill = info.promptTokensPerSecond { facts.append("prefill \(Format.tokens(prefill))") }
            if let kv = info.kvCacheUsage { facts.append("KV cache \(Format.percent(kv)) full") }
            if let busy = info.gpuUtilisation { facts.append("GPU \(Format.percent(busy)) busy") }
            return facts.isEmpty ? head : head + " — " + facts.joined(separator: ", ")
        }
    }

    /// What the working model actually managed: the runtime's own figure for the
    /// prediction it last completed. No ceiling is set against it — a mixture-of-experts
    /// model beats the dense arithmetic, and a bound the screen contradicts is worse
    /// than none.
    private static func throughput(sample: Sample) -> String? {
        guard let model = sample.working, !model.isRemote,
              let rate = model.tokensPerSecond else { return nil }
        let verb = model.activity == .generating ? "is decoding" : "last decoded"
        return "\(model.displayName) \(verb) at \(Format.tokens(rate))"
    }

    private static func warnings(sample: Sample, hardware: Hardware, thresholds: Thresholds,
                                 verdict: Verdict) -> [String] {
        var result: [String] = []
        let models = sample.models.local

        // The level of swap is not a fault; macOS never shrinks it eagerly, so it sits
        // high long after the pressure that caused it. Only the rate means anything.
        let paging = sample.memory.swapoutRate ?? 0
        if !models.isEmpty, paging >= thresholds.swapoutWarn {
            result.append("pages are going to disk at \(Format.rate(paging)) while models "
                + "are resident — that costs far more throughput than any quantisation "
                + "choice")
        } else if !models.isEmpty, sample.memory.swapIsResidual {
            result.append("\(Format.bytes(sample.memory.swapUsed)) of swap is still "
                + "allocated from earlier pressure, but nothing is paging now — this is "
                + "residue, and macOS will reclaim it in its own time")
        }

        if sample.memoryPressure == .critical {
            result.append("the kernel reports critical memory pressure; macOS will start "
                + "killing processes to reclaim pages")
        } else if sample.memoryPressure == .warning, !models.isEmpty {
            result.append("the kernel reports memory pressure — there is less room than "
                + "the used-memory percentage suggests")
        }

        if let biggest = biggest(models), verdict.headroom < biggest.sizeBytes {
            result.append("no room to load another model the size of the largest one "
                + "already resident (\(Format.bytes(biggest.sizeBytes)))")
        }

        if verdict.reclaimable >= 4 << 30 {
            let names = verdict.reclaimCandidates.prefix(3).map(\.displayName).joined(separator: ", ")
            result.append("\(Format.bytes(verdict.reclaimable)) is held by models that are "
                + "not generating (\(names))")
        }

        if let greedy = models.first(where: {
            ($0.contextLength ?? 0) >= 131_072 && $0.sizeBytes > 4 << 30
        }) {
            result.append("\(greedy.displayName) is loaded at "
                + "\(Format.contextLength(greedy.contextLength ?? 0)) context — the KV "
                + "cache that reserves grows with the window, whether or not you use it")
        }

        for model in verdict.thrashing {
            let info = model.remote!
            result.append("\(info.name) on \(info.provider) is thrashing: \(info.waitingForCapacity) "
                + "request(s) waiting for cache, \(info.preemptions ?? 0) preemptions so far, KV cache "
                + "\(Format.percent(info.kvCacheUsage ?? 0)) full — the contexts in flight exceed its "
                + "cache, so it evicts one to serve another and recomputes it later. Compact or close "
                + "sessions, or switch to a lane with a bigger cache")
        }

        if let model = models.first(where: { $0.sizeBytes > hardware.maxBufferLength }) {
            result.append("\(model.displayName) is larger than the largest single Metal "
                + "allocation (\(Format.bytes(hardware.maxBufferLength))) and must be split")
        }
        return result
    }

    private static func headline(sample: Sample, hardware: Hardware, thresholds: Thresholds,
                                 verdict: Verdict) -> (Level, String) {
        let models = sample.models.local
        if let box = verdict.thrashing.first?.remote {
            return (.critical, "\(box.name) is thrashing — too much context for its cache")
        }
        guard !models.isEmpty else {
            let remotes = sample.models.remotes
            if let first = remotes.first?.remote {
                let boxes = remotes.count == 1 ? "a box on \(first.provider)" : "\(remotes.count) remote boxes"
                return (.ok, "Nothing loaded locally — \(boxes) serving")
            }
            return (.ok, sample.runtimesSeen.isEmpty
                ? "No inference runtime running"
                : "Nothing loaded — \(Format.bytes(verdict.headroom)) free to load into")
        }

        let paging = sample.memory.swapoutRate ?? 0
        if paging >= thresholds.swapoutCritical || sample.memoryPressure == .critical {
            return (.critical, "Paging weights — throughput is collapsing")
        }
        if paging >= thresholds.swapoutWarn {
            return (.warn, "Paging to disk with models resident")
        }
        if sample.memoryPressure == .warning {
            return (.warn, "Under memory pressure with models resident")
        }
        if let biggest = biggest(models), verdict.headroom < biggest.sizeBytes {
            return (.notice, "Full — no room for another model this size")
        }
        if verdict.reclaimable >= 4 << 30 {
            return (.notice, "\(Format.bytes(verdict.reclaimable)) held by idle models")
        }
        return (.ok, "Running with room to spare")
    }

    private static func biggest(_ models: [LoadedModel]) -> LoadedModel? {
        models.max { $0.sizeBytes < $1.sizeBytes }
    }

}

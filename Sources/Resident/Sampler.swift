import Foundation

/// Builds a `Sample`. Runs on a background queue: it talks to model runtimes over HTTP
/// and must never be on the path that draws the menu.
final class Sampler {
    private let runtimes: [ModelRuntime]
    private let hardware = Hardware.current
    /// When true, runtimes that only report some facts slowly are asked to fetch them
    /// and waited for. Costs seconds; used by one-shot commands, never by the menu.
    private let detailed: Bool

    /// Previous swapout counter, so the *rate* can be derived. One reading tells you
    /// nothing — the counter is cumulative since boot.
    private var previousSwapouts: (pages: UInt64, at: Date)?

    /// `live` keeps runtime connections open between samples — the LM Studio log
    /// stream that reports throughput. Costs a child process, so only long-running
    /// modes ask for it.
    init(runtimes: [ModelRuntime]? = nil, detailed: Bool = false, live: Bool = false) {
        self.runtimes = runtimes
            ?? [LMStudio(live: live), Ollama(), LlamaServer(), UnmanagedRuntime()]
        self.detailed = detailed
    }

    func stop() { runtimes.forEach { $0.stop() } }

    func take() -> Sample {
        var models: [LoadedModel] = []
        var seen: [String] = []
        for runtime in runtimes where runtime.isPresent() {
            seen.append(runtime.name)
            if detailed { runtime.refreshDetail() }
            models.append(contentsOf: runtime.loadedModels())
        }

        let memory = MemoryStats.read()
        let pagingRate: Double? = memory.flatMap { swapoutRate(from: $0) }
        let swap = Sysctl.swapUsage()
        let gpu = GPU.read()

        let snapshot = Sample.MemorySnapshot(
            total: memory?.totalBytes ?? hardware.totalMemory,
            available: memory?.availableBytes ?? 0,
            wired: memory?.wiredBytes ?? 0,
            compressed: memory?.compressedBytes ?? 0,
            swapUsed: swap?.used ?? 0,
            swapTotal: swap?.total ?? 0,
            swapoutRate: pagingRate
        )

        return Sample(
            ts: Date().timeIntervalSince1970,
            gauges: gauges(models: models, memory: snapshot, gpu: gpu),
            models: models.ranked,
            memory: snapshot,
            gpuUtilisation: gpu?.deviceUtilisation ?? 0,
            gpuResidentBytes: gpu?.allocatedMemory ?? 0,
            pressure: MemoryPressure.read()?.rawValue ?? MemoryPressure.normal.rawValue,
            runtimesSeen: seen
        )
    }

    /// Bytes per second going to swap since the last sample. The first call has nothing
    /// to compare against, so it takes a second reading rather than report nothing — a
    /// one-shot `resident status` would otherwise never know whether the machine is
    /// paging, which is the one thing it most needs to say.
    private func swapoutRate(from current: MemoryStats.Snapshot) -> Double? {
        defer { previousSwapouts = (current.swapouts, Date()) }

        guard let previous = previousSwapouts else {
            Thread.sleep(forTimeInterval: 0.4)
            guard let second = MemoryStats.read() else { return nil }
            previousSwapouts = (second.swapouts, Date())
            let pages = second.swapouts >= current.swapouts
                ? second.swapouts - current.swapouts : 0
            return Double(pages) * Double(current.pageSize) / 0.4
        }

        let elapsed = Date().timeIntervalSince(previous.at)
        guard elapsed > 0.2 else { return nil }
        // The counter is monotonic; a decrease means it wrapped or the host reset it.
        guard current.swapouts >= previous.pages else { return 0 }
        let pages = current.swapouts - previous.pages
        return Double(pages) * Double(current.pageSize) / elapsed
    }

    /// Asks whichever runtime owns a model to release it. Returns a reason per failure.
    func unload(_ models: [LoadedModel]) -> [String] {
        models.compactMap { model in
            guard let runtime = runtimes.first(where: { $0.name == model.runtime })
                    ?? runtimes.first(where: { model.runtime.hasPrefix($0.name) }) else {
                return "\(model.displayName): no runtime owns it"
            }
            return runtime.unload(model).map { "\(model.displayName): \($0)" }
        }
    }

    private func gauges(models: [LoadedModel], memory: Sample.MemorySnapshot,
                        gpu: GPU.Snapshot?) -> [Gauge] {
        var result: [Gauge?] = []
        result.append(weightsGauge(models: models))
        result.append(gpuMemoryGauge(gpu, models: models))
        result.append(memoryGauge(memory))
        result.append(gpuGauge(gpu))
        result.append(swapGauge(memory, models: models))
        return result.compactMap { $0 }
    }

    /// What the GPU actually holds, which is always more than the weights. The gap is
    /// the KV cache and runtime overhead, and at a long context window it can exceed the
    /// model. This is the gauge that explains where the memory really went.
    private func gpuMemoryGauge(_ gpu: GPU.Snapshot?, models: [LoadedModel]) -> Gauge? {
        guard let gpu, gpu.allocatedMemory > 0 else { return nil }
        // With nothing loaded this is the window server and the browsers, not inference
        // overhead — claiming otherwise would be a lie in the quiet case.
        let overhead = models.isEmpty ? 0 : gpu.allocatedMemory - models.totalBytes
        return Gauge(
            key: "gpumemory",
            label: "GPU memory allocated",
            used: Double(gpu.allocatedMemory),
            limit: Double(hardware.workingSetLimit),
            unit: .bytes,
            note: models.isEmpty
                ? "no models loaded — this is the window server and other GPU clients"
                : (overhead > 256 << 20
                    ? "\(Format.bytes(overhead)) of this is KV cache and runtime "
                        + "overhead, not weights"
                    : nil)
        )
    }

    /// The headline ceiling. Metal's recommended working set is the amount of unified
    /// memory the GPU may hold; a model that does not fit under it is not slow, it is
    /// paged, and decode collapses by an order of magnitude.
    private func weightsGauge(models: [LoadedModel]) -> Gauge {
        let approximate = models.contains { $0.sizeIsApproximate }
        return Gauge(
            key: "weights",
            label: "Model weights resident",
            used: Double(models.totalBytes),
            limit: Double(hardware.workingSetLimit),
            unit: .bytes,
            note: approximate
                ? "includes a process-memory estimate for a runtime with no model API"
                : nil
        )
    }

    private func memoryGauge(_ memory: Sample.MemorySnapshot) -> Gauge {
        Gauge(
            key: "memory",
            label: "Memory in use",
            used: Double(memory.used),
            limit: Double(memory.total),
            unit: .bytes
        )
    }

    private func gpuGauge(_ gpu: GPU.Snapshot?) -> Gauge? {
        guard let gpu else { return nil }
        // A busy GPU is the machine working, not a problem, so it never raises the
        // level on its own. It is here to answer "is it actually on the GPU?".
        return Gauge(
            key: "gpu",
            label: "GPU utilisation",
            used: gpu.deviceUtilisation,
            limit: 1,
            unit: .ratio,
            informational: true,
            note: gpu.recoveryCount > 0
                ? "the driver has reset the GPU \(gpu.recoveryCount) time(s) since boot"
                : nil
        )
    }

    /// Swap is normal on macOS and means nothing on its own. Swap while models are
    /// resident means weights are being paged to disk, which is the worst thing that
    /// can happen to inference throughput.
    private func swapGauge(_ memory: Sample.MemorySnapshot, models: [LoadedModel]) -> Gauge? {
        guard memory.swapTotal > 0 else { return nil }
        let paging = (memory.swapoutRate ?? 0) >= Thresholds.default.swapoutWarn
        let note: String
        if paging {
            note = "writing \(Format.rate(memory.swapoutRate ?? 0)) to disk right now"
                + (models.isEmpty ? "" : " — that is weight pages")
        } else if memory.swapUsed > 0 {
            note = "nothing is paging right now; macOS does not shrink swap eagerly, so "
                + "this is residue from earlier pressure and costs disk, not throughput"
        } else {
            note = "macOS grows swap on demand"
        }
        return Gauge(
            key: "swap",
            label: "Swap in use",
            used: Double(memory.swapUsed),
            limit: Double(memory.swapTotal),
            unit: .bytes,
            // A full swap file is not a fault. Writing to it during inference is.
            informational: !paging,
            note: note
        )
    }
}

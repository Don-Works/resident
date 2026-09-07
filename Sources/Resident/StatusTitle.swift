import Foundation

/// The status item's text: provider · model · quant · tok/s · gpu, in that order, for
/// one model only — the one with the highest rate on record, wherever it runs. Nothing
/// else shares the bar, and the choice does not move as requests start and stop, since
/// a rate outlives the request that produced it. A field with no reading is left out
/// rather than filled with a dash, and nothing is a glyph — a box that is thrashing
/// says so in a word. Kept free of AppKit so the exact string is testable.
enum StatusTitle {
    struct Rendering: Equatable {
        var text: String
        /// One line per figure saying where it came from; the tooltip.
        var legend: [String]
    }

    static func render(sample: Sample, verdict: Verdict, interval: TimeInterval = 5) -> Rendering {
        var parts: [String] = []
        if let box = verdict.thrashing.first?.remote { parts.append("\(box.name) thrashing") }

        guard let headline = fastest(sample) else {
            parts.append("idle")
            return Rendering(text: join(parts),
                             legend: ["idle — nothing is loaded here or on a listed box"])
        }
        parts += fields(for: headline, sample: sample)
        var legend = legend(for: headline, sample: sample, interval: interval)
        if headline.activity != .generating {
            legend.insert("the model with the highest rate on record keeps the title", at: 0)
        }
        return Rendering(text: join(parts), legend: legend)
    }

    /// The model with the highest rate as the bar would show it — a box's total shared
    /// per request — generating or not; failing any rate, the largest local model.
    private static func fastest(_ sample: Sample) -> LoadedModel? {
        let generative = sample.models.filter { !$0.isEmbedding }
        if let best = generative.filter({ $0.tokensPerSecond != nil })
            .max(by: { shownRate($0) < shownRate($1) }) { return best }
        return generative.local.max { $0.sizeBytes < $1.sizeBytes } ?? generative.first
    }

    private static func shownRate(_ model: LoadedModel) -> Double {
        guard let rate = model.tokensPerSecond else { return 0 }
        return model.isRemote && model.inFlight > 1 ? rate / Double(model.inFlight) : rate
    }

    /// `vast.ai · qwen3.8-27b · bf16 · 36 tok/s ×2 · gpu 100%` for a box with two
    /// requests on it, where the rate is each request's share of the box's total;
    /// `local · Qwen3.8 27B · Q4_K_M · 25 tok/s · gpu 54%` for this Mac. A remote rate is
    /// vLLM's counters over the last sample interval, a box-wide total, so it is divided
    /// among the requests sharing it; a local one is the runtime's own figure for a
    /// single prediction it completed, already per request, so it is never divided.
    static func fields(for model: LoadedModel, sample: Sample) -> [String] {
        var parts = [provider(of: model), Format.shortName(model.displayName, limit: 18)]
        if let quantisation = model.quantisation { parts.append(quantisation) }
        if let rate = model.tokensPerSecond {
            parts.append(model.isRemote && model.inFlight > 1
                ? "\(Format.tokens(rate / Double(model.inFlight))) ×\(model.inFlight)"
                : Format.tokens(rate))
        }
        parts.append(gpu(of: model, sample: sample))
        return parts
    }

    static func provider(of model: LoadedModel) -> String { model.remote?.provider ?? "local" }

    private static func gpu(of model: LoadedModel, sample: Sample) -> String {
        guard let remote = model.remote else { return gpu(fraction: sample.gpuUtilisation) }
        return remote.gpuUtilisation.map(gpu(fraction:)) ?? "gpu —"
    }

    private static func gpu(fraction: Double) -> String { "gpu " + Format.percent(fraction) }

    private static func join(_ parts: [String]) -> String { parts.joined(separator: " · ") }

    private static func legend(for model: LoadedModel, sample: Sample,
                               interval: TimeInterval) -> [String] {
        var lines: [String] = []
        let seconds = Int(interval)
        let resident = Format.compactBytes(sample.models.totalBytes) + " of weights resident"
        if let remote = model.remote {
            lines.append("\(remote.name) on \(remote.provider)" + (remote.gpu.map { " (\($0))" } ?? "")
                + " — the model doing the most right now")
            if let rate = model.tokensPerSecond {
                lines.append(model.inFlight > 1
                    ? "\(Format.tokens(rate)) total across \(model.inFlight) requests, "
                        + "\(Format.tokens(rate / Double(model.inFlight))) each — vLLM's counters "
                        + "over the last \(seconds)s"
                    : "\(Format.tokens(rate)) — vLLM's counters over the last \(seconds)s")
            }
            lines.append("\(gpu(of: model, sample: sample)) — the box's card, from its sidecar")
            if !sample.models.local.isEmpty {
                lines.append("this mac: \(gpu(fraction: sample.gpuUtilisation)), \(resident)")
            }
        } else {
            lines.append((model.activity == .generating ? "generating now" : "finished just now")
                + " — \(model.displayName) on \(model.runtime), this Mac")
            lines.append(model.tokensPerSecond.map {
                "\(Format.tokens($0)) — decode rate the runtime reported for its last completed prediction"
            } ?? "no rate yet — reported when the first prediction completes")
            lines.append("\(gpu(fraction: sample.gpuUtilisation)) — this Mac's GPU, with \(resident)")
        }
        return lines
    }
}

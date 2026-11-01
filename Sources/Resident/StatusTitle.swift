import Foundation

enum StatusTitle {
    struct Rendering: Equatable {
        var text: String
        var legend: [String]
    }

    static func render(sample: Sample, verdict: Verdict, interval: TimeInterval = 1,
                       now: Double = Date().timeIntervalSince1970) -> Rendering {
        let age = max(now - sample.ts, 0)
        guard age <= max(3, interval * 3) else {
            return Rendering(text: "stale · updated \(Format.duration(age)) ago",
                             legend: ["Live readings unavailable; last sample \(sample.date.formatted())."])
        }
        var parts: [String] = []
        if let box = verdict.thrashing.first?.remote { parts.append("\(box.name) thrashing") }
        let localGPU = "gpu " + Format.percent(sample.gpuUtilisation)
        let freshness = "Updated \(sample.date.formatted(date: .omitted, time: .standard)) · every \(Format.duration(interval))"
        let runtimeActivity = Dictionary(grouping: sample.models.filter { ($0.runtimeInFlight ?? 0) > 0 }, by: \.runtime)
        guard let model = sample.working else {
            if let runtime = runtimeActivity.keys.sorted().first,
               let count = runtimeActivity[runtime]?.first?.runtimeInFlight {
                parts += [runtime, "\(count) in flight", localGPU]
                return Rendering(text: parts.joined(separator: " · "), legend: [freshness,
                    "\(runtime) is serving \(count) request(s). Its public API does not identify the active model.",
                    "Loaded there: " + (runtimeActivity[runtime]?.map(\.identifier).joined(separator: ", ") ?? ""),
                    "\(localGPU) — this Mac's whole GPU, including other apps"])
            }
            let unknown = sample.models.contains { $0.activity == .loaded && !$0.isEmbedding }
            parts += [unknown ? "activity unknown" : "idle", "\(sample.models.count) loaded", localGPU]
            return Rendering(text: parts.joined(separator: " · "), legend: [freshness,
                unknown ? "A loaded runtime does not report current activity."
                    : "No predictions in flight; loaded models still occupy memory.",
                "\(localGPU) — this Mac's whole GPU, including other apps"])
        }
        parts += fields(for: model, sample: sample)
        let busy = sample.models.filter { $0.activity == .generating }.count + runtimeActivity.count
        if busy > 1 { parts.append("+\(busy - 1) active") }
        var legend = [freshness, "\(model.displayName) on \(model.runtime) · \(model.activity.label) · \(model.inFlight) request(s) in flight"]
        if let rate = model.currentRate(at: sample.ts) {
            legend.append("\(Format.tokens(rate)) total over the current sampling interval")
        } else {
            legend.append("No live token rate from this runtime; past prediction speeds are in the model submenu.")
        }
        legend.append(model.isRemote ? "GPU reading is the remote card's sidecar measurement."
            : "\(localGPU) — this Mac's whole GPU, including other apps")
        return Rendering(text: parts.joined(separator: " · "), legend: legend)
    }

    static func fields(for model: LoadedModel, sample: Sample) -> [String] {
        var parts = [provider(of: model), Format.shortName(model.displayName, limit: 18)]
        if let quantisation = model.quantisation { parts.append(quantisation) }
        parts.append(model.activity.label)
        if let rate = model.currentRate(at: sample.ts) {
            parts.append(model.isRemote && model.inFlight > 1
                ? "\(Format.tokens(rate / Double(model.inFlight))) ×\(model.inFlight)"
                : Format.tokens(rate))
        }
        parts.append(model.remote.map { $0.gpuUtilisation.map { "gpu " + Format.percent($0) } ?? "gpu —" }
            ?? "gpu " + Format.percent(sample.gpuUtilisation))
        return parts
    }

    static func provider(of model: LoadedModel) -> String { model.remote?.provider ?? "local" }
}

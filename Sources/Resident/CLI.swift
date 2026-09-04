import Foundation

/// The same readings as the menu, over SSH or in a script.
enum CLI {
    static let usage = """
    resident — what your local models are doing to this machine

    USAGE
      resident                      run in the menu bar
      resident status [--detail]    one-shot report
      resident watch [seconds]      repeat the report until interrupted
      resident models [--json]      list resident models and their decode ceilings
      resident unload <id>          ask the owning runtime to release a model
      resident unload --idle        release every model that is not generating
      resident version

    --detail waits for the slow per-model activity that only `lms ps` reports. Without
    it, activity comes from the shared cache the menu bar app keeps warm.
    """

    static func status(detailed: Bool = false) {
        let sample = Sampler(detailed: detailed).take()
        print(render(sample))
    }

    /// Long-running like the menu bar, so it holds the LM Studio log stream open too
    /// and shows live throughput. Ctrl-C must take the child process with it.
    static func watch(interval: TimeInterval) {
        let sampler = Sampler(live: true)
        signal(SIGINT, SIG_IGN)
        // Not the main queue: the loop below never yields to it.
        let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
        interrupt.setEventHandler { sampler.stop(); exit(0) }
        interrupt.resume()

        while true {
            let sample = sampler.take()
            print("\u{1B}[2J\u{1B}[H", terminator: "")
            print(render(sample))
            Thread.sleep(forTimeInterval: interval)
        }
    }

    static func models(json: Bool, detailed: Bool = false) {
        let sample = Sampler(detailed: detailed).take()
        guard !json else { emit(sample.models); return }
        guard !sample.models.isEmpty else {
            print("No models resident.")
            return
        }
        print(modelTable(sample.models, peak: Hardware.current.peakBandwidth))
    }

    // MARK: - Rendering

    static func render(_ sample: Sample) -> String {
        let verdict = Verdict.evaluate(sample: sample)
        var lines: [String] = []

        lines.append("\(marker(verdict.level))  \(verdict.headline)")
        for line in verdict.summary { lines.append("        \(line)") }
        for warning in verdict.warnings { lines.append("        ⚠︎ \(warning)") }
        lines.append("")

        for gauge in sample.gauges {
            let level = gauge.level(.default)
            lines.append("\(marker(level, gauge: gauge))  \(Format.pad(gauge.label, 25))"
                + "\(bar(gauge.fraction))  \(Format.pad(Format.percent(gauge.fraction), 5, right: true))"
                + "   \(gauge.usedDescription) / \(gauge.limitDescription)")
            if let note = gauge.note { lines.append("        \(note)") }
        }

        if !sample.models.isEmpty {
            lines.append("")
            lines.append(modelTable(sample.models, peak: Hardware.current.peakBandwidth))
        }
        lines.append("")
        lines.append(Hardware.current.summary)
        return lines.joined(separator: "\n")
    }

    static func modelTable(_ models: [LoadedModel], peak: Double?) -> String {
        var lines = [Format.pad("MODEL", 34) + Format.pad("SIZE", 11, right: true) + "  "
            + Format.pad("QUANT", 8) + Format.pad("STATE", 12)
            + Format.pad("TOK/S", 9, right: true)
            + Format.pad("CEILING", 11, right: true) + "  CONTEXT"]

        for model in models {
            let ceiling = model.decodeCeiling(peakBandwidth: peak)
                .map { Format.tokens($0) } ?? "—"
            let measured = model.tokensPerSecond.map { Format.tokens($0) } ?? "—"
            let size = Format.bytes(model.sizeBytes) + (model.sizeIsApproximate ? "~" : "")
            let context = model.contextLength.map { Format.contextLength($0) } ?? "—"
            lines.append(Format.pad(model.displayName, 34)
                + Format.pad(size, 11, right: true) + "  "
                + Format.pad(model.quantisation ?? "—", 8)
                + Format.pad(model.activity.label, 12)
                + Format.pad(measured, 9, right: true)
                + Format.pad(ceiling, 11, right: true) + "  " + context)
        }

        if models.contains(where: { $0.decodeCeiling(peakBandwidth: peak) != nil }) {
            lines.append("")
            lines.append("TOK/S is the rate the runtime reported for the last prediction it "
                + "completed on that model.")
            lines.append("CEILING is decode speed if memory bandwidth were the only limit: "
                + "bus ÷ weight bytes.")
            lines.append("Real throughput lands below it. A mixture-of-experts model reads "
                + "only its active experts and beats it.")
        }
        return lines.joined(separator: "\n")
    }

    private static func emit(_ models: [LoadedModel]) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(models),
              let text = String(data: data, encoding: .utf8) else { return }
        print(text)
    }

    static func marker(_ level: Level, gauge: Gauge? = nil) -> String {
        if gauge?.informational == true { return "·" }
        switch level {
        case .ok: return "○"
        case .notice: return "◔"
        case .warn: return "◑"
        case .critical: return "●"
        }
    }

    private static func bar(_ fraction: Double, width: Int = 16) -> String {
        let filled = min(Int((fraction * Double(width)).rounded()), width)
        return String(repeating: "█", count: filled)
            + String(repeating: "░", count: width - filled)
    }
}

extension Format {
    /// Context windows are quoted in thousands of tokens everywhere else, so they are
    /// quoted that way here too.
    static func contextLength(_ tokens: Int) -> String {
        tokens >= 1000 ? "\(tokens / 1024)K" : "\(tokens)"
    }
}

import AppKit
import Foundation

/// Turns a sample into menu items. Separate from the controller so the layout can change
/// without touching sampling or actions.
enum MenuBuilder {
    private static let mono = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    private static let monoBold = NSFont.monospacedSystemFont(ofSize: 12, weight: .bold)
    private static let barWidth = 14

    /// The verdict, first and in plain language. Percentages go underneath.
    static func buildVerdict(into menu: NSMenu, verdict: Verdict) {
        let title = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        title.attributedTitle = NSAttributedString(
            string: "\(CLI.marker(verdict.level))  \(verdict.headline)",
            attributes: [
                .font: NSFont.systemFont(
                    ofSize: 13, weight: verdict.level >= .warn ? .bold : .semibold),
                .foregroundColor: colour(for: verdict.level),
            ]
        )
        title.isEnabled = false
        menu.addItem(title)

        // These lines are the whole point of the menu, so they are set in full label
        // colour rather than the faint style used for asides.
        for line in verdict.summary { menu.addItem(detail("        \(line)")) }
        for warning in verdict.warnings {
            menu.addItem(detail("        ⚠︎ \(warning)", weight: .medium))
        }
    }

    static func buildGauges(into menu: NSMenu, sample: Sample) {
        menu.addItem(header("Ceilings"))

        for gauge in sample.gauges {
            let level = gauge.level(.default)
            let line = "\(CLI.marker(level, gauge: gauge))  \(Format.pad(gauge.label, 24))"
                + "\(bar(gauge.fraction))  "
                + "\(Format.pad(Format.percent(gauge.fraction), 5, right: true))"
                + "   \(gauge.usedDescription) / \(gauge.limitDescription)"

            let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
            item.attributedTitle = NSAttributedString(
                string: line,
                attributes: [
                    .font: gauge.informational || level < .warn ? mono : monoBold,
                    .foregroundColor: colour(for: level, gauge: gauge),
                ]
            )
            item.isEnabled = false
            menu.addItem(item)

            if let note = gauge.note { menu.addItem(caption("        \(note)")) }
        }
    }

    /// Each model is a submenu, so releasing one is never a stray click — you have to
    /// open the row and choose it.
    static func buildModels(into menu: NSMenu, sample: Sample, target: AnyObject,
                            unload: Selector) {
        menu.addItem(header("Resident models"))
        let local = sample.models.local

        if local.isEmpty {
            let runtimes = sample.runtimesSeen.filter { $0 != "vllm" }
            menu.addItem(caption(runtimes.isEmpty
                ? "        no inference runtime is running"
                : "        \(runtimes.joined(separator: ", ")) running, nothing loaded"))
        }

        for model in local {
            let measured = model.tokensPerSecond.map { Format.tokens($0) } ?? ""
            let size = Format.bytes(model.sizeBytes) + (model.sizeIsApproximate ? "~" : "")
            let line = "\(activityMark(model))  \(Format.pad(size, 10, right: true))  "
                + "\(Format.pad(model.displayName, 26))\(Format.pad(model.quantisation ?? "", 9))"
                + "\(Format.pad(measured, 10, right: true))"

            let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
            item.attributedTitle = NSAttributedString(
                string: line,
                attributes: [.font: model.activity == .generating ? monoBold : mono])
            item.submenu = submenu(for: model, target: target, unload: unload)
            menu.addItem(item)
        }

        if !local.isEmpty {
            menu.addItem(caption("        ▶ generating · tok/s is the runtime's figure for its "
                + "last prediction"))
        }

        buildRemotes(into: menu, remotes: sample.models.remotes)
    }

    /// Boxes elsewhere, each on its own row: who owns it, what it is, and the readings
    /// vLLM and its sidecar report. Nothing here is a ceiling — that is this machine's
    /// bus, and a remote model is not on it.
    private static func buildRemotes(into menu: NSMenu, remotes: [LoadedModel]) {
        guard !remotes.isEmpty else { return }
        menu.addItem(header("Remote boxes"))
        for model in remotes {
            let info = model.remote!
            let where_ = [info.provider, info.gpu].compactMap { $0 }.joined(separator: " · ")
            let rate = model.tokensPerSecond.map { Format.tokens($0) } ?? ""
            let flight = model.inFlight > 0 || info.queued > 0
                ? "\(model.inFlight)" + (info.queued > 0 ? "+\(info.queued)" : "") + " req" : ""
            let each = model.inFlight > 1
                ? model.tokensPerSecond.map { Format.tokens($0 / Double(model.inFlight)) + " ea" } ?? "" : ""
            let kv = info.kvCacheUsage.map { "kv " + Format.percent($0) } ?? ""
            let busy = info.gpuUtilisation.map { "gpu " + Format.percent($0) } ?? ""
            let line = "\(activityMark(model))  ☁ \(Format.pad(where_, 22))"
                + "\(Format.pad(model.displayName, 20))\(Format.pad(model.quantisation ?? "", 6))"
                + "\(Format.pad(rate, 10, right: true))"
                + "\(Format.pad(flight, 9, right: true))\(Format.pad(each, 12, right: true))"
                + "\(Format.pad(kv, 8, right: true))\(Format.pad(busy, 9, right: true))"

            let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
            item.attributedTitle = NSAttributedString(
                string: line,
                attributes: [.font: model.activity == .generating ? monoBold : mono])
            item.submenu = remoteSubmenu(for: model)
            menu.addItem(item)
        }
        menu.addItem(caption("        ☁ served elsewhere · tok/s is the box's total, ea is each request's "
            + "share · req from vLLM's counters · kv is its cache fill · gpu is the sidecar reading"))
    }

    private static func remoteSubmenu(for model: LoadedModel) -> NSMenu {
        let info = model.remote!
        let submenu = NSMenu()
        submenu.addItem(caption("\(model.runtime) · \(model.identifier)"
            + (model.quantisation.map { " · \($0)" } ?? "")))
        submenu.addItem(caption("\(info.name) on \(info.provider)"
            + (info.gpu.map { " · \($0)" } ?? "") + " · \(info.host)"))
        if let rate = model.tokensPerSecond, let at = model.measuredAt {
            let ago = Format.duration(max(Date().timeIntervalSince1970 - at, 0))
            var line = "decode \(Format.tokens(rate)) · \(ago) ago"
            if let prefill = info.promptTokensPerSecond { line += " · prefill \(Format.tokens(prefill))" }
            submenu.addItem(caption(line))
        }
        var load = "\(model.inFlight) running · \(info.queued) queued"
        if model.inFlight > 1, let rate = model.tokensPerSecond {
            load += " · \(Format.tokens(rate / Double(model.inFlight))) each"
        }
        if let kv = info.kvCacheUsage { load += " · KV cache \(Format.percent(kv)) full" }
        submenu.addItem(caption(load))
        if let busy = info.gpuUtilisation {
            var gpu = "GPU \(Format.percent(busy)) busy"
            if let used = info.gpuMemoryUsed, let total = info.gpuMemoryTotal {
                gpu += " · \(Format.bytes(used)) of \(Format.bytes(total)) VRAM"
            }
            submenu.addItem(caption(gpu))
        }
        if let context = model.contextLength {
            submenu.addItem(caption("context \(Format.contextLength(context))"))
        }
        submenu.addItem(.separator())
        submenu.addItem(caption("stopped by whatever rented it, not from here"))
        return submenu
    }

    private static func submenu(for model: LoadedModel, target: AnyObject,
                                unload: Selector) -> NSMenu {
        let submenu = NSMenu()
        submenu.addItem(caption("\(model.runtime) · \(model.identifier)"))
        if let rate = model.tokensPerSecond, let at = model.measuredAt {
            let ago = Format.duration(max(Date().timeIntervalSince1970 - at, 0))
            let count = model.inFlight > 1 ? " · \(model.inFlight) in flight" : ""
            submenu.addItem(caption("last prediction \(Format.tokens(rate)) · \(ago) ago\(count)"))
            if let prompt = model.promptTokens, let first = model.timeToFirstToken {
                submenu.addItem(caption("its \(Format.contextLength(prompt)) prompt took "
                    + "\(Format.duration(first)) before the first token"))
            }
        }
        if let quantisation = model.quantisation {
            var detail = "\(quantisation)"
            if let parameters = model.parameters { detail = "\(parameters) · " + detail }
            if let architecture = model.architecture { detail += " · \(architecture)" }
            submenu.addItem(caption(detail))
        }
        if let context = model.contextLength {
            let maximum = model.maxContextLength.map { " of \(Format.contextLength($0))" } ?? ""
            submenu.addItem(caption("context \(Format.contextLength(context))\(maximum)"))
        }
        if let ttl = model.timeToLive {
            submenu.addItem(caption("unloads itself after \(Format.duration(ttl)) idle"))
        }
        if model.sizeIsApproximate {
            submenu.addItem(caption("size is process memory, not weight bytes"))
        }

        submenu.addItem(.separator())
        let item = NSMenuItem(title: "Release \(model.displayName)…", action: unload,
                              keyEquivalent: "")
        item.target = target
        item.representedObject = model
        submenu.addItem(item)
        return submenu
    }

    static func buildActions(into menu: NSMenu, verdict: Verdict, target: AnyObject,
                             release: Selector, copyReport: Selector, quit: Selector) {
        let title = verdict.reclaimable > 0
            ? "Release \(Format.bytes(verdict.reclaimable)) of Idle Models…"
            : "Nothing Idle to Release"
        let releaseItem = NSMenuItem(title: title, action: release, keyEquivalent: "")
        releaseItem.target = target
        releaseItem.isEnabled = verdict.reclaimable > 0
        menu.addItem(releaseItem)

        let report = NSMenuItem(title: "Copy Report", action: copyReport, keyEquivalent: "c")
        report.target = target
        menu.addItem(report)

        menu.addItem(.separator())
        menu.addItem(caption(Hardware.current.summary))
        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit Resident", action: quit, keyEquivalent: "q")
        quitItem.target = target
        menu.addItem(quitItem)
    }

    // MARK: - Pieces

    private static func activityMark(_ model: LoadedModel) -> String {
        switch model.activity {
        case .generating: return "▶"
        case .idle: return "·"
        case .loaded: return " "
        }
    }

    private static func bar(_ fraction: Double) -> String {
        let filled = min(Int((fraction * Double(barWidth)).rounded()), barWidth)
        return String(repeating: "█", count: filled)
            + String(repeating: "░", count: barWidth - filled)
    }

    /// Text colour, deliberately almost monochrome.
    ///
    /// System orange is unreadable against several of the backgrounds AppKit will put
    /// behind it, and severity conveyed by hue alone excludes anyone who cannot separate
    /// the hues. So warn is plain label text made bold, and only critical takes a colour
    /// — red, which is the one AppKit tunes for contrast in both appearances.
    private static func colour(for level: Level, gauge: Gauge? = nil) -> NSColor {
        if gauge?.informational == true { return .secondaryLabelColor }
        switch level {
        case .ok, .notice, .warn: return .labelColor
        case .critical: return .systemRed
        }
    }

    private static func header(_ text: String) -> NSMenuItem {
        let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        item.attributedTitle = NSAttributedString(
            string: text,
            attributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
                .foregroundColor: NSColor.secondaryLabelColor,
            ]
        )
        item.isEnabled = false
        return item
    }

    /// Findings: full contrast, because they are what you opened the menu to read.
    private static func detail(_ text: String,
                               weight: NSFont.Weight = .regular) -> NSMenuItem {
        let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        item.attributedTitle = NSAttributedString(
            string: text,
            attributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: weight),
                .foregroundColor: NSColor.labelColor,
            ]
        )
        item.isEnabled = false
        return item
    }

    /// Asides — notes on a gauge, model metadata, the hardware footer. Quieter than a
    /// finding, but never `tertiaryLabelColor`, which at this size is barely legible.
    private static func caption(_ text: String) -> NSMenuItem {
        let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        item.attributedTitle = NSAttributedString(
            string: text,
            attributes: [
                .font: NSFont.systemFont(ofSize: 11),
                .foregroundColor: NSColor.secondaryLabelColor,
            ]
        )
        item.isEnabled = false
        return item
    }
}

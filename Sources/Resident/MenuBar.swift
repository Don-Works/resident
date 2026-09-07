import AppKit
import Foundation
import UserNotifications

/// The menu bar presence: a status item carrying the two numbers worth glancing at, and
/// a menu that explains what the models are costing you.
final class MenuBarController: NSObject {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private let sampler = Sampler(live: true)
    private let queue = DispatchQueue(label: "co.revitt.resident.sampler", qos: .utility)
    private var timer: Timer?
    private var sample: Sample?
    private var verdict = Verdict()
    private var sampling = false
    /// Boxes already alerted about, so an episode fires one notification, not one per sample.
    var alertedThrash: Set<String> = []

    var interval: TimeInterval = 5

    func stop() {
        timer?.invalidate()
        sampler.stop()
    }

    func start() {
        statusItem.menu = menu
        menu.delegate = self
        statusItem.button?.imagePosition = .imageLeading
        // Remembers where you drag it, so it stays put across restarts.
        statusItem.autosaveName = "co.revitt.resident.status"
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        refresh()

        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// Sampling talks to model runtimes over HTTP, so it never runs on the main thread.
    private func refresh(then completion: (() -> Void)? = nil) {
        guard !sampling else { completion?(); return }
        sampling = true
        queue.async { [weak self] in
            guard let self else { return }
            let sample = self.sampler.take()
            let verdict = Verdict.evaluate(sample: sample)
            DispatchQueue.main.async {
                self.sampling = false
                self.sample = sample
                self.verdict = verdict
                self.updateStatusItem(sample: sample, verdict: verdict)
                self.alertIfThrashing(verdict)
                // Rebuilding under an open highlighted item would move it out from
                // under the pointer mid-click.
                if self.menu.highlightedItem == nil {
                    self.rebuildMenu(sample: sample, verdict: verdict)
                }
                completion?()
            }
        }
    }

    // MARK: - Status item

    /// The headline names its source. A local model reads `▶ Qwen3.8 27B 14 tok/s · mac gpu 54%`;
    /// a rented box reads `▶ ☁ vast.ai qwen3.8-27b 39 tok/s ×2 · gpu 100%`, where the rate is
    /// what each request is getting and the gpu figure is the box's card, never this Mac's.
    /// Whichever is producing the most tokens takes the headline; idle, both sources are
    /// listed with their own label so a number is never read against the wrong machine.
    ///
    /// Nothing here is coloured, with one exception: a box thrashing its cache draws a
    /// dark red filled triangle and says "thrashing" in words, so the colour is never the
    /// only carrier. The menu bar sits over whatever wallpaper you have and switches its
    /// own text between black and white to stay legible; a status item that paints its
    /// own orange opts out of that and becomes unreadable on a light bar. Severity is
    /// otherwise carried by the icon's shape and the text weight.
    private func updateStatusItem(sample: Sample, verdict: Verdict) {
        guard let button = statusItem.button else { return }
        button.image = Self.icon(for: verdict.level, thrashing: !verdict.thrashing.isEmpty)
        button.imagePosition = .imageLeading

        let local = sample.models.local
        let mac = "mac " + (local.isEmpty ? "" : Format.compactBytes(local.totalBytes) + " ")
            + "gpu " + Format.percent(sample.gpuUtilisation)
        var parts: [String] = []
        var legend: [String] = []

        if let box = verdict.thrashing.first?.remote {
            parts.append("⚠︎ \(box.name) thrashing")
        }

        if let working = sample.working {
            parts.append(Self.workingTitle(working))
            if let remote = working.remote {
                let gpu = remote.gpuUtilisation.map { "gpu " + Format.percent($0) } ?? "gpu —"
                parts.append(gpu)
                legend.append("☁ \(remote.name) on \(remote.provider)"
                    + (remote.gpu.map { " (\($0))" } ?? "") + " — the model doing the most right now")
                if let rate = working.tokensPerSecond {
                    legend.append(working.inFlight > 1
                        ? "\(Format.tokens(rate)) total across \(working.inFlight) requests, "
                            + "\(Format.tokens(rate / Double(working.inFlight))) each — vLLM's counters "
                            + "over the last \(Int(interval))s"
                        : "\(Format.tokens(rate)) — vLLM's counters over the last \(Int(interval))s")
                }
                legend.append("\(gpu) — the box's card, from its sidecar")
                if !local.isEmpty { legend.append("this mac: \(mac)") }
            } else {
                parts.append(mac)
                legend.append((working.activity == .generating ? "▶ generating now" : "finished just now")
                    + " — \(working.displayName) on \(working.runtime), this Mac")
                legend.append(working.tokensPerSecond.map {
                    "\(Format.tokens($0)) — decode rate the runtime reported for its last completed prediction"
                } ?? "no rate yet — reported when the first prediction completes")
                legend.append("\(mac) — weights resident and GPU utilisation on this Mac")
            }
        } else if sample.models.isEmpty {
            parts.append("idle")
        } else {
            if !local.isEmpty { parts.append(mac) }
            for model in sample.models.remotes {
                let info = model.remote!
                parts.append("☁ \(info.provider) " + (info.gpuUtilisation.map { "gpu " + Format.percent($0) } ?? "idle"))
            }
            legend.append("idle — each figure is labelled with its machine")
        }

        button.attributedTitle = NSAttributedString(
            string: " " + parts.joined(separator: " · "),
            attributes: [
                .font: NSFont.monospacedDigitSystemFont(
                    ofSize: 11, weight: verdict.level >= .warn ? .bold : .regular),
                .foregroundColor: NSColor.labelColor,
            ]
        )
        button.toolTip = (legend + [""] + [verdict.headline] + verdict.summary + verdict.warnings)
            .joined(separator: "\n")
    }

    /// `▶ ☁ vast.ai qwen3.8-27b 39 tok/s ×2` for a box with two requests on it, where the
    /// rate is each request's share of the box's total; `▶ Qwen3.8 27B 16 tok/s` locally.
    /// A remote rate is vLLM's counters over the last sample interval; a local one is the
    /// runtime's own figure for its last completed prediction, so it lags the generation.
    private static func workingTitle(_ model: LoadedModel) -> String {
        var parts: [String] = []
        if model.activity == .generating { parts.append("▶") }
        if let remote = model.remote { parts.append("☁ \(remote.provider)") }
        parts.append(Format.shortName(model.displayName, limit: 18))
        if let rate = model.tokensPerSecond {
            if model.inFlight > 1 {
                parts.append("\(Format.tokens(rate / Double(model.inFlight))) ×\(model.inFlight)")
            } else {
                parts.append(Format.tokens(rate))
            }
        }
        return parts.joined(separator: " ")
    }

    /// Four distinct silhouettes, so the level is legible in one glance without colour
    /// and without reading the number. Thrash is the one coloured case: a filled triangle
    /// in dark red, with "thrashing" spelled out beside it.
    private static func icon(for level: Level, thrashing: Bool) -> NSImage? {
        if thrashing {
            let image = NSImage(systemSymbolName: "exclamationmark.triangle.fill",
                                accessibilityDescription: "Resident — a box is thrashing its cache")
            let config = NSImage.SymbolConfiguration(paletteColors: [NSColor(red: 0.62, green: 0.05, blue: 0.05, alpha: 1)])
            let tinted = image?.withSymbolConfiguration(config)
            tinted?.isTemplate = false
            return tinted
        }
        let name: String
        let description: String
        switch level {
        case .ok:
            name = "memorychip"; description = "Resident — plenty of room"
        case .notice:
            name = "memorychip.fill"; description = "Resident — filling up"
        case .warn:
            name = "exclamationmark.triangle"; description = "Resident — under pressure"
        case .critical:
            name = "exclamationmark.octagon.fill"; description = "Resident — out of room"
        }
        let image = NSImage(systemSymbolName: name, accessibilityDescription: description)
            ?? NSImage(systemSymbolName: "memorychip", accessibilityDescription: description)
        // Template images are tinted by the system to match the menu bar it is drawn on.
        image?.isTemplate = true
        return image
    }

    // MARK: - Menu

    private func rebuildMenu(sample: Sample, verdict: Verdict) {
        menu.removeAllItems()
        MenuBuilder.buildVerdict(into: menu, verdict: verdict)
        menu.addItem(.separator())
        MenuBuilder.buildGauges(into: menu, sample: sample)
        menu.addItem(.separator())
        MenuBuilder.buildModels(into: menu, sample: sample, target: self,
                                unload: #selector(unloadModel(_:)))
        menu.addItem(.separator())
        MenuBuilder.buildActions(into: menu, verdict: verdict, target: self,
                                 release: #selector(releaseIdle),
                                 copyReport: #selector(copyReport),
                                 quit: #selector(quit))
    }

    // MARK: - Actions

    @objc private func unloadModel(_ item: NSMenuItem) {
        guard let model = item.representedObject as? LoadedModel else { return }
        confirm(
            title: "Release \(model.displayName)?",
            body: "\(model.runtime) will free about \(Format.bytes(model.sizeBytes)). "
                + "It reloads on the next request, which takes as long as loading it did."
        ) { [weak self] in
            self?.perform(models: [model])
        }
    }

    @objc private func releaseIdle() {
        let candidates = verdict.reclaimCandidates
        guard !candidates.isEmpty else { return }
        let list = candidates
            .map { "• \($0.displayName) — \(Format.bytes($0.sizeBytes))" }
            .joined(separator: "\n")

        confirm(
            title: "Release \(candidates.count) idle model(s)?",
            body: "This frees about \(Format.bytes(candidates.totalBytes)). Each reloads "
                + "on its next request.\n\n\(list)"
        ) { [weak self] in
            self?.perform(models: candidates)
        }
    }

    private func perform(models: [LoadedModel]) {
        queue.async { [weak self] in
            guard let self else { return }
            let failures = self.sampler.unload(models)
            DispatchQueue.main.async {
                self.refresh()
                guard !failures.isEmpty else { return }
                let alert = NSAlert()
                alert.messageText = "Some models were not released"
                alert.informativeText = failures.joined(separator: "\n")
                alert.alertStyle = .warning
                NSApp.activate(ignoringOtherApps: true)
                alert.runModal()
            }
        }
    }

    @objc private func copyReport() {
        guard let sample else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(CLI.render(sample), forType: .string)
    }

    @objc private func quit() { NSApp.terminate(nil) }

    private func confirm(title: String, body: String, action: @escaping () -> Void) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = body
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Release")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        action()
    }
}

extension MenuBarController: NSMenuDelegate {
    /// Show the last sample immediately so the menu is never blank, then refresh into it.
    func menuWillOpen(_ menu: NSMenu) {
        if let sample { rebuildMenu(sample: sample, verdict: verdict) }
        refresh()
    }
}

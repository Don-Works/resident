import AppKit
import Foundation

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

    /// While a model is working, its name and the decode rate its runtime reported;
    /// otherwise how much memory the models are holding and whether the GPU is busy.
    /// A glyph alone in a crowded menu bar tells you nothing, and an unlabelled
    /// percentage next to a byte count reads as a percentage of it — so the GPU figure
    /// carries its own label.
    ///
    /// Nothing here is coloured. The menu bar sits over whatever wallpaper you have and
    /// switches its own text between black and white to stay legible; a status item that
    /// paints its own orange opts out of that and becomes unreadable on a light bar.
    /// Severity is carried by the icon's shape and the text weight instead, which also
    /// means it survives being read by someone who cannot separate orange from grey.
    private func updateStatusItem(sample: Sample, verdict: Verdict) {
        guard let button = statusItem.button else { return }
        button.image = Self.icon(for: verdict.level)
        // Template images are tinted by the system to match the menu bar it is drawn on.
        button.image?.isTemplate = true
        button.imagePosition = .imageLeading

        let memory = "\(Format.compactBytes(sample.models.totalBytes))"
            + "  gpu \(Format.percent(sample.gpuUtilisation))"
        let title: String
        var legend: [String] = []
        if let working = sample.working {
            title = " \(Self.workingTitle(working))  \(memory)"
            legend = [
                (working.activity == .generating ? "▶ generating now" : "finished just now")
                    + " — \(working.displayName) on \(working.runtime)",
                working.tokensPerSecond.map {
                    "\(Format.tokens($0)) — decode rate the runtime reported for its "
                        + "last completed prediction"
                } ?? "no rate yet — reported when the first prediction completes",
            ]
        } else if sample.models.isEmpty {
            title = " idle"
        } else {
            title = " " + memory
        }
        if !sample.models.isEmpty {
            legend += [
                "\(Format.compactBytes(sample.models.totalBytes)) — model weights resident",
                "gpu \(Format.percent(sample.gpuUtilisation)) — GPU device utilisation",
                "",
            ]
        }

        button.attributedTitle = NSAttributedString(
            string: title,
            attributes: [
                .font: NSFont.monospacedDigitSystemFont(
                    ofSize: 11, weight: verdict.level >= .warn ? .bold : .regular),
                .foregroundColor: NSColor.labelColor,
            ]
        )
        button.toolTip = (legend + [verdict.headline] + verdict.summary + verdict.warnings)
            .joined(separator: "\n")
    }

    /// `▶ Qwen3.8 27B 16 tok/s` while a prediction is running; the same without the
    /// mark for a short hold after it finishes. The rate is the runtime's own figure
    /// for the last completed prediction, so it lags the generation it describes.
    private static func workingTitle(_ model: LoadedModel) -> String {
        var parts = [Format.shortName(model.displayName, limit: 18)]
        if model.activity == .generating { parts.insert("▶", at: 0) }
        if let rate = model.tokensPerSecond { parts.append(Format.tokens(rate)) }
        return parts.joined(separator: " ")
    }

    /// Four distinct silhouettes, so the level is legible in one glance without colour
    /// and without reading the number.
    private static func icon(for level: Level) -> NSImage? {
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
        return NSImage(systemSymbolName: name, accessibilityDescription: description)
            ?? NSImage(systemSymbolName: "memorychip", accessibilityDescription: description)
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

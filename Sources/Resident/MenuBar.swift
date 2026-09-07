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

    /// The title is five fields in a fixed order — provider, model, quant, tok/s, gpu —
    /// composed by `StatusTitle` so the exact text can be checked without AppKit. A
    /// remote's gpu figure is the box's card, never this Mac's; the tooltip says where
    /// every number came from.
    ///
    /// The icon appears only when there is something to act on: a triangle from warn
    /// upwards, an octagon at critical, and a dark red filled triangle for a box
    /// thrashing its cache, with "thrashing" spelled out beside it so the colour is
    /// never the only carrier. Plenty of room draws no icon at all. Nothing else is
    /// coloured: the menu bar sits over whatever wallpaper you have and switches its own
    /// text between black and white to stay legible; a status item that paints its own
    /// orange opts out of that and becomes unreadable on a light bar. Severity is
    /// otherwise carried by the text weight.
    private func updateStatusItem(sample: Sample, verdict: Verdict) {
        guard let button = statusItem.button else { return }
        let icon = Self.icon(for: verdict.level, thrashing: !verdict.thrashing.isEmpty)
        button.image = icon
        button.imagePosition = .imageLeading

        let rendering = StatusTitle.render(sample: sample, verdict: verdict, interval: interval)
        button.attributedTitle = NSAttributedString(
            string: (icon == nil ? "" : " ") + rendering.text,
            attributes: [
                .font: NSFont.monospacedDigitSystemFont(
                    ofSize: 11, weight: verdict.level >= .warn ? .bold : .regular),
                .foregroundColor: NSColor.labelColor,
            ]
        )
        button.toolTip = (rendering.legend + [""] + [verdict.headline] + verdict.summary + verdict.warnings)
            .joined(separator: "\n")
    }

    /// Two silhouettes and one coloured case, shown only when the level asks for
    /// attention; at ok and notice the bar carries the title alone. Thrash is the one
    /// coloured case: a filled triangle in dark red, with "thrashing" spelled out beside it.
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
        case .ok, .notice:
            return nil
        case .warn:
            name = "exclamationmark.triangle"; description = "Resident — under pressure"
        case .critical:
            name = "exclamationmark.octagon.fill"; description = "Resident — out of room"
        }
        let image = NSImage(systemSymbolName: name, accessibilityDescription: description)
            ?? NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: description)
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

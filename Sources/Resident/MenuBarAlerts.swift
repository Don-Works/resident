import AppKit
import Foundation
import UserNotifications

/// The one thing Resident interrupts you for: a box evicting live requests because the
/// contexts in flight exceed its cache. Everything else stays in the menu.
extension MenuBarController {
    /// One notification per thrash episode per box. Cleared when the box stops, so the
    /// next episode alerts again.
    func alertIfThrashing(_ verdict: Verdict) {
        let now = Set(verdict.thrashing.compactMap { $0.remote?.name })
        for name in now.subtracting(alertedThrash) {
            guard let model = verdict.thrashing.first(where: { $0.remote?.name == name }),
                  let info = model.remote else { continue }
            let content = UNMutableNotificationContent()
            content.title = "\(info.name) is thrashing"
            content.body = "\(info.waitingForCapacity) request(s) waiting for cache, KV "
                + "\(Format.percent(info.kvCacheUsage ?? 0)) full, \(info.preemptions ?? 0) preemptions. "
                + "Contexts exceed the box's cache — compact or close sessions, or switch lane."
            content.sound = .defaultCritical
            content.interruptionLevel = .timeSensitive
            let request = UNNotificationRequest(identifier: "resident.thrash.\(name)", content: content, trigger: nil)
            UNUserNotificationCenter.current().add(request)
        }
        alertedThrash = now
    }

}

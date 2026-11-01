import AppKit

extension MenuBuilder {
    /// Update readings without moving a highlighted action under the pointer.
    static func updateVisible(_ menu: NSMenu, from next: NSMenu) {
        for item in menu.items {
            guard let id = item.identifier else { continue }
            guard let fresh = next.items.first(where: { $0.identifier == id }) else {
                item.attributedTitle = NSAttributedString(string: "No longer present — reopen for updated list")
                item.submenu = nil
                item.isEnabled = false
                continue
            }
            item.title = fresh.title
            item.attributedTitle = fresh.attributedTitle
            item.toolTip = fresh.toolTip
            if let old = item.submenu, let new = fresh.submenu {
                // Submenu rows have fixed metadata order until load configuration changes.
                if old.items.count == new.items.count {
                    for (oldRow, newRow) in zip(old.items, new.items) where oldRow.action == nil {
                        oldRow.title = newRow.title
                        oldRow.attributedTitle = newRow.attributedTitle
                    }
                }
            }
        }
    }

}

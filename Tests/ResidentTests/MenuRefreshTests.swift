import AppKit
import XCTest
@testable import Resident

final class MenuRefreshTests: XCTestCase {
    func testHighlightedRowsUpdateWithoutReplacingTheMenuItemOrAction() {
        let menu = NSMenu()
        let row = NSMenuItem(title: "old", action: nil, keyEquivalent: "")
        row.identifier = NSUserInterfaceItemIdentifier("model-x")
        let submenu = NSMenu()
        let release = NSMenuItem(title: "Release x", action: NSSelectorFromString("release:"), keyEquivalent: "")
        submenu.addItem(release)
        row.submenu = submenu
        menu.addItem(row)
        let next = NSMenu()
        let updated = NSMenuItem(title: "generating now", action: nil, keyEquivalent: "")
        updated.identifier = row.identifier
        next.addItem(updated)
        MenuBuilder.updateVisible(menu, from: next)
        XCTAssertTrue(menu.items[0] === row)
        XCTAssertEqual(row.title, "generating now")
        XCTAssertTrue(row.submenu?.items[0] === release)
    }

    func testUnloadedModelCannotLeaveAWorkingReleaseActionOnScreen() {
        let menu = NSMenu()
        let row = NSMenuItem(title: "loaded", action: nil, keyEquivalent: "")
        row.identifier = NSUserInterfaceItemIdentifier("model-gone")
        row.submenu = NSMenu()
        menu.addItem(row)
        MenuBuilder.updateVisible(menu, from: NSMenu())
        XCTAssertNil(row.submenu)
        XCTAssertFalse(row.isEnabled)
        XCTAssertTrue(row.attributedTitle?.string.contains("No longer present") == true)
    }
}

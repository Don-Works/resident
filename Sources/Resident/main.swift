import AppKit
import Foundation

/// Entry point. With no arguments Resident runs in the menu bar; every other mode is a
/// plain CLI command, so the same binary is useful over SSH and inside the LaunchDaemon.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let controller = MenuBarController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        controller.start()
    }

    /// The LM Studio log stream is a child process; it must not outlive the menu bar.
    func applicationWillTerminate(_ notification: Notification) {
        controller.stop()
    }
}

let arguments = Array(CommandLine.arguments.dropFirst())

switch arguments.first {
case "status":
    CLI.status(detailed: arguments.contains("--detail"))

case "watch":
    CLI.watch(interval: arguments.count > 1 ? (TimeInterval(arguments[1]) ?? 2) : 2)

case "models":
    CLI.models(json: arguments.contains("--json"),
               detailed: arguments.contains("--detail"))

case "unload":
    let positional = arguments.dropFirst().first { !$0.hasPrefix("--") }
    CLI.unload(identifier: positional, idleOnly: arguments.contains("--idle"))

case "version", "--version", "-v":
    print(Build.summary)

case "help", "-h", "--help":
    print(CLI.usage)

case .none, "menubar":
    let delegate = AppDelegate()
    let application = NSApplication.shared
    application.delegate = delegate
    // Menu bar only — no Dock icon, no application menu.
    application.setActivationPolicy(.accessory)
    application.run()

default:
    FileHandle.standardError.write(Data("Unknown command: \(arguments[0])\n\n".utf8))
    print(CLI.usage)
    exit(1)
}

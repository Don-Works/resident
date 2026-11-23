import Foundation

/// Ports served by processes matching a predicate, rescanned at most every `interval`.
/// The scan reads every process's arguments; servers start rarely, so a new one may take
/// up to `interval` to appear while known ports are still probed every sample.
/// Only the sampling queue touches this.
final class ServingPorts {
    private let matches: ([String]) -> Bool
    private let interval: TimeInterval
    private var last: (ports: [Int], at: Date)?

    init(interval: TimeInterval = 10, matching matches: @escaping ([String]) -> Bool) {
        self.interval = interval
        self.matches = matches
    }

    func current(now: Date = Date()) -> [Int] {
        if let last, now.timeIntervalSince(last.at) < interval { return last.ports }
        let ports = ProcessList.servingPorts(where: matches)
        last = (ports, now)
        return ports
    }
}

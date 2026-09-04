import Foundation

/// Severity of a single gauge, and of a sample overall.
enum Level: Int, Codable, Comparable, Sendable {
    case ok = 0
    case notice = 1
    case warn = 2
    case critical = 3

    static func < (lhs: Level, rhs: Level) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// A single ceiling: how much is in use, and how much there is.
struct Gauge: Codable, Sendable {
    enum Unit: String, Codable, Sendable { case bytes, rate, ratio }

    var key: String
    var label: String
    var used: Double
    var limit: Double
    var unit: Unit
    /// Displayed but never raises the overall level.
    var informational: Bool = false
    /// Explains a reading that looks alarming but is not, or names what is missing.
    var note: String?

    var fraction: Double {
        guard limit > 0 else { return 0 }
        return min(used / limit, 1.0)
    }

    func level(_ thresholds: Thresholds) -> Level {
        if informational { return .ok }
        let f = fraction
        if f >= thresholds.critical { return .critical }
        if f >= thresholds.warn { return .warn }
        if f >= thresholds.notice { return .notice }
        return .ok
    }

    var usedDescription: String {
        switch unit {
        case .bytes: return Format.bytes(Int(used))
        case .rate: return Format.rate(used)
        case .ratio: return Format.percent(used)
        }
    }

    var limitDescription: String {
        switch unit {
        case .bytes: return Format.bytes(Int(limit))
        case .rate: return Format.rate(limit)
        case .ratio: return Format.percent(limit)
        }
    }
}

struct Thresholds: Codable, Sendable {
    var notice: Double = 0.55
    var warn: Double = 0.75
    var critical: Double = 0.90

    /// Swap being *written* while models are resident, in bytes per second. The level
    /// of swap is not a fault; the rate is.
    var swapoutWarn: Double = 8 * 1024 * 1024
    var swapoutCritical: Double = 64 * 1024 * 1024

    /// A model doing nothing for this long is holding memory for no reason.
    var idleReclaim: TimeInterval = 20 * 60

    static let `default` = Thresholds()
}

/// One point-in-time reading of everything Resident watches.
struct Sample: Codable, Sendable {
    var ts: Double
    var gauges: [Gauge]
    var models: [LoadedModel]
    var memory: MemorySnapshot
    var gpuUtilisation: Double
    var gpuResidentBytes: Int
    var pressure: Int
    var runtimesSeen: [String]

    var date: Date { Date(timeIntervalSince1970: ts) }
    var memoryPressure: MemoryPressure? { MemoryPressure(rawValue: pressure) }

    func gauge(_ key: String) -> Gauge? { gauges.first { $0.key == key } }

    func level(_ thresholds: Thresholds = .default) -> Level {
        gauges.map { $0.level(thresholds) }.max() ?? .ok
    }

    /// A finished measurement stays "current" for this long. An agent loop issues a
    /// request every few seconds; without a hold the menu bar would flip between the
    /// model's name and the memory figure on every sample.
    static let workingHold: TimeInterval = 30

    /// The model doing the work: one with a prediction in flight, else the one whose
    /// last prediction finished within the hold.
    var working: LoadedModel? {
        if let busy = models.first(where: { $0.activity == .generating }) { return busy }
        return models
            .filter { model in model.measuredAt.map { ts - $0 <= Self.workingHold } ?? false }
            .max { ($0.measuredAt ?? 0) < ($1.measuredAt ?? 0) }
    }

    /// Codable mirror of `MemoryStats.Snapshot`, so a sample can be written to disk.
    struct MemorySnapshot: Codable, Sendable {
        var total: Int
        var available: Int
        var wired: Int
        var compressed: Int
        var swapUsed: Int
        var swapTotal: Int
        /// Bytes per second currently being written to swap, or nil before two readings
        /// exist to compare. This, not `swapUsed`, is what says the machine is paging.
        var swapoutRate: Double?

        var used: Int { max(total - available, 0) }

        /// Swap that is present but not growing — residue from earlier pressure that
        /// macOS has not reclaimed. Costs disk, not throughput.
        var swapIsResidual: Bool { swapUsed > 0 && (swapoutRate ?? 0) < 1024 * 1024 }
    }
}

enum Format {
    static func bytes(_ value: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(value), countStyle: .memory)
    }

    /// Compact bytes for the menu bar, where every character competes for space.
    static func compactBytes(_ value: Int) -> String {
        let gigabytes = Double(value) / 1_073_741_824
        if gigabytes >= 99.5 { return String(format: "%.0fG", gigabytes) }
        if gigabytes >= 9.95 { return String(format: "%.0fG", gigabytes) }
        if gigabytes >= 1 { return String(format: "%.1fG", gigabytes) }
        return String(format: "%.0fM", Double(value) / 1_048_576)
    }

    /// Swap-out rates are tens of megabytes a second; in GB/s they would round to 0.
    static func rate(_ bytesPerSecond: Double) -> String {
        bytesPerSecond >= 1e9
            ? String(format: "%.0f GB/s", bytesPerSecond / 1e9)
            : String(format: "%.0f MB/s", bytesPerSecond / 1e6)
    }

    static func percent(_ fraction: Double) -> String {
        String(format: "%.0f%%", fraction * 100)
    }

    static func tokens(_ perSecond: Double) -> String {
        perSecond >= 10
            ? String(format: "%.0f tok/s", perSecond)
            : String(format: "%.1f tok/s", perSecond)
    }

    /// A model name cut to fit the menu bar, where a long identifier would push every
    /// other status item off the edge.
    static func shortName(_ name: String, limit: Int = 22) -> String {
        name.count <= limit ? name : String(name.prefix(limit - 1)).trimmingCharacters(in: .whitespaces) + "…"
    }

    static func duration(_ seconds: TimeInterval) -> String {
        if seconds < 90 { return String(format: "%.0fs", seconds) }
        if seconds < 5400 { return String(format: "%.0fm", seconds / 60) }
        return String(format: "%.1fh", seconds / 3600)
    }

    /// Pads or truncates to an exact width. `String(format:)` width specifiers are
    /// unreliable with `%@`, and every table here needs columns that line up.
    static func pad(_ text: String, _ width: Int, right: Bool = false) -> String {
        if text.count >= width {
            return String(text.prefix(max(width - 1, 1))) + " "
        }
        let filler = String(repeating: " ", count: width - text.count)
        return right ? filler + text : text + filler
    }
}

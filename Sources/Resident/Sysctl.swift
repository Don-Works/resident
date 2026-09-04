import Darwin
import Foundation

/// Thin wrappers over `sysctl(3)`. Every read here is a cheap in-kernel lookup — no
/// process sweep, no shelling out, nothing that can block while a model is generating.
enum Sysctl {
    static func int(_ name: String) -> Int? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }

        if size <= MemoryLayout<Int32>.size {
            var value: Int32 = 0
            var len = MemoryLayout<Int32>.size
            guard sysctlbyname(name, &value, &len, nil, 0) == 0 else { return nil }
            return Int(value)
        }

        var value: Int64 = 0
        var len = MemoryLayout<Int64>.size
        guard sysctlbyname(name, &value, &len, nil, 0) == 0 else { return nil }
        return Int(value)
    }

    static func string(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }

    /// Swap usage in bytes, straight from `vm.swapusage`.
    static func swapUsage() -> (total: Int, used: Int)? {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0 else { return nil }
        return (Int(usage.xsu_total), Int(usage.xsu_used))
    }

    static func uptime() -> TimeInterval? {
        var boot = timeval()
        var size = MemoryLayout<timeval>.size
        guard sysctlbyname("kern.boottime", &boot, &size, nil, 0) == 0 else { return nil }
        let bootDate = Double(boot.tv_sec) + Double(boot.tv_usec) / 1_000_000
        return Date().timeIntervalSince1970 - bootDate
    }
}

/// The kernel's own verdict on memory, which is not the same thing as "percent used".
/// macOS is happy at 90% used and unhappy at 60% if the 60% cannot be reclaimed.
enum MemoryPressure: Int {
    case normal = 1
    case warning = 2
    case critical = 4

    static func read() -> MemoryPressure? {
        guard let raw = Sysctl.int("kern.memorystatus_vm_pressure_level") else { return nil }
        return MemoryPressure(rawValue: raw)
    }

    var label: String {
        switch self {
        case .normal: return "normal"
        case .warning: return "warning"
        case .critical: return "critical"
        }
    }
}

/// Physical memory statistics via `host_statistics64`.
enum MemoryStats {
    struct Snapshot {
        var totalBytes: Int
        /// Reclaimable without swapping: free + inactive + purgeable.
        var availableBytes: Int
        var wiredBytes: Int
        var compressedBytes: Int
        var appBytes: Int
        /// Cumulative pages written to swap since boot. The level of swap says nothing
        /// on its own — macOS never shrinks it eagerly, so it stays high long after the
        /// pressure that caused it is gone. This counter climbing is what says pages are
        /// going to disk *now*.
        var swapouts: UInt64
        var pageSize: Int

        var usedBytes: Int { max(totalBytes - availableBytes, 0) }
        var usedFraction: Double {
            guard totalBytes > 0 else { return 0 }
            return Double(usedBytes) / Double(totalBytes)
        }
    }

    static func read() -> Snapshot? {
        var stats = vm_statistics64()
        var count = UInt32(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                host_statistics64(mach_host_self(), HOST_VM_INFO64, rebound, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }

        let page = Int(vm_kernel_page_size)
        let total = Sysctl.int("hw.memsize") ?? 0
        let available = (Int(stats.free_count) + Int(stats.inactive_count)
            + Int(stats.purgeable_count)) * page
        let wired = Int(stats.wire_count) * page
        let compressed = Int(stats.compressor_page_count) * page
        let app = Int(stats.internal_page_count - stats.purgeable_count) * page

        return Snapshot(
            totalBytes: total,
            availableBytes: min(available, total),
            wiredBytes: wired,
            compressedBytes: compressed,
            appBytes: max(app, 0),
            swapouts: stats.swapouts,
            pageSize: page
        )
    }
}

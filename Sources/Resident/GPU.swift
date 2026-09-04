import Foundation
import IOKit

/// GPU utilisation and resident GPU memory, read from the accelerator's own
/// `PerformanceStatistics` dictionary in the IO registry. This needs no privileges,
/// unlike `powermetrics`, and costs about a millisecond.
enum GPU {
    struct Snapshot {
        /// Fraction of the time the device was busy since the driver last sampled.
        var deviceUtilisation: Double
        var rendererUtilisation: Double
        /// Bytes the GPU driver currently has allocated. On a unified-memory Mac this
        /// is where model weights and the KV cache live, so it is the figure that tracks
        /// loaded models. It drifts down as buffers are released; it is not a high-water
        /// mark.
        var allocatedMemory: Int
        /// Bytes mapped for work at the instant of sampling. This collapses to a
        /// gigabyte or two between requests and climbs towards `allocatedMemory` during
        /// generation, so it measures activity, not residency.
        var inUseMemory: Int
        /// The driver reset the GPU. During inference this means a hung kernel.
        var recoveryCount: Int
    }

    static func read() -> Snapshot? {
        let matching = IOServiceMatching("AGXAccelerator")
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS
        else { return nil }
        defer { IOObjectRelease(iterator) }

        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            guard let stats = statistics(of: service) else { continue }
            return Snapshot(
                deviceUtilisation: percent(stats["Device Utilization %"]),
                rendererUtilisation: percent(stats["Renderer Utilization %"]),
                allocatedMemory: integer(stats["Alloc system memory"]),
                inUseMemory: integer(stats["In use system memory"]),
                recoveryCount: integer(stats["recoveryCount"])
            )
        }
        return nil
    }

    private static func statistics(of service: io_registry_entry_t) -> [String: Any]? {
        let key = "PerformanceStatistics" as CFString
        let property = IORegistryEntryCreateCFProperty(service, key, kCFAllocatorDefault, 0)
        return property?.takeRetainedValue() as? [String: Any]
    }

    private static func percent(_ value: Any?) -> Double {
        guard let number = value as? NSNumber else { return 0 }
        return min(max(number.doubleValue / 100, 0), 1)
    }

    private static func integer(_ value: Any?) -> Int {
        (value as? NSNumber)?.intValue ?? 0
    }
}

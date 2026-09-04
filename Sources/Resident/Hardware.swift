import Foundation
import IOKit
import Metal

/// What this machine can actually do, read once at launch. The peak bandwidth figure is
/// the denominator for every "% of the bus" claim the app makes, so it is a published
/// spec looked up by chip — never a guess. An unrecognised chip reports `nil` and the
/// app then shows GB/s with no percentage rather than a percentage of nothing.
struct Hardware {
    var chip: String
    var gpuCores: Int?
    var totalMemory: Int
    /// Peak theoretical DRAM bandwidth in bytes/sec.
    var peakBandwidth: Double?
    /// Metal's own ceiling on resident GPU memory — the real "how much model fits".
    var workingSetLimit: Int
    /// Largest single allocation, which caps one model's weight buffer.
    var maxBufferLength: Int

    static let current = Hardware.detect()

    private static func detect() -> Hardware {
        let chip = Sysctl.string("machdep.cpu.brand_string") ?? "unknown"
        let cores = gpuCoreCount()
        let total = Sysctl.int("hw.memsize") ?? 0
        let device = MTLCreateSystemDefaultDevice()

        return Hardware(
            chip: chip,
            gpuCores: cores,
            totalMemory: total,
            peakBandwidth: peak(chip: chip, gpuCores: cores),
            workingSetLimit: Int(device?.recommendedMaxWorkingSetSize ?? 0),
            maxBufferLength: device?.maxBufferLength ?? 0
        )
    }

    private static func gpuCoreCount() -> Int? {
        let matching = IOServiceMatching("AGXAccelerator")
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS
        else { return nil }
        defer { IOObjectRelease(iterator) }

        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            let key = "gpu-core-count" as CFString
            let property = IORegistryEntryCreateCFProperty(service, key, kCFAllocatorDefault, 0)
            guard let value = property?.takeRetainedValue() as? NSNumber else { continue }
            return value.intValue
        }
        return nil
    }

    /// Published peak memory bandwidth per chip, in GB/s. The Max and Pro tiers ship in
    /// binned and full versions with different bus widths, so the GPU core count picks
    /// between them — an M4 Max is 410 GB/s at 32 cores and 546 GB/s at 40.
    private static func peak(chip: String, gpuCores: Int?) -> Double? {
        let cores = gpuCores ?? 0
        let gigabytes: Double?

        switch true {
        case chip.contains("M1 Ultra"), chip.contains("M2 Ultra"), chip.contains("M3 Ultra"):
            gigabytes = 800
        case chip.contains("M1 Max"), chip.contains("M2 Max"):
            gigabytes = 400
        case chip.contains("M3 Max"):
            gigabytes = cores >= 40 ? 400 : 300
        case chip.contains("M4 Max"):
            gigabytes = cores >= 40 ? 546 : 410
        case chip.contains("M1 Pro"), chip.contains("M2 Pro"):
            gigabytes = 200
        case chip.contains("M3 Pro"):
            gigabytes = 150
        case chip.contains("M4 Pro"):
            gigabytes = 273
        case chip.contains("M1"):
            gigabytes = 68.25
        case chip.contains("M2"), chip.contains("M3"):
            gigabytes = 100
        case chip.contains("M4"):
            gigabytes = 120
        default:
            gigabytes = nil
        }

        guard let gigabytes else { return nil }
        return gigabytes * 1e9
    }

    /// A one-line description for the menu footer.
    var summary: String {
        var parts = [chip]
        if let gpuCores { parts.append("\(gpuCores)-core GPU") }
        parts.append(Format.bytes(totalMemory))
        if let peakBandwidth {
            parts.append(String(format: "%.0f GB/s", peakBandwidth / 1e9))
        }
        return parts.joined(separator: " · ")
    }
}

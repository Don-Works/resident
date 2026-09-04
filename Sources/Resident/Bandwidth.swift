import Foundation

/// Memory bandwidth, and why there is no gauge for it.
///
/// The DRAM traffic counters exist. They live in the IOReport group
/// `AMC Stats / Perf Counters`, published by the memory cache controller, and they carry
/// exactly what a local-AI monitor would want: `DCS RD` and `DCS WR` totals plus
/// per-agent attribution (`GFX` for the GPU, `PCPU`/`ECPU` for the cores, `ANE`).
///
/// They are not readable. Verified on macOS 26 / M4 Max, all three ways:
///
///  - `IOReportCreateSubscription` on that group returns NULL as a normal user *and*
///    as root (uid 0, euid 0).
///  - Subscribing to every channel instead does succeed, but the samples come back with
///    all 189 AMC channels silently removed — 11,202 of 11,399 — again including as root.
///  - `powermetrics` cannot help either: its samplers are cpu_power, gpu_power and
///    ane_power. There is no DRAM traffic sampler to parse.
///
/// The gate is therefore not privilege but entitlement, and Apple does not grant it.
/// Rather than show an estimate dressed as a measurement, Resident shows the one
/// bandwidth number that is exactly true: the decode ceiling, which is the machine's
/// published peak bandwidth divided by a model's weight bytes. See
/// `LoadedModel.decodeCeiling(peakBandwidth:)`.
///
/// This file exists to record the finding. If a future macOS opens the group up, the
/// subscription is about thirty lines and the gauge slots back in beside the others.
enum Bandwidth {
    /// The IOReport group that would carry it.
    static let group = "AMC Stats"
    static let subgroup = "Perf Counters"
}

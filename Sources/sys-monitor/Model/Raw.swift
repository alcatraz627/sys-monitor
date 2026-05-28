import Foundation

// Raw cumulative counter readings returned by samplers. These are NOT rates —
// the SamplingCoordinator deltas successive raw readings against measured
// elapsed time (RateMath) to produce the rate types in Samples.swift. Keeping
// raw and rate types distinct is what lets the coordinator be the single
// owner of rate logic (per docs/03-implementation.md §5.1).

/// One cumulative-tick reading for a single CPU (or the overall host). Tick
/// counters are monotonically increasing and `host_statistics`-derived.
public struct CPUTicks: Sendable, Equatable {
    public let user: UInt32
    public let system: UInt32
    public let idle: UInt32
    public let nice: UInt32
}

/// Cumulative CPU counters at one sample point. The overall reading and the
/// per-core readings come from two different mach calls (`host_statistics`
/// and `host_processor_info`); we surface both so the coordinator can decide
/// which to delta in which tier (overall: both tiers; per-core: open only).
public struct CPUCounters: Sendable {
    public let overall: CPUTicks
    public let perCore: [CPUTicks]
}

/// One memory snapshot. Memory is instantaneous — no two-sample wait needed —
/// so this is its own rate-free form. `physicalTotalBytes` is read once at
/// startup and carried into each sample for convenience.
public struct MemoryRaw: Sendable {
    public let activeBytes: UInt64
    public let wiredBytes: UInt64
    public let compressedBytes: UInt64
    public let freeBytes: UInt64
    public let physicalTotalBytes: UInt64
    public let swapUsedBytes: UInt64
}

/// Cumulative byte counters from the network interfaces, summed across all
/// non-loopback interfaces that were up at sample time. `ifaceSet` is the
/// set of interface identifiers seen — if it changes between samples, an
/// interface came up or went down (VPN toggle, USB tether plug/unplug) and
/// the coordinator treats the next delta as a gap that needs re-baseline.
public struct NetCounters: Sendable {
    public let inBytes: UInt64
    public let outBytes: UInt64
    public let ifaceSet: Set<String>
}

/// One raw process reading. `cpuTimeNs` is `pti_total_user + pti_total_system`
/// in nanoseconds — a monotonically increasing cumulative counter for that
/// process's lifetime; the coordinator deltas it against wall-clock elapsed
/// to produce a %CPU. `residentBytes` is instantaneous (`pti_resident_size`).
public struct ProcRaw: Sendable {
    public let pid: Int32
    public let name: String
    public let cpuTimeNs: UInt64
    public let residentBytes: UInt64
}

/// Cumulative byte counters from the IOKit `IOBlockStorageDriver` family,
/// summed across non-virtual drivers. Provisional per N8 — DiskSampler may
/// throw `.unavailable` on hardware where the API is unreliable.
public struct DiskCounters: Sendable {
    public let readBytes: UInt64
    public let writeBytes: UInt64
    /// Number of IOBlockStorageDriver nodes that contributed. Used by the
    /// Phase-1 spike to judge whether the API found anything plausible.
    public let driverCount: Int
}

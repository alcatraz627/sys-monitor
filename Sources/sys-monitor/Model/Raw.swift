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
    /// Pages the scanner has aged off the active queue. Not displayed; it is
    /// here so the XNU identity active+inactive+speculative ==
    /// internal+external can be asserted, which is what proves these counters
    /// still mean what the formula assumes.
    public let inactiveBytes: UInt64
    /// Anonymous (application) pages. This, not `active`, is what "app
    /// memory" means: the active/inactive split is a page-queue balance the
    /// scanner maintains, so `active` both includes file cache that happens
    /// to sit on the active queue and excludes app pages moved to inactive.
    public let internalBytes: UInt64
    /// File-backed pages. With `purgeable` this is Activity Monitor's
    /// "Cached Files".
    public let externalBytes: UInt64
    public let purgeableBytes: UInt64
    /// Pages read ahead but not yet faulted. `vm_stat` subtracts these from
    /// free; the raw `free_count` includes them.
    public let speculativeBytes: UInt64
    public let physicalTotalBytes: UInt64
    public let swapUsedBytes: UInt64

    /// Cumulative pages the compressor has taken in. Rising means memory is
    /// being squeezed, which on its own is the OS working as designed.
    public let compressions: UInt64
    /// Cumulative pages faulted back OUT of the compressor. This is the half
    /// that costs the user time: a thread asked for a page and had to wait
    /// for it to be decompressed.
    public let decompressions: UInt64
    /// Cumulative pages faulted back from disk. Same stall as a
    /// decompression and far more expensive.
    public let swapins: UInt64
    public let swapouts: UInt64
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
    /// Cumulative in/out bytes per interface NAME (en0, utun3, …). Feeds the
    /// optional per-interface breakdown; the aggregate above is independent
    /// of it (and stays the field-bug-fixed rate path).
    public let perInterface: [String: NetIfaceBytes]

    public init(inBytes: UInt64, outBytes: UInt64, ifaceSet: Set<String>,
                perInterface: [String: NetIfaceBytes] = [:]) {
        self.inBytes = inBytes
        self.outBytes = outBytes
        self.ifaceSet = ifaceSet
        self.perInterface = perInterface
    }
}

public struct NetIfaceBytes: Sendable {
    public let inBytes: UInt64
    public let outBytes: UInt64
    public init(inBytes: UInt64, outBytes: UInt64) {
        self.inBytes = inBytes; self.outBytes = outBytes
    }
}

/// One raw process reading. `cpuTimeNs` is `pti_total_user + pti_total_system`
/// in nanoseconds and `diskBytes` is lifetime read+written from rusage —
/// both monotonically increasing cumulative counters the coordinator
/// deltas against wall-clock elapsed to produce rates. `residentBytes`
/// is instantaneous (`pti_resident_size`).
public struct ProcRaw: Sendable {
    public let pid: Int32
    /// Parent pid, for rolling helper processes up under the app that owns
    /// them. 0 or 1 means "no useful parent" and the process is its own root.
    public let ppid: Int32
    public let name: String
    public let cpuTimeNs: UInt64
    public let residentBytes: UInt64
    /// What Activity Monitor's "Memory" column shows, from
    /// `ri_phys_footprint`. Zero when rusage was denied for this pid, in
    /// which case the caller falls back to `residentBytes`. RSS and
    /// footprint are different quantities, not two scales of one: measured
    /// across the live process table the ratio runs from 0.09 (a GPU-heavy
    /// process whose IOSurface pages RSS cannot see) to 19.4, crossing 1.0,
    /// so nothing can be calibrated from one to the other.
    public let footprintBytes: UInt64
    public let diskBytes: UInt64
    /// Lifetime energy attributed to this process, in nanojoules, from
    /// `ri_energy_nj` on the rusage call the sampler already makes. Cumulative
    /// like the disk counter, so watts is a delta over elapsed. Zero when
    /// rusage was denied, which ranks the process last in a power sort.
    public let energyNanojoules: UInt64

    /// The memory figure to display: footprint when it was readable, else
    /// RSS. Kept here rather than at the call site so every consumer makes
    /// the same choice.
    public var displayMemoryBytes: UInt64 {
        footprintBytes > 0 ? footprintBytes : residentBytes
    }
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

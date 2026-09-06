import Foundation

// Rate / display sample types. These are what the SamplingCoordinator
// publishes inside the snapshot — every value is render-ready (no further
// arithmetic in the UI). Distinct from Raw.swift counter readings; the
// transformation lives in RateMath.swift so the rules are testable in
// isolation (docs/03-implementation.md §5.1).

/// One CPU usage sample. Values are fractions in 0...1 (where 1 = 100% busy
/// on that lens — overall = % of one core averaged across cores; perCore = %
/// per individual core). Display layer multiplies by 100 for the user-facing
/// percentage.
public struct CPUSample: Sendable, Equatable {
    public let overall: Double
    public let perCore: [Double]
}

public enum MemoryPressure: Sendable, Equatable {
    case normal, warn, critical
}

/// One memory snapshot in display form. Instantaneous metric — appears in
/// `.ok` on the first sample (no two-sample baseline wait, per FR-16 — a
/// legitimate `0` for swap is real, not the `—` placeholder).
public struct MemorySample: Sendable, Equatable {
    public let usedBytes: UInt64
    public let totalBytes: UInt64
    public let swapUsedBytes: UInt64
    public let pressure: MemoryPressure
    /// What the MEM colour keys on. Deliberately separate from
    /// `usedBytes / totalBytes`, which stays the bar fill and the number: a
    /// machine can sit at 71% and thrash, or at 90% and be perfectly calm.
    public let severity: MetricSeverity
    /// Nil until two samples exist, so a rate can be computed.
    public let reclaim: ReclaimRate?
    /// The pools the used total is made of. Carried as values rather than
    /// recomputed in the view, because each one is a formula the suite pins
    /// (app is internal minus purgeable, free excludes speculative), and a
    /// second implementation in the UI is a second place to get it wrong.
    public let pools: MemoryPools
}

/// Where the machine's memory actually is. On Apple Silicon there is one
/// physical pool, so these are claims on the same unified memory rather than
/// separate banks.
public struct MemoryPools: Sendable, Equatable {
    public let appBytes: UInt64
    public let wiredBytes: UInt64
    public let compressedBytes: UInt64
    public let cachedFilesBytes: UInt64
    public let freeBytes: UInt64

    public init(appBytes: UInt64, wiredBytes: UInt64, compressedBytes: UInt64,
                cachedFilesBytes: UInt64, freeBytes: UInt64) {
        self.appBytes = appBytes
        self.wiredBytes = wiredBytes
        self.compressedBytes = compressedBytes
        self.cachedFilesBytes = cachedFilesBytes
        self.freeBytes = freeBytes
    }
}

/// Three levels, matching the existing green / amber / red ramp. Comparable so
/// that combining two independent signals is `max`, which is the whole policy:
/// any signal may raise severity and none may lower another's.
public enum MetricSeverity: Sendable, Equatable, Comparable {
    case normal, warn, critical
}

/// Reclaim activity as rates. Levels say what the kernel decided; rates say
/// what the machine is doing, which is what fires below the kernel's own
/// escalation point.
public struct ReclaimRate: Sendable, Equatable {
    /// Pages per second faulted back in, decompressions plus swapins. The
    /// half the user feels, because a thread waited for each one.
    public let stallPagesPerSec: Double
    /// Pages per second pushed out, compressions plus swapouts.
    public let evictPagesPerSec: Double

    public init(stallPagesPerSec: Double, evictPagesPerSec: Double) {
        self.stallPagesPerSec = stallPagesPerSec
        self.evictPagesPerSec = evictPagesPerSec
    }
}

/// Bytes-per-second throughput, used for network and disk rows.
public struct Throughput: Sendable, Equatable {
    public let inPerSec: Double
    public let outPerSec: Double
}

/// Instantaneous package power in watts for the Apple-Silicon compute
/// blocks, derived from IOReport energy-counter deltas. ANE is
/// best-effort (some chips report it sparsely, idle reads 0).
public struct PowerSample: Sendable, Equatable {
    public let cpuWatts: Double
    public let gpuWatts: Double
    public let aneWatts: Double
}

/// Battery state from the public IOKit power-sources API. Present only on
/// machines with an internal battery (a laptop); absent on desktops.
public struct BatterySample: Sendable, Equatable {
    public let percent: Int           // 0…100
    public let charging: Bool
    public let charged: Bool
    public let onAC: Bool
    public let minutesRemaining: Int? // to full (charging) or empty (discharging); nil = calculating
}

/// Free / total space on the boot volume, from `statfs`. Panel-only and
/// slow-changing, so it's read live each open-tier sweep (no cache — free
/// space is mutated by every other process, so any TTL would show a
/// plausible-but-stale number).
public struct DiskSpaceSample: Sendable, Equatable {
    public let freeBytes: UInt64
    public let totalBytes: UInt64
}

/// One CPU cluster's residency-weighted average frequency, in MHz. Derived
/// from IOReport performance-state residency × the per-cluster DVFS table.
public struct ClusterFrequency: Sendable, Equatable {
    public let name: String   // e.g. "P0", "P1", "S" — the IOReport channel name
    public let mhz: Double
}

/// One interface's throughput for the per-interface NET breakdown.
public struct InterfaceThroughput: Sendable, Equatable {
    public let name: String
    public let inPerSec: Double
    public let outPerSec: Double
}

/// System load averages (1 / 5 / 15 min) plus uptime — the htop footer line.
/// Load is "runnable + uncomputable threads," not a percentage; a value near
/// the core count means fully busy.
public struct LoadAverage: Sendable, Equatable {
    public let one: Double
    public let five: Double
    public let fifteen: Double
    public let uptimeSeconds: TimeInterval
}

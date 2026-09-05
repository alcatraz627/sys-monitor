import Foundation

/// One immutable view of "everything the UI knows right now."
///
/// Crosses the sampling-thread → main-thread boundary as a `Sendable` value.
/// Equality compares only `generation` (which the producer bumps once per
/// tick) so SwiftUI's diff is cheap — it never has to walk the 60-point
/// history arrays to decide whether anything changed.
public struct MetricsSnapshot: Sendable, Equatable {
    public var generation: UInt64
    public var cpu: Metric<CPUSample>
    public var memory: Metric<MemorySample>
    public var processes: Metric<[ProcSample]>
    public var net: Metric<Throughput>
    public var disk: Metric<Throughput>
    public var power: Metric<PowerSample>
    public var battery: BatterySample?   // nil on desktops or while unread
    public var diskSpace: DiskSpaceSample? = nil   // boot volume; panel-tier only
    public var loadAverage: LoadAverage? = nil     // load + uptime; panel-tier only
    public var perInterfaceNet: [InterfaceThroughput] = []  // NET breakdown; panel-tier
    public var cpuHistory: RingBuffer
    public var memHistory: RingBuffer
    public var netHistory: RingBuffer
    public var diskHistory: RingBuffer
    /// Whether per-process network counters are available (the private
    /// NetworkStatistics framework resolved). Drives whether the panel
    /// offers a Network sort. Constant for a session; carried on the
    /// snapshot so the UI reads it through the one channel it already
    /// observes.
    public var perProcessNetAvailable: Bool = false
    /// Whether IOReport package-power readings are available (the private
    /// framework resolved). Drives whether the panel shows a power row.
    public var powerAvailable: Bool = false

    public static func == (a: MetricsSnapshot, b: MetricsSnapshot) -> Bool {
        a.generation == b.generation
    }

    /// Empty initial state: every metric in `measuring`, both history buffers
    /// empty. Used at app start before the first sample lands so SwiftUI and
    /// the glyph have something coherent to render.
    public static func initial(windowSeconds: TimeInterval = 60) -> MetricsSnapshot {
        MetricsSnapshot(
            generation: 0,
            cpu: .measuring,
            memory: .measuring,
            processes: .measuring,
            net: .measuring,
            disk: .measuring,
            power: .measuring,
            battery: nil,
            cpuHistory: RingBuffer(windowSeconds: windowSeconds),
            memHistory: RingBuffer(windowSeconds: windowSeconds),
            netHistory: RingBuffer(windowSeconds: windowSeconds),
            diskHistory: RingBuffer(windowSeconds: windowSeconds)
        )
    }
}

/// One process's render-ready reading: %CPU and disk throughput are rates
/// over the last process-sampling window; memory is the instantaneous
/// physical footprint, the same quantity Activity Monitor's "Memory" shows.
public struct ProcSample: Sendable, Equatable {
    public let pid: Int32
    public let name: String
    public let cpu: Double
    public let memBytes: UInt64
    /// Bytes/sec of disk I/O (read + written). 0 for pids whose rusage
    /// is denied (other users) — they rank last in a disk sort.
    public let diskBps: Double
    /// Bytes/sec of network I/O (rx + tx) from the per-process network
    /// monitor. 0 when the monitor is unavailable or the pid has no
    /// tracked flows.
    public let netBps: Double

    /// Build from a raw reading. This is the only path the coordinator
    /// uses, so which memory quantity reaches the UI is decided here rather
    /// than at the call site. A previous version chose it inline; reverting
    /// that one expression then re-shipped RSS with the whole suite green,
    /// because no guard covered the wiring.
    public init(raw: ProcRaw, cpu: Double, diskBps: Double, netBps: Double) {
        self.pid = raw.pid
        self.name = raw.name
        self.cpu = cpu
        self.memBytes = raw.displayMemoryBytes
        self.diskBps = diskBps
        self.netBps = netBps
    }

    /// Direct construction, for fixtures and tests.
    public init(pid: Int32, name: String, cpu: Double,
                memBytes: UInt64, diskBps: Double, netBps: Double) {
        self.pid = pid; self.name = name; self.cpu = cpu
        self.memBytes = memBytes; self.diskBps = diskBps; self.netBps = netBps
    }
}

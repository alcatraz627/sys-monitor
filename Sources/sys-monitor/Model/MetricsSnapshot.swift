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
    /// One history per core, for the expanded heatmap. Empty in the idle
    /// tier, which never reads per-core counters, and empty on the first open
    /// tick before a delta exists.
    public var perCoreHistory: [RingBuffer] = []
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
    /// Parent pid, for grouping helpers under the app that spawned them.
    public var ppid: Int32 = 0
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
    /// Watts attributed to this process over the sampling interval, from the
    /// cumulative `ri_energy_nj` counter. 0 for pids whose rusage is denied,
    /// which ranks them last in a power sort, same as disk.
    public let watts: Double

    /// Build from a raw reading. This is the only path the coordinator
    /// uses, so which memory quantity reaches the UI is decided here rather
    /// than at the call site. A previous version chose it inline; reverting
    /// that one expression then re-shipped RSS with the whole suite green,
    /// because no guard covered the wiring.
    public init(raw: ProcRaw, cpu: Double, diskBps: Double, netBps: Double,
                watts: Double = 0) {
        self.pid = raw.pid
        self.ppid = raw.ppid
        self.name = raw.name
        self.cpu = cpu
        self.memBytes = raw.displayMemoryBytes
        self.watts = watts
        self.diskBps = diskBps
        self.netBps = netBps
    }

    /// Direct construction, for fixtures and tests.
    public init(pid: Int32, ppid: Int32 = 0, name: String, cpu: Double,
                memBytes: UInt64, diskBps: Double, netBps: Double,
                watts: Double = 0) {
        self.pid = pid; self.ppid = ppid; self.name = name; self.cpu = cpu
        self.memBytes = memBytes; self.diskBps = diskBps; self.netBps = netBps
        self.watts = watts
    }
}

/// A process tree rolled up under the process that owns it.
///
/// Almost everything heavy on a Mac is a tree, and a flat top-N misattributes
/// it badly: Chrome measured 3853 MB across 41 processes while its largest
/// single row read 245 MB, and a Next.js dev server's workers each read 55 to
/// 100 MB against roughly 750 MB for the tree. The flat list is still the
/// right view when hunting one runaway pid, so both are offered.
public struct ProcGroup: Sendable, Equatable, Identifiable {
    public let root: ProcSample
    public let members: [ProcSample]

    public var id: Int32 { root.pid }
    public var name: String { root.name }
    public var count: Int { members.count }
    public var cpu: Double { members.reduce(0) { $0 + $1.cpu } }
    public var memBytes: UInt64 { members.reduce(0) { $0 &+ $1.memBytes } }
    public var diskBps: Double { members.reduce(0) { $0 + $1.diskBps } }
    public var netBps: Double { members.reduce(0) { $0 + $1.netBps } }

    /// Roll samples up to their outermost visible ancestor.
    ///
    /// The walk stops below pid 1, so trees root at the app rather than at
    /// launchd, and it stops at any pid the sampler cannot see, which makes
    /// a process whose parent is invisible its own root. Cycles and long
    /// chains are bounded by a hop limit; a pid whose parent chain does not
    /// terminate is treated as its own root rather than dropped.
    public static func group(_ samples: [ProcSample]) -> [ProcGroup] {
        guard !samples.isEmpty else { return [] }
        var byPid: [Int32: ProcSample] = [:]
        byPid.reserveCapacity(samples.count)
        for s in samples { byPid[s.pid] = s }

        func rootPid(of s: ProcSample) -> Int32 {
            var cur = s
            var hops = 0
            while hops < 64 {
                hops += 1
                let parent = cur.ppid
                guard parent > 1, let next = byPid[parent], next.pid != cur.pid else { break }
                cur = next
            }
            return cur.pid
        }

        var membersByRoot: [Int32: [ProcSample]] = [:]
        for s in samples { membersByRoot[rootPid(of: s), default: []].append(s) }

        return membersByRoot.compactMap { rootPid, members in
            guard let root = byPid[rootPid] else { return nil }
            // Largest child first, so expanding a group shows the reason it
            // is heavy at the top.
            return ProcGroup(root: root,
                             members: members.sorted { $0.memBytes > $1.memBytes })
        }
    }
}

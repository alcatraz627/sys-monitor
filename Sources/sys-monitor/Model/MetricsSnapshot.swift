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
            cpuHistory: RingBuffer(windowSeconds: windowSeconds),
            memHistory: RingBuffer(windowSeconds: windowSeconds),
            netHistory: RingBuffer(windowSeconds: windowSeconds),
            diskHistory: RingBuffer(windowSeconds: windowSeconds)
        )
    }
}

/// One process's render-ready reading: %CPU and disk throughput are
/// rates over the last process-sampling window; memory is instantaneous
/// resident size.
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
}

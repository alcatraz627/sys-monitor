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
            memHistory: RingBuffer(windowSeconds: windowSeconds)
        )
    }
}

// Placeholder process sample type so MetricsSnapshot compiles before the
// open-tier process sampler exists. Replaced wholesale when the real one
// lands; this stub just defines the shape so the snapshot type is stable.
public struct ProcSample: Sendable, Equatable {
    public let pid: Int32
    public let name: String
    public let cpu: Double
    public let memBytes: UInt64
}

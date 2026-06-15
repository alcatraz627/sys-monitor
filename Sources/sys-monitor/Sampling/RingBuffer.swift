import Foundation

// A bounded, time-windowed history of samples. Value-type by design (per
// docs/03-implementation.md §4 / review issue 1): the SamplingCoordinator
// owns the authoritative buffer on its background serial queue and copies
// the current window into each `MetricsSnapshot`; the GlyphRenderer and
// SwiftUI read only the immutable copy. There is NO shared mutable buffer.
//
// The eviction rule is time-based, not count-based: callers pass a window
// duration and any point older than `now - window` is dropped on the next
// append. This keeps history length constant under cadence changes (FR-7).

public struct HistoryPoint: Sendable, Equatable {
    public let timestamp: TimeInterval   // monoSeconds() — CLOCK_MONOTONIC, advances across sleep
    public let value: Double             // metric-defined unit (e.g. 0...1 for CPU)
}

public struct RingBuffer: Sendable, Equatable {
    /// The retention window in seconds. Points older than `now - window` are
    /// evicted on append.
    public let windowSeconds: TimeInterval
    /// Hard cap on stored points — defensive bound so a runaway producer
    /// can't grow the array unboundedly even if `now` drifts. NFR-4.
    public let maxCapacity: Int
    public private(set) var points: [HistoryPoint]

    public init(windowSeconds: TimeInterval, maxCapacity: Int = 4096) {
        self.windowSeconds = windowSeconds
        self.maxCapacity = maxCapacity
        self.points = []
        self.points.reserveCapacity(min(maxCapacity, 256))
    }

    /// Append a point and evict anything older than the window OR beyond
    /// the hard cap. Idempotent and cheap (FIFO from the head).
    public mutating func append(_ point: HistoryPoint) {
        points.append(point)
        evict(now: point.timestamp)
    }

    /// Drop points older than `now - windowSeconds`, then trim to the cap.
    /// Exposed for tests / coordinator manual eviction at tier-switch time.
    public mutating func evict(now: TimeInterval) {
        let cutoff = now - windowSeconds
        var dropCount = 0
        for p in points {
            if p.timestamp < cutoff { dropCount += 1 } else { break }
        }
        if dropCount > 0 { points.removeFirst(dropCount) }
        if points.count > maxCapacity {
            points.removeFirst(points.count - maxCapacity)
        }
    }

    public var isEmpty: Bool { points.isEmpty }
    public var count: Int { points.count }
}

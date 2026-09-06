import Foundation

// Pure free functions that turn cumulative counter pairs into rates. Kept
// separate from the samplers AND from the coordinator so they're trivially
// testable without the timer machinery (docs/03-implementation.md §5.2 /
// review nit "consider making the coordinator's rate math a free function").
//
// EVERY rate divides by MEASURED elapsed wall-clock time between the two
// samples — never the nominal cadence (the Stage-2 review issue 4 invariant).
// This makes cadence changes, tier switches, and timer jitter correct by
// construction.

public enum RateMath {

    /// Overall CPU utilization 0...1 from two `CPUTicks` readings. Util =
    /// busy / (busy + idle), where busy = user+system+nice. Δticks are
    /// unitless (Mach ticks), so the elapsed argument is unused for the
    /// ratio itself — but we still take it for symmetry with byte-rate
    /// callers and so we can short-circuit pathological elapsed values.
    public static func cpuUtilization(prev: CPUTicks, now: CPUTicks) -> Double {
        let dUser = Double(now.user &- prev.user)
        let dSys  = Double(now.system &- prev.system)
        let dIdle = Double(now.idle &- prev.idle)
        let dNice = Double(now.nice &- prev.nice)
        let busy = dUser + dSys + dNice
        let total = busy + dIdle
        guard total > 0 else { return 0 }
        return min(1.0, max(0.0, busy / total))
    }

    /// Per-core utilization in 0...1 from two parallel arrays of ticks. If
    /// the arrays differ in length (a core appeared/disappeared between
    /// samples — vanishingly rare on macOS but defended-against), the shorter
    /// length wins and the result is treated as a one-shot baseline by the
    /// caller (re-baseline next tick).
    public static func cpuPerCore(prev: [CPUTicks], now: [CPUTicks]) -> [Double] {
        let n = min(prev.count, now.count)
        var out: [Double] = []
        out.reserveCapacity(n)
        for i in 0..<n {
            out.append(cpuUtilization(prev: prev[i], now: now[i]))
        }
        return out
    }

    /// Bytes-per-second between two cumulative byte counts and the measured
    /// elapsed seconds between the readings. Negative deltas (counter wrap or
    /// interface reset) are returned as `nil` — the coordinator treats `nil`
    /// as a gap signal and re-baselines per FR-18.
    public static func bytesPerSec(prev: UInt64, now: UInt64, elapsed: TimeInterval) -> Double? {
        guard elapsed > 0, now >= prev else { return nil }
        return Double(now - prev) / elapsed
    }

    /// Whether the interval since the last tick is too long to delta across —
    /// see `isGap` below. `SampleClock` is the per-metric wrapper.

    /// Tracks when ONE metric was last read, so its rate divides by the time
    /// since that metric's own last reading rather than since the last tick
    /// of any kind.
    ///
    /// The distinction is not academic. NET and DISK are read every tick in
    /// the open tier but only on request in the idle tier, so a shared tick
    /// clock told them that 0.3 s had passed when their counters were minutes
    /// old, and the whole panel-closed period of bytes was divided by one
    /// tick. The gap test could not see it: the interval it judged was
    /// healthy, and the stale thing was the counter. Owning the clock makes
    /// that mistake unrepresentable rather than merely fixed.
    public struct SampleClock: Sendable, Equatable {
        /// Optional rather than a 0 sentinel: `monoSeconds()` is free to
        /// return 0, and a sentinel would read that legitimate stamp as
        /// "never sampled" and silently re-baseline forever.
        private var last: (time: TimeInterval, cadence: Double)?

        public init() {}

        /// Elapsed since this metric was last read, and whether that gap is
        /// too wide to delta across. A first read reports elapsed 0 and
        /// `isGap == true`, which callers treat as "baseline only".
        public func evaluate(now: TimeInterval, cadence: Double,
                             gapMultiplier: Double) -> (elapsed: TimeInterval, isGap: Bool) {
            guard let last else { return (0, true) }
            let elapsed = now - last.time
            guard elapsed > 0 else { return (elapsed, true) }
            let gap = RateMath.isGap(
                elapsed: elapsed, cadence: cadence,
                prevCadence: last.cadence > 0 ? last.cadence : cadence,
                gapMultiplier: gapMultiplier)
            return (elapsed, gap)
        }

        public mutating func stamp(now: TimeInterval, cadence: Double) {
            last = (now, cadence)
        }

        /// Forget the last reading, so the next one only re-baselines. Used
        /// when the counter behind it is dropped (read failure, wake).
        public mutating func reset() { last = nil }

        public var hasBaseline: Bool { last != nil }

        public static func == (a: SampleClock, b: SampleClock) -> Bool {
            a.last?.time == b.last?.time && a.last?.cadence == b.last?.cadence
        }
    }

    /// Pages/sec between two cumulative page counters. Same wrap rule as
    /// `bytesPerSec`: a backwards counter is `nil`, meaning re-baseline.
    public static func pagesPerSec(prev: UInt64, now: UInt64, elapsed: TimeInterval) -> Double? {
        guard elapsed > 0, now >= prev else { return nil }
        return Double(now - prev) / elapsed
    }

    /// What the MEM colour keys on, from reclaim evidence rather than percent
    /// used. Percent used stays the bar fill and the number.
    ///
    /// The kernel's own level is a FLOOR, never a ceiling: it can raise the
    /// result but never lower it, because when memorystatus has escalated the
    /// machine is already in trouble whatever the rates say. The rates then
    /// add sensitivity below that point, which is the 71%-while-thrashing case
    /// the percent-driven trigger reads as calm today.
    ///
    /// Thresholds are anchored to measurement, not taste. On this machine
    /// during ordinary use, decompressions and swapins were sustained at
    /// exactly 0.0 pages/sec across 30 s, and swap had not been touched since
    /// boot (2026-09-06, `reclaim_probe.py`). Any sustained fault-back is
    /// therefore already abnormal, so the warn anchor sits low.
    ///
    /// Caveat, deliberate: this is a pure function of one interval, so a
    /// single-tick burst on an app launch can show amber for one tick. The
    /// debounce that would suppress that lives in `AlertEvaluator` and is not
    /// wired here yet.
    public static func memorySeverity(pressure: MemoryPressure,
                                      reclaim: ReclaimRate?,
                                      warnPagesPerSec: Double = 50,
                                      criticalPagesPerSec: Double = 1000) -> MemorySeverity {
        let fromKernel: MemorySeverity
        switch pressure {
        case .normal:   fromKernel = .normal
        case .warn:     fromKernel = .warn
        case .critical: fromKernel = .critical
        }
        guard let reclaim else { return fromKernel }

        let fromRate: MemorySeverity
        switch reclaim.stallPagesPerSec {
        case ..<warnPagesPerSec:     fromRate = .normal
        case ..<criticalPagesPerSec: fromRate = .warn
        default:                     fromRate = .critical
        }
        return max(fromKernel, fromRate)
    }

    /// Whether the interval since the last tick is too long to delta across —
    /// a "gap" that forces a re-baseline. The threshold is judged against the
    /// LARGER of the current cadence and the cadence the previous tick was
    /// stamped under, so the first tick after a tier switch or cadence change
    /// doesn't misclassify a healthy old-cadence interval as a gap. That
    /// misclassification was field bugs FB-2 / FB-4 (NET/DISK blanking on
    /// panel-open and on settings change): a ~5 s idle interval judged
    /// against the 1 s open threshold (×2 = 2 s) read as a gap ~60% of opens.
    public static func isGap(
        elapsed: TimeInterval, cadence: Double, prevCadence: Double, gapMultiplier: Double
    ) -> Bool {
        guard elapsed > 0 else { return true }
        return elapsed > max(cadence, prevCadence) * gapMultiplier
    }
}

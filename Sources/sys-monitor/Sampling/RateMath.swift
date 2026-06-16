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

import Foundation

// Boundary-check harness, run via `sys-monitor --self-test` (exits 0 if all
// pass, 1 otherwise). This is the project's regression suite for the math
// classes that caused real bugs — kept as a runnable mode rather than an
// XCTest target because XCTest ships with full Xcode, not the Command Line
// Tools this project builds under. The two headline cases reproduce the two
// shipped crashes/bugs:
//   • CPU tick counters above Int32.max  → commit 0de4eae (launch crash)
//   • formatBps width at every magnitude → commit fa31022 (cell clip)

@MainActor
func runSelfTest() -> Int32 {
    var failures = 0
    func check(_ name: String, _ cond: Bool, _ detail: @autoclosure () -> String = "") {
        if cond { print("  ok   \(name)") }
        else { failures += 1; print("  FAIL \(name)\(detail().isEmpty ? "" : " — \(detail())")") }
    }

    print("RateMath — CPU utilization")
    // 0de4eae regression: cumulative host idle ticks exceed Int32.max within
    // weeks of uptime. CPUTicks is UInt32, so values past 2^31 must be
    // constructible and computed correctly (the crash was an Int32() round-
    // trip in the sampler; this guards the whole counter path stays UInt32).
    do {
        let prev = CPUTicks(user: 3_000_000_000, system: 100, idle: 4_000_000_000, nice: 0)
        let now  = CPUTicks(user: 3_000_000_050, system: 110, idle: 4_000_000_150, nice: 0)
        let u = RateMath.cpuUtilization(prev: prev, now: now)   // must not trap
        // busy Δ = 50+10 = 60, idle Δ = 150 → 60/210 ≈ 0.286
        check("ticks above Int32.max compute, no trap", abs(u - 60.0/210.0) < 0.001, "got \(u)")
    }
    // Counter wrap (UInt32 rollover): &- must yield the small forward delta,
    // never a huge value or a trap.
    do {
        let prev = CPUTicks(user: 10, system: 0, idle: UInt32.max - 4, nice: 0)
        let now  = CPUTicks(user: 20, system: 0, idle: 5, nice: 0)  // idle wrapped past 0
        let u = RateMath.cpuUtilization(prev: prev, now: now)
        // idle Δ via &- = 5 &- (max-4) = 10 ; busy Δ = 10 → 10/20 = 0.5
        check("UInt32 wrap yields small forward delta", abs(u - 0.5) < 0.001, "got \(u)")
    }
    // Idle-only tick, zero total guard.
    check("zero total → 0", RateMath.cpuUtilization(
        prev: CPUTicks(user: 1, system: 1, idle: 1, nice: 1),
        now:  CPUTicks(user: 1, system: 1, idle: 1, nice: 1)) == 0)
    // Clamp to 0…1.
    do {
        let u = RateMath.cpuUtilization(
            prev: CPUTicks(user: 0, system: 0, idle: 100, nice: 0),
            now:  CPUTicks(user: 50, system: 50, idle: 100, nice: 0))
        check("utilization in 0…1", u >= 0 && u <= 1, "got \(u)")
    }

    print("RateMath — bytes/sec")
    check("normal rate", RateMath.bytesPerSec(prev: 0, now: 1_048_576, elapsed: 1.0) == 1_048_576)
    check("counter wrap/reset → nil", RateMath.bytesPerSec(prev: 1000, now: 500, elapsed: 1.0) == nil)
    check("zero elapsed → nil", RateMath.bytesPerSec(prev: 0, now: 1000, elapsed: 0) == nil)

    print("RateMath — gap detection (FB-2 / FB-4 transition-gap class)")
    // The regression that blanked NET/DISK on panel-open and settings-change:
    // the first tick after idle(5s)→open(1s) sees a ~5 s interval. It must be
    // judged against the LARGER cadence (5), not the new 1 s threshold.
    check("idle→open transition interval is NOT a gap",
          RateMath.isGap(elapsed: 4.0, cadence: 1.0, prevCadence: 5.0, gapMultiplier: 2.0) == false,
          "4 s after a 5 s-cadence tick must not be a gap")
    // The bug, asserted as the wrong answer the old code gave: judged against
    // only the new 1 s cadence (×2 = 2 s), 4 s WOULD have been a gap.
    check("…and would have been a gap under new-cadence-only judging",
          RateMath.isGap(elapsed: 4.0, cadence: 1.0, prevCadence: 1.0, gapMultiplier: 2.0) == true)
    check("cadence raised (idle 2→4) mid-interval is not a gap",
          RateMath.isGap(elapsed: 3.9, cadence: 4.0, prevCadence: 2.0, gapMultiplier: 2.0) == false)
    check("genuine long gap IS a gap",
          RateMath.isGap(elapsed: 15.0, cadence: 1.0, prevCadence: 1.0, gapMultiplier: 2.0) == true)
    check("steady same-cadence tick is not a gap",
          RateMath.isGap(elapsed: 1.0, cadence: 1.0, prevCadence: 1.0, gapMultiplier: 2.0) == false)
    check("first tick (elapsed 0) is a gap → re-baseline",
          RateMath.isGap(elapsed: 0, cadence: 1.0, prevCadence: 0, gapMultiplier: 2.0) == true)

    print("GlyphRenderer.formatBps — width-safe at every magnitude (fa31022)")
    // Every value must render to EXACTLY 5 chars so the throughput cell never
    // clips. The bug was %3.0f rounding 999.7 KB/s → "1000KB" (6 chars).
    let boundaries: [(String, Double)] = [
        ("zero",        0),
        ("1 B/s",       1),
        ("sub-KB",      500),
        ("1 KB",        1024),
        ("999 KB",      999 * 1024),
        ("KB→MB bdry",  999.7 * 1024),     // the original overflow value
        ("1 MB",        1_048_576),
        ("99 MB",       99.0 * 1_048_576),
        ("999 MB",      999.0 * 1_048_576),
        ("MB→GB bdry",  999.7 * 1_048_576),
        ("7 GB NVMe",   7.0 * 1_073_741_824),
        ("1 TB cap",    1_099_511_627_776),
        ("measuring",   -1),
    ]
    for (name, v) in boundaries {
        let s = GlyphRenderer.formatBps(v)
        check("formatBps \(name) is 5 chars", s.count == 5, "got \"\(s)\" (\(s.count))")
    }

    print(failures == 0 ? "\nALL PASS" : "\n\(failures) FAILURE(S)")
    return failures == 0 ? 0 : 1
}

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
    // bits/s mode (9.1): same width invariant must hold for the ×8 path, and
    // the unit letter must be lowercase 'b'. A few values also push a tier
    // higher than their byte form (×8), exercising the KB→MB→GB carries.
    print("GlyphRenderer.formatBps — bits/s mode width-safe (9.1)")
    for (name, v) in boundaries where v >= 0 {
        let s = GlyphRenderer.formatBps(v, unit: .bitsPerSec)
        check("formatBps bits \(name) is 5 chars", s.count == 5, "got \"\(s)\" (\(s.count))")
        check("formatBps bits \(name) uses 'b' not 'B'", !s.contains("B"), "got \"\(s)\"")
    }
    // Spot-check the ×8 scaling crosses a tier: 200 KB/s = 1600 Kb/s ≈ 1.6 Mb/s.
    check("bits scaling crosses tier (200KB/s → ~1.6Mb/s)",
          GlyphRenderer.formatBps(200 * 1024, unit: .bitsPerSec).contains("Mb"),
          "got \"\(GlyphRenderer.formatBps(200 * 1024, unit: .bitsPerSec))\"")

    print("SettingsStore — bar-cell migration + reorder (9.4)")
    // Fresh store backed by an isolated, cleared defaults suite.
    func freshStore(_ suite: String, seed: (UserDefaults) -> Void = { _ in }) -> SettingsStore {
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        seed(d)
        return SettingsStore(defaults: d)
    }
    // Legacy OptionSet Int (cpu|net = 1|4 = 5) migrates to the legacy fixed
    // order CPU>MEM>NET>DISK → [.cpu, .net].
    let legacy = freshStore("selftest.bc.legacy") { $0.set(5, forKey: "barCells") }
    check("legacy Int 5 → [.cpu, .net]", legacy.barCells == [.cpu, .net], "got \(legacy.barCells)")
    // New [String] format preserves the stored order verbatim.
    let arr = freshStore("selftest.bc.arr") { $0.set(["disk", "cpu"], forKey: "barCells") }
    check("array [disk,cpu] preserves order", arr.barCells == [.disk, .cpu], "got \(arr.barCells)")
    // Absent → default.
    check("absent → default [.cpu,.mem]", freshStore("selftest.bc.empty").barCells == [.cpu, .mem])
    // setBarCell: enable appends; the last cell can never be removed.
    let g = freshStore("selftest.bc.guard")
    g.setBarCell(.net, enabled: true)
    check("enable appends at end", g.barCells == [.cpu, .mem, .net], "got \(g.barCells)")
    g.setBarCell(.cpu, enabled: false)
    g.setBarCell(.mem, enabled: false)
    g.setBarCell(.net, enabled: false)   // would empty the bar → refused
    check("last cell cannot be removed", g.barCells.count == 1, "got \(g.barCells)")
    // moveBarCell: adjacent swap, clamped at both ends.
    let m = freshStore("selftest.bc.move") { $0.set(["cpu", "mem", "net"], forKey: "barCells") }
    m.moveBarCell(.net, up: true)
    check("move up swaps with predecessor", m.barCells == [.cpu, .net, .mem], "got \(m.barCells)")
    m.moveBarCell(.cpu, up: true)        // already first
    check("move up at front is a no-op", m.barCells == [.cpu, .net, .mem], "got \(m.barCells)")
    m.moveBarCell(.mem, up: false)       // already last
    check("move down at back is a no-op", m.barCells == [.cpu, .net, .mem], "got \(m.barCells)")

    print("SettingsStore — severity thresholds persistence (9.2)")
    // Absent → ship defaults.
    let td = freshStore("selftest.thr.empty")
    check("thresholds default to shipped values",
          td.severityThresholds == .defaults, "got \(td.severityThresholds)")
    // Mutate → persists across a reload of the same suite.
    let suite = "selftest.thr.rt"
    let d1 = UserDefaults(suiteName: suite)!
    d1.removePersistentDomain(forName: suite)
    let s1 = SettingsStore(defaults: d1)
    s1.severityThresholds = SeverityThresholds(cpuWarn: 0.50, cpuCritical: 0.80,
                                               memWarn: 0.70, memCritical: 0.95)
    let s2 = SettingsStore(defaults: d1)   // reload from the same backing store
    check("thresholds round-trip through defaults",
          s2.severityThresholds == SeverityThresholds(cpuWarn: 0.50, cpuCritical: 0.80,
                                                       memWarn: 0.70, memCritical: 0.95),
          "got \(s2.severityThresholds)")

    print("SettingsStore — alert config persistence (6.1 / 9.5)")
    let ac0 = freshStore("selftest.alert.empty")
    check("alert config defaults to OFF", ac0.alertConfig == .defaults, "got \(ac0.alertConfig)")
    let asuite = "selftest.alert.rt"
    let ad1 = UserDefaults(suiteName: asuite)!
    ad1.removePersistentDomain(forName: asuite)
    let as1 = SettingsStore(defaults: ad1)
    as1.alertConfig = AlertConfig(enabled: true, cpuThreshold: 0.70, memThreshold: 0.88,
                                  sustainTicks: 8, cooldownSeconds: 120)
    let as2 = SettingsStore(defaults: ad1)
    check("alert config round-trips (incl. enabled + ticks)",
          as2.alertConfig == AlertConfig(enabled: true, cpuThreshold: 0.70, memThreshold: 0.88,
                                         sustainTicks: 8, cooldownSeconds: 120),
          "got \(as2.alertConfig)")

    print("AlertEvaluator — debounce + cooldown (6.1)")
    do {
        var ev = AlertEvaluator(config: AlertConfig(enabled: true, cpuThreshold: 0.80,
                                memThreshold: 0.90, sustainTicks: 3, cooldownSeconds: 100))
        check("below threshold → no fire", ev.evaluate(cpuLoad: 0.5, memLoad: 0.5, now: 0).isEmpty)
        check("1/3 high → no fire", ev.evaluate(cpuLoad: 0.85, memLoad: 0.1, now: 1).isEmpty)
        check("2/3 high → no fire", ev.evaluate(cpuLoad: 0.85, memLoad: 0.1, now: 2).isEmpty)
        let fire = ev.evaluate(cpuLoad: 0.85, memLoad: 0.1, now: 3)
        check("3/3 high → cpu fires once", fire.count == 1 && fire.first?.kind == .cpu, "got \(fire)")
        _ = ev.evaluate(cpuLoad: 0.9, memLoad: 0.1, now: 4)
        _ = ev.evaluate(cpuLoad: 0.9, memLoad: 0.1, now: 5)
        check("sustained within cooldown → silent",
              ev.evaluate(cpuLoad: 0.9, memLoad: 0.1, now: 6).isEmpty)
        check("past cooldown → re-fires",
              ev.evaluate(cpuLoad: 0.9, memLoad: 0.1, now: 104).first?.kind == .cpu)
    }
    do {
        let cfg = AlertConfig(enabled: true, cpuThreshold: 0.80, memThreshold: 0.90,
                              sustainTicks: 3, cooldownSeconds: 100)
        var ev = AlertEvaluator(config: cfg)
        _ = ev.evaluate(cpuLoad: 0.85, memLoad: 0.1, now: 1)
        _ = ev.evaluate(cpuLoad: 0.85, memLoad: 0.1, now: 2)
        _ = ev.evaluate(cpuLoad: 0.10, memLoad: 0.1, now: 3)   // drop resets
        check("drop below threshold resets streak",
              ev.evaluate(cpuLoad: 0.85, memLoad: 0.1, now: 4).isEmpty)
        var ev2 = AlertEvaluator(config: cfg)
        _ = ev2.evaluate(cpuLoad: 0.85, memLoad: nil, now: 1)
        _ = ev2.evaluate(cpuLoad: nil, memLoad: nil, now: 2)   // unavailable resets
        check("unavailable resets streak",
              ev2.evaluate(cpuLoad: 0.85, memLoad: nil, now: 3).isEmpty)
        var ev3 = AlertEvaluator(config: cfg)
        _ = ev3.evaluate(cpuLoad: 0.1, memLoad: 0.95, now: 1)
        _ = ev3.evaluate(cpuLoad: 0.1, memLoad: 0.95, now: 2)
        check("memory fires independently of cpu",
              ev3.evaluate(cpuLoad: 0.1, memLoad: 0.95, now: 3).first?.kind == .memory)
        var ev4 = AlertEvaluator(config: AlertConfig(enabled: false, cpuThreshold: 0.1,
                                 memThreshold: 0.1, sustainTicks: 1, cooldownSeconds: 0))
        check("disabled → no fire even at trivial threshold",
              ev4.evaluate(cpuLoad: 1.0, memLoad: 1.0, now: 1).isEmpty)
    }

    print("SettingsStore — reset to defaults + display toggles (9.6)")
    do {
        let rs = freshStore("selftest.reset")
        rs.processCount = 25
        rs.throughputUnit = .bitsPerSec
        rs.severityThresholds = SeverityThresholds(cpuWarn: 0.1, cpuCritical: 0.2,
                                                   memWarn: 0.3, memCritical: 0.4)
        rs.alertConfig = AlertConfig(enabled: true, cpuThreshold: 0.1, memThreshold: 0.1,
                                     sustainTicks: 2, cooldownSeconds: 10)
        rs.pinnedPids = [1, 2, 3]
        rs.showSparklines = false
        rs.historyWindowSeconds = 240
        rs.compactGlyph = true
        rs.resetToDefaults()
        check("reset restores history window", rs.historyWindowSeconds == 60, "got \(rs.historyWindowSeconds)")
        check("reset restores standard glyph", rs.compactGlyph == false, "got \(rs.compactGlyph)")
        check("reset restores processCount", rs.processCount == 10)
        check("reset restores throughputUnit", rs.throughputUnit == .bytesPerSec)
        check("reset restores thresholds", rs.severityThresholds == .defaults)
        check("reset restores alertConfig", rs.alertConfig == .defaults)
        check("reset clears pins", rs.pinnedPids.isEmpty)
        check("reset restores sparklines toggle", rs.showSparklines)
        // a display toggle loads from its stored value
        let dt = freshStore("selftest.disp") { $0.set(false, forKey: "showSparklines") }
        check("display toggle loads stored false", dt.showSparklines == false)
    }

    print("SettingsStore — pinned pids (8.1)")
    do {
        let suite = "selftest.pins.rt"
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        let s = SettingsStore(defaults: d)
        check("pins start empty", s.pinnedPids.isEmpty)
        s.togglePin(42); s.togglePin(7)
        check("togglePin inserts", s.pinnedPids == [42, 7], "got \(s.pinnedPids)")
        s.togglePin(42)
        check("togglePin removes on second call", s.pinnedPids == [7], "got \(s.pinnedPids)")
        let s2 = SettingsStore(defaults: d)   // reload
        check("pins round-trip through defaults (Int32↔Int)",
              s2.pinnedPids == [7], "got \(s2.pinnedPids)")
    }

    print("GlyphRenderer — battery cell dispatch (7.4)")
    do {
        let r = GlyphRenderer(cells: [.battery])
        var snap = MetricsSnapshot.initial()
        snap.battery = BatterySample(percent: 15, charging: false, charged: false,
                                     onAC: false, minutesRemaining: nil)
        check("battery a11y reflects percent",
              r.accessibilityValue(snapshot: snap) == "Battery 15%",
              "got \(r.accessibilityValue(snapshot: snap))")
        check("battery renderKey encodes a discharging low charge",
              r.renderKey(snapshot: snap).contains("b15"),
              "got \(r.renderKey(snapshot: snap))")
        snap.battery = BatterySample(percent: 80, charging: true, charged: false,
                                     onAC: true, minutesRemaining: 30)
        check("battery a11y shows charging",
              r.accessibilityValue(snapshot: snap).contains("charging"),
              "got \(r.accessibilityValue(snapshot: snap))")
        check("battery renderKey distinguishes charging state",
              r.renderKey(snapshot: snap).contains("b80c"),
              "got \(r.renderKey(snapshot: snap))")
        snap.battery = nil
        check("no battery → a11y says unavailable",
              r.accessibilityValue(snapshot: snap) == "Battery unavailable",
              "got \(r.accessibilityValue(snapshot: snap))")
    }

    print("System facts samplers (7.1 / 7.2)")
    if let ds = DiskSpaceSampler().read() {
        check("disk space: total > 0", ds.totalBytes > 0)
        check("disk space: free <= total", ds.freeBytes <= ds.totalBytes,
              "free \(ds.freeBytes) total \(ds.totalBytes)")
    } else {
        check("disk space sampler returns a value for /", false, "got nil")
    }
    if let la = LoadSampler().read() {
        check("load averages non-negative",
              la.one >= 0 && la.five >= 0 && la.fifteen >= 0, "got \(la)")
        check("uptime is positive", la.uptimeSeconds > 0, "got \(la.uptimeSeconds)")
    } else {
        check("load sampler returns a value", false, "got nil")
    }

    print("GlyphRenderer — compact density (compact-glyph)")
    do {
        let snap = MetricsSnapshot.initial()
        let std = GlyphRenderer(cells: [.cpu, .mem], density: .standard)
        let cmp = GlyphRenderer(cells: [.cpu, .mem], density: .compact)
        let stdW = std.render(snapshot: snap).size.width
        let cmpW = cmp.render(snapshot: snap).size.width
        check("compact glyph is narrower than standard", cmpW < stdW, "compact \(cmpW) standard \(stdW)")
        check("compact glyph is shorter than standard",
              cmp.render(snapshot: snap).size.height < std.render(snapshot: snap).size.height,
              "compact \(cmp.render(snapshot: snap).size.height)")
    }
    let cg = freshStore("selftest.compact") { $0.set(true, forKey: "compactGlyph") }
    check("compact glyph loads stored value", cg.compactGlyph == true, "got \(cg.compactGlyph)")

    print("RingBuffer — adjustable window (9.3)")
    do {
        var rb = RingBuffer(windowSeconds: 60)
        for t in stride(from: 0.0, through: 100.0, by: 10.0) {
            rb.append(HistoryPoint(timestamp: t, value: 0.5))
        }
        // At now=100 with a 60 s window, points ≥40 survive: 40…100 = 7.
        check("60 s window keeps the last 60 s", rb.count == 7, "got \(rb.count)")
        rb.setWindow(30, now: 100)   // cutoff 70 → 70,80,90,100
        check("narrowing trims the stale head", rb.count == 4, "got \(rb.count)")
        rb.setWindow(200, now: 100)  // can't recover dropped points
        check("widening keeps current points (no recovery)", rb.count == 4, "got \(rb.count)")
        // A fresh point now lands within the wider window.
        rb.append(HistoryPoint(timestamp: 110, value: 0.5))
        check("wider window retains a new point", rb.count == 5, "got \(rb.count)")
    }
    let hw = freshStore("selftest.histwin") { $0.set(Double(180), forKey: "historyWindowSeconds") }
    check("history window loads stored value", hw.historyWindowSeconds == 180, "got \(hw.historyWindowSeconds)")

    print("Network per-interface split (7.3)")
    if let nc = try? NetworkSampler().read() {
        let sumIn  = nc.perInterface.values.reduce(UInt64(0)) { $0 &+ $1.inBytes }
        let sumOut = nc.perInterface.values.reduce(UInt64(0)) { $0 &+ $1.outBytes }
        // The split is a subset of the aggregate (a name lookup can drop one),
        // so it must never exceed it.
        check("per-interface in-bytes sum ≤ aggregate", sumIn <= nc.inBytes, "sum \(sumIn) agg \(nc.inBytes)")
        check("per-interface out-bytes sum ≤ aggregate", sumOut <= nc.outBytes, "sum \(sumOut) agg \(nc.outBytes)")
        check("at least one named interface", !nc.perInterface.isEmpty)
    } else {
        check("NetworkSampler reads", false, "threw")
    }
    do {
        let prev = NetCounters(inBytes: 0, outBytes: 0, ifaceSet: ["if1", "if2"], perInterface: [
            "en0":   NetIfaceBytes(inBytes: 0,    outBytes: 0),
            "utun0": NetIfaceBytes(inBytes: 1000, outBytes: 1000),
        ])
        let now = NetCounters(inBytes: 0, outBytes: 0, ifaceSet: ["if1", "if2"], perInterface: [
            "en0":   NetIfaceBytes(inBytes: 1_048_576, outBytes: 0),
            "utun0": NetIfaceBytes(inBytes: 1000, outBytes: 1000),   // unchanged → idle
        ])
        let rates = SamplingCoordinator.perInterfaceRates(prev: prev, now: now, elapsed: 1.0)
        check("per-interface rate computes en0 download",
              rates.contains { $0.name == "en0" && abs($0.inPerSec - 1_048_576) < 1 },
              "got \(rates)")
        check("idle interface is dropped from the split",
              !rates.contains { $0.name == "utun0" }, "got \(rates)")
    }

    print("FrequencyMonitor — DVFS tables validated vs powermetrics (10.1)")
    // Pure helpers first (deterministic).
    let ambiguous = FrequencyMonitor.uniqueByCount([[1000, 2000, 3000, 4000],
                                                    [1100, 2100, 3100, 4100]])  // same count, differ
    check("uniqueByCount drops an ambiguous state count", ambiguous[4] == nil, "got \(ambiguous)")
    let identical = FrequencyMonitor.uniqueByCount([[1344, 1644, 1992, 2304],
                                                    [1344, 1644, 1992, 2304]])  // identical dup
    check("uniqueByCount keeps an identical-duplicate count", identical[4] != nil)
    check("decodeTable rejects a decreasing/out-of-range blob",
          FrequencyMonitor.decodeTable(Data([1, 0, 0, 0, 0, 0, 0, 0]) +
                                       Data(repeating: 0, count: 24)) == nil)
    // Live parse: the tables must reproduce this machine's powermetrics curves —
    // P-cluster 15 states 1344…4380, S-cluster 20 states 1308…4608. (Skips
    // cleanly on a chip where these specific clusters aren't present.)
    let tables = FrequencyMonitor.cpuFrequencyTables()
    if let p = tables.first(where: { $0.count == 15 }) {
        check("P-cluster DVFS table matches powermetrics (1344…4380)",
              abs(p.first! - 1344) < 1 && abs(p.last! - 4380) < 1, "got \(p.first ?? 0)…\(p.last ?? 0)")
    } else { print("  (no 15-state table — not this machine's P-cluster layout)") }
    if let s = tables.first(where: { $0.count == 20 }) {
        check("S-cluster DVFS table matches powermetrics (1308…4608)",
              abs(s.first! - 1308) < 1 && abs(s.last! - 4608) < 1, "got \(s.first ?? 0)…\(s.last ?? 0)")
    } else { print("  (no 20-state table — not this machine's S-cluster layout)") }
    // Live read: any reported cluster frequency must sit in CPU range.
    let fm = FrequencyMonitor()
    if fm.isAvailable {
        _ = fm.read()                                   // baseline
        Thread.sleep(forTimeInterval: 0.3)
        if let freqs = fm.read() {
            check("live cluster frequencies are in 200…6000 MHz",
                  freqs.allSatisfy { $0.mhz >= 200 && $0.mhz <= 6000 }, "got \(freqs)")
        } else { print("  (live read nil — clusters idle in window; not a failure)") }
    } else { print("  (FrequencyMonitor unavailable here — skipping live read)") }

    print(failures == 0 ? "\nALL PASS" : "\n\(failures) FAILURE(S)")
    return failures == 0 ? 0 : 1
}

import Foundation
import AppKit

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

    print("Process power segment — per-process watts")
    do {
        // Sub-watt is the common case, so a column that printed "0.0 W" for
        // everything would rank rows the reader cannot tell apart.
        check("sub-watt reads in milliwatts",
              PanelRootView.formatWatts(0.112) == "112mW",
              "got \(PanelRootView.formatWatts(0.112))")
        check("a tiny draw is still distinguishable from zero",
              PanelRootView.formatWatts(0.002) != PanelRootView.formatWatts(0),
              "both render as \(PanelRootView.formatWatts(0))")
        check("a watt or more reads in watts",
              PanelRootView.formatWatts(3.5) == "3.50W",
              "got \(PanelRootView.formatWatts(3.5))")

        // The width must grow with the segment count. It was a ternary on one
        // availability flag, which a fifth segment makes wrong (review S3).
        let four = PanelRootView.pickerWidth(segments: 4)
        let five = PanelRootView.pickerWidth(segments: 5)
        check("the picker widens for a fifth segment", five > four,
              "4 segments \(four) pt, 5 segments \(five) pt")
        check("the picker still fits inside the 360 pt panel beside a search field",
              five <= 200, "\(five) pt leaves nothing for the search field")

        // Watts must survive the raw path, the same wiring a revert to RSS
        // once broke silently for memory.
        let raw = ProcRaw(pid: 9, ppid: 0, name: "p", cpuTimeNs: 0,
                          residentBytes: 1, footprintBytes: 1, diskBytes: 0,
                          energyNanojoules: 0)
        check("ProcSample(raw:) carries watts through",
              ProcSample(raw: raw, cpu: 0, diskBps: 0, netBps: 0, watts: 0.25).watts == 0.25)
        check("watts defaults to zero rather than nil-ing the row",
              ProcSample(raw: raw, cpu: 0, diskBps: 0, netBps: 0).watts == 0)

        check("pwr is a real sort option", SettingsStore.ProcSort.allCases.contains(.pwr))
        check("every sort option has a short segment label",
              SettingsStore.ProcSort.allCases.allSatisfy { $0.segmentLabel.count <= 4 },
              "a long label will not fit 31 pt")
    }

    print("SettingsStore — expanded metric sections")
    do {
        let suite = "selftest.expanded.rt"
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        let s = SettingsStore(defaults: d)
        check("every section starts collapsed", s.expandedSections.isEmpty,
              "collapsed is the state the panel ships in, so empty is correct")
        s.toggleSection(.mem)
        check("toggleSection expands", s.expandedSections == [.mem], "got \(s.expandedSections)")
        s.toggleSection(.cpu)
        s.toggleSection(.mem)
        check("toggleSection collapses on the second call",
              s.expandedSections == [.cpu], "got \(s.expandedSections)")
        let reloaded = SettingsStore(defaults: d)
        check("expansion round-trips through defaults",
              reloaded.expandedSections == [.cpu], "got \(reloaded.expandedSections)")
        // A section removed in a later build must not come back as a phantom.
        // The junk sits beside .mem, never beside .cpu: a first version of
        // this paired it with .cpu, and a mutation that defaulted junk to .cpu
        // produced the same set, so the guard could not fail.
        d.set(["mem", "notASection"], forKey: "expandedSections")
        let withJunk = SettingsStore(defaults: d)
        check("an unknown stored section is dropped, not defaulted",
              withJunk.expandedSections == [.mem], "got \(withJunk.expandedSections)")
        d.set(["notASection"], forKey: "expandedSections")
        check("junk alone leaves everything collapsed",
              SettingsStore(defaults: d).expandedSections.isEmpty,
              "got \(SettingsStore(defaults: d).expandedSections)")
        withJunk.resetToDefaults()
        check("reset collapses everything", withJunk.expandedSections.isEmpty,
              "got \(withJunk.expandedSections)")
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

    // ---- Per-metric sample clock (docs/12-parity-baseline.md #6) ----------
    // The reopen spike: NET/DISK counters go stale while the panel is closed,
    // but the shared tick clock keeps advancing, so their bytes-since-close
    // got divided by one tick. Measured 10741 MB/s disk against a true 0.5.
    print("SampleClock — a metric's rate divides by ITS own interval")
    do {
        let gm = 2.0
        var c = RateMath.SampleClock()
        check("first read has no baseline", !c.hasBaseline)
        check("first read is a gap", c.evaluate(now: 100, cadence: 1, gapMultiplier: gm).isGap)

        c.stamp(now: 100, cadence: 1)
        check("baseline recorded", c.hasBaseline)
        let steady = c.evaluate(now: 101, cadence: 1, gapMultiplier: gm)
        check("steady 1 s tick is not a gap", !steady.isGap)
        check("…and reports its own elapsed", abs(steady.elapsed - 1.0) < 0.001,
              "got \(steady.elapsed)")

        // The reopen case. The panel closed at t=100 and reopened at t=400.
        // Five minutes of bytes must never be divided by one tick.
        let reopen = c.evaluate(now: 400, cadence: 1, gapMultiplier: gm)
        check("300 s since this metric was last read IS a gap", reopen.isGap,
              "elapsed \(reopen.elapsed)")
        check("…and elapsed is the real 300 s, not one tick",
              abs(reopen.elapsed - 300.0) < 0.001, "got \(reopen.elapsed)")

        // A cadence change must not misread a healthy old-cadence interval
        // as a gap — the FB-2/FB-4 case, now per metric.
        var d = RateMath.SampleClock()
        d.stamp(now: 0, cadence: 5)
        check("5 s interval judged against the cadence it accrued under",
              !d.evaluate(now: 5, cadence: 1, gapMultiplier: gm).isGap)

        var e = RateMath.SampleClock()
        e.stamp(now: 0, cadence: 1)
        e.reset()
        check("reset drops the baseline", !e.hasBaseline)
        check("…so the next read only re-baselines",
              e.evaluate(now: 1, cadence: 1, gapMultiplier: gm).isGap)

        // Time going backwards (clock step) must not produce a rate.
        var f = RateMath.SampleClock()
        f.stamp(now: 500, cadence: 1)
        check("non-advancing clock is a gap, never a negative elapsed",
              f.evaluate(now: 499, cadence: 1, gapMultiplier: gm).isGap)
    }

    // ---- Process tree roll-up (docs/12-parity-baseline.md #12) ------------
    print("Process grouping — a tree reads as one consumer")
    do {
        func p(_ pid: Int32, _ ppid: Int32, _ name: String, _ mem: UInt64,
               _ cpu: Double = 0) -> ProcSample {
            ProcSample(pid: pid, ppid: ppid, name: name, cpu: cpu,
                       memBytes: mem, diskBps: 0, netBps: 0)
        }
        // The shape that motivated this: one browser, three helpers, each
        // helper smaller than an unrelated process that should not outrank
        // the tree.
        let chrome = [p(100, 1, "Google Chrome", 500 << 20, 0.1),
                      p(101, 100, "Chrome Helper", 240 << 20, 0.2),
                      p(102, 100, "Chrome Helper", 240 << 20, 0.2),
                      p(103, 101, "Chrome Renderer", 240 << 20, 0.1)]
        let other = [p(200, 1, "qbittorrent", 600 << 20, 0.05)]
        let groups = ProcGroup.group(chrome + other)

        check("one group per tree", groups.count == 2, "got \(groups.count)")
        if let g = groups.first(where: { $0.name == "Google Chrome" }),
           let q = groups.first(where: { $0.name == "qbittorrent" }) {
            check("a grandchild rolls up to the root", g.count == 4, "got \(g.count)")
            check("group memory is the sum", g.memBytes == UInt64(1220) << 20,
                  "got \(g.memBytes >> 20) MB")
            check("group cpu is the sum", abs(g.cpu - 0.6) < 0.0001, "got \(g.cpu)")
            check("the tree outranks a bigger single process", g.memBytes > q.memBytes,
                  "\(g.memBytes >> 20) vs \(q.memBytes >> 20) MB")
            check("largest child first", g.members.first?.pid == 100)
        } else {
            check("both expected groups exist", false)
        }

        // A process whose parent the sampler cannot see is its own root. This
        // is the common case, not an edge one: 321 of 941 pids are invisible.
        let orphan = ProcGroup.group([p(300, 999, "node", 100 << 20)])
        check("invisible parent means the process is its own root",
              orphan.count == 1 && orphan[0].root.pid == 300)

        // Roots stop below launchd rather than collapsing the machine into
        // one group. launchd MUST be in the fixture: without it the walk
        // stops because byPid[1] is missing, not because pid 1 is excluded,
        // and the assertion passes while testing nothing. Mutating the bound
        // from `parent > 1` to `parent > 0` left the old fixture green.
        let withLaunchd = ProcGroup.group([p(1, 0, "launchd", 1),
                                           p(10, 1, "a", 2), p(20, 1, "b", 3)])
        check("launchd is present in the fixture, so the bound is what stops the walk",
              withLaunchd.contains { $0.root.pid == 1 })
        check("pid 1 does not absorb its children",
              withLaunchd.count == 3, "got \(withLaunchd.count) groups")
        check("a child of launchd is its own root",
              withLaunchd.first { $0.root.pid == 10 }?.count == 1)
        check("launchd's own group holds only launchd",
              withLaunchd.first { $0.root.pid == 1 }?.count == 1)

        // A parent cycle must terminate rather than hang the open tier.
        let cycle = ProcGroup.group([p(50, 51, "x", 1), p(51, 50, "y", 1)])
        check("a ppid cycle terminates and keeps both processes",
              cycle.reduce(0) { $0 + $1.count } == 2,
              "got \(cycle.reduce(0) { $0 + $1.count })")
        check("self-parenting terminates",
              ProcGroup.group([p(60, 60, "z", 1)]).count == 1)
        check("empty input yields no groups", ProcGroup.group([]).isEmpty)

        // Live: grouping must not lose or duplicate a process.
        if let raws = try? ProcessSampler().read(), !raws.isEmpty {
            let live = raws.map { ProcSample(raw: $0, cpu: 0, diskBps: 0, netBps: 0) }
            let lg = ProcGroup.group(live)
            let total = lg.reduce(0) { $0 + $1.count }
            check("grouping is lossless across the live process table",
                  total == live.count, "\(total) of \(live.count)")
            let withParents = live.filter { $0.ppid > 1 }.count
            check("the live table actually has trees to roll up",
                  withParents > 0, "\(withParents) processes have a visible parent")
            if let big = lg.max(by: { $0.memBytes < $1.memBytes }) {
                print("  largest live tree: \(big.name) \(big.memBytes >> 20) MB across \(big.count)")
            }
        }
    }

    // ---- Glyph fits a notched menu bar (docs/12-parity-baseline.md #9) ----
    print("Glyph width against a notched laptop's status-item strip")
    do {
        // Measured on the 14" built-in: auxiliaryTopRightArea is 664 pt, and
        // ~15 other menu-bar apps share it. A third of the strip is already
        // generous for one monitor.
        let strip: CGFloat = 664
        let budget = strip / 3
        let snap = MetricsSnapshot.initial()

        func width(_ cells: [BarCell], _ d: GlyphDensity) -> CGFloat {
            GlyphRenderer(cells: cells, activityArrows: true,
                          throughputUnit: .bytesPerSec, thresholds: .defaults,
                          density: d).totalWidth(snapshot: snap)
        }

        let narrow = width(SettingsStore.defaultNarrowBarCells, .compact)
        check("narrow profile fits a third of the strip",
              narrow <= budget,
              String(format: "%.0f pt of a %.0f pt budget", narrow, budget))
        print(String(format: "  narrow profile %.0f pt = %.0f%% of the 664 pt strip",
                     narrow, narrow / strip * 100))

        // The configuration that prompted this: four cells at standard
        // density. It must still be MEASURED as too wide, otherwise the
        // budget above is meaningless and would pass anything.
        let full = width([.cpu, .mem, .net, .disk], .standard)
        check("the four-cell standard glyph really is too wide for the strip",
              full > budget,
              String(format: "%.0f pt", full))
        print(String(format: "  four-cell standard %.0f pt = %.0f%% of the strip",
                     full, full / strip * 100))
        check("narrow profile is materially narrower than the full one",
              narrow < full / 2, String(format: "%.0f vs %.0f", narrow, full))

        // Padding must not creep back: it is charged on top of the padding
        // NSStatusBarButton already applies.
        check("compact padding stays lean",
              GlyphDensity.compact.leftPad + GlyphDensity.compact.rightPad <= 8,
              "got \(GlyphDensity.compact.leftPad + GlyphDensity.compact.rightPad)")

        // Width stability is the property the reserved columns exist for and
        // the one most at risk from narrowing. A status item that changes
        // width shifts every neighbour on every tick.
        //
        // The first version of this varied only NET and DISK, so it passed
        // while the compute cells grew 7 pt at 100% — the reserved width was
        // "00%", not "100%". Vary EVERY cell across its full range, and walk
        // the percentages rather than sampling two of them.
        func loaded(_ frac: Double, _ inBps: Double, _ outBps: Double) -> MetricsSnapshot {
            var s = MetricsSnapshot.initial()
            s.cpu = .ok(CPUSample(overall: frac, perCore: []))
            s.memory = .ok(MemorySample(usedBytes: UInt64(frac * 64_000_000_000),
                                        totalBytes: 64_000_000_000,
                                        swapUsedBytes: 0, pressure: .normal,
                                        severity: .normal, reclaim: nil,
                                       pools: MemoryPools(appBytes: 0, wiredBytes: 0, compressedBytes: 0, cachedFilesBytes: 0, freeBytes: 0)))
            s.net = .ok(Throughput(inPerSec: inBps, outPerSec: outBps))
            s.disk = .ok(Throughput(inPerSec: outBps, outPerSec: inBps))
            return s
        }
        for cells in [[BarCell.cpu, .mem], [.cpu, .mem, .net, .disk], [.cpu, .mem, .net, .disk, .battery]] {
            for density in [GlyphDensity.standard, .compact] {
                let r = GlyphRenderer(cells: cells, activityArrows: true,
                                      throughputUnit: .bytesPerSec,
                                      thresholds: .defaults, density: density)
                let reference = r.totalWidth(snapshot: loaded(0, 0, 0))
                var widest = reference
                var culprit = "none"
                // Every whole percent, plus throughput spanning bytes to GB.
                for pct in 0...100 {
                    let f = Double(pct) / 100.0
                    for bps in [0.0, 1, 999, 1024, 1_048_576, 999_000_000, 9_999_999_999] {
                        let w = r.totalWidth(snapshot: loaded(f, bps, bps / 3))
                        if w > widest { widest = w; culprit = "\(pct)% at \(Int(bps)) B/s" }
                    }
                }
                check("width is constant across every load and rate (\(cells.count) cells, \(density.valuePt == 11 ? "standard" : "compact"))",
                      widest == reference,
                      String(format: "grew %.0f -> %.0f pt at %@", reference, widest, culprit))
            }
        }
        // The specific regression: a cell at 100% must not be wider than one
        // at 0%, which is what "00%" as the reserved string got wrong.
        let pctRenderer = GlyphRenderer(cells: [.cpu, .mem], activityArrows: true,
                                        throughputUnit: .bytesPerSec, thresholds: .defaults,
                                        density: .standard)
        check("100% is not wider than 0% (reserved string is \"100%\", not \"00%\")",
              pctRenderer.totalWidth(snapshot: loaded(1.0, 0, 0))
                == pctRenderer.totalWidth(snapshot: loaded(0.0, 0, 0)),
              String(format: "%.0f vs %.0f",
                     pctRenderer.totalWidth(snapshot: loaded(1.0, 0, 0)),
                     pctRenderer.totalWidth(snapshot: loaded(0.0, 0, 0))))
    }

    print("Menu-bar room classification")
    do {
        // No screen: the safe default is roomy, because shrinking a glyph
        // nobody asked to shrink is the worse error.
        check("nil screen classifies as roomy", !MenuBarRoom.classify(nil).isNarrow)

        // screenFor falls back when window.screen is nil. Confirmed in the
        // running app that it is normally set, but a status-item window that
        // has not been laid out reports nil, so the fallbacks must hold.
        check("no window at all still yields a screen",
              MenuBarRoom.screenFor(window: nil) != nil || NSScreen.screens.isEmpty)
        if let first = NSScreen.screens.first {
            let w = NSWindow(contentRect: NSRect(x: first.frame.midX, y: first.frame.midY,
                                                 width: 20, height: 20),
                             styleMask: [.borderless], backing: .buffered, defer: true)
            let resolved = MenuBarRoom.screenFor(window: w)
            check("a window's midpoint picks the screen containing it",
                  resolved?.localizedName == first.localizedName,
                  "got \(resolved?.localizedName ?? "nil"), wanted \(first.localizedName)")
        }
        for s in NSScreen.screens {
            let r = MenuBarRoom.classify(s)
            let notched = s.safeAreaInsets.top > 0
            check("\(s.localizedName) classified by its notch, not its size",
                  r.isNarrow == notched,
                  "insets.top \(s.safeAreaInsets.top), narrow \(r.isNarrow)")
            print(String(format: "  %@: %@ %.0f pt", s.localizedName,
                         r.isNarrow ? "narrow" : "roomy", r.statusItemWidth))
        }
    }

    print("Self memory footprint metric (perf finding #3)")
    let fp = currentProcessFootprintBytes()
    print("  self phys_footprint = \(fp / 1_048_576) MB (Activity Monitor 'Memory'; cf. RSS, which is larger)")
    check("self footprint readable + sane (1 MB … 4 GB)",
          fp > 1_048_576 && fp < 4_294_967_296, "got \(fp) bytes")

    // ---- Memory severity fires on reclaim, not on percent used -------------
    // The trigger these pin: 71% while thrashing must not read calm, and 90%
    // with no reclaim must not read alarming. Ordinary operation on the dev
    // machine measured exactly 0.0 stall pages/sec over 30 s, so any sustained
    // fault-back is already abnormal.
    print("Memory severity — reclaim evidence, not percent used")
    do {
        func sev(_ pressure: MemoryPressure, stall: Double, evict: Double = 0) -> MemorySeverity {
            RateMath.memorySeverity(
                pressure: pressure,
                reclaim: ReclaimRate(stallPagesPerSec: stall, evictPagesPerSec: evict))
        }

        check("first sample has no rate, so the kernel alone decides",
              RateMath.memorySeverity(pressure: .normal, reclaim: nil) == .normal)
        check("a quiet machine is calm", sev(.normal, stall: 0) == .normal)
        check("sustained fault-back warns while the kernel is still normal",
              sev(.normal, stall: 200) == .warn,
              "this is the 71%-while-thrashing case the old percent trigger read as calm")
        check("heavy fault-back is critical", sev(.normal, stall: 5000) == .critical)

        // The kernel level is a floor. Both directions, because a one-way
        // guard passes while the other direction is broken.
        check("kernel warn raises a quiet reading", sev(.warn, stall: 0) == .warn)
        check("kernel critical raises a quiet reading", sev(.critical, stall: 0) == .critical)
        check("a quiet kernel cannot lower a bad rate", sev(.normal, stall: 5000) == .critical)
        check("kernel warn cannot lower a critical rate", sev(.warn, stall: 5000) == .critical)

        // Eviction is the OS working as designed; only fault-back costs time.
        check("eviction alone never raises severity",
              sev(.normal, stall: 0, evict: 100_000) == .normal,
              "compressions without decompressions is the compressor doing its job")

        // The whole point: severity must not track the fraction.
        let page: UInt64 = 16384
        func sample(usedPages: UInt64, stall: Double) -> MemorySample {
            let raw = MemoryRaw(
                activeBytes: 0, wiredBytes: 0, compressedBytes: 0,
                freeBytes: 0, inactiveBytes: 0,
                internalBytes: usedPages * page, externalBytes: 0, purgeableBytes: 0,
                speculativeBytes: 0, physicalTotalBytes: 100 * page, swapUsedBytes: 0,
                compressions: 0, decompressions: 0, swapins: 0, swapouts: 0)
            return raw.toSample(
                pressure: .normal,
                reclaim: ReclaimRate(stallPagesPerSec: stall, evictPagesPerSec: 0))
        }
        let thrashingAt71 = sample(usedPages: 71, stall: 200)
        let calmAt90 = sample(usedPages: 90, stall: 0)
        check("71% while thrashing is not calm", thrashingAt71.severity == .warn,
              "got \(thrashingAt71.severity)")
        check("90% with no reclaim is calm", calmAt90.severity == .normal,
              "got \(calmAt90.severity)")
        check("…and the fraction really is the wrong way round in that pair",
              Double(thrashingAt71.usedBytes) < Double(calmAt90.usedBytes),
              "the fixture cannot detect a percent-driven revert")
        check("toSample carries severity through, not a hardcoded normal",
              sample(usedPages: 10, stall: 5000).severity == .critical)
        check("reclaim rate survives onto the sample",
              thrashingAt71.reclaim?.stallPagesPerSec == 200)

        // The glyph is the always-visible light, so it must key on the same
        // evidence as the panel. It recomputed severity from percent used
        // until 2026-09-06, which left the menu bar carrying the bug the
        // panel had just been fixed for.
        func snapWithMemory(_ s: MemorySample) -> MetricsSnapshot {
            var snap = MetricsSnapshot.initial()
            snap.memory = .ok(s)
            return snap
        }
        let glyph = GlyphRenderer(cells: [.mem])
        let quiet = snapWithMemory(sample(usedPages: 40, stall: 0))
        let thrashing = snapWithMemory(sample(usedPages: 40, stall: 5000))
        check("glyph severity follows reclaim, at an identical percentage",
              glyph.renderKey(snapshot: quiet) != glyph.renderKey(snapshot: thrashing),
              "both keys are \(glyph.renderKey(snapshot: quiet)), so the glyph is still percent-driven")
        // The key is "m<state><pct>|<barfill>|<severity>", so everything
        // before the last separator is the percent-driven half. If that
        // differed, the pair would prove nothing about severity.
        func keyWithoutSeverity(_ k: String) -> String {
            k.split(separator: "|").dropLast().joined(separator: "|")
        }
        check("…and the percent-driven half really is identical in that pair",
              keyWithoutSeverity(glyph.renderKey(snapshot: quiet))
                  == keyWithoutSeverity(glyph.renderKey(snapshot: thrashing)),
              "the fixture varies the percent too, so it cannot detect a revert")
        check("glyph reads critical off the sample",
              glyph.renderKey(snapshot: thrashing).contains("critical"),
              "got \(glyph.renderKey(snapshot: thrashing))")

        // Pools are carried on the sample rather than recomputed in the view,
        // so this pins the wiring. The formulas themselves are pinned by the
        // "System memory formula" section below.
        let poolRaw = MemoryRaw(
            activeBytes: 0, wiredBytes: 10 * page, compressedBytes: 5 * page,
            freeBytes: 20 * page, inactiveBytes: 0,
            internalBytes: 140 * page, externalBytes: 60 * page, purgeableBytes: 10 * page,
            speculativeBytes: 8 * page, physicalTotalBytes: 200 * page, swapUsedBytes: 0,
            compressions: 0, decompressions: 0, swapins: 0, swapouts: 0)
        let pooled = poolRaw.toSample(pressure: .normal, reclaim: nil).pools
        check("pool app is the app-memory formula, not internal",
              pooled.appBytes == poolRaw.appBytes && pooled.appBytes == 130 * page,
              "got \(pooled.appBytes / page) pages")
        check("pool cached is external + purgeable", pooled.cachedFilesBytes == 70 * page)
        check("pool free excludes speculative", pooled.freeBytes == 12 * page)
        check("pool wired and compressed pass through",
              pooled.wiredBytes == 10 * page && pooled.compressedBytes == 5 * page)

        // Cumulative page counters wrap the same way byte counters do.
        check("page rate over a normal delta",
              RateMath.pagesPerSec(prev: 100, now: 300, elapsed: 2) == 100)
        check("a backwards page counter re-baselines",
              RateMath.pagesPerSec(prev: 300, now: 100, elapsed: 2) == nil)
        check("zero elapsed re-baselines",
              RateMath.pagesPerSec(prev: 100, now: 300, elapsed: 0) == nil)
    }

    // ---- System memory formula (docs/12-parity-baseline.md #3) -------------
    // These fail if usedBytes reverts to active+wired+compressed.
    print("System memory formula — app memory, not page queues")
    do {
        // A machine where active and internal diverge, which is every real
        // one: half the active queue is file cache, and a third of app memory
        // has aged onto the inactive queue.
        let page: UInt64 = 16384
        let raw = MemoryRaw(
            activeBytes:      100 * page,
            wiredBytes:        10 * page,
            compressedBytes:    5 * page,
            freeBytes:         20 * page,
            inactiveBytes:     92 * page,
            internalBytes:    140 * page,   // app pages, some of them inactive
            externalBytes:     60 * page,
            purgeableBytes:    10 * page,
            speculativeBytes:   8 * page,
            physicalTotalBytes: 200 * page,
            swapUsedBytes: 0,
            compressions: 0, decompressions: 0, swapins: 0, swapouts: 0
        )
        check("app memory = internal − purgeable",
              raw.appBytes == 130 * page, "got \(raw.appBytes / page) pages")
        check("used = app + wired + compressed (NOT active-based)",
              raw.usedBytes == 145 * page, "got \(raw.usedBytes / page) pages")
        check("used differs from the old active-based formula",
              raw.usedBytes != raw.activeBytes + raw.wiredBytes + raw.compressedBytes,
              "the two formulas agree, so this fixture cannot detect a revert")
        check("cached files = external + purgeable",
              raw.cachedFilesBytes == 70 * page, "got \(raw.cachedFilesBytes / page) pages")
        check("truly free excludes speculative",
              raw.trulyFreeBytes == 12 * page, "got \(raw.trulyFreeBytes / page) pages")

        // Underflow guards: purgeable > internal and speculative > free are
        // not reachable on a healthy kernel, but the subtraction is unsigned.
        let odd = MemoryRaw(
            activeBytes: 0, wiredBytes: 0, compressedBytes: 0, freeBytes: 1 * page,
            inactiveBytes: 0,
            internalBytes: 1 * page, externalBytes: 0, purgeableBytes: 9 * page,
            speculativeBytes: 9 * page, physicalTotalBytes: 10 * page, swapUsedBytes: 0,
            compressions: 0, decompressions: 0, swapins: 0, swapouts: 0)
        check("purgeable > internal clamps to 0, no unsigned wrap", odd.appBytes == 0)
        check("speculative > free clamps to 0, no unsigned wrap", odd.trulyFreeBytes == 0)
    }

    // ---- Live memory identity (docs/12-parity-baseline.md) -----------------
    // XNU's own invariant. If it stops holding, the field meanings moved and
    // the formula above is reading the wrong counters.
    do {
        let live = try? MemorySampler().read()
        if let m = live {
            let lhs = m.activeBytes + m.inactiveBytes + m.speculativeBytes
            let rhs = m.internalBytes + m.externalBytes
            // Sampled a moment apart from the kernel's own update, so allow a
            // small drift rather than demanding equality.
            let drift = lhs > rhs ? lhs - rhs : rhs - lhs
            check("active+inactive+speculative ≈ internal+external",
                  drift < m.physicalTotalBytes / 100,
                  "drift \(drift / 1_048_576) MB")
            check("live app memory ≤ live used", m.appBytes <= m.usedBytes)
            check("live used ≤ physical total", m.usedBytes <= m.physicalTotalBytes,
                  "used \(m.usedBytes / 1_048_576) MB of \(m.physicalTotalBytes / 1_048_576) MB")
            // The expanded breakdown draws these five as one composition, so
            // they must be disjoint claims on real RAM. A synthetic fixture
            // cannot test this: the app-memory fixture spends the whole
            // physical total on internal+external by design.
            let p = m.toSample(pressure: .normal, reclaim: nil).pools
            let bandSum = p.appBytes + p.wiredBytes + p.compressedBytes
                + p.cachedFilesBytes + p.freeBytes
            check("the five pool bands do not sum past real RAM",
                  bandSum <= m.physicalTotalBytes,
                  "bands \(bandSum / 1_048_576) MB of \(m.physicalTotalBytes / 1_048_576) MB, so a band double-counts")
            print("  live pools sum = \(bandSum / 1_048_576) MB of \(m.physicalTotalBytes / 1_048_576) MB")
            print("  live used = \(m.usedBytes / 1_048_576) MB, cached files = \(m.cachedFilesBytes / 1_048_576) MB")
        } else {
            print("  (MemorySampler unavailable here — skipping live identity)")
        }
    }

    // ---- Per-process memory picks footprint (docs/12-parity-baseline.md #2)
    print("Per-process memory — footprint with an RSS fallback")
    do {
        let both = ProcRaw(pid: 1, ppid: 0, name: "x", cpuTimeNs: 0,
                           residentBytes: 900, footprintBytes: 300, diskBytes: 0,
                           energyNanojoules: 0)
        check("footprint wins when readable", both.displayMemoryBytes == 300,
              "got \(both.displayMemoryBytes)")
        check("…and is NOT the resident size", both.displayMemoryBytes != both.residentBytes)
        let denied = ProcRaw(pid: 2, ppid: 0, name: "y", cpuTimeNs: 0,
                             residentBytes: 900, footprintBytes: 0, diskBytes: 0,
                             energyNanojoules: 0)
        check("RSS fallback when rusage was denied", denied.displayMemoryBytes == 900,
              "got \(denied.displayMemoryBytes)")

        // The wiring, not just the helper. Reverting the coordinator's call
        // site to raw.residentBytes once left the whole suite green while the
        // UI showed RSS again, so the sample the coordinator actually builds
        // is asserted here.
        let wired = ProcSample(raw: both, cpu: 0.5, diskBps: 1, netBps: 2)
        check("ProcSample(raw:) carries footprint, not RSS",
              wired.memBytes == 300, "got \(wired.memBytes)")
        let wiredDenied = ProcSample(raw: denied, cpu: 0, diskBps: 0, netBps: 0)
        check("ProcSample(raw:) falls back to RSS when denied",
              wiredDenied.memBytes == 900, "got \(wiredDenied.memBytes)")
        check("ProcSample(raw:) copies pid/name through",
              wired.pid == 1 && wired.name == "x")

        // Live: every pid the sampler can see should also yield a footprint,
        // which is the measured claim the RSS decision was reversed on.
        if let procs = try? ProcessSampler().read(), !procs.isEmpty {
            let withFootprint = procs.filter { $0.footprintBytes > 0 }.count
            check("footprint readable for every visible pid",
                  withFootprint == procs.count,
                  "\(withFootprint) of \(procs.count)")
            // The power segment's whole premise: ri_energy_nj is readable
            // without root, off the rusage call already being made.
            let withEnergy = procs.filter { $0.energyNanojoules > 0 }.count
            check("energy readable for nearly every visible pid",
                  Double(withEnergy) / Double(procs.count) > 0.9,
                  "\(withEnergy) of \(procs.count), so per-process watts would be mostly blank")
            print("  \(withEnergy) of \(procs.count) pids report an energy counter")
            let selfPid = ProcessInfo.processInfo.processIdentifier
            if let me = procs.first(where: { $0.pid == selfPid }) {
                // Same quantity from two APIs, sampled microseconds apart.
                let a = me.footprintBytes, b = currentProcessFootprintBytes()
                let d = a > b ? a - b : b - a
                check("sampler footprint agrees with the self-cost reader",
                      d < 8 * 1_048_576, "sampler \(a / 1_048_576) MB vs self \(b / 1_048_576) MB")
            }
            print("  \(procs.count) visible pids; \(withFootprint) reported a footprint")
        } else {
            print("  (ProcessSampler unavailable here — skipping live footprint)")
        }
    }

    print(failures == 0 ? "\nALL PASS" : "\n\(failures) FAILURE(S)")
    return failures == 0 ? 0 : 1
}

import Foundation

// Phase-1 verification harness. Invoked when the binary is launched with
// `--probe` (see main.swift). Runs the CPU, memory, and disk samplers a
// handful of times, prints readable summaries to stdout, then exits before
// NSApplication starts. This is what produces the "believable values + disk
// verdict" halt-point evidence for Phase 1 (docs/03-implementation.md §10).
//
// Deliberately uses plain `print` rather than `os.Logger` because the probe
// is run interactively from a terminal; the live app uses unified logging.

@MainActor
func runProbe() {
    print("sys-monitor — Phase-1 probe")
    print(String(repeating: "─", count: 56))

    let cpu = CPUSampler()
    let mem = MemorySampler()
    let disk = DiskSampler()

    // Warm-up CPU read establishes the baseline; rates appear from sample
    // #2 onward (FR-16 baseline contract in miniature). Wall-clock Δt is
    // measured for every interval — never assumed to be 1.0s — to satisfy
    // the RateMath measured-elapsed invariant.
    var prevCpu: CPUCounters
    var prevTime: TimeInterval
    do {
        prevCpu = try cpu.read()
        prevTime = monoSeconds()
        print("[cpu] baseline established  cores=\(prevCpu.perCore.count)")
    } catch {
        print("[cpu] FAILED at baseline: \(error)")
        return
    }

    let ticks = 5
    print("[probe] sampling \(ticks) ticks at ~1s …")
    for i in 1...ticks {
        Thread.sleep(forTimeInterval: 1.0)
        do {
            let nowCpu = try cpu.read()
            let nowTime = monoSeconds()
            let elapsed = nowTime - prevTime
            let overall = RateMath.cpuUtilization(prev: prevCpu.overall, now: nowCpu.overall)
            let perCore = RateMath.cpuPerCore(prev: prevCpu.perCore, now: nowCpu.perCore)
            let raw = try mem.read()
            let usedGB  = Double(raw.usedBytes)          / 1_073_741_824
            let totalGB = Double(raw.physicalTotalBytes) / 1_073_741_824
            let swapGB  = Double(raw.swapUsedBytes)      / 1_073_741_824

            print(String(
                format: "[%d/%d Δt=%.2fs]  CPU %.1f%%  cores=[%@]  MEM %.2f/%.2f GB  swap %.2f GB",
                i, ticks, elapsed,
                overall * 100,
                perCore.map { String(format: "%.0f", $0 * 100) }.joined(separator: " "),
                usedGB, totalGB, swapGB
            ))

            prevCpu = nowCpu
            prevTime = nowTime
        } catch {
            print("[\(i)/\(ticks)] sample failed: \(error)")
        }
    }

    // -- Disk spike (N8 gate) -------------------------------------------------
    print(String(repeating: "─", count: 56))
    print("[disk] IOKit IOBlockStorageDriver spike")
    do {
        let a = try disk.read()
        Thread.sleep(forTimeInterval: 1.0)
        let b = try disk.read()
        let elapsed = 1.0
        let readBps  = RateMath.bytesPerSec(prev: a.readBytes,  now: b.readBytes,  elapsed: elapsed) ?? -1
        let writeBps = RateMath.bytesPerSec(prev: a.writeBytes, now: b.writeBytes, elapsed: elapsed) ?? -1
        print(String(
            format: "[disk] drivers=%d  cum_read=%.2f GB  cum_write=%.2f GB  Δ1s read=%@/s  write=%@/s",
            a.driverCount,
            Double(a.readBytes)  / 1_073_741_824,
            Double(a.writeBytes) / 1_073_741_824,
            formatBytes(readBps), formatBytes(writeBps)
        ))
        // Heuristic verdict: any drivers + any nonzero cumulative bytes →
        // plausible. Final commit is a user judgment, recorded in
        // docs/ when we sign off Phase 1.
        let plausible = a.driverCount > 0 && (a.readBytes > 0 || a.writeBytes > 0)
        print("[disk] verdict: \(plausible ? "PLAUSIBLE — commit disk row" : "SUSPICIOUS — investigate or demote per N8")")
    } catch {
        print("[disk] UNAVAILABLE: \(error)")
        print("[disk] verdict: DEMOTE to v2 per N8 (sampler will report .unavailable, NetDiskRow hides disk)")
    }

    print(String(repeating: "─", count: 56))
    print("probe done")
}

private func formatBytes(_ bps: Double) -> String {
    if bps < 0 { return "—" }
    if bps >= 1_048_576 { return String(format: "%.2f MB", bps / 1_048_576) }
    if bps >= 1_024     { return String(format: "%.2f KB", bps / 1_024) }
    return String(format: "%.0f B", bps)
}

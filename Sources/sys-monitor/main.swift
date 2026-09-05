import AppKit

// sys-monitor — entry point.
//
// Modes:
//   • `--self-test` → run the boundary-check suite (RateMath / formatBps) and
//                     exit 0 on pass, 1 on failure. The regression net for the
//                     math classes that shipped real bugs; replaces an XCTest
//                     target (XCTest needs full Xcode, not Command Line Tools).
//   • `--probe`     → run the Phase-1 sampler verification harness and exit.
//   • default       → start the menu-bar app (NSApplication).
//
// Manual NSApplication bootstrap rather than @main because the SPM executable
// target needs LSUIElement = YES to suppress the Dock icon, and that lives in
// the Info.plist shipped inside the .app bundle (assembled by build.sh).
//
// `MainActor.assumeIsolated` is a no-op at runtime — AppKit drives this whole
// process on the main thread — but it satisfies Swift's strict concurrency
// checker for the @MainActor-isolated AppDelegate.init() and runProbe().

MainActor.assumeIsolated {
    if CommandLine.arguments.contains("--self-test") {
        exit(runSelfTest())
    }

    if CommandLine.arguments.contains("--probe") {
        runProbe()
        exit(0)
    }

    // Per-cluster CPU frequency validation instrument (v2.1 item 10.1). Prints
    // the computed residency-weighted GHz so it can be eyeballed against
    // `sudo powermetrics --samplers cpu_power` before the panel row is trusted.
    if CommandLine.arguments.contains("--probe-freq") {
        let fm = FrequencyMonitor()
        guard fm.isAvailable else { print("FrequencyMonitor unavailable on this machine"); exit(1) }
        _ = fm.read()                       // baseline
        Thread.sleep(forTimeInterval: 1.0)
        if let freqs = fm.read() {
            print("per-cluster frequency (residency-weighted, 1 s window):")
            for f in freqs { print(String(format: "  %-6@  %.0f MHz", f.name as NSString, f.mhz)) }
            print("compare to: sudo powermetrics --samplers cpu_power -i 1000 -n 1")
        } else {
            print("no active clusters in the window (all idle) — run under load")
        }
        exit(0)
    }

    // Memory validation instrument. Prints what the real samplers report so
    // it can be diffed against `/usr/bin/footprint -p <pid>` and against
    // Activity Monitor, which is the only way to catch a formula reading the
    // wrong quantity — every such bug still produces plausible numbers.
    if CommandLine.arguments.contains("--probe-mem") {
        if let m = try? MemorySampler().read() {
            let g = 1073741824.0
            print("system memory (GiB)")
            print(String(format: "  used         %6.2f   <- app + wired + compressed",
                         Double(m.usedBytes) / g))
            print(String(format: "  app          %6.2f   (internal %.2f - purgeable %.2f)",
                         Double(m.appBytes) / g, Double(m.internalBytes) / g,
                         Double(m.purgeableBytes) / g))
            print(String(format: "  wired        %6.2f", Double(m.wiredBytes) / g))
            print(String(format: "  compressed   %6.2f", Double(m.compressedBytes) / g))
            print(String(format: "  cached files %6.2f", Double(m.cachedFilesBytes) / g))
            print(String(format: "  free         %6.2f   (raw free %.2f - speculative %.2f)",
                         Double(m.trulyFreeBytes) / g, Double(m.freeBytes) / g,
                         Double(m.speculativeBytes) / g))
            print(String(format: "  superseded active-based figure would be %6.2f",
                         Double(m.activeBytes + m.wiredBytes + m.compressedBytes) / g))
            print("  compare to: Activity Monitor > Memory")
        } else {
            print("MemorySampler unavailable")
        }

        let top = (try? ProcessSampler().read())?
            .sorted { $0.displayMemoryBytes > $1.displayMemoryBytes }
            .prefix(10) ?? []
        print("\ntop 10 by memory — MB as displayed, with the RSS it replaced")
        print("  pid      displayed   footprint   RSS      name")
        for p in top {
            print(String(format: "  %-8d %9llu %11llu %8llu   %@",
                         p.pid, p.displayMemoryBytes / 1048576,
                         p.footprintBytes / 1048576, p.residentBytes / 1048576,
                         p.name as NSString))
        }
        print("  compare to: /usr/bin/footprint -p <pid>")
        exit(0)
    }

    if CommandLine.arguments.contains("--preview-widget") {
        let app = NSApplication.shared
        WidgetPreview.show()
        app.run()
        exit(0)
    }

    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)

    // Dev safety net: `--dev-autoquit <seconds>` makes this instance terminate
    // itself after the interval. Only the isolated dev bundle (build.sh --dev)
    // passes it, so a dev build launched for a quick check can never outlive
    // the work session even if nobody remembers to quit it. The real .app is
    // never launched with this flag, so production runs forever as normal.
    if let i = CommandLine.arguments.firstIndex(of: "--dev-autoquit"),
       i + 1 < CommandLine.arguments.count,
       let seconds = Double(CommandLine.arguments[i + 1]), seconds > 0 {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
            NSApp.terminate(nil)
        }
    }

    app.run()
}

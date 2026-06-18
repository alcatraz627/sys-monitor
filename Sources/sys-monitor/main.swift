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
    app.run()
}

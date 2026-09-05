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

        let all = (try? ProcessSampler().read())?
            .map { ProcSample(raw: $0, cpu: 0, diskBps: 0, netBps: 0) } ?? []
        let groups = ProcGroup.group(all).sorted { $0.memBytes > $1.memBytes }
        print("\ntop 10 trees — what the grouped list shows")
        print("  total MB   procs   largest child   name")
        for g in groups.prefix(10) {
            print(String(format: "  %8llu %7d %15llu   %@",
                         g.memBytes / 1048576, g.count,
                         (g.members.first?.memBytes ?? 0) / 1048576,
                         g.name as NSString))
        }
        exit(0)
    }

    // Per-process network across a panel close/reopen. The defect this
    // exists to catch is invisible on a first open: flows that predate the
    // close simply stop being counted, so the column reads 0 for anything
    // long-lived. Run it with a download or a torrent active.
    if CommandLine.arguments.contains("--probe-net") {
        let mon = PerProcessNetworkMonitor()
        guard mon.isAvailable else { print("per-process network unavailable"); exit(1) }
        func livePids() -> Set<Int32> {
            Set((try? ProcessSampler().read())?.map(\.pid) ?? [])
        }
        func sample(_ label: String) -> Int {
            let pids = livePids()
            let m = mon.cumulativeBytesByPid(livePids: pids)
            let busy = m.filter { $0.value > 0 }
            print(String(format: "  %-28s %3d pids with bytes", (label as NSString).utf8String!, busy.count))
            for (pid, b) in busy.sorted(by: { $0.value > $1.value }).prefix(3) {
                print(String(format: "      pid %-7d %8llu KB", pid, b / 1024))
            }
            return busy.count
        }

        print("per-process network across a close/reopen")
        mon.start()
        Thread.sleep(forTimeInterval: 4.0)
        let before = sample("open, 4 s of traffic")

        mon.stop()                       // panel closed
        Thread.sleep(forTimeInterval: 3.0)
        mon.start()                      // panel reopened
        Thread.sleep(forTimeInterval: 4.0)
        let after = sample("reopened, 4 s of traffic")

        print("")
        if before == 0 {
            print("INCONCLUSIVE — no traffic during the first window; re-run with a download active")
            exit(2)
        }
        // Flows that predated the close must still be counted. Some churn is
        // normal, so the bar is that most of them survived.
        let ok = after >= max(1, before / 2)
        print(ok ? "PASS pre-existing flows still counted after reopen"
                 : "FAIL flows that predated the close stopped being counted")
        exit(ok ? 0 : 1)
    }

    // Render each glyph profile to a PNG so the pixels can be looked at
    // without restarting the live widget. A width in points is not a render;
    // spacing and legibility only show up in the image.
    if let i = CommandLine.arguments.firstIndex(of: "--probe-glyph") {
        let dir = (i + 1 < CommandLine.arguments.count && !CommandLine.arguments[i + 1].hasPrefix("--"))
            ? CommandLine.arguments[i + 1] : NSTemporaryDirectory()
        var snap = MetricsSnapshot.initial()
        snap.cpu = .ok(CPUSample(overall: 0.26, perCore: []))
        snap.memory = .ok(MemorySample(usedBytes: 32 << 30, totalBytes: 64 << 30,
                                       swapUsedBytes: 0, pressure: .normal))
        snap.net = .ok(Throughput(inPerSec: 1_572_864, outPerSec: 138_240))
        snap.disk = .ok(Throughput(inPerSec: 361_472, outPerSec: 12_582_912))

        let profiles: [(String, [BarCell], GlyphDensity)] = [
            ("full-standard", [.cpu, .mem, .net, .disk], .standard),
            ("full-compact",  [.cpu, .mem, .net, .disk], .compact),
            ("narrow",        SettingsStore.defaultNarrowBarCells, .compact),
        ]
        for (name, cells, density) in profiles {
            let r = GlyphRenderer(cells: cells, activityArrows: true,
                                  throughputUnit: .bytesPerSec,
                                  thresholds: .defaults, density: density)
            let img = r.render(snapshot: snap)
            // Draw on the menu bar's own grey; a bare alpha channel reads as
            // white in a viewer and hides every contrast problem.
            let out = NSImage(size: img.size)
            out.lockFocus()
            NSColor(calibratedWhite: 0.22, alpha: 1).setFill()
            NSRect(origin: .zero, size: img.size).fill()
            img.draw(at: .zero, from: .zero, operation: .sourceOver, fraction: 1)
            out.unlockFocus()
            guard let tiff = out.tiffRepresentation,
                  let rep = NSBitmapImageRep(data: tiff),
                  let png = rep.representation(using: .png, properties: [:]) else { continue }
            let path = (dir as NSString).appendingPathComponent("glyph-\(name).png")
            try? png.write(to: URL(fileURLWithPath: path))
            print(String(format: "%-16s %6.0f pt  %@", (name as NSString).utf8String!,
                         r.totalWidth(snapshot: snap), path))
        }
        exit(0)
    }

    // Does a REAL status item resolve to a screen, and what does that screen
    // classify as? The per-display glyph profile hangs entirely on
    // `statusItem.button?.window?.screen`, and no unit test can exercise it:
    // the window is created by AppKit when the item is added to the menu bar.
    // Creates a transient item, reads the accessor, and exits.
    if CommandLine.arguments.contains("--probe-room") {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "?"
        // AppKit materialises the window asynchronously; poll briefly rather
        // than sleeping a fixed guess.
        var window: NSWindow?
        for _ in 0..<40 {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            if let w = item.button?.window { window = w; break }
        }
        print("status item window: \(window == nil ? "nil" : "present")")
        if let w = window {
            print(String(format: "  window.frame    : x %.0f y %.0f w %.0f h %.0f",
                         w.frame.minX, w.frame.minY, w.frame.width, w.frame.height))
            print("  window.screen   : \(w.screen?.localizedName ?? "nil")")
            for s in NSScreen.screens {
                let contains = s.frame.intersects(w.frame)
                print(String(format: "    %@ frame x %.0f y %.0f w %.0f h %.0f  contains: %@",
                             s.localizedName, s.frame.minX, s.frame.minY,
                             s.frame.width, s.frame.height, contains ? "YES" : "no"))
            }
        }
        if let screen = window?.screen {
            let room = MenuBarRoom.classify(screen)
            print("  resolved screen : \(screen.localizedName)")
            print(String(format: "  safeArea.top    : %.1f", screen.safeAreaInsets.top))
            print("  classified as   : \(room.isNarrow ? "NARROW" : "roomy")")
            print(String(format: "  status-item room: %.0f pt", room.statusItemWidth))
            let profile = room.isNarrow
                ? (SettingsStore.defaultNarrowBarCells, GlyphDensity.compact)
                : ([BarCell.cpu, .mem, .net, .disk], GlyphDensity.standard)
            let r = GlyphRenderer(cells: profile.0, activityArrows: true,
                                  throughputUnit: .bytesPerSec,
                                  thresholds: .defaults, density: profile.1)
            let w = r.totalWidth(snapshot: MetricsSnapshot.initial())
            print(String(format: "  glyph it picks  : %d cells, %.0f pt (%.0f%% of the strip)",
                         profile.0.count, w, w / room.statusItemWidth * 100))
            print(w <= room.statusItemWidth / 3 ? "PASS fits within a third of the strip"
                                                : "NOTE wider than a third of the strip")
        } else {
            print("  window has no screen — cannot classify")
        }
        NSStatusBar.system.removeStatusItem(item)
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

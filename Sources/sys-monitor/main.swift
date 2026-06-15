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

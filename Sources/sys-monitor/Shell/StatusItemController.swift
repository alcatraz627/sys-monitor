import AppKit
import Combine
import os

/// Owns the menu-bar `NSStatusItem`, keeps its image in sync with the
/// `MetricsStore`, and routes the button's click to a supplied handler
/// (the panel controller's `toggle`). Holds the Combine subscription
/// that drives per-tick redraws — letting it drop would silently freeze
/// the glyph, which is the kind of silent no-op that's painful to
/// diagnose, so it's stored explicitly.
@MainActor
final class StatusItemController {
    let statusItem: NSStatusItem
    private let store: MetricsStore
    // The three glyph inputs the user can change at runtime. Each has its
    // own setter; any change rebuilds the renderer (cheap — it just
    // re-measures reserved widths) and forces a fresh frame.
    private var cells: [BarCell]
    private var activityArrows: Bool
    private var throughputUnit: ThroughputUnit
    private var thresholds: SeverityThresholds
    private var renderer: GlyphRenderer
    private var subscription: AnyCancellable?
    private var clickTarget: ClickTarget?

    /// Key of the last frame actually drawn — when the next snapshot
    /// would draw the same pixels, skip the NSImage rebuild entirely.
    private var lastRenderKey: String?

    /// On notched Macs the system can silently hide a status item that
    /// doesn't fit the menu bar. Rendering into that void is wasted work,
    /// so rendering pauses while the status window reports itself
    /// occluded. (Sampling continues — the panel must still work.)
    private var glyphOnScreen = true

    private let log = Logger(subsystem: "dev.sys-monitor.menubar", category: "glyph")

    init(
        store: MetricsStore,
        cells: [BarCell] = [.cpu, .mem],
        activityArrows: Bool = true,
        throughputUnit: ThroughputUnit = .bytesPerSec,
        thresholds: SeverityThresholds = .defaults,
        onClick: @escaping () -> Void,
        onShowSettings: @escaping () -> Void
    ) {
        self.store = store
        self.cells = cells
        self.activityArrows = activityArrows
        self.throughputUnit = throughputUnit
        self.thresholds = thresholds
        self.renderer = GlyphRenderer(cells: cells, activityArrows: activityArrows,
                                      throughputUnit: throughputUnit, thresholds: thresholds)
        self.statusItem = NSStatusBar.system.statusItem(
            withLength: NSStatusItem.variableLength
        )

        // Paint once immediately so the item has visible width and the
        // user sees `—` rather than an empty slot during the first tick.
        redraw(snapshot: store.snapshot)

        // Hook the button's click. AppKit's target/action wants an
        // `@objc` selector, so we route through a tiny NSObject shim
        // and keep a strong reference to it from here. Left-click
        // toggles the panel; right-click shows a small menu — the
        // standard escape hatch when the panel itself is broken or
        // off-screen.
        let target = ClickTarget(
            handler: onClick,
            onShowSettings: onShowSettings,
            statusItem: statusItem
        )
        self.clickTarget = target
        if let button = statusItem.button {
            button.target = target
            button.action = #selector(ClickTarget.fire)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        subscription = store.$snapshot.sink { [weak self] snap in
            self?.redraw(snapshot: snap)
        }

        // Now that all stored properties are set, hand the click target a
        // way to read the current top consumer for its menu header.
        target.topConsumer = { [weak self] in self?.topConsumerText() }
    }

    /// Runtime settings changes. Each updates one input and rebuilds the
    /// renderer; the rebuild is cheap (it re-measures reserved widths) and
    /// resetting `lastRenderKey` guarantees the next frame draws.
    func updateCells(_ cells: [BarCell]) {
        self.cells = cells
        rebuildRenderer()
    }
    func updateActivityArrows(_ on: Bool) {
        self.activityArrows = on
        rebuildRenderer()
    }
    func updateThroughputUnit(_ unit: ThroughputUnit) {
        self.throughputUnit = unit
        rebuildRenderer()
    }
    func updateThresholds(_ t: SeverityThresholds) {
        self.thresholds = t
        rebuildRenderer()
    }

    private func rebuildRenderer() {
        renderer = GlyphRenderer(cells: cells, activityArrows: activityArrows,
                                 throughputUnit: throughputUnit, thresholds: thresholds)
        lastRenderKey = nil
        redraw(snapshot: store.snapshot)
    }

    private func redraw(snapshot: MetricsSnapshot) {
        guard let button = statusItem.button else { return }

        // Skip drawing while the status window reports itself occluded
        // (hidden by menu-bar overflow on notched Macs, etc.).
        // `occlusionState` is the AppKit-native signal; the classic
        // CGWindowList technique is unusable for status items on modern
        // macOS — the window is absent from even the app's own on-screen
        // list query, and `windowNumber` reads as 2^32. A nil window
        // (first paint, before AppKit materializes it) counts as visible
        // so the initial frame always lands.
        let occluded = button.window.map { !$0.occlusionState.contains(.visible) } ?? false
        if occluded {
            if glyphOnScreen {
                glyphOnScreen = false
                log.info("status item occluded — pausing glyph renders")
            }
            return
        }
        if !glyphOnScreen {
            glyphOnScreen = true
            lastRenderKey = nil      // force a fresh frame on return
            log.info("status item visible again — resuming renders")
        }

        let key = renderer.renderKey(snapshot: snapshot)
        if key == lastRenderKey {
            log.debug("render skipped (identical frame)")
            return
        }
        lastRenderKey = key
        button.image = renderer.render(snapshot: snapshot)
        var a11y = renderer.accessibilityValue(snapshot: snapshot)
        if let top = topConsumerText() { a11y = "Top process \(top). " + a11y }
        button.setAccessibilityValue(a11y)
    }

    /// "Chrome — 84%" for the busiest process, or nil when no process data
    /// exists yet (the idle tier never enumerates processes, so this is
    /// populated only once the panel has been opened this session).
    func topConsumerText() -> String? {
        guard case .ok(let procs) = store.snapshot.processes,
              let top = procs.max(by: { $0.cpu < $1.cpu }), top.cpu > 0.01
        else { return nil }
        let name = top.name.isEmpty ? "pid \(top.pid)" : top.name
        return "\(name) — \(Int((top.cpu * 100).rounded()))%"
    }
}

/// AppKit target/action only accepts `@objc` selectors on `NSObject`
/// subclasses, so we route the SwiftUI/Swift-closure click handlers
/// through this minimal shim. Lives as long as the StatusItemController.
/// Left-click runs the toggle handler; right-click pops a context menu.
@MainActor
private final class ClickTarget: NSObject {
    private let handler: () -> Void
    private let onShowSettings: () -> Void
    private weak var statusItem: NSStatusItem?
    /// Returns the busiest process ("Chrome — 84%") for the menu header, or
    /// nil when no process data exists. Set after init (capturing the owner
    /// during init would reference self before it's fully initialized).
    var topConsumer: (() -> String?)?

    init(
        handler: @escaping () -> Void,
        onShowSettings: @escaping () -> Void,
        statusItem: NSStatusItem
    ) {
        self.handler = handler
        self.onShowSettings = onShowSettings
        self.statusItem = statusItem
    }

    @objc func fire() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showMenu()
        } else {
            handler()
        }
    }

    private func showMenu() {
        guard let button = statusItem?.button else { return }
        let menu = NSMenu()
        // Top-consumer header (disabled, informational) — only when process
        // data exists. The menu-bar tooltip can't show this (macOS suppresses
        // tooltips for nonactivating accessory apps), so the menu is its home.
        if let top = topConsumer?() {
            let header = NSMenuItem(title: "Top: \(top)", action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)
            menu.addItem(.separator())
        }
        let settings = NSMenuItem(
            title: "Settings…", action: #selector(menuShowSettings), keyEquivalent: ""
        )
        settings.target = self
        menu.addItem(settings)
        menu.addItem(.separator())
        let quit = NSMenuItem(
            title: "Quit sys-monitor", action: #selector(menuQuit), keyEquivalent: ""
        )
        quit.target = self
        menu.addItem(quit)
        menu.popUp(
            positioning: nil,
            at: NSPoint(x: 0, y: button.bounds.maxY + 4),
            in: button
        )
    }

    @objc private func menuShowSettings() { onShowSettings() }
    @objc private func menuQuit() { NSApp.terminate(nil) }
}

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
        onClick: @escaping () -> Void,
        onShowSettings: @escaping () -> Void
    ) {
        self.store = store
        self.renderer = GlyphRenderer(cells: cells, activityArrows: activityArrows)
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
    }

    /// Swap the bar-cell layout at runtime (settings change). Rebuilds
    /// the renderer with new reserved-width and per-cell rules, then
    /// redraws against the current snapshot.
    func updateCells(_ cells: [BarCell], activityArrows: Bool) {
        renderer = GlyphRenderer(cells: cells, activityArrows: activityArrows)
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
        button.setAccessibilityValue(renderer.accessibilityValue(snapshot: snapshot))
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

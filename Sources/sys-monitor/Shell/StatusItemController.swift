import AppKit
import Combine

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

    init(
        store: MetricsStore,
        style: GlyphRenderer.Style = .cpuPercent,
        onClick: @escaping () -> Void
    ) {
        self.store = store
        self.renderer = GlyphRenderer(style: style)
        self.statusItem = NSStatusBar.system.statusItem(
            withLength: NSStatusItem.variableLength
        )

        // Paint once immediately so the item has visible width and the
        // user sees `—` rather than an empty slot during the first tick.
        redraw(snapshot: store.snapshot)

        // Hook the button's click. AppKit's target/action wants an
        // `@objc` selector, so we route through a tiny NSObject shim
        // and keep a strong reference to it from here.
        let target = ClickTarget(handler: onClick)
        self.clickTarget = target
        if let button = statusItem.button {
            button.target = target
            button.action = #selector(ClickTarget.fire)
        }

        subscription = store.$snapshot.sink { [weak self] snap in
            self?.redraw(snapshot: snap)
        }
    }

    private func redraw(snapshot: MetricsSnapshot) {
        guard let button = statusItem.button else { return }
        button.image = renderer.render(snapshot: snapshot)
        button.setAccessibilityValue(renderer.accessibilityValue(snapshot: snapshot))
    }
}

/// AppKit target/action only accepts `@objc` selectors on `NSObject`
/// subclasses, so we route the SwiftUI/Swift-closure click handler through
/// this minimal shim. Lives as long as the StatusItemController.
@MainActor
private final class ClickTarget: NSObject {
    private let handler: () -> Void
    init(handler: @escaping () -> Void) { self.handler = handler }
    @objc func fire() { handler() }
}

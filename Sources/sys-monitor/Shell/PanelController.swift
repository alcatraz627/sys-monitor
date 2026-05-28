import AppKit
import SwiftUI

/// Owns the dropdown panel and the click-outside event monitor.
///
/// Click handler (`toggle`) is wired by the status-item controller's button
/// target/action. On open, the panel anchors below the menu-bar item on
/// the screen that holds it, becomes key, and a global `NSEvent` monitor
/// listens for clicks outside the panel to dismiss. On close, the monitor
/// is removed.
@MainActor
final class PanelController {

    private let store: MetricsStore
    private let settings: SettingsStore
    private let coordinator: SamplingCoordinator
    private weak var statusItem: NSStatusItem?
    private var panel: DropPanel?
    private var clickMonitor: Any?

    /// Set after construction by the AppDelegate so the panel's "Settings…"
    /// footer button has somewhere to dispatch. Captured weakly inside the
    /// SwiftUI view so a dead controller doesn't keep settings alive.
    var onShowSettings: (() -> Void)?

    init(store: MetricsStore, settings: SettingsStore, coordinator: SamplingCoordinator) {
        self.store = store
        self.settings = settings
        self.coordinator = coordinator
    }

    /// Close the panel without dismissing-via-event. Used by the settings
    /// flow so the dropdown gets out of the way before the settings window
    /// opens.
    func close() {
        removeClickMonitor()
        panel?.orderOut(nil)
        coordinator.enterIdleTier()
    }

    /// The status-item controller passes its `NSStatusItem` in so we can
    /// position the panel relative to its button on every open.
    func bind(statusItem: NSStatusItem) {
        self.statusItem = statusItem
    }

    /// Toggle: open if closed, close if open. Idempotent — driven by the
    /// status-item button's click.
    @objc func toggle() {
        if isVisible { close() } else { open() }
    }

    private var isVisible: Bool { panel?.isVisible == true }

    private func open() {
        let panel = panel ?? makePanel()
        self.panel = panel
        anchor(panel: panel)
        panel.makeKeyAndOrderFront(nil)
        coordinator.enterOpenTier()
        installClickMonitor()
    }


    // MARK: - Build

    private func makePanel() -> DropPanel {
        let panel = DropPanel(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 480),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.backgroundColor = .clear
        panel.hasShadow = true

        let root = PanelRootView(
            onShowSettings: { [weak self] in self?.onShowSettings?() }
        )
        .environmentObject(store)
        .environmentObject(settings)
        panel.contentViewController = NSHostingController(rootView: root)
        return panel
    }

    // MARK: - Positioning

    private func anchor(panel: NSPanel) {
        guard let button = statusItem?.button, let buttonWindow = button.window else { return }
        let buttonFrameInScreen = buttonWindow.convertToScreen(button.frame)
        let panelSize = panel.frame.size
        // Center under the button, with a small gap from the menu bar.
        let x = buttonFrameInScreen.midX - panelSize.width / 2
        let y = buttonFrameInScreen.minY - panelSize.height - 6
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    // MARK: - Click-outside dismiss

    private func installClickMonitor() {
        removeClickMonitor()
        // A global monitor fires for events delivered to OTHER apps — the
        // common "click outside our panel" case. A re-click on our status
        // item is handled by the toggle action and doesn't need monitor
        // help. We deliberately don't install a local monitor, because
        // a local monitor would fire for clicks INSIDE the panel and we
        // need those to drive SwiftUI controls untouched.
        clickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            Task { @MainActor in self?.close() }
        }
    }

    private func removeClickMonitor() {
        if let m = clickMonitor {
            NSEvent.removeMonitor(m)
        }
        clickMonitor = nil
    }
}

import AppKit
import SwiftUI
import Combine
import os

/// Shared panel-session state the SwiftUI content can both read and
/// mutate. Pinning lives here rather than in SettingsStore because it's
/// a session gesture, not a persisted preference — it resets when the
/// panel is explicitly closed.
@MainActor
final class PanelState: ObservableObject {
    /// While pinned, the panel ignores click-outside, Escape, and
    /// Space-change dismissal — only the menu-bar icon (or unpinning)
    /// closes it. Occlusion demotes the sampling tier instead of
    /// dismissing, and screen lock still closes unconditionally.
    @Published var isPinned = false
}

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
    private var occlusionObserver: NSObjectProtocol?
    private var spaceObserver: NSObjectProtocol?
    private var resizeObserver: NSObjectProtocol?
    let panelState = PanelState()
    private var isPinned: Bool { panelState.isPinned }
    private let log = Logger(subsystem: "dev.sys-monitor.menubar", category: "panel")

    /// Set after construction by the AppDelegate so the panel's "Settings…"
    /// footer button has somewhere to dispatch. Captured weakly inside the
    /// SwiftUI view so a dead controller doesn't keep settings alive.
    var onShowSettings: (() -> Void)?

    private var pinSync: AnyCancellable?
    private var zoomSync: AnyCancellable?

    init(store: MetricsStore, settings: SettingsStore, coordinator: SamplingCoordinator) {
        self.store = store
        self.settings = settings
        self.coordinator = coordinator
        // Pin state round-trips through settings so it survives relaunch.
        panelState.isPinned = settings.panelPinned
        pinSync = panelState.$isPinned.dropFirst().sink { [weak settings] pinned in
            settings?.panelPinned = pinned
        }
        // The view scales itself; the window has to follow, because its width
        // and its size bounds are in points and would otherwise clip the zoomed
        // content or leave a margin around it.
        zoomSync = settings.$panelZoom.dropFirst().sink { [weak self] z in
            Task { @MainActor [weak self] in self?.applyZoom(z) }
        }
    }

    /// Resize the window to the zoomed layout, keeping the top edge and the
    /// horizontal anchor under the status item.
    private func applyZoom(_ z: Double) {
        guard let panel else { return }
        let w = 360 * CGFloat(z)
        panel.minSize = NSSize(width: w, height: 320 * CGFloat(z))
        panel.maxSize = NSSize(width: w, height: 900 * CGFloat(z))
        var r = panel.frame
        let h = min(max(r.height, panel.minSize.height), panel.maxSize.height)
        r.origin.y = r.maxY - h
        r.size = NSSize(width: w, height: h)
        panel.setFrame(r, display: true)
        anchor(panel: panel)
    }

    /// Close the panel without dismissing-via-event. Used by the settings
    /// flow so the dropdown gets out of the way before the settings window
    /// opens.
    func close() {
        // The pin deliberately SURVIVES close: it's the user's standing
        // preference for how the panel behaves, and resetting it here
        // would force re-pinning on every open.
        removeClickMonitor()
        removeVisibilityObservers()
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
        installVisibilityObservers(panel: panel)
    }

    // MARK: - Visibility-driven dismiss

    /// Close when the panel stops being visible without a click: a Space
    /// switch, Mission Control, or anything that occludes it. The panel is
    /// dismissed (not kept marooned on the old Space) and the open tier —
    /// the expensive one — ends with it. Without this, a keyboard Space
    /// switch left full process enumeration running until the next click
    /// anywhere happened to reach the global monitor.
    private func installVisibilityObservers(panel: DropPanel) {
        removeVisibilityObservers()
        occlusionObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification,
            object: panel, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let p = self.panel, p.isVisible else { return }
                let visible = p.occlusionState.contains(.visible)
                if self.isPinned {
                    // Pinned: never dismiss for visibility — but stop
                    // paying open-tier cost into an invisible panel, and
                    // resume when it can be seen again.
                    if visible {
                        self.coordinator.enterOpenTier()
                        self.log.info("pinned panel visible again -> open tier")
                    } else {
                        self.coordinator.enterIdleTier()
                        self.log.info("pinned panel occluded -> idle tier (kept open)")
                    }
                } else if !visible {
                    self.log.info("panel occluded -> closing (demote to idle tier)")
                    self.close()
                }
            }
        }
        spaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.isVisible, !self.isPinned else { return }
                self.log.info("active Space changed -> closing panel")
                self.close()
            }
        }
    }

    private func removeVisibilityObservers() {
        if let o = occlusionObserver { NotificationCenter.default.removeObserver(o) }
        if let o = spaceObserver { NSWorkspace.shared.notificationCenter.removeObserver(o) }
        occlusionObserver = nil
        spaceObserver = nil
    }


    // MARK: - Build

    private func makePanel() -> DropPanel {
        let panel = DropPanel(
            contentRect: NSRect(x: 0, y: 0, width: 360 * settings.panelZoom,
                                height: settings.panelHeight * settings.panelZoom),
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
            onShowSettings: { [weak self] in self?.onShowSettings?() },
            onResizeDrag: { [weak self] dy in self?.resize(byDragging: dy) },
            onResizeEnd: { [weak self] in self?.commitDraggedHeight() }
        )
        .environmentObject(store)
        .environmentObject(settings)
        .environmentObject(panelState)
        panel.contentViewController = NSHostingController(rootView: root)
        panel.onCancel = { [weak self] in
            guard let self, !self.isPinned else { return }
            self.close()
        }

        // Height is user-resizable (borderless windows resize from their
        // edges once .resizable is in the style mask); width stays
        // locked to the design's 360 via min == max. The chosen height
        // persists through settings.
        // `.resizable` is deliberately NOT set. It was there for the height
        // drag and it brought AppKit's zoom with it. The grip in the panel's
        // own footer does the drag now, on a 12 pt target.
        let z = CGFloat(settings.panelZoom)
        panel.minSize = NSSize(width: 360 * z, height: 320 * z)
        panel.maxSize = NSSize(width: 360 * z, height: 900 * z)

        return panel
    }

    // MARK: - Height drag

    /// Height at the moment the grip was grabbed. The gesture reports total
    /// translation from the start, not a per-frame delta, so the drag has to be
    /// applied against this rather than against the current height.
    private var dragStartHeight: CGFloat?

    private func resize(byDragging translationY: CGFloat) {
        guard let panel else { return }
        let start = dragStartHeight ?? panel.frame.height
        dragStartHeight = start
        let target = min(max(start + translationY, panel.minSize.height), panel.maxSize.height)
        var r = panel.frame
        r.origin.y = r.maxY - target      // top edge stays under the menu bar
        r.size.height = target
        panel.setFrame(r, display: true)
    }

    private func commitDraggedHeight() {
        guard let panel else { return }
        dragStartHeight = nil
        // Stored unscaled. The window is zoom * height, so persisting the
        // window's own height would multiply the zoom in again on next launch.
        settings.panelHeight = Double(panel.frame.height) / settings.panelZoom
    }

    // MARK: - Positioning

    private func anchor(panel: NSPanel) {
        guard let button = statusItem?.button, let buttonWindow = button.window else { return }
        let buttonFrameInScreen = buttonWindow.convertToScreen(button.frame)
        let panelSize = panel.frame.size
        // Center under the button, with a small gap from the menu bar —
        // then clamp into the visible frame: status items live near the
        // right screen edge, where naive centering pushes half the panel
        // off-screen.
        var x = buttonFrameInScreen.midX - panelSize.width / 2
        let y = buttonFrameInScreen.minY - panelSize.height - 6
        if let screen = buttonWindow.screen {
            let vis = screen.visibleFrame.insetBy(dx: 8, dy: 0)
            x = min(max(x, vis.minX), vis.maxX - panelSize.width)
        }
        panel.setFrameOrigin(NSPoint(x: x, y: y))
        // Positioned. From here a content-driven resize grows downward from
        // this top edge instead of climbing into the menu bar and being shoved
        // back onto the screen.
        (panel as? DropPanel)?.keepsTopEdge = true
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
            Task { @MainActor in
                guard let self, !self.isPinned else { return }
                self.close()
            }
        }
    }

    private func removeClickMonitor() {
        if let m = clickMonitor {
            NSEvent.removeMonitor(m)
        }
        clickMonitor = nil
    }
}

import AppKit

/// Borderless, status-bar-level dropdown panel.
///
/// `canBecomeKey` is overridden to `true` so SwiftUI controls inside
/// (scroll, sort toggle, hover) receive routed events. `canBecomeMain`
/// stays `false` and the style mask keeps `.nonactivatingPanel` set, so
/// taking key does NOT activate the app — the Dock stays empty and we
/// stay an `.accessory` agent.
///
/// Dismissal channels: the click-outside `NSEvent` monitor, Escape (via
/// `cancelOperation`), and the controller's occlusion / Space-change
/// observers. `resignKey` deliberately is NOT one of them — it also
/// fires on Settings window activation, which must keep the panel's
/// state machine out of the way rather than racing it.
final class DropPanel: NSPanel {
    override var canBecomeKey: Bool  { true }
    override var canBecomeMain: Bool { false }

    /// Invoked on Escape. AppKit routes `cancelOperation` here whenever
    /// no view in the responder chain claims the key — including from
    /// the search field, which is the decided behavior: Esc always
    /// closes the panel, never just clears the filter.
    var onCancel: (() -> Void)?
    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }

    /// `.resizable` is in the style mask so the height can be dragged, and it
    /// brings AppKit's double-click-to-zoom with it. On a dropdown anchored to
    /// a status item that is never wanted: a double click anywhere in the
    /// panel re-framed it against min/max and dropped it in the screen centre.
    /// A dropdown hangs from the menu bar, so its top edge is the fixed one.
    ///
    /// AppKit's origin is the bottom-left, and `anchor()` computes it once from
    /// the height it sees. When SwiftUI later grows the window to fit an opened
    /// section, the origin stays and the top edge climbs past the menu bar, so
    /// AppKit shoves the whole window back onto the screen. That shove is what
    /// reads as the panel snapping to the middle of the display.
    ///
    /// Set once the controller has positioned the panel. Every later resize
    /// then grows downward from the same top edge.
    var keepsTopEdge = false

    override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        var r = frameRect
        if keepsTopEdge, !inLiveResize, frame.height > 0, r.height != frame.height {
            r.origin.y = frame.maxY - r.height
        }
        super.setFrame(r, display: flag)
    }
}

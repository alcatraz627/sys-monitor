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
    override func zoom(_ sender: Any?) {}
}

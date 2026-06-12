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
}

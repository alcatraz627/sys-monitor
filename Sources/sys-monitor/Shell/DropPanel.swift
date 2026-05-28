import AppKit

/// Borderless, status-bar-level dropdown panel.
///
/// `canBecomeKey` is overridden to `true` so SwiftUI controls inside
/// (scroll, sort toggle, hover) receive routed events. `canBecomeMain`
/// stays `false` and the style mask keeps `.nonactivatingPanel` set, so
/// taking key does NOT activate the app — the Dock stays empty and we
/// stay an `.accessory` agent.
///
/// Dismiss is driven externally by an `NSEvent` click-outside monitor;
/// `resignKey` deliberately does NOT dismiss because it also fires on
/// occlusion, Space switches, and Settings window activation — all of
/// which should keep the panel open.
final class DropPanel: NSPanel {
    override var canBecomeKey: Bool  { true }
    override var canBecomeMain: Bool { false }
}

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

    /// Never be shorter than the content.
    ///
    /// SwiftUI lays the panel out at its natural height and centres it when the
    /// window is shorter, so a window a few points short does not compress: it
    /// cuts the CPU header off the top and the footer and the resize grip off the
    /// bottom, and it takes the corner radius with them, because the rounded
    /// shape belongs to the content and its corners end up outside the window.
    /// That is what shipped, and `--probe-resize` could not see it: its content
    /// check asserts content >= window, which an oversized content satisfies.
    ///
    /// Growing only. A section that closes leaves the room behind rather than
    /// snapping the window shut under the pointer, and the footer grip can still
    /// drag the panel taller than its content.
    var fitsContentHeight = false

    private var isFittingContent = false

    func fitToContentHeight() {
        guard fitsContentHeight, !inLiveResize, !isFittingContent,
              let content = contentViewController?.view else { return }
        // The ceiling is the screen, not `maxSize`. AppKit does not apply
        // maxSize to a programmatic setFrame, so the window already grows past
        // 900 on a tall display and the constant was describing nothing. What
        // it must never do is grow past what the display can show, which only
        // moves the clip from the window to the screen edge.
        let ceiling = screen?.visibleFrame.height ?? maxSize.height
        let need = min(content.fittingSize.height, ceiling)
        guard need > frame.height + 0.5 else { return }
        isFittingContent = true
        defer { isFittingContent = false }
        var r = frame
        r.origin.y = r.maxY - need
        r.size.height = need
        setFrame(r, display: true)
    }

    /// AppKit runs this once per update cycle for a window that needs layout,
    /// which is the point at which SwiftUI has published a new content size and
    /// `fittingSize` is answerable. Doing the fit here rather than on a metrics
    /// tick means an expanded section is measured on the pass that expanded it.
    override func layoutIfNeeded() {
        super.layoutIfNeeded()
        fitToContentHeight()
    }
}

import AppKit

/// Renders the menu-bar glyph (mini usage bar + tabular percentage) into an
/// `NSImage` that the status-item button can take as-is.
///
/// The image width is fixed: we measure the widest possible value string
/// ("100%") in the chosen font and reserve that much room, so the bar item
/// never jitters horizontally as digits change (38% → 100% must not shove
/// the neighbouring menu-bar items around).
///
/// The image is NOT a template image — we want our load colors to show
/// through rather than being flattened to the menu-bar tint.
public struct GlyphRenderer {

    public enum Style: Sendable {
        case cpuPercent
        case memoryPercent
    }

    public let style: Style

    // Layout constants. Menu-bar item height on macOS is ~22pt; the visible
    // ink fits in ~18pt with a little vertical padding above and below.
    private let height: CGFloat = 18
    private let barWidth: CGFloat = 16
    private let gap: CGFloat = 5
    private let leftPad: CGFloat = 2
    private let rightPad: CGFloat = 4

    private let font: NSFont
    private let textWidth: CGFloat
    private let totalWidth: CGFloat

    public init(style: Style = .cpuPercent) {
        self.style = style
        let f = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        self.font = f
        // Reserve room for the widest formatted value. "100%" beats "0%"–"99%"
        // because of the extra digit; everything renders right-aligned into
        // the reserved column.
        let attrs: [NSAttributedString.Key: Any] = [.font: f]
        self.textWidth = ceil(("100%" as NSString).size(withAttributes: attrs).width)
        self.totalWidth = leftPad + barWidth + gap + textWidth + rightPad
    }

    /// Build a fresh `NSImage` from the snapshot. Cheap enough to call once
    /// per tick — drawing happens lazily when AppKit asks for the bitmap.
    public func render(snapshot: MetricsSnapshot) -> NSImage {
        let (load, text) = valueAndLabel(from: snapshot)
        let size = NSSize(width: totalWidth, height: height)

        // Capture-by-value for the drawing closure — GlyphRenderer is a
        // value type, so `self` capture is fine and `Sendable`-friendly.
        let drawHeight = height
        let drawBarWidth = barWidth
        let drawGap = gap
        let drawLeftPad = leftPad
        let drawTextWidth = textWidth
        let drawFont = font

        let image = NSImage(size: size, flipped: false) { _ in
            // Background of the bar (very faint so it reads as a track).
            let barRect = NSRect(
                x: drawLeftPad, y: 3,
                width: drawBarWidth, height: drawHeight - 6
            )
            let track = NSBezierPath(roundedRect: barRect, xRadius: 2, yRadius: 2)
            NSColor.tertiaryLabelColor.withAlphaComponent(0.3).setFill()
            track.fill()

            // Fill proportional to load. A 1-pixel minimum width lets you
            // see SOMETHING for tiny but non-zero values, which is useful
            // when comparing "actually 0" vs "tiny but moving."
            if load > 0 {
                let filled = max(1, barRect.width * CGFloat(load))
                let fillRect = NSRect(
                    x: barRect.minX, y: barRect.minY,
                    width: filled, height: barRect.height
                )
                let path = NSBezierPath(roundedRect: fillRect, xRadius: 2, yRadius: 2)
                Self.color(for: load).setFill()
                path.fill()
            }

            // Right-aligned text in the reserved column.
            let textColumn = NSRect(
                x: drawLeftPad + drawBarWidth + drawGap, y: 0,
                width: drawTextWidth, height: drawHeight
            )
            let para = NSMutableParagraphStyle()
            para.alignment = .right
            let textAttrs: [NSAttributedString.Key: Any] = [
                .font: drawFont,
                .foregroundColor: NSColor.labelColor,
                .paragraphStyle: para,
            ]
            // Vertical centering for the cap-height of the font.
            let textHeight = drawFont.ascender + abs(drawFont.descender)
            let textY = (drawHeight - textHeight) / 2
            let drawRect = NSRect(
                x: textColumn.minX, y: textY,
                width: textColumn.width, height: textHeight
            )
            (text as NSString).draw(in: drawRect, withAttributes: textAttrs)
            return true
        }
        image.isTemplate = false
        return image
    }

    /// Plain accessibility string ("CPU 38 percent" or "CPU measuring").
    /// Read on focus by VoiceOver — we deliberately don't fire announcements
    /// on every tick.
    public func accessibilityValue(snapshot: MetricsSnapshot) -> String {
        let (_, text) = valueAndLabel(from: snapshot)
        let label: String = {
            switch style {
            case .cpuPercent:    return "CPU"
            case .memoryPercent: return "Memory"
            }
        }()
        if text == "—" { return "\(label) measuring" }
        return "\(label) \(text)"
    }

    // MARK: - Helpers

    private func valueAndLabel(from snapshot: MetricsSnapshot) -> (load: Double, text: String) {
        switch style {
        case .cpuPercent:
            switch snapshot.cpu {
            case .ok(let s):                return (s.overall, format(s.overall))
            case .measuring, .unavailable:  return (0, "—")
            }
        case .memoryPercent:
            switch snapshot.memory {
            case .ok(let s) where s.totalBytes > 0:
                let frac = Double(s.usedBytes) / Double(s.totalBytes)
                return (frac, format(frac))
            case .ok, .measuring, .unavailable:
                return (0, "—")
            }
        }
    }

    private func format(_ load: Double) -> String {
        let pct = Int((load * 100).rounded())
        return "\(pct)%"
    }

    private static func color(for load: Double) -> NSColor {
        // Calm → elevated → hot. Color is secondary signal; the digits
        // are the primary readout.
        switch load {
        case ..<0.60: return NSColor.systemGreen
        case ..<0.85: return NSColor.systemOrange
        default:      return NSColor.systemRed
        }
    }
}

import AppKit

/// One unit of the menu-bar glyph. CPU + MEM render as a mini bar plus a
/// right-aligned percentage. NET + DISK render as two icon+value pairs
/// (down then up). Cells are drawn left to right with a hairline separator
/// between them — there is no container pill, by design.
public enum BarCell: Sendable, Hashable {
    case cpu, mem, net, disk
}

/// Renders one or more `BarCell` values into a single `NSImage` for the
/// status-item button. The image has a fixed total width — each cell and
/// every numeric sub-box reserves room for its worst-case content so
/// nothing horizontally jitters as digits change order of magnitude.
public struct GlyphRenderer {

    public let cells: [BarCell]
    private let font: NSFont
    private let cellWidths: [CGFloat]
    private let totalWidth: CGFloat

    private let height: CGFloat = 18
    private let gap: CGFloat = 6
    private let leftPad: CGFloat = 9
    private let rightPad: CGFloat = 9
    private let separatorAlpha: CGFloat = 0.32
    private let separatorHeight: CGFloat = 11

    // Per-cell layout constants
    private let barWidth: CGFloat = 16
    private let barTextGap: CGFloat = 4
    private let numericBoxWidth: CGFloat = 30   // fits "999K" / "1.2M" comfortably
    private let symbolBoxWidth: CGFloat = 10
    private let symbolNumGap: CGFloat = 2
    private let throughputPairGap: CGFloat = 6  // between the "down" pair and the "up" pair

    public init(cells: [BarCell] = [.cpu, .mem]) {
        let effectiveCells = cells.isEmpty ? [.cpu] : cells
        self.cells = effectiveCells
        // Regular weight to sit alongside the system clock / battery rather
        // than against them — medium read as slightly bolded next to native.
        let f = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        self.font = f
        var widths: [CGFloat] = []
        for cell in effectiveCells {
            switch cell {
            case .cpu, .mem:
                widths.append(16 + 4 + 28)  // bar + gap + "100%" text box
            case .net, .disk:
                // [9 icon][2 gap][22 left-aligned value] x 2, separated by
                // a 5pt pair gap. Left alignment keeps the icon visually
                // adjacent to its number; the cell is still fixed-width so
                // the widget itself doesn't shift as values change.
                widths.append(
                    9 + 2 + 22 + 5 + 9 + 2 + 22
                )
            }
        }
        self.cellWidths = widths
        let cellsTotal = widths.reduce(0, +)
        let gapsTotal = CGFloat(max(0, effectiveCells.count - 1)) * 6
        self.totalWidth = 9 + cellsTotal + gapsTotal + 9
    }

    public func render(snapshot: MetricsSnapshot) -> NSImage {
        let size = NSSize(width: totalWidth, height: height)
        let cells = self.cells
        let cellWidths = self.cellWidths
        let height = self.height
        let gap = self.gap
        let leftPad = self.leftPad
        let separatorHeight = self.separatorHeight
        let separatorAlpha = self.separatorAlpha
        let font = self.font

        let image = NSImage(size: size, flipped: false) { _ in
            var x: CGFloat = leftPad
            for (i, cell) in cells.enumerated() {
                let w = cellWidths[i]
                let cellRect = NSRect(x: x, y: 0, width: w, height: height)
                Self.drawCell(cell, in: cellRect, snapshot: snapshot, font: font)
                x += w
                if i < cells.count - 1 {
                    // Hairline separator centered in the inter-cell gap.
                    let sepX = x + gap / 2 - 0.5
                    let sepY = (height - separatorHeight) / 2
                    let sep = NSRect(x: sepX, y: sepY, width: 1, height: separatorHeight)
                    NSColor.labelColor.withAlphaComponent(separatorAlpha).setFill()
                    sep.fill()
                    x += gap
                }
            }
            return true
        }
        image.isTemplate = false
        return image
    }

    public func accessibilityValue(snapshot: MetricsSnapshot) -> String {
        cells.map { Self.accessibilityFor(cell: $0, snapshot: snapshot) }
             .joined(separator: ", ")
    }

    // MARK: - Per-cell drawing

    private static func drawCell(
        _ cell: BarCell, in rect: NSRect, snapshot: MetricsSnapshot, font: NSFont
    ) {
        switch cell {
        case .cpu:
            drawLoadCell(
                load: cpuLoad(snapshot), text: cpuText(snapshot),
                color: cpuLoadColor(cpuLoad(snapshot)),
                in: rect, font: font
            )
        case .mem:
            drawLoadCell(
                load: memLoad(snapshot), text: memText(snapshot),
                color: memLoadColor(memLoad(snapshot)),
                in: rect, font: font
            )
        case .net:
            drawThroughputCell(
                downSymbol: "arrow.down",
                upSymbol:   "arrow.up",
                downBps:    netDownBps(snapshot),
                upBps:      netUpBps(snapshot),
                downText:   netDownText(snapshot),
                upText:     netUpText(snapshot),
                in: rect, font: font
            )
        case .disk:
            // Bare arrows match NET so the two throughput cells have
            // identical visual weight. The separator + cell order
            // (NET first, DISK second) is what distinguishes them.
            drawThroughputCell(
                downSymbol: "arrow.down",
                upSymbol:   "arrow.up",
                downBps:    diskReadBps(snapshot),
                upBps:      diskWriteBps(snapshot),
                downText:   diskReadText(snapshot),
                upText:     diskWriteText(snapshot),
                in: rect, font: font
            )
        }
    }

    private static func drawLoadCell(
        load: Double, text: String, color: NSColor, in rect: NSRect, font: NSFont
    ) {
        let barWidth: CGFloat = 16
        let barRect = NSRect(
            x: rect.minX, y: rect.minY + 3,
            width: barWidth, height: rect.height - 6
        )
        NSColor.tertiaryLabelColor.withAlphaComponent(0.3).setFill()
        NSBezierPath(roundedRect: barRect, xRadius: 2, yRadius: 2).fill()

        if load > 0 {
            let filled = max(1, barRect.width * CGFloat(min(max(load, 0), 1)))
            let fillRect = NSRect(
                x: barRect.minX, y: barRect.minY,
                width: filled, height: barRect.height
            )
            color.setFill()
            NSBezierPath(roundedRect: fillRect, xRadius: 2, yRadius: 2).fill()
        }

        let textRect = NSRect(
            x: rect.minX + barWidth + 4, y: 0,
            width: rect.width - barWidth - 4, height: rect.height
        )
        drawText(text, in: textRect, font: font, color: NSColor.labelColor, alignment: .right)
    }

    private static func drawThroughputCell(
        downSymbol: String, upSymbol: String,
        downBps: Double, upBps: Double,
        downText: String, upText: String,
        in rect: NSRect, font: NSFont
    ) {
        let symW: CGFloat = 9
        let numW: CGFloat = 22
        let symNumGap: CGFloat = 2
        let pairGap: CGFloat = 5

        var x = rect.minX
        // Each direction is [icon][value], read as a tight pair. Icons
        // at secondaryLabelColor so they survive saturated wallpapers;
        // values left-aligned so they sit immediately next to their icon
        // rather than floating at the far end of a right-aligned column.
        drawSymbol(downSymbol, in: NSRect(x: x, y: 0, width: symW, height: rect.height),
                   color: .secondaryLabelColor)
        x += symW + symNumGap
        drawText(downText, in: NSRect(x: x, y: 0, width: numW, height: rect.height),
                 font: font,
                 color: throughputColor(forBps: downBps),
                 alignment: .left)
        x += numW + pairGap
        drawSymbol(upSymbol, in: NSRect(x: x, y: 0, width: symW, height: rect.height),
                   color: .secondaryLabelColor)
        x += symW + symNumGap
        drawText(upText, in: NSRect(x: x, y: 0, width: numW, height: rect.height),
                 font: font,
                 color: throughputColor(forBps: upBps),
                 alignment: .left)
    }

    // MARK: - Drawing primitives

    private static func drawText(
        _ text: String, in rect: NSRect, font: NSFont,
        color: NSColor, alignment: NSTextAlignment
    ) {
        let para = NSMutableParagraphStyle()
        para.alignment = alignment
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: para,
        ]
        let textHeight = font.ascender + abs(font.descender)
        let textY = (rect.height - textHeight) / 2
        let drawRect = NSRect(x: rect.minX, y: textY, width: rect.width, height: textHeight)
        (text as NSString).draw(in: drawRect, withAttributes: attrs)
    }

    /// Render an SF Symbol image with a fixed tint into the given rect,
    /// vertically centered. The symbol is recreated per draw — fine at one
    /// redraw per tick; cache later only if measurable. 9pt point size keeps
    /// the icon visually lighter than the 11pt numbers it accompanies.
    private static func drawSymbol(_ name: String, in rect: NSRect, color: NSColor) {
        let config = NSImage.SymbolConfiguration(pointSize: 9, weight: .regular)
        guard
            let base = NSImage(systemSymbolName: name, accessibilityDescription: nil),
            let configured = base.withSymbolConfiguration(config)
        else { return }
        let tinted = configured.tinted(color)
        let s = tinted.size
        // Center the symbol inside its column.
        let drawRect = NSRect(
            x: rect.minX + (rect.width - s.width) / 2,
            y: (rect.height - s.height) / 2,
            width: s.width, height: s.height
        )
        tinted.draw(in: drawRect)
    }

    // MARK: - Snapshot → display values

    private static func cpuLoad(_ s: MetricsSnapshot) -> Double {
        if case .ok(let v) = s.cpu { return v.overall }
        return 0
    }
    private static func cpuText(_ s: MetricsSnapshot) -> String {
        switch s.cpu {
        case .ok(let v):              return "\(Int((v.overall * 100).rounded()))%"
        case .measuring, .unavailable: return "—"
        }
    }
    private static func memLoad(_ s: MetricsSnapshot) -> Double {
        if case .ok(let v) = s.memory, v.totalBytes > 0 {
            return Double(v.usedBytes) / Double(v.totalBytes)
        }
        return 0
    }
    private static func memText(_ s: MetricsSnapshot) -> String {
        switch s.memory {
        case .ok(let v) where v.totalBytes > 0:
            let frac = Double(v.usedBytes) / Double(v.totalBytes)
            return "\(Int((frac * 100).rounded()))%"
        case .ok, .measuring, .unavailable: return "—"
        }
    }

    private static func netDownBps(_ s: MetricsSnapshot) -> Double {
        if case .ok(let t) = s.net { return t.inPerSec }
        return -1
    }
    private static func netUpBps(_ s: MetricsSnapshot) -> Double {
        if case .ok(let t) = s.net { return t.outPerSec }
        return -1
    }
    private static func netDownText(_ s: MetricsSnapshot) -> String {
        if case .ok(let t) = s.net { return compactBytes(t.inPerSec) }
        return "—"
    }
    private static func netUpText(_ s: MetricsSnapshot) -> String {
        if case .ok(let t) = s.net { return compactBytes(t.outPerSec) }
        return "—"
    }
    private static func diskReadBps(_ s: MetricsSnapshot) -> Double {
        if case .ok(let t) = s.disk { return t.inPerSec }
        return -1
    }
    private static func diskWriteBps(_ s: MetricsSnapshot) -> Double {
        if case .ok(let t) = s.disk { return t.outPerSec }
        return -1
    }
    private static func diskReadText(_ s: MetricsSnapshot) -> String {
        if case .ok(let t) = s.disk { return compactBytes(t.inPerSec) }
        return "—"
    }
    private static func diskWriteText(_ s: MetricsSnapshot) -> String {
        if case .ok(let t) = s.disk { return compactBytes(t.outPerSec) }
        return "—"
    }

    /// Very compact bytes-per-second formatter. Reserves enough characters
    /// for "999M" worst case so right-aligned values lock in their column.
    private static func compactBytes(_ v: Double) -> String {
        if v < 0 { return "—" }
        if v >= 1_048_576 { return "\(Int((v / 1_048_576).rounded()))M" }
        if v >= 1_024     { return "\(Int((v / 1_024).rounded()))K" }
        return "\(Int(v))B"
    }

    /// Idle-dim a throughput number when it's truly quiet. `secondary`
    /// (not tertiary) so a dim value reads as "low activity" rather than
    /// "broken" against saturated wallpapers. Threshold raised to 150 KB/s
    /// — modern machines breathe at ~35 KB/s on idle, and the old 50 KB/s
    /// fired the dim too eagerly.
    private static func throughputColor(forBps bps: Double) -> NSColor {
        if bps < 0            { return .secondaryLabelColor }   // .measuring / .unavailable
        if bps < 150 * 1_024  { return .secondaryLabelColor }
        return .labelColor
    }

    /// CPU load ramp: calm < 60% < elevated < 85% < hot.
    private static func cpuLoadColor(_ load: Double) -> NSColor {
        switch load {
        case ..<0.60: return .systemGreen
        case ..<0.85: return .systemOrange
        default:      return .systemRed
        }
    }

    /// Memory load ramp: thresholds raised because compressed memory +
    /// cache on a healthy macOS routinely sit at 60-70% even on idle
    /// machines. 75 / 92 reads as "actually elevated" / "actually hot."
    private static func memLoadColor(_ load: Double) -> NSColor {
        switch load {
        case ..<0.75: return .systemGreen
        case ..<0.92: return .systemOrange
        default:      return .systemRed
        }
    }

    private static func accessibilityFor(cell: BarCell, snapshot: MetricsSnapshot) -> String {
        switch cell {
        case .cpu:  return "CPU \(cpuText(snapshot))"
        case .mem:  return "Memory \(memText(snapshot))"
        case .net:  return "Network down \(netDownText(snapshot)), up \(netUpText(snapshot))"
        case .disk: return "Disk read \(diskReadText(snapshot)), write \(diskWriteText(snapshot))"
        }
    }
}

// MARK: - Image tinting helper

private extension NSImage {
    /// Returns a copy of the image with every non-transparent pixel
    /// replaced by `color`. Used to tint SF Symbol template images for a
    /// specific role without relying on the host context's ink color
    /// (which doesn't apply in a custom drawingHandler).
    func tinted(_ color: NSColor) -> NSImage {
        let out = NSImage(size: size)
        out.lockFocus()
        color.set()
        let r = NSRect(origin: .zero, size: size)
        r.fill(using: .sourceOver)
        draw(at: .zero, from: r, operation: .destinationIn, fraction: 1.0)
        out.unlockFocus()
        return out
    }
}

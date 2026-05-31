import AppKit

/// One cell of the menu-bar widget.
/// `cpu` / `mem` render as: icon · horizontal-progress-bar · `XX%`.
/// `net` / `disk` render as: icon · ↓green-arrow value · ↑red-arrow value.
/// GPU is planned but its sampler isn't wired yet; the case is reserved.
public enum BarCell: Sendable, Hashable {
    case cpu, mem, net, disk
}

/// Renders the cells into a fixed-width `NSImage` for the status-item
/// button. Grouping follows gestalt by proximity: elements within a cell
/// are tight; the gap between cells is ~1.5× wider.
public struct GlyphRenderer {

    public let cells: [BarCell]
    /// When true, the throughput arrows dim/brighten on a log scale of
    /// their current rate — visual "level of activity" without animation.
    public let activityArrows: Bool
    private let valueFont: NSFont
    private let arrowFont: NSFont
    private let arrowW: CGFloat

    // Variant A — selected from the preview. If we ever offer multiple
    // densities, fork these into a `Style` enum.
    private static let iconPt:       CGFloat = 17
    private static let iconWeight: NSFont.Weight = .bold
    private static let barW:         CGFloat = 16
    private static let barH:         CGFloat = 12   // chunky bar
    private static let valuePt:      CGFloat = 11
    private static let arrowPt:      CGFloat = 11
    private static let height:       CGFloat = 18
    private static let elementGap:   CGFloat = 3
    private static let groupGap:     CGFloat = 10   // doubled — more air before each icon
    private static let arrowValGap:  CGFloat = 1    // arrow hugs its value
    private static let leftPad:      CGFloat = 14   // doubled — same reason
    private static let rightPad:     CGFloat = 7

    /// Constant identity color per cell. The bar still uses load colors
    /// (green / yellow / red); the icon's hue is purely "which cell is
    /// this?" — read it the way you read battery/wifi/bluetooth icons.
    private static func identityColor(for cell: BarCell) -> NSColor {
        switch cell {
        case .cpu:  return NSColor(red: 0.96, green: 0.74, blue: 0.20, alpha: 1) // golden
        case .mem:  return .systemTeal
        case .net:  return .systemPurple
        case .disk: return NSColor(red: 0.52, green: 0.65, blue: 0.80, alpha: 1) // brighter slate-blue
        }
    }

    public init(cells: [BarCell] = [.cpu, .mem], activityArrows: Bool = true) {
        let effective = cells.isEmpty ? [.cpu] : cells
        self.cells = effective
        self.activityArrows = activityArrows
        let vFont = NSFont.monospacedDigitSystemFont(ofSize: Self.valuePt, weight: .medium)
        let aFont = NSFont.systemFont(ofSize: Self.arrowPt, weight: .semibold)
        self.valueFont = vFont
        self.arrowFont = aFont
        self.arrowW    = Self.measure("↓", font: aFont)
    }

    public func render(snapshot: MetricsSnapshot) -> NSImage {
        // Cell widths re-measured each tick from the actual rendered
        // text. The widget reflows on digit-count changes (e.g. "9%" →
        // "10%" or "999B" → "1KB") rather than hogging menu-bar real
        // estate by always reserving the worst case.
        var cellWidths: [CGFloat] = []
        cellWidths.reserveCapacity(cells.count)
        for cell in cells {
            cellWidths.append(measureCell(cell, snapshot: snapshot))
        }
        let cellsTotal = cellWidths.reduce(0, +)
        let groupsTotal = CGFloat(max(0, cells.count - 1)) * Self.groupGap
        let totalWidth = Self.leftPad + cellsTotal + groupsTotal + Self.rightPad

        let size = NSSize(width: totalWidth, height: Self.height)
        let cells = self.cells
        let renderer = self

        let image = NSImage(size: size, flipped: false) { _ in
            var x: CGFloat = Self.leftPad
            for (i, cell) in cells.enumerated() {
                let cellRect = NSRect(x: x, y: 0, width: cellWidths[i], height: Self.height)
                renderer.drawCell(cell, in: cellRect, snapshot: snapshot)
                x += cellWidths[i]
                if i < cells.count - 1 { x += Self.groupGap }
            }
            return true
        }
        image.isTemplate = false
        return image
    }

    /// Width of a single cell given the snapshot. Compute cells reserve
    /// a small minimum-width text column so a transient `0%` doesn't
    /// collapse the icon and bar into the next cell's space.
    private func measureCell(_ cell: BarCell, snapshot: MetricsSnapshot) -> CGFloat {
        switch cell {
        case .cpu:
            let text = Self.cpuPercentText(snapshot)
            let textW = max(Self.measure(text, font: valueFont),
                            Self.measure("00%", font: valueFont))
            return Self.iconPt + Self.elementGap + Self.barW + Self.elementGap + textW
        case .mem:
            let text = Self.memPercentText(snapshot)
            let textW = max(Self.measure(text, font: valueFont),
                            Self.measure("00%", font: valueFont))
            return Self.iconPt + Self.elementGap + Self.barW + Self.elementGap + textW
        case .net:
            return throughputCellWidth(
                downText: Self.formatBps(Self.netDownBps(snapshot)),
                upText:   Self.formatBps(Self.netUpBps(snapshot))
            )
        case .disk:
            return throughputCellWidth(
                downText: Self.formatBps(Self.diskReadBps(snapshot)),
                upText:   Self.formatBps(Self.diskWriteBps(snapshot))
            )
        }
    }

    private func throughputCellWidth(downText: String, upText: String) -> CGFloat {
        // Values are always 5 monospaced chars, so both sub-groups are
        // the same width by construction — no per-tick `max(down, up)`
        // call needed. Width is structurally fixed.
        let valueW = throughputValueReservedW
        let halfW = arrowW + Self.arrowValGap + valueW
        return Self.iconPt + Self.elementGap + halfW + Self.elementGap + halfW
    }

    /// 5-char monospaced width — matches every value `formatBps` can
    /// produce, so no width changes per tick.
    private var throughputValueReservedW: CGFloat {
        Self.measure("999MB", font: valueFont)
    }

    public func accessibilityValue(snapshot: MetricsSnapshot) -> String {
        cells.map { Self.accessibilityFor(cell: $0, snapshot: snapshot) }
             .joined(separator: ", ")
    }

    // MARK: - Cell dispatch

    private func drawCell(_ cell: BarCell, in rect: NSRect, snapshot: MetricsSnapshot) {
        let identity = Self.identityColor(for: cell)
        switch cell {
        case .cpu:
            drawComputeCell(
                symbol: "cpu",
                load: Self.cpuLoad(snapshot),
                valueText: Self.cpuPercentText(snapshot),
                severity: Self.severity(load: Self.cpuLoad(snapshot), warn: 0.60, critical: 0.85),
                identityColor: identity, in: rect
            )
        case .mem:
            drawComputeCell(
                symbol: "memorychip",
                load: Self.memLoad(snapshot),
                valueText: Self.memPercentText(snapshot),
                severity: Self.severity(load: Self.memLoad(snapshot), warn: 0.75, critical: 0.92),
                identityColor: identity, in: rect
            )
        case .net:
            // Cellular bars: reads as "signal strength" universally and
            // gives the bar row a distinct silhouette from cpu/mem chip
            // shapes and disk's flat puck.
            drawThroughputCell(
                symbol: "cellularbars",
                downBps: Self.netDownBps(snapshot),
                upBps:   Self.netUpBps(snapshot),
                identityColor: identity, in: rect
            )
        case .disk:
            // Optical disc — a flat circle, distinct shape from every
            // other cell's icon, no isometric perspective.
            drawThroughputCell(
                symbol: "opticaldisc",
                downBps: Self.diskReadBps(snapshot),
                upBps:   Self.diskWriteBps(snapshot),
                identityColor: identity, in: rect
            )
        }
    }

    // MARK: - Compute cell (icon · bar · %)

    private func drawComputeCell(
        symbol: String, load: Double, valueText: String,
        severity: Severity, identityColor: NSColor, in rect: NSRect
    ) {
        var x = rect.minX
        drawIcon(symbol, color: identityColor,
                 in: NSRect(x: x, y: 0, width: Self.iconPt, height: rect.height))
        x += Self.iconPt + Self.elementGap

        let barRect = NSRect(
            x: x, y: (rect.height - Self.barH) / 2,
            width: Self.barW, height: Self.barH
        )
        drawBar(load: load, severity: severity, in: barRect)
        x += Self.barW + Self.elementGap

        let valueW = rect.maxX - x
        drawText(valueText, font: valueFont, color: .labelColor,
                 in: NSRect(x: x, y: 0, width: valueW, height: rect.height),
                 align: .left)
    }

    // MARK: - Throughput cell (icon · ↓green value · ↑red value)

    private func drawThroughputCell(
        symbol: String, downBps: Double, upBps: Double,
        identityColor: NSColor, in rect: NSRect
    ) {
        var x = rect.minX
        drawIcon(symbol, color: identityColor,
                 in: NSRect(x: x, y: 0, width: Self.iconPt, height: rect.height))
        x += Self.iconPt + Self.elementGap

        let downText = Self.formatBps(downBps)
        let upText   = Self.formatBps(upBps)
        let reservedW = throughputValueReservedW
        let downArrowColor = Self.arrowColor(.systemGreen, bps: downBps, activity: activityArrows)
        let upArrowColor   = Self.arrowColor(.systemRed,   bps: upBps,   activity: activityArrows)

        let downValColor: NSColor = (downBps < 1024) ? .secondaryLabelColor : .labelColor
        drawText("↓", font: arrowFont, color: downArrowColor,
                 in: NSRect(x: x, y: 0, width: arrowW, height: rect.height),
                 align: .left)
        x += arrowW + Self.arrowValGap
        drawText(downText, font: valueFont, color: downValColor,
                 in: NSRect(x: x, y: 0, width: reservedW, height: rect.height),
                 align: .left)
        x += reservedW + Self.elementGap

        let upValColor: NSColor = (upBps < 1024) ? .secondaryLabelColor : .labelColor
        drawText("↑", font: arrowFont, color: upArrowColor,
                 in: NSRect(x: x, y: 0, width: arrowW, height: rect.height),
                 align: .left)
        x += arrowW + Self.arrowValGap
        drawText(upText, font: valueFont, color: upValColor,
                 in: NSRect(x: x, y: 0, width: reservedW, height: rect.height),
                 align: .left)
    }

    /// Arrow color with optional log-scale activity treatment. Without
    /// the setting the arrow is at full color/alpha. With it BOTH alpha
    /// AND saturation drop on a log curve of the throughput — a dim
    /// arrow also reads as more gray, so the visual signal is "is this
    /// direction *alive*?" in both dimensions.
    ///
    /// Saturation is quantized into 4 coarse steps (per user request) so
    /// the desaturation is a deliberate band, not a continuous slide.
    private static func arrowColor(_ base: NSColor, bps: Double, activity: Bool) -> NSColor {
        guard activity else { return base }
        let frac: CGFloat
        if bps < 100 {
            frac = 0
        } else {
            let maxLog = log10(10.0 * 1_048_576.0)             // ≈ 7.02
            let bpsLog = log10(max(bps, 100))
            frac = max(0, min(1, CGFloat(bpsLog / maxLog)))
        }
        let alpha = 0.30 + 0.70 * frac
        // 4-bucket saturation: 0.10 / 0.40 / 0.70 / 1.00. The idle bucket
        // sits at 10% saturation, not 0, so the green/red hue is barely
        // distinguishable but not gone — direction stays identifiable.
        let satBuckets: [CGFloat] = [0.10, 0.40, 0.70, 1.00]
        let bucket = min(3, Int(frac * 4))
        let sScale = satBuckets[bucket]

        let sRGB = base.usingColorSpace(.sRGB) ?? base
        var h: CGFloat = 0, s: CGFloat = 0, v: CGFloat = 0, a: CGFloat = 0
        sRGB.getHue(&h, saturation: &s, brightness: &v, alpha: &a)
        return NSColor(hue: h, saturation: s * sScale, brightness: v, alpha: alpha)
    }

    // MARK: - Drawing primitives

    private func drawIcon(_ symbol: String, color: NSColor, in rect: NSRect) {
        guard let img = TintedGlyphCache.shared.tinted(
            symbol: symbol, pointSize: Self.iconPt, weight: Self.iconWeight,
            color: color
        ) else { return }
        let s = img.size
        let drawRect = NSRect(
            x: rect.minX + (rect.width - s.width) / 2,
            y: (rect.height - s.height) / 2,
            width: s.width, height: s.height
        )
        img.draw(in: drawRect)
    }

    private func drawBar(load: Double, severity: Severity, in rect: NSRect) {
        // Small, fixed corner radius. Pill-shape (radius = height/2) made
        // low-load fills look like floating dots because the fill width
        // shrank below 2× the corner radius.
        let cornerRadius: CGFloat = 2
        let trackPath = NSBezierPath(roundedRect: rect,
                                     xRadius: cornerRadius, yRadius: cornerRadius)
        NSColor.labelColor.withAlphaComponent(0.22).setFill()
        trackPath.fill()

        let frac = CGFloat(min(max(load, 0), 1))
        guard frac > 0 else { return }
        let fillRect = NSRect(
            x: rect.minX, y: rect.minY,
            width: max(2, rect.width * frac), height: rect.height
        )
        let color: NSColor = {
            switch severity {
            case .normal:   return .systemGreen
            case .warn:     return .systemYellow
            case .critical: return .systemRed
            }
        }()
        color.setFill()
        NSBezierPath(roundedRect: fillRect,
                     xRadius: cornerRadius, yRadius: cornerRadius).fill()
    }

    private static func drawText(
        _ text: String, font: NSFont, color: NSColor,
        in rect: NSRect, align: NSTextAlignment
    ) {
        let para = NSMutableParagraphStyle()
        para.alignment = align
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: color, .paragraphStyle: para,
        ]
        let h = font.ascender + abs(font.descender)
        let y = (rect.height - h) / 2
        (text as NSString).draw(
            in: NSRect(x: rect.minX, y: y, width: rect.width, height: h),
            withAttributes: attrs
        )
    }

    private func drawText(
        _ text: String, font: NSFont, color: NSColor,
        in rect: NSRect, align: NSTextAlignment
    ) {
        Self.drawText(text, font: font, color: color, in: rect, align: align)
    }

    private static func measure(_ s: String, font: NSFont) -> CGFloat {
        ceil((s as NSString).size(withAttributes: [.font: font]).width)
    }

    // MARK: - Severity

    fileprivate enum Severity { case normal, warn, critical }
    fileprivate static func severity(load: Double, warn: Double, critical: Double) -> Severity {
        if load >= critical { return .critical }
        if load >= warn     { return .warn }
        return .normal
    }

    // MARK: - Snapshot → display values

    private static func cpuLoad(_ s: MetricsSnapshot) -> Double {
        if case .ok(let v) = s.cpu { return v.overall }
        return 0
    }
    private static func cpuPercentText(_ s: MetricsSnapshot) -> String {
        switch s.cpu {
        case .ok(let v):               return "\(Int((v.overall * 100).rounded()))%"
        case .measuring, .unavailable: return "—"
        }
    }
    private static func memLoad(_ s: MetricsSnapshot) -> Double {
        if case .ok(let v) = s.memory, v.totalBytes > 0 {
            return Double(v.usedBytes) / Double(v.totalBytes)
        }
        return 0
    }
    private static func memPercentText(_ s: MetricsSnapshot) -> String {
        switch s.memory {
        case .ok(let v) where v.totalBytes > 0:
            return "\(Int(((Double(v.usedBytes) / Double(v.totalBytes)) * 100).rounded()))%"
        case .ok, .measuring, .unavailable: return "—"
        }
    }
    private static func netDownBps(_ s: MetricsSnapshot) -> Double {
        if case .ok(let t) = s.net { return max(0, t.inPerSec) }
        return -1
    }
    private static func netUpBps(_ s: MetricsSnapshot) -> Double {
        if case .ok(let t) = s.net { return max(0, t.outPerSec) }
        return -1
    }
    private static func diskReadBps(_ s: MetricsSnapshot) -> Double {
        if case .ok(let t) = s.disk { return max(0, t.inPerSec) }
        return -1
    }
    private static func diskWriteBps(_ s: MetricsSnapshot) -> Double {
        if case .ok(let t) = s.disk { return max(0, t.outPerSec) }
        return -1
    }

    /// Throughput formatter — **always 5 characters** in a monospaced
    /// font, so the rendered width never changes regardless of magnitude.
    /// Truly-zero values render as 5 spaces — the arrow's dimming alone
    /// conveys "nothing happening", a literal `0` was redundant noise.
    /// Output examples:
    ///   "  1KB"  " 12KB"  "999KB"  "1.5MB"  " 99MB"  "999MB"  "     "  "    —"
    private static func formatBps(_ v: Double) -> String {
        if v < 0    { return "    —" }     // measuring / unavailable
        if v < 50   { return "     " }     // truly zero — let the arrow opacity speak
        if v < 1024 { return "  1KB" }     // sub-KB clamps to 1KB
        if v >= 1_048_576 {
            let mb = v / 1_048_576
            if mb >= 100 { return String(format: "%3.0fMB", mb) }
            if mb >= 10  { return String(format: " %2.0fMB", mb) }
            return String(format: "%.1fMB", mb)
        }
        let kb = v / 1024
        if kb >= 100 { return String(format: "%3.0fKB", kb) }
        if kb >= 10  { return String(format: " %2.0fKB", kb) }
        return String(format: "  %.0fKB", kb)
    }

    private static func accessibilityFor(cell: BarCell, snapshot: MetricsSnapshot) -> String {
        switch cell {
        case .cpu:  return "CPU \(cpuPercentText(snapshot))"
        case .mem:  return "Memory \(memPercentText(snapshot))"
        case .net:
            return "Network down \(formatBps(netDownBps(snapshot))), up \(formatBps(netUpBps(snapshot)))"
        case .disk:
            return "Disk read \(formatBps(diskReadBps(snapshot))), write \(formatBps(diskWriteBps(snapshot)))"
        }
    }
}

// MARK: - Tinted-glyph cache
//
// Memoizes tinted symbol images so repeated renders reuse the same NSImage
// instances. (symbol × color × point size × weight) is small enough that a
// plain dictionary covers every render combo we use; appearance toggles
// add new keys without evicting old ones, but the count stays bounded.
// The NSLock + @unchecked Sendable is defensive: in practice the cache is
// only touched from main during NSImage drawing, but AppKit doesn't commit
// to when drawing handlers run.

private struct TintedGlyphKey: Hashable {
    let symbol: String
    let pointSize: Double
    let weightRaw: Double
    let colorR: Int
    let colorG: Int
    let colorB: Int
    let colorA: Int

    init(symbol: String, pointSize: CGFloat, weight: NSFont.Weight, color: NSColor) {
        self.symbol = symbol
        self.pointSize = Double(pointSize)
        self.weightRaw = Double(weight.rawValue)
        let rgb = color.usingColorSpace(.sRGB) ?? color
        self.colorR = Int((rgb.redComponent   * 1000).rounded())
        self.colorG = Int((rgb.greenComponent * 1000).rounded())
        self.colorB = Int((rgb.blueComponent  * 1000).rounded())
        self.colorA = Int((rgb.alphaComponent * 1000).rounded())
    }
}

private final class TintedGlyphCache: @unchecked Sendable {
    static let shared = TintedGlyphCache()
    private let lock = NSLock()
    private var store: [TintedGlyphKey: NSImage] = [:]

    func tinted(
        symbol: String, pointSize: CGFloat, weight: NSFont.Weight, color: NSColor
    ) -> NSImage? {
        let key = TintedGlyphKey(symbol: symbol, pointSize: pointSize, weight: weight, color: color)
        lock.lock(); defer { lock.unlock() }
        if let cached = store[key] { return cached }
        let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: weight)
        guard
            let base = NSImage(systemSymbolName: symbol, accessibilityDescription: nil),
            let configured = base.withSymbolConfiguration(config)
        else { return nil }
        let out = NSImage(size: configured.size)
        out.lockFocus()
        color.set()
        let r = NSRect(origin: .zero, size: configured.size)
        r.fill(using: .sourceOver)
        configured.draw(at: .zero, from: r, operation: .destinationIn, fraction: 1.0)
        out.unlockFocus()
        store[key] = out
        return out
    }
}

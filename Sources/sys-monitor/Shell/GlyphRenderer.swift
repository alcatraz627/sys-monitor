import AppKit

/// One unit of the menu-bar glyph. Each cell leads with an identity SF
/// Symbol, then a numeric readout. CPU and MEM render the glyph itself as
/// a fill gauge (clipped from the bottom by load fraction). NET and DISK
/// show one combined throughput value with a small direction triangle.
public enum BarCell: Sendable, Hashable {
    case cpu, mem, net, disk
}

/// Renders one or more `BarCell` values into a single `NSImage` for the
/// status-item button. The widget's grammar matches native menu-bar items:
/// each cell is `[icon][value]`, color used only for severity (yellow on
/// warn, red on critical), monochrome at rest.
public struct GlyphRenderer {

    public let cells: [BarCell]
    private let cellLayouts: [CellLayout]
    private let totalWidth: CGFloat

    // Cell-shape constants
    private static let primaryGlyphPt:   CGFloat = 13
    private static let secondaryGlyphPt: CGFloat = 12
    private static let primaryNumPt:     CGFloat = 12
    private static let secondaryNumPt:   CGFloat = 11
    private static let unitPt:           CGFloat = 8
    private static let trianglePt:       CGFloat = 7
    private static let height:           CGFloat = 18
    private static let glyphTextGap:     CGFloat = 3
    private static let interCellGap:     CGFloat = 8
    private static let pairSepLeftGap:   CGFloat = 4
    private static let pairSepRightGap:  CGFloat = 5
    private static let separatorWidth:   CGFloat = 1
    private static let separatorHeight:  CGFloat = 12
    private static let leftPad:          CGFloat = 9
    private static let rightPad:         CGFloat = 9
    // Reserved value widths so the overall widget doesn't shift even
    // though individual numbers may.
    private static let cpuMemNumberBoxW: CGFloat = 30   // "100%"
    private static let throughputNumW:   CGFloat = 26   // "999K" + small triangle

    private struct CellLayout {
        let cell: BarCell
        let width: CGFloat
        let isPrimary: Bool
    }

    public init(cells: [BarCell] = [.cpu, .mem]) {
        let effectiveCells = cells.isEmpty ? [.cpu] : cells
        self.cells = effectiveCells
        var layouts: [CellLayout] = []
        for cell in effectiveCells {
            switch cell {
            case .cpu, .mem:
                layouts.append(.init(
                    cell: cell,
                    width: Self.primaryGlyphPt + Self.glyphTextGap + Self.cpuMemNumberBoxW,
                    isPrimary: true
                ))
            case .net, .disk:
                layouts.append(.init(
                    cell: cell,
                    width: Self.secondaryGlyphPt + Self.glyphTextGap + Self.throughputNumW,
                    isPrimary: false
                ))
            }
        }
        self.cellLayouts = layouts

        // Total width = padding + cells + gaps. Gaps are intra-pair (8pt)
        // or pair-separator (4 + 1 + 5 = 10pt) where adjacency crosses the
        // compute/IO boundary.
        var w: CGFloat = Self.leftPad
        for (i, layout) in layouts.enumerated() {
            w += layout.width
            if i < layouts.count - 1 {
                let next = layouts[i + 1]
                if Self.isPairBoundary(from: layout.cell, to: next.cell) {
                    w += Self.pairSepLeftGap + Self.separatorWidth + Self.pairSepRightGap
                } else {
                    w += Self.interCellGap
                }
            }
        }
        w += Self.rightPad
        self.totalWidth = w
    }

    public func render(snapshot: MetricsSnapshot) -> NSImage {
        let size = NSSize(width: totalWidth, height: Self.height)
        let layouts = self.cellLayouts

        let image = NSImage(size: size, flipped: false) { _ in
            var x: CGFloat = Self.leftPad
            for (i, layout) in layouts.enumerated() {
                let cellRect = NSRect(x: x, y: 0, width: layout.width, height: Self.height)
                Self.drawCell(layout.cell, in: cellRect, snapshot: snapshot)
                x += layout.width
                if i < layouts.count - 1 {
                    let next = layouts[i + 1]
                    if Self.isPairBoundary(from: layout.cell, to: next.cell) {
                        x += Self.pairSepLeftGap
                        Self.drawSeparator(atX: x)
                        x += Self.separatorWidth + Self.pairSepRightGap
                    } else {
                        x += Self.interCellGap
                    }
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

    // MARK: - Layout helpers

    /// The compute pair (CPU, MEM) and the I/O pair (NET, DISK) are visually
    /// separated by a hairline. Any time we cross that boundary going
    /// left-to-right, drop in a separator.
    private static func isPairBoundary(from a: BarCell, to b: BarCell) -> Bool {
        let computeSet: Set<BarCell> = [.cpu, .mem]
        let ioSet: Set<BarCell>      = [.net, .disk]
        return (computeSet.contains(a) && ioSet.contains(b))
            || (ioSet.contains(a) && computeSet.contains(b))
    }

    private static func drawSeparator(atX x: CGFloat) {
        // 1pt labelColor at 30% alpha — tertiary still washes out against
        // vibrant menu-bar materials; this registers on any background.
        let y = (height - separatorHeight) / 2
        let rect = NSRect(x: x, y: y, width: separatorWidth, height: separatorHeight)
        NSColor.labelColor.withAlphaComponent(0.30).setFill()
        rect.fill()
    }

    // MARK: - Cell dispatch

    private static func drawCell(_ cell: BarCell, in rect: NSRect, snapshot: MetricsSnapshot) {
        switch cell {
        case .cpu:
            drawComputeCell(
                symbol: "cpu",
                load: cpuLoad(snapshot),
                text: cpuPercentText(snapshot),
                severity: severity(load: cpuLoad(snapshot), warn: 0.60, critical: 0.85),
                isMeasuring: !cpuOK(snapshot),
                in: rect
            )
        case .mem:
            drawComputeCell(
                symbol: "memorychip",
                load: memLoad(snapshot),
                text: memPercentText(snapshot),
                severity: severity(load: memLoad(snapshot), warn: 0.75, critical: 0.92),
                isMeasuring: !memOK(snapshot),
                in: rect
            )
        case .net:
            // `network` carries identity without implying direction —
            // direction is shown by the trailing ▲/▼/• triangle.
            drawThroughputCell(
                symbol: "network",
                metric: snapshot.net,
                in: rect
            )
        case .disk:
            drawThroughputCell(
                symbol: "internaldrive",
                metric: snapshot.disk,
                in: rect
            )
        }
    }

    // MARK: - CPU / MEM cell (glyph-as-gauge + number)

    private static func drawComputeCell(
        symbol: String, load: Double, text: String,
        severity: Severity, isMeasuring: Bool,
        in rect: NSRect
    ) {
        let glyphRect = NSRect(
            x: rect.minX, y: 0,
            width: primaryGlyphPt, height: rect.height
        )
        drawGaugeGlyph(
            symbol: symbol, pointSize: primaryGlyphPt, weight: .medium,
            load: isMeasuring ? 0 : load,
            severity: severity,
            in: glyphRect
        )

        let textRect = NSRect(
            x: rect.minX + primaryGlyphPt + glyphTextGap, y: 0,
            width: rect.width - primaryGlyphPt - glyphTextGap,
            height: rect.height
        )
        drawPercent(text: text, severity: severity, in: textRect)
    }

    /// Draws an SF Symbol with a load-fraction fill rising from the
    /// bottom. Track (unfilled portion) is `quaternaryLabelColor`; fill
    /// is `labelColor` at normal load, `systemYellow` at warn, `systemRed`
    /// at critical. The glyph IS the gauge.
    ///
    /// Tinted images are pulled from a shared bounded cache to keep RSS
    /// flat — each render would otherwise allocate two fresh NSImages per
    /// CPU/MEM cell via `lockFocus`.
    private static func drawGaugeGlyph(
        symbol: String, pointSize: CGFloat, weight: NSFont.Weight,
        load: Double, severity: Severity,
        in rect: NSRect
    ) {
        guard let trackImg = TintedGlyphCache.shared.tinted(
            symbol: symbol, pointSize: pointSize, weight: weight,
            color: .quaternaryLabelColor
        ) else { return }

        let s = trackImg.size
        let drawRect = NSRect(
            x: rect.minX + (rect.width - s.width) / 2,
            y: (rect.height - s.height) / 2,
            width: s.width, height: s.height
        )
        trackImg.draw(in: drawRect)

        let frac = CGFloat(min(max(load, 0), 1))
        guard frac > 0 else { return }
        let fillColor: NSColor = {
            switch severity {
            case .normal:   return .labelColor
            case .warn:     return .systemYellow
            case .critical: return .systemRed
            }
        }()
        guard let fillImg = TintedGlyphCache.shared.tinted(
            symbol: symbol, pointSize: pointSize, weight: weight, color: fillColor
        ) else { return }

        let fillHeight = s.height * frac
        let clipRect = NSRect(
            x: drawRect.minX, y: drawRect.minY,
            width: s.width, height: fillHeight
        )
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: clipRect).addClip()
        fillImg.draw(in: drawRect)
        NSGraphicsContext.restoreGraphicsState()
    }

    private static func drawPercent(text: String, severity: Severity, in rect: NSRect) {
        // Split "26%" into digits + "%" so we can render the unit smaller.
        let digits: String
        let unit: String
        if let pIdx = text.firstIndex(of: "%") {
            digits = String(text[..<pIdx])
            unit = "%"
        } else {
            digits = text
            unit = ""
        }
        let numberFont = roundedFont(size: primaryNumPt, weight: severity == .critical ? .bold : .semibold)
        let unitFont   = roundedFont(size: unitPt, weight: .medium)
        let numberColor: NSColor = severity == .critical ? .systemRed : .labelColor
        let unitColor:   NSColor = .tertiaryLabelColor

        // Combine into one attributed string so layout is automatic.
        let attr = NSMutableAttributedString()
        attr.append(NSAttributedString(string: digits, attributes: [
            .font: numberFont,
            .foregroundColor: numberColor,
        ]))
        if !unit.isEmpty {
            attr.append(NSAttributedString(string: unit, attributes: [
                .font: unitFont,
                .foregroundColor: unitColor,
                .baselineOffset: 0.5,
            ]))
        }

        let attrSize = attr.size()
        let drawY = (rect.height - attrSize.height) / 2
        let drawRect = NSRect(
            x: rect.minX + (rect.width - attrSize.width),  // right-aligned in box
            y: drawY,
            width: attrSize.width, height: attrSize.height
        )
        attr.draw(in: drawRect)
    }

    // MARK: - NET / DISK cell (icon + combined value + direction triangle)

    private static func drawThroughputCell(
        symbol: String, metric: Metric<Throughput>, in rect: NSRect
    ) {
        let glyphRect = NSRect(
            x: rect.minX, y: 0,
            width: secondaryGlyphPt, height: rect.height
        )
        drawIconOnly(
            symbol: symbol, pointSize: secondaryGlyphPt, weight: .regular,
            color: .tertiaryLabelColor,
            in: glyphRect
        )

        let textRect = NSRect(
            x: rect.minX + secondaryGlyphPt + glyphTextGap, y: 0,
            width: rect.width - secondaryGlyphPt - glyphTextGap,
            height: rect.height
        )
        let (display, direction) = throughputDisplay(metric: metric)
        drawThroughputValue(display: display, direction: direction, in: textRect)
    }

    private static func drawIconOnly(
        symbol: String, pointSize: CGFloat, weight: NSFont.Weight,
        color: NSColor, in rect: NSRect
    ) {
        guard let img = TintedGlyphCache.shared.tinted(
            symbol: symbol, pointSize: pointSize, weight: weight, color: color
        ) else { return }
        let s = img.size
        let drawRect = NSRect(
            x: rect.minX + (rect.width - s.width) / 2,
            y: (rect.height - s.height) / 2,
            width: s.width, height: s.height
        )
        img.draw(in: drawRect)
    }

    fileprivate enum Direction {
        case down, up, balanced, none

        /// Unicode triangle: ▼ down-dominant, ▲ up-dominant, • balanced,
        /// nil for idle (no triangle drawn).
        var triangle: String? {
            switch self {
            case .down:     return "▼"
            case .up:       return "▲"
            case .balanced: return "•"
            case .none:     return nil
            }
        }

        var spokenLabel: String {
            switch self {
            case .down:     return "downloading"
            case .up:       return "uploading"
            case .balanced: return "balanced"
            case .none:     return "idle"
            }
        }
    }

    private static func throughputDisplay(metric: Metric<Throughput>) -> (display: String, direction: Direction) {
        switch metric {
        case .measuring, .unavailable:
            return ("—", .none)
        case .ok(let t):
            let down = max(0, t.inPerSec)
            let up   = max(0, t.outPerSec)
            let total = down + up
            // Idle: anything under 1 KB/s combined reads as quiet. The
            // em-dash + neutral color is the native "nothing here" signal.
            if total < 1024 {
                return ("—", .none)
            }
            let dir: Direction
            if down > up * 1.6      { dir = .down }
            else if up > down * 1.6 { dir = .up }
            else                    { dir = .balanced }
            return (compactBytes(total), dir)
        }
    }

    private static func drawThroughputValue(display: String, direction: Direction, in rect: NSRect) {
        // Split "999K" into "999" + "K" so the unit can render smaller.
        let digits: String
        let unit: String
        if let unitIdx = display.firstIndex(where: { "BKMG".contains($0) }) {
            digits = String(display[..<unitIdx])
            unit = String(display[unitIdx])
        } else if display == "—" {
            digits = "—"
            unit = ""
        } else {
            digits = display
            unit = ""
        }

        let numberFont = roundedFont(size: secondaryNumPt, weight: .regular)
        let unitFont   = roundedFont(size: unitPt, weight: .regular)
        // Triangle bumped to medium weight; at 7pt regular it reads as a
        // decorative diamond rather than a direction indicator.
        let dirFont    = roundedFont(size: trianglePt, weight: .semibold)

        let attr = NSMutableAttributedString()
        attr.append(NSAttributedString(string: digits, attributes: [
            .font: numberFont,
            .foregroundColor: display == "—" ? NSColor.tertiaryLabelColor : NSColor.labelColor,
        ]))
        if !unit.isEmpty {
            attr.append(NSAttributedString(string: unit, attributes: [
                .font: unitFont,
                .foregroundColor: NSColor.tertiaryLabelColor,
                .baselineOffset: 0.5,
            ]))
        }
        if let triangle = direction.triangle {
            // 1pt kern instead of a full space — keeps the triangle tight
            // to the value it modifies.
            attr.append(NSAttributedString(string: triangle, attributes: [
                .font: dirFont,
                .foregroundColor: NSColor.secondaryLabelColor,
                .baselineOffset: 1.5,
                .kern: 1,
            ]))
        }

        let attrSize = attr.size()
        let drawY = (rect.height - attrSize.height) / 2
        let drawRect = NSRect(
            x: rect.minX + (rect.width - attrSize.width),  // right-aligned in cell
            y: drawY,
            width: attrSize.width, height: attrSize.height
        )
        attr.draw(in: drawRect)
    }

    // MARK: - Severity

    private enum Severity { case normal, warn, critical }
    private static func severity(load: Double, warn: Double, critical: Double) -> Severity {
        if load >= critical { return .critical }
        if load >= warn     { return .warn }
        return .normal
    }

    // MARK: - Snapshot → display values

    private static func cpuLoad(_ s: MetricsSnapshot) -> Double {
        if case .ok(let v) = s.cpu { return v.overall }
        return 0
    }
    private static func cpuOK(_ s: MetricsSnapshot) -> Bool {
        if case .ok = s.cpu { return true }; return false
    }
    private static func cpuPercentText(_ s: MetricsSnapshot) -> String {
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
    private static func memOK(_ s: MetricsSnapshot) -> Bool {
        if case .ok(let v) = s.memory, v.totalBytes > 0 { return true }
        return false
    }
    private static func memPercentText(_ s: MetricsSnapshot) -> String {
        switch s.memory {
        case .ok(let v) where v.totalBytes > 0:
            let frac = Double(v.usedBytes) / Double(v.totalBytes)
            return "\(Int((frac * 100).rounded()))%"
        case .ok, .measuring, .unavailable: return "—"
        }
    }

    /// Compact bytes/sec formatter. We round aggressively (no decimal) for
    /// menu-bar density — the panel shows precise values for users who care.
    private static func compactBytes(_ v: Double) -> String {
        if v >= 1_048_576 { return "\(Int((v / 1_048_576).rounded()))M" }
        if v >= 1_024     { return "\(Int((v / 1_024).rounded()))K" }
        return "\(Int(v))B"
    }

    // MARK: - Fonts

    /// SF Pro Rounded at the requested size + weight. Falls back to the
    /// default system font if rounded isn't available on the host (it
    /// always is on macOS 11+, but defensive).
    private static func roundedFont(size: CGFloat, weight: NSFont.Weight) -> NSFont {
        let base = NSFont.systemFont(ofSize: size, weight: weight)
        if let descriptor = base.fontDescriptor.withDesign(.rounded),
           let rounded = NSFont(descriptor: descriptor, size: size) {
            return rounded
        }
        return base
    }

    private static func accessibilityFor(cell: BarCell, snapshot: MetricsSnapshot) -> String {
        switch cell {
        case .cpu:  return "CPU \(cpuPercentText(snapshot))"
        case .mem:  return "Memory \(memPercentText(snapshot))"
        case .net:
            let (d, dir) = throughputDisplay(metric: snapshot.net)
            return "Network \(d) \(dir.spokenLabel)"
        case .disk:
            let (d, dir) = throughputDisplay(metric: snapshot.disk)
            return "Disk \(d) \(dir.spokenLabel)"
        }
    }
}

// MARK: - Tinted-glyph cache
//
// Memoizes tinted symbol images so repeated renders reuse the same
// NSImage instances. The space of (symbol × color × point size × weight)
// the bar draws from is small — a few dozen entries cover every
// appearance — so a plain dictionary is enough.
//
// The NSLock + @unchecked Sendable is defensive: in practice the cache
// is only touched from main during NSImage drawing, but AppKit doesn't
// commit publicly to when image drawing handlers run, and the lock cost
// is trivial.

/// Identity for a cached tinted symbol image. NSColor doesn't conform to
/// Hashable, so we key by its sRGB components rounded to 3 decimals —
/// effectively identity for the system colors we draw with.
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

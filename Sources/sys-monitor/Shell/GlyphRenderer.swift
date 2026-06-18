import AppKit

/// One cell of the menu-bar widget.
/// `cpu` / `mem` render as: icon · horizontal-progress-bar · `XX%`.
/// `net` / `disk` render as: icon · ↓green-arrow value · ↑red-arrow value.
/// (GPU/power lives in the panel's POWER row via IOReport, not the bar —
/// a watts cell would break the bar's fixed-width grammar.)
public enum BarCell: String, Sendable, Hashable, CaseIterable, Codable {
    case cpu, mem, net, disk, battery

    /// Human label for the settings list. The bar itself draws an icon,
    /// not this text.
    public var displayName: String {
        switch self {
        case .cpu:     return "CPU"
        case .mem:     return "Memory"
        case .net:     return "Network"
        case .disk:    return "Disk I/O"
        case .battery: return "Battery"
        }
    }
}

/// How throughput numbers are displayed everywhere they appear (the glyph
/// cells and the panel's NET/DISK rows). Networking is conventionally
/// quoted in bits/s, storage in bytes/s — different users expect
/// different defaults, so it's a single app-wide preference.
public enum ThroughputUnit: String, Sendable, Hashable, CaseIterable, Codable {
    case bytesPerSec, bitsPerSec

    public var displayName: String {
        switch self {
        case .bytesPerSec: return "Bytes/s"
        case .bitsPerSec:  return "Bits/s"
        }
    }

    /// Bits are 8× the byte count; the unit letter switches B→b. Both keep
    /// the K/M/G tier letter, so the 5-char width grammar is identical.
    var scale: Double { self == .bitsPerSec ? 8 : 1 }
    var letter: String { self == .bitsPerSec ? "b" : "B" }
}

/// The bar's size/spacing constants, bundled so the glyph can render at a
/// standard or a compact density. Compact shrinks every dimension for users
/// who want a smaller menu-bar footprint; standard is the shipped look.
public struct GlyphDensity: Sendable {
    let iconPt, barW, barH, valuePt, arrowPt, height: CGFloat
    let elementGap, groupGap, arrowValGap, leftPad, rightPad: CGFloat
    let iconWeight: NSFont.Weight

    public static let standard = GlyphDensity(
        iconPt: 17, barW: 16, barH: 12, valuePt: 11, arrowPt: 11, height: 18,
        elementGap: 3, groupGap: 10, arrowValGap: 1, leftPad: 14, rightPad: 7,
        iconWeight: .bold)

    public static let compact = GlyphDensity(
        iconPt: 13, barW: 12, barH: 9, valuePt: 9, arrowPt: 9, height: 16,
        elementGap: 2, groupGap: 6, arrowValGap: 1, leftPad: 8, rightPad: 5,
        iconWeight: .semibold)
}

/// Renders the cells into a fixed-width `NSImage` for the status-item
/// button. Grouping follows gestalt by proximity: elements within a cell
/// are tight; the gap between cells is ~1.5× wider.
public struct GlyphRenderer {

    public let cells: [BarCell]
    /// When true, the throughput arrows dim/brighten on a log scale of
    /// their current rate — visual "level of activity" without animation.
    public let activityArrows: Bool
    /// Bytes/s or bits/s for the NET / DISK cells.
    public let throughputUnit: ThroughputUnit
    /// Per-metric warn/critical load levels for the CPU / MEM cell colors.
    public let thresholds: SeverityThresholds
    /// Size/spacing constants — standard or compact.
    public let density: GlyphDensity
    private let valueFont: NSFont
    private let arrowFont: NSFont
    private let arrowW: CGFloat

    /// Constant identity color per cell. The bar still uses load colors
    /// (green / yellow / red); the icon's hue is purely "which cell is
    /// this?" — read it the way you read battery/wifi/bluetooth icons.
    private static func identityColor(for cell: BarCell) -> NSColor {
        switch cell {
        case .cpu:  return NSColor(red: 0.96, green: 0.74, blue: 0.20, alpha: 1) // golden
        case .mem:  return .systemTeal
        case .net:  return .systemPurple
        case .disk: return NSColor(red: 0.52, green: 0.65, blue: 0.80, alpha: 1) // brighter slate-blue
        case .battery: return .systemGreen   // overridden at draw by charge color
        }
    }

    public init(cells: [BarCell] = [.cpu, .mem], activityArrows: Bool = true,
                throughputUnit: ThroughputUnit = .bytesPerSec,
                thresholds: SeverityThresholds = .defaults,
                density: GlyphDensity = .standard) {
        let effective = cells.isEmpty ? [.cpu] : cells
        self.cells = effective
        self.activityArrows = activityArrows
        self.throughputUnit = throughputUnit
        self.thresholds = thresholds
        self.density = density
        let vFont = NSFont.monospacedDigitSystemFont(ofSize: density.valuePt, weight: .medium)
        let aFont = NSFont.systemFont(ofSize: density.arrowPt, weight: .semibold)
        self.valueFont = vFont
        self.arrowFont = aFont
        self.arrowW    = Self.measure("↓", font: aFont)
        // Constant per renderer instance (fonts are fixed at init) — the
        // M/G/K letters aren't digit-monospaced, so take the max across
        // units once instead of re-measuring two strings every tick.
        self.throughputValueReservedW = max(
            Self.measure("999MB", font: vFont),
            Self.measure("999GB", font: vFont)
        )
    }

    /// Cheap identity of what `render` would draw for this snapshot. Two
    /// snapshots with equal keys produce visually identical glyphs, so the
    /// caller can skip the NSImage rebuild. Quantization (bar fill and
    /// arrow activity to 1/32) deliberately treats imperceptible
    /// differences as equal; severity is included explicitly because its
    /// thresholds don't align with bucket edges.
    public func renderKey(snapshot: MetricsSnapshot) -> String {
        func state<T>(_ m: Metric<T>) -> String {
            switch m {
            case .ok: return "o"
            case .measuring: return "m"
            case .unavailable: return "u"
            }
        }
        var parts: [String] = []
        parts.reserveCapacity(cells.count)
        for cell in cells {
            switch cell {
            case .cpu:
                let load = Self.cpuLoad(snapshot)
                let sev = Self.severity(load: load, warn: thresholds.cpuWarn, critical: thresholds.cpuCritical)
                parts.append("c\(state(snapshot.cpu))\(Self.cpuPercentText(snapshot))|\(Int(load * 32))|\(sev)")
            case .mem:
                let load = Self.memLoad(snapshot)
                let sev = Self.severity(load: load, warn: thresholds.memWarn, critical: thresholds.memCritical)
                parts.append("m\(state(snapshot.memory))\(Self.memPercentText(snapshot))|\(Int(load * 32))|\(sev)")
            case .net:
                let d = Self.netDownBps(snapshot), u = Self.netUpBps(snapshot)
                parts.append("n\(state(snapshot.net))\(fmt(d))|\(fmt(u))|\(Int(Self.activityFrac(bps: d) * 32))|\(Int(Self.activityFrac(bps: u) * 32))")
            case .disk:
                let r = Self.diskReadBps(snapshot), w = Self.diskWriteBps(snapshot)
                parts.append("d\(state(snapshot.disk))\(fmt(r))|\(fmt(w))|\(Int(Self.activityFrac(bps: r) * 32))|\(Int(Self.activityFrac(bps: w) * 32))")
            case .battery:
                let b = snapshot.battery.map { "\($0.percent)\($0.charging ? "c" : "")\($0.onAC ? "a" : "")" } ?? "-"
                parts.append("b\(b)")
            }
        }
        return parts.joined(separator: ";")
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
        let groupsTotal = CGFloat(max(0, cells.count - 1)) * density.groupGap
        let totalWidth = density.leftPad + cellsTotal + groupsTotal + density.rightPad

        let size = NSSize(width: totalWidth, height: density.height)
        let cells = self.cells
        let renderer = self

        let image = NSImage(size: size, flipped: false) { _ in
            var x: CGFloat = density.leftPad
            for (i, cell) in cells.enumerated() {
                let cellRect = NSRect(x: x, y: 0, width: cellWidths[i], height: density.height)
                renderer.drawCell(cell, in: cellRect, snapshot: snapshot)
                x += cellWidths[i]
                if i < cells.count - 1 { x += density.groupGap }
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
            return density.iconPt + density.elementGap + density.barW + density.elementGap + textW
        case .mem:
            let text = Self.memPercentText(snapshot)
            let textW = max(Self.measure(text, font: valueFont),
                            Self.measure("00%", font: valueFont))
            return density.iconPt + density.elementGap + density.barW + density.elementGap + textW
        case .net:
            return throughputCellWidth(
                downText: fmt(Self.netDownBps(snapshot)),
                upText:   fmt(Self.netUpBps(snapshot))
            )
        case .disk:
            return throughputCellWidth(
                downText: fmt(Self.diskReadBps(snapshot)),
                upText:   fmt(Self.diskWriteBps(snapshot))
            )
        case .battery:
            let textW = max(Self.measure(Self.batteryPercentText(snapshot), font: valueFont),
                            Self.measure("100%", font: valueFont))
            return density.iconPt + density.elementGap + textW
        }
    }

    private func throughputCellWidth(downText: String, upText: String) -> CGFloat {
        // `throughputValueReservedW` is the maximum width any formatBps
        // string can produce (measured once at init), so both columns use
        // the same reserved cap — no per-tick `max(down, up)` needed.
        // (Strings are NOT equal-width by construction: "." and the unit
        // letters aren't digit-monospaced; the reservation is what fixes
        // the width.)
        let valueW = throughputValueReservedW
        let halfW = arrowW + density.arrowValGap + valueW
        return density.iconPt + density.elementGap + halfW + density.elementGap + halfW
    }

    /// 5-char reserved width — wide enough for every value `formatBps`
    /// can produce. Measured once at init; see the init comment.
    private let throughputValueReservedW: CGFloat

    public func accessibilityValue(snapshot: MetricsSnapshot) -> String {
        cells.map { accessibilityFor(cell: $0, snapshot: snapshot) }
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
                severity: Self.severity(load: Self.cpuLoad(snapshot), warn: thresholds.cpuWarn, critical: thresholds.cpuCritical),
                identityColor: identity, in: rect
            )
        case .mem:
            drawComputeCell(
                symbol: "memorychip",
                load: Self.memLoad(snapshot),
                valueText: Self.memPercentText(snapshot),
                severity: Self.severity(load: Self.memLoad(snapshot), warn: thresholds.memWarn, critical: thresholds.memCritical),
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
        case .battery:
            // Icon + % only (no bar): the battery glyph already encodes the
            // level by which symbol it picks, and the color carries severity
            // (inverted — low charge is the warning, not high).
            let color = Self.batteryColor(snapshot)
            drawValueCell(symbol: Self.batterySymbol(snapshot),
                          valueText: Self.batteryPercentText(snapshot),
                          iconColor: color, valueColor: color, in: rect)
        }
    }

    // MARK: - Value cell (icon · value, no bar) — used by battery

    private func drawValueCell(symbol: String, valueText: String,
                               iconColor: NSColor, valueColor: NSColor, in rect: NSRect) {
        var x = rect.minX
        drawIcon(symbol, color: iconColor,
                 in: NSRect(x: x, y: 0, width: density.iconPt, height: rect.height))
        x += density.iconPt + density.elementGap
        drawText(valueText, font: valueFont, color: valueColor,
                 in: NSRect(x: x, y: 0, width: rect.maxX - x, height: rect.height),
                 align: .left)
    }

    // MARK: - Compute cell (icon · bar · %)

    private func drawComputeCell(
        symbol: String, load: Double, valueText: String,
        severity: Severity, identityColor: NSColor, in rect: NSRect
    ) {
        var x = rect.minX
        drawIcon(symbol, color: identityColor,
                 in: NSRect(x: x, y: 0, width: density.iconPt, height: rect.height))
        x += density.iconPt + density.elementGap

        let barRect = NSRect(
            x: x, y: (rect.height - density.barH) / 2,
            width: density.barW, height: density.barH
        )
        drawBar(load: load, severity: severity, in: barRect)
        x += density.barW + density.elementGap

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
                 in: NSRect(x: x, y: 0, width: density.iconPt, height: rect.height))
        x += density.iconPt + density.elementGap

        let downText = fmt(downBps)
        let upText   = fmt(upBps)
        let reservedW = throughputValueReservedW
        let downArrowColor = Self.arrowColor(.systemGreen, bps: downBps, activity: activityArrows)
        let upArrowColor   = Self.arrowColor(.systemRed,   bps: upBps,   activity: activityArrows)

        let downValColor: NSColor = (downBps < 1024) ? .secondaryLabelColor : .labelColor
        drawText("↓", font: arrowFont, color: downArrowColor,
                 in: NSRect(x: x, y: 0, width: arrowW, height: rect.height),
                 align: .left)
        x += arrowW + density.arrowValGap
        drawText(downText, font: valueFont, color: downValColor,
                 in: NSRect(x: x, y: 0, width: reservedW, height: rect.height),
                 align: .left)
        x += reservedW + density.elementGap

        let upValColor: NSColor = (upBps < 1024) ? .secondaryLabelColor : .labelColor
        drawText("↑", font: arrowFont, color: upArrowColor,
                 in: NSRect(x: x, y: 0, width: arrowW, height: rect.height),
                 align: .left)
        x += arrowW + density.arrowValGap
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
        let frac = activityFrac(bps: bps)
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

    /// Log-scale activity fraction (0…1) shared by the arrow color and
    /// the render key, so the key's buckets track the drawn output.
    private static func activityFrac(bps: Double) -> CGFloat {
        guard bps >= 100 else { return 0 }
        let maxLog = log10(10.0 * 1_048_576.0)             // ≈ 7.02
        let bpsLog = log10(max(bps, 100))
        return max(0, min(1, CGFloat(bpsLog / maxLog)))
    }

    // MARK: - Drawing primitives

    private func drawIcon(_ symbol: String, color: NSColor, in rect: NSRect) {
        guard let img = TintedGlyphCache.shared.tinted(
            symbol: symbol, pointSize: density.iconPt, weight: density.iconWeight,
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

    /// Throughput formatter — **always 5 characters**, so the rendered
    /// width never changes regardless of magnitude. Truly-zero values
    /// render as 5 spaces — the arrow's dimming alone conveys "nothing
    /// happening", a literal `0` was redundant noise.
    ///
    /// Magnitude bump rule: each tier promotes to the next when the
    /// lower-tier value would round to 4 digits (≥ 999.5), not at the
    /// power-of-1024 boundary. `%3.0fXB` rounds the float, so without
    /// this rule `999.7 MB/s` formats as `"1000MB"` — 6 chars — and
    /// the cell clips. NVMe sequential reads on Apple Silicon hit
    /// 3–7 GB/s routinely, so the GB tier is reachable in practice.
    ///
    /// Output examples:
    ///   "  1KB"  " 12KB"  "999KB"  "1.0MB"  " 99MB"  "999MB"
    ///   "1.0GB"  " 10GB"  "999GB"  "     "  "    —"
    // Internal, not private: the panel's throughput cells reuse this
    // exact grammar (plus a "/s" suffix) so both surfaces stay
    // width-stable and read identically.
    /// Instance shorthand: format at this renderer's configured unit. The
    /// glyph's internal call sites use this so the bytes/bits choice flows
    /// without threading the unit through every signature.
    private func fmt(_ v: Double) -> String { Self.formatBps(v, unit: throughputUnit) }

    static func formatBps(_ v: Double, unit: ThroughputUnit = .bytesPerSec) -> String {
        if v < 0 { return "    —" }     // measuring / unavailable
        let u = unit.letter             // "B" or "b" — width is identical
        let scaled = v * unit.scale
        if scaled < 50   { return "     " }       // truly zero — arrow opacity speaks
        if scaled < 1024 { return "  1K\(u)" }    // sub-K clamps to 1K

        let kb = scaled / 1024
        if kb < 999.5 {
            if kb >= 100 { return String(format: "%3.0fK\(u)", kb) }
            if kb >= 10  { return String(format: " %2.0fK\(u)", kb) }
            return String(format: "  %.0fK\(u)", kb)
        }

        let mb = scaled / 1_048_576
        if mb < 999.5 {
            if mb >= 100 { return String(format: "%3.0fM\(u)", mb) }
            if mb >= 10  { return String(format: " %2.0fM\(u)", mb) }
            return String(format: "%.1fM\(u)", mb)
        }

        // ≥ TB territory would re-introduce the 4-digit overflow; cap at
        // 999G since that's already an order of magnitude beyond any
        // practical disk or NIC on a personal Mac. (Bits/s reaches the G
        // tier 8× sooner, but a 10 GbE NIC saturated is ~1.25 GB/s = 10 Gb/s,
        // still inside the cap.)
        let gb = min(scaled / 1_073_741_824, 999)
        if gb >= 100 { return String(format: "%3.0fG\(u)", gb) }
        if gb >= 10  { return String(format: " %2.0fG\(u)", gb) }
        return String(format: "%.1fG\(u)", gb)
    }

    private func accessibilityFor(cell: BarCell, snapshot: MetricsSnapshot) -> String {
        switch cell {
        case .cpu:  return "CPU \(Self.cpuPercentText(snapshot))"
        case .mem:  return "Memory \(Self.memPercentText(snapshot))"
        case .net:
            return "Network down \(fmt(Self.netDownBps(snapshot))), up \(fmt(Self.netUpBps(snapshot)))"
        case .disk:
            return "Disk read \(fmt(Self.diskReadBps(snapshot))), write \(fmt(Self.diskWriteBps(snapshot)))"
        case .battery:
            guard let b = snapshot.battery else { return "Battery unavailable" }
            let st = b.charging ? " charging" : (b.onAC ? " on AC power" : "")
            return "Battery \(b.percent)%\(st)"
        }
    }

    // MARK: - Battery cell helpers

    private static func batteryPercentText(_ s: MetricsSnapshot) -> String {
        if let b = s.battery { return "\(b.percent)%" }
        return "—"
    }

    /// Level-appropriate SF Symbol; the bolt variant while charging.
    private static func batterySymbol(_ s: MetricsSnapshot) -> String {
        guard let b = s.battery else { return "battery.0percent" }
        if b.charging || b.charged { return "battery.100percent.bolt" }
        switch b.percent {
        case ..<13: return "battery.0percent"
        case ..<38: return "battery.25percent"
        case ..<63: return "battery.50percent"
        case ..<88: return "battery.75percent"
        default:    return "battery.100percent"
        }
    }

    /// Inverted severity: a *low* charge is the warning. Plugged in or
    /// charging always reads green regardless of level.
    private static func batteryColor(_ s: MetricsSnapshot) -> NSColor {
        guard let b = s.battery else { return .secondaryLabelColor }
        if b.charging || b.charged || b.onAC { return .systemGreen }
        switch b.percent {
        case ..<20: return .systemRed
        case ..<40: return .systemOrange
        default:    return .labelColor
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

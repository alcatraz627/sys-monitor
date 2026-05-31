import AppKit
import SwiftUI

/// Stand-alone preview window for iterating on the menu-bar widget design
/// without rebuilding the whole shell each time. Triggered by passing
/// `--preview-widget` on the command line — `main.swift` short-circuits
/// the NSStatusItem path and shows this window instead.
@MainActor
enum WidgetPreview {
    static func show() {
        NSApplication.shared.setActivationPolicy(.regular)
        let host = NSHostingController(rootView: PreviewRoot())
        let window = NSWindow(contentViewController: host)
        window.title = "sys-monitor — Widget design preview"
        window.styleMask = [.titled, .closable, .resizable]
        window.setContentSize(NSSize(width: 760, height: 560))
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

// MARK: - Shared sample state

private struct SampleData {
    let cpu: Double          // 0..1
    let mem: Double          // 0..1
    let gpu: Double?         // 0..1; nil = no GPU sampler yet
    let netDown: Double      // bytes / sec
    let netUp: Double
    let diskRead: Double
    let diskWrite: Double

    static let demo = SampleData(
        cpu: 0.37, mem: 0.73, gpu: 0.45,
        netDown: 555 * 1024, netUp: 100 * 1024,
        diskRead: 5 * 1024 * 1024, diskWrite: 200 * 1024
    )
}

// MARK: - Preview root

private struct PreviewRoot: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Icon picker — memory + disk")
                        .font(.system(size: 18, weight: .semibold))
                    Text("Each icon rendered at the live widget's exact size (17pt), weight (bold), and identity color (purple for memory, slate-blue for disk), against a simulated menu-bar background. Tell me which slug you want for each.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal)
                .padding(.top, 16)

                iconRow(
                    title: "Network icon options — purple identity (pick by letter)",
                    color: .systemPurple,
                    candidates: [
                        ("A: network",                                  "Globe + latitude lines"),
                        ("B: globe",                                    "Simple outline globe"),
                        ("C: wifi",                                     "WiFi fan (radio waves up)"),
                        ("D: antenna.radiowaves.left.and.right",        "Antenna with arc waves both sides"),
                        ("E: dot.radiowaves.up.forward",                "Dot emitting waves (CURRENT)"),
                        ("F: point.3.filled.connected.trianglepath.dotted", "Three connected nodes"),
                    ]
                )

                Text("How to call it out: '\(slugCallout)'")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal)
                    .padding(.bottom, 16)
            }
        }
        .frame(minWidth: 720, minHeight: 460)
    }

    private var slugCallout: String {
        "memory: <slug>, disk: <slug>"
    }

    /// Side-by-side: the current custom-drawn memory icon vs SF Symbol
    /// alternatives, all rendered in teal at the live widget size.
    private var memoryComparisonRow: some View {
        let teal = NSColor.systemTeal
        return VStack(alignment: .leading, spacing: 10) {
            Text("Memory icon — custom-drawn vs SF Symbol, all in teal")
                .font(.system(size: 14, weight: .semibold))
                .padding(.horizontal)
            HStack(spacing: 12) {
                swatch(label: "custom-drawn", sub: "(current — body + 5 legs)") {
                    Image(nsImage: customMemoryIcon(side: 17, color: teal))
                        .scaleEffect(2.5)
                }
                swatch(label: "memorychip", sub: "outline (legs faint)") {
                    if let img = IconRender.tinted(symbol: "memorychip",
                                                   pointSize: 17, weight: .bold, color: teal) {
                        Image(nsImage: img).scaleEffect(2.5)
                    }
                }
                swatch(label: "memorychip.fill", sub: "filled (no leg detail)") {
                    if let img = IconRender.tinted(symbol: "memorychip.fill",
                                                   pointSize: 17, weight: .bold, color: teal) {
                        Image(nsImage: img).scaleEffect(2.5)
                    }
                }
            }
            .padding(.horizontal)
        }
    }

    private func swatch<Content: View>(
        label: String, sub: String, @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(spacing: 6) {
            ZStack {
                LinearGradient(
                    colors: [Color(red: 0.10, green: 0.18, blue: 0.55),
                             Color(red: 0.18, green: 0.10, blue: 0.40)],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                )
                content()
            }
            .frame(width: 80, height: 54)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .frame(width: 110)
                .multilineTextAlignment(.center)
            Text(sub)
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
                .frame(width: 110)
                .multilineTextAlignment(.center)
        }
    }

    private var memoryColorPicker: some View {
        // Five purple-teal blends, fraction = how much teal we mix into
        // the systemPurple base. 0.0 = current pure purple, 1.0 = pure
        // teal. The labels are honest about the mix ratio so the user
        // can think in terms of "I want about X% teal".
        let purple = NSColor.systemPurple
        let teal = NSColor.systemTeal
        let blends: [(String, String, NSColor)] = [
            ("A — pure purple (current)",  "0 % teal blend",   purple),
            ("B — mostly purple",          "25 % teal blend",  purple.blended(withFraction: 0.25, of: teal) ?? purple),
            ("C — even mix",               "50 % teal blend",  purple.blended(withFraction: 0.50, of: teal) ?? purple),
            ("D — mostly teal",            "75 % teal blend",  purple.blended(withFraction: 0.75, of: teal) ?? purple),
            ("E — pure teal",              "100 % teal blend", teal),
        ]
        return VStack(alignment: .leading, spacing: 10) {
            Text("Memory icon color — pick a purple-teal blend")
                .font(.system(size: 14, weight: .semibold))
                .padding(.horizontal)
            HStack(spacing: 12) {
                ForEach(blends, id: \.0) { (label, sub, color) in
                    VStack(spacing: 6) {
                        ZStack {
                            LinearGradient(
                                colors: [Color(red: 0.10, green: 0.18, blue: 0.55),
                                         Color(red: 0.18, green: 0.10, blue: 0.40)],
                                startPoint: .topLeading, endPoint: .bottomTrailing
                            )
                            // Render the custom memory icon at the same
                            // 17pt × 17pt size the live widget uses.
                            Image(nsImage: customMemoryIcon(side: 17, color: color))
                                .scaleEffect(2.5)
                        }
                        .frame(width: 80, height: 54)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        Text(label)
                            .font(.system(size: 10, weight: .medium))
                            .frame(width: 110)
                            .multilineTextAlignment(.center)
                        Text(sub)
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                            .frame(width: 110)
                            .multilineTextAlignment(.center)
                    }
                }
            }
            .padding(.horizontal)
        }
    }

    private func customMemoryIcon(side: CGFloat, color: NSColor) -> NSImage {
        let img = NSImage(size: NSSize(width: side, height: side))
        img.lockFocus()
        color.setFill()
        color.setStroke()
        let icon = NSRect(x: 0, y: 0, width: side, height: side)
        let strokeW: CGFloat = 1.5
        let legH = max(3, side * 0.20)
        let bodyHPad = max(1, side * 0.08)
        let bodyRect = NSRect(
            x: icon.minX + bodyHPad,
            y: icon.minY + legH + 1,
            width: icon.width - bodyHPad * 2,
            height: icon.height - legH - 2
        )
        let body = NSBezierPath(roundedRect: bodyRect, xRadius: 1.5, yRadius: 1.5)
        body.lineWidth = strokeW
        body.stroke()
        let dotR = max(0.8, side * 0.07)
        NSBezierPath(ovalIn: NSRect(
            x: bodyRect.midX - dotR, y: bodyRect.midY - dotR,
            width: dotR * 2, height: dotR * 2
        )).fill()
        let legCount = 5
        let legW = max(1.0, side * 0.09)
        let totalLegs = CGFloat(legCount) * legW
        let gap = (bodyRect.width - totalLegs) / CGFloat(legCount + 1)
        for i in 0..<legCount {
            let x = bodyRect.minX + gap + CGFloat(i) * (legW + gap)
            NSBezierPath(rect: NSRect(x: x, y: icon.minY, width: legW, height: legH)).fill()
        }
        img.unlockFocus()
        return img
    }

    private func iconRow(title: String, color: NSColor,
                        candidates: [(String, String)]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .padding(.horizontal)
            HStack(spacing: 12) {
                ForEach(candidates, id: \.0) { (slugWithPrefix, desc) in
                    // Strip "A: " etc. prefix from the slug to get the SF Symbol name.
                    let parts = slugWithPrefix.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                    let slug = parts.count == 2 ? parts[1] : slugWithPrefix
                    VStack(spacing: 6) {
                        ZStack {
                            LinearGradient(
                                colors: [Color(red: 0.10, green: 0.18, blue: 0.55),
                                         Color(red: 0.18, green: 0.10, blue: 0.40)],
                                startPoint: .topLeading, endPoint: .bottomTrailing
                            )
                            Image(nsImage: IconRender.tinted(
                                symbol: slug, pointSize: 17, weight: .bold, color: color
                            ) ?? NSImage())
                                .scaleEffect(2.5)
                        }
                        .frame(width: 80, height: 54)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        Text(slugWithPrefix)
                            .font(.system(size: 10, design: .monospaced))
                            .lineLimit(2)
                            .multilineTextAlignment(.center)
                            .frame(width: 110)
                        Text(desc)
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .multilineTextAlignment(.center)
                            .frame(width: 110)
                    }
                }
            }
            .padding(.horizontal)
        }
    }

    @available(*, unavailable) private func variantSection(label: String, detail: String, image: NSImage) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(label).font(.system(size: 13, weight: .semibold))
                Text(detail).font(.system(size: 10)).foregroundStyle(.secondary)
            }
            // Render the widget at 2x so it's inspectable, against a
            // dark gradient that mimics a saturated menu-bar background.
            ZStack {
                LinearGradient(
                    colors: [Color(red: 0.10, green: 0.18, blue: 0.55),
                             Color(red: 0.18, green: 0.10, blue: 0.40)],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                )
                Image(nsImage: image)
                    .interpolation(.none)
                    .scaleEffect(3.0)  // big enough to actually see
            }
            .frame(height: 100)
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .padding(.horizontal)
    }
}

// MARK: - Icon renderer helper

private enum IconRender {
    static func tinted(symbol: String, pointSize: CGFloat,
                       weight: NSFont.Weight, color: NSColor) -> NSImage? {
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
        return out
    }
}

// MARK: - The variants (kept around for reference; not displayed)

private enum WidgetVariants {

    static func variantA(sample: SampleData) -> NSImage {
        render(sample: sample,
               iconPt: 13, iconWt: .regular,
               barW: 16, barH: 4,
               valuePt: 11, valueWt: .medium,
               elementGap: 3, groupGap: 5)
    }
    static func variantB(sample: SampleData) -> NSImage {
        render(sample: sample,
               iconPt: 14, iconWt: .semibold,
               barW: 20, barH: 5,
               valuePt: 12, valueWt: .semibold,
               elementGap: 3, groupGap: 6)
    }
    static func variantC(sample: SampleData) -> NSImage {
        render(sample: sample,
               iconPt: 12, iconWt: .regular,
               barW: 14, barH: 3,
               valuePt: 10, valueWt: .medium,
               elementGap: 2, groupGap: 4)
    }

    /// Render one variant. Layout (left → right):
    ///   [icon][bar][value%]   for each compute cell (CPU, MEM, GPU)
    ///   [icon][↓green value][↑red value]   for each IO cell (NET, DISK)
    ///   element-gap inside a cell, 1.5× element-gap between cells.
    private static func render(
        sample: SampleData,
        iconPt: CGFloat, iconWt: NSFont.Weight,
        barW: CGFloat, barH: CGFloat,
        valuePt: CGFloat, valueWt: NSFont.Weight,
        elementGap: CGFloat, groupGap: CGFloat
    ) -> NSImage {

        let height: CGFloat = 18
        let valueFont = NSFont.monospacedDigitSystemFont(ofSize: valuePt, weight: valueWt)

        // Build cell list with their measured widths.
        var cells: [(NSRect) -> Void] = []
        var widths: [CGFloat] = []

        func computeCell(symbol: String, load: Double, valueText: String) -> (CGFloat, (NSRect) -> Void) {
            let valueW = textWidth(valueText, font: valueFont)
            let cellW = iconPt + elementGap + barW + elementGap + valueW
            let draw: (NSRect) -> Void = { rect in
                var x = rect.minX
                drawIcon(symbol: symbol, pointSize: iconPt, weight: iconWt,
                         color: .labelColor,
                         in: NSRect(x: x, y: 0, width: iconPt, height: height))
                x += iconPt + elementGap
                drawBar(load: load,
                        in: NSRect(x: x, y: (height - barH)/2, width: barW, height: barH))
                x += barW + elementGap
                drawText(valueText, font: valueFont, color: .labelColor,
                         in: NSRect(x: x, y: 0, width: valueW, height: height),
                         align: .left)
            }
            return (cellW, draw)
        }

        func ioCell(symbol: String, downBps: Double, upBps: Double) -> (CGFloat, (NSRect) -> Void) {
            let arrowFont = NSFont.systemFont(ofSize: valuePt, weight: .semibold)
            let downText = formatBps(downBps)
            let upText   = formatBps(upBps)
            let downW = textWidth("↓", font: arrowFont) + 1 + textWidth(downText, font: valueFont)
            let upW   = textWidth("↑", font: arrowFont) + 1 + textWidth(upText, font: valueFont)
            let cellW = iconPt + elementGap + downW + elementGap + upW
            let draw: (NSRect) -> Void = { rect in
                var x = rect.minX
                drawIcon(symbol: symbol, pointSize: iconPt, weight: iconWt,
                         color: .labelColor,
                         in: NSRect(x: x, y: 0, width: iconPt, height: height))
                x += iconPt + elementGap
                // Down (green ↓ + value)
                drawText("↓", font: arrowFont, color: .systemGreen,
                         in: NSRect(x: x, y: 0, width: 10, height: height),
                         align: .left)
                x += textWidth("↓", font: arrowFont) + 1
                drawText(downText, font: valueFont, color: .labelColor,
                         in: NSRect(x: x, y: 0, width: textWidth(downText, font: valueFont), height: height),
                         align: .left)
                x += textWidth(downText, font: valueFont) + elementGap
                // Up (red ↑ + value)
                drawText("↑", font: arrowFont, color: .systemRed,
                         in: NSRect(x: x, y: 0, width: 10, height: height),
                         align: .left)
                x += textWidth("↑", font: arrowFont) + 1
                drawText(upText, font: valueFont, color: .labelColor,
                         in: NSRect(x: x, y: 0, width: textWidth(upText, font: valueFont), height: height),
                         align: .left)
            }
            return (cellW, draw)
        }

        let cpuCell = computeCell(symbol: "cpu", load: sample.cpu,
                                  valueText: "\(Int((sample.cpu * 100).rounded()))%")
        let memCell = computeCell(symbol: "memorychip", load: sample.mem,
                                  valueText: "\(Int((sample.mem * 100).rounded()))%")
        let gpuCell = computeCell(symbol: "display", load: sample.gpu ?? 0,
                                  valueText: sample.gpu.map { "\(Int(($0 * 100).rounded()))%" } ?? "—")
        let netCell = ioCell(symbol: "network", downBps: sample.netDown, upBps: sample.netUp)
        let diskCell = ioCell(symbol: "internaldrive", downBps: sample.diskRead, upBps: sample.diskWrite)

        cells = [cpuCell.1, memCell.1, gpuCell.1, netCell.1, diskCell.1]
        widths = [cpuCell.0, memCell.0, gpuCell.0, netCell.0, diskCell.0]

        // Total width = sum of cell widths + (n-1) group gaps + 8pt padding L/R.
        let leftPad: CGFloat = 8
        let rightPad: CGFloat = 8
        let totalCells = widths.reduce(0, +)
        let totalGaps = CGFloat(max(0, cells.count - 1)) * groupGap
        let totalW = leftPad + totalCells + totalGaps + rightPad

        let img = NSImage(size: NSSize(width: totalW, height: height))
        img.lockFocus()
        var x = leftPad
        for i in 0..<cells.count {
            cells[i](NSRect(x: x, y: 0, width: widths[i], height: height))
            x += widths[i]
            if i < cells.count - 1 { x += groupGap }
        }
        img.unlockFocus()
        return img
    }

    // MARK: - Drawing helpers

    private static func drawIcon(
        symbol: String, pointSize: CGFloat, weight: NSFont.Weight,
        color: NSColor, in rect: NSRect
    ) {
        let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: weight)
        guard
            let base = NSImage(systemSymbolName: symbol, accessibilityDescription: nil),
            let configured = base.withSymbolConfiguration(config)
        else { return }
        let tinted = configured.tinted(color)
        let s = tinted.size
        let drawRect = NSRect(
            x: rect.minX + (rect.width - s.width) / 2,
            y: (rect.height - s.height) / 2,
            width: s.width, height: s.height
        )
        tinted.draw(in: drawRect)
    }

    private static func drawBar(load: Double, in rect: NSRect) {
        let track = NSBezierPath(roundedRect: rect, xRadius: rect.height/2, yRadius: rect.height/2)
        NSColor.labelColor.withAlphaComponent(0.20).setFill()
        track.fill()
        let frac = CGFloat(min(max(load, 0), 1))
        guard frac > 0 else { return }
        let fillRect = NSRect(x: rect.minX, y: rect.minY,
                              width: max(2, rect.width * frac), height: rect.height)
        thresholdColor(load).setFill()
        NSBezierPath(roundedRect: fillRect, xRadius: rect.height/2, yRadius: rect.height/2).fill()
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

    private static func textWidth(_ s: String, font: NSFont) -> CGFloat {
        ceil((s as NSString).size(withAttributes: [.font: font]).width)
    }

    private static func thresholdColor(_ load: Double) -> NSColor {
        // Green / yellow / red thresholds matching the user's spec.
        switch load {
        case ..<0.60: return .systemGreen
        case ..<0.85: return .systemYellow
        default:      return .systemRed
        }
    }

    private static func formatBps(_ v: Double) -> String {
        if v >= 1_048_576 { return String(format: "%.0fMB", v / 1_048_576) }
        if v >= 1_024     { return String(format: "%.0fKB", v / 1_024) }
        return "\(Int(v))B"
    }
}

// MARK: - NSImage tint helper (mirrors GlyphRenderer's)

private extension NSImage {
    func tinted(_ color: NSColor) -> NSImage {
        let out = NSImage(size: size)
        out.lockFocus()
        color.set()
        NSRect(origin: .zero, size: size).fill(using: .sourceOver)
        draw(at: .zero, from: NSRect(origin: .zero, size: size),
             operation: .destinationIn, fraction: 1.0)
        out.unlockFocus()
        return out
    }
}

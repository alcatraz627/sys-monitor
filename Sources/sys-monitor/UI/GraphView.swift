import SwiftUI

/// A compact area-and-line sparkline over a `RingBuffer`. Hand-drawn via
/// SwiftUI `Canvas` rather than Swift Charts because we want a tight,
/// per-tick redraw without the framework overhead — a ~60-point Path is
/// microseconds of work per update and adds essentially nothing to RSS.
///
/// The trace is deliberately neutral: history is SHAPE, not color. A
/// trace tinted by the current value paints past samples with present
/// state (a spike from 30 s ago rendered green because now is calm) —
/// the "now" signal lives in the section header's tinted value instead.
struct GraphView: View {

    /// How the graph maps values to vertical space.
    enum ScaleMode {
        /// Fixed range — what every graph used to do. Best when the data's
        /// dynamic range is naturally well-known (e.g. CPU 0..1).
        case fixed(ClosedRange<Double>)
        /// Auto-zoom to the observed min/max within the window, padded.
        /// `minSpan` keeps the graph from amplifying microscopic noise
        /// (e.g. a steady-state system at 50% memory shouldn't draw a
        /// roller-coaster trace from 0.502 → 0.504). Best when the
        /// signal sits in a narrow band that fixed-range would flatten.
        case auto(minSpan: Double)
    }

    let buffer: RingBuffer
    let height: CGFloat
    let scaleMode: ScaleMode
    /// Show the resolved min/max as tiny corner labels. Auto-scaled
    /// graphs need this: auto-zoom renders a 2% wobble with the same
    /// full-frame shape a fixed graph uses for 0–100%, and with a
    /// neutral trace, shape is the only history channel — the labels
    /// are what keep the two graphs from teaching contradictory
    /// readings.
    let showRangeLabels: Bool

    init(
        buffer: RingBuffer,
        height: CGFloat = 26,
        scaleMode: ScaleMode = .fixed(0...1),
        showRangeLabels: Bool = false
    ) {
        self.buffer = buffer
        self.height = height
        self.scaleMode = scaleMode
        self.showRangeLabels = showRangeLabels
    }

    var body: some View {
        Canvas { ctx, size in
            let pts = buffer.points
            guard pts.count >= 2 else { return }

            // X maps to the full window even if the buffer hasn't filled
            // yet — that's why a freshly-started graph "grows in from the
            // right" rather than spanning the whole width with a tiny
            // wavy line in the middle.
            let windowEnd = pts.last!.timestamp
            let windowStart = windowEnd - buffer.windowSeconds
            let span = max(buffer.windowSeconds, 0.001)
            let valueRange = self.resolvedRange(points: pts)
            let valSpan = max(valueRange.upperBound - valueRange.lowerBound, 0.001)

            let xFor: (TimeInterval) -> CGFloat = { t in
                CGFloat((t - windowStart) / span) * size.width
            }
            let yFor: (Double) -> CGFloat = { v in
                let clamped = min(max(v, valueRange.lowerBound), valueRange.upperBound)
                let frac = (clamped - valueRange.lowerBound) / valSpan
                // Inset by 1pt top and bottom so the stroke doesn't clip.
                return (size.height - 2) - CGFloat(frac) * (size.height - 2) + 1
            }

            var line = Path()
            for (i, p) in pts.enumerated() {
                let x = xFor(p.timestamp)
                let y = yFor(p.value)
                if i == 0 { line.move(to: CGPoint(x: x, y: y)) }
                else      { line.addLine(to: CGPoint(x: x, y: y)) }
            }

            // Filled area beneath the line, very faint — gives the graph
            // visual weight at glance without competing with the stroke.
            var area = line
            area.addLine(to: CGPoint(x: xFor(pts.last!.timestamp),  y: size.height))
            area.addLine(to: CGPoint(x: xFor(pts.first!.timestamp), y: size.height))
            area.closeSubpath()

            // Neutral trace + thin wash — see the type comment for why
            // this is not the current load color.
            let color = Color.secondary
            ctx.fill(area, with: .color(color.opacity(0.10)))
            ctx.stroke(line, with: .color(color.opacity(0.9)), lineWidth: 1.4)

            if showRangeLabels {
                let font = Font.system(size: 8, design: .monospaced)
                let labelColor = Color.secondary.opacity(0.7)
                let hi = Text(String(format: "%.0f%%", valueRange.upperBound * 100))
                    .font(font).foregroundColor(labelColor)
                let lo = Text(String(format: "%.0f%%", valueRange.lowerBound * 100))
                    .font(font).foregroundColor(labelColor)
                ctx.draw(hi, at: CGPoint(x: 3, y: 5), anchor: .leading)
                ctx.draw(lo, at: CGPoint(x: 3, y: size.height - 5), anchor: .leading)
            }
        }
        .frame(height: height)
        .background(
            RoundedRectangle(cornerRadius: 3)
                .fill(Color.secondary.opacity(0.06))
        )
        .clipShape(RoundedRectangle(cornerRadius: 3))
    }

    /// Decide the y-axis range based on the scale mode. For `.auto`, snap
    /// to the min/max of the visible window with a 10% pad — but never
    /// less than `minSpan` so a flat trace doesn't become a noise plot.
    private func resolvedRange(points: [HistoryPoint]) -> ClosedRange<Double> {
        switch scaleMode {
        case .fixed(let r):
            return r
        case .auto(let minSpan):
            let values = points.map { $0.value }
            guard let lo = values.min(), let hi = values.max() else { return 0...1 }
            // Guard against minSpan = 0 callers — a true flat trace
            // would otherwise divide by zero downstream.
            let span = max(hi - lo, max(minSpan, 0.001))
            let center = (lo + hi) / 2
            let pad = span * 0.1
            let low  = max(0, center - span / 2 - pad)
            let high = min(1, center + span / 2 + pad)
            return low...high
        }
    }
}

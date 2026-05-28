import SwiftUI

/// A compact area-and-line sparkline over a `RingBuffer`. Hand-drawn via
/// SwiftUI `Canvas` rather than Swift Charts because we want a tight,
/// per-tick redraw without the framework overhead — a ~60-point Path is
/// microseconds of work per update and adds essentially nothing to RSS.
///
/// The line color is the load color at the most-recent value, so a graph
/// that's currently elevated draws orange, currently hot draws red — the
/// graph itself communicates the same state as the bar without needing a
/// separate legend.
struct GraphView: View {

    let buffer: RingBuffer
    let height: CGFloat
    /// The value-space the graph normalizes to. CPU and memory both run
    /// 0...1; bytes-per-second graphs (future) would use a different range.
    let valueRange: ClosedRange<Double>

    init(
        buffer: RingBuffer,
        height: CGFloat = 26,
        valueRange: ClosedRange<Double> = 0...1
    ) {
        self.buffer = buffer
        self.height = height
        self.valueRange = valueRange
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

            let color = DesignTokens.loadColor(pts.last?.value ?? 0)
            ctx.fill(area, with: .color(color.opacity(0.16)))
            ctx.stroke(line, with: .color(color), lineWidth: 1.2)
        }
        .frame(height: height)
        .background(
            RoundedRectangle(cornerRadius: 3)
                .fill(Color.secondary.opacity(0.06))
        )
        .clipShape(RoundedRectangle(cornerRadius: 3))
    }
}

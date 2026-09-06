import SwiftUI
import AppKit

/// The load levels at which a metric turns elevated (orange) then hot (red).
/// CPU and memory carry their own pair because the same percentage means
/// different things — 80% memory is closer to trouble than 80% CPU. These
/// are user-tunable; the defaults match the values the app shipped with.
public struct SeverityThresholds: Sendable, Hashable, Codable {
    public var cpuWarn: Double
    public var cpuCritical: Double
    public var memWarn: Double
    public var memCritical: Double

    public init(cpuWarn: Double, cpuCritical: Double, memWarn: Double, memCritical: Double) {
        self.cpuWarn = cpuWarn
        self.cpuCritical = cpuCritical
        self.memWarn = memWarn
        self.memCritical = memCritical
    }

    public static let defaults = SeverityThresholds(
        cpuWarn: 0.60, cpuCritical: 0.85, memWarn: 0.75, memCritical: 0.92)
}

/// Visual constants shared by the panel and the glyph. Kept lean for now —
/// the goal is one place to change a color or a size, not a full design
/// system. Density / text-scale knobs can grow here later when settings
/// surfaces the option.
public enum DesignTokens {

    // MARK: - Load color ramp

    /// Calm → elevated → hot, at the supplied thresholds. The same ramp
    /// drives the menu-bar bar fill and the panel bars; passing a metric's
    /// own thresholds keeps glyph and panel in agreement for that metric.
    /// Color is a *secondary* cue; the numeric value remains primary.
    public static func loadColor(_ load: Double,
                                 warn: Double = 0.60,
                                 critical: Double = 0.85) -> Color {
        switch load {
        case ..<warn:     return .green
        case ..<critical: return .orange
        default:          return .red
        }
    }

    /// Heatmap cell colour for one core's load. Opacity within the CPU
    /// identity hue, so a parked cluster reads as a pale block and a saturated
    /// one as a solid band, without borrowing another metric's colour.
    public static func cpuHeat(_ load: Double) -> Color {
        Color.orange.opacity(cpuHeatOpacity(load))
    }

    /// The opacity behind `cpuHeat`, separated so it can be asserted on.
    ///
    /// A guard comparing two `Color` values cannot see this: `Color.orange`
    /// at zero opacity is a different value from `Color.clear` while
    /// rendering identically, so the comparison passes whatever the opacity
    /// is. The number is the only readable thing here.
    ///
    /// Floors at 0.06 so an idle core draws a visible row. An invisible row
    /// and a core missing from the map look the same, and only one is a bug.
    public static func cpuHeatOpacity(_ load: Double) -> Double {
        let clamped = min(1, max(0, load))
        return 0.06 + clamped * 0.84
    }

    /// The same three colours, for a metric whose severity is decided from
    /// evidence rather than from a fraction crossing a threshold. Memory uses
    /// this: percent used still fills the bar, but reclaim activity picks the
    /// colour.
    public static func severityColor(_ s: MemorySeverity) -> Color {
        switch s {
        case .normal:   return .green
        case .warn:     return .orange
        case .critical: return .red
        }
    }

    // MARK: - Spacing

    public enum Space {
        public static let xs: CGFloat = 4
        public static let s:  CGFloat = 8
        public static let m:  CGFloat = 12
        public static let l:  CGFloat = 16
    }

    // MARK: - Type

    /// Monospaced numerals so columns of percentages and byte values don't
    /// jitter as digits change. Use everywhere a number is displayed.
    public static func numericFont(size: CGFloat, weight: Font.Weight = .medium) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}

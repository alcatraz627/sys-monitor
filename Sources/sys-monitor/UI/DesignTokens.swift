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

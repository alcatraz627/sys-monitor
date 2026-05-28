import SwiftUI
import AppKit

/// Visual constants shared by the panel and the glyph. Kept lean for now —
/// the goal is one place to change a color or a size, not a full design
/// system. Density / text-scale knobs can grow here later when settings
/// surfaces the option.
public enum DesignTokens {

    // MARK: - Load color ramp

    /// Calm → elevated → hot. The same ramp drives the menu-bar bar fill
    /// and the panel bars, so a 70% CPU reading looks identical in both.
    /// Color is a *secondary* cue; the numeric value remains primary.
    public static func loadColor(_ load: Double) -> Color {
        switch load {
        case ..<0.60: return .green
        case ..<0.85: return .orange
        default:      return .red
        }
    }

    /// AppKit-side variant for the glyph renderer (NSColor parity).
    public static func nsLoadColor(_ load: Double) -> NSColor {
        switch load {
        case ..<0.60: return .systemGreen
        case ..<0.85: return .systemOrange
        default:      return .systemRed
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

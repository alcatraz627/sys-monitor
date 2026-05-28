import Foundation
import Combine

// User-tunable settings, persisted to UserDefaults and observed by every
// reader site (the coordinator's cadences, the glyph's bar style, the
// panel's process count and default sort, the SMAppService login item).
//
// Each setter writes through to defaults so a relaunch picks up the same
// values; @Published lets observers (AppDelegate + the SwiftUI panel)
// react live without a save/apply step.

@MainActor
public final class SettingsStore: ObservableObject {

    /// Which resource cells appear in the menu-bar glyph, left to right
    /// in the order CPU > MEM > NET > DISK. At least one must be on; the
    /// settings UI enforces this by refusing to uncheck the last enabled
    /// cell. Persisted as the raw OptionSet integer.
    public struct BarCells: OptionSet, Sendable, Codable, Hashable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }

        public static let cpu  = BarCells(rawValue: 1 << 0)
        public static let mem  = BarCells(rawValue: 1 << 1)
        public static let net  = BarCells(rawValue: 1 << 2)
        public static let disk = BarCells(rawValue: 1 << 3)

        public static let defaultCells: BarCells = [.cpu, .mem]

        /// Ordered cell list, left-to-right in the bar.
        public var ordered: [BarCell] {
            var out: [BarCell] = []
            if contains(.cpu)  { out.append(.cpu) }
            if contains(.mem)  { out.append(.mem) }
            if contains(.net)  { out.append(.net) }
            if contains(.disk) { out.append(.disk) }
            return out
        }
    }

    public enum ProcSort: String, CaseIterable, Sendable {
        case cpu, mem
        public var displayName: String {
            switch self { case .cpu: return "CPU"; case .mem: return "Memory" }
        }
    }

    // Cadence choices the user is allowed to pick. Constrained because
    // wider freedom doesn't add value and creates pathological corners
    // (e.g. sub-100ms ticks that swamp the budget).
    public static let idleCadenceChoices: [Double] = [1, 2, 5]
    public static let openCadenceChoices: [Double] = [0.5, 1, 2]

    private let defaults: UserDefaults
    private static let kIdle  = "idleCadenceSeconds"
    private static let kOpen  = "openCadenceSeconds"
    private static let kCells = "barCells"
    private static let kCount = "processCount"
    private static let kSort  = "defaultSort"
    private static let kLogin = "launchAtLogin"

    @Published public var idleCadenceSeconds: Double {
        didSet {
            defaults.set(idleCadenceSeconds, forKey: Self.kIdle)
            enforceOrdering()
        }
    }
    @Published public var openCadenceSeconds: Double {
        didSet {
            defaults.set(openCadenceSeconds, forKey: Self.kOpen)
            enforceOrdering()
        }
    }
    @Published public var barCells: BarCells {
        didSet { defaults.set(barCells.rawValue, forKey: Self.kCells) }
    }
    @Published public var processCount: Int {
        didSet { defaults.set(processCount, forKey: Self.kCount) }
    }
    @Published public var defaultSort: ProcSort {
        didSet { defaults.set(defaultSort.rawValue, forKey: Self.kSort) }
    }
    @Published public var launchAtLogin: Bool {
        didSet { defaults.set(launchAtLogin, forKey: Self.kLogin) }
    }

    /// Read-only status of the actual login-item registration, refreshed
    /// after a register/unregister call. The setting (above) is the user's
    /// *intent*; this is what `SMAppService` actually believes.
    @Published public private(set) var launchAtLoginStatus: String = "—"

    private var suspendOrdering = false

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        // Load with sensible defaults if first run.
        self.idleCadenceSeconds = defaults.object(forKey: Self.kIdle) as? Double ?? 2.0
        self.openCadenceSeconds = defaults.object(forKey: Self.kOpen) as? Double ?? 1.0
        // Load barCells from the persisted Int rawValue. Absent → default
        // [.cpu, .mem]. Empty stored value is impossible because the UI
        // refuses to write one (last cell can't be unchecked).
        if let raw = defaults.object(forKey: Self.kCells) as? Int, raw != 0 {
            self.barCells = BarCells(rawValue: raw)
        } else {
            self.barCells = .defaultCells
        }
        self.processCount = (defaults.object(forKey: Self.kCount) as? Int) ?? 10
        self.defaultSort = ProcSort(rawValue: defaults.string(forKey: Self.kSort) ?? "")
            ?? .cpu
        self.launchAtLogin = defaults.bool(forKey: Self.kLogin)
    }

    /// idle cadence must be >= open cadence (idle is the always-on budget
    /// tier and should never sample MORE often than the on-demand tier).
    /// If the user picks an invalid combination we lift the smaller one to
    /// match — visible feedback is a brief glyph "—" while the timer
    /// re-baselines.
    private func enforceOrdering() {
        guard !suspendOrdering else { return }
        if idleCadenceSeconds < openCadenceSeconds {
            suspendOrdering = true
            // Lift idle up to match open. Picking the strictly smaller of
            // the two changes felt arbitrary; user intent is "I want more
            // detail," so we honor the bound by raising idle.
            idleCadenceSeconds = openCadenceSeconds
            suspendOrdering = false
        }
    }

    /// Called by AppDelegate after `SMAppService.mainApp.register()` /
    /// `.unregister()` returns, so the UI can show the actual status
    /// the system believes (not just what we asked for).
    public func setLaunchAtLoginStatus(_ status: String) {
        launchAtLoginStatus = status
    }
}

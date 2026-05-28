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

    public enum BarStyle: String, CaseIterable, Sendable {
        case cpuPercent
        case memoryPercent

        public var displayName: String {
            switch self {
            case .cpuPercent:    return "CPU %"
            case .memoryPercent: return "Memory %"
            }
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
    private static let kStyle = "barStyle"
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
    @Published public var barStyle: BarStyle {
        didSet { defaults.set(barStyle.rawValue, forKey: Self.kStyle) }
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
        self.barStyle = BarStyle(rawValue: defaults.string(forKey: Self.kStyle) ?? "")
            ?? .cpuPercent
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

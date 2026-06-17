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

    /// Which resource cells appear in the menu-bar glyph, and in what
    /// left-to-right order. The list holds exactly the *enabled* cells in
    /// the user's chosen order; a cell absent from the list is off. At
    /// least one must remain on (the settings UI refuses to remove the
    /// last). Persisted as an array of `BarCell` raw strings.
    public static let defaultBarCells: [BarCell] = [.cpu, .mem]

    public enum ProcSort: String, CaseIterable, Sendable {
        case cpu, mem, disk, net
        public var displayName: String {
            switch self {
            case .cpu:  return "CPU"
            case .mem:  return "Memory"
            case .disk: return "Disk I/O"
            case .net:  return "Network I/O"
            }
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
    private static let kArrowActivity = "arrowActivityIndicator"
    private static let kPanelHeight = "panelHeight"
    private static let kPanelPinned = "panelPinned"
    private static let kThroughputUnit = "throughputUnit"
    private static let kCpuWarn  = "sevCpuWarn"
    private static let kCpuCrit  = "sevCpuCritical"
    private static let kMemWarn  = "sevMemWarn"
    private static let kMemCrit  = "sevMemCritical"
    private static let kPinnedPids = "pinnedPids"
    private static let kAlertsOn   = "alertsEnabled"
    private static let kAlertCpu   = "alertCpuThreshold"
    private static let kAlertMem   = "alertMemThreshold"
    private static let kAlertTicks = "alertSustainTicks"
    private static let kAlertCool  = "alertCooldownSeconds"

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
    @Published public var barCells: [BarCell] {
        didSet { defaults.set(barCells.map(\.rawValue), forKey: Self.kCells) }
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
    @Published public var arrowActivityIndicator: Bool {
        didSet { defaults.set(arrowActivityIndicator, forKey: Self.kArrowActivity) }
    }

    /// Panel height in points, set by dragging the panel's bottom edge
    /// (not exposed in the settings UI — the resize itself is the
    /// control). Clamped to the panel's min/max on load.
    @Published public var panelHeight: Double {
        didSet { defaults.set(panelHeight, forKey: Self.kPanelHeight) }
    }

    /// Whether the panel pin is engaged. A pin the user set survives
    /// close, reopen, and relaunch — it un-sets only when the user
    /// unpins. (Its first version reset on close, which made the
    /// feature need re-arming on every open.)
    @Published public var panelPinned: Bool {
        didSet { defaults.set(panelPinned, forKey: Self.kPanelPinned) }
    }

    /// Whether throughput reads as bytes/s (default — matches Activity
    /// Monitor and disk benchmarks) or bits/s (matches NIC / ISP quoting).
    /// Applies to both the glyph cells and the panel's NET/DISK rows.
    @Published public var throughputUnit: ThroughputUnit {
        didSet { defaults.set(throughputUnit.rawValue, forKey: Self.kThroughputUnit) }
    }

    /// Load levels at which CPU / memory turn orange then red, in the glyph
    /// and the panel. User-tunable; persisted as four separate Doubles.
    @Published public var severityThresholds: SeverityThresholds {
        didSet {
            defaults.set(severityThresholds.cpuWarn,     forKey: Self.kCpuWarn)
            defaults.set(severityThresholds.cpuCritical, forKey: Self.kCpuCrit)
            defaults.set(severityThresholds.memWarn,     forKey: Self.kMemWarn)
            defaults.set(severityThresholds.memCritical, forKey: Self.kMemCrit)
        }
    }

    /// Processes the user pinned to the top of the list ("watch this one"),
    /// by pid. Pinned rows sort above everything else and are never cut by
    /// the row-count cap. A pinned pid that exits just stops appearing.
    /// Persisted as a sorted Int array.
    @Published public var pinnedPids: Set<Int32> {
        didSet { defaults.set(pinnedPids.sorted().map(Int.init), forKey: Self.kPinnedPids) }
    }

    /// When/how the monitor notifies about sustained high CPU or memory —
    /// the only feature that's useful while the panel is closed. Ships OFF.
    @Published public var alertConfig: AlertConfig {
        didSet {
            defaults.set(alertConfig.enabled,         forKey: Self.kAlertsOn)
            defaults.set(alertConfig.cpuThreshold,    forKey: Self.kAlertCpu)
            defaults.set(alertConfig.memThreshold,    forKey: Self.kAlertMem)
            defaults.set(alertConfig.sustainTicks,    forKey: Self.kAlertTicks)
            defaults.set(alertConfig.cooldownSeconds, forKey: Self.kAlertCool)
        }
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
        // Load the ordered cell list. New format is [String] of raw values;
        // an older build stored an OptionSet Int — migrate it into the
        // legacy fixed order (CPU>MEM>NET>DISK) on first read. Absent or
        // empty → default [.cpu, .mem].
        if let rawArr = defaults.object(forKey: Self.kCells) as? [String] {
            let decoded = rawArr.compactMap(BarCell.init(rawValue:))
            self.barCells = decoded.isEmpty ? Self.defaultBarCells : decoded
        } else if let rawInt = defaults.object(forKey: Self.kCells) as? Int, rawInt != 0 {
            var migrated: [BarCell] = []
            if rawInt & (1 << 0) != 0 { migrated.append(.cpu) }
            if rawInt & (1 << 1) != 0 { migrated.append(.mem) }
            if rawInt & (1 << 2) != 0 { migrated.append(.net) }
            if rawInt & (1 << 3) != 0 { migrated.append(.disk) }
            self.barCells = migrated.isEmpty ? Self.defaultBarCells : migrated
        } else {
            self.barCells = Self.defaultBarCells
        }
        self.processCount = (defaults.object(forKey: Self.kCount) as? Int) ?? 10
        self.defaultSort = ProcSort(rawValue: defaults.string(forKey: Self.kSort) ?? "")
            ?? .cpu
        self.launchAtLogin = defaults.bool(forKey: Self.kLogin)
        // Default ON — the brightness step is free (no perf cost) and
        // makes the NET / DISK arrows feel "live."
        self.arrowActivityIndicator = (defaults.object(forKey: Self.kArrowActivity) as? Bool) ?? true
        let storedHeight = (defaults.object(forKey: Self.kPanelHeight) as? Double) ?? 480
        self.panelHeight = min(max(storedHeight, 320), 900)
        self.panelPinned = defaults.bool(forKey: Self.kPanelPinned)
        self.throughputUnit = ThroughputUnit(rawValue: defaults.string(forKey: Self.kThroughputUnit) ?? "")
            ?? .bytesPerSec
        let d = SeverityThresholds.defaults
        func thr(_ key: String, _ fallback: Double) -> Double {
            (defaults.object(forKey: key) as? Double) ?? fallback
        }
        self.severityThresholds = SeverityThresholds(
            cpuWarn:     thr(Self.kCpuWarn, d.cpuWarn),
            cpuCritical: thr(Self.kCpuCrit, d.cpuCritical),
            memWarn:     thr(Self.kMemWarn, d.memWarn),
            memCritical: thr(Self.kMemCrit, d.memCritical))
        let storedPins = (defaults.object(forKey: Self.kPinnedPids) as? [Int]) ?? []
        self.pinnedPids = Set(storedPins.map(Int32.init))
        let ad = AlertConfig.defaults
        self.alertConfig = AlertConfig(
            enabled:         (defaults.object(forKey: Self.kAlertsOn) as? Bool) ?? ad.enabled,
            cpuThreshold:    (defaults.object(forKey: Self.kAlertCpu) as? Double) ?? ad.cpuThreshold,
            memThreshold:    (defaults.object(forKey: Self.kAlertMem) as? Double) ?? ad.memThreshold,
            sustainTicks:    (defaults.object(forKey: Self.kAlertTicks) as? Int) ?? ad.sustainTicks,
            cooldownSeconds: (defaults.object(forKey: Self.kAlertCool) as? Double) ?? ad.cooldownSeconds)
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

    /// Turn a bar cell on or off. Enabling appends it at the end (the user
    /// reorders afterward); disabling removes it, but never the last one —
    /// the glyph must always show something.
    public func setBarCell(_ cell: BarCell, enabled: Bool) {
        if enabled {
            if !barCells.contains(cell) { barCells.append(cell) }
        } else if barCells.count > 1 {
            barCells.removeAll { $0 == cell }
        }
    }

    /// Pin or unpin a process by pid (the row's "watch" toggle).
    public func togglePin(_ pid: Int32) {
        if pinnedPids.contains(pid) { pinnedPids.remove(pid) }
        else { pinnedPids.insert(pid) }
    }

    /// Nudge a cell one slot toward the front (`up`) or back of the bar.
    /// No-op at the ends. Adjacent swap keeps the index math unambiguous.
    public func moveBarCell(_ cell: BarCell, up: Bool) {
        guard let i = barCells.firstIndex(of: cell) else { return }
        let j = up ? i - 1 : i + 1
        guard barCells.indices.contains(j) else { return }
        barCells.swapAt(i, j)
    }
}

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

    /// What the glyph shows on a menu bar with little room. A notched 14"
    /// gives status items 664 pt in total, and the four-cell standard glyph
    /// is 411 pt of that, so one app takes 62% of the strip and macOS drops
    /// somebody with no overflow indicator. These two at compact density are
    /// 110 pt.
    public static let defaultNarrowBarCells: [BarCell] = [.cpu, .mem]

    /// A metric section the user can expand for detail. Raw values are the
    /// persisted identity, so renaming a case silently forgets that section's
    /// state; add cases, do not rename them.
    public enum PanelSection: String, CaseIterable, Sendable {
        case cpu, mem, net, disk, storage, energy
    }

    public enum ProcSort: String, CaseIterable, Sendable {
        case cpu, mem, disk, net, pwr
        public var displayName: String {
            switch self {
            case .cpu:  return "CPU"
            case .mem:  return "Memory"
            case .disk: return "Disk I/O"
            case .net:  return "Network I/O"
            case .pwr:  return "Power"
            }
        }

        /// The segment label. Short because the picker is 156 pt wide, not the
        /// panel's 360: five segments is about 31 pt each.
        public var segmentLabel: String {
            switch self {
            case .cpu:  return "CPU"
            case .mem:  return "MEM"
            case .disk: return "DISK"
            case .net:  return "NET"
            case .pwr:  return "PWR"
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
    private static let kExpanded   = "expandedSections"
    private static let kHistoryWindow = "historyWindowSeconds"
    private static let kCompactGlyph = "compactGlyph"
    private static let kGroupProcs = "groupProcesses"
    private static let kAdaptToDisplay = "adaptGlyphToDisplay"
    private static let kNarrowCells = "narrowBarCells"
    private static let kPerCore    = "showPerCoreStrip"
    private static let kSparklines = "showSparklines"
    private static let kCoverage   = "showCoverageRow"
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

    /// How many seconds of history the sparklines retain (60…300). Pushed
    /// to the coordinator's ring buffers; widening keeps existing points.
    @Published public var historyWindowSeconds: Double {
        didSet { defaults.set(historyWindowSeconds, forKey: Self.kHistoryWindow) }
    }

    /// Panel display toggles — each gates an existing render path. All
    /// default on; turning one off declutters the panel.
    /// Show one row per process tree instead of one per process. Chrome is
    /// 3804 MB across 42 processes whose largest single row reads 489 MB, so
    /// a flat list understates whatever is actually using the machine.
    /// Default off: the flat list is the reviewed behaviour and is still the
    /// right view when hunting one runaway pid.
    @Published public var groupProcesses: Bool {
        didSet { defaults.set(groupProcesses, forKey: Self.kGroupProcs) }
    }

    /// Use the narrow profile when the glyph is on a cramped menu bar. On
    /// by default: the same glyph that reads well on a 3440 pt external
    /// display is the one that gets silently dropped on a notched laptop.
    @Published public var adaptGlyphToDisplay: Bool {
        didSet { defaults.set(adaptGlyphToDisplay, forKey: Self.kAdaptToDisplay) }
    }

    /// The cell list used on a cramped menu bar. Rendered at compact
    /// density regardless of `compactGlyph`, which governs the roomy case.
    @Published public var narrowBarCells: [BarCell] {
        didSet { defaults.set(narrowBarCells.map(\.rawValue), forKey: Self.kNarrowCells) }
    }

    /// Compact menu-bar glyph — every bar dimension shrinks for a smaller
    /// footprint. Default off (the shipped standard density). Governs the
    /// roomy case only; a cramped menu bar always renders compact.
    @Published public var compactGlyph: Bool {
        didSet { defaults.set(compactGlyph, forKey: Self.kCompactGlyph) }
    }

    @Published public var showPerCoreStrip: Bool {
        didSet { defaults.set(showPerCoreStrip, forKey: Self.kPerCore) }
    }
    @Published public var showSparklines: Bool {
        didSet { defaults.set(showSparklines, forKey: Self.kSparklines) }
    }
    @Published public var showCoverageRow: Bool {
        didSet { defaults.set(showCoverageRow, forKey: Self.kCoverage) }
    }

    /// Processes the user pinned to the top of the list ("watch this one"),
    /// by pid. Pinned rows sort above everything else and are never cut by
    /// the row-count cap. A pinned pid that exits just stops appearing.
    /// Persisted as a sorted Int array.
    /// Which metric sections are showing their detail view. Collapsed is the
    /// default and the state the panel ships in, so an empty set is correct
    /// rather than uninitialised.
    @Published public var expandedSections: Set<PanelSection> {
        didSet {
            defaults.set(expandedSections.map(\.rawValue).sorted(), forKey: Self.kExpanded)
        }
    }

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
        let storedWindow = (defaults.object(forKey: Self.kHistoryWindow) as? Double) ?? 60
        self.historyWindowSeconds = min(max(storedWindow, 60), 300)
        self.compactGlyph = (defaults.object(forKey: Self.kCompactGlyph) as? Bool) ?? false
        self.groupProcesses = (defaults.object(forKey: Self.kGroupProcs) as? Bool) ?? false
        self.adaptGlyphToDisplay = (defaults.object(forKey: Self.kAdaptToDisplay) as? Bool) ?? true
        if let raw = defaults.object(forKey: Self.kNarrowCells) as? [String] {
            let decoded = raw.compactMap(BarCell.init(rawValue:))
            self.narrowBarCells = decoded.isEmpty ? Self.defaultNarrowBarCells : decoded
        } else {
            self.narrowBarCells = Self.defaultNarrowBarCells
        }
        self.showPerCoreStrip = (defaults.object(forKey: Self.kPerCore) as? Bool) ?? true
        self.showSparklines   = (defaults.object(forKey: Self.kSparklines) as? Bool) ?? true
        self.showCoverageRow  = (defaults.object(forKey: Self.kCoverage) as? Bool) ?? true
        let storedPins = (defaults.object(forKey: Self.kPinnedPids) as? [Int]) ?? []
        self.pinnedPids = Set(storedPins.map(Int32.init))
        // An unknown raw value is dropped rather than defaulted, so a section
        // removed in a later build cannot resurrect itself as a phantom.
        let storedExpanded = (defaults.object(forKey: Self.kExpanded) as? [String]) ?? []
        self.expandedSections = Set(storedExpanded.compactMap(PanelSection.init(rawValue:)))
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

    /// Restore the user-tunable preferences to their shipped defaults. Each
    /// assignment writes through via its didSet. Deliberately leaves system
    /// / window state alone: launch-at-login (a real OS registration),
    /// panel height and pin (per-window prefs the user set by direct
    /// manipulation, not in this form).
    public func resetToDefaults() {
        idleCadenceSeconds = 2.0
        openCadenceSeconds = 1.0
        barCells = Self.defaultBarCells
        processCount = 10
        defaultSort = .cpu
        arrowActivityIndicator = true
        throughputUnit = .bytesPerSec
        severityThresholds = .defaults
        alertConfig = .defaults
        pinnedPids = []
        expandedSections = []
        historyWindowSeconds = 60
        compactGlyph = false
        groupProcesses = false
        adaptGlyphToDisplay = true
        narrowBarCells = Self.defaultNarrowBarCells
        showPerCoreStrip = true
        showSparklines = true
        showCoverageRow = true
    }

    /// Pin or unpin a process by pid (the row's "watch" toggle).
    public func togglePin(_ pid: Int32) {
        if pinnedPids.contains(pid) { pinnedPids.remove(pid) }
        else { pinnedPids.insert(pid) }
    }

    public func toggleSection(_ s: PanelSection) {
        if expandedSections.contains(s) { expandedSections.remove(s) }
        else { expandedSections.insert(s) }
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

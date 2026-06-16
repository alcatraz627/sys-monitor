import SwiftUI
import AppKit

/// Shared sink for the panel's hover-help status line. macOS suppresses
/// real tooltips for inactive apps, and this app is a nonactivating
/// accessory by design — `.explain()` never fires here. Instead, hoverable
/// elements publish a one-line explanation that the footer status line
/// renders (the htop function-bar idiom).
@MainActor
final class HoverHelp: ObservableObject {
    @Published var text: String?
}

private struct HoverHelpModifier: ViewModifier {
    @EnvironmentObject var help: HoverHelp
    let text: String
    func body(content: Content) -> some View {
        content.onHover { hovering in
            if hovering {
                help.text = text
            } else if help.text == text {
                help.text = nil
            }
        }
    }
}

extension View {
    /// Publish `text` to the panel's footer status line while hovered.
    func hoverHelp(_ text: String) -> some View {
        modifier(HoverHelpModifier(text: text))
    }

    /// Both help channels at once: the status line (works always) and
    /// the system tooltip (works if the app is ever active — and feeds
    /// accessibility).
    func explain(_ text: String) -> some View {
        self.help(text).hoverHelp(text)
    }
}

/// The dropdown panel's SwiftUI root: CPU + per-core strip, memory + swap,
/// network/disk throughput, and a sortable process list. Reads everything
/// from the shared `MetricsStore` — no sampling here, just rendering.
struct PanelRootView: View {
    @EnvironmentObject var store: MetricsStore
    @EnvironmentObject var settings: SettingsStore
    @EnvironmentObject var panelState: PanelState
    /// While the user is hovering over the process list, we freeze the
    /// displayed *ordering* to whatever it was when the hover began. This
    /// stops rows from re-sorting out from under a click or scroll — but
    /// only the order freezes: each row's CPU/MEM values keep updating
    /// from the live snapshot, so a spike that starts mid-hover is still
    /// visible. When the hover ends, we drop back to the live ranking.
    @State private var hoverFrozenPids: [Int32]?

    /// Text the user has typed into the process search box. Filters the
    /// list by case-insensitive name containment.
    @State private var searchText: String = ""

    /// Pids of process rows the user has clicked to expand for detail
    /// (executable path + copy-kill buttons).
    @State private var expandedPids: Set<Int32> = []

    /// Per-pid exponential-moving-average of CPU usage, used for *ranking*
    /// only. Display still shows the raw current %. This is the "rank
    /// hysteresis" mechanism — a process needs to climb the EMA for a few
    /// ticks before it bubbles up past a neighbor, so the bottom of the
    /// list stops slot-machining.
    @State private var smoothedCpu: [Int32: Double] = [:]
    @State private var smoothedGeneration: UInt64 = 0

    /// Per-pid lookup caches hoisted to the panel root so they survive
    /// the panel close → reopen cycle (NSPanel has isReleasedWhenClosed
    /// = false) and so a single prune call can keep them bounded.
    @State private var triedLookup: Set<Int32> = []
    @State private var pidPath: [Int32: String] = [:]
    @State private var pidIcon: [Int32: NSImage] = [:]
    /// Resolved human display name per pid (localizedName → meaningful
    /// path segment → proc_name). Filled in the same once-per-pid task
    /// as the path/icon lookups.
    @State private var pidDisplayName: [Int32: String] = [:]

    let onShowSettings: () -> Void

    private var sortBy: SettingsStore.ProcSort { settings.defaultSort }
    private func setSortBy(_ s: SettingsStore.ProcSort) { settings.defaultSort = s }

    typealias ProcSort = SettingsStore.ProcSort

    @StateObject private var hoverHelp = HoverHelp()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            cpuSection
            divider
            memorySection
            divider
            netDiskRow
            if store.snapshot.powerAvailable {
                divider
                powerRow
            }
            divider
            processSection
            divider
            statusLine
            footer
        }
        .environmentObject(hoverHelp)
        .padding(DesignTokens.Space.s)
        .frame(width: 360)
        .background(
            // Vibrant material so the dropdown has the standard menu-bar
            // feel even though we own the window chrome.
            VisualEffectBackground()
                .clipShape(RoundedRectangle(cornerRadius: 10))
        )
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - Sections

    private var cpuSection: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.xs) {
            HStack(spacing: DesignTokens.Space.s) {
                Text("CPU").font(DesignTokens.numericFont(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .explain("Overall CPU load; sparkline shows the last 60 s on a fixed 0–100% scale")
                Button(action: { panelState.isPinned.toggle() }) {
                    Image(systemName: panelState.isPinned ? "pin.fill" : "pin")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(panelState.isPinned ? Color.accentColor : Color.secondary)
                        .rotationEffect(.degrees(45))
                        .frame(width: 22, height: 18)
                        .background(RoundedRectangle(cornerRadius: 4)
                            .fill(Color.accentColor.opacity(panelState.isPinned ? 0.15 : 0)))
                }
                .buttonStyle(.plain)
                .explain(panelState.isPinned
                      ? "Pinned — clicks outside, Esc, and Space switches won't close the panel. Click the menu-bar icon or unpin to close."
                      : "Pin the panel open")
                Spacer()
                // The header value is where "now" gets its color — the
                // sparkline trace stays neutral (history is shape).
                // Default text color while normal; orange/red at the
                // same thresholds the bars use.
                Text(cpuValueText)
                    .font(DesignTokens.numericFont(size: 12, weight: .medium))
                    .foregroundStyle(cpuLoad >= 0.60 ? DesignTokens.loadColor(cpuLoad) : Color.primary)
            }
            // Sparkline carries "now + recent"; the per-core strip carries
            // distribution. The overall bar was a third encoding of "now"
            // and ate vertical real estate for no extra signal.
            GraphView(buffer: store.snapshot.cpuHistory)
            CoreStrip(loads: cpuPerCore)
        }
    }

    private var memorySection: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.xs) {
            HStack(spacing: DesignTokens.Space.s) {
                Text("MEM").font(DesignTokens.numericFont(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .explain("Used memory (active + wired + compressed); sparkline shows the last 60 s, auto-scaled to the corner labels")
                Spacer()
                Text(memValueText)
                    .font(DesignTokens.numericFont(size: 12, weight: .medium))
                    .foregroundStyle(memLoad >= 0.60 ? DesignTokens.loadColor(memLoad) : Color.primary)
            }
            // Auto-scale because memory sits in a narrow band; minSpan
            // keeps the trace from amplifying single-percent jitter.
            // Range labels because auto-scale renders a 2% wobble with
            // the same shape CPU uses for 0–100%.
            GraphView(buffer: store.snapshot.memHistory,
                      scaleMode: .auto(minSpan: 0.05),
                      showRangeLabels: true)
            HStack(spacing: DesignTokens.Space.m) {
                Text("swap \(swapText)")
                    .explain("Swap space in use — sustained growth means RAM is oversubscribed")
                Spacer()
                HStack(spacing: 4) {
                    Text("pressure").foregroundStyle(.secondary)
                    Text(pressureText).foregroundStyle(pressureColor)
                }
                .explain("Kernel memory-pressure level, polled every tick: normal / warn / critical")
            }
            .font(DesignTokens.numericFont(size: 10))
            .foregroundStyle(.secondary)
        }
    }

    /// Pressure text takes the severity color from the enum: normal stays
    /// secondary text, warn is orange, critical is red. The categorical
    /// signal otherwise gets read as neutral the same as "swap 0.00 GB".
    private var pressureColor: Color {
        if case .ok(let s) = store.snapshot.memory {
            switch s.pressure {
            case .normal:   return .secondary
            case .warn:     return .orange
            case .critical: return .red
            }
        }
        return .secondary
    }

    private var netDiskRow: some View {
        HStack(spacing: DesignTokens.Space.m) {
            ThroughputCell(label: "NET", metric: store.snapshot.net,
                           activity: settings.arrowActivityIndicator,
                           history: store.snapshot.netHistory)
            // Hide the disk cell entirely when the sampler is permanently
            // unavailable — better than showing empty values forever,
            // which reads as "broken" rather than "doesn't apply on this Mac."
            if !diskUnavailable {
                ThroughputCell(label: "DISK", metric: store.snapshot.disk,
                               activity: settings.arrowActivityIndicator,
                               history: store.snapshot.diskHistory)
            }
        }
    }

    private var diskUnavailable: Bool {
        if case .unavailable = store.snapshot.disk { return true }
        return false
    }

    /// Apple-Silicon package power (CPU/GPU/ANE watts) from IOReport —
    /// panel-tier, shown only when the private framework resolved. ANE is
    /// best-effort; hidden when it reads zero.
    private var powerRow: some View {
        HStack(spacing: DesignTokens.Space.s) {
            Text("POWER")
                .font(DesignTokens.numericFont(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .explain("Live package power on Apple Silicon (CPU / GPU / Neural Engine), read sudoless from IOReport energy counters.")
            Spacer()
            if case .ok(let p) = store.snapshot.power {
                powerCell("cpu", p.cpuWatts, .orange)
                powerCell("gpu", p.gpuWatts, .teal)
                if p.aneWatts >= 0.01 { powerCell("ane", p.aneWatts, .purple) }
            } else {
                Text("—").foregroundStyle(.tertiary)
                    .font(DesignTokens.numericFont(size: 11))
            }
        }
    }

    private func powerCell(_ label: String, _ watts: Double, _ tint: Color) -> some View {
        HStack(spacing: 3) {
            Text(label).foregroundStyle(.tertiary)
            Text(String(format: "%.2fW", watts)).foregroundStyle(tint)
        }
        .font(DesignTokens.numericFont(size: 11))
    }

    /// A dim pinned row stating, honestly, that the list is a slice — the
    /// top N of M processes we could attribute, with the rest (and the
    /// kernel + other-user processes that are invisible without root) not
    /// shown. This is the truthful "don't pretend the visible list is
    /// everything" signal. (A literal unaccounted-CPU number was tried and
    /// dropped: reconciling host-wide CPU against summed per-process
    /// user+system time leaves ~2 cores of kernel/system time unattributed
    /// on a quiet machine, which renders as a misleading "kernel 200%"
    /// next to a 1%-busy list.)
    @ViewBuilder
    private var unaccountedRow: some View {
        if let (shown, total) = coverageCounts, total > shown {
            HStack(spacing: DesignTokens.Space.s) {
                Image(systemName: "ellipsis")
                    .font(.system(size: 9))
                    .foregroundStyle(.quaternary)
                    .frame(width: 10)
                Text(searchText.isEmpty
                     ? "top \(shown) of \(total) processes"
                     : "\(shown) of \(total) matching")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(DesignTokens.numericFont(size: 10))
            .foregroundStyle(.tertiary)
            .padding(.top, 2)
            .overlay(alignment: .top) {
                Rectangle().fill(Color.secondary.opacity(0.15)).frame(height: 0.5)
            }
            .explain("The list shows the top processes by the current sort. Kernel and other-user processes are invisible without root, so this is never the whole machine.")
        }
    }

    /// (shown, total): how many rows are displayed vs how many processes
    /// matched the current filter. nil until the first process tick.
    private var coverageCounts: (Int, Int)? {
        guard case .ok = store.snapshot.processes else { return nil }
        let total = filteredProcesses.count
        return (min(displayedProcesses.count, total), total)
    }

    private var processSection: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.xs) {
            HStack(spacing: DesignTokens.Space.s) {
                Text("PROCESSES")
                    .font(DesignTokens.numericFont(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                searchField
                Picker("", selection: Binding(
                    get: { sortBy },
                    set: { setSortBy($0) }
                )) {
                    Text("CPU").tag(SettingsStore.ProcSort.cpu)
                    Text("MEM").tag(SettingsStore.ProcSort.mem)
                    Text("DISK").tag(SettingsStore.ProcSort.disk)
                    if store.snapshot.perProcessNetAvailable {
                        Text("NET").tag(SettingsStore.ProcSort.net)
                    }
                }
                .pickerStyle(.segmented)
                .controlSize(.mini)
                .frame(width: store.snapshot.perProcessNetAvailable ? 156 : 124)
                .explain("Rank by CPU, memory, disk, or network I/O — the third column shows the chosen metric's value")
            }
            ProcessList(
                metric: store.snapshot.processes,
                ranked: displayedProcesses,
                sortBy: sortBy,
                expandedPids: $expandedPids,
                triedLookup: $triedLookup,
                pidPath: $pidPath,
                pidIcon: $pidIcon,
                pidDisplayName: $pidDisplayName
            )
            .onHover { hovering in
                if hovering {
                    // Never freeze an EMPTY order. The panel opens under
                    // the cursor, so hover usually begins while processes
                    // are still measuring — freezing [] would pin the
                    // list empty for the whole hover. Stay live until
                    // there's a real order to freeze; the cost is one
                    // unfrozen reorder under the cursor when data lands.
                    let pids = rankedProcesses.map(\.pid)
                    hoverFrozenPids = pids.isEmpty ? nil : pids
                } else {
                    hoverFrozenPids = nil
                }
            }
            unaccountedRow
        }
        .onChange(of: store.snapshot.generation) { gen in
            updateSmoothedCpu(generation: gen)
        }
        .onChange(of: searchText) { _ in
            // Filter changes should be reflected immediately even if the
            // pointer is over the list — otherwise the user types into the
            // search box and nothing happens until they move away.
            hoverFrozenPids = nil
        }
    }

    private var searchField: some View {
        HStack(spacing: 4) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
            TextField("filter", text: $searchText)
                .textFieldStyle(.plain)
                .font(DesignTokens.numericFont(size: 11))
                .frame(maxWidth: 80)
                .explain(ProcessList.filterSyntax)
            if !searchText.isEmpty {
                Button(action: { searchText = "" }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.secondary.opacity(0.12))
        )
    }

    /// Rebuild the per-pid EMA from the current snapshot and drop any
    /// long-tail state for pids no longer alive. New pids seed at 0 so a
    /// startup CPU spike doesn't anchor the EMA above the process's true
    /// steady-state load.
    private func updateSmoothedCpu(generation: UInt64) {
        guard generation != smoothedGeneration else { return }
        smoothedGeneration = generation
        guard case .ok(let procs) = store.snapshot.processes else { return }
        let alpha: Double = 0.4
        var next: [Int32: Double] = [:]
        next.reserveCapacity(procs.count)
        for p in procs {
            let prev = smoothedCpu[p.pid] ?? 0
            next[p.pid] = alpha * p.cpu + (1 - alpha) * prev
        }
        smoothedCpu = next
        prunePerPidState(livePids: Set(procs.map { $0.pid }))
    }

    /// Drop per-pid UI caches whose process is no longer present. Without
    /// this, a panel left open across many process churns would keep
    /// retained NSImages and Strings for every pid it ever saw.
    private func prunePerPidState(livePids: Set<Int32>) {
        if !expandedPids.isSubset(of: livePids) {
            expandedPids.formIntersection(livePids)
        }
        if !triedLookup.isSubset(of: livePids) {
            triedLookup.formIntersection(livePids)
        }
        pidPath.keys
            .filter { !livePids.contains($0) }
            .forEach { pidPath.removeValue(forKey: $0) }
        pidIcon.keys
            .filter { !livePids.contains($0) }
            .forEach { pidIcon.removeValue(forKey: $0) }
        pidDisplayName.keys
            .filter { !livePids.contains($0) }
            .forEach { pidDisplayName.removeValue(forKey: $0) }
    }

    /// What the process list actually shows: live ranking when not hovered;
    /// while hovered, the pid order from hover-begin filled with FRESH
    /// samples from the current snapshot. Pids that have exited simply
    /// drop out (no reshuffle); pids that appeared after hover-begin —
    /// or were below the display cap when it began — stay out until the
    /// hover ends.
    private var displayedProcesses: [ProcSample] {
        // Empty-frozen guard mirrors the capture-side rule in onHover —
        // an empty order must never mask live data.
        guard let frozen = hoverFrozenPids, !frozen.isEmpty else { return rankedProcesses }
        guard case .ok(let procs) = store.snapshot.processes else { return [] }
        var byPid: [Int32: ProcSample] = [:]
        byPid.reserveCapacity(procs.count)
        for p in procs { byPid[p.pid] = p }
        return frozen.compactMap { byPid[$0] }
    }

    /// Fixed-height context line fed by whatever the cursor is over —
    /// the panel's tooltip surface (real tooltips never appear for a
    /// nonactivating accessory app). Reserved height so hovering never
    /// shifts layout.
    private var statusLine: some View {
        Text(hoverHelp.text ?? " ")
            .lineLimit(1)
            .truncationMode(.middle)
            .font(DesignTokens.numericFont(size: 9))
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: 12)
    }

    private var footer: some View {
        HStack(spacing: DesignTokens.Space.s) {
            footerButton("gearshape", help: "Settings") { onShowSettings() }
            Spacer()
            selfCostReadout
            Spacer()
            footerButton("power", tint: .red, help: "Quit sys-monitor") { NSApp.terminate(nil) }
        }
    }

    /// The monitor's own footprint — how much CPU/memory sys-monitor itself
    /// is spending to watch everything else. It's the budget canary: a
    /// glanceable monitor that becomes a top consumer has failed its one
    /// promise, so its own cost should be visible, not hidden in Activity
    /// Monitor. Tints when the cost crosses into "something's wrong"
    /// territory (we should sit well under 1%).
    @ViewBuilder
    private var selfCostReadout: some View {
        if let s = selfSample {
            let pct = s.cpu * 100
            Text(String(format: "self %.1f%% · %@", pct, formatBytes(Double(s.memBytes))))
                .font(DesignTokens.numericFont(size: 10))
                .foregroundStyle(pct >= 3 ? DesignTokens.loadColor(pct >= 8 ? 1.0 : 0.7)
                                          : Color.secondary.opacity(0.7))
                .explain("sys-monitor's own CPU% and memory — the budget canary. If this climbs into the top processes, the monitor has become the load it's meant to watch.")
        }
    }

    /// Our own process's sample, pulled from the full (un-truncated) process
    /// snapshot. Nil until the first open-tier process tick lands.
    private var selfSample: ProcSample? {
        guard case .ok(let procs) = store.snapshot.processes else { return nil }
        let me = ProcessInfo.processInfo.processIdentifier
        return procs.first { $0.pid == me }
    }

    private func footerButton(_ icon: String, tint: Color = .secondary,
                              help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: 26, height: 22)
                .background(RoundedRectangle(cornerRadius: 5).fill(tint.opacity(0.10)))
        }
        .buttonStyle(.plain)
        .explain(help)
    }

    private var divider: some View {
        Rectangle().fill(Color.secondary.opacity(0.25))
            .frame(height: 0.5)
            .padding(.vertical, DesignTokens.Space.xs)
    }

    // MARK: - Derived values

    private var cpuLoad: Double {
        if case .ok(let s) = store.snapshot.cpu { return s.overall }
        return 0
    }

    private var cpuValueText: String {
        switch store.snapshot.cpu {
        case .ok(let s):              return String(format: "%.0f%%", s.overall * 100)
        case .measuring, .unavailable: return "—"
        }
    }

    private var cpuPerCore: [Double] {
        if case .ok(let s) = store.snapshot.cpu { return s.perCore }
        return []
    }

    private var memLoad: Double {
        if case .ok(let s) = store.snapshot.memory, s.totalBytes > 0 {
            return Double(s.usedBytes) / Double(s.totalBytes)
        }
        return 0
    }

    private var memValueText: String {
        switch store.snapshot.memory {
        case .ok(let s):
            let usedGB  = Double(s.usedBytes) / 1_073_741_824
            let totalGB = Double(s.totalBytes) / 1_073_741_824
            // Leading % matches CPU's unit and gives the severity color
            // ramp (keyed on the fraction) a visible numeric anchor.
            let pct = s.totalBytes > 0
                ? Double(s.usedBytes) / Double(s.totalBytes) * 100 : 0
            return String(format: "%.0f%% · %.1f / %.0f GB", pct, usedGB, totalGB)
        case .measuring, .unavailable: return "—"
        }
    }

    private var swapText: String {
        if case .ok(let s) = store.snapshot.memory {
            let gb = Double(s.swapUsedBytes) / 1_073_741_824
            return String(format: "%.2f GB", gb)
        }
        return "—"
    }

    private var pressureText: String {
        if case .ok(let s) = store.snapshot.memory {
            switch s.pressure {
            case .normal:   return "normal"
            case .warn:     return "warn"
            case .critical: return "critical"
            }
        }
        return "—"
    }

    /// The current snapshot's processes after the search filter, before
    /// sort/truncation. Shared by the ranked list and the coverage count.
    /// Three filter shapes, dispatched on the needle itself:
    ///   >N / <N, optional :cpu/:mem/:disk/:net — threshold filters
    ///   digits  pid contains those digits
    ///   text    case-insensitive name match (kernel + resolved name)
    private var filteredProcesses: [ProcSample] {
        guard case .ok(let procs) = store.snapshot.processes else { return [] }
        let raw = searchText.trimmingCharacters(in: .whitespaces)
        if raw.isEmpty { return procs }
        if let threshold = ProcessList.thresholdFilter(raw) {
            return procs.filter(threshold)
        }
        if raw.allSatisfy({ $0.isNumber }) {
            return procs.filter { String($0.pid).contains(raw) }
        }
        let needle = raw.lowercased()
        return procs.filter { p in
            if p.name.lowercased().contains(needle) { return true }
            if let resolved = pidDisplayName[p.pid] {
                return resolved.lowercased().contains(needle)
            }
            return false
        }
    }

    private var rankedProcesses: [ProcSample] {
        let filtered = filteredProcesses
        // Sort uses the EMA-smoothed CPU value for ranking so transient
        // 1-tick spikes don't toss processes around. Stable secondary
        // tiebreaks on the OTHER metric, then PID, keep order
        // deterministic between equally-loaded processes.
        let sorted: [ProcSample]
        switch sortBy {
        case .cpu:
            sorted = filtered.sorted { a, b in
                let av = smoothedCpu[a.pid] ?? a.cpu
                let bv = smoothedCpu[b.pid] ?? b.cpu
                if av           != bv           { return av           > bv }
                if a.memBytes   != b.memBytes   { return a.memBytes   > b.memBytes }
                return a.pid < b.pid
            }
        case .mem:
            sorted = filtered.sorted { a, b in
                if a.memBytes != b.memBytes { return a.memBytes > b.memBytes }
                if a.cpu      != b.cpu      { return a.cpu      > b.cpu }
                return a.pid < b.pid
            }
        case .disk:
            // Raw rate, no EMA: disk traffic is bursty by nature and the
            // user sorting by disk is hunting the burst.
            sorted = filtered.sorted { a, b in
                if a.diskBps != b.diskBps { return a.diskBps > b.diskBps }
                if a.cpu     != b.cpu     { return a.cpu     > b.cpu }
                return a.pid < b.pid
            }
        case .net:
            // Same bursty-burst logic as disk — you sort by network to
            // catch the thing hammering the connection right now.
            sorted = filtered.sorted { a, b in
                if a.netBps != b.netBps { return a.netBps > b.netBps }
                if a.cpu    != b.cpu    { return a.cpu    > b.cpu }
                return a.pid < b.pid
            }
        }
        return Array(sorted.prefix(settings.processCount))
    }
}

// MARK: - Reusable cells

private struct UsageBar: View {
    let load: Double
    let height: CGFloat

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Color.secondary.opacity(0.18))
                RoundedRectangle(cornerRadius: 1.5)
                    // No minimum fill width: an idle core must read as
                    // EMPTY, not as a pebble indistinguishable from a few
                    // percent of load. The tighter radius keeps small
                    // fills bar-shaped instead of blob-shaped.
                    .fill(DesignTokens.loadColor(load))
                    .frame(width: geo.size.width * CGFloat(min(max(load, 0), 1)))
                    // GPU-side interpolation on width — cheap, smooths the
                    // 1Hz tick edges into a continuous-looking bar.
                    .animation(.easeInOut(duration: 0.35), value: load)
            }
        }
        .frame(height: height)
    }
}

private struct CoreStrip: View {
    let loads: [Double]

    var body: some View {
        // While the open-tier baseline is still being established, the
        // coordinator publishes an empty `perCore` array. Show a row of
        // dim placeholder bars sized to the system's actual core count
        // so the strip occupies its real footprint immediately — no
        // layout shift when real data lands ~1 s later.
        if loads.isEmpty {
            let placeholderCount = ProcessInfo.processInfo.activeProcessorCount
            return AnyView(stripLayout(loads: Array(repeating: 0.0, count: placeholderCount),
                                       placeholder: true))
        }
        return AnyView(stripLayout(loads: loads, placeholder: false))
    }

    private func stripLayout(loads: [Double], placeholder: Bool) -> some View {
        // Balanced rows instead of a hardcoded 9-per-row: a 10-core Mac
        // gets 5+5, not 9+1, and core counts beyond 27 still lay out
        // (3 rows of however many fit) instead of being silently cut.
        let rowCount = loads.count <= 9 ? 1 : (loads.count <= 18 ? 2 : 3)
        let perRow = Int((Double(loads.count) / Double(rowCount)).rounded(.up))
        let display = loads
        let rows: [[Double]] = stride(from: 0, to: display.count, by: perRow).map {
            Array(display[$0..<min($0 + perRow, display.count)])
        }
        return VStack(spacing: 2) {
            ForEach(0..<rows.count, id: \.self) { i in
                HStack(spacing: 2) {
                    ForEach(0..<rows[i].count, id: \.self) { j in
                        UsageBar(load: rows[i][j], height: 8)
                            .opacity(placeholder ? 0.35 : 1)
                    }
                }
            }
        }
        .explain("One bar per core (\(loads.count)) — fill and color track each core's load")
    }
}

private struct ThroughputCell: View {
    let label: String
    let metric: Metric<Throughput>
    let activity: Bool
    let history: RingBuffer

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(DesignTokens.numericFont(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .explain(label == "NET"
                      ? "Network throughput across all interfaces: ↓ received · ↑ sent, per second. Sparkline = last 60 s of total activity, log-scaled."
                      : "Disk throughput across all drives: ↓ read · ↑ written, per second. Sparkline = last 60 s of total activity, log-scaled.")
            HStack(spacing: DesignTokens.Space.s) {
                HStack(spacing: 2) {
                    Text("↓")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(arrowColor(base: .systemGreen, bps: inBps))
                    Text(inText).font(DesignTokens.numericFont(size: 11))
                }
                HStack(spacing: 2) {
                    Text("↑")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(arrowColor(base: .systemRed, bps: outBps))
                    Text(outText).font(DesignTokens.numericFont(size: 11))
                }
            }
            // Log-scaled activity sparkline (history is shape; the numbers
            // above carry the live colour). Fixed 0…1 — the buffer already
            // holds the log-normalized fraction.
            GraphView(buffer: history, height: 16, scaleMode: .fixed(0...1))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var inBps: Double {
        if case .ok(let t) = metric { return max(0, t.inPerSec) }
        return -1
    }
    private var outBps: Double {
        if case .ok(let t) = metric { return max(0, t.outPerSec) }
        return -1
    }
    private var inText: String  { formatBps(inBps) }
    private var outText: String { formatBps(outBps) }

    /// Same brightness + saturation treatment the menu-bar widget uses,
    /// implemented in NSColor (macOS 13 compatible — SwiftUI's
    /// `Color.mix` requires 15+).
    private func arrowColor(base: NSColor, bps: Double) -> Color {
        guard activity else { return Color(nsColor: base) }
        let frac: CGFloat
        if bps < 100 { frac = 0 }
        else {
            let maxLog = log10(10.0 * 1_048_576.0)
            let bpsLog = log10(max(bps, 100))
            frac = max(0, min(1, CGFloat(bpsLog / maxLog)))
        }
        let alpha = 0.30 + 0.70 * frac
        let satBuckets: [CGFloat] = [0.10, 0.40, 0.70, 1.00]
        let bucket = min(3, Int(frac * 4))
        let sScale = satBuckets[bucket]

        let sRGB = base.usingColorSpace(.sRGB) ?? base
        var h: CGFloat = 0, s: CGFloat = 0, v: CGFloat = 0, a: CGFloat = 0
        sRGB.getHue(&h, saturation: &s, brightness: &v, alpha: &a)
        let final = NSColor(hue: h, saturation: s * sScale, brightness: v, alpha: alpha)
        return Color(nsColor: final)
    }
}

private struct ProcessList: View {
    let metric: Metric<[ProcSample]>
    let ranked: [ProcSample]
    let sortBy: PanelRootView.ProcSort
    @Binding var expandedPids: Set<Int32>
    @Binding var triedLookup: Set<Int32>
    @Binding var pidPath: [Int32: String]
    @Binding var pidIcon: [Int32: NSImage]
    @Binding var pidDisplayName: [Int32: String]

    var body: some View {
        ScrollView {
            switch metric {
            case .measuring:
                loadingView
            case .unavailable:
                unavailableView
            case .ok:
                // Trailing gutter keeps the overlay scrollbar off the PID
                // column — an occluded pid is a mis-typed kill target.
                listView.padding(.trailing, 10)
            }
        }
        // Flexible: the process list absorbs whatever height the user
        // drags the panel to (the fixed sections above it don't flex).
        .frame(minHeight: 140, maxHeight: .infinity)
    }

    private var loadingView: some View {
        // Reserve the full process-list height so opening the panel
        // doesn't show an empty box — instead, an explicit "we're
        // measuring" affordance until the second open tick lands.
        VStack(spacing: 6) {
            Spacer()
            Text("Measuring processes…")
                .font(DesignTokens.numericFont(size: 11))
                .foregroundStyle(.tertiary)
            Text("first sample is the baseline")
                .font(DesignTokens.numericFont(size: 10))
                .foregroundStyle(.quaternary)
            Spacer()
        }
        .frame(maxWidth: .infinity, minHeight: 200)
    }

    private var unavailableView: some View {
        VStack {
            Spacer()
            Text("Process list unavailable")
                .font(DesignTokens.numericFont(size: 11))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, minHeight: 200)
    }

    private var listView: some View {
        LazyVStack(spacing: 1) {
            ForEach(ranked, id: \.pid) { p in
                let expanded = expandedPids.contains(p.pid)
                VStack(spacing: 0) {
                    rowView(for: p)
                    if expanded {
                        ExpandedRow(pid: p.pid, path: pidPath[p.pid])
                            .transition(.opacity)
                    }
                }
                // Selected row + its detail panel read as ONE region: a
                // single rounded card tinted above the list, with a hair
                // outline. No internal divider — common region alone does
                // the grouping, which keeps the noise down.
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.primary.opacity(expanded ? 0.05 : 0))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(Color.primary.opacity(expanded ? 0.10 : 0), lineWidth: 0.5)
                )
            }
        }
    }

    private func rowView(for p: ProcSample) -> some View {
        HStack(spacing: DesignTokens.Space.s) {
            // Disclosure caret rotates when expanded. The whole row is the
            // tap target — a tiny caret is too small a hit area.
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.tertiary)
                .rotationEffect(.degrees(expandedPids.contains(p.pid) ? 90 : 0))
                .frame(width: 10)
            // App icon if available; reserved width either way so rows
            // stay column-aligned. Deliberately blank for non-.app
            // processes — a sea of generic terminal icons would just
            // create visual noise.
            Group {
                if let icon = pidIcon[p.pid] {
                    Image(nsImage: icon).resizable().interpolation(.high)
                }
            }
            .frame(width: 14, height: 14)
            Text(displayName(for: p))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            // Third column tracks the sort: %CPU normally, or the I/O
            // rate when ranked by disk/network — there's no width for a
            // fourth column at 360 pt, and the value you sorted by is the
            // one you want to read.
            Text(thirdColumnText(p))
                .frame(width: 60, alignment: .trailing)
                .foregroundStyle(sortBy != .mem ? .primary : .secondary)
            Text(formatBytes(Double(p.memBytes)))
                .frame(width: 64, alignment: .trailing)
                .foregroundStyle(sortBy == .mem ? .primary : .secondary)
            Text(String(p.pid))
                .frame(width: 52, alignment: .trailing)
                .foregroundStyle(.tertiary)
        }
        .font(DesignTokens.numericFont(size: 11))
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onTapGesture {
            if expandedPids.contains(p.pid) {
                expandedPids.remove(p.pid)
            } else {
                expandedPids.insert(p.pid)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(processRowLabel(for: p))
        .accessibilityHint("Double tap to expand")
        .explain(pidPath[p.pid] ?? displayName(for: p))
        .task(id: p.pid) {
            // Look up path + icon + display name once per pid. All cheap
            // (proc_pidpath is one syscall; NSWorkspace caches icons
            // internally), but we still avoid repeating them on every
            // render by stamping `triedLookup`.
            if !triedLookup.contains(p.pid) {
                triedLookup.insert(p.pid)
                let path = ProcessIntrospection.executablePath(for: p.pid)
                if let path {
                    pidPath[p.pid] = path
                    if let icon = ProcessIntrospection.appIcon(for: path) {
                        pidIcon[p.pid] = icon
                    }
                }
                pidDisplayName[p.pid] = Self.resolveDisplayName(
                    pid: p.pid, procName: p.name, path: path
                )
            }
        }
    }

    /// One-line syntax reference for the filter field. Lives next to the
    /// parser below so the help can't drift from what's implemented —
    /// update both together.
    static let filterSyntax =
        "Filter: name · pid digits · >5:cpu (≥5%) · <300:mem (MB) · >2:disk · >1:net (MB/s) — cpu is the default metric"

    /// Third-column value text — whatever metric the list is sorted by.
    private func thirdColumnText(_ p: ProcSample) -> String {
        switch sortBy {
        case .disk: return formatBps(p.diskBps)
        case .net:  return formatBps(p.netBps)
        default:    return String(format: "%.1f%%", p.cpu * 100)
        }
    }

    /// Parse ">5", "<3:mem", ">2:disk", ">1:net", ">1:CPU" into a
    /// predicate, or nil when the needle isn't threshold-shaped. Units:
    /// cpu in percent, mem in MB resident, disk/net in MB/s.
    /// Case-insensitive metric names.
    static func thresholdFilter(_ raw: String) -> ((ProcSample) -> Bool)? {
        guard let op = raw.first, op == ">" || op == "<" else { return nil }
        let body = raw.dropFirst()
        let parts = body.split(separator: ":", maxSplits: 1)
        guard let first = parts.first,
              let value = Double(first.replacingOccurrences(of: "%", with: ""))
        else { return nil }
        let metric = parts.count > 1 ? parts[1].lowercased() : "cpu"
        switch metric {
        case "cpu":
            return { op == ">" ? $0.cpu * 100 >= value : $0.cpu * 100 <= value }
        case "mem":
            let bytes = value * 1_048_576
            return { op == ">" ? Double($0.memBytes) >= bytes : Double($0.memBytes) <= bytes }
        case "disk":
            let bps = value * 1_048_576
            return { op == ">" ? $0.diskBps >= bps : $0.diskBps <= bps }
        case "net":
            let bps = value * 1_048_576
            return { op == ">" ? $0.netBps >= bps : $0.netBps <= bps }
        default:
            return nil
        }
    }

    /// Resolved name from the per-pid cache, else the kernel's
    /// `proc_name` (clipped at ~32 bytes). The cache fills lazily after
    /// a row's first render, so a name can sharpen one tick after
    /// appearing — acceptable.
    private func displayName(for p: ProcSample) -> String {
        if let resolved = pidDisplayName[p.pid] { return resolved }
        return p.name.isEmpty ? "[pid \(p.pid)]" : p.name
    }

    /// Best human name for a process, in preference order: the app's
    /// localized name (covers every NSRunningApplication, including
    /// helpers), then the executable basename — UNLESS that basename is
    /// a bare version string ("2.1.162"), the artifact of binaries that
    /// live inside versioned framework directories, in which case walk
    /// up the path past structural segments to the first meaningful one.
    /// `proc_name` is the floor when there's no path at all.
    static func resolveDisplayName(pid: Int32, procName: String, path: String?) -> String {
        if let app = NSRunningApplication(processIdentifier: pid),
           let localized = app.localizedName, !localized.isEmpty {
            return localized
        }
        let fallback = procName.isEmpty ? "[pid \(pid)]" : procName
        guard let path else { return fallback }
        let base = (path as NSString).lastPathComponent
        if !base.isEmpty && !isVersionLike(base) { return base }

        // Lowercased set + lowercased lookup: directory conventions vary
        // ("Versions" in frameworks, "versions" in nvm/asdf trees).
        let structural: Set<String> = [
            "macos", "contents", "versions", "frameworks", "helpers",
            "resources", "current", "a", "bin", "sbin", "libexec", "usr",
            "lib", "install", "installs", "dist", "build", "release",
        ]
        for component in path.split(separator: "/").reversed().dropFirst() {
            let s = String(component)
            if structural.contains(s.lowercased()) || isVersionLike(s) { continue }
            return s
                .replacingOccurrences(of: ".app", with: "")
                .replacingOccurrences(of: ".framework", with: "")
                .replacingOccurrences(of: ".xpc", with: "")
        }
        return fallback
    }

    /// "2.1.162", "14", "1.0", "v22.1.0" — digits and dots, optional
    /// leading "v".
    private static func isVersionLike(_ s: String) -> Bool {
        var body = Substring(s)
        if body.first == "v" || body.first == "V" { body = body.dropFirst() }
        return !body.isEmpty && body.allSatisfy { $0.isNumber || $0 == "." }
    }

    private func processRowLabel(for p: ProcSample) -> String {
        let name = displayName(for: p)
        let cpu  = String(format: "%.1f", p.cpu * 100)
        let mem  = formatBytes(Double(p.memBytes))
        return "\(name), \(cpu) percent CPU, \(mem), PID \(p.pid)"
    }
}

/// Detail row shown beneath an expanded process. Path is supplied by the
/// parent list (which caches it shared with the row's icon), so this view
/// holds no per-process state of its own.
private struct ExpandedRow: View {
    let pid: Int32
    let path: String?

    /// Which signal the user is one click away from sending; nil when no
    /// confirm is pending. Two-step inline confirm instead of a modal —
    /// a modal on a nonactivating panel is awkward, and the morphing
    /// button keeps the destructive action under the same cursor.
    @State private var confirmingSignal: Int32?
    /// One-line outcome of the last signal attempt ("asked to quit",
    /// "no permission — command copied", …).
    @State private var killFeedback: String?

    /// One-shot process biography (owner, threads, uptime, parent),
    /// fetched when the row expands — never on the sampling tick.
    @State private var details: ProcessIntrospection.Details?

    /// Indent aligns the row's content with the parent's name column —
    /// 10pt chevron + the standard inter-cell gap.
    private var leadingIndent: CGFloat { 10 + DesignTokens.Space.s }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Kill feedback temporarily replaces the path line rather
            // than appending below it: the path is the least useful info
            // in the seconds after a kill attempt, and swapping in place
            // keeps the row height stable (no layout jump under the
            // cursor). Reverts automatically; a successful kill usually
            // removes the whole row first anyway.
            HStack(spacing: 4) {
                if let feedback = killFeedback {
                    Image(systemName: "info.circle")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    Text(feedback)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .font(DesignTokens.numericFont(size: 10))
                        .foregroundStyle(.secondary)
                } else {
                    Image(systemName: "folder")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                    pathText
                }
            }
            HStack(spacing: 6) {
                // Icon-only, semantically tinted — the colour and glyph
                // carry the meaning, the footer status line carries the
                // words on hover (same idiom as the rest of the panel).
                // Focus only for `.regular` apps. A bare `!= nil` check is
                // NOT enough: NSRunningApplication is non-nil for faceless
                // `.accessory`/`.prohibited` agents too, and `.activate` on
                // a non-activatable agent can block the main thread — the
                // FB-1 freeze (UniversalControl). Same `.regular` gate the
                // kill path uses for `terminate()`.
                if NSRunningApplication(processIdentifier: pid)?.activationPolicy == .regular {
                    iconButton("arrow.up.forward.app", tint: .accentColor,
                               help: "Bring this app to the front") {
                        NSRunningApplication(processIdentifier: pid)?
                            .activate(options: [.activateAllWindows])
                    }
                }
                // Two-step kill: first click arms (glyph fills + reddens),
                // second within 3 s sends. EPERM falls back to copying the
                // shell command. Fixed frames so arming never shifts a
                // neighbour under the cursor.
                killIconButton(sig: SIGTERM, armed: "stop.circle", fired: "stop.circle.fill",
                               tint: .orange, help: "Terminate — ask to quit (SIGTERM)")
                killIconButton(sig: SIGKILL, armed: "bolt.circle", fired: "bolt.circle.fill",
                               tint: .red, help: "Force Kill — immediate (SIGKILL)")
                if let p = path {
                    iconButton("doc.on.doc", tint: .secondary, help: "Copy path") {
                        let pb = NSPasteboard.general
                        pb.clearContents(); pb.setString(p, forType: .string)
                    }
                    iconButton("magnifyingglass", tint: .secondary, help: "Reveal in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: p)])
                    }
                }
                Spacer()
            }
            // Detail lines, each anchored by a leading glyph so the eye
            // chunks them by kind (gestalt: a consistent leading edge of
            // similar marks reads as a scannable column). Distinct gray
            // levels separate the three kinds without adding colour noise.
            if let d = details {
                detailLine("person", identityLine(d), tint: .secondary,
                           help: "Owner · threads · time alive · parent process")
                if let activity = activityLine(d) {
                    detailLine("gauge.medium", activity, tint: .secondary,
                               help: "Lifetime totals: CPU time and disk bytes since launch")
                }
            }
        }
        .padding(.leading, leadingIndent)
        .padding(.vertical, 6)
        .padding(.trailing, DesignTokens.Space.s)
        .task(id: pid) {
            details = ProcessIntrospection.details(for: pid)
        }
    }

    /// One info line: a dim leading glyph + text. The glyph gives the
    /// line a recognisable "kind" marker at a fixed left edge.
    private func detailLine(_ icon: String, _ text: String, tint: Color, help: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
                .frame(width: 11)
            Text(text)
                .lineLimit(1)
                .truncationMode(.middle)
                .font(DesignTokens.numericFont(size: 10))
                .foregroundStyle(tint)
        }
        .explain(help)
    }

    /// Square icon action button: tinted glyph, faint same-tint chip,
    /// words deferred to the hover status line. No persistent text.
    private func iconButton(_ icon: String, tint: Color, help: String,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: 22, height: 20)
                .background(RoundedRectangle(cornerRadius: 4).fill(tint.opacity(0.12)))
        }
        .buttonStyle(.plain)
        .explain(help)
    }

    /// Kill variant with the two-step arm/fire interaction folded into
    /// the glyph: idle shows the outline icon, armed shows the filled
    /// icon on a stronger chip. Same fixed frame in both states.
    private func killIconButton(sig: Int32, armed: String, fired: String,
                                tint: Color, help: String) -> some View {
        let confirming = confirmingSignal == sig
        return Button(action: {
            if confirming { confirmingSignal = nil; performKill(sig) }
            else {
                confirmingSignal = sig; killFeedback = nil
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                    if confirmingSignal == sig { confirmingSignal = nil }
                }
            }
        }) {
            Image(systemName: confirming ? fired : armed)
                .font(.system(size: 12, weight: confirming ? .bold : .medium))
                .foregroundStyle(confirming ? .white : tint)
                .frame(width: 22, height: 20)
                .background(RoundedRectangle(cornerRadius: 4)
                    .fill(confirming ? tint.opacity(0.85) : tint.opacity(0.12)))
        }
        .buttonStyle(.plain)
        .explain(confirming ? "Click again to confirm" : help)
    }

    /// Path rendered as two segments: directory (head-truncated) + basename
    /// (always visible). Lets the user see the binary name at the right
    /// even when the folder context elides.
    @ViewBuilder
    private var pathText: some View {
        let font = DesignTokens.numericFont(size: 10)
        if let path {
            let url = URL(fileURLWithPath: path)
            let basename = url.lastPathComponent
            let dirname = url.deletingLastPathComponent().path
            HStack(spacing: 0) {
                Text(dirname + "/")
                    .lineLimit(1)
                    .truncationMode(.head)
                    .font(font)
                    .foregroundStyle(.tertiary)
                Text(basename)
                    .font(font)
                    .foregroundStyle(.secondary)
            }
            .textSelection(.enabled)
        } else {
            Text("(path unavailable — process may have exited or read denied)")
                .lineLimit(1)
                .font(font)
                .foregroundStyle(.secondary)
        }
    }

    /// The kill path never does blocking IPC on the main thread —
    /// `kill(2)` is a plain syscall, and `NSRunningApplication.terminate()`
    /// is used ONLY for `.regular` apps (the polite quit-AppleEvent path);
    /// faceless system agents get the raw signal. That restriction is the
    /// FB-1 lesson: AppKit process IPC against non-activatable agents can
    /// hang the main thread, and a frozen widget is worse than a blunt
    /// signal.
    private func performKill(_ sig: Int32) {
        // Pid-reuse guard: if the executable path changed since this row
        // was expanded, the pid was recycled — never signal a stranger.
        // Only enforceable when BOTH paths resolve; a process whose path
        // was unreadable at expand time gets no protection beyond the 3 s
        // confirm window (pids ascend, so reuse inside it is negligible).
        if let cached = path,
           let current = ProcessIntrospection.executablePath(for: pid),
           current != cached {
            killFeedback = "process changed — nothing sent"
            scheduleFeedbackRevert()
            return
        }
        if sig == SIGTERM,
           let app = NSRunningApplication(processIdentifier: pid),
           app.activationPolicy == .regular {
            _ = app.terminate()
            killFeedback = "asked to quit"
            scheduleFeedbackRevert()
            return
        }
        if kill(pid, sig) == 0 {
            killFeedback = sig == SIGKILL ? "killed" : "terminated"
        } else if errno == EPERM {
            let cmd = "kill \(sig == SIGKILL ? "-9" : "-TERM") \(pid)"
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(cmd, forType: .string)
            killFeedback = "no permission — `\(cmd)` copied for sudo"
        } else {
            killFeedback = "already gone"
        }
        scheduleFeedbackRevert()
    }

    /// "alcatraz · 14 threads · up 2h 13m · parent launchd (1)" —
    /// whatever fields resolved; missing ones are simply omitted.
    private func identityLine(_ d: ProcessIntrospection.Details) -> String {
        var parts: [String] = []
        if let u = d.userName { parts.append(u) }
        if let t = d.threadCount { parts.append("\(t) thread\(t == 1 ? "" : "s")") }
        if let s = d.startDate { parts.append("up \(Self.uptimeText(since: s))") }
        if let pp = d.parentPid {
            parts.append("parent \(d.parentName.map { "\($0) (\(pp))" } ?? "pid \(pp)")")
        }
        return parts.joined(separator: " · ")
    }

    /// "cpu 37m total · disk ↓1.2 GB ↑300 MB" — lifetime burn rates that
    /// tell a runaway from a long-lived steady worker. Nil when rusage
    /// was denied (other-user processes).
    private func activityLine(_ d: ProcessIntrospection.Details) -> String? {
        var parts: [String] = []
        if let c = d.cpuTime, c >= 1 {
            parts.append("cpu \(Self.cpuTimeText(c)) total")
        }
        if let r = d.diskBytesRead, let w = d.diskBytesWritten, r + w > 0 {
            parts.append("disk ↓\(formatBytes(Double(r))) ↑\(formatBytes(Double(w)))")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private static func cpuTimeText(_ secs: TimeInterval) -> String {
        let s = Int(secs)
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m \(s % 60)s" }
        return "\(s / 3600)h \((s % 3600) / 60)m"
    }

    private static func uptimeText(since start: Date) -> String {
        let secs = max(0, Int(Date().timeIntervalSince(start)))
        if secs < 60 { return "\(secs)s" }
        if secs < 3600 { return "\(secs / 60)m" }
        if secs < 86_400 { return "\(secs / 3600)h \((secs % 3600) / 60)m" }
        return "\(secs / 86_400)d \((secs % 86_400) / 3600)h"
    }

    /// The feedback line borrows the path line's slot — give the slot
    /// back after a few seconds.
    private func scheduleFeedbackRevert() {
        let shown = killFeedback
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            if killFeedback == shown { killFeedback = nil }
        }
    }

}

// MARK: - Formatting helpers

// Width-stable throughput text: the glyph's 5-char value grammar plus
// "/s", so panel numbers stop jittering sideways every tick. The one
// divergence: the glyph renders zero as blank (its arrow opacity speaks
// for it); the panel has no second channel, so zero shows explicitly.
private func formatBps(_ bps: Double) -> String {
    if bps < 0  { return "—" }
    if bps < 50 { return "  0KB/s" }
    return GlyphRenderer.formatBps(bps) + "/s"
}

private func formatBytes(_ bytes: Double) -> String {
    if bytes >= 1_073_741_824 { return String(format: "%.2f GB", bytes / 1_073_741_824) }
    if bytes >= 1_048_576     { return String(format: "%.0f MB", bytes / 1_048_576) }
    if bytes >= 1_024         { return String(format: "%.0f KB", bytes / 1_024) }
    return String(format: "%.0f B", bytes)
}

// MARK: - Vibrant background

private struct VisualEffectBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .menu
        v.blendingMode = .behindWindow
        v.state = .active
        return v
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

import SwiftUI
import AppKit

/// The dropdown panel's SwiftUI root: CPU + per-core strip, memory + swap,
/// network/disk throughput, and a sortable process list. Reads everything
/// from the shared `MetricsStore` — no sampling here, just rendering.
struct PanelRootView: View {
    @EnvironmentObject var store: MetricsStore
    @EnvironmentObject var settings: SettingsStore
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

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            cpuSection
            divider
            memorySection
            divider
            netDiskRow
            divider
            processSection
            divider
            footer
        }
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
                Spacer()
                HStack(spacing: 4) {
                    Text("pressure").foregroundStyle(.secondary)
                    Text(pressureText).foregroundStyle(pressureColor)
                }
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
                           activity: settings.arrowActivityIndicator)
            // Hide the disk cell entirely when the sampler is permanently
            // unavailable — better than showing empty values forever,
            // which reads as "broken" rather than "doesn't apply on this Mac."
            if !diskUnavailable {
                ThroughputCell(label: "DISK", metric: store.snapshot.disk,
                               activity: settings.arrowActivityIndicator)
            }
        }
    }

    private var diskUnavailable: Bool {
        if case .unavailable = store.snapshot.disk { return true }
        return false
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
                }
                .pickerStyle(.segmented)
                .controlSize(.mini)
                .frame(width: 80)
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

    private var footer: some View {
        HStack(spacing: DesignTokens.Space.m) {
            Button("Settings…") { onShowSettings() }
                .buttonStyle(.borderless)
            Spacer()
            Button("Quit") { NSApp.terminate(nil) }
                .buttonStyle(.borderless)
        }
        .font(DesignTokens.numericFont(size: 11))
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

    private var rankedProcesses: [ProcSample] {
        guard case .ok(let procs) = store.snapshot.processes else { return [] }
        // Apply the user's search filter first — smaller working set,
        // cheaper sort.
        let filtered: [ProcSample]
        if searchText.isEmpty {
            filtered = procs
        } else {
            // Match the truncated kernel name AND the executable basename
            // when we have it — `proc_name` clips at ~32 bytes, so the
            // name a user knows from Activity Monitor may only exist in
            // the path.
            let needle = searchText.lowercased()
            filtered = procs.filter { p in
                if p.name.lowercased().contains(needle) { return true }
                if let resolved = pidDisplayName[p.pid] {
                    return resolved.lowercased().contains(needle)
                }
                return false
            }
        }
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
    }
}

private struct ThroughputCell: View {
    let label: String
    let metric: Metric<Throughput>
    let activity: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(DesignTokens.numericFont(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
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
        .frame(height: 200)
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
        LazyVStack(spacing: 0) {
            ForEach(ranked, id: \.pid) { p in
                VStack(spacing: 0) {
                    rowView(for: p)
                    if expandedPids.contains(p.pid) {
                        ExpandedRow(pid: p.pid, path: pidPath[p.pid])
                            .transition(.opacity)
                    }
                }
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
            Text(String(format: "%.1f%%", p.cpu * 100))
                .frame(width: 56, alignment: .trailing)
                .foregroundStyle(sortBy == .cpu ? .primary : .secondary)
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

        let structural: Set<String> = [
            "MacOS", "Contents", "Versions", "Frameworks", "Helpers",
            "Resources", "Current", "A", "bin", "sbin", "libexec", "usr",
        ]
        for component in path.split(separator: "/").reversed().dropFirst() {
            let s = String(component)
            if structural.contains(s) || isVersionLike(s) { continue }
            return s
                .replacingOccurrences(of: ".app", with: "")
                .replacingOccurrences(of: ".framework", with: "")
                .replacingOccurrences(of: ".xpc", with: "")
        }
        return fallback
    }

    /// "2.1.162", "14", "1.0" — digits and dots only.
    private static func isVersionLike(_ s: String) -> Bool {
        !s.isEmpty && s.allSatisfy { $0.isNumber || $0 == "." }
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
            HStack(spacing: 5) {
                // Focus button only renders when macOS classifies the pid
                // as a regular app (LSUIElement=false bundle). Daemons,
                // CLI processes, and kernel tasks return nil here.
                if NSRunningApplication(processIdentifier: pid) != nil {
                    focusButton(pid: pid)
                }
                // Real signals, two-step confirm. Severity tinting tells
                // Terminate from Force Kill at a glance. On EPERM the
                // action falls back to copying the shell command (the
                // pre-v2 behavior) with an explanation.
                killButton(label: "Terminate",  sig: SIGTERM, role: .warn)
                killButton(label: "Force Kill", sig: SIGKILL, role: .destructive)
                if let p = path {
                    copyButton(label: "path", command: p, role: .neutral)
                }
                Spacer()
            }
        }
        .padding(.leading, leadingIndent)
        .padding(.vertical, 5)
        .padding(.trailing, DesignTokens.Space.s)
        // Stronger contrast than secondary@0.06 so the expanded row reads
        // as a contained sub-surface, not as a same-row continuation.
        // Semantic recessed color, not hardcoded black — adapts to light
        // mode where a black wash would read as a stain.
        .background(
            Color(nsColor: .underPageBackgroundColor).opacity(0.55)
                .overlay(alignment: .top) {
                    Rectangle()
                        .fill(Color.secondary.opacity(0.30))
                        .frame(height: 0.5)
                }
        )
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

    /// Two-step kill: first click arms ("really?"), second click within
    /// 3 s sends the signal. The signal path never does blocking IPC on
    /// the main thread — `kill(2)` is a plain syscall, and
    /// `NSRunningApplication.terminate()` is used ONLY for `.regular`
    /// apps (the polite quit-AppleEvent path); faceless system agents
    /// get the raw signal. That restriction is the FB-1 lesson: AppKit
    /// process IPC against non-activatable agents can hang the main
    /// thread, and a frozen widget is worse than a blunt signal.
    private func killButton(label: String, sig: Int32, role: ButtonRole) -> some View {
        let confirming = confirmingSignal == sig
        return Button(action: {
            if confirming {
                confirmingSignal = nil
                performKill(sig)
            } else {
                confirmingSignal = sig
                killFeedback = nil
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                    if confirmingSignal == sig { confirmingSignal = nil }
                }
            }
        }) {
            // Width fixed to the widest of the two states so the morph
            // to "really?" never shifts the NEIGHBORING button under a
            // stationary cursor — that geometry would turn a double-click
            // into a misdirected destructive click.
            ZStack {
                Text(label).hidden()
                Text("really?").hidden()
                Text(confirming ? "really?" : label)
            }
            .font(DesignTokens.numericFont(size: 10))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 3)
                    .fill(confirming ? Color.red.opacity(0.35) : roleFill(role))
            )
        }
        .buttonStyle(.plain)
        .help(sig == SIGTERM ? "Ask the process to quit (SIGTERM)"
                             : "Force kill immediately (SIGKILL)")
    }

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

    /// The feedback line borrows the path line's slot — give the slot
    /// back after a few seconds.
    private func scheduleFeedbackRevert() {
        let shown = killFeedback
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            if killFeedback == shown { killFeedback = nil }
        }
    }

    enum ButtonRole { case neutral, warn, destructive }

    private func copyButton(label: String, command: String, role: ButtonRole = .neutral) -> some View {
        Button(action: {
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(command, forType: .string)
        }) {
            Text(label)
                .font(DesignTokens.numericFont(size: 10))
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(
                    RoundedRectangle(cornerRadius: 3)
                        .fill(roleFill(role))
                )
        }
        .buttonStyle(.plain)
        .help("Copy to clipboard: \(command)")
    }

    private func roleFill(_ role: ButtonRole) -> Color {
        switch role {
        case .neutral:     return Color.secondary.opacity(0.18)
        case .warn:        return Color.orange.opacity(0.20)
        case .destructive: return Color.red.opacity(0.20)
        }
    }

    private func focusButton(pid: Int32) -> some View {
        Button(action: {
            // Pid-based activation: NSRunningApplication looks up the
            // process by pid and `activate` brings its windows forward.
            // No-op if the process exits between render and click — fine.
            NSRunningApplication(processIdentifier: pid)?
                .activate(options: [.activateAllWindows])
        }) {
            HStack(spacing: 3) {
                Image(systemName: "arrow.up.forward.app")
                    .font(.system(size: 9))
                Text("Focus")
                    .font(DesignTokens.numericFont(size: 10))
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.accentColor.opacity(0.22))
            )
        }
        .buttonStyle(.plain)
        .help("Bring this app to the front")
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

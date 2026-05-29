import SwiftUI
import AppKit

/// The dropdown panel's SwiftUI root: CPU + per-core strip, memory + swap,
/// network/disk throughput, and a sortable process list. Reads everything
/// from the shared `MetricsStore` — no sampling here, just rendering.
struct PanelRootView: View {
    @EnvironmentObject var store: MetricsStore
    @EnvironmentObject var settings: SettingsStore
    /// While the user is hovering over the process list, we freeze the
    /// displayed ordering to whatever it was when the hover began. This
    /// stops rows from re-sorting out from under a click or scroll. When
    /// the hover ends, we drop back to the live ranking on the next tick.
    @State private var hoverFrozenOrder: [ProcSample]?

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
                Text(cpuValueText)
                    .font(DesignTokens.numericFont(size: 12, weight: .medium))
            }
            UsageBar(load: cpuLoad, height: 6)
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
            }
            UsageBar(load: memLoad, height: 6)
            // Memory stays in a narrow band (a healthy machine moves a few
            // percent over a minute), so fixed 0...1 flattens it into a
            // boring line. Auto-scale with 5% minimum span zooms into the
            // variation without amplifying single-percent jitter.
            GraphView(buffer: store.snapshot.memHistory,
                      scaleMode: .auto(minSpan: 0.05))
            HStack(spacing: DesignTokens.Space.m) {
                Text("swap \(swapText)")
                Spacer()
                Text("pressure \(pressureText)")
            }
            .font(DesignTokens.numericFont(size: 10))
            .foregroundStyle(.secondary)
        }
    }

    private var netDiskRow: some View {
        HStack(spacing: DesignTokens.Space.m) {
            ThroughputCell(label: "NET", metric: store.snapshot.net,
                           inLabel: "↓", outLabel: "↑")
            // Hide the disk cell entirely when the sampler is permanently
            // unavailable — better than showing "R — W —" forever, which
            // reads as "broken" rather than "doesn't apply on this Mac."
            if !diskUnavailable {
                ThroughputCell(label: "DISK", metric: store.snapshot.disk,
                               inLabel: "R", outLabel: "W")
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
                .frame(width: 96)
                .scaleEffect(0.85, anchor: .trailing)
            }
            ProcessList(
                metric: store.snapshot.processes,
                ranked: displayedProcesses,
                sortBy: sortBy,
                expandedPids: $expandedPids,
                triedLookup: $triedLookup,
                pidPath: $pidPath,
                pidIcon: $pidIcon
            )
            .onHover { hovering in
                if hovering {
                    hoverFrozenOrder = rankedProcesses
                } else {
                    hoverFrozenOrder = nil
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
            hoverFrozenOrder = nil
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
    }

    /// What the process list actually shows: live ranking when not hovered;
    /// the frozen snapshot taken at hover-begin while hovered.
    private var displayedProcesses: [ProcSample] {
        hoverFrozenOrder ?? rankedProcesses
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
            return String(format: "%.1f / %.0f GB", usedGB, totalGB)
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
            let needle = searchText.lowercased()
            filtered = procs.filter { $0.name.lowercased().contains(needle) }
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
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.secondary.opacity(0.18))
                RoundedRectangle(cornerRadius: 3)
                    .fill(DesignTokens.loadColor(load))
                    .frame(width: max(1, geo.size.width * CGFloat(min(max(load, 0), 1))))
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
        let perRow = 9
        let display = Array(loads.prefix(perRow * 3))    // 3 rows max
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
    let inLabel: String
    let outLabel: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(DesignTokens.numericFont(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
            HStack(spacing: DesignTokens.Space.s) {
                Text("\(inLabel) \(inText)")
                Text("\(outLabel) \(outText)")
            }
            .font(DesignTokens.numericFont(size: 11))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var inText: String {
        if case .ok(let t) = metric { return formatBps(t.inPerSec) }
        return "—"
    }
    private var outText: String {
        if case .ok(let t) = metric { return formatBps(t.outPerSec) }
        return "—"
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

    var body: some View {
        ScrollView {
            switch metric {
            case .measuring:
                loadingView
            case .unavailable:
                unavailableView
            case .ok:
                listView
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
                        ExpandedRow(pid: p.pid, name: p.name, path: pidPath[p.pid])
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
            Text(p.name.isEmpty ? "[pid \(p.pid)]" : p.name)
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
            // Look up path + icon once per pid. Both lookups are cheap
            // (proc_pidpath is one syscall; NSWorkspace caches icons
            // internally), but we still avoid repeating them on every
            // render by stamping `triedLookup`.
            if !triedLookup.contains(p.pid) {
                triedLookup.insert(p.pid)
                if let path = ProcessIntrospection.executablePath(for: p.pid) {
                    pidPath[p.pid] = path
                    if let icon = ProcessIntrospection.appIcon(for: path) {
                        pidIcon[p.pid] = icon
                    }
                }
            }
        }
    }

    private func processRowLabel(for p: ProcSample) -> String {
        let name = p.name.isEmpty ? "process \(p.pid)" : p.name
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
    let name: String
    let path: String?

    /// Indent aligns the row's content with the parent's name column —
    /// 10pt chevron + the standard inter-cell gap.
    private var leadingIndent: CGFloat { 10 + DesignTokens.Space.s }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: "folder")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                Text(path ?? "(path unavailable — process may have exited or read denied)")
                    .lineLimit(1)
                    .truncationMode(.head)
                    .font(DesignTokens.numericFont(size: 10))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            HStack(spacing: 6) {
                // Focus button only renders when macOS classifies the pid
                // as a regular app (LSUIElement=false bundle). Daemons,
                // CLI processes, and kernel tasks return nil here.
                if NSRunningApplication(processIdentifier: pid) != nil {
                    focusButton(pid: pid)
                }
                copyButton(label: "Copy kill -TERM", command: "kill -TERM \(pid)")
                copyButton(label: "Copy kill -9",   command: "kill -9 \(pid)")
                if let p = path {
                    copyButton(label: "Copy path", command: p)
                }
                Spacer()
            }
        }
        .padding(.leading, leadingIndent)
        .padding(.vertical, 4)
        .padding(.trailing, DesignTokens.Space.s)
        .background(Color.secondary.opacity(0.06))
    }

    private func copyButton(label: String, command: String) -> some View {
        Button(action: {
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(command, forType: .string)
        }) {
            HStack(spacing: 3) {
                Image(systemName: "doc.on.doc")
                    .font(.system(size: 9))
                Text(label)
                    .font(DesignTokens.numericFont(size: 10))
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.secondary.opacity(0.15))
            )
        }
        .buttonStyle(.plain)
        .help(command)
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
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.accentColor.opacity(0.18))
            )
        }
        .buttonStyle(.plain)
        .help("Bring this app to the front")
    }
}

// MARK: - Formatting helpers

private func formatBps(_ bps: Double) -> String {
    let neg = bps < 0
    let v = abs(bps)
    let s: String
    if v >= 1_048_576      { s = String(format: "%.1f MB/s", v / 1_048_576) }
    else if v >= 1_024     { s = String(format: "%.0f KB/s", v / 1_024) }
    else                   { s = String(format: "%.0f B/s",  v) }
    return neg ? "—" : s
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

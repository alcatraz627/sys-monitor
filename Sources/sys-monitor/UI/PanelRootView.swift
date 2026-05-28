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

    let onShowSettings: () -> Void

    /// The active sort. Bound to `settings.defaultSort` so the in-panel
    /// segmented picker both reflects the user's saved preference AND
    /// can override it for this session — toggling here writes through.
    private var sortBy: SettingsStore.ProcSort { settings.defaultSort }
    private func setSortBy(_ s: SettingsStore.ProcSort) { settings.defaultSort = s }

    /// Local alias kept for the existing helper signatures (rank logic,
    /// process row labels, etc.).
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
            GraphView(buffer: store.snapshot.memHistory)
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
            HStack {
                Text("PROCESSES")
                    .font(DesignTokens.numericFont(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Picker("", selection: Binding(
                    get: { sortBy },
                    set: { setSortBy($0) }
                )) {
                    Text("CPU").tag(SettingsStore.ProcSort.cpu)
                    Text("MEM").tag(SettingsStore.ProcSort.mem)
                }
                .pickerStyle(.segmented)
                .frame(width: 100)
                .scaleEffect(0.85, anchor: .trailing)
            }
            ProcessList(
                metric: store.snapshot.processes,
                ranked: displayedProcesses,
                sortBy: sortBy
            )
            .onHover { hovering in
                if hovering {
                    // Snapshot the live ranking and pin to it for the
                    // duration of the hover. Resume live on exit.
                    hoverFrozenOrder = rankedProcesses
                } else {
                    hoverFrozenOrder = nil
                }
            }
        }
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
        // Stable secondary sort: tie-breaking by the OTHER metric then by
        // pid means two near-tied processes don't keep swapping seats every
        // tick. This is the cheap form of rank hysteresis — true 2-tick
        // hysteresis can come later if needed.
        let sorted: [ProcSample]
        switch sortBy {
        case .cpu:
            sorted = procs.sorted { a, b in
                if a.cpu      != b.cpu      { return a.cpu      > b.cpu }
                if a.memBytes != b.memBytes { return a.memBytes > b.memBytes }
                return a.pid < b.pid
            }
        case .mem:
            sorted = procs.sorted { a, b in
                if a.memBytes != b.memBytes { return a.memBytes > b.memBytes }
                if a.cpu      != b.cpu      { return a.cpu      > b.cpu }
                return a.pid < b.pid
            }
        }
        // Truncate to the user's preferred display count (clamped to a
        // sane range by the settings stepper).
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
                HStack(spacing: DesignTokens.Space.s) {
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
                // One a11y element per row, read as a sentence, so VoiceOver
                // doesn't enumerate each column separately. Empty names fall
                // back to "[pid N]" already on the visible side; mirror that
                // for the spoken label.
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(processRowLabel(for: p))
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

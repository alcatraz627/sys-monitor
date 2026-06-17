import SwiftUI

/// The settings form. Every control is read by exactly one place in the
/// app (cadences → coordinator, bar style → glyph, count + sort → panel,
/// launch-at-login → SMAppService) — no placeholders or unwired knobs.
struct SettingsView: View {
    @EnvironmentObject var settings: SettingsStore

    var body: some View {
        Form {
            Section("Sampling") {
                Picker("Idle cadence", selection: $settings.idleCadenceSeconds) {
                    ForEach(SettingsStore.idleCadenceChoices, id: \.self) { v in
                        Text("\(formatSeconds(v))").tag(v)
                    }
                }
                .pickerStyle(.menu)
                .help("How often the bar glyph updates while the dropdown is closed. Smaller values cost more idle CPU.")

                Picker("Open cadence", selection: $settings.openCadenceSeconds) {
                    ForEach(SettingsStore.openCadenceChoices, id: \.self) { v in
                        Text("\(formatSeconds(v))").tag(v)
                    }
                }
                .pickerStyle(.menu)
                .help("How often everything in the open dropdown updates. Constraint: idle cadence must be ≥ open cadence.")

                if settings.idleCadenceSeconds < settings.openCadenceSeconds {
                    Label("Idle cadence is being held to match open cadence",
                          systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                        .font(.caption)
                }
            }

            Section("Menu bar") {
                Text("Enable one or more metrics, then order them. They render left-to-right in the menu bar in the order listed below.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("CPU",       isOn: cellBinding(.cpu))
                Toggle("Memory",    isOn: cellBinding(.mem))
                Toggle("Network",   isOn: cellBinding(.net))
                Toggle("Disk I/O",  isOn: cellBinding(.disk))
                if settings.barCells.count == 1 {
                    Label("At least one metric must remain enabled",
                          systemImage: "info.circle")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                }

                // Order of the enabled cells. Up/down nudges one slot; the
                // chevrons disable at the ends.
                ForEach(Array(settings.barCells.enumerated()), id: \.element) { idx, cell in
                    HStack {
                        Text("\(idx + 1).")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                        Text(cell.displayName)
                        Spacer()
                        Button { settings.moveBarCell(cell, up: true) } label: {
                            Image(systemName: "chevron.up")
                        }
                        .buttonStyle(.borderless)
                        .disabled(idx == 0)
                        Button { settings.moveBarCell(cell, up: false) } label: {
                            Image(systemName: "chevron.down")
                        }
                        .buttonStyle(.borderless)
                        .disabled(idx == settings.barCells.count - 1)
                    }
                }

                Toggle("Activity-brightness arrows (NET / DISK)",
                       isOn: $settings.arrowActivityIndicator)
                    .help("Arrow brightness scales logarithmically with throughput — dim at idle, bright at high transfer. No animation, no extra CPU.")

                Picker("Throughput units", selection: $settings.throughputUnit) {
                    ForEach(ThroughputUnit.allCases, id: \.self) { u in
                        Text(u.displayName).tag(u)
                    }
                }
                .pickerStyle(.segmented)
                .help("How NET / DISK rates read, in the glyph and the panel. Bytes/s matches Activity Monitor and disk benchmarks; bits/s matches NIC and ISP quoting.")
            }

            Section("Process list") {
                Stepper(value: $settings.processCount, in: 5...25, step: 1) {
                    HStack {
                        Text("Default count")
                        Spacer()
                        Text("\(settings.processCount)")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
                Picker("Default sort", selection: $settings.defaultSort) {
                    ForEach(SettingsStore.ProcSort.allCases, id: \.self) { s in
                        Text(s.displayName).tag(s)
                    }
                }
                .pickerStyle(.segmented)
            }

            Section("Startup") {
                Toggle("Launch at login", isOn: $settings.launchAtLogin)
                HStack {
                    Text("Status").foregroundStyle(.secondary)
                    Spacer()
                    Text(settings.launchAtLoginStatus)
                        .foregroundStyle(.secondary)
                        .monospaced()
                }
                .font(.caption)
            }

            Section {
                Text("Settings apply live. Cadence changes re-baseline rate metrics for one tick (the glyph briefly shows “—”).")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 380, minHeight: 460)
    }

    private func formatSeconds(_ v: Double) -> String {
        if v == floor(v) { return "\(Int(v)) s" }
        return String(format: "%.1f s", v)
    }

    /// Toggle for a single bar cell. The store's `setBarCell` refuses to
    /// remove the last enabled cell — the menu-bar glyph must always show
    /// something.
    private func cellBinding(_ cell: BarCell) -> Binding<Bool> {
        Binding(
            get: { settings.barCells.contains(cell) },
            set: { settings.setBarCell(cell, enabled: $0) }
        )
    }
}

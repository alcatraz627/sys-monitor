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

            Section("Menu bar glyph") {
                Picker("Show", selection: $settings.barStyle) {
                    ForEach(SettingsStore.BarStyle.allCases, id: \.self) { s in
                        Text(s.displayName).tag(s)
                    }
                }
                .pickerStyle(.segmented)
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
}

# Architecture overview (current)

The one doc to read first. Describes sys-monitor as it stands today (v1.0.0,
post-v2.1) — what the pieces are and where each feature lives. The numbered
`01`–`03` docs are the original v1 planning narrative (WHAT / HOW-IT-BEHAVES /
HOW-IT'S-BUILT) and are kept as design records; this overview supersedes their
module inventories.

## The shape

A menu-bar–only AppKit app (`LSUIElement`, `.accessory` — no Dock icon). Two
halves, one boundary:

```
main thread (AppKit + SwiftUI)                 background serial queue
┌───────────────────────────────┐             ┌──────────────────────────────┐
│ StatusItemController            │  tier cmds  │ SamplingCoordinator          │
│   └ GlyphRenderer → NSImage     │◀───────────▶│   ├ idle / open timers       │
│ PanelController → DropPanel      │             │   ├ rate math vs measured Δt  │
│   └ NSHostingView(PanelRootView) │             │   └ samplers (raw → rates)   │
│ AlertNotifier · GlobalHotkey     │             └──────────────┬───────────────┘
└───────────────┬─────────────────┘                            │ one immutable
                │      MetricsStore (@MainActor, @Published)     │ MetricsSnapshot
                └────────────────────◀──────────────────────────┘ per tick
```

- **All sampling lives on one serial queue.** The only thing that crosses to
  the main thread is an immutable, `Sendable` `MetricsSnapshot` value, published
  once per tick. No shared mutable state.
- **Two sampling tiers.** *Idle* (panel closed) samples only what the menu-bar
  glyph needs. *Open* (panel visible) adds process enumeration, power, battery,
  storage, load, and per-interface network — the expensive work. Rates always
  divide by *measured* `CLOCK_MONOTONIC` elapsed, never nominal cadence, so tier
  switches and timer jitter are correct by construction.
- **Private frameworks behind degrade-to-unavailable adapters.** Power and
  per-process network use private APIs via `dlsym`; any resolution failure
  flips the feature to "unavailable" and the rest of the app is unaffected.

## Module map

### `Model/` — the data that crosses the boundary
| File | Role |
|------|------|
| `Raw.swift` | Raw counter readings (`CPUTicks`, `NetCounters`, `ProcRaw`, etc.) before rate math |
| `Samples.swift` | Render-ready samples (`CPUSample`, `MemorySample`, `Throughput`, `PowerSample`, `BatterySample`, `DiskSpaceSample`, `LoadAverage`, `InterfaceThroughput`, `ClusterFrequency`, `ProcSample`) |
| `Metric.swift` | `Metric<T>` = `.ok` / `.measuring` / `.unavailable` |
| `MetricsSnapshot.swift` | The immutable per-tick value; `Equatable` by `generation` (cheap SwiftUI diff) |
| `MetricsStore.swift` | `@MainActor ObservableObject` holding `@Published snapshot` |

### `Sampling/` — raw reads + the coordinator
| File | Role |
|------|------|
| `SamplingCoordinator.swift` | The two-tier state machine; owns timers, rate math, all queue-isolated state, alert evaluation, and `publishSnapshot` |
| `Sampler.swift` | The sampler protocol + errors |
| `CPUSampler` · `MemorySampler` · `NetworkSampler` · `DiskSampler` · `ProcessSampler` | Core mach/sysctl/libproc reads |
| `RateMath.swift` | Pure rate functions (tick-wrap-safe util, bytes/sec, gap detection) — heavily unit-tested |
| `RingBuffer.swift` | Time-windowed history (value type, COW); adjustable window |
| `PerProcessNetworkMonitor.swift` | Private NetworkStatistics framework (per-pid net) |
| `PowerMonitor.swift` | Private IOReport energy counters → CPU/GPU/ANE watts |
| `FrequencyMonitor.swift` | Per-cluster CPU frequency (IOReport residency × IORegistry DVFS) — engine only, see perf audit |
| `BatterySampler.swift` | Public IOKit power-sources |
| `DiskSpaceSampler.swift` · `LoadSampler.swift` | `statfs` storage · `getloadavg`+uptime |
| `AlertEvaluator.swift` | Pure debounce/cooldown decision core for threshold alerts |
| `ProcessIntrospection.swift` | One-shot per-process detail (owner, threads, parent, app icon) |

### `Shell/` — the AppKit surface
| File | Role |
|------|------|
| `StatusItemController.swift` | Owns the `NSStatusItem`; per-tick glyph redraw + render-skip cache; right-click menu (top consumer) |
| `GlyphRenderer.swift` | Draws the menu-bar cells (`BarCell`, `ThroughputUnit`, `GlyphDensity`, `SeverityThresholds`) into an `NSImage` |
| `DropPanel.swift` · `PanelController.swift` | Borderless key-eligible panel + open/close/pin lifecycle |
| `SettingsWindowController.swift` | The settings window host |
| `AlertNotifier.swift` | `UNUserNotificationCenter` wrapper (bundle-id guarded) |
| `GlobalHotkey.swift` | Carbon `RegisterEventHotKey` (⌥⌘M), no Accessibility permission |

### `UI/` — SwiftUI
| File | Role |
|------|------|
| `PanelRootView.swift` | The whole panel: every row, the process list + interactions, footer actions, self-cost |
| `GraphView.swift` | The sparkline renderer |
| `DesignTokens.swift` | Colors, spacing, the load-color ramp |

### `Settings/`
`SettingsStore.swift` (the persisted `@Published` settings + helpers) and
`SettingsView.swift` (the live form).

### Entry points
`main.swift` dispatches: default → the app; `--self-test` → the regression
suite; `--probe` → headless sampler readout; `--probe-freq` → frequency
validation; `--preview-widget` → the glyph design harness; `--dev-autoquit` →
the isolated dev-build self-terminator.

## Feature → where it lives

| Feature | Primary files |
|---------|---------------|
| Menu-bar cells (CPU/MEM/NET/DISK/Battery), reorder, compact, bytes↔bits | `GlyphRenderer`, `SettingsStore`, `StatusItemController` |
| Severity thresholds (adjustable) | `DesignTokens.loadColor`, `GlyphRenderer.severity`, `SettingsStore` |
| Threshold alerts | `AlertEvaluator` (logic) + `AlertNotifier` (I/O) + coordinator hook |
| Power / battery / storage / load rows | `PowerMonitor` · `BatterySampler` · `DiskSpaceSampler` · `LoadSampler` → `PanelRootView` |
| Per-interface network split | `NetworkSampler` + `SamplingCoordinator.perInterfaceRates` |
| Watch-a-process (pin) | `SettingsStore.pinnedPids` + `PanelRootView` ranking |
| Kill / Focus / Copy / Reveal | `PanelRootView` (ExpandedRow) |
| Copy-snapshot · open Activity Monitor | `PanelRootView` footer |
| Global hotkey · top-consumer menu | `GlobalHotkey` · `StatusItemController` |
| History window, display toggles, reset | `SettingsStore` + `RingBuffer.setWindow` |

## Verifying changes

- `sys-monitor --self-test` — the runnable regression suite (rate math,
  formatters, settings persistence, alert state machine, DVFS parsing, sampler
  invariants). Exit 0 = pass.
- `tools/drills/` — timed behavioral drills (tier transitions, pressure, sleep).
- `docs/09-manual-checks.md` — the human-glance list for pixels/interactions
  that can't be checked headlessly.
- `docs/11-perf-audit.md` — measured footprint + the standing optimization notes.

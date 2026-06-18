<!-- sessions: sys-monitor@2026-05-28 -->

# sys-monitor — Stage 3: Implementation Plan (HOW IT'S BUILT)

> **v1 design record.** The v1 blueprint. Its repo layout + sampler list below
> are the v1 set; the **current** module map (Power/Battery/Frequency/Alerts/
> per-interface net + everything v2.1) lives in [`00-overview.md`](00-overview.md).

> **Stage 3 of 3.** The technical blueprint: toolchain, repo layout, module breakdown,
> the sampling architecture, the two-tier state machine, the AppKit shell + SwiftUI panel
> wiring, build/run, verification, and a phased build sequence with halt points. Grounded
> in `docs/01-spec.md`, `docs/02-behavior.md`, and the proven `claude-instances-v2` build
> template. **Status: revised after sub-agent review** (`.claude/output/20260528-
> implementation-review/`) — concurrency model, panel key/dismiss design, glyph rendering,
> mach/sysctl hygiene, and raw-vs-rate types all corrected.

---

## 1. Architecture at a glance

```
┌──────────────────────────── sys-monitor.app (.accessory, LSUIElement) ────────────────┐
│  AppKit shell (main / @MainActor)                    Sampling core (bg serial queue)   │
│  ┌──────────────────────────────────┐               ┌─────────────────────────────┐    │
│  │ AppDelegate                       │   tier cmds   │ SamplingCoordinator         │    │
│  │  ├ StatusItemController           │  (dispatched  │  ├ idle/open DispatchSource   │   │
│  │  │   └ button.image = NSImage     │   onto bg     │  │   timers (exactly one on)  │   │
│  │  │       (GlyphRenderer draws)    │   queue)      │  ├ rawReading→rate (measured Δt)│  │
│  │  ├ PanelController (DropPanel)    │◀─────────────▶│  ├ re-baseline logic           │   │
│  │  │   └ NSHostingView(PanelRoot)   │               │  ├ memory-pressure source      │   │
│  │  └ SettingsWindowController       │               │  └ samplers (raw counters):    │   │
│  └──────────────────────────────────┘               │     CPU·Mem·Process·Net·Disk   │   │
│             ▲ retained AnyCancellable                └──────────────┬──────────────┘    │
│             │  (redraw glyph on snapshot change)                     │ MainActor.run hop  │
│  ┌──────────┴───────────────────────────────────────────────────────▼──────────────┐    │
│  │ MetricsStore : ObservableObject @MainActor                                       │    │
│  │   @Published var snapshot: MetricsSnapshot   (Sendable value type, set ONCE/tick) │    │
│  └─────────────────────────────────────────────────────────────────────────────────┘    │
│       ▲ reads snapshot copy                  ▲ reads snapshot                            │
│  GlyphRenderer (NSImage)            PanelRootView + sections (SwiftUI, @Environment)      │
│  SettingsStore (UserDefaults) ──▶ cadence / metric / launch-at-login into all of above    │
└───────────────────────────────────────────────────────────────────────────────────────┘
```

**Threading contract (NFR-5, race-free):** all sampling, prev/now counter state, rate math,
and the **authoritative** ring buffers live on one **serial** background `DispatchQueue`.
The coordinator builds a `Sendable` `MetricsSnapshot` (carrying *immutable copies* of the
history window) and assigns it to the `@MainActor` `MetricsStore` exactly once per tick via
`await MainActor.run`. Nothing shared-mutable crosses threads; the glyph and SwiftUI read
only the published snapshot copy. Tier-transition commands from the (`@MainActor`)
`PanelController` are **dispatched onto the sampling queue** (`samplingQueue.async`), never
mutating coordinator timer state from main.

---

## 2. Toolchain & build (mirrors claude-instances-v2)

- **SwiftPM**, `swift-tools-version: 5.9`, `platforms: [.macOS(.v13)]`. Build under
  `-strict-concurrency=complete` (the reference's `MainActor.assumeIsolated` pattern implies
  it; §4's types are designed to pass it).
- One executable product (`sys-monitor`); `build.sh` compiles it and **wraps the bare SPM
  binary into a `.app`** (`Contents/MacOS/` + `Contents/Info.plist`), then **ad-hoc-signs**
  (`codesign --force --sign -`). Identical mechanics to the reference `build.sh`.
- `Info.plist`: `LSUIElement = true`, `NSHighResolutionCapable`, `LSMinimumSystemVersion
  13.0`, `NSPrincipalClass NSApplication`, `CFBundleIdentifier dev.sys-monitor.menubar`.
- **Toolchain caveat (C1):** keep the `.testTarget` **commented in `Package.swift`** (XCTest
  ships with Xcode, not Command Line Tools) — verbatim reference pattern. Rate-math is
  written as pure free functions so it's reasoned-about/testable even before Xcode runs them.
- Frameworks only (NFR-6): AppKit, SwiftUI, Combine, `ServiceManagement`, `IOKit`, Darwin
  (mach/sysctl/libproc). Swift Charts is **not** a default dependency — see §7 (Path
  sparkline first).

---

## 3. Repo layout

```
sys-monitor/
├── Package.swift · build.sh · Resources/Info.plist · docs/
├── Sources/sys-monitor/
│   ├── main.swift                   # manual NSApplication bootstrap (.accessory)
│   ├── AppDelegate.swift            # owns controllers + coordinator + store; sleep/wake obs
│   ├── Shell/
│   │   ├── StatusItemController.swift   # NSStatusItem; retains the glyph redraw cancellable
│   │   ├── GlyphRenderer.swift          # draws bar/sparkline + tabular value -> NSImage
│   │   ├── DropPanel.swift              # NSPanel subclass: canBecomeKey=true, main=false
│   │   ├── PanelController.swift        # anchor, open/close, click-outside monitor, occlusion
│   │   └── SettingsWindowController.swift
│   ├── Sampling/
│   │   ├── SamplingCoordinator.swift    # tiers, raw→rate, re-baseline, pressure source
│   │   ├── Sampler.swift                # protocol: read() throws -> RawReading
│   │   ├── RateMath.swift               # pure free funcs: (prev,now,elapsed)->rate (testable)
│   │   ├── CPUSampler.swift MemorySampler.swift ProcessSampler.swift
│   │   │   NetworkSampler.swift DiskSampler.swift
│   │   └── RingBuffer.swift             # VALUE TYPE struct, fixed-capacity, time-stamped
│   ├── Model/
│   │   ├── Raw.swift                    # CPUCounters, NetCounters, ProcRaw … (cumulative)
│   │   ├── Samples.swift                # CPUSample, MemorySample, ProcSample, Throughput (rates)
│   │   ├── Metric.swift                 # enum Metric<T>: Sendable where T: Sendable
│   │   ├── MetricsSnapshot.swift        # Sendable + Equatable(by generation) value type
│   │   └── MetricsStore.swift           # ObservableObject @MainActor
│   ├── UI/DesignSystem/DesignTokens.swift   # ported from reference + load→color ramp
│   ├── UI/PanelRootView.swift + Sections/… + GraphView.swift
│   └── Settings/SettingsStore.swift + SettingsView.swift
└── Tests/sys-monitorTests/          # RateMath, RingBuffer, re-baseline, Metric (Xcode)
```

---

## 4. Data model (`Model/`) — designed to pass strict concurrency

```swift
// Raw cumulative readings the samplers return (NOT rates):
struct CPUCounters: Sendable  { let perCore: [(user:UInt32,sys:UInt32,idle:UInt32,nice:UInt32)] } // + overall
struct NetCounters: Sendable  { let inBytes, outBytes: UInt64; let ifaceSet: Set<String> }
struct DiskCounters: Sendable { let readBytes, writeBytes: UInt64 }
struct ProcRaw: Sendable      { let pid: Int32; let name: String; let cpuTimeNs: UInt64; let residentBytes: UInt64 }

// Rate / display types stored in the snapshot:
struct CPUSample: Sendable    { let overall: Double; let perCore: [Double] }    // 0...1
struct MemorySample: Sendable { let usedBytes, totalBytes, swapUsedBytes: UInt64; let pressure: Pressure } // instantaneous
enum   Pressure: Sendable     { case normal, warn, critical }
struct ProcSample: Sendable   { let pid: Int32; let name: String; let cpu: Double; let memBytes: UInt64 } // cpu = % of ONE core
struct Throughput: Sendable   { let inPerSec, outPerSec: Double }

enum Metric<T> { case measuring; case ok(T); case unavailable }
extension Metric: Sendable where T: Sendable {}

struct MetricsSnapshot: Sendable, Equatable {
    var generation: UInt64                  // bump per tick; Equatable compares this (cheap, avoids 60-pt array compare)
    var cpu: Metric<CPUSample>; var memory: Metric<MemorySample>
    var processes: Metric<[ProcSample]>; var net: Metric<Throughput>; var disk: Metric<Throughput>
    var cpuHistory, memHistory: RingBuffer  // immutable COPY of the coordinator's window
    static func == (a: Self, b: Self) -> Bool { a.generation == b.generation }
}
```

- **`RingBuffer` is a `struct`** of `[HistoryPoint]` where `HistoryPoint: Sendable`
  (`(timestamp, value)`), fixed capacity, FIFO by time (NFR-4 bound). The coordinator owns
  the authoritative buffer on its serial queue and **copies the current window** into each
  snapshot — there is **no shared mutable buffer** (review issue 1). "BQ-4 shared" now means
  *the history values are shared by being copied into each snapshot*, not one buffer two
  threads touch.
- **`Metric<T>` placeholder contract (FR-16/FR-17):** rate metrics start `.measuring` (→ `—`);
  instantaneous metrics (`memory`) can be `.ok` on tick #1 incl. a legitimate `0`; an errored
  sample is `.unavailable` (→ `—`). UI renders `—` for both `.measuring` and `.unavailable`,
  never `0`.
- `MetricsStore: ObservableObject @MainActor` holds one `@Published var snapshot`. The
  `Equatable`-by-`generation` keeps SwiftUI from over-diffing the 60-point arrays.

---

## 5. Sampling core (`Sampling/`)

### 5.1 Samplers return RAW readings; the coordinator converts to rates

`Sampler` protocol: `func read() throws -> RawReading`. Samplers do **no** rate math — they
return cumulative counters / instantaneous values. This resolves the "samplers return raw
but model is already rates" contradiction (review issue/gap 8): raw types (§4) are distinct
from rate types, and `RateMath` (pure free functions) deltas raw→rate against measured Δt.

| Sampler | Reads (with the mandatory hygiene) | Tier |
| --- | --- | --- |
| `CPUSampler` | `mach_host_self()` → `host_statistics(HOST_CPU_LOAD_INFO)` (overall) and `host_processor_info(PROCESSOR_CPU_LOAD_INFO)` (per-core). **MUST `vm_deallocate(mach_task_self(), addr, count * MemoryLayout<integer_t>.stride)` the returned array every call** (NFR-4 leak otherwise). Returns `CPUCounters` (cumulative ticks). | idle: overall only · open: + per-core |
| `MemorySampler` | `host_statistics64(HOST_VM_INFO64)` → used = (active+wired+compressed)×pagesize; `sysctl([CTL_VM,VM_SWAPUSAGE])` into `xsw_usage` (`xsu_used` bytes; pass `&size`); pressure latched from the dispatch source (§5.3). Instantaneous → `.ok` on tick #1. | idle + open |
| `ProcessSampler` | `proc_listpids(PROC_ALL_PIDS)` (**two-call sizing**: 0-buffer for count, then allocate) → per-pid `proc_pidinfo(PROC_PIDTASKINFO)` → `proc_taskinfo`. **Use ONLY `PROC_PIDTASKINFO`** (drop `proc_pid_rusage` — redundant, doubles syscalls). %CPU = Δ(`pti_total_user`+`pti_total_system` ns)/Δt ns, **normalized to one core (can exceed 100%)** to match Activity Monitor/NFR-2a; mem = `pti_resident_size`. **Skip pids where `proc_pidinfo` returns ≤ 0** (vanished/permission, FR-17). Empty name → `[pid N]` fallback (behavior §3.1 #5). | **OPEN ONLY** |
| `NetworkSampler` | `sysctl([CTL_NET,AF_ROUTE,0,AF_INET,NET_RT_IFLIST2,0])` with the **size-probe-then-fetch two-call pattern**; walk the blob by `if_msghdr2` where `ifm_type==RTM_IFINFO2`, sum `ifm_data.ifi_ibytes/ifi_obytes` over non-loopback `IFF_UP` ifaces. Returns `NetCounters` incl. the iface set (a changed set / negative delta → gap → re-baseline, FR-18). | open |
| `DiskSampler` | IOKit: `IOServiceMatching("IOBlockStorageDriver")` → `kIOBlockStorageDriverStatisticsKey` → `…BytesReadKey`/`…BytesWrittenKey`. **PROVISIONAL (N8/R6):** a persistent capability flag set by the Phase-1 spike; if the spike fails, the sampler permanently reports `.unavailable` and `NetDiskRow` hides the disk side (never `—/—`). | open |

### 5.2 `SamplingCoordinator` — two-tier state machine (behavior §6)

- **Two `DispatchSourceTimer`s** on one **serial** background queue: `idleTimer` (CPU+Mem
  raw reads) and `openTimer` (CPU+per-core+Mem+Process+Net+Disk). **Exactly one active.**
  Prev/now raw counters and the authoritative ring buffers are serial-queue-isolated → no
  intra-sampling race.
- **Tier predicate** (commanded by `PanelController`, dispatched onto the sampling queue):
  `panel.isVisible && panel.occlusionState.contains(.visible)` — NOT key status (issue 1).
- **Rate math (`RateMath`, invariant):** every rate = `(now − prev) / measuredElapsedSeconds`
  where `measuredElapsed` is a `DispatchTime`/`mach_absolute_time` delta — **never** the
  nominal cadence (review issue 4 of Stage-2 / consistent here). Written as free functions
  `rate(prev:now:elapsed:)` so they unit-test without the timer machinery.
- **Re-baseline triggers** (affected metrics → `.measuring`, fresh baseline, no delta):
  idle→open switch (per-core/net/disk/proc never existed in idle); `gap > N×tick` (N=2);
  `NSWorkspace.didWakeNotification`; cadence change; invisible→visible return. **Overall CPU
  carries its idle baseline (the raw tick array, not a rate) into the open tier iff
  `gap < N×tick`** — valid because idle and open read the same `host_statistics` counter.
- **Idempotent + singular timers (issue 5):** `enterOpenTier()` while open = no-op;
  `enterIdleTier()` keeps baselines + buffers alive for the grace window (`N×tick`); reopen
  within grace resumes without re-baseline; a sleep during the closed interval discards/
  gap-marks the buffer.
- **Publish:** build the `Sendable` snapshot (copy history window, bump `generation`) on the
  bg queue → `await MainActor.run { store.snapshot = snap }` (single set; SwiftUI diffs by
  `generation`).

### 5.3 Memory-pressure source

> **Superseded (v2).** The original design here was a
> `DispatchSource.makeMemoryPressureSource` whose handler latched the level.
> It was built and then **removed** during v2 verification: macOS delivers
> warn-level pressure events selectively (largest consumers first), so a
> small menu-bar process can sit through a whole warn episode without ever
> receiving the event — the source stayed silent while the kernel read
> level 2. The shipping implementation polls
> `kern.memorystatus_vm_pressure_level` once per tick on the coordinator's
> serial queue (`refreshPressureLevel`) and latches it into `currentPressure`;
> the sysctl reports the host-wide level unconditionally and is microsecond-
> cheap. See `SamplingCoordinator.refreshPressureLevel` and the rationale
> comment there.

---

## 6. AppKit shell (`Shell/`)

### 6.1 `main.swift` + `AppDelegate`

- Manual `NSApplication` bootstrap inside `MainActor.assumeIsolated { … }`,
  `setActivationPolicy(.accessory)`, `app.run()` — **verbatim reference pattern** (`main.swift`).
- `applicationDidFinishLaunching`: build `SettingsStore`, `MetricsStore`,
  `SamplingCoordinator` (start idle tier), `StatusItemController`, `PanelController`; observe
  `NSWorkspace` `willSleep`/`didWake` → dispatch a re-baseline command onto the sampling
  queue. `applicationWillTerminate`: cancel both timers + the pressure source (no orphan
  timers — review nit).

### 6.2 `StatusItemController` + `GlyphRenderer` (NSImage, not custom NSView)

- `NSStatusBar.system.statusItem(withLength: .variableLength)`. The glyph is rendered to an
  **`NSImage` each tick** and assigned to `statusItem.button?.image` — the proven reference
  path (`button.image`) and `exelban/stats`' technique (review issue 3). `image.isTemplate =
  false` (it's a *colored* load glyph, FR-4 path (b)).
- `GlyphRenderer` draws the bar (or sparkline from `snapshot.cpuHistory`) + the value in a
  **monospaced/tabular font** into a **fixed-width** image whose width = the measured width
  of the widest possible value string (`"100%"` or widest memory string) + bar + insets,
  recomputed only on metric/style change (resolves the old "intrinsic width" open question,
  issue 9). `.variableLength` sizes the button to the image → no separate length math.
- **Redraw wiring (issue 6):** `StatusItemController` holds `private var cancellable:
  AnyCancellable?` = `store.$snapshot.sink { [weak self] snap in self?.redraw(snap) }`. The
  store is `@MainActor`, so the sink runs on main — correct for touching `button.image`. One
  redraw per tick (snapshot changes ≤ once/tick).
- **Glyph accessibility (NFR-9):** `button.setAccessibilityValue("CPU 38 percent")` updated
  on redraw but **not announced** per tick; reads Increase-Contrast / Reduce-Motion via
  `NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast` /
  `…ShouldReduceMotion` and observes `accessibilityDisplayOptionsDidChangeNotification` to
  pick the high-contrast ramp + redraw (review issue 7).
- Left-click toggles the panel (idempotent against live panel state).

### 6.3 `DropPanel` + `PanelController` — borderless anchored dropdown (key-eligible)

- **`DropPanel: NSPanel`** overrides `canBecomeKey { true }` and `canBecomeMain { false }`,
  `styleMask: [.borderless, .nonactivatingPanel]`, `level = .statusBar`,
  `isFloatingPanel = true`, `isReleasedWhenClosed = false`, `hidesOnDeactivate = false`.
  Becoming key lets the SwiftUI sort-toggle + `ScrollView` route events; `.nonactivatingPanel`
  + `canBecomeMain=false` keeps the *app* `.accessory` (review issue 2). Background = SwiftUI
  material, rounded corners.
- **Content:** `NSHostingView(rootView: PanelRootView().environmentObject(store)
  .environmentObject(settings).environment(\.design, settings.resolvedDesign))` — same
  Environment-injection as the reference `DashboardController`.
- **Anchor (FR-19):** on open, position the panel's top edge just below the status-item
  button, x-aligned to it, on the **screen containing the button**; `makeKeyAndOrderFront`.
- **Dismiss vs. demote — `resignKey` is explicitly NOT a dismiss signal (issue 2):**
  - **Dismiss:** a global+local `NSEvent` monitor on `[.leftMouseDown, .rightMouseDown]`
    closes the panel iff the click is **outside** the panel frame → `enterIdleTier()`.
  - **Demote (keep panel):** `windowDidChangeOcclusionState` → if not visible, command idle
    tier; on re-visible, command open tier (which re-baselines). Space-switch/display-sleep/
    Settings-open all resign key but must NOT dismiss — occlusion drives the demote, the
    event monitor drives the dismiss. (Anchor display unplugged → close, behavior §3.4.)

### 6.4 `SettingsWindowController`

- A normal titled window. Opening it: **close the panel first**, then
  `NSApp.activate(ignoringOtherApps:)` + `makeKeyAndOrderFront` (the `.accessory` dance, R8).
- Launch-at-login: `SMAppService.mainApp.register()` / `.unregister()`. **Requires the `.app`
  at a stable path (`~/Applications`, C4)** — a login item pointing at `.build/` silently
  fails. **Read back `SMAppService.mainApp.status` to confirm `.enabled`** and surface
  failure (FR-11 spirit; this is the AC-4 launch-at-login check) — review issue 10.

---

## 7. SwiftUI panel & design (`UI/`)

- `PanelRootView` observes `MetricsStore`; fixed section order (behavior §3.1): CPU →
  per-core → memory → net/disk → processes → footer.
- `CoreStripView`: a plain `Grid`/`VStack` of fixed per-core bars (not `LazyVGrid` — review
  nit; lazy machinery isn't worth it for ≤ dozens of cores). **Caps at 3 rows**, then an
  aggregate histogram (BQ-2). Per-core a11y label.
- `ProcessListView`: fixed-height scroll (top 10, scroll to 25). **Rank hysteresis** (swap
  only after beating a neighbor by a margin or for 2 ticks) + **freeze-on-hover**; stable
  `id: pid`; scroll offset preserved across re-sorts; sort-toggle resets to top; Reduce
  Motion → snap. **No padding `—` rows** when fewer processes than configured; empty name →
  `[pid N]` (behavior §3.1 #5).
- `GraphView`: renders `snapshot.cpuHistory`/`memHistory` (the immutable copy) as a
  hand-drawn **`Path` sparkline** (cheapest per-tick, best for NFR-4; OQ-5/BQ-5 resolved —
  Swift Charts only if richer axes are later wanted and the budget holds). Pre-populated on
  open from the idle ring buffer; gap markers for sleep/wake; Reduce Motion → step/freeze.
- `DesignTokens` + `ResolvedDesign`: **port the reference token system wholesale** (semantic
  colors, `font(_:weight:monospaced:)` with monospaced for **all numerics**, density-scaled
  spacing, the `\.design` `EnvironmentKey`, the `Sendable ResolvedDesign` struct). Add the
  **load→color ramp** (calm/elevated/hot) + an **Increase-Contrast** variant, shared by glyph
  and panel (BQ-3). Panel reads accessibility via `@Environment(\.accessibilityReduceMotion)`
  and `@Environment(\.colorSchemeContrast)` (review issue 7). Color always secondary to value.

---

## 8. Settings (`Settings/`)

- `SettingsStore: ObservableObject` over `UserDefaults`: `idleCadence`, `openCadence`
  (**enforced `idle ≥ open`**, behavior §0), `barMetric`/`barStyle`, `processCount`,
  `defaultSort`, `launchAtLogin`. **Every property has a reader at its effect site** (FR-11):
  cadence → coordinator reschedule + baseline reset (FR-13, dispatched onto sampling queue);
  barMetric/style → `GlyphRenderer` (recompute fixed width); processCount/sort →
  `PanelRootView`; launchAtLogin → `SMAppService` (+ status read-back, §6.4).

---

## 9. Verification strategy (per global testing rules)

- **Unit (Xcode target, kept ready):** `RateMath.rate(prev:now:elapsed:)` against known
  inputs incl. a large elapsed (gap → sane rate, not a spike); `RingBuffer` time-window
  eviction; re-baseline (gap > N×tick → `.measuring`); `Metric` contract (`0` vs `—`). These
  are the correctness landmines — test them directly as pure value logic.
- **Manual / functional (the bar is UI — exercise in the running app, not just build):**
  launch → glyph `—` then live value (AC-1); open → all sections live, sort toggle,
  hover-freeze, scroll persists (AC-2); CPU/MEM graphs pre-populated on open (AC-3); change
  cadence + bar metric → observe effect (AC-4); **idle CPU via Activity Monitor %CPU
  normalized to one core over ≥5 min < ~1%** (AC-5/NFR-2a); open→close CPU drop (AC-6);
  sleep/wake → no spike, `—` then resume (AC-7).
- **Disk spike (Phase 1, gates N8):** throwaway IOKit probe on the user's actual
  Apple-Silicon Mac → confirm `IOBlockStorageDriver` yields sane bytes before committing the
  row; failure → capability flag off → `.unavailable` → row hidden.

---

## 10. Build sequence (phased, halt-point after each)

- **Phase 0 — Skeleton.** `Package.swift`, `Info.plist`, `build.sh`, `main.swift` + empty
  `AppDelegate` with an `NSStatusItem` showing a static SF Symbol (the *image* path — same
  one the live glyph will use, review nit). *Halt:* `.app` builds, launches menu-bar-only,
  icon shows (AC-8).
- **Phase 1 — Raw samplers + rate math + disk spike.** `CPUSampler`, `MemorySampler`, raw
  types, `RateMath`, `RingBuffer` (struct), and the **disk IOKit spike**. Unit-test
  RateMath/RingBuffer. *Halt:* debug loop prints believable CPU%/mem; disk verdict recorded
  (commit/demote N8).
- **Phase 2 — Idle tier + live glyph.** `SamplingCoordinator` idle timer (CPU+Mem),
  `MetricsStore`, `MetricsSnapshot`, the `MainActor.run` publish hop, `GlyphRenderer`
  (NSImage, fixed width, appearance-aware), retained cancellable. *Halt:* live bar updates;
  `—` on launch then value; first idle-CPU read (AC-1, AC-5 first look).
- **Phase 3 — Panel + open tier.** `DropPanel` (key-eligible, click-outside dismiss,
  occlusion demote), `PanelController` anchoring, open timer + re-baseline on switch,
  `PanelRootView` with CPU/per-core/memory/process sections live. *Halt:* click opens live
  panel; sort toggle + scroll work; close drops CPU (AC-2, AC-6); tier switch shows no spike.
- **Phase 4 — Graphs + net/disk + density polish.** `GraphView` (Path sparkline, pre-populated),
  `NetDiskRow` (hides disk side when `.unavailable`), rank hysteresis + freeze-on-hover,
  design tokens + load ramp. *Halt:* graphs populated on open (AC-3); list stable; htop density.
- **Phase 5 — Settings + launch-at-login.** `SettingsStore` (all wired, FR-11), `SettingsView`,
  `SMAppService` + status read-back, the `.accessory` Settings dance. *Halt:* every control
  has a live effect (AC-4); login item toggles and is confirmed `.enabled`.
- **Phase 6 — Edge cases + accessibility + verification pass.** Sleep/wake re-baseline (AC-7),
  occlusion/Space/display-unplug, VoiceOver labels + reading order, Reduce Motion, Increase
  Contrast ramp (both glyph + panel paths). Full AC-1…AC-8 sweep + ≥5-min idle-CPU measure.
  *Halt:* all ACs pass; idle budget confirmed.

---

## 11. Implementation risks & mitigations

- **Off-main → main publish churn.** Mitigated by `Equatable`-by-`generation` snapshots so
  SwiftUI diffs once/tick and unchanged sections don't redraw (NFR-5).
- **Borderless key-eligible panel focus.** `canBecomeMain=false` + `.nonactivatingPanel`
  keeps the app `.accessory` while the panel takes key; dismiss is event-monitor-only, never
  `resignKey` (§6.3). Phase-3 risk, now a decided design.
- **Mach VM leak.** The `vm_deallocate`-every-call invariant (§5.1) is the guard; watch
  resident memory across a long open session in Phase 6 (NFR-4).
- **Disk (N8/R6).** Gated by the Phase-1 spike; never blocks Phases 2–6 (`.unavailable` → hide).
- **`SMAppService` silent failure.** Status read-back (§6.4) surfaces it.

---

## 12. Open questions remaining (low-risk, decide during build)

- **BQ-2** exact per-core wrap counts / aggregate-histogram form at the real core count.
- **BQ-3** precise color-ramp token values + the Increase-Contrast set.

> *(Resolved here: glyph = NSImage with fixed-width rule; `RingBuffer` = struct, snapshot-
> copied; panel = key-eligible borderless, dismiss-via-event-monitor; samplers return raw
> readings, coordinator does rate math; graph = `Path` sparkline (OQ-5/BQ-5); accessibility
> plumbing named for both surfaces; all snapshot types `Sendable`.)*

---

*End of Stage 3 implementation plan (revised post-review). The three stages — spec,
behavior, implementation — are complete and mutually consistent; ready to build from
Phase 0.*

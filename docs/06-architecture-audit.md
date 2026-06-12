# sys-monitor — Independent Architecture Audit Blueprint

<!-- sessions: v2-audit@2026-06-12 -->

Audit of the codebase as it exists at commit `fa31022` (+ `0de4eae` tick-wrap
fix in history). Every structural claim below was verified against source;
`docs/` was used only for cross-checking and drift detection (§8). Line
numbers refer to the current working tree.

Scope: ~3,760 lines of Swift across 24 files under `Sources/sys-monitor/`,
zero third-party dependencies, SwiftPM single executable target
(`Package.swift:21-24`), macOS 13+ (`Package.swift:15`).

---

## 0. Architecture diagram

```
┌──────────────────────────── sys-monitor.app ────────────────────────────┐
│ main.swift ──(--probe → Probe.swift / --preview-widget)──┐              │
│      │ default                                           ▼              │
│      ▼                                              stdout / exit       │
│ AppDelegate (lifecycle, wiring, SMAppService, didWake re-baseline)      │
│   │ builds + wires                                                      │
│   ├──────────────┬──────────────────┬───────────────┬─────────────────┐ │
│   ▼              ▼                  ▼               ▼                 │ │
│ SettingsStore  SamplingCoordinator  StatusItem-    Panel-    Settings-│ │
│ (UserDefaults,   (serial queue)     Controller     Controller Window  │ │
│  Combine pubs)        │             (NSStatusItem)  (DropPanel)       │ │
│                 ┌─────┴──────┐           ▲              │             │ │
│   idle tier 2s ─┤ DispatchSourceTimer ├─ │              │ click       │ │
│   open tier 1s ─┤ (exactly one alive) │  │              ▼             │ │
│                 └─────┬──────┘        │  │      PanelRootView (SwiftUI│ │
│        per tick       ▼               │  │       CPU/MEM graphs, net/ │ │
│  ┌────────────────────────────────┐   │  │       disk, process list)  │ │
│  │ CPUSampler   host_statistics + │   │  │              ▲             │ │
│  │              host_processor_info│  │  │              │ @Published  │ │
│  │ MemorySampler host_statistics64│   │  │              │             │ │
│  │              + sysctl swap     │   │  │              │             │ │
│  │ NetworkSampler sysctl IFLIST2  │   │  │              │             │ │
│  │ DiskSampler  IOKit BlockStorage│   │  │              │             │ │
│  │ ProcessSampler proc_listpids + │   │  │              │             │ │
│  │ (open only)  proc_pidinfo ×N   │   │  │              │             │ │
│  └───────┬────────────────────────┘   │  │              │             │ │
│   raw counters → RateMath deltas      │  │              │             │ │
│   + RingBuffer 60s histories          │  │              │             │ │
│          ▼                            │  │              │             │ │
│   MetricsSnapshot (immutable,         │  │              │             │ │
│   generation-equatable) ──Task@Main──▶ MetricsStore.snapshot ─────────┘ │
│                                          (@MainActor @Published)        │
│   StatusItemController.sink → GlyphRenderer.render → NSImage → button   │
└──────────────────────────────────────────────────────────────────────────┘
```

Data flow in one sentence: a single serial-queue timer ticks a sampler sweep,
RateMath turns cumulative counters into rates, an immutable `MetricsSnapshot`
hops to the main actor into `MetricsStore`, and two independent subscribers —
the AppKit glyph and the SwiftUI panel — re-render from it.

---

## 1. Process & lifecycle

### Entrypoint
- Manual `NSApplication` bootstrap, not `@main` — `main.swift:19-37`. The
  comment at `main.swift:11-13` explains why: SPM executables can't carry
  `LSUIElement`; `build.sh` wraps the bare binary into `sys-monitor.app`
  with `Resources/Info.plist` (`LSUIElement = true` at `Info.plist:23-24`,
  bundle id `dev.sys-monitor.menubar` at `Info.plist:6`).
- Three modes (`main.swift:20-30`): `--probe` runs the Phase-1 sampler
  harness (`Probe.swift:13-95`) and exits; `--preview-widget` shows
  `WidgetPreview` (a design-iteration window, `Preview/WidgetPreview.swift`);
  default starts the menu-bar app with `.accessory` activation policy
  (`main.swift:35`) so there is no Dock icon.
- `MainActor.assumeIsolated` wraps the whole bootstrap (`main.swift:19`)
  to satisfy strict concurrency for `@MainActor` AppDelegate init.

### AppDelegate wiring (`AppDelegate.swift:20-119`)
`applicationDidFinishLaunching` constructs, in order: `SettingsStore`,
`MetricsStore`, `SamplingCoordinator` (cadences from settings,
`AppDelegate.swift:24-28`), `PanelController`, `SettingsWindowController`,
`StatusItemController` (whose click closure toggles the panel,
`AppDelegate.swift:41-47`), then:

- `panelController.bind(statusItem:)` so the panel can anchor under the
  button (`AppDelegate.swift:48`, consumed at `PanelController.swift:43-45`).
- `coordinator.configureIdleSamplers(net:disk:)` — idle-tier NET/DISK
  sampling tracks whether those cells are in the bar
  (`AppDelegate.swift:53-56`).
- Five Combine `sink`s live-apply settings changes, each `dropFirst()` to
  skip the replay value (`AppDelegate.swift:68-102`): idle cadence, open
  cadence, bar cells (rebuilds renderer AND reconfigures idle samplers),
  arrow-activity toggle, launch-at-login.
- Sleep/wake: observes `NSWorkspace.didWakeNotification`
  (`AppDelegate.swift:111-116`) → `coordinator.reBaseline()`
  (`AppDelegate.swift:125-127`) so the first post-wake tick is a baseline,
  not a multi-hour delta.
- Finally `coordinator.startIdleTier()` (`AppDelegate.swift:118`).

### Launch at login
`SMAppService.mainApp.register()/unregister()` driven by the
`launchAtLogin` setting (`AppDelegate.swift:131-140`). Actual status is
read back via `SMAppService.mainApp.status` and surfaced as a label string
(`AppDelegate.swift:142-152`) into `SettingsStore.launchAtLoginStatus`
(`SettingsStore.swift:94, 141-143`) so the settings UI shows truth, not
intent — including the "move .app to ~/Applications" `.notFound` case
(`AppDelegate.swift:147`).

### Quit / reopen
- Quit: panel footer button calls `NSApp.terminate(nil)`
  (`PanelRootView.swift:268`) → `applicationWillTerminate` →
  `coordinator.shutdown()` cancels both timers
  (`AppDelegate.swift:121-123`, `SamplingCoordinator.swift:152-159`).
- Reopen: no `applicationShouldHandleReopen` handler exists — as an
  `LSUIElement` accessory app there is no Dock icon to click; re-launch
  goes through the .app bundle. The status item itself is the only
  persistent surface.

---

## 2. Sampling pipeline

### Coordinator threading model
All mutable sampling state lives behind one serial `DispatchQueue`
(`"sys-monitor.sampling"`, QoS `.utility`, `SamplingCoordinator.swift:36`).
The class is `@unchecked Sendable` with the stated invariant "never call
private methods directly — always `queue.async`"
(`SamplingCoordinator.swift:20-23`). The only cross-thread transfer is the
immutable `MetricsSnapshot`, assigned on the main actor via
`Task { @MainActor ... }` once per tick (`SamplingCoordinator.swift:422-424`).

### Tiers and cadence
- Exactly one of two `DispatchSourceTimer`s is alive at a time
  (`idleTimer`/`openTimer`, `SamplingCoordinator.swift:39-40`); tier
  transitions cancel the other timer first
  (`transitionToIdle` `:163-182`, `transitionToOpen` `:184-201`).
- **Idle tier** (panel closed): overall CPU + memory always; NET/DISK only
  when shown in the bar (`idleTick`, `SamplingCoordinator.swift:233-255`).
  Process enumeration is never promoted to idle "too expensive"
  (`SamplingCoordinator.swift:48-51`).
- **Open tier** (panel visible): full sweep including per-core CPU and
  processes (`openTick`, `SamplingCoordinator.swift:260-279`).
- Cadences: defaults idle 2.0s / open 1.0s (`SamplingCoordinator.swift:71-72`);
  user choices constrained to idle {1,2,5} and open {0.5,1,2}
  (`SettingsStore.swift:51-52`); the invariant idle ≥ open is enforced by
  lifting idle to match (`SettingsStore.enforceOrdering`,
  `SettingsStore.swift:126-136`).
- Timer setup: 20ms initial deadline, repeating at the cadence, **50ms
  leeway** for kernel coalescing (`SamplingCoordinator.swift:208-213`).
- Tier entry/exit is driven by the panel: `open()` →
  `coordinator.enterOpenTier()` (`PanelController.swift:60`), `close()` →
  `enterIdleTier()` (`PanelController.swift:38`). Both are idempotent
  (`SamplingCoordinator.swift:88-103`).

### Samplers and their syscalls

| Sampler | API | Tier | Citation |
|---|---|---|---|
| CPU overall | `host_statistics(HOST_CPU_LOAD_INFO)` → cumulative UInt32 ticks | both | `CPUSampler.swift:29-51` |
| CPU per-core | `host_processor_info(PROCESSOR_CPU_LOAD_INFO)` + mandatory `vm_deallocate` of the kernel array | both (used only in open — see §6) | `CPUSampler.swift:55-89`, dealloc `:68-72` |
| Memory | `host_statistics64(HOST_VM_INFO64)` page counts × `vm_kernel_page_size`; swap via `sysctl(CTL_VM, VM_SWAPUSAGE)`; total RAM once at init from `ProcessInfo.physicalMemory` | both | `MemorySampler.swift:24-60`, init `:19-21` |
| Network | `sysctl(NET_RT_IFLIST2)` two-call sizing, walks `if_msghdr2` records, sums `ifi_ibytes/ifi_obytes` over non-loopback (`IFT_LOOP` skipped); records interface set for change detection | both (idle only if NET in bar) | `NetworkSampler.swift:13-57`, loopback `:46`, ifaceSet `:49` |
| Disk | IOKit `IOServiceGetMatchingServices("IOBlockStorageDriver")`, sums `"Bytes (Read)"`/`"Bytes (Write)"` from each driver's `"Statistics"` property; throws if zero drivers | both (idle only if DISK in bar) | `DiskSampler.swift:24-64`, keys `:8-10` |
| Processes | `proc_listpids(PROC_ALL_PIDS)` two-call sizing, then per PID `proc_pidinfo(PROC_PIDTASKINFO)` + `proc_name`; CPU time = `pti_total_user &+ pti_total_system` (ns); vanished/denied PIDs skipped | open only | `ProcessSampler.swift:21-79`, skip rule `:59` |

All samplers conform to `Sampler` (`Sampling/Sampler.swift:8-14`) and throw
`SamplerError` (`Sampler.swift:18-32`).

### Raw counters → rates (RateMath)
Pure free functions, deliberately separated from timers for testability
(`RateMath.swift:3-11`):
- `cpuUtilization(prev:now:)` — busy/(busy+idle) from tick deltas, **deltas
  with `&-` wrapping subtraction** so UInt32 counter wrap yields a correct
  small delta; clamped to 0...1 (`RateMath.swift:20-29`).
- `cpuPerCore` — per-element of the above, shorter array wins on core-count
  mismatch (`RateMath.swift:36-44`).
- `bytesPerSec(prev:now:elapsed:)` — returns `nil` on non-positive elapsed
  or `now < prev` (counter wrap/reset), which the coordinator treats as
  "measuring" (`RateMath.swift:50-53`).
- Per-process %CPU is computed inline in the coordinator, not RateMath:
  Δ cpu-time-ns / Δ wall-ns, Activity-Monitor convention, can exceed 1.0
  (`SamplingCoordinator.swift:383-393`).

The invariant "every rate divides by MEASURED elapsed, never nominal
cadence" is stated at `RateMath.swift:8-11` and honored: `elapsed` comes
from `monoSeconds()` (`clock_gettime(CLOCK_MONOTONIC)`,
`SamplingCoordinator.swift:430-435`) sampled at each tick
(`SamplingCoordinator.swift:234-236, 261-263`).

### Gap and baseline handling
- A tick is a "gap" when `elapsed <= 0` or `elapsed > cadence ×
  gapMultiplier` (2.0) (`SamplingCoordinator.swift:44, 236, 263`). Gap ticks
  store fresh prevs (via `defer`) but return `.measuring`.
- Tier switches drop per-core and per-process prevs but **preserve**
  NET/DISK prevs (so a bar-resident NET keeps its rate across panel
  open/close); the gap check catches the stale-prev case when idle wasn't
  sampling them (`SamplingCoordinator.swift:163-200`, rationale comments
  `:166-172, 187-191`).
- Wake from sleep drops **all** baselines (`dropAllBaselines`,
  `SamplingCoordinator.swift:219-226`). Note: on Darwin
  `CLOCK_MONOTONIC` continues across sleep (unlike `CLOCK_UPTIME_RAW`), so
  the 2× gap check is itself a second line of defense against sleep gaps.
- Interface-set change (VPN/USB) forces NET re-baseline
  (`SamplingCoordinator.swift:338-339`).
- History: two value-type `RingBuffer`s (60s window, hard cap 4096,
  `RingBuffer.swift:27`, time-based eviction `:43-53`) for CPU and memory,
  appended in the read functions (`SamplingCoordinator.swift:290, 304, 322`)
  and copied into every snapshot.

### Publication
`publishSnapshot` bumps a `generation` counter with `&+=` and builds an
immutable `MetricsSnapshot` (`SamplingCoordinator.swift:404-425`).
Snapshot equality compares **only** `generation`
(`MetricsSnapshot.swift:19-21`) so SwiftUI diffing never walks the history
arrays. `MetricsStore` is a tiny `@MainActor ObservableObject` with one
`@Published var snapshot` (`MetricsStore.swift:10-15`).

---

## 3. Rendering — the menu-bar glyph

### Update path
`StatusItemController` subscribes to `store.$snapshot`
(`StatusItemController.swift:44-46`) and on every publish sets
`button.image = renderer.render(snapshot:)` plus an accessibility value
(`StatusItemController.swift:57-61`). It paints once at init so the item
has width before the first tick (`StatusItemController.swift:30-32`).
Clicks route through an `@objc` NSObject shim (`ClickTarget`,
`StatusItemController.swift:67-72`) into `PanelController.toggle()`.
Settings changes rebuild the `GlyphRenderer` wholesale
(`StatusItemController.swift:52-55`).

### GlyphRenderer (`Shell/GlyphRenderer.swift`)
- Cell model: `BarCell { cpu, mem, net, disk }` (`GlyphRenderer.swift:7-9`);
  GPU mentioned as reserved in the comment but **no case exists**.
- `render(snapshot:)` builds one `NSImage` per tick with the
  drawing-handler initializer (`GlyphRenderer.swift:62-92`),
  `isTemplate = false` (`:90`) because cells use identity colors.
- **Width strategy is hybrid, not globally fixed**:
  - CPU/MEM cells: icon (17pt) + 16×12 progress bar + percent text whose
    width is `max(actual, "00%")` — so the widget reflows at the 99%→100%
    boundary by design (`measureCell`, `GlyphRenderer.swift:97-108`, design
    note `:63-66`).
  - NET/DISK cells: **structurally fixed** — values are always exactly
    5 monospaced chars (`formatBps`, `GlyphRenderer.swift:419-445`) and the
    reserved width is `max(measure("999MB"), measure("999GB"))`
    (`GlyphRenderer.swift:135-138`). Magnitude promotion happens at the
    999.5 rounding boundary, not 1024, to keep 5 chars
    (`:408-418`); zero renders as 5 spaces, measuring/unavailable as
    right-aligned `—` (`:420-421`).
- Severity coloring: bar fill green/yellow/red at CPU 0.60/0.85 and MEM
  0.75/0.92 thresholds (`GlyphRenderer.swift:155, 163, 313-319, 356-360`).
  Icon hue is a constant per-cell identity color (`:42-49`).
- Activity arrows: ↓green/↑red, with optional log-scale dimming — alpha
  0.30–1.00 continuous, saturation quantized into 4 buckets
  {0.10, 0.40, 0.70, 1.00} (`arrowColor`, `GlyphRenderer.swift:257-279`).
- `TintedGlyphCache` memoizes tinted SF Symbol images keyed on
  symbol×size×weight×color, `NSLock`-guarded, never evicts (bounded key
  space in practice) (`GlyphRenderer.swift:469-516`).

---

## 4. Panel UI

### Window machinery
- Click on the status item → `PanelController.toggle()`
  (`PanelController.swift:49-51`). `open()` lazily creates a `DropPanel`
  once and reuses it (`isReleasedWhenClosed = false`,
  `PanelController.swift:56-58, 77`), anchors it centered under the button
  with a 6pt gap (`anchor`, `:92-100`), makes it key, enters open tier,
  installs a **global** `NSEvent` monitor for outside-clicks
  (`:104-117`); the monitor deliberately isn't local so in-panel clicks
  reach SwiftUI controls (`comment :108-111`).
- `DropPanel` is a borderless `.nonactivatingPanel` at `.statusBar` level;
  `canBecomeKey = true` / `canBecomeMain = false` so it takes keyboard
  focus without activating the app; dismiss-on-`resignKey` is deliberately
  NOT used because it fires on Space switches/occlusion
  (`DropPanel.swift:15-18`, `PanelController.swift:74-79`).
- Settings window: an "activation dance" — close the panel first, then
  `NSApp.activate(ignoringOtherApps:)` + `makeKeyAndOrderFront`
  (`SettingsWindowController.swift:21-37`).

### Content (`UI/PanelRootView.swift`)
Fixed 360pt-wide VStack on `NSVisualEffectView` (`.menu` material,
`PanelRootView.swift:58-66, 788-797`). Sections top to bottom
(`:46-57`):

1. **CPU** — header + value, 60s sparkline (`GraphView`, fixed 0...1
   scale), per-core strip (`:71-86`). `CoreStrip` lays up to 27 cores in
   rows of 9 and shows dim placeholders sized to
   `activeProcessorCount` while per-core is still `[]` (`:394-428`).
2. **MEM** — sparkline with auto-scale (`minSpan: 0.05`,
   `:99-100`; range logic `GraphView.swift:99-115`), swap GB and a
   pressure label colored by severity (`:101-126`).
3. **NET / DISK throughput row** — disk cell hidden entirely when the
   metric is `.unavailable` ("doesn't apply on this Mac" vs "broken",
   `:128-145`).
4. **Process list** — search field (case-insensitive name containment,
   `:339-345`), CPU/MEM segmented sort (persisted via
   `settings.defaultSort`, `:41-42, 155-164`), top-N rows
   (`prefix(settings.processCount)`, default 10, `:367`,
   `SettingsStore.swift:112`).
5. **Footer** — Settings… and Quit (`:263-272`).

Process-list behaviors worth knowing:
- **Rank hysteresis**: sorting (CPU mode) uses a per-pid EMA (α = 0.4)
  rebuilt on each generation change, so one-tick spikes don't reorder the
  list (`updateSmoothedCpu`, `:224-237`; sort use `:350-359`).
- **Hover freeze**: while hovering the list, the displayed order is frozen
  to the order at hover-begin so rows don't move under the cursor
  (`:10-14, 175-181, 259-261`); typing in search un-freezes (`:186-191`).
- **Expandable rows**: click toggles an expanded detail row
  (`:595-601, 545-556`) with executable path (head-truncated dir +
  visible basename, `:686-710`), copy-to-clipboard `kill -TERM` /
  `kill -9` / path buttons (`:660-663, 714-731` — they copy, they do not
  execute), and a Focus button only for pids that map to an
  `NSRunningApplication` (`:654-656, 741-764`).
- **Per-pid lookup caches** (`triedLookup`, `pidPath`, `pidIcon`) are
  hoisted to the root so they survive panel close/reopen, populated once
  per pid via `.task(id:)` calling `ProcessIntrospection.executablePath`
  (`proc_pidpath`, `ProcessIntrospection.swift:13-23`) and a walk-up-to-
  `.app`-bundle icon lookup (`ProcessIntrospection.swift:30-45`); pruned
  against live pids each tick (`prunePerPidState`,
  `PanelRootView.swift:242-255`).

Refresh: everything re-renders reactively from
`@EnvironmentObject store: MetricsStore` — snapshot generation bump per
tick drives SwiftUI invalidation; there is no panel-local timer.

---

## 5. Error handling & failure modes

### The contract
A sampler `throw` becomes `Metric.unavailable` for that metric, that tick —
each `readX` wraps its sampler in `do/catch`
(`SamplingCoordinator.swift:285, 296, 325-327, 334, 351, 366`). `Metric<T>`
is the tri-state `measuring / ok / unavailable` (`Metric.swift:15-19`); UI
shows `—` for both non-ok states (e.g. `GlyphRenderer.swift:368-373`).
Errors are retried implicitly — every tick calls every active sampler
again; nothing is latched except the UI's choice to hide a permanently
unavailable disk cell (`PanelRootView.swift:135-145`).

### The UInt32 tick-wrap crash fix (commit `0de4eae`)
The overall-CPU read used to do
`UInt32(bitPattern: Int32(info.cpu_ticks.N))` — `host_cpu_load_info`'s
fields are `natural_t` (UInt32), and once cumulative host idle ticks
crossed `Int32.max` (weeks of uptime), the `Int32(...)` conversion trapped
on **every** sample. The fix passes the UInt32 values through unchanged
(`CPUSampler.swift:42-50`); wrap is handled downstream by `&-` deltas in
`RateMath.cpuUtilization` (`RateMath.swift:21-24`).

### Sibling-risk sweep (verified, with verdicts)
- `CPUSampler.readPerCore` still uses
  `UInt32(bitPattern: Int32(info[...]))` (`CPUSampler.swift:82-85`) — this
  is **safe**, not a latent copy of the bug: `info` is
  `processor_info_array_t` (pointer to `integer_t` = Int32), so
  `Int32(Int32)` is identity (no trap) and `bitPattern:` correctly
  reinterprets kernel values past 2³¹ that arrive as negative Int32s.
- `RateMath.bytesPerSec` handles UInt64 wrap/reset by returning `nil`
  (→ `.measuring`), never subtracting (`RateMath.swift:51`). Safe.
- `ProcessSampler` cpu-time sum uses `&+` (`ProcessSampler.swift:70`);
  per-proc delta guards `raw.cpuTimeNs >= prevNs`
  (`SamplingCoordinator.swift:383`). Safe.
- `NetworkSampler`/`DiskSampler` accumulate with `&+=`
  (`NetworkSampler.swift:47-48`, `DiskSampler.swift:49, 52`). Safe.
- Generation counter uses `&+=` (`SamplingCoordinator.swift:411`). Safe.

### Latent failure modes found (not currently crashing, worth a v2 look)
1. **Stale-prev rate inflation after transient sampler failure.**
   `prevTickTime` is updated unconditionally every tick
   (`SamplingCoordinator.swift:247, 271`), but `prevNet`/`prevDisk` are
   only updated on a successful read (the `defer` runs only when `read()`
   didn't throw — `:335, 352`). If NET or DISK throws for N consecutive
   ticks and then recovers, the next success deltas N ticks' worth of
   bytes against ONE tick's `elapsed` → a transient rate spike of up to
   N×. The gap check can't catch it because `elapsed` is normal. CPU is
   immune (its rate is a ratio of deltas, not delta/elapsed). Fix shape:
   per-metric prev timestamps, or null the prev on read failure.
2. **Memory pressure is dead plumbing.** `MemorySample.pressure` exists
   (`Samples.swift:29`) and the panel renders it with severity colors
   (`PanelRootView.swift:117-126, 324-333`), but the coordinator calls
   `raw.toSample()` with the `.normal` default
   (`SamplingCoordinator.swift:324`, default at
   `MemorySampler.swift:74`). No `DispatchSource.makeMemoryPressureSource`
   exists anywhere in `Sources/`. The panel will display "pressure normal"
   forever, including during real pressure events. (See drift, §8.)
3. **Snapshot loss is theoretically possible, invisible in practice.**
   Each tick's publish is an unordered `Task { @MainActor }` hop
   (`SamplingCoordinator.swift:422-424`); two ticks' tasks could in
   principle land out of order under main-thread starvation, and a
   later-generation snapshot could be overwritten by an earlier one.
   Equality-by-generation means SwiftUI would just render the stale one
   for a tick. Low severity; worth ordering (e.g.
   `if snap.generation > current.generation`) in v2.
4. **`CoreStrip` caps display at 27 cores** (9 × 3 rows,
   `PanelRootView.swift:412-413`) — silently truncates on >27-core Macs
   (Mac Pro). Cosmetic-functional edge.
5. **Empty `barCells` is guarded twice** — settings UI refuses to uncheck
   the last cell (claim at `SettingsStore.swift:104-106`), and
   `GlyphRenderer.init` falls back to `[.cpu]` on an empty list
   (`GlyphRenderer.swift:52`). Defense in depth, no gap found.

---

## 6. Resource cost of the monitor itself

### Timers / wakeups
- Exactly one `DispatchSourceTimer` alive at any moment; 50ms leeway
  allows coalescing (`SamplingCoordinator.swift:203-217`). Idle default:
  one wake per 2s, forever — **sampling never pauses for display sleep or
  screen lock**; only full system sleep suspends it (timer queue
  suspension) with `didWake` re-baseline. There is no
  `screensDidSleep` handling. A locked-but-awake Mac pays full idle cost
  including bar rendering.
- The panel's open tier reverts correctly on every close path (click-out
  monitor, toggle, settings dance — all go through `close()`,
  `PanelController.swift:35-39`), so the expensive tier can't leak on.

### Per-idle-tick work (default config, CPU+MEM bar)
- `host_statistics` (1 mach call) + **`host_processor_info`** — note:
  `CPUSampler.read()` always reads per-core
  (`CPUSampler.swift:20-25`), and the idle path calls the same `read()`
  (`SamplingCoordinator.swift:283-285`) then throws the per-core data away
  (`readOverallCPU` returns `perCore: []`, `:291`). That's a kernel
  array allocation + copy + `vm_deallocate` every idle tick for data
  nobody uses. Cheap individually, but it is the single clearest "wakes
  the CPU unnecessarily" item — an idle-only overall read would halve the
  CPU sampler's mach traffic.
- `host_statistics64` + `sysctl(VM_SWAPUSAGE)` for memory.
- If NET in bar: 2 sysctls + one `[UInt8]` buffer allocation sized to the
  full interface list per tick (`NetworkSampler.swift:17-24`). If DISK in
  bar: an IOKit service iteration + a CF dictionary copy per driver per
  tick (`DiskSampler.swift:26-54`).
- One `MetricsSnapshot` (value copy; the RingBuffer arrays are CoW —
  the snapshot's retained reference forces one ~60-element array copy on
  the next append).
- One `Task` closure allocation for the main-actor hop (`:422`).
- Main-thread side: `GlyphRenderer.render` builds a **new NSImage** plus
  several `NSString.size()` text measurements per cell per tick
  (`GlyphRenderer.swift:62-92, 349-351`), plus an accessibility string
  (`StatusItemController.swift:60`). Tinted icons are cache hits after
  first render (`TintedGlyphCache`, `GlyphRenderer.swift:490-516`).

### Per-open-tick extra work (1s default)
- `proc_listpids` + per-PID `proc_pidinfo` + `proc_name` — roughly 2
  syscalls × N processes (N ≈ 400–700 on a busy Mac) every second
  (`ProcessSampler.swift:24-77`), plus two dictionary builds
  (`SamplingCoordinator.swift:370-396`).
- SwiftUI: full snapshot invalidation per generation; process ranking
  re-sorts the filtered list (`PanelRootView.swift:335-368`) and rebuilds
  the EMA dictionary (`:224-237`) each tick. Per-row path/icon lookups are
  once-per-pid (`:605-619`).
- Open-tier cost exists **only while the panel is visible** — the design's
  central cost-control idea, and it holds up under audit.

### Memory
- Bounded by construction: RingBuffers capped (60s window / 4096 hard cap,
  `RingBuffer.swift:22-31`), per-pid UI caches pruned to live pids
  (`PanelRootView.swift:242-255`), glyph cache key-space bounded.
  `vm_deallocate` discipline in CPUSampler prevents the classic
  `host_processor_info` leak (`CPUSampler.swift:65-72`).

---

## 7. Settings surface (for completeness)

`SettingsStore` persists 7 keys to `UserDefaults` with write-through
`didSet`s (`SettingsStore.swift:63-95`): idle/open cadence, bar cells
(OptionSet rawValue Int, ordered CPU>MEM>NET>DISK,
`SettingsStore.swift:19-39`), process count (default 10), default sort,
launch-at-login, arrow-activity (default ON, `:116-118`).
`SettingsView` (`Settings/SettingsView.swift`) renders them; the panel and
coordinator react via the AppDelegate sinks (§1).

---

## 8. Docs / comment drift found (docs are NOT ground truth)

| Claim | Where claimed | Reality |
|---|---|---|
| Coordinator owns a `DispatchSource.makeMemoryPressureSource` and latches pressure into snapshots | `MemorySampler.swift:9-12`; `docs/03-implementation.md:191` (§5.3), `:86`, `:161`, `:210`; architecture diagram `:26` | **Not implemented.** No pressure source exists in `Sources/`; pressure is permanently `.normal` (`SamplingCoordinator.swift:324`, default `MemorySampler.swift:74`). UI renders the dead value (`PanelRootView.swift:104-126`). |
| Idle tier is "bar glyph only: overall CPU + memory" | `SamplingCoordinator.swift:12-13` (own doc comment) | Stale — idle also samples NET/DISK when those cells are in the bar (`SamplingCoordinator.swift:48-51, 240-245`). The later comments are correct; the header comment lags. |
| `HistoryPoint.timestamp` is "seconds since reference (mach absolute time)" | `RingBuffer.swift:14` | It's `clock_gettime(CLOCK_MONOTONIC)` (`SamplingCoordinator.swift:430-435`) — which on Darwin advances across sleep, unlike mach absolute time. Materially different for gap semantics. |
| `monoSeconds` returns "wall-clock seconds" | `SamplingCoordinator.swift:429` | Misnomer — it's monotonic, deliberately NOT wall-clock (immune to clock changes is the point). Wording only. |
| GPU bar cell "planned, case is reserved" | `GlyphRenderer.swift:6` | No `gpu` case exists in `BarCell` (`GlyphRenderer.swift:7-9`). Comment describes an intention, not reserved code. |
| `nsLoadColor` provides "NSColor parity for the glyph renderer" | `DesignTokens.swift:24` | **Dead code** — zero callers; GlyphRenderer uses its own `Severity` switch (`GlyphRenderer.swift:313-319`). |
| Tests exist in `Tests/` | `Package.swift:12-13` (commented target) | Test target is commented out (XCTest needs full Xcode); RateMath's "trivially testable" design currently has no executing tests. |

Spot-checks of `docs/01-spec.md`/`02-behavior.md` FR references embedded in
code comments (FR-16/17/18, NFR-4) matched observed behavior; the
memory-pressure section is the one substantive docs-vs-code divergence.

---

## 9. Audit verdicts (summary)

**Sound:** serial-queue isolation with value-type hand-off; measured-elapsed
rate math with wrap-safe deltas; two-tier cost model that provably reverts;
gap/baseline discipline incl. wake and interface-change handling;
mach-memory hygiene; bounded memory everywhere checked.

**Fix-worthy for v2 (functional):** stale-prev rate inflation after
transient NET/DISK failures (§5.1); memory pressure dead plumbing (§5.2);
out-of-order snapshot publish (§5.3, low).

**Fix-worthy for v2 (efficiency):** idle tier pays for per-core CPU it
discards (§6); no display-sleep/lock pause; per-tick NSImage + text
measurement on the glyph path.

**Hygiene:** stale comments listed in §8; dead `nsLoadColor`; re-enable
tests.

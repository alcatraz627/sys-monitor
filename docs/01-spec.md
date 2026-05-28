<!-- sessions: sys-monitor@2026-05-28 -->

# sys-monitor — Stage 1: Specification (WHAT)

> **Stage 1 of 3.** Defines *what* sys-monitor is and the requirements it must satisfy —
> not *how* it behaves moment-to-moment (Stage 2) or *how* it's built (Stage 3).
> **Status: revised after sub-agent review** (review at
> `.claude/output/20260528-spec-review/spec-review.md`). All critical + should-fix
> findings incorporated; C-1 resolved with the user (hybrid shell).

---

## 1. One-liner

A macOS menu-bar application that shows a live system-resource readout in the menu bar
and, on click, drops down a rich, htop-inspired panel with CPU, memory, top processes,
and network/disk I/O — including history graphs — while staying light enough to run all
day.

---

## 2. Goals

- **G1 — At-a-glance health.** The menu-bar glyph itself surfaces a live resource value
  (default: overall CPU %) without the user having to click anything.
- **G2 — htop-grade depth on demand.** Clicking the glyph reveals per-core CPU, memory +
  swap, a ranked process list, and network/disk throughput — the information density of
  htop, in a native panel.
- **G3 — Trends, not just instants.** Recent history is shown as graphs (sparklines /
  small charts), so the user sees direction, not only the current number.
- **G4 — Leave-it-running light.** Idle resource cost is low enough that the app runs
  continuously without being a meaningful contributor to the very load it measures.
- **G5 — Configurable.** Refresh cadence, which metric the bar shows, and panel content
  are adjustable through a settings surface.
- **G6 — Native and self-contained.** A single `.app` for personal use on the user's own
  Mac, with no external runtime dependencies.

---

## 3. Non-goals (v1 scope ceiling)

Explicitly **out** of v1 to keep scope bounded — candidate v2 items, not commitments.

- **N1** — GPU, temperature/fan sensors, battery detail. (Apple-Silicon sensor access is
  fiddly and often needs SMC reads / extra entitlements; defer.)
- **N2** — Process *control* (kill/renice/inspect). v1 process list is **read-only**.
- **N3** — Multi-machine / remote monitoring.
- **N4** — Distribution, notarization, App Store, sandbox. Personal/local only (see C3).
- **N5** — Alerting / notifications on thresholds.
- **N6** — Per-process network or disk attribution (very expensive; system-wide only in v1).
- **N7** — Historical persistence across launches. Graph history is in-memory,
  session-scoped.
- **N8** — Reliable disk throughput is **demotable to v2.** If a Stage-3 spike shows
  system-wide disk I/O can't be obtained reliably on the target Apple-Silicon hardware
  without elevated privileges, the disk row drops to v2 rather than blocking v1 (see C-3 /
  §9 R6 / §8).
- **N9** — P/E-core labeling in the per-core strip (see §9 R7). v1 shows cores by index.

---

## 4. Inspirations & references

- **htop** — interaction model and density target: per-core meters, memory/swap bars, a
  live ranked process table, color-coded usage.
- **exelban/stats** (open source, ~38k★) — canonical macOS menu-bar monitor; reference for
  mach-API sampling (CPU/mem/net/disk) and bar rendering. Mine for *technique*, not
  copy-paste. (Note: its disk-I/O handling has had repeated issues — see C-3.)
- **iStat Menus / MenuMeters** — the "live value in the bar" interaction (G1).
- **Existing local widget code** — `~/.claude/widgets/claude-instances` (V1 AppKit bar)
  and `claude-instances-v2` (SwiftPM build, design tokens, status-bar controller, manual
  `NSApplication` + `.accessory` shell). **This is the architectural template for the
  hybrid shell** (see C2). Its `gotchas.md` is a constraint source (§9).

---

## 5. Functional requirements

### 5.1 Menu-bar glyph (always-on)

- **FR-1** The app runs as a menu-bar-only agent (no Dock icon, no main window) via
  `.accessory` activation policy + `LSUIElement`.
- **FR-2** The glyph displays a **live inline readout**, updated on the idle cadence, via a
  custom-drawn `NSView` in the `NSStatusItem` button — supporting a mini-bar/sparkline +
  numeric value, not only text. Default content: overall CPU % with a mini usage bar.
- **FR-3** The bar readout's metric/style is user-selectable (e.g. CPU %, CPU sparkline,
  memory %). Exact option set finalized in Stage 2.
- **FR-4** The glyph renders **crisply at all backing-scale factors (1×/2×/3×)** and stays
  legible in light, dark, and tinted/translucent menu bars. The spec mandates a decision
  (locked in Stage 2/3) between: **(a) template/monochrome** glyph that auto-adapts to
  menu-bar appearance, or **(b) custom-colored** glyph that must manually handle
  appearance changes (incl. "Reduce Transparency" and tinted menu bars). A live colored
  usage bar implies (b); plan for the manual appearance handling.

### 5.2 Dropdown panel (on click)

- **FR-5** Clicking the glyph opens a dropdown panel rendered as a **live SwiftUI view
  hosted in an `NSPanel` (via `NSHostingView`)**; its contents update continuously while
  open (no close/reopen needed to see fresh data).
- **FR-6** The panel presents these sections (final layout/order is Stage 2):
  - **CPU** — overall %, plus a **per-core** meter strip (htop-style; cores by index, see
    N9/R7).
  - **Memory** — used / total, memory pressure, and **swap** used.
  - **Top processes** — a ranked list (default: by CPU), showing process name, %CPU,
    memory, and PID. Read-only.
  - **Network** — current up / down throughput (system-wide).
  - **Disk** — current read / write throughput (system-wide). **Provisional — see N8/C-3.**
- **FR-7** **Graphs.** At least CPU and memory show recent history as a compact graph
  (sparkline or small area chart). The history window is specified in **time** (default:
  **last 60 seconds**), so it stays constant when cadence changes — not as a fixed sample
  count.
- **FR-8** The process list can be re-ranked (at minimum: by CPU vs. by memory). Sort
  affordance specified in Stage 2.
- **FR-9** Quit and open-Settings are reachable from the panel. *(Note: presenting a
  Settings window from an `.accessory` app is a known activation sharp edge — see §9 R8.)*

### 5.3 Settings

- **FR-10** A settings surface exposes at least:
  - **Refresh cadence** — idle (bar) tick and open-panel tick (one or two controls).
  - **Bar readout metric/style** — what the glyph shows.
  - **Process list defaults** — count shown, default sort.
  - **Launch at login** — toggle (via `SMAppService`; shares the activation concern in R8).
- **FR-11** **Every settings control must be wired to a reader at the point it affects.**
  No placeholder/unwired controls ship (direct lesson from the existing widget's
  gotchas.md). A not-yet-wired control must be visibly labeled "not yet active."
- **FR-12** Settings persist across launches (`UserDefaults` / `@AppStorage`).
- **FR-13 (cadence-change safety)** Changing a cadence at runtime must not leave a
  double-firing timer or a stale rate baseline: the affected sampler re-establishes its
  baseline on cadence change (ties FR-10 ↔ FR-15/FR-18).

### 5.4 Refresh cadence & sampling tiers

- **FR-14** Two logical cadences: an **idle cadence** (bar glyph only, always running) and
  an **open-panel cadence** (full metric set, only while the panel is visible). Default:
  **2 s idle / 1 s open** (resolves OQ-2; trades against NFR-1).
- **FR-15** Expensive sampling (per-core, process enumeration, net/disk, graph history)
  runs **only while the panel is visible/key** — not merely while the panel object exists.
  A panel open on another Space/display that is not visible must drop to the idle cadence
  (protects NFR-1; see S-2/FR-19).

### 5.5 Robustness & always-on edge cases

- **FR-16 (first-sample baseline contract).** Rate metrics (CPU, per-process %CPU, net,
  disk) require two samples. Before a valid rate exists (cold start, post-wake,
  post-interface-change), the readout shows a **neutral placeholder (e.g. `—` / "measuring…"),
  never a numeric `0`.** (Visual form is Stage 2; the contract is locked here. A busy
  machine showing `0%` reads as broken.)
- **FR-17 (metric-unavailable contract).** Each metric defines an explicit
  unavailable/empty presentation (e.g. `—`). A failed or raced sample never crashes the
  app, blanks the whole panel, or poisons a rate baseline. The `proc_listpids` →
  `proc_pidinfo` PID race is handled by **skipping vanished PIDs**, not erroring. Partial
  fields for other-user/root processes are tolerated.
- **FR-18 (sleep/wake re-baseline).** On wake from sleep — or any sampling gap exceeding
  N× the tick interval — the next sample is treated as a **fresh baseline**: no rate is
  computed across the gap (prevents garbage spikes like "CPU 4000%"). Triggered off
  `NSWorkspace.willSleepNotification` / `didWakeNotification`. Network counter-wrap and
  interface appear/disappear (VPN) are handled the same way (gap → re-baseline).
- **FR-19 (multi-display anchoring).** The panel anchors to the display whose menu bar was
  clicked, and dismisses on resign-key.

---

## 6. Non-functional requirements

- **NFR-1 — Idle CPU budget (the hard one).** With the panel closed, sustained CPU use
  attributable to sys-monitor should be **< ~1% of a single core, as Activity Monitor
  reports it** (see NFR-2a for the measurement contract). The idle tick does the minimum:
  **one or two cheap aggregate snapshots (overall CPU, and memory)** for the bar readout
  plus a lightweight CPU/memory ring buffer that pre-populates the panel graphs on open
  — **never** per-core, process, network, or disk sampling (those are open-tier only).
- **NFR-2 — Tiered sampling.** Expensive work (process enumeration, per-core, net/disk,
  graph history) runs **only while the panel is visible** (FR-15). Process enumeration must
  never run on the idle tick. *(This is the architectural lever that makes NFR-1
  achievable; it is a requirement, not an implementation detail.)*
- **NFR-2a — Idle-budget measurement method (so NFR-1/AC-5 are objectively verifiable).**
  Measured via **Activity Monitor / `top` %CPU, normalized to a single core** (the value
  Activity Monitor shows), sampled over a **≥5-minute** window with the panel closed, on
  an Apple-Silicon Mac (M-series). This defines what "1%" means and how AC-5 is adjudicated.
- **NFR-3 — Native sampling APIs.** Metrics come from in-process system APIs (mach /
  libproc / sysctl / IOKit), **not** by shelling out to `top`/`ps`/`vm_stat` on a timer
  (subprocess-per-tick was a death-curve lesson in the existing widget work).
- **NFR-4 — Low memory footprint.** Resident memory small enough to be a non-event for an
  always-running utility. **Target: stay under ~80 MB resident** including retained graph
  history (note: Swift Charts + retained history can drift toward 100 MB+ — this cap is a
  design constraint on history length and chart choice; ties to OQ-5).
- **NFR-5 — Fast, glitch-free updates.** Live updates must not flicker or visibly reflow
  the panel. Sampling happens **off the main thread**; only the UI mutation is on main.
- **NFR-6 — Single binary, no external deps.** No bundled Python/Node/daemon. First-party
  Apple frameworks only (Swift Charts acceptable for graphs, subject to NFR-4).
- **NFR-7 — Cold start is quick.** App is usable within ~1 s of launch (bar readout shows
  the FR-16 placeholder until the first rate is valid).
- **NFR-8 — Correct on Apple Silicon and Intel** where feasible. Per-core counts and P/E
  asymmetry differ; v1 shows cores by index and **must not crash or misreport** on either
  architecture. (See R7 for the P/E honesty limitation.)
- **NFR-9 — Accessibility.** The bar glyph and panel values expose accessibility labels
  (the existing `StatusBarController` already sets `accessibilityDescription` — don't
  regress). Graphs **honor Reduce Motion** (freeze/step rather than animate). Colors honor
  Increase Contrast, and **load is never signaled by color alone** (don't rely on red/green
  as the sole cue).

---

## 7. Constraints

- **C1 — Platform.** macOS 13+ (Ventura) minimum. Target the user's actual OS
  (Tahoe / macOS 26) for design idioms. **Toolchain:** Swift 5.9+ tools-version,
  `.macOS(.v13)` platform (mirrors the reference `Package.swift`). Note the reference
  repo's lesson: **a test target may require full Xcode, not Command Line Tools alone** —
  carry forward so Stage 3 doesn't rediscover it.
- **C2 — Shell architecture (resolved from C-1 with the user).** **Hybrid:** AppKit
  `NSStatusItem` with a **custom `NSView` glyph** for the always-on bar readout (full
  control over mini-bar/sparkline/%/color — what `MenuBarExtra`'s label can't do), plus an
  **`NSPanel` hosting a live SwiftUI view via `NSHostingView`** for the dropdown. Manual
  `NSApplication` bootstrap with `.accessory` policy and `LSUIElement` (the SPM-executable
  pattern proven in `claude-instances-v2/Sources/HostShell/main.swift`). SwiftUI is used
  for *all* panel content; AppKit is confined to the shell + glyph.
- **C3 — Distribution.** Personal/local only: ad-hoc or unsigned, **no App Sandbox**, no
  notarization. The lack of sandbox is what allows free process enumeration and the
  user-space mach/IOKit reads in §8; a deliberate trade, acceptable because the app never
  leaves the user's machine.
- **C4 — Build.** SwiftPM-based build producing a `.app` (mirroring
  `claude-instances-v2`'s `Package.swift` + `build.sh`, which assembles the bundle +
  Info.plist around the SPM executable). Runnable from `~/Applications`. No Xcode project
  files required (subject to C1's test-target caveat).
- **C5 — Repo.** Project root `/Users/alcatraz627/Code/Claude/sys-monitor`; not yet a git
  repo (init is a Stage 3 concern). When init happens, `.claude/output/` (review artifacts)
  must be gitignored.

---

## 8. Data sources (what each metric reads — feasibility-vetted in review)

All sources below are usable **from user space without the App Sandbox** (C3 is what
enables process enumeration and these reads). Risk level noted per row.

| Metric            | System source (intended)                                          | Risk |
| ----------------- | ----------------------------------------------------------------- | ---- |
| Overall CPU %     | `host_statistics(HOST_CPU_LOAD_INFO)` deltas between ticks         | OK |
| Per-core CPU %    | `host_processor_info(PROCESSOR_CPU_LOAD_INFO)` per-core deltas (remember `vm_deallocate`) | OK (interpretation caveat: P/E cores, R7) |
| Memory + pressure | `host_statistics64(HOST_VM_INFO64)` + `DISPATCH_SOURCE_TYPE_MEMORYPRESSURE` (or `kern.memorystatus_vm_pressure_level`) | OK |
| Swap              | `sysctl(VM_SWAPUSAGE)`                                              | OK |
| Process list      | `proc_listpids` + `proc_pid_rusage` / `proc_pidinfo`               | OK (handle PID race FR-17; %CPU is itself a delta) |
| Network throughput| `sysctl(NET_RT_IFLIST2)` interface byte counters, delta'd          | OK (handle counter-wrap + interface churn, FR-18) |
| Disk throughput   | IOKit `IOBlockStorageDriver` statistics, delta'd                   | **RISKY — provisional (N8/C-3): spike in Stage 3** |

> **Rate metrics** (CPU, per-process %CPU, network, disk) are computed from deltas between
> two samples; the first tick establishes a baseline and the rate appears on the second.
> See FR-16 (baseline contract) and FR-18 (sleep/wake re-baseline).

---

## 9. Known risks & constraints inherited from prior widget work + review

From `~/.claude/widgets/claude-instances/gotchas.md` and the Stage-1 review:

- **R1 — AppKit menus freeze while open.** `NSMenu` rows / `attributedTitle` don't redraw
  while visible. *Mitigation:* the dropdown is a SwiftUI view in an `NSPanel` (C2), which
  updates from `@Published` state — sidesteps R1. (The glyph is a custom `NSView` we redraw
  ourselves, also not subject to the `NSMenu` freeze.)
- **R2 — Per-tick heavy work flickers.** *Mitigation:* NFR-5 (off-main sampling,
  minimal-diff UI updates).
- **R3 — Subprocess-per-tick is a death curve.** *Mitigation:* NFR-3 (in-process APIs).
- **R4 — Unwired settings mislead.** *Mitigation:* FR-11.
- **R5 — Sandbox would block process enumeration.** *Mitigation:* C3 (no sandbox).
- **R6 — Disk I/O via IOKit is unreliable on Apple-Silicon/APFS/NVMe.** Matching the right
  driver node and aggregating APFS-synth vs. physical store is non-obvious; exelban/stats
  has struggled here. *Mitigation:* N8 (demotable to v2) + Stage-3 spike before committing
  the disk row.
- **R7 — P/E-core asymmetry.** On Apple Silicon, `host_processor_info` intermixes P/E
  cores; a uniform per-core strip is interpretively misleading (E-cores pinned, P-cores
  idle, unlabeled). *Mitigation:* v1 shows cores by index (N9); P/E labeling is v2. Stated
  so the cut is intentional, not an oversight.
- **R8 — Settings/Launch-at-login presentation from an `.accessory` app** is a known
  activation sharp edge (`NSApp.activate`, window ordering, `Settings` scene vs. custom
  window). *Mitigation:* budget for it in Stage 2/3 (FR-9/FR-10); don't treat it as a
  one-liner.

---

## 10. Acceptance criteria (how we'll know v1 is done)

- **AC-1** A menu-bar glyph shows a live, updating CPU (or chosen) readout — with a mini
  usage bar — while the panel is closed.
- **AC-2** Clicking opens a panel showing per-core CPU, memory+swap, a ranked process
  list, and network throughput, all updating live while open. *(Disk row subject to N8 —
  if demoted, AC-2 drops the disk requirement.)*
- **AC-3** CPU and memory each show a recent-history graph over a fixed time window (FR-7).
- **AC-4** Settings can change the bar metric and the open-panel cadence, and the change
  takes effect (verified live). For the **idle** cadence, verification is by observing the
  bar update interval change (it can't be checked the same instant as the bar-metric swap).
- **AC-5** Measured idle CPU (panel closed) sits at/under the NFR-1 budget using the
  **NFR-2a measurement method** over ≥5 minutes.
- **AC-6** Closing the panel (or it becoming non-visible) demonstrably stops the expensive
  sampling (NFR-2/FR-15), verifiable via the idle CPU drop.
- **AC-7** After a sleep/wake cycle, no rate metric displays a garbage spike (FR-18) — the
  first post-wake interval shows the placeholder, then resumes normally.
- **AC-8** The app builds to a `.app` via a single build script and launches as a
  menu-bar-only agent.

---

## 11. Open questions (to resolve in later stages)

- **OQ-1** Bar readout when style is "CPU sparkline": is a text % always shown alongside,
  or sparkline-only? (Stage 2 UX.)
- **OQ-3** Process list length default (e.g. top 8 vs top 15) and whether it scrolls.
- **OQ-5** Graph rendering: Swift Charts vs. hand-drawn `Path` sparklines — decided in
  Stage 3 on perf/memory grounds (NFR-4; Swift Charts can be heavier per-tick).

> *(OQ-2 resolved → FR-14: 2 s idle / 1 s open. OQ-4 resolved → launch-at-login is in v1
> via `SMAppService`, FR-10.)*

---

*End of Stage 1 spec (revised post-review). Next: Stage 2 (behavior plan).*

# External research: best practices from existing system monitors

<!-- sessions: v2-audit@2026-06-12 -->

Research input for sys-monitor v2 (Swift/AppKit menu-bar monitor, htop-inspired,
tiered sampling: cheap idle tier for menu-bar glyphs + rich tier when the panel
is open). Eleven sources surveyed; practices below are concrete and citable.

## Per-source summary table

| Source | Type | Key takeaway for us |
|---|---|---|
| [exelban/stats](https://github.com/exelban/stats) | Swift menu-bar monitor (GitHub, ~30k stars) | Per-module configurable update intervals (default 1s); separate interval for top-processes; sensors/Bluetooth modules cost up to 50% of the app's CPU; SMC sensor keys change per SoC generation |
| [macmon](https://github.com/vladkens/macmon) | Rust Apple Silicon TUI monitor | Sudoless CPU/GPU/ANE power via private IOReport API; default 1000ms interval; exposes both frequency-scaled "effective usage" and raw active-residency ratios; library offers `get_metrics_now(stale_after_ms)` for caller-paced sampling |
| [socpowerbud](https://github.com/dehydratedpotato/socpowerbud) | ObjC sudoless powermetrics clone | IOReport dual-sample delta methodology; derives freq/voltage/usage from performance-state residency counters; reverse-engineered from powermetrics |
| [asitop](https://github.com/tlkh/asitop) | Python Apple Silicon monitor | The anti-pattern to avoid: wraps `sudo powermetrics` subprocess; hardcoded TDP/bandwidth maxima because no public API exists; rolling-average smoothing window (`--avg`) as a UX feature |
| [MenuMeters (yujitach fork)](https://github.com/yujitach/MenuMeters/blob/main/MenuMetersMenuExtraBase.m) | ObjC menu-bar monitor source | `NSTimer` with explicit `setTolerance:.2*interval` (20%); `NSRunLoopCommonModes` so updates continue while menus are open; detects "installed but hidden by system" via `CGWindowListCreate(kCGWindowListOptionOnScreenOnly)` |
| [btop](https://github.com/aristocratos/btop) | C++ TUI monitor | Default `update_ms = 2000`; docs recommend ≥2000ms "for better sample times for graphs" — longer windows give smoother, more truthful deltas |
| [iStat Menus](https://bjango.com/mac/istatmenus/) + [MacRumors](https://forums.macrumors.com/threads/istat-menus-cpu-usage-power-consumption.2131152/) / [TheSweetBits review](https://thesweetbits.com/tools/istatmenus-review/) | Commercial monitor (reviews/forums) | User-facing refresh-rate tiers (Slow/Medium/Fast ≈ 1.4% / 1.8% / 2.8% self-CPU); v7 marketed as "1/5th the CPU usage of v6 with the same items" — self-cost is a competitive feature |
| [Apple: Minimize Timer Usage](https://developer.apple.com/library/archive/documentation/Performance/Conceptual/power_efficiency_guidelines_osx/Timers.html) | Apple Energy Efficiency Guide | Tolerance ≥10% of interval on every repeating timer; >1 idle wakeup/sec means investigate; timer coalescing batches wakeups across apps; `timerfires` for debugging |
| [Apple: Schedule Background Activity](https://developer.apple.com/library/archive/documentation/Performance/Conceptual/power_efficiency_guidelines_osx/SchedulingBackgroundActivity.html) / [NSBackgroundActivityScheduler](https://developer.apple.com/documentation/foundation/nsbackgroundactivityscheduler) | Apple docs | Deferrable-work scheduler with default tolerance = half the interval; `shouldDefer` for battery-aware backoff; intended for ≥10-minute cadence (housekeeping, not per-second sampling) |
| [Apple: Extend App Nap](https://developer.apple.com/library/archive/documentation/Performance/Conceptual/power_efficiency_guidelines_osx/AppNap.html) | Apple docs | Don't rely on App Nap; proactively listen for visibility/occlusion changes and suspend work yourself; App Nap mostly protects *other* apps from you |
| [Apple Dev Forums: per-process CPU](https://developer.apple.com/forums/thread/655349) | Forum thread (DTS-grade answer) | `proc_pidinfo(PROC_PIDTASKINFO)` + `host_processor_info` deltas is the supported path; `proc_pid_rusage` adds nothing and breaks in sandbox; Activity Monitor uses private `sysmond` XPC — unavailable to us |

---

## Theme 1 — Sampling strategy

**Per-module, per-tier intervals are the industry norm.** exelban/stats stores
`"\(title)_updateInterval"` per module with a 1-second default
([reader.swift](https://github.com/exelban/stats/blob/master/Kit/module/reader.swift)),
and crucially keeps a *separate, slower* interval for the top-processes list —
process enumeration is the expensive part, so it ticks less often than the
headline gauge. iStat Menus exposes the same idea as user-facing Slow/Medium/Fast
tiers with measurably different self-CPU (≈1.4%→2.8%,
[MacRumors thread](https://forums.macrumors.com/threads/istat-menus-cpu-usage-power-consumption.2131152/)).

**Longer windows give better graphs.** btop defaults to `update_ms = 2000` and
its docs recommend ≥2000ms "for better sample times for graphs"
([btop README](https://github.com/aristocratos/btop)). CPU% is a *delta over a
window*, not an instantaneous value; a 2s window is less noisy than 1s and half
the cost. classic `top` defaults to 3s.

**Delta-based counters need careful window bookkeeping.** All credible sources
sample cumulative counters twice and divide by the elapsed window: socpowerbud's
"dual-sample delta" over IOReport residency counters
([socpowerbud](https://github.com/dehydratedpotato/socpowerbud)), the
`/proc/stat` tick-delta approach in htop/top, and `proc_pidinfo` tick deltas for
per-process CPU ([Apple forums](https://developer.apple.com/forums/thread/655349)).
A real-world failure mode: exelban/stats
[issue #2777](https://github.com/exelban/stats/issues/2777) — CPU/GPU/ANE *power*
readings doubled when the update interval was set to ≥2s, because the energy
delta wasn't being normalized by the actual elapsed window. Lesson: always
divide by measured wall-clock elapsed, never by the nominal interval.

**Pull, don't push, when tiers differ.** macmon's library API offers
`get_metrics_now(stale_after_ms)` — caller-paced sampling with a staleness
cache — alongside the continuous `get_metrics(duration_ms)` poller
([macmon](https://github.com/vladkens/macmon)). That is exactly the shape a
tiered monitor wants: the panel tier *pulls* fresh data on its own schedule and
reuses a sample if one is recent enough, rather than running a second
free-running timer that can double-sample.

**Align ticks to coalesce work.** exelban/stats users complain that independent
module timers drift apart and the menu bar updates raggedly
([issue #2369](https://github.com/exelban/stats/issues/2369)). One master tick
that fans out to subscribed modules (each with a divisor: every tick, every 2nd
tick, ...) gives one wakeup instead of N and a visually coherent update.

## Theme 2 — Energy discipline (the monitor must not become the load)

**Timer tolerance is non-negotiable.** Apple's guide: set tolerance to at least
10% of the interval on every repeating timer so the system can coalesce wakeups
across apps; timers never fire early, only up to `fireDate + tolerance`
([Minimize Timer Usage](https://developer.apple.com/library/archive/documentation/Performance/Conceptual/power_efficiency_guidelines_osx/Timers.html)).
MenuMeters goes further than the minimum in shipping code:
`[updateTimer setTolerance:.2*interval]` — 20%
([MenuMetersMenuExtraBase.m](https://github.com/yujitach/MenuMeters/blob/main/MenuMetersMenuExtraBase.m)).
For a menu-bar glyph, even 25–50% tolerance is imperceptible.

**Budget: >1 idle wakeup/second is the red line.** Apple's stated threshold for
"investigate your app" is more than one wakeup per second while idle; Activity
Monitor's "Idle Wake Ups" column and `sudo timerfires -p <pid> -s` are the
measurement tools ([Timers guide](https://developer.apple.com/library/archive/documentation/Performance/Conceptual/power_efficiency_guidelines_osx/Timers.html)).
A monitor whose idle tier ticks at 2–5s with tolerance sits well under this.

**Know which readers are expensive and gate them.** exelban/stats README states
that Sensors and Bluetooth are the most inefficient modules and disabling them
"could reduce CPU usage and power efficiency by up to 50% in some cases"
([stats](https://github.com/exelban/stats)). SMC key enumeration and Bluetooth
battery queries do not belong in an idle tier. There is also a reported
pathology where *fewer* enabled modules increased CPU
([issue #2351](https://github.com/exelban/stats/issues/2351)) — reader lifecycle
bugs (orphaned timers, readers running while their widget is hidden) are a real
class of regression to test for.

**Self-cost is a feature users compare on.** iStat Menus 7's headline claim:
"as little as 1/5th the CPU usage of iStat Menus 6 with the same items"
([version history](https://bjango.com/mac/istatmenus/versionhistory/)); forum
threads comparing Stats vs iStat Menus on battery drain are common
([MacRumors](https://forums.macrumors.com/threads/istats-menu-vs-stats-which-is-better-battery-consumption.2354863/)).
Track our own `proc_pidinfo` numbers and show them (htop shows itself; honesty
builds trust).

**NSBackgroundActivityScheduler is for housekeeping, not sampling.** Apple
positions it for deferrable ≥10-minute work; default tolerance is half the
interval, and `shouldDefer` lets the system push work off battery
([Schedule Background Activity](https://developer.apple.com/library/archive/documentation/Performance/Conceptual/power_efficiency_guidelines_osx/SchedulingBackgroundActivity.html)).
Right tool for: history compaction/persistence, update checks, log rotation —
not for the per-second tick (a tolerant GCD timer is correct there).

**Don't rely on App Nap — suspend yourself.** Apple is explicit: App Nap
heuristics (background, no visible content updates, no audio, no assertions)
mainly reduce your impact on other apps; an app that updates a visible menu-bar
item never naps. Listen for visibility/active-state changes and suspend
energy-intensive work proactively
([Extend App Nap](https://developer.apple.com/library/archive/documentation/Performance/Conceptual/power_efficiency_guidelines_osx/AppNap.html)).

## Theme 3 — Data sources on Apple Silicon

**IOReport is the sudoless path to power/frequency.** macmon and socpowerbud
both read the same counters powermetrics reads, via the private-but-unprivileged
IOReport API: CPU/GPU/ANE package power, per-cluster performance-state residency
(from which average frequency and "effective usage" are derived), without sudo,
kexts, or helpers ([macmon](https://github.com/vladkens/macmon),
[socpowerbud](https://github.com/dehydratedpotato/socpowerbud)). The
counterexample is asitop, which shells out to `sudo powermetrics` and parses its
plist stream — workable for a dev TUI, unacceptable for a login-item menu-bar
app ([asitop](https://github.com/tlkh/asitop)). Caveats: IOReport is private
(App Store risk; channel names can shift across macOS releases), and per-chip
maxima (TDP, max bandwidth) have no public API — asitop hardcodes them per chip.

**Report both residency and frequency-scaled usage.** macmon distinguishes
"active residency" (fraction of time not idle) from "effective usage"
(frequency-scaled, weighted by core count). htop-style %CPU is residency;
powermetrics-style utilization is frequency-scaled. Pick one for the glyph
(residency matches user intuition) but keep both available in the panel.

**SMC for temperature, with humility.** exelban/stats reads sensors via SMC and
documents that "with each new SoC, Apple changes the sensor keys" — its sensor
list needs per-generation updates, and CPU/GPU "temperature" is really a set of
thermal-zone sensors, not per-core ([stats](https://github.com/exelban/stats)).
eul's App Store build had to remove all SMC calls entirely
([eul](https://github.com/gao-sun/eul)) — SMC access and sandboxing don't mix.
Treat temperature as best-effort, panel-tier only.

**Per-process attribution: `proc_pidinfo`, and accept the limits.** The
supported recipe ([Apple forums thread 655349](https://developer.apple.com/forums/thread/655349)):
enumerate pids, `proc_pidinfo(pid, PROC_PIDTASKINFO, ...)` for cumulative
user+system ticks, diff against the previous sample, normalize by
`host_processor_info` total-tick delta. `proc_pid_rusage` offers no advantage
and fails in sandbox; kernel_task and other users' processes are invisible
without root; Activity Monitor itself uses private `libsysmon`/`sysmond` XPC we
cannot. Cost is O(process count) per sample — which is exactly why stats gives
top-processes its own slower interval. Show an "unaccounted" row instead of
pretending the visible list sums to 100%.

**Cheap tier primitives are all public Mach/sysctl.** `host_processor_info` /
`host_statistics64` (CPU ticks, vm_stat), `sysctl` (hw.memsize, vm.swapusage),
`getifaddrs` (network byte counters), `statfs` (disk). These are microsecond-cheap
and sandbox-safe — the idle tier should touch only these.

## Theme 4 — UX patterns

**Menu-bar glyph conventions.** MenuMeters renders by setting
`statusItem.button.image` each tick and registers its timer in
`NSRunLoopCommonModes` so the glyph keeps updating while a menu is open
([MenuMetersMenuExtraBase.m](https://github.com/yujitach/MenuMeters/blob/main/MenuMetersMenuExtraBase.m))
— default-mode timers silently freeze during menu tracking, a classic AppKit trap.
It also detects being hidden by the system (menu-bar overflow on notched Macs)
by checking whether its status window appears in
`CGWindowListCreate(kCGWindowListOptionOnScreenOnly, ...)` — when hidden, there
is no reason to render (and arguably none to sample).

**Tiered detail: glyph → panel → settings.** stats and iStat Menus both follow
the same ladder: tiny always-on widget, click for a rich popover (charts, top
processes, per-core detail), settings for which modules exist and how fast they
tick. iStat Menus 7 adds stacked label/value menu-bar modes and per-item
customization ([bjango](https://bjango.com/mac/istatmenus/)).

**Top-processes interaction.** stats shows a configurable-length top-process
list per module (CPU/RAM/network) in the popover, updated on its own interval.
htop's enduring UX lesson: the process list is an *action surface* (kill,
renice, search, sort) — but every action needs the attribution caveat above
(you can only signal your own processes without privileges).

**Smoothing as presentation, not data.** asitop's `--avg` rolling-average window
smooths the displayed power numbers while charts show peaks
([asitop](https://github.com/tlkh/asitop)). Keep raw samples in history; apply
EMA/rolling-average only at render time so the sparkline stays honest.

**Graphs want a fixed-size ring, drawn cheaply.** btop keeps a fixed history
window per metric sized to the visible graph and ties graph quality to the
sampling window (its ≥2000ms guidance). For AppKit: a ring buffer of the last
N samples per metric, rendered as a single bezier path per sparkline; no
per-sample layers.

## Theme 5 — History and persistence

- **In-memory ring buffers, not databases, for live sparklines.** Every TUI
  monitor (btop, macmon, asitop) keeps history purely in memory, sized to the
  widget. The idle tier should append to small fixed rings (e.g. 60–120 entries)
  regardless of whether the panel is open — that's what makes the panel show an
  instant backstory on open instead of an empty chart.
- **Two-resolution history if longer ranges are wanted.** iStat Menus sells
  long history windows; the standard cheap approach is a fine ring (panel-tier
  resolution, minutes) plus a coarse ring (idle-tier resolution, hours) fed by
  decimation, with optional persistence done lazily via
  NSBackgroundActivityScheduler — never on the hot tick.
- **Normalize by measured elapsed time on every append** (the stats #2777
  lesson) so rings survive interval changes, sleep/wake gaps, and tier switches
  without spikes. On wake from sleep, drop the first delta (counters jumped).

---

## Transferable recommendations for our v2

1. **One master GCD timer per tier, fan-out to modules.** Idle tier ~2–5s,
   panel tier ~1s; modules subscribe with divisors. Avoids N independent timers
   (stats issue #2369 raggedness) and keeps wakeups ≤1/s idle (Apple's red line).
2. **Set `tolerance` on every timer: ≥10% per Apple, 20% per MenuMeters
   precedent; use 25–50% on the idle tier** — glyph jitter of a second is
   invisible, the coalescing win is real.
3. **Make panel-tier sampling pull-based with a staleness cache**
   (macmon's `get_metrics_now(stale_after_ms)` shape): on panel open, reuse the
   last idle-tier sample if fresh, then accelerate. Never run both tiers'
   readers for the same metric concurrently.
4. **Normalize every delta by measured wall-clock elapsed, not nominal
   interval**, and discard the first post-sleep sample — directly prevents the
   stats #2777 doubled-power bug class.
5. **Restrict the idle tier to public, microsecond-cheap calls** —
   `host_processor_info`, `host_statistics64`, `sysctl`, `getifaddrs`, `statfs`.
   IOReport power, SMC temperature, and process enumeration are panel-tier only.
6. **Adopt IOReport (macmon/socpowerbud style) for Apple Silicon power/frequency
   instead of powermetrics**: no sudo, no subprocess; isolate it behind a
   protocol so channel-name drift across macOS releases breaks one adapter, not
   the app. Accept it bars the App Store (eul's SMC removal shows that tradeoff).
7. **Per-process CPU via `proc_pidinfo(PROC_PIDTASKINFO)` tick deltas against
   `host_processor_info` totals**, on its own slow interval (stats pattern:
   separate "top processes" interval), with an explicit "unaccounted/other" row
   for what we can't see without root.
8. **Suspend, don't trust App Nap**: pause panel tier on popover close, pause
   rendering (and consider pausing sampling) when the glyph is hidden by
   menu-bar overflow (MenuMeters' `CGWindowListCreate` on-screen check), and
   drop the idle tier rate further on `NSWorkspace` screensleep/lock
   notifications.
9. **Run glyph-update timers in `NSRunLoopCommonModes`** (or a GCD timer
   updating via main-queue hops) so the menu bar doesn't freeze during menu
   tracking — MenuMeters' battle-tested detail.
10. **Keep fixed-size in-memory rings per metric, always fed by the idle tier**,
    so the panel opens with history already present; smooth at render time
    (asitop `--avg` pattern), never at storage time.
11. **Use NSBackgroundActivityScheduler only for housekeeping** (history
    persistence, update checks) with `repeats=true` and generous tolerance;
    honor `shouldDefer` on battery.
12. **Measure ourselves and surface it**: track our own process CPU and idle
    wakeups (`timerfires`, Activity Monitor "Idle Wake Ups") in a debug panel;
    budget = under iStat Menus' "Slow" tier (~1.4% CPU) at idle, and treat any
    regression where the monitor enters its own top-5 list as a release blocker.

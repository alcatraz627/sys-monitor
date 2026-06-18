# Performance audit — sys-monitor (2026-06-18)

Measurement-first audit of the app's own footprint (the tool's whole pitch is
being a cheap monitor). Numbers are from the live release instance on this
machine (18-core, 650 processes running); code evidence is cited file:line.

## Verdict

**Genuinely lean — it delivers on the "lightweight" promise.** Idle CPU is
effectively zero, there is no memory leak (RSS *shrinks* when idle), the
expensive work is correctly confined to the open tier, and the costly caches are
bounded and pruned. The findings below are low-priority refinements, not problems
— the app already meets its budget.

## Measured footprint

| State | CPU | Memory |
|-------|-----|--------|
| Idle (panel closed) | 0.0–0.2% | ~118 MB RSS / ~59 MB "real" (private) |
| Open (panel up, 650 procs) | ~0.7% (self-cost readout) | ~146 MB RSS peak |
| Leak check | — | RSS 141 → 118 MB over 18 s idle (**drops**, no leak) |

- Idle tier samples only the glyph every 2 s; CPU is in the noise.
- The open-tier peak (~146 MB) is transient — panel views + the process list +
  per-row icons — and is released back when the panel closes (the 23 MB drop).
- `top` "real memory" (~59 MB private) is the honest incremental cost; RSS
  (~118–146 MB) mostly counts shared AppKit/SwiftUI framework pages.

## What's already done right (don't regress these)

- **Tiered sampling** — idle tier is glyph-only; process enumeration and power
  are never run while the panel is closed (`SamplingCoordinator` idle vs open).
- **Render-skip cache** — the glyph rebuilds its `NSImage` only when the drawn
  output actually changes (`renderKey` vs `lastRenderKey`, StatusItemController).
- **Bounded, pruned caches** — per-pid path/icon/name caches are evicted for
  dead pids every tick (`prunePerPidState`, PanelRootView:508); icons are fetched
  lazily per *visible* row (`.task(id: p.pid)`, :1151), not for all 650.
- **COW snapshots** — `MetricsSnapshot` is a value type; the four `RingBuffer`
  arrays are copy-on-write, so publishing a snapshot each tick copies no arrays.
- **Energy hygiene** — idle timer runs with leeway; sampling suspends on display
  sleep; serial-queue isolation keeps all sampling off the main thread.

## Findings (ranked; all low priority)

### 1. [perf · low] ~1,250 avoidable per-pid syscalls per tick in the common case

`ProcessSampler.read()` does **three** syscalls for *every* one of ~650 pids each
process-tick: `proc_pidinfo` (cpu+mem, :51), `proc_name` (:66), and
`proc_pid_rusage` (disk, :79) → ~1,950 syscalls/tick. But in the default case
(sort = CPU, no filter):
- `proc_name` is only *displayed* for the top-N rows (10–25); names for the other
  ~625 are computed and discarded (the UI re-resolves display names per visible
  row anyway via `resolveDisplayName`). Names ARE needed for all only when a
  name filter is active.
- `proc_pid_rusage` (disk) is only needed to *rank* when sorted by disk, or for
  the disk column of the top-N; for the ~625 non-displayed pids under a CPU sort
  it's wasted.

**Fix:** two-pass — always fetch the cheap `proc_pidinfo` (cpu+mem) for all to
rank, then fetch `proc_name` + `proc_pid_rusage` only for the rows that need them
(top-N always; all only when sorting/filtering by that field). Saves ~1,250
syscalls/tick in the common case. The sampler would need the current sort/filter
passed in. **Current cost is acceptable (~0.7% open), so this is "halve the
open-tier work if you want it," not a bug.**

### 2. [perf · low] Open panel re-renders the whole view tree every tick

`MetricsSnapshot.==` compares only `generation` (MetricsSnapshot.swift), which
bumps every tick — so SwiftUI rebuilds the entire panel (gauges + sparklines +
per-core strip + process list) at 1 Hz while open, even when most sections are
unchanged. Fine at the measured ~0.7%, but a finer-grained `Equatable` (or
splitting the snapshot so each section observes only its slice) would let
unchanged sections skip their diff. Low value; only matters if open-tier CPU ever
needs trimming.

### 3. [accuracy · minor] Memory readouts use RSS, not "real memory"

Self-cost and the per-process MEM column use `pti_resident_size` (RSS,
ProcessSampler:90). Activity Monitor's "Memory" column is `phys_footprint`, which
is smaller (excludes shared/clean pages). So sys-monitor's numbers read *higher*
than Activity Monitor for the same process — and the app over-reports its own
~146 MB when its real cost is ~59 MB, which is ironic for the "budget canary."
**`ri_phys_footprint` is already in the `usage` struct the sampler fetches**
(`rusage_info_current`, :76) — switching the memory field to it is one line and
zero extra syscalls, and makes the numbers match Activity Monitor (which the user
will compare against, especially now there's a button to open it).

## Not an issue (checked, clean)

- **Memory leak** — none; RSS shrinks at idle, caches are pruned.
- **Idle CPU** — ~0%; no busy-wait, no sub-second timers, idle tier glyph-only.
- **Thread safety / responsiveness** — sampling is serial-queue isolated; main
  only receives immutable snapshots.
- **Icon cache blowup** — icons are lazy per visible row + pruned, not 650-wide.

## Recommendation

Ship-as-is on performance grounds. If you want polish, **#3 is the cheap win**
(one line, fixes a user-visible inconsistency vs Activity Monitor). #1 is the only
real CPU optimization and it's a moderate refactor for a sub-1% gain — worth it
only if the open-tier budget ever tightens.

## Re-assessment (2026-06-18): is each finding deliberate? would "fixing" break behavior?

Checked each against the code's own intent before touching it. The check flipped
two of the three.

- **#3 — implemented.** Not deliberate; just RSS where footprint was meant. Fixed
  *narrowly*: the self-cost readout now reports `ri_phys_footprint`
  (`currentProcessFootprintBytes`, PanelRootView) = Activity Monitor's "Memory",
  so the budget canary stops over-reporting itself (~59 MB, not ~146 MB).
  **Per-process MEM intentionally stays RSS** — `proc_pid_rusage`/footprint is
  privilege-denied for other users' PIDs, so RSS is the only metric available
  consistently for all processes sudoless. Switching per-process to footprint
  would (a) show 0/inconsistent memory for system processes and (b) make memory
  ranking depend on rusage for all PIDs, foreclosing the #1 optimization.

- **#2 — deliberate and correct; do NOT fix.** MetricsSnapshot.swift:6-8 documents
  it: `==` compares only `generation` *so the diff never walks the 60-point
  history arrays*. The panel is a live monitor — every section changes each tick,
  so there is nothing to skip; a finer-grained `==` would make the equality check
  itself walk the arrays (the cost the design avoids) for zero rendering benefit.
  Leaving as-is.

- **#1 — NOT deliberate; it contradicts a documented intent (now corrected).**
  ProcessSampler's header used to claim *"proc_pid_rusage is NOT used … would
  double the syscall count of the most expensive sampler"* — but the later
  per-process disk-I/O feature added `proc_pid_rusage` for every PID, leaving the
  comment lying. The comment is now fixed to describe reality. The *optimization*
  (defer name + rusage to displayed rows) is real but **must stay conditional**:
  the `>N:disk` filter and disk-sort both need disk bytes for ALL pids to rank
  correctly, and the name filter needs names for all — so a deferral can only skip
  those syscalls when neither a disk sort/filter nor a name filter is active.
  Done carelessly it WOULD break instant, complete re-sort/filter. Left unbuilt
  (moderate refactor, sub-1% open-tier gain); the stale comment that hid the cost
  is the part that's fixed.

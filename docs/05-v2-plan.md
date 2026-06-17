# v2 Plan

The roadmap for sys-monitor v2, synthesized from three independent inputs
produced on 2026-06-12:

- **Architecture audit** — [06-architecture-audit.md](06-architecture-audit.md)
- **Perf/UX review** — [07-perf-ux-findings.md](07-perf-ux-findings.md)
- **External research (11 sources)** — [08-external-research.md](08-external-research.md)

Scope filter applied throughout: every item must make the tool **more
trustworthy, cheaper to run, or more usable**. Display-only changes were
explicitly excluded.

## Context: v1 state

v1 shipped and works. The audit's verdict on the core architecture is
*sound*: serial-queue isolation with immutable snapshot hand-off,
measured-elapsed rate math with wrap-safe deltas, a two-tier cost model
that provably reverts, and bounded memory everywhere checked. Measured
idle cost: 0.0–0.2% CPU, ~53 MB RSS. v2 builds on this skeleton; nothing
here is a rewrite.

A launch-blocking crash (UInt32 tick-wrap trap in `CPUSampler.readOverall`
once host uptime pushed idle ticks past `Int32.max`) was fixed and pushed
as `0de4eae` before this plan was written.

## Guiding budget

Adopted from the research (iStat Menus tiers, Apple energy guides):

- Idle self-CPU stays under **1%**; open-tier under iStat Menus' "Slow"
  tier (~1.4%).
- **≤ 1 timer wakeup/sec while idle** (Apple's stated red line).
- Every rate divides by measured wall-clock elapsed (already an invariant;
  the stats issue #2777 doubled-power bug is the cautionary tale).
- The monitor appearing in its own top-5 process list is a release blocker.

---

## Phase 1 — Trust: no metric may lie

The worst monitor bug is a value that looks live but isn't. Three findings
were independently flagged by both the audit and the perf/UX review.

| # | Item | Evidence | Size |
|---|------|----------|------|
| 1.1 | **Wire real memory pressure.** Panel renders severity-colored pressure, but the coordinator hardcodes `.normal` — the promised `DispatchSource.makeMemoryPressureSource` was never built. Latch `.warning`/`.critical` events into the snapshot. | `SamplingCoordinator.swift:324`, `MemorySampler.swift:74` | ~20 lines |
| 1.2 | **Hover must freeze order, not values.** Hovering the process list freezes full `ProcSample`s, so CPU/MEM numbers stop updating in exactly the posture used to watch a runaway. Freeze the pid *order*, map fresh samples each render. | `PanelRootView.swift:175-181, 259-261` | ~15 lines |
| 1.3 | **Fix stale-prev rate inflation.** NET/DISK prevs survive a throwing tick while `prevTickTime` advances; on recovery, N ticks of bytes delta over one tick's elapsed → transient N× spike. Null the prev on read failure (or per-metric prev timestamps). | `SamplingCoordinator.swift:247, 271, 335, 352` | ~15 lines |
| 1.4 | **Order snapshot publication.** Unordered `Task { @MainActor }` hops can theoretically publish generations out of order. Guard with `if snap.generation > current.generation`. | `SamplingCoordinator.swift:422-424` | ~5 lines |

## Phase 2 — Energy: honor the budget in every state

The idle architecture delivers at rest; these close the states where it
doesn't.

| # | Item | Evidence | Size |
|---|------|----------|------|
| 2.1 | **Demote to idle tier on panel occlusion / Space switch.** Dismissal is click-monitor-only; switching Spaces with the panel open leaves the 1 Hz full-PID sweep (p95 4.4% CPU) running until the next click. Observe `windowDidChangeOcclusionState` + `activeSpaceDidChange`. | `PanelController.swift:104-117` | ~15 lines |
| 2.2 | **Split the CPU sampler API.** Idle tick calls full `read()` and discards the per-core result — a kernel array alloc + `vm_deallocate` every 2 s for nothing. Add `readOverall()`-only path for idle. | `CPUSampler.swift:20-25`, `SamplingCoordinator.swift:283-291` | ~15 lines |
| 2.3 | **Proportional timer leeway.** Both tiers use 50 ms leeway; Apple says ≥10%, MenuMeters ships 20%. Use `cadence * 0.1` minimum on idle (200 ms at 2 s), keep open tier tight for visual liveness. | `SamplingCoordinator.swift:208-213` | 2 lines |
| 2.4 | **Pause on screen sleep / lock.** Sampling and glyph rendering continue on a locked-but-awake Mac. Observe `NSWorkspace.screensDidSleep`/`screensDidWake` (and session lock notifications), drop to a deep-idle cadence or suspend, re-baseline on resume. Research: "don't rely on App Nap — suspend yourself." | audit §6 | ~25 lines |
| 2.5 | **Skip identical glyph renders.** New `NSImage` + text measurement per tick even when output is unchanged. Derive a render key (strings + bar/arrow buckets); cache `throughputValueReservedW` at init. | `StatusItemController.swift:44-46`, `GlyphRenderer.swift:135-138` | ~20 lines |
| 2.6 | **Process enumeration on its own divisor.** Per-PID enumeration is the open tier's dominant cost (p95 4.4%); tick it every 2nd open tick (effective 2 s) while gauges stay at 1 s. Research: stats keeps a separate slower top-processes interval; btop recommends ≥2 s windows — the 2 s CPU% delta is also *less noisy*, so this is a cost cut and a quality gain. Pairs with 3.5 so first paint stays fast. | research theme 1; `SamplingCoordinator.swift:260-279` | ~20 lines |
| 2.7 | **Detect the glyph being hidden by menu-bar overflow.** On notched Macs the status item can be silently hidden; we keep sampling and rendering for nothing. MenuMeters' shipping precedent: check the status window against `CGWindowListCreate(kCGWindowListOptionOnScreenOnly)`; when hidden, skip rendering (and consider a deep-idle cadence). Check on a slow divisor, not per tick. | research theme 4 | ~25 lines |
| 2.8 | **Verify glyph updates during menu tracking** (verify-first, may be a no-op). Default-mode timers freeze while any menu is open — MenuMeters runs in `NSRunLoopCommonModes` for this. Our path is a GCD timer + `Task { @MainActor }` hop, which *should* be immune, but nobody has watched the glyph while a menu is open. If frozen: re-route the publish. | research theme 4; `SamplingCoordinator.swift:422-424` | verify, then 0–10 lines |

## Phase 3 — Interaction: the panel becomes an action surface

htop's enduring lesson: a process list you can't act on is half a tool.

| # | Item | Evidence | Size |
|---|------|----------|------|
| 3.1 | **Real kill buttons.** Expanded rows only copy `kill` commands. Add Terminate (SIGTERM) / Force Kill (SIGKILL) with two-step inline confirm; `NSRunningApplication.terminate()` for regular apps; fall back to copy-command on `EPERM` (other-uid/system). Time-to-kill drops ~15 s → ~2 s. | `PanelRootView.swift:660-661` | ~60 lines |
| 3.2 | **Esc dismisses the panel.** The panel takes key focus but `cancelOperation(_:)` is unimplemented — no keyboard dismissal exists at all (also a VoiceOver gap). | `DropPanel.swift` | ~6 lines |
| 3.3 | **Clamp panel to screen edge.** Centered anchoring with no `visibleFrame` clamp; status items live near the right edge, so the panel can render partially off-screen. | `PanelController.swift:92-100` | 3 lines |
| 3.4 | **Right-click menu on the status item.** Standard escape hatch (Settings…, Quit) when the panel is broken or off-screen; every long-lived menu-bar utility has one. | `StatusItemController.swift:39-42` | ~25 lines |
| 3.5 | **Cut open latency.** First data tick lands a full open-cadence after open (~1–2 s of "Measuring…"). (a) Schedule one early tick at ~+300 ms; (b) retain `prevProcCpu` baseline across close→reopen when younger than the gap threshold; (c) on open, publish the freshest idle-tier sample synchronously before the first open tick — CPU/MEM gauges and sparklines paint instantly from data ≤2 s old, only the process list waits for its baseline. (c) is macmon's pull-with-staleness-cache shape (`get_metrics_now(stale_after_ms)`). (d) **Fix the tier-switch gap misclassification** (field bug FB-2): the first tick after a tier switch computes `elapsed` against the *old* tier's last tick but tests it against the *new* tier's gap threshold — switching from a 5 s idle cadence into the 1 s open tier flags `elapsed > 2 s` as a gap ~60% of the time, wiping NET/DISK (and all rates) to `—` for a tick. The transition must carry the outgoing cadence into the first tick's gap test (or stamp `prevTickTime`'s expected cadence alongside it). Ship (a)+(c)+(d) first. | `SamplingCoordinator.swift` tick gap checks; research rec 3 | (a) ~10 / (c) ~15 / (d) ~10 / (b) refactor |
| 3.6 | **Better process names.** `proc_name` truncates at ~32 bytes and search matches the truncated string. Prefer the already-cached executable path basename / `NSRunningApplication.localizedName`. | `ProcessSampler.swift:62-68`, `PanelRootView.swift:343-345, 605-619` | ~15 lines |

## Phase 4 — Capability: history and Apple Silicon power

The feature slots, gated on Phases 1–3 landing first.

| # | Item | Notes | Size |
|---|------|-------|------|
| 4.1 | **NET/DISK history rings + sparklines.** Two more `RingBuffer`s appended in `readNet`/`readDisk`; log-scaled `GraphView`s. Research: rings always fed by the idle tier are what make the panel open with backstory. When NET/DISK aren't bar-enabled, feed their rings on a slow idle divisor (e.g. every 3rd tick) rather than not at all — the net sysctls are cheap; disk's IOKit walk is the costlier one, hence the divisor instead of every-tick. Render any remaining gaps honestly (buffers are time-indexed). | perf F13, research rec 10 | medium |
| 4.2 | **GPU/power via IOReport (the v1 deferral, now de-risked).** macmon and socpowerbud prove sudoless CPU/GPU/ANE power + frequency via private IOReport with dual-sample residency deltas. Isolate behind a protocol so channel-name drift across macOS releases breaks one adapter, not the app. Panel-tier only; glyph stays on residency-style %. Accepts App Store incompatibility (already moot — ad-hoc signed). | research theme 3 | ~half-day spike, then adapter |
| 4.3 | **"Unaccounted/other" row in the process list.** Without root, kernel_task and other-uid processes are invisible; don't pretend the visible list sums to 100%. | research rec 7 | small |
| 4.4 | **Self-cost surface.** Show our own CPU% (we already enumerate ourselves) and idle wakeups in the panel footer or a settings debug row. htop shows itself; iStat Menus markets self-cost as a feature. Doubles as the budget regression canary: the monitor entering its own top-5 is a release blocker, and this makes that visible without Activity Monitor. | research rec 12 | small |

## Phase 4.5 — Pinning + UI sprint (user-requested, post-Phase-4)

| # | Item | Notes | Size |
|---|------|-------|------|
| 4.5.1 | **Pin the panel open.** A pin toggle in the panel header: when pinned, click-outside, Esc, and Space-change dismissal are disabled — only clicking the menu-bar icon (or unpinning) closes it. Interaction spec to settle at implementation, with drills: (a) pinned + occluded (Space switch / fullscreen app) should DEMOTE to idle tier without dismissing — the original README occlusion intent finally lands here — and re-promote when visible again; (b) pinned panel must not block screen-lock suspension (2.4 wins); (c) pin state persists across close/reopen? Recommend: no — pin is a session gesture, not a setting; revisit if usage says otherwise. | new `isPinned` in PanelController gating the three dismissal channels; occlusion handler branches demote-vs-close | ~40 lines + drill |
| 4.5.2 | **UI improvement sprint.** Screenshot-driven pass over the panel + settings with the designer-reviewer flow: visual hierarchy, spacing rhythm, section dividers, expanded-row layout (it now carries 4 buttons + feedback line), settings window structure (growing — see backlog below), dark/light contrast audit, motion (Reduce-Motion honored — overlaps the NFR-9 deferral). Scope rule from this plan still applies: changes ship only with a usability rationale, but this sprint is the sanctioned place for visual-quality work. | run /designer-reviewer per screen; fixes batched | one session |

## Feature backlog (curated 2026-06-12, user-requested brainstorm)

Recommended — high payoff, fits the tool's identity (glanceable +
actionable, cheap always-on):

- **Watch a process**: pin a specific process row to the top of the list
  regardless of rank (the natural companion to hover-freeze and kill —
  "I'm watching THIS one"). Cheap: a pinned-pids set + sort override.
- **Per-process DISK I/O column + sort + `>N:disk` filter** (user
  request 2026-06-12): feasible — `proc_pid_rusage` exposes cumulative
  `ri_diskio_bytesread/written` per pid (already used one-shot in the
  expanded row). Live rates need the sampler to call rusage per pid per
  process-tick and delta against a prev-map, exactly like the cpu-time
  map — roughly +1 syscall per pid per 2 s, acceptable for the open
  tier. Then DISK joins the CPU|MEM sort control and the threshold
  filter. **Per-process NETWORK I/O: feasible via the private
  NetworkStatistics framework** — the earlier "not feasible" verdict
  was inconsistent with this project's own standard (4.2 already
  embraces private IOReport behind an adapter). Probe evidence
  (2026-06-12, `.claude/output/20260612-nstat-probe/`): the framework
  dlopens, `NStatManagerCreate` works, and per-pid TCP/UDP sources
  enumerate **with process names, without root**. Byte-counter
  delivery (the counts-block wiring) is signature-sensitive on this
  macOS and didn't yield in the timeboxed probe — the full spike needs
  the version-conditional headers from existing open-source consumers
  rather than guessed signatures. Slot as the NET twin of 4.2's
  IOReport spike: same risk class, same adapter isolation, same
  degrade-to-unavailable contract. Once counters flow, NET joins the
  sort control and `>N:net` lands in the threshold filter exactly like
  disk did.
  **SHIPPED 2026-06-13** (`PerProcessNetworkMonitor`). Counter delivery
  resolved by the spike: the counts-only `QueryAllSources` does NOT
  refresh per-flow byte totals on macOS 26; the combined
  `QueryAllSourcesUpdate` does (fallback to the former on older OSes).
  Two bugs caught in verification and fixed before shipping: (1) a
  pre-existing flow dumped its entire lifetime total into one tick as a
  phantom multi-Gbps spike — fixed with per-flow baselining (a flow
  contributes only bytes observed while watched; closed flows retire
  them); (2) counts blocks fire with pid=0 before the description
  resolves — fixed by forcing `NStatSourceQueryDescription` in the
  new-source block. Verification limit, stated honestly: the sandbox
  network was throttled to ~200 B/s, so HIGH-rate attribution is
  unconfirmed here — light-traffic attribution is correct and the
  phantom-spike class is gone, but heavy-talker capture needs a real
  network. Platform limitation (same as Activity Monitor / nettop):
  relayed traffic (VPN / iCloud Private Relay / Network Extension)
  attributes to the tunnel process, not the origin app. Open-tier only;
  the NET sort tab hides when the framework doesn't resolve.
- **Battery / power cell**: battery %, charging state, and (Apple
  Silicon) watts via the public `IOPSCopyPowerSourcesInfo` — cheap,
  public API, huge glance value on MacBooks. Bar cell + panel row.
  **SHIPPED 2026-06-17** (`e14a800`): panel energy-row element (glyph +
  %, charge-state tint, time-to-full/empty in hover), verified vs
  `pmset`. A menu-bar *bar cell* for battery is still open if wanted.
- **Threshold alerts**: optional notification when CPU > X% or memory
  pressure ≥ warn for N consecutive ticks (`UNUserNotificationCenter`).
  The monitor already has the data; this makes it useful while hidden.
  Settings-gated, default off.
- **Disk space row**: free/total via `statfs` — one syscall, panel-only.
- **Load average + uptime footer line**: `sysctl vm.loadavg` — trivial,
  htop heritage.

Worth considering, second tier:

- **Glyph tooltip with top consumer** (hover the menu-bar item → "top:
  chrome 84%") — uses existing accessibility string plumbing.
- **Per-interface network breakdown** in the panel (Wi-Fi vs VPN vs USB)
  — the sampler already walks per-interface records and discards the
  split.
- **Global hotkey to toggle the panel** — pairs with Esc; needs the
  Carbon hotkey API or MASShortcut-style code, no third-party deps rule
  applies.
- **Copy stats snapshot** (one keystroke → current readings as text).

Rejected, with reasons (consistent with the research triage):

- SMC temperatures (per-SoC key churn, up to half of stats' self-CPU).
- Public-IP / ping / speedtest widgets (network tools, not system
  monitoring; external traffic from a monitor is a smell).
- Menu-bar graphs/sparklines in the glyph (width cost on the bar
  contradicts the fixed-width grammar the bar v2 design settled).

## Settings backlog (curated 2026-06-12)

Recommended:

- **NET unit preference: bytes/s vs bits/s** — network people think in
  Mbps; one formatter branch.
- **Severity thresholds per metric** (CPU warn/crit, MEM warn/crit) —
  the colors are currently hardcoded at 0.60/0.85 and 0.75/0.92; expose
  them with sane bounds.
- **History window length** (60 s ↔ 300 s) — RingBuffer already takes
  `windowSeconds`.
- **Bar cell order** — `BarCells.ordered` is currently fixed
  CPU>MEM>NET>DISK; expose drag-to-reorder in settings (OptionSet must
  become an ordered array — small persistence migration).
- **Alert thresholds** (with the alerts feature above).
- **Reset to defaults** button.

Second tier: compact glyph mode (icon+bar only, no numbers); per-core
strip on/off; sparklines on/off; "show unaccounted row" toggle (pairs
with 4.3); pin-by-default (only if 4.5.1 usage demands it).

## Phase 5 — Hygiene

- Re-enable the test target (`Package.swift:12-13` commented out — RateMath's
  "trivially testable" design has zero executing tests; the tick-wrap crash
  is exactly the class a boundary-table test catches).
- Fix the 7 docs/comment drift items from audit §8 — chiefly the
  memory-pressure claims in `MemorySampler.swift:9-12` and
  `docs/03-implementation.md` (moot once 1.1 lands), the
  `RingBuffer.swift:14` timestamp comment, and the GlyphRenderer GPU
  "reserved case" comment.
- Delete dead `DesignTokens.nsLoadColor` (zero callers).
- `CoreStrip` 27-core display cap — decide: scroll, wrap, or document.
- If 4.1 ever grows history persistence, do it via
  `NSBackgroundActivityScheduler` (deferrable, generous tolerance, honors
  `shouldDefer` on battery) — never on the hot tick. Not needed until then.

## Research triage — what was adopted, what wasn't

The 12 recommendations in [08-external-research.md](08-external-research.md)
sort into three buckets:

**Adopted into phases above:** timer tolerance (2.3), idle-tier API
whitelist (2.2 completes it), pull-based open entry with staleness cache
(3.5c), separate process-list interval (2.6), menu-bar-overflow detection
(2.7), common-modes glyph verification (2.8), suspend-don't-trust-App-Nap
(2.1, 2.4), always-warm history rings (4.1), IOReport adapter (4.2),
unaccounted row (4.3), self-cost surface (4.4), housekeeping scheduler
(Phase 5, conditional).

**Already held by v1 — no action:** measured-elapsed normalization and
wrap-safe deltas (the stats #2777 doubled-power bug class is prevented by
construction, `RateMath.swift:8-11`); one-timer-per-tier with provable
revert; wake-from-sleep re-baseline.

**Considered and skipped, with reasons:**
- **SMC temperature sensors** — per-SoC sensor-key churn means a
  maintenance treadmill (stats re-maps keys every chip generation), the
  value is a coarse thermal-zone proxy, and stats attributes up to 50% of
  its self-CPU to the sensors module. Wrong cost/benefit for a personal
  tool; revisit only if thermal throttling becomes a real question.
- **Frequency-scaled "effective usage" as the headline metric** —
  residency-style %CPU matches user intuition (and Activity Monitor);
  effective usage arrives for free with 4.2's IOReport data and can sit in
  the panel, but the glyph stays residency-based.
- **App Store packaging constraints** — moot; ad-hoc signed personal tool
  by design, which is exactly what makes 4.2 (private IOReport) available
  to us at all.

## Field bug log

User-reported during v2 testing (2026-06-12). Every entry gets a
reproducing drill *before* its fix, and the drill stays in the suite.

- **FB-1 — Focus on UniversalControl freezes the widget.** Post-v2
  investigation (no plan item covers it). Initial hypothesis:
  `focusButton` calls `NSRunningApplication.activate(options:)`
  synchronously on the main thread (`PanelRootView.swift:752-758`);
  UniversalControl is a faceless system agent that is not activatable,
  and the activation request plausibly blocks in an IPC round-trip —
  freezing the main thread freezes both the panel and the glyph (all
  rendering is main-thread). Likely shape of fix: only offer Focus for
  `activationPolicy == .regular` apps, and treat "no panel action may
  block the main thread" as a hard invariant. Severity: high (freeze),
  scope: panel action surface.
- **FB-2 — Opening/closing the dropdown blanks some NET/DISK values.**
  Root cause identified — tier-switch gap misclassification; folded into
  3.5(d) above, so it's fixed *within* v2 Phase 3, not post-v2. The
  partial pattern ("some values, most times") matches: it depends on how
  long before the switch the last idle tick fired.
- **FB-3 — Hovering the process list pins it empty.** FIXED same day
  (pending user retest). The panel opens under the cursor, so hover
  begins while processes are still `.measuring` — the 1.2 hover fix
  froze that *empty* pid order and rendered it for the whole hover; the
  2.6 divisor widened the measuring window and the exposure. Fix: never
  freeze an empty order (capture-side nil + display-side guard,
  `PanelRootView.swift`). Process note: this was exactly the checklist
  row left unchecked as "pending human check" — the human check worked,
  but the *empty-capture* edge was missing from both the checklist edges
  and the code review's hover analysis. Lesson absorbed into the
  checklist style: edge lists must include "input is empty / in its
  initial state at capture time", not just "input shrinks later".
- **FB-4 — Settings changes (cadence, bar cells) blank NET/DISK.**
  Same family as FB-2; folded into 3.5(d), whose scope is now ALL
  transition ticks (tier switch, cadence change, sampler reconfigure):
  lowering the cadence re-schedules the timer and the first tick tests
  elapsed accumulated under the OLD cadence against the NEW cadence's
  gap threshold → misclassified gap → rates blank one tick (5 s of `—`
  at the slowest cadence). MEM never blanks because it's instantaneous
  (no delta) — the asymmetry the report correctly flagged as a smell.
  Secondary contributor: ADDING a bar cell legitimately re-baselines
  that one metric (by design), but the blank shouldn't leak to metrics
  whose configuration didn't change — the 3.5(d) drill must cover both.

## Verification protocol

Each phase lands only after its checklist below passes, in this order:

- **V1 Concept review** — before coding, re-read the item's rationale
  against current evidence (the cited lines, the audit reports). If the
  design no longer holds, amend the plan first.
- **V2 Concept vs implementation** — after coding, walk every claim the
  change makes (comments, docs, plan rows) and point at the file:line
  implementing it. A promised symbol with no caller fails this gate.
- **V3 Runtime & edge drill** — run the app and watch logs/behavior.
  Induce the driving states; where real conditions are hard to trigger,
  mock the data feed (debug env hooks or a temporary injected fault are
  fine — remove before commit unless promoted to a `--sim-*` flag).
- **V4 Code review** — fresh-lens skeptical review of the full phase
  diff, confidence floor 80.

A checklist row counts only when *executed in-session* — passive "looks
right" inspection is what shipped the Phase 1 bugs (atone
`declared-ready-without-runtime-exercise`, 5×).

### Harness upgrades (from Phases 1–2 experience)

What produced the catches so far: induced states, mocked feeds,
temporary instruments, and skeptical application of review findings.
What limited them: every drill was ad-hoc (rebuilt by hand), temp
instruments cost a build cycle each, and anything needing the panel
open was blocked on a human mouse. Upgrades, in priority order:

1. **Headless panel test hook.** A debug-only signal handler (e.g.
   SIGUSR1 → `panelController.toggle()`, SIGUSR2 → close), compiled in
   `#if DEBUG` or gated on an env var. This single hook converts every
   "needs a mouse" row — 2.1 Space-switch demote, 2.6 divisor timing,
   3.5 open-latency stopwatch, FB-2's reproduction — into a headless
   drill. Highest leverage item on this list.
2. **Drills become committed scripts.** Promote the ad-hoc drills from
   Phases 1–2 (pressure induction, fault injection, display-sleep
   cycle, occlusion soak) into `tools/drills/*.sh`, each exiting
   non-zero on failure. Every phase's verification re-runs ALL prior
   drills — behavioral regression suite, not just a one-time gate.
3. **Standing debug observability.** A `SYSMON_DEBUG=1` env check that
   enables the per-tick debug logs permanently (tick timing, rates,
   render decisions) instead of temp-patch → build → drill → revert →
   build. Field bug reports become diagnosable with
   `SYSMON_DEBUG=1 + log stream` instead of an instrumented rebuild.
4. **Bug-report → drill discipline.** Every field bug (FB-n) gets a
   reproducing drill BEFORE the fix is written, and the drill joins the
   suite. The fix is proven by the drill flipping, not by re-reading
   the diff.
5. **A/B on fixes when cheap.** Demonstrate the bug on the pre-fix
   binary first (1.3's drill proved the fix's signature but never
   showed the inflation live — structural evidence carried it, A/B
   would have been stronger).
6. **Soak-with-assertions before every commit.** One script: N-minute
   soak that greps for invariant violations (out-of-order drops, crash
   reports, RSS growth beyond threshold, unexpected transitions) and
   samples self-CPU. Run as the last gate of every phase.
7. **Pull Phase 5's unit tests forward.** RateMath/formatBps/gap-logic
   boundary tables catch the arithmetic class (tick wrap, gap
   misclassification like FB-2) at build time — cheaper than any drill.

### Phase 1 checklist (trust) — executed 2026-06-12

- [x] **1.1** VERIFIED. Induced real pressure (`memory_pressure -l warn`,
  unprivileged; `-S` needs root): app logged `-> warn` at t=22s — the same
  second the kernel sysctl hit level 2 — and `-> normal` 4s after release.
  Panel was *closed* throughout (idle tick polls too). Launch-under-
  pressure is covered by construction (first tick polls).
  **Design changed by this drill:** `DispatchSource.makeMemoryPressureSource`
  never fired while the kernel sat at warn — macOS delivers warn events
  selectively (largest consumers first), so a small menu-bar app may never
  be notified. Shipped a per-tick sysctl poll of
  `kern.memorystatus_vm_pressure_level` instead. Honest gaps: `critical`
  branch not induced (same switch statement, code-reviewed only); panel
  row *recoloring* not visually confirmed (same snapshot→view binding as
  every other metric).
- [ ] **1.2** Implemented + reviewer-verified semantics (order-only freeze,
  dead pids drop via compactMap, `.measuring` snapshot returns empty not
  stale). NOT runtime-exercised: a real hover needs a human mouse (or
  focus-stealing automation). **10-second human check pending: open panel,
  park cursor over the list, confirm CPU% values keep ticking.**
- [x] **1.3** VERIFIED structurally via injected fault (temporary throw in
  NetworkSampler keyed on a marker file, removed after the drill): 5
  outage ticks went silent (`.unavailable`), the first recovery tick is
  absent from the rate log (re-baseline returning `.measuring` — in the
  buggy version this tick computes ~5× inflation), the second logs a
  clean-window ambient rate. Drill ran on ambient traffic only (the
  intended 2 MB/s load failed silently); the structural signature is the
  proof. Tier-switch-spanning failure not drilled (panel stayed closed).
- [x] **1.4** VERIFIED by soak: 3 minutes (plan said 5; panel closed, idle
  5 s cadence ≈ 36 publishes), zero drop logs, app alive, no crash
  reports. Review proposed switching the guard to `!=` for wrap-safety —
  rejected: `!=` admits the very out-of-order overwrite the guard exists
  to stop; `>` kept with wrap-acceptance documented.

### Phase 2 checklist (energy) — executed 2026-06-12

- [ ] **2.1** Implemented (occlusion + active-Space observers close the
  panel; decision: *dismiss*, not restore — a panel marooned on another
  Space is worse than re-clicking). Review-verified observer lifecycle.
  NOT runtime-exercised: opening the panel needs a mouse. **Human check:
  open panel, switch Space, confirm it's gone and (via Activity Monitor)
  CPU settles within a second.**
- [x] **2.2** VERIFIED: temporary log on the per-core read, 40 s idle soak
  → zero invocations; the call compiles only into the open path now.
  (Per-core strip rendering when the panel opens — human glance.)
- [x] **2.3** VERIFIED: schedule log shows `leeway=500ms` at the 5 s idle
  cadence (10%). Wakeup counting via Activity Monitor not separately
  performed — the arithmetic (≤0.2 wakes/s) is below Apple's 1/s red line
  by construction.
- [x] **2.4** VERIFIED live: `pmset displaysleepnow` → "sampling suspended"
  the same second; display wake → "sampling resumed" + timer rescheduled +
  baselines dropped. (The drill's display re-woke in 0.4 s — both
  directions still exercised.) The lock-while-panel-open edge produced a
  review finding: a click during the dark gap could leave the panel open
  on idle tier; fixed with `desiredTier` (resume honors the last
  *requested* tier, not the last achieved one).
- [ ] **2.5** Implemented; key encodes every drawn input (review-verified).
  0 skips observed in 45 s under this machine's real config — all four
  cells + activity arrows means ambient NET churn changes the key nearly
  every tick. Honest status: mechanism runtime-unverified, and its win is
  small for a 4-cell-with-arrows bar; it pays off for CPU+MEM-only setups.
- [ ] **2.6** Implemented with a dedicated process-elapsed clock (the naive
  divisor would have doubled every %CPU — same trap class as 1.3).
  Review-verified; **human check: open panel, confirm process rows step
  every ~2 s while gauges step every 1 s.**
- [x] **2.7** REDESIGNED during verification: the MenuMeters CGWindowList
  technique is dead on macOS 26 — `windowNumber` for the status window
  reads 2³², and the window is absent even from the app's own on-screen
  query (drill-proven). Also caught a launch deadlock in the first
  implementation (visibility probe before first paint → zero-width window
  → "hidden" → paint skipped forever). Shipped: AppKit `occlusionState`
  check, fail-open on nil window. Both transitions exercised live at
  launch (occluded at first composite → visible 5 s later → painted).
- [ ] **2.8** Deferred to Phase 3 — meaningfully testable once the
  right-click menu (3.4) exists to hold a tracked menu open.

### Phase 3 checklist (interaction) — executed 2026-06-12

- [ ] **3.1** Implemented: two-step confirm (3 s auto-reset), pid-reuse
  guard (path comparison; honestly documented as unenforceable when the
  path was unreadable at expand time), `NSRunningApplication.terminate()`
  ONLY for `.regular` apps with raw `kill(2)` otherwise — the FB-1
  lesson applied preemptively. EPERM auto-copies the shell command with
  feedback. NOT runtime-exercised (buttons need a mouse). **Human check:
  spawn `sleep 999`, expand its row, Terminate → really? → it dies;
  repeat with Force Kill; try a root process → "no permission" + copy.**
- [ ] **3.2** Implemented: `cancelOperation` → close; decision recorded —
  Esc always closes, even from the search field. **Human check: open,
  press Esc.**
- [ ] **3.3** Implemented: anchor clamps into `visibleFrame` inset 8 pt;
  arithmetic review-verified. **Human glance on the smallest display.**
- [ ] **3.4** Implemented: right-click menu (Settings…, Quit), left-click
  toggle preserved. **Human check — which is ALSO the 2.8 probe: hold
  the right-click menu open ≥3 ticks and watch whether the glyph keeps
  updating.** (Reviewer's analysis: sampling queue unaffected by menu
  tracking; store updates queue and land at dismiss — so expect the
  glyph to freeze during tracking and catch up instantly. If observed,
  2.8's common-modes fix becomes a v2 item; the panel is closed during
  right-click so the cost is cosmetic.)
- [x] **3.5** VERIFIED headlessly (SIGUSR1 hook + SYSMON_DEBUG): across
  two drills and ~8 tier transitions — including user-click-injected
  ones — zero rate metrics flipped ok→measuring on any transition
  (FB-2/FB-4 dead), and process data lands on the early tick, one
  publish after open (~300 ms). (c) was NOT built: with (d) fixed, the
  first open tick computes real rates from surviving prevs and the
  store's retained snapshot already paints instantly — the staleness
  cache would duplicate both. (b) unnecessary for the same reason.
  Post-review hardening: a per-open epoch prevents a stale early tick
  from a close→reopen-within-300 ms firing into the new session.
- [ ] **3.6** Implemented: display + search + accessibility use the
  executable basename when cached (one-tick sharpening lag accepted and
  documented). **Human check: find "Code Helper" by its full name.**

Drill-design note for the suite: SIGUSR1 *toggle* is parity-blind — a
user click between signals inverts open/close intent (observed live).
Drills that depend on panel state need explicit open/close verbs or
must assert on the tick log's `tier=` field, not on signal count.

### Phase 4 checklist (capability) — executed 2026-06-15

- [x] **4.1** VERIFIED (data): under a `curl` download the net ring fills
  every tick and the log-normalized frac tracks rate (3.4 MB/s → 0.93,
  8.7 MB/s burst → 0.99), staying in 0…1. The "slow idle divisor when not
  bar-enabled" sub-item was DEFERRED, not shipped — it needs net/disk to
  carry their own elapsed clock (like `readProcesses`) to avoid stale-prev
  inflation; backstory currently comes from the bar-enabled idle feed or
  fills from open. **Human glance: the sparkline renders under each
  throughput cell.**
- [x] **4.2** VERIFIED (in-app): IOReport resolves and reports available;
  idle reads cpu≈5 W / gpu≈0.07 W (matching the standalone probe) and
  tracks load (cpu 5→8 W under `yes` stress); ANE 0 idle. Cross-check vs
  `powermetrics` skipped (needs sudo) — the standalone probe validated the
  absolute values against the energy-counter math instead. Channel-naming
  drift handled (friendly aggregates only; physical channels excluded to
  avoid double-count). Degrade-to-unavailable is by construction (every
  symbol guarded). **Human glance: the POWER row renders.**
- [x] **4.3** SHIPPED AS PIVOT. The literal "unaccounted ≈ overall − Σ
  visible" was exercised and REJECTED: on a quiet machine the host-wide
  busy (~2 cores) minus summed per-process user+system (~0.03 cores) left
  ~2 cores unattributed (kernel_task + system time), rendering as a
  misleading "kernel + others 200%". Shipped the honest, can't-look-broken
  signal instead — a "top N of M processes" coverage row. **Human glance:
  the dim coverage row shows at the list bottom.**
- [ ] **4.4** Self-cost: VERIFIED app-computed value is correct and
  understood (reads ~0.1–0.4% averaged over its 2 s window; `ps` oscillates
  0.7–6.1% catching the per-tick enumeration bursts — window difference,
  not a bug; the averaged number is internally consistent with the rest of
  the list). **Human glance: `self 0.X% · NN MB` renders between the gear
  and power icons in the footer.**

### Phase 5 checklist (hygiene) — executed 2026-06-15

- [x] Boundary suite runs and passes — via `sys-monitor --self-test`, NOT
  `swift test` (XCTest needs full Xcode, absent under Command Line Tools;
  documented in `Package.swift`). 20 checks incl. the `UInt32` tick-wrap
  (`0de4eae`) and formatBps-width (`fa31022`) crash classes. Verified both
  directions: all pass + exit 0; a deliberately-false probe reports the
  failure + exit 1.
- [x] rg-sweep clean: the 4 living drift items fixed (monoSeconds
  "wall-clock"→monotonic; BarCell "reserved GPU case"→panel POWER row;
  HistoryPoint "mach absolute"→monoSeconds; `docs/03-implementation.md`
  §5.3 DispatchSource→Superseded/sysctl). MemorySampler's comment was
  already corrected in Phase 1. The audit reports (06/07) and this plan
  intentionally record the drift as history — left as-is.
- [x] Dead `DesignTokens.nsLoadColor` deleted (zero callers); build clean,
  no warnings. CoreStrip 27-core cap was already resolved in Phase 2
  (balanced rows, no truncation) — no further action.

## Sequencing

```
Phase 1 (trust)      ──►  Phase 2 (energy)  ──►  Phase 3 (interaction)
  ~55 lines total          ~140 lines total       independent items,
  all small, ship as       2.4/2.7 need light     3.1 needs confirm-UX
  one batch                design; 2.8 verify     design; rest trivial
                                                        │
                                                        ▼
                           Phase 5 (hygiene)      Phase 4 (capability)
                           anytime, low risk      4.2 starts with a spike
```

Phases 1–2 are almost entirely sub-20-line fixes against cited lines — one
focused session. Phase 3 is a second session (3.1 needs interaction design).
Phase 4 is where v2 grows new capability; 4.2's IOReport spike should be
timeboxed before committing to the adapter.

## Acceptance criteria for v2

1. Under real memory pressure (e.g. `memory_pressure -l warn` simulation),
   the panel's pressure row changes color within one tick.
2. With cursor parked over the process list, CPU% values visibly update
   every open-tick.
3. A runaway process can be terminated entirely from the panel in ≤ 3
   clicks, no terminal.
4. Panel open on Space A, switch to Space B: open tier demotes within 1 s
   (verify via logging or self-CPU).
5. Esc closes the panel; panel never renders off-screen on any display
   arrangement.
6. Idle wakeups ≤ 0.5/s at default cadence (Activity Monitor "Idle Wake
   Ups" / `timerfires`).
7. NET/DISK sampler failure followed by recovery never shows a rate spike
   exceeding the true transfer rate.
8. All RateMath boundary tests pass in CI (`swift test`).
9. Glyph keeps updating while a menu is open (watch it during menu
   tracking — the 2.8 verification, kept as a regression check).
10. Panel opens with CPU/MEM gauges populated immediately (no "Measuring"
    flash) when the app has been running ≥ one idle tick.
11. The self-cost row reads under 1% at idle and under ~1.4% with the
    panel open.

Every criterion above is written to be *executed*, not inspected — per
atone `declared-ready-without-runtime-exercise` (5 recurrences, RCA
2026-06-12): a state-driven behavior counts as accepted only when the
state was induced and the change observed in-session.

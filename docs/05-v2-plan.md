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
| 3.5 | **Cut open latency.** First data tick lands a full open-cadence after open (~1–2 s of "Measuring…"). (a) Schedule one early tick at ~+300 ms; (b) retain `prevProcCpu` baseline across close→reopen when younger than the gap threshold; (c) on open, publish the freshest idle-tier sample synchronously before the first open tick — CPU/MEM gauges and sparklines paint instantly from data ≤2 s old, only the process list waits for its baseline. (c) is macmon's pull-with-staleness-cache shape (`get_metrics_now(stale_after_ms)`). Ship (a)+(c) first. | `SamplingCoordinator.swift:174, 210`; research rec 3 | (a) ~10 / (c) ~15 / (b) refactor |
| 3.6 | **Better process names.** `proc_name` truncates at ~32 bytes and search matches the truncated string. Prefer the already-cached executable path basename / `NSRunningApplication.localizedName`. | `ProcessSampler.swift:62-68`, `PanelRootView.swift:343-345, 605-619` | ~15 lines |

## Phase 4 — Capability: history and Apple Silicon power

The feature slots, gated on Phases 1–3 landing first.

| # | Item | Notes | Size |
|---|------|-------|------|
| 4.1 | **NET/DISK history rings + sparklines.** Two more `RingBuffer`s appended in `readNet`/`readDisk`; log-scaled `GraphView`s. Research: rings always fed by the idle tier are what make the panel open with backstory. When NET/DISK aren't bar-enabled, feed their rings on a slow idle divisor (e.g. every 3rd tick) rather than not at all — the net sysctls are cheap; disk's IOKit walk is the costlier one, hence the divisor instead of every-tick. Render any remaining gaps honestly (buffers are time-indexed). | perf F13, research rec 10 | medium |
| 4.2 | **GPU/power via IOReport (the v1 deferral, now de-risked).** macmon and socpowerbud prove sudoless CPU/GPU/ANE power + frequency via private IOReport with dual-sample residency deltas. Isolate behind a protocol so channel-name drift across macOS releases breaks one adapter, not the app. Panel-tier only; glyph stays on residency-style %. Accepts App Store incompatibility (already moot — ad-hoc signed). | research theme 3 | ~half-day spike, then adapter |
| 4.3 | **"Unaccounted/other" row in the process list.** Without root, kernel_task and other-uid processes are invisible; don't pretend the visible list sums to 100%. | research rec 7 | small |
| 4.4 | **Self-cost surface.** Show our own CPU% (we already enumerate ourselves) and idle wakeups in the panel footer or a settings debug row. htop shows itself; iStat Menus markets self-cost as a feature. Doubles as the budget regression canary: the monitor entering its own top-5 is a release blocker, and this makes that visible without Activity Monitor. | research rec 12 | small |

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

### Phase 1 checklist (trust)

- [ ] **1.1** Induce memory pressure (`sudo memory_pressure -S -l warn`,
  then `critical`) → pressure log line fires and the panel row recolors
  within one tick; release → returns to normal.
  Edges: event fires while panel *closed* → next open shows the latched
  level, not stale `.normal`; app launched while pressure is *already
  elevated* — verify what the dispatch source reports before the first
  event and document the behavior honestly.
- [ ] **1.2** Park cursor over the process list for ≥5 open-ticks →
  CPU/MEM values visibly change while row order doesn't.
  Edges: hovered pid exits mid-hover → its row drops without reshuffle or
  crash; typing in search mid-hover unfreezes; frozen order referencing
  more pids than the fresh snapshot has → no index errors.
- [ ] **1.3** With a mocked flaky NET or DISK sampler (throw for N ticks,
  then recover) → during outage the cell shows `—`/measuring; the first
  recovery tick shows measuring or a sane rate — never an N× spike.
  Edge: failure spanning a tier switch (panel open→close mid-outage).
- [ ] **1.4** Generation-regression guard logs (or asserts in debug) when
  an older snapshot would overwrite a newer one → 5-minute soak with panel
  open produces zero regression logs.

### Phase 2 checklist (energy)

- [ ] **2.1** Panel open → switch Space (keyboard shortcut, not click) →
  demote log within 1 s; `ps -o %cpu` settles back to idle level.
  Edge: return to the original Space — panel state (dismissed vs restored)
  matches what the plan row decided.
- [ ] **2.2** Idle tier emits no `host_processor_info` (debug-log the
  per-core read; idle soak shows zero such lines); per-core data still
  appears when the panel opens.
- [ ] **2.3** Log leeway at timer build: idle ≥10% of cadence. Activity
  Monitor "Idle Wake Ups" for our pid ≤ cadence rate over a 5-min soak.
- [ ] **2.4** Lock screen or `pmset displaysleepnow` → pause/deep-idle log;
  wake → re-baseline log and no spike values on the first tick.
  Edge: panel open at lock time → open tier doesn't survive the lock.
- [ ] **2.5** Idle soak → render-skip counter increments (identical frames
  skipped); generate load → rendering resumes immediately.
- [ ] **2.6** Panel open: gauges update every open-tick, process rows every
  2nd tick (watch row timestamps or log), first paint unaffected.
- [ ] **2.7** Mock the on-screen check to "hidden" → render skipped (log) /
  deep-idle; restore → resumes. (Real overflow induction optional.)
- [ ] **2.8** Hold a menu open ≥3 ticks (any app menu, or 3.4's right-click
  menu) → glyph keeps updating. If it freezes, fix lands in this phase.

### Phase 3 checklist (interaction)

- [ ] **3.1** Spawn a disposable `sleep 999`; Terminate from the panel →
  process exits via SIGTERM; spawn again, Force Kill → SIGKILL.
  Edges: kill a root-owned pid → `EPERM` falls back to copy-command with
  explanation; confirm-step resets after timeout/cursor-leave; pid gone
  between click and confirm → no signal sent to a reused pid (re-verify
  identity before `kill`).
- [ ] **3.2** Esc closes the panel when it has key focus.
  Edge: Esc with the search field focused — decide (clear-then-close vs
  close) and verify the decided behavior.
- [ ] **3.3** Status item within ~180 pt of the right screen edge (drag it,
  or smallest display) → panel fully on-screen. Edge: multi-display
  boundary placement.
- [ ] **3.4** Right-click → menu (Settings…, Quit) works; left-click still
  toggles the panel; menu dismisses cleanly.
- [ ] **3.5** Stopwatch (log timestamps): click → gauges populated from
  cached idle sample in <100 ms; process list populated ≈300 ms.
  Edges: first-ever open with no cached sample → clean measuring state;
  reopen after a gap longer than threshold → baseline NOT reused.
- [ ] **3.6** A long-named helper (e.g. "Code Helper (Renderer)") shows its
  full name and is findable via search by that name. Edge: process whose
  path lookup fails keeps the `proc_name` fallback.

### Phase 4 checklist (capability)

- [ ] **4.1** `curl` a large file + `dd` a temp file → NET/DISK sparklines
  show the spike with correct timing; disable the cells → rings still fill
  on the slow divisor; gaps (if any) render as gaps, not interpolation.
- [ ] **4.2** IOReport readings cross-checked against a one-shot
  `sudo powermetrics` sample within reasonable tolerance; mock unknown
  channel names → adapter degrades to `unavailable`, app keeps running.
- [ ] **4.3** Under load: visible rows + unaccounted ≈ overall CPU within a
  few percent.
- [ ] **4.4** Self-cost row matches `ps -o %cpu` for our pid (±0.5%); idle
  reads <1%, open-tier <1.4%.

### Phase 5 checklist (hygiene)

- [ ] `swift test` executes the RateMath boundary table locally — including
  a `UInt32` tick-wrap case that reproduces the `0de4eae` crash class.
- [ ] rg-sweep: zero comments/docs promising a symbol that doesn't exist
  (re-check all seven §8 drift items from the audit).
- [ ] Dead-code removal compiles clean; CoreStrip cap decision recorded in
  docs.

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

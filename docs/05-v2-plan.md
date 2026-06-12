# v2 Plan

The roadmap for sys-monitor v2, synthesized from three independent inputs
produced on 2026-06-12:

- **Architecture audit** — `.claude/output/20260612-1515-v2-audit/architecture-blueprint.md`
- **Perf/UX review** — `.claude/output/20260612-1515-v2-audit/perf-ux-findings.md`
- **External research (11 sources)** — `.claude/output/20260612-1515-v2-audit/external-research.md`

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

## Phase 3 — Interaction: the panel becomes an action surface

htop's enduring lesson: a process list you can't act on is half a tool.

| # | Item | Evidence | Size |
|---|------|----------|------|
| 3.1 | **Real kill buttons.** Expanded rows only copy `kill` commands. Add Terminate (SIGTERM) / Force Kill (SIGKILL) with two-step inline confirm; `NSRunningApplication.terminate()` for regular apps; fall back to copy-command on `EPERM` (other-uid/system). Time-to-kill drops ~15 s → ~2 s. | `PanelRootView.swift:660-661` | ~60 lines |
| 3.2 | **Esc dismisses the panel.** The panel takes key focus but `cancelOperation(_:)` is unimplemented — no keyboard dismissal exists at all (also a VoiceOver gap). | `DropPanel.swift` | ~6 lines |
| 3.3 | **Clamp panel to screen edge.** Centered anchoring with no `visibleFrame` clamp; status items live near the right edge, so the panel can render partially off-screen. | `PanelController.swift:92-100` | 3 lines |
| 3.4 | **Right-click menu on the status item.** Standard escape hatch (Settings…, Quit) when the panel is broken or off-screen; every long-lived menu-bar utility has one. | `StatusItemController.swift:39-42` | ~25 lines |
| 3.5 | **Cut open latency.** First data tick lands a full open-cadence after open (~1–2 s of "Measuring…"). (a) Schedule one early tick at ~+300 ms; (b) retain `prevProcCpu` baseline across close→reopen when younger than the gap threshold. Ship (a) first. | `SamplingCoordinator.swift:174, 210` | (a) ~10 / (b) refactor |
| 3.6 | **Better process names.** `proc_name` truncates at ~32 bytes and search matches the truncated string. Prefer the already-cached executable path basename / `NSRunningApplication.localizedName`. | `ProcessSampler.swift:62-68`, `PanelRootView.swift:343-345, 605-619` | ~15 lines |

## Phase 4 — Capability: history and Apple Silicon power

The feature slots, gated on Phases 1–3 landing first.

| # | Item | Notes | Size |
|---|------|-------|------|
| 4.1 | **NET/DISK history rings + sparklines.** Two more `RingBuffer`s appended in `readNet`/`readDisk`; log-scaled `GraphView`s. Idle tier feeds rings only when those cells are bar-enabled — render gaps honestly (buffers are time-indexed). Research: rings always fed by the idle tier are what make the panel open with backstory. | perf F13, research rec 10 | medium |
| 4.2 | **GPU/power via IOReport (the v1 deferral, now de-risked).** macmon and socpowerbud prove sudoless CPU/GPU/ANE power + frequency via private IOReport with dual-sample residency deltas. Isolate behind a protocol so channel-name drift across macOS releases breaks one adapter, not the app. Panel-tier only; glyph stays on residency-style %. Accepts App Store incompatibility (already moot — ad-hoc signed). | research theme 3 | ~half-day spike, then adapter |
| 4.3 | **"Unaccounted/other" row in the process list.** Without root, kernel_task and other-uid processes are invisible; don't pretend the visible list sums to 100%. | research rec 7 | small |

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

## Sequencing

```
Phase 1 (trust)      ──►  Phase 2 (energy)  ──►  Phase 3 (interaction)
  ~55 lines total          ~75 lines total        independent items,
  all small, ship as       2.4 needs light        3.1 needs confirm-UX
  one batch                design                 design; rest trivial
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

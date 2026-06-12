# sys-monitor v2 audit — performance & UX findings

<!-- sessions: v2-audit@2026-06-12 -->

Fresh-lens review of the running app + full `Sources/` read. Scope filter
applied per request: **only changes that make the tool more usable, cheaper
to run, or more trustworthy.** Display-only items are explicitly marked OUT
OF SCOPE.

## Measurements (live process, pid 85874, panel closed)

| Metric | Observed | Method |
| --- | --- | --- |
| Idle CPU | 0.0–0.2% (6 samples over 12 s) | `ps -o %cpu -p` |
| RSS | ~53 MB (stable across samples) | `ps -o rss` |
| Threads | 19 | `top -l 3 -pid` |
| Mach ports | 214 | `top -l 3 -pid` |
| Footprint (top "MEM") | 16 MB | `top -l 3 -pid` |

The idle-tier budget claim (< 1% CPU) holds in practice. RSS is below the
README's 63 MB figure. No leak signal over the observation window.
`powermetrics` (wakeup counts) requires sudo — skipped per instructions.
Open-tier cost not re-measured live (would require focus-stealing the
panel); docs/04-acceptance.md records p95 = 4.4% while open, attributable
to per-PID `proc_pidinfo` enumeration.

---

## Findings, ranked by payoff-per-effort

### F1 — Memory "pressure" is a fake metric: it always reads "normal" — HIGH

- **Severity:** high (trust — the worst kind of monitor bug: a value that
  looks live but is hardcoded)
- **Evidence:** `MemorySampler.swift:74` declares
  `func toSample(pressure: MemoryPressure = .normal)`, and the only caller,
  `SamplingCoordinator.swift:324`, calls `raw.toSample()` with no argument.
  `rg -n "makeMemoryPressureSource" Sources/` → zero hits. The
  `MemorySampler.swift:9-12` comment says "the SamplingCoordinator owns a
  `DispatchSource.makeMemoryPressureSource` … and latches the level into the
  snapshot" — that source was never built. The panel renders the value with
  color severity (`PanelRootView.swift:105-126`) as if it were real.
- **User-visible payoff:** the one signal that distinguishes "memory is
  full but fine" from "the machine is about to start swapping/jetsamming"
  becomes real. Under genuine pressure, today the panel says "normal" in
  calm gray — actively misleading.
- **Fix:** create `DispatchSource.makeMemoryPressureSource(eventMask:
  [.warning, .critical], queue:)` in the coordinator, latch the level into
  a queue-isolated var, pass it to `toSample(pressure:)`. ~20 lines.
- **Cost:** low. Alternatively remove the row until wired — showing nothing
  beats showing a lie.

### F2 — Hover freezes the process list's VALUES, not just its order — HIGH

- **Severity:** high (trust)
- **Evidence:** `PanelRootView.swift:175-181` stores
  `hoverFrozenOrder = rankedProcesses` — an array of full `ProcSample`
  structs (cpu, memBytes included) — and `displayedProcesses`
  (`PanelRootView.swift:259-261`) returns it verbatim while hovering. The
  doc comment at `PanelRootView.swift:10-13` and the README ("pauses
  re-sorting … the displayed value is still the raw current %") describe
  order-only freezing; the implementation freezes everything.
- **User-visible payoff:** the natural posture when watching for a runaway
  process is cursor parked over the list. Today that means **all CPU/MEM
  numbers stop updating indefinitely** while you watch. A spike that starts
  during hover is invisible until the pointer leaves.
- **Fix:** freeze the *pid order* (`[Int32]`), then map each pid to the
  fresh sample from the current snapshot each render (drop pids that died,
  keep order otherwise). ~15 lines.
- **Cost:** low.

### F3 — You cannot actually kill a process from the panel — HIGH

- **Severity:** high (missing core affordance)
- **Evidence:** `PanelRootView.swift:660-661` — the expanded row offers
  `Copy kill -TERM` / `Copy kill -9` which only write a string to the
  pasteboard. The primary use case of a glanceable monitor — *spot a
  runaway, stop it* — requires opening a terminal and pasting.
- **User-visible payoff:** time-to-kill drops from ~15 s (open terminal,
  paste, enter) to ~2 s. This is the single change that most affects
  "materially better when actually using the tool."
- **Fix:** add `Terminate` (SIGTERM) and `Force Kill` (SIGKILL) buttons.
  `kill(pid, SIGTERM)` works for same-uid processes with no entitlements
  (app is unsandboxed by design — README "no sandbox (deliberate trade)").
  Use `NSRunningApplication.terminate()` for regular apps. Guard with a
  two-step confirm (click → button morphs to "really?") rather than a modal
  — a modal on a nonactivating panel is awkward. Handle `EPERM` (other-uid
  / system processes) by falling back to the existing copy-command
  behavior with a brief explanation. Keep the copy buttons for the
  privileged cases.
- **Cost:** medium-low (~60 lines + confirm interaction). Note: the
  existing copy buttons also emit zero feedback on click (no "copied"
  state) — fold a pressed/confirmation state into the same edit. The
  feedback half alone would be borderline cosmetic; bundled with real kill
  it's part of the interaction contract.

### F4 — Open tier keeps burning full process enumeration when the panel is invisible but not dismissed — MEDIUM

- **Severity:** medium (energy/cost; the app violates its own budget story
  in a common scenario)
- **Evidence:** dismissal is driven *only* by the global click monitor
  (`PanelController.swift:104-117`) and the toggle. Nothing observes
  `windowDidChangeOcclusionState`, `NSWorkspace.activeSpaceDidChangeNotification`,
  or `NSApplication.didChangeScreenParametersNotification`
  (`rg -n "occlusion|activeSpaceDid" Sources/` → comment hits only). Switch
  Spaces with the panel open (keyboard, Mission Control, trackpad swipe)
  and the panel stays "visible" on the old Space while the open tier runs
  1 Hz full-PID `proc_pidinfo` sweeps (~300+ pids/tick, the documented
  p95=4.4% load) until the next click anywhere happens to fire the global
  monitor. A keyboard-heavy stretch can leave it burning for minutes. The
  README itself lists occlusion handling as a deferred "few-line follow-up"
  (README.md:252-255).
- **User-visible payoff:** the "< 1% always" promise becomes true in all
  states, not just the click-to-dismiss path. Also fixes the orphaned-panel
  UX (panel marooned on another Space).
- **Fix:** observe `windowDidChangeOcclusionState` on the panel — when
  `!occlusionState.contains(.visible)`, call `close()` (or demote to idle
  tier and keep the panel, which is the README's stated intent). Add
  `activeSpaceDidChange` as a belt-and-braces close.
- **Cost:** low (~15 lines).

### F5 — Panel can render partially off-screen; no edge clamping — MEDIUM

- **Severity:** medium (UX; likely visible today on small/secondary
  displays)
- **Evidence:** `PanelController.swift:92-100` — `x = midX - width/2` with
  no clamp against `screen.visibleFrame`. Status items live near the
  *right* edge of the menu bar; a 360 pt panel centered under an item
  within 180 pt of the screen edge overflows off-screen. On a multi-display
  setup where the item sits near a display boundary the panel can straddle
  or vanish.
- **User-visible payoff:** panel always fully visible, on every display
  arrangement.
- **Fix:** clamp `x` to `button.window.screen.visibleFrame.insetBy(dx: 8)`.
  3 lines.
- **Cost:** trivial.

### F6 — ~1 s "Measuring processes…" on every open; baselines discarded on every close — MEDIUM

- **Severity:** medium (latency to the tool's main payload)
- **Evidence:** rate metrics need two samples. First open tick fires at
  +20 ms (`SamplingCoordinator.swift:210`) and is the baseline; the first
  *data* tick lands one full open-cadence later (1 s default, 2 s if the
  user picked it). Worse, `transitionToIdle()` (`SamplingCoordinator.swift:174`)
  wipes `prevProcCpu` on every close, so a close→reopen two seconds later
  pays the full re-baseline again even though a fresh baseline existed.
  Per-core strip has the same one-tick blank (placeholder bars,
  `PanelRootView.swift:403`).
- **User-visible payoff:** the panel's reason-to-exist (the process list)
  appears in ~0.3 s instead of 1–2 s, and instantly on quick reopen. For a
  "spot the runaway" tool, open-latency is the metric.
- **Fix (two independent pieces):**
  1. Schedule one early second tick at ~+300 ms after entering open tier
     (a 280 ms delta is statistically noisier but fine for a first paint;
     the next regular tick corrects it). ~10 lines.
  2. Keep `prevProcCpu` (+ a timestamp of its capture) across the
     open→idle transition; on re-entering open tier, if the baseline is
     younger than the gap threshold, compute immediately using measured
     elapsed-since-capture. Requires a per-metric prev-timestamp instead of
     the shared `prevTickTime` — modest refactor.
- **Cost:** (1) low, (2) medium-low. Ship (1) first.

### F7 — Idle tier reads per-core CPU every tick and throws it away — MEDIUM-LOW

- **Severity:** medium-low (pure waste on the always-on path)
- **Evidence:** `CPUSampler.read()` unconditionally does `readOverall` +
  `readPerCore` (`CPUSampler.swift:20-25`); `readPerCore` is a
  `host_processor_info` call that kernel-allocates an array per invocation
  (then `vm_deallocate`s it). The idle tick consumes only
  `counters.overall` (`SamplingCoordinator.swift:283-292`); `perCore` is
  computed, copied into 18 `CPUTicks` structs, and discarded — every 2 s,
  forever.
- **User-visible payoff:** fewer syscalls + one less kernel allocation per
  idle tick. Individually small, but it's the always-on loop — the place
  where waste compounds into energy.
- **Fix:** split the sampler API (`readOverall()` / `read()`); idle path
  calls the cheap one. ~15 lines.
- **Cost:** trivial-low.

### F8 — No keyboard path to dismiss the panel (Esc) — MEDIUM-LOW

- **Severity:** medium-low (accessibility + everyday ergonomics)
- **Evidence:** `DropPanel.swift` overrides only `canBecomeKey`/
  `canBecomeMain`; `rg -n "cancelOperation|keyDown" Sources/` → no hits.
  The panel takes key (so it *eats* keyboard focus) but Escape does
  nothing; the only dismissals are clicking outside or re-clicking the
  status item.
- **User-visible payoff:** open-glance-Esc becomes a fluid keyboard loop;
  also the standard expectation for any transient panel. VoiceOver users
  currently have no non-pointer dismissal at all.
- **Fix:** override `cancelOperation(_:)` in `DropPanel` to invoke a close
  callback. ~6 lines.
- **Cost:** trivial.

### F9 — Idle timer leeway is 50 ms regardless of cadence — LOW

- **Severity:** low (energy)
- **Evidence:** `SamplingCoordinator.swift:208-213` — both tiers schedule
  with `leeway: .milliseconds(50)`. For the 2 s (or 5 s) idle cadence,
  a 50 ms leeway prevents the kernel from coalescing this wakeup with
  others. Nothing about the idle glyph needs ±50 ms precision.
- **User-visible payoff:** fewer scheduled wakeups on battery; the
  rate math already divides by *measured* elapsed so accuracy is unaffected
  by construction (`README.md:162-165`).
- **Fix:** `leeway = cadence * 0.1` (200 ms at 2 s, 500 ms at 5 s); keep
  open tier at 50–100 ms for visual liveness. 2 lines.
- **Cost:** trivial.

### F10 — Status-item image is re-rendered every tick even when visually identical — LOW

- **Severity:** low (main-thread work on the always-on path)
- **Evidence:** `StatusItemController.swift:44-46` redraws on every
  snapshot publish; `GlyphRenderer.render` re-measures strings
  (`measureCell` → multiple `NSString.size` calls plus the
  `throughputValueReservedW` computed property re-measuring "999MB"/"999GB"
  per call, `GlyphRenderer.swift:135-138`) and allocates a fresh `NSImage`
  each time. On an idle machine the rendered output ("cpu 1%, mem 60%") is
  identical tick after tick.
- **User-visible payoff:** marginal CPU/allocations saved at 0.5 Hz —
  honest framing: this is a small win, ranked low accordingly.
- **Fix:** derive a cheap render key (the displayed strings + bar fill
  buckets + arrow buckets); skip `render` when unchanged. Cache
  `throughputValueReservedW` in `init` regardless — it's constant per
  renderer instance. ~20 lines.
- **Cost:** low.

### F11 — Right-click on the status item does nothing — LOW

- **Severity:** low (missing macOS-native affordance)
- **Evidence:** `StatusItemController.swift:39-42` wires a single
  target/action; no `sendAction(on:)` mask including `.rightMouseUp`, no
  menu. Every long-lived menu-bar utility offers right-click → Quit /
  Settings; here the only path to Quit is open panel → footer button.
- **User-visible payoff:** standard escape hatch when the panel is broken
  or off-screen (see F5) — a robustness affordance, not decoration.
- **Fix:** `button.sendAction(on: [.leftMouseUp, .rightMouseUp])`, branch
  on `NSApp.currentEvent?.type`, show a 3-item `NSMenu` (Settings…, Quit)
  on right-click. ~25 lines.
- **Cost:** low.

### F12 — Process names come from `proc_name` and truncate; hurts search and identification — LOW

- **Severity:** low-medium (usability of search + disambiguation)
- **Evidence:** `ProcessSampler.swift:62-68` uses `proc_name` (caps at
  ~32 bytes; long helper names like
  "Code Helper (Plugin) <something>" clip). The search filter matches
  against this truncated name (`PanelRootView.swift:343-345`), so a user
  typing the visible app name from Activity Monitor may get no match. The
  UI already lazily caches the full executable path per pid
  (`PanelRootView.swift:605-619`) but never uses it for the display name.
- **User-visible payoff:** search that matches what the user thinks the
  process is called; distinguishable helper processes.
- **Fix:** when `pidPath[pid]` exists, prefer its basename (or
  `NSRunningApplication.localizedName` for regular apps) as display/search
  name. Pure UI-layer change; sampler untouched. ~15 lines.
- **Cost:** low. (Caveat: name changes only after the row has been
  on-screen once, since path lookup is lazy — acceptable.)

### F13 — No NET/DISK history; spike forensics limited to CPU/MEM — LOW (feature)

- **Severity:** low (capability gap, not a defect)
- **Evidence:** only `cpuHistory`/`memHistory` ring buffers exist
  (`SamplingCoordinator.swift:64-65`); net/disk publish instantaneous
  values only.
- **User-visible payoff:** "what just hammered the disk for 10 s?" is
  answerable after the fact. For a glanceable monitor, 60 s of throughput
  history is the difference between catching a spike and missing it.
- **Fix:** two more `RingBuffer`s (they're cheap value types), append in
  `readNet`/`readDisk`, two more `GraphView`s (log-scaled) in the panel.
  Note the idle tier only samples net/disk when those bar cells are
  enabled, so history may have gaps — render gaps honestly (the buffer is
  time-indexed already).
- **Cost:** medium.

---

## Explicitly OUT OF SCOPE (display-only — do not implement under this audit)

- Identity-color / icon / bar-grammar tweaks of any kind (just shipped in
  bar v2; no usability delta).
- README says "top-25 process list" while the default is 10
  (`SettingsStore.swift:112`) — documentation fix only.
- Sparkline styling, divider weights, fonts, paddings.
- Copy-button "copied!" animation *as a standalone change* (folded into F3
  where it becomes part of a real interaction).

## Non-findings (checked, healthy)

- `vm_deallocate` hygiene on `host_processor_info` — present and correct
  (`CPUSampler.swift:68-72`).
- Wake-from-sleep re-baseline — wired (`AppDelegate.swift:111-127`).
- Per-pid UI cache pruning — present (`PanelRootView.swift:242-255`), no
  unbounded growth.
- RingBuffer value-type isolation / single MainActor hop per tick — sound;
  measured idle CPU confirms the architecture delivers.
- Search-filter-before-sort, EMA rank hysteresis — both implemented as
  documented.

## Suggested implementation order (payoff ÷ effort)

| # | Finding | Effort | Why this order |
| --- | --- | --- | --- |
| 1 | F1 pressure source | ~20 lines | Removes an active lie |
| 2 | F5 screen clamp | 3 lines | Trivial, user-visible bug |
| 3 | F8 Esc dismiss | 6 lines | Trivial, daily-use ergonomics |
| 4 | F2 hover value freeze | ~15 lines | Trust during the core workflow |
| 5 | F4 occlusion → idle tier | ~15 lines | Honors the energy budget everywhere |
| 6 | F9 idle leeway | 2 lines | Free energy win |
| 7 | F7 split CPU read | ~15 lines | Always-on path waste |
| 8 | F3 real kill buttons | ~60 lines | Biggest usability jump, needs confirm UX |
| 9 | F6.1 early second tick | ~10 lines | Open latency |
| 10 | F11 right-click menu | ~25 lines | Robustness affordance |
| 11 | F12 better names | ~15 lines | Search quality |
| 12 | F6.2 baseline retention | refactor | After F6.1 proves insufficient |
| 13 | F13 net/disk history | medium | v2 feature slot |

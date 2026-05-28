<!-- sessions: sys-monitor@2026-05-28 -->

# sys-monitor — Stage 2: Behavior Plan (HOW IT BEHAVES)

> **Stage 2 of 3.** Defines *how the app behaves moment-to-moment* — the UX of the bar
> glyph and dropdown panel, every interaction flow, every state, and the sampling state
> machine that ties behavior to the NFR-1 budget. It does **not** specify code structure /
> files / APIs (Stage 3). Grounded in `docs/01-spec.md`.
> **Status: revised after sub-agent review** (`.claude/output/20260528-behavior-review/`).
> All critical + should-fix findings, unhandled states, and nits incorporated.

---

## 0. Behavior decisions taken here

| Ref | Decision | Rationale |
| --- | --- | --- |
| OQ-1 | Bar glyph default = **mini usage-bar + numeric %**. "Sparkline" is an alternate style (setting); when chosen, sparkline + small %. | `%` is the at-a-glance number; the bar/sparkline is the texture. |
| OQ-3 | Process list = **top 10 default, scrollable to top 25**; fixed-height region so the panel doesn't resize as ranks churn. | 10 fits without scroll; scroll reveals more without growing the panel. |
| — | Sort toggle in the **process section header** (segmented `CPU \| MEM`). | Local to the data it sorts. |
| — | **Dismissal model (resolves review issues 1–2):** `resignKey` caused by a user click *outside the panel* → **dismiss**. Becoming invisible *without* a user dismiss (occlusion / display sleep / Space switch) → **keep the panel, drop to idle tier**, resume on return. | Distinguishes user-intent-to-close from incidental invisibility; satisfies both FR-19 (dismiss) and FR-15 (hidden→idle). |
| — | **Idle tier samples overall CPU + memory** (two cheap aggregate calls) into a shared ring buffer that also pre-populates the panel's CPU/MEM graphs. | Resolves the "blank graph for 60 s" problem (issue 9) and BQ-4 (buffers are **shared**); cost is a handful of floats per idle tick. |
| — | **Cadence ordering invariant: idle cadence ≥ open cadence.** Settings enforces it (can't set idle faster than open). | Idle is the always-on budget tier; it must never sample more often than the on-demand tier. |
| — | **`N = 2`** is the default gap multiplier: a sampling gap > `N × tick` triggers re-baseline, and the same `N×tick` bounds the close→reopen grace window. | One constant governs all gap logic so the rules stay consistent. |

---

## 1. The two surfaces at a glance

```
 ┌─ macOS menu bar ───────────────────────────────────────  ▕▓▓▓░▏ 38%  ◀─ GLYPH (always on)
 │                                                              │ click
 │                                                              ▼
 │   ┌──────────── DROPDOWN PANEL (NSPanel · live SwiftUI) ────────────┐
 │   │  CPU            38%   ▕▓▓▓▓▓▓▓░░░░░░░░░░░░░░░▏   ╱╲╱‾╲╱  (60s)   │
 │   │  cores  ▕▓▓░░▏▕▓▓▓▓▏▕▓░░░▏▕▓▓▓░▏▕░░░░▏▕▓▓▓▓▏▕▓▓░░▏▕░░░░▏        │ ← illustrative (8-core)
 │   │ ───────────────────────────────────────────────────────────── │
 │   │  MEM   11.2 / 16 GB   ▕▓▓▓▓▓▓▓▓▓▓▓▓▓░░░░░░▏   pressure: normal  │
 │   │  swap  0.4 GB                                  ‾‾‾╲╱‾‾ (60s)   │
 │   │ ───────────────────────────────────────────────────────────── │
 │   │  NET   ↓ 1.2 MB/s   ↑ 0.3 MB/s        DISK  ↓ 4.1 MB/s ↑ 0.0   │
 │   │ ───────────────────────────────────────────────────────────── │
 │   │  PROCESSES                                      [ CPU | MEM ]   │
 │   │   Google Chrome Helper      22.4%     1.8 GB     1827           │
 │   │   WindowServer               9.1%     412 MB      143           │
 │   │   Code Helper (Plugin)       6.7%     980 MB     4410           │
 │   │   … (scroll for more, up to 25)                                │
 │   │ ───────────────────────────────────────────────────────────── │
 │   │  ⚙ Settings                                     ⏻ Quit         │
 │   └─────────────────────────────────────────────────────────────────┘
```

Glyph = a custom `NSView` we draw; panel = SwiftUI hosted in an `NSPanel`. The per-core
row above is illustrative for an 8-core machine; real core count drives wrapping (§3.1 #2).

---

## 2. Menu-bar glyph behavior

### 2.1 Content & styles (FR-2/FR-3)

- **Default — bar + value:** a compact horizontal usage bar then the numeric value
  (`▕▓▓▓░▏ 38%`), filling left→right with load.
- **Alternate — sparkline + value:** a tiny sparkline of the **shared idle-tier ring
  buffer** (the same buffer that feeds the panel CPU graph), then the value.
- **Alternate metric — memory:** same two styles for memory %.
- All glyph text uses **monospaced/tabular figures** so width never jitters as digits
  change (38% → 100% must not wobble neighbors). Width is reserved for the widest value.

### 2.2 Visual semantics

- Load color is a **secondary cue only** (NFR-9); the **numeric value is always primary** —
  never color-only. Illustrative thresholds (final ramp = Stage 3 tokens): <60% calm,
  60–85% elevated, >85% hot. Under **Increase Contrast**, the ramp swaps to a
  higher-contrast token set.
- The colored usage bar makes the glyph the **custom-colored** path (FR-4): it re-draws on
  every menu-bar appearance change (light/dark, tinted, Reduce Transparency). A monochrome
  template style is an optional Stage-3 add, not required v1.

### 2.3 Glyph states

| State | Glyph shows |
| --- | --- |
| **Launching / measuring** (FR-16) | Bar empty + `—` until the 2nd idle sample yields a valid CPU rate. Never `0%`. |
| **Normal** | Bar + live value, every idle tick (default 2 s). |
| **Post-wake / post-gap** (FR-18) | `—` until the **first valid post-gap rate** — that's the tick *after* the re-baseline sample, so it can be **up to two ticks** of `—`, then resumes. No spike. |
| **Sample failed** (FR-17) | Holds last good value for one tick; if it fails again, shows `—`. Never crashes, never `0`. |

### 2.4 Click

- Left-click **toggles** the panel. The toggle reads live panel state and is **idempotent**:
  a click while opening is a no-op, not a second open (guards the open-tier timer against
  double-scheduling — issue 5).
- v1 has no right-click menu; Quit/Settings live in the panel footer (§3.5).

---

## 3. Dropdown panel behavior

### 3.1 Layout & information architecture (FR-6)

Top→bottom, fixed order:

1. **CPU** — label, overall %, full-width usage bar, 60 s history graph.
2. **Per-core strip** — one small bar per core, by index (R7/N9). Tooltip + a11y label per
   core: "core N — XX%". **Wrapping & cap:** wraps to additional rows as needed up to a
   **max of 3 rows**; beyond the count that fills 3 rows (high-core Mac Pro), it collapses
   to an **aggregate mini-histogram** (distribution of per-core load) so the per-core strip
   can never push the process list or footer off-screen. The panel has a **max height**;
   the process region scrolls, the per-core region caps.
3. **Memory** — used / total (GB), usage bar, memory-pressure word
   (normal/warn/critical), swap used, 60 s history graph.
4. **Network + Disk** — one compact row: NET ↓/↑ and DISK ↓/↑, human-readable units
   (B/s→KB/s→MB/s). Each throughput column **reserves max-unit width** (like the glyph
   width rule, §2.1) so values don't jitter as units change. (Disk subject to N8 — §3.6.)
5. **Processes** — header with `[ CPU | MEM ]` sort toggle; ranked rows (name, %CPU, memory,
   PID), top 10, scrollable to 25. Process **names truncate with ellipsis** to the column
   width (htop-style); an empty/blank name falls back to a bracketed PID label
   (`[pid 143]`). If fewer processes exist than the configured count, the list renders what
   exists — **no padding `—` rows**.
6. **Footer** — `⚙ Settings` and `⏻ Quit`. (The cadence indicator is **folded into a
   tooltip** on the footer rather than always-visible text — it earns no permanent space at
   htop density.)

### 3.2 Live update behavior (FR-5, NFR-5)

- While open, sections refresh on the open-panel tick (default 1 s).
- Updates are **value mutations, not layout rebuilds** — numbers and bar widths animate;
  the panel never resizes or reflows (no flicker, R2/NFR-5).
- **Process-list churn control (issue 7):** rows have stable identity by PID **and**
  **rank hysteresis** — a process must beat the one above it by a margin **or** hold the
  better position for **2 consecutive ticks** before they swap. Combined with
  **freeze-on-hover**: while the pointer is over the list, re-sorting pauses (also prevents
  the row sliding out from under a click/scroll). Re-sort transitions honor **Reduce
  Motion** (snap, don't animate, when on).
- **Scroll behavior (issue 8):** interactions *inside* the panel (scroll, sort toggle, hover)
  never dismiss it — only a click *outside* the panel bounds does. Scroll offset is
  **preserved across re-sorts** (anchored to the scrolled position, not reset to top).
  Toggling the sort basis **resets scroll to top** (intentional — the ranking changed).

### 3.3 Graphs (FR-7, G3)

- CPU and memory each show a **60-second** window, **time-based** (stays 60 s whether the
  open cadence is 1 s or 2 s).
- **Pre-populated on open:** graphs read from the **shared idle-tier CPU/MEM ring buffer**
  (§0 decision), so opening the panel shows existing history immediately — not a blank
  graph that fills over a minute. While open, the open-tier cadence appends finer-grained
  points on top.
- **Sleep/wake in the history:** if a sleep/wake (or any gap > `N×tick`) falls inside the
  60 s window, the trace shows a **gap marker** at that point rather than interpolating a
  spike (FR-18).
- Reduce Motion: graphs **step/freeze** rather than animate the trace (NFR-9).

### 3.4 Panel states

| State | Behavior |
| --- | --- |
| **First open after launch** | Sections render immediately. **Instantaneous** metrics (mem %, pressure, swap) show real values on open tick #1 — including a legitimate `0` (e.g. swap `0.0 GB`), which is **not** the same as `—`. **Rate** metrics (per-core, net, disk, per-proc %CPU) show `—` on tick #1 and real values on tick #2 (FR-16). CPU/MEM graphs are pre-populated from the idle buffer. |
| **Steady open** | All live at 1 s. |
| **Metric unavailable** (FR-17) | Only an **errored** sample shows `—` for that metric; the rest of the panel is unaffected. `0` is a real value, shown as `0`. Disk-demoted (N8) hides the row (§3.6). |
| **Process race** (FR-17) | Vanished PIDs dropped silently between ticks; no error row. Partial fields for root/other-user processes are tolerated. |
| **Became invisible without dismiss** (occlusion / display sleep / Space switch) (FR-15) | Panel **stays**, drops to idle tier (expensive sampling pauses). On return-to-visible, re-baselines the open-only counters (§6) and resumes. |
| **Dismissed** (user click outside → resignKey) (FR-19) | Panel tears down; open tier stops; baselines + 60 s buffer kept alive for the grace window (§0 `N×tick`) so a quick reopen resumes instead of re-baselining. |
| **Post-wake while open** (FR-18) | The open-tier timer was suspended during sleep; the `didWake` handler re-baselines the open-tier counters; rate sections show `—` for one interval; graph inserts a gap marker. |
| **Display disconnected while open** | Panel **dismisses** (its anchor display is gone) rather than re-anchoring mid-session; reopen anchors to the current menu-bar display (FR-19). |

### 3.5 Footer actions

- **⚙ Settings** — opens the settings window. Because the app is `.accessory`, this performs
  the activation dance (R8): bring the app forward, show + order-front the window, return to
  `.accessory` on close. **Opening Settings dismisses the panel.**
- **⏻ Quit** — terminates the app. On quit, **all timers and the open-tier sampler are torn
  down cleanly** (no orphaned timers — a gotchas.md theme).

### 3.6 Disk row degradation (N8 / C-3)

- Stage-3 spike confirms reliability → show the DISK ↓/↑ row.
- Not reliable → the row is **hidden** (preferred). The panel must look intentional — no
  lingering empty `—/—` disk row.

---

## 4. Settings behavior (FR-10–FR-13)

Settings is a small window (not the dropdown). Every control is **wired** (FR-11):

| Control | Effect when changed | Notes |
| --- | --- | --- |
| **Idle cadence** | Idle timer reschedules; idle baseline resets → glyph blinks `—` for one tick then resumes (FR-16/FR-13). Constrained to **≥ open cadence** (§0 invariant). | If the panel is open (open tier owns sampling), the idle change applies on tier-return. |
| **Open cadence** | Open-tier timer reschedules; baseline resets. **Applies on the *next* panel open** — opening Settings closed the panel (§3.5), so the user reopens to see it. | Reconciles AC-4: open-cadence is "verified live" on the *next* open, not the same instant. |
| **Bar metric/style** | Glyph re-renders next idle tick. | Verified live in the bar. |
| **Process count / default sort** | Panel list length + initial sort change. | Reflected on next open. |
| **Launch at login** | `SMAppService.register()` / `.unregister()`. | Shares the R8 activation concern. |

- No unwired controls (FR-11). A staged-but-unwired control shows "(not yet active)"; v1
  ships all of the above wired.
- Cadence change cancels the old timer, resets the baseline, reschedules — never
  double-fires or emits a spike (FR-13).

---

## 5. End-to-end interaction flows

### 5.1 Launch → first readout
```
launch (.accessory, no Dock) → glyph shows "—" (measuring)
   → idle tick #1: CPU+MEM baseline captured, still "—"
   → idle tick #2 (≈2s): first valid CPU rate → glyph ▕▓▓░▏ 17%; ring buffer growing
```

### 5.2 Open → inspect → close
```
click glyph → panel opens; instantaneous metrics (mem/pressure/swap) show real values now;
              CPU/MEM graphs pre-populated from idle ring buffer; open-tier sampler starts
   → open tick #1: re-baseline per-core/net/disk/per-proc (they didn't exist in idle tier);
                   those show "—"
   → open tick #2: live rate values appear
   → user toggles [MEM] → list re-sorts by memory (hysteresis + Reduce-Motion aware), scroll→top
   → user hovers list → re-sorting freezes while pointer is over rows
   → click outside → dismiss → open tier stops → baselines+buffer kept for grace window
```

### 5.3 Sleep/wake (always-on edge case, FR-18)
```
panel closed, idle tier running → system sleeps (timer stops firing)
   → wake → NSWorkspace.didWake → next idle sample flagged "gap" (> N×tick)
   → glyph "—" until first valid post-gap rate (up to 2 ticks) → resumes; no 4000% spike
```

### 5.4 Occlusion vs. dismiss (the distinction that resolves issues 1–2)
```
panel open ─ user clicks another app's window  → resignKey(user) → DISMISS
panel open ─ fullscreen app covers it           → occlusionState=.invisible → KEEP, drop to idle
panel open ─ user switches Space                 → panel occluded on origin Space → KEEP, drop to idle
panel open ─ display sleeps                      → occlusion → KEEP, drop to idle; re-baseline on wake
panel open ─ that display is unplugged           → DISMISS (anchor gone); reopen on current display
```

---

## 6. Sampling state machine (ties behavior ↔ NFR-1 budget)

```
                         ┌───────────────────────────────────────────────┐
                         │                    IDLE TIER                   │
                         │  timer @ idle cadence (default 2s, ≥ open)     │
   app launch ─────────▶ │  samples: overall CPU + memory (2 cheap calls) │
                         │  keeps: shared CPU/MEM ring buffer (bar         │
                         │         sparkline + pre-populates panel graphs) │
                         │  cost target: < ~1% of one core (NFR-1)         │
                         └──────┬───────────────────────────▲──────────────┘
       panel VISIBLE & key     │                            │  panel dismissed (resignKey by
       (becomes expensive-     │                            │  user click outside)  OR
        eligible)              ▼                            │  became invisible (occlusion /
                         ┌──────────────────────────────────┴───────────┐ display-sleep / Space)
                         │                    OPEN TIER                  │
                         │  timer @ open cadence (default 1s)            │
                         │  samples: overall+per-core CPU, mem+swap,     │
                         │           net, disk, process enumeration      │
                         │  keeps: 60s time-based graph buffers          │
                         │  (the ONLY tier that runs proc enumeration)   │
                         └────────────────────────────────────────────────┘

  Expensive-eligible predicate:  panel.isVisible && occlusionState.contains(.visible)
                                 (NOT isKeyWindow alone — issue 1)

  RE-BASELINE triggers (drop the cross-gap delta, show "—" per FR-16):
    • idle → open tier switch ....... re-baseline per-core/net/disk/per-proc (didn't exist idle)
                                      overall CPU carries its idle baseline forward IF gap < N×tick
    • sleep/wake or any gap > N×tick . re-baseline ALL rate metrics in the active tier
    • cadence changed in Settings ... cancel timer, reset baseline, reschedule (FR-13)
    • return from invisible→visible . treated as idle→open switch (re-baseline open counters)
```

**Invariants (enforce in Stage 3):**
- **Process enumeration, per-core, net, disk, and 60 s graph buffers exist ONLY in the OPEN
  tier.** The idle tier does exactly two cheap aggregate calls (CPU, memory).
- Tier eligibility keys off **visibility + occlusion**, not panel existence or key status
  alone (FR-15, issue 1).
- **All rate metrics divide cumulative-counter deltas by the *measured elapsed wall-clock
  time* between the two samples — never the nominal tick interval** (issue 4). This makes
  cadence changes, tier switches, and timer jitter correct by construction (subsumes part
  of FR-13).
- The open-tier timer is **singular and guarded**: starting while already open is a no-op;
  flapping open/close reuses baselines within the grace window (issue 5).
- Sampling runs **off the main thread**; UI mutation dispatches to main (NFR-5).
- **Grace window = `N×tick`** (§0): on dismiss, baselines + buffer survive that long; a
  reopen within it resumes without re-baselining; a sleep/wake during the closed interval
  discards/gap-marks the buffer (issue 10). Buffers are dropped after the grace window so
  history isn't retained for a panel that won't reopen (NFR-4).

---

## 7. Accessibility behavior (NFR-9)

- **Glyph:** exposes an `accessibilityValue` reflecting the current metric + value (e.g.
  "CPU 38 percent"), updated as values change but **not announced every tick** — VoiceOver
  reads it on focus, never as a per-second firehose. Trait marks it as updating
  (`updatesFrequently`) rather than posting announcements.
- **Panel reading order:** CPU → per-core → memory → network/disk → processes → footer.
- **Process rows:** each row is **one a11y element** — "Google Chrome Helper, 22.4 percent
  CPU, 1.8 gigabytes, PID 1827".
- **Reduce Motion:** graphs and re-sorts step/snap instead of animating (also §3.2/§3.3).
- **Increase Contrast:** load→color ramp swaps to a high-contrast token set; and because
  color is never the sole signal (§2.2), every value remains legible in grayscale.

---

## 8. Memory / footprint behavior (NFR-4)

- Retained history is bounded: the shared idle ring buffer holds **60 s at the idle
  cadence**; open-tier graph buffers hold **60 s at the open cadence**; both evict FIFO.
- Grace-period buffers are dropped after the `N×tick` window (§6).
- No history persists across launches (N7). These bounds are the behavioral expression of
  the ~80 MB cap (NFR-4); Stage 3 picks graph rendering (Swift Charts vs. `Path`) against
  this budget (OQ-5).

---

## 9. Visual/density principles (handoff to Stage 3 design tokens)

- htop-like density: tight vertical rhythm, **tabular/monospaced figures everywhere** so
  columns align and widths never jitter (glyph value, throughput columns, process columns).
- Bars and sparklines share one load→color ramp (Stage 3 tokens), reused by glyph and
  panel.
- Color is decorative/secondary; every value legible in grayscale (NFR-9).
- Subtle dividers; the panel reads as one dense instrument, not boxed cards — closer to
  htop than a settings screen.

---

## 10. Open questions for Stage 3 (implementation-level)

- **BQ-2** Exact per-core wrap thresholds (rows→aggregate switch) at real core counts, and
  the aggregate mini-histogram's form. (Behavior: capped at 3 rows then aggregate — §3.1 #2.)
- **BQ-3** Exact load→color thresholds and the token ramp (incl. the Increase-Contrast set).
- **BQ-5** Graph rendering tech (Swift Charts vs. hand-drawn `Path`) decided on perf/memory
  (NFR-4, OQ-5).

> *(BQ-1 resolved → grace window = `N×tick`, §6/§0. BQ-4 resolved → buffers are **shared**,
> §0/§3.3.)*

---

*End of Stage 2 behavior plan (revised post-review). Next: Stage 3 (implementation plan).*

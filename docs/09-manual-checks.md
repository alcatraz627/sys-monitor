# Manual verification checklist

The things automated checks can't confirm: **pixels** (does it render?) and
behaviors needing a real mouse or a real network. Everything here is *wired
and logic-verified* — this list only closes the *visual/interaction*
confirmation. The build-time math is covered by `sys-monitor --self-test`;
the runtime behaviors by `tools/drills/`.

Open the panel (click the menu-bar item) and walk these. ~3 minutes total.
Mark a row failed → it's a one-line bug report back to me.

## Panel renders (Phase 4 additions)
- [ ] **energy row** — between NET/DISK and PROCESSES: a battery glyph + `NN%`
      on the left (green when charging/charged, orange/red when low+draining;
      hover shows time-to-full/empty), and `cpu N.NNW  gpu N.NNW` watts on the
      right (ane only when active). Numbers move under load. On a desktop the
      left side shows the `POWER` label instead of a battery.
- [ ] **NET/DISK sparklines** — a small log-scaled trace under each throughput
      cell; rises during a download / `dd`, flat when idle.
- [ ] **self-cost** — footer, between the gear and power icons:
      `self 0.X% · NN MB`. Should read well under 1% at rest.
- [ ] **coverage row** — dim line at the list bottom: `top 15 of ~900 processes`
      (or `N of M matching` when filtering).

## Process list interactions
- [ ] **hover keeps values live** — park the cursor over the list ≥5 s; the
      CPU%/MEM numbers keep updating, only the row *order* freezes. (FB-3 class)
- [ ] **kill** — expand a disposable `sleep 999`, click Terminate → "really?"
      → it dies. Force Kill on a stubborn one. A root process → "no permission,
      command copied".
- [ ] **Focus** — appears ONLY for real apps (Safari, Code), NOT for
      menu-bar/background agents. Clicking it must NOT freeze the widget. (FB-1)
- [ ] **process names** — a long helper ("Code Helper (Renderer)") shows its
      full name and is findable by typing it in the filter.
- [ ] **filters** — `>5:cpu`, `<300:mem`, `>1:disk`, `>1:net`, a pid number,
      and a name substring each filter as expected.

## Settings — v2.1 additions
- [ ] **bar-cell reorder (9.4)** — Settings ▸ Menu bar: the enabled metrics show
      a numbered, ordered list with ▲/▼ buttons. Reorder → the menu-bar glyph
      redraws cells in the new order live; chevrons disable at the ends; order
      survives quit+relaunch. Disabling down to one cell shows the "at least one"
      note and refuses to remove the last.
- [ ] **battery bar cell (7.4)** — Settings ▸ Menu bar ▸ enable Battery. A battery
      glyph + `NN%` appears in the menu bar. The symbol tracks the level
      (0/25/50/75/100), shows a bolt while charging, and the color inverts vs the
      other cells: green when charging/plugged or healthy, orange <40%, red <20%.
      On a desktop (no battery) it shows `—`. Reorder it via the cell list (9.4).
- [ ] **throughput units (9.1)** — Settings ▸ Menu bar ▸ Throughput units: flip
      Bytes/s ↔ Bits/s. The NET/DISK glyph cells AND the panel's NET/DISK rows +
      per-process disk/net columns all switch together, live. Bits show a
      lowercase `b` (e.g. `12Mb/s`), bytes an uppercase `B`. Cell width stays
      stable (no menu-bar reflow jitter). Setting survives relaunch.
- [ ] **severity thresholds (9.2)** — Settings ▸ Severity thresholds: drag CPU
      warn down to ~30%. Under light load the CPU value text + glyph CPU bar +
      per-core bars all turn orange/red at the new level, live. Memory has its
      own pair (default 75/92). The warn/critical inversion warning appears if
      warn ≥ critical. Glyph and panel now agree per-metric (previously memory
      coloured at 60% in the panel but 75% in the glyph). Survives relaunch.

- [ ] **threshold alerts (6.1 / 9.5)** — Settings ▸ Alerts ▸ enable. On first
      enable, macOS prompts for notification permission (grant it). Set "CPU
      alert at" to ~30% and "Sustained for" to ~3 samples, then run
      `yes > /dev/null` in a terminal. Within a few samples a "High CPU"
      notification appears — **once**, not every tick. Kill `yes`; it stops.
      Re-spin within the quiet period → no repeat until the cooldown elapses.
      Alerts fire with the panel closed (that's the point). Config survives
      relaunch; disabling stops all alerts.

## Panel signals — v2.1
- [ ] **storage row (7.1)** — between DISK throughput and PROCESSES: a `STORAGE`
      row with a fullness bar + "NNN GB free". Matches `df -h /` within rounding.
      Bar greens/oranges/reds as the disk fills (test thresholds via a full-ish
      volume if available). Hover shows used-of-total.
- [ ] **load + uptime (7.2)** — a dim line below the coverage count:
      `load N.NN N.NN N.NN · up Xd Yh`. The three numbers match `uptime`; the
      uptime matches roughly. Updates while the panel is open.
- [ ] **copy snapshot (8.3)** — the doc-on-doc footer button (next to the gear).
      Click it, paste into an editor → a text block with CPU/MEM/NET/DISK/STORAGE/
      POWER/BATTERY/LOAD lines + top-5 processes, using the on-screen formatted
      values at the current throughput unit (bytes vs bits).

## Global — v2.1
- [ ] **global hotkey (8.2)** — from another app (e.g. a browser), press ⌥⌘M.
      The panel toggles open/closed, same as clicking the menu-bar icon. Works
      without granting any Accessibility permission. (⌥⌘M is uncommon, so no
      conflict with other apps' shortcuts.)

## Menu bar — v2.1
- [ ] **top consumer in menu (6.2)** — open the panel once (so process data is
      gathered), then right-click the menu-bar icon: a disabled "Top: <name> — N%"
      header tops the menu (busiest process). It's absent before the panel has
      ever been opened (idle tier doesn't enumerate processes). VoiceOver on the
      icon also announces the top process. (No hover tooltip — macOS suppresses
      those for accessory apps; the menu is the substitute.)

## Process interactions — v2.1
- [ ] **watch a process / pin (8.1)** — expand a row → a pin icon appears as the
      first action. Click it: the row jumps to the top of the list and stays
      there (filled pin) regardless of the sort metric (cycle CPU→MEM→NET). A
      pinned process below the row cap still shows (it's never cut). Unpin → it
      returns to its ranked spot. Kill a pinned process → its row drops silently.
      Pins survive quit+relaunch.

## Window / lifecycle
- [ ] **Esc** closes the panel; **right-click** the menu-bar icon → Settings/Quit.
- [ ] **resize** — drag the panel's bottom edge; height persists across reopen.
- [ ] **pin** — click the pin; click outside → stays open; switch Space → stays;
      unpin or click the icon → closes. Survives quit+relaunch.
- [ ] **Space switch (unpinned)** — open panel, switch Space → it dismisses.
- [ ] **process rows cadence** — rows update ~every 2 s while the gauges above
      update ~every 1 s (the divisor; watch a moving %).
- [ ] **glyph during menu** — hold the right-click menu open a few seconds;
      the menu-bar readout should keep updating (2.8 — never verified).

## Needs a real (un-throttled) network
- [ ] **per-process NET** — start a real download, sort the list by NET; the
      downloader should top the list. If it shows under a relay process
      (`nesessionmanager`) instead, that's the VPN/Private-Relay platform
      limit (same as Activity Monitor), not a bug.

---
*Provenance: the v2 plan's Phase 1–4 checklists left these as "human check
pending" — the headless-screenshot limitation. This consolidates them.*

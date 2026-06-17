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

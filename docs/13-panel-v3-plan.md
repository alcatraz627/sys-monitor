# Panel v3: expandable sections, felt severity, power

Plan of record for the next build session. Ruled with the owner 2026-09-06 against the
mocks at `.claude/output/20260906-panel-mocks/mocks.html` and the research under
`.claude/output/20260906-monitor-capabilities/`.

Status: reviewed 2026-09-06, partly built. Done: severity on the memory side,
expand and collapse with the memory pools view, and the power segment. Not done:
CPU severity, and expansion for the CPU and NET sections. See "Still open" at the
end for what is waiting on a ruling. The adversarial review is at
`.claude/output/20260906-panel-v3-review/review.md` and it did not pass the plan as
written. Findings S3 through S9 are folded into the sections below. Three sections stay
open on an owner ruling and are marked UNDER REVIEW where they sit: severity (§3, the
proposed instrument was measured and fails the plan's own acceptance test), the CPU
expanded view (§1a) and the NET expanded view (§1c), both of which would move a shipped
on-by-default surface out of the default view.

## Corrections this plan carries

Two things in the mocks were wrong, and the plan exists partly to stop them propagating.

1. **The mocks omitted every sparkline.** The panel already draws history for all four
   metrics: `PanelRootView.swift:167` (CPU), `:195` (MEM), `:261` (NET), `:268` (DISK),
   gated by `settings.showSparklines`. Mock panel A was labelled "the build you have"
   and was missing a shipped feature. Nothing in this plan removes a sparkline.
2. **NET and DISK already share one row, two columns, each with its own graph.**
   `netDiskRow` at `:257` is an HStack of two `ThroughputCell`s. The owner asked for
   this; it exists. No work.

A third correction, to my own recommendation: the PWR section in mock C was redundant.
`energyRow` already shows IOReport package watts beside battery, so system power has a
home. Power belongs only in the process list.

## What is not changing

The owner's words: the visual layout, colour and choices feel compact and modern, and
the aesthetic is not the problem. So:

- No change to the material, corner radius, padding, or the 360 pt width.
- No change to the identity colours or to the green, amber, red severity ramp.
- No new tab bar. Everything lands in the sections and the segmented control that exist.
- Section order stays: CPU, memory, net and disk, storage, energy, processes.

The changes are about which information is present and when a colour fires, not how any
of it looks.

## 1. Expand and collapse, per section

Every metric section gains a disclosure caret at the end of its header row, reusing the
idiom already on process rows (`expandedPids`, the rotating chevron at `:1140`).

- **Collapsed** is today's view: one bar, one value, one aggregate sparkline. This is the
  default and the state the owner already likes.
- **Expanded** adds the detail view for that metric, below the existing content.

This is what makes the rest affordable. The per-core heatmap costs about 110 pt, which is
a serious bite out of 360 pt when always present, and nothing at all when it appears on
demand.

> UNCITED (review S6). That 110 pt appears nowhere else in the repo, and the only other
> 110 pt is `SettingsStore.swift:25-27`, which measures menu-bar glyph width on a
> different axis. Since this figure is the whole argument for expand and collapse,
> measure it against a render before relying on it.

The cluster-averaged compromise from mock D is therefore dropped: it solved a
problem that expansion solves better.

Persist the expanded set in `SettingsStore` so the panel reopens as the user left it.

### CPU expanded

> UNDER REVIEW (S2a). The bar strip below already ships and is on by default:
> `CoreStrip` at `PanelRootView.swift:936`, rendered at `:170` under
> `settings.showPerCoreStrip`, which defaults true (`SettingsStore.swift:267`). It
> already colours per core by the cpuWarn/cpuCritical ramp. So this is not new work, and
> moving it into the expanded state would remove it from the default view, which needs
> the owner's approval. The opacity idea also collides with an existing meaning: opacity
> 0.35 already marks the placeholder state at `:968`. Pending that ruling, the only new
> thing in this view is the heatmap.

- A bar strip, one bar per core, current values. Cluster is encoded as opacity within
  the CPU identity hue, never by borrowing another metric's colour.
- Below it, the per-core heatmap over the history window. One row per core, gapless,
  with a one-row break between clusters.
- Cluster labels derived from `hw.perflevel*`, not hardcoded. This machine reports
  `hw.nperflevels: 2`, 6 Super and 12 Performance.

Why both a sparkline and a heatmap: they answer different questions. The collapsed
sparkline is aggregate shape over time. The expanded heatmap is which core, and it is
the only encoding tested that makes a parked cluster read as a block. Measured on this
machine the two Performance groups differ 1.3% against 22.5% mean, so the aggregate
genuinely hides structure.

### Memory expanded  ·  POOLS BUILT 2026-09-06 (`3f143a8`)

The five pools ship, as a composition bar plus the figures, behind the MEM
caret. GPU memory is not built yet. The band sources are fixed in code and
pinned by the suite, and the live bands sum to 64549 MB of 65536 MB, the
remainder being the speculative pages `trulyFreeBytes` excludes by design.

The owner asked whether this device has multiple types of memory. Physically no:
`hw.packages: 1`, one unified 64 GiB pool, no NUMA and no per-DIMM breakdown on Apple
Silicon. But there are multiple **pools**, and those are the real analogue of per-core:

- App, wired, compressed, cached files, free. Three of these are fields on `MemoryRaw`
  after the 2026-09-06 memory work; two are derivations, and naming the wrong source is
  how the bug fixed in `a3855fa` comes back (review S4). The band sources are fixed:
  app is `internalBytes` and never `activeBytes`, wired is `wiredBytes`, compressed is
  `compressedBytes`, cached files is `externalBytes + purgeableBytes`, free is
  `freeBytes − speculativeBytes`.
- Swap used. Already on `MemoryRaw` as `swapUsedBytes`, so this bullet needs no
  sampling work.
- GPU-allocated memory, from `IOAccelerator`. Verified readable sudoless: 2.8 GB
  allocated and 1.3 GB in use at the time of measurement. On unified memory this is a
  genuinely distinct claim on the same 64 GiB and is not visible anywhere today.

Render as a single stacked composition bar plus a labelled breakdown. Note the known
perception cost of stacking: only the bottom band reads against a flat baseline, so put
the band the user most needs to judge at the bottom, and label every band numerically
rather than relying on area comparison.

### NET and DISK expanded

Per-interface breakdown for NET already exists (`perInterfaceNet`) and is currently its
own row; it becomes the expanded state instead. DISK expands to per-process disk rate.

> UNDER REVIEW (S2b). `netInterfaceBreakdown` renders unconditionally today at
> `PanelRootView.swift:100`, so moving it behind a collapsed caret removes it from the
> default view. Same gate as the CPU strip above: this needs the owner's approval, not a
> plan sentence. DISK expanding to per-process rate is new work and is unaffected.

## 2. Subtitles carry felt severity, not a second number

Each section's subtitle line becomes the place where saturation and stall evidence is
stated in words. The owner's constraint, verbatim: the subtitles can show the felt
severity, as long as we are not using that visual signifier but just making it more
relevant.

So the subtitle is **text only**. No coloured dot, no second bar, no badge. The existing
colour ramp on the existing bar remains the only visual signifier.

The CPU row needs rework before it is built (S2c). `loadLine` at
`PanelRootView.swift:604-615` already renders the load average and uptime at the panel
footer, always, and its explain string already says load is runnable threads and that
roughly 18 means fully busy. A CPU subtitle showing run queue against core count would
put the same number a dozen rows above where it already sits, inside a 360 pt panel.
Whatever replaces it should carry something `loadLine` does not.

| Section | Subtitle shows | Not |
|---|---|---|
| CPU | run queue against core count (already in `loadLine`, needs rework) | a restatement of the percentage |
| Memory | compressor and swap rate when nonzero, else a calm phrase | percentage used, which the bar already gives |
| NET | retransmits or link trouble when present | a restatement of throughput |
| DISK | service time when it is elevated | a restatement of throughput |

The rule this follows is `~/.claude/conventions/visual-design.md`, section "Severity:
what makes a light worth lighting". The subtitle earns its line by carrying something
the bar cannot.

## 3. Severity fires on felt evidence

> UNDER REVIEW (S1). The principle below stands and the owner ruled it. The proposed
> instrument does not: `getloadavg` was measured at 21 s to fire and still 0.80x cores a
> full minute after the machine went idle, so it fails this section's own steady-state
> amber criterion. See the answered open questions at the end of this file for the
> measurements and the two-signal replacement. Do not build §3 until the confirmer is
> ruled.
>
> One thing this section never addressed, and must (S7): `DesignTokens.loadColor` is
> also what colours every per-core bar in `CoreStrip` (`:969-971`), against per-core
> load. A single core has no run queue. Once the headline colour stops meaning
> utilisation, eighteen core bars can sit red while the headline reads calm, in the same
> section at the same moment. Rule what a per-core bar's colour means.

The colour ramp stays. What changes is the input.

- **CPU colour comes from run-queue depth relative to core count**, not utilisation.
  The case that motivated this: 94% utilisation with a queue of 2.1 on 18 cores is a
  machine working correctly and must stay calm. 91% with a queue of 37 is the machine
  the owner calls laggy and must not.
- **Memory colour comes from reclaim evidence**, the compressor and swap rate, not from
  percent used. 71% used while thrashing must not read calm, which today it does,
  because the warn threshold is 75%.
- Utilisation stays fully visible as the bar fill and the number. It simply stops
  deciding the colour.

Source for run queue: `getloadavg` already sampled by `LoadSampler`, divided by
`activeProcessorCount`. This is a proxy rather than an instantaneous run queue, and the
plan should say so in the UI wording rather than overclaim.

**A steady-state amber is a bug.** If any indicator sits warm during ordinary operation
after this change, its trigger is describing the machine's normal condition and must be
re-baselined. This is an acceptance criterion, not a preference.

## 4. Power as a fifth segment  ·  BUILT 2026-09-06 (`df0d0ec`)

Built as specified. The width question below was answered by making the frame a
function of segment count, `PanelRootView.pickerWidth(segments:)`, which is what
review S3 said it had to become. Labels are abbreviations because 31 pt per
segment is what five segments actually get. Live check: 561 of 561 visible pids
report `ri_energy_nj` without root, asserted in the suite rather than assumed.


- Add `pwr` to `SettingsStore.ProcSort` (`SettingsStore.swift:29`, today
  `case cpu, mem, disk, net`) and a fifth segment to the picker at `:406`.
- **Decide the picker width first (review S3).** This is a blocker on §4, not only on
  §5. The width at `:419` is a binary ternary on one availability flag; a fifth segment
  makes availability two-dimensional, so it must become a function of segment count.
  Widening competes with the search field inside 360 pt, and leaving it at 156 pt gives
  31 pt per segment.
- Per-process watts from `ri_energy_nj`, deltaed over the process sampling interval.
  Confirmed live on this machine: the field is a cumulative nanojoule counter readable
  for every visible pid without root, from the `proc_pid_rusage` call
  `ProcessSampler` already makes for disk bytes. Measured node at 0.112 W over a 5.01 s
  interval.
- No new section. System power already lives in `energyRow`.
- State the honest limit somewhere the user can find it: the sum covers only visible
  processes, and 321 of 941 are invisible without the task-ports entitlement.

## 5. Icons on the segment labels

Reuse each metric's identity icon from the glyph, to the left of the label, so the
control matches the menu bar.

**This is the least certain item in the plan, and the review made it worse (S3).** The
control is `.pickerStyle(.segmented)` at `:417`. The width figure this section was
written on was wrong by 2.2x: `PanelRootView.swift:419` reads
`.frame(width: store.snapshot.perProcessNetAvailable ? 156 : 124)`, so the picker is not
panel-width. It shares its header row with the "PROCESSES" label and the search field.
Four segments in 156 pt is 39 pt each today, and a fifth at the same width is 31 pt.

Icon plus label in 31 pt is not a probe outcome in doubt. Treat this item as
provisionally dead unless the width decision in §4 frees real space, and if the stock
picker will not carry it the alternative is a custom segmented control, which is a
bigger change than the rest of this plan combined. Do not start here.

## Verification

Every item below is a check to run, not a box to tick by inspection.

1. **Nothing regressed.** `--self-test` must still print ALL PASS, and the four
   sparklines must still render. Compare against `docs/12-parity-baseline.md`. The count
   is 176 today, confirmed 2026-09-06, but the binary prints no total, so check it with
   `.build/release/sys-monitor --self-test > out.txt` then `rg -c '^  ok   ' out.txt`
   (review S8).
2. **Expansion.** The panel window does not grow when a section expands: its height is
   user-set and clamped 320 to 900 by `PanelController.swift:185-186`, and only the
   process list scrolls (`PanelRootView.swift:1070`, floored at 140 pt by `:1084`).
   Expansion therefore steals space from the process list. Test that instead: with every
   section expanded at the 320 pt minimum height, no section is clipped and the process
   list still shows at least one row (review S5).
3. **Severity.** Induce each of the four mock scenarios and confirm the colour matches
   the felt state, in particular that a busy-but-responsive machine stays calm.
4. **Steady-state amber.** Watch the panel through an ordinary hour. Any indicator that
   sits warm without the owner noticing anything is a failed trigger.
5. **Power.** Cross-check a process's watts against its CPU time, and confirm the sum
   moves when a known load starts.
6. **Both themes and both displays.** Read the rendered pixels, not the assertions.
7. **Mutation-test every new guard.** Break the thing it protects, watch it go red,
   restore. Two guards written on 2026-09-06 were blind when first tested.

## Sequence

1. Severity re-trigger. Smallest change, largest effect on the complaint that started
   this, and touches no layout.
2. Expand and collapse scaffolding, with the CPU detail view as its first consumer.
3. Memory expanded, including GPU memory.
4. Power segment.
5. Subtitles.
6. Segment icons, last, gated on the probe above.

## Open questions, answered by the review

All three were answered on 2026-09-06 by measurement. Full working in
`.claude/output/20260906-panel-v3-review/review.md`.

**Is run-queue-over-core-count a good enough saturation proxy? No.** Measured on this
machine, 18 cores, a step of 36 runnable threads. It took 21 s to cross the saturation
line, and a full minute after the load stopped it still read 0.80x cores on a completely
idle machine. So it is both too late to confirm a felt hitch and, worse, guaranteed to
sit amber on an idle machine for over a minute, which is the exact steady-state amber
this plan calls a bug. A scheduling-delay probe was tried and rejected (it read flat, the
probe was wrong). A fixed-work slowdown probe fires in 0.2 s and clears in 0.1 s with 3.1x
separation, but it burns roughly 10% of a core continuously, which is disqualifying on
its own for a monitor. The recommended shape is two signals rather than one: utilisation
stays the cheap instant gate, and a saturation signal confirms, so nothing fires unless
the machine is both busy and delivering less. The confirmer is UNDER REVIEW with the
owner.

**Does GPU memory need live sampling? Yes, and the question conflated two key
families.** Read from the same `IOAccelerator` node on 2026-09-06:
`Alloc system memory` 9.15 GB, `In use system memory` 7.26 GB, while
`Device Utilization %` and `Renderer Utilization %` both read 0. The plan recorded
2.8 GB allocated and 1.3 GB in use earlier the same day, so the memory value moved 3.3x
within hours and a static read would be wrong most of the time. The utilisation keys
reading zero says nothing about the memory keys, which demonstrably track. Sample memory
live, and do not use utilisation from this node for anything.

**Does persisting expansion risk a panel too tall for a cramped menu bar? No.** The
window height is user-set and clamped 320 to 900 (`PanelController.swift:185-186`), and
positioning already clamps into `screen.visibleFrame` (`:210-212`). Expansion consumes
process-list space rather than growing the window. The narrow-display profile does not
need to force collapsed. The real risk is the opposite one, the process list hitting its
140 pt floor, and verification item 2 above now tests that.

## Still open, on an owner ruling

1. Which confirmer drives CPU severity, given the fixed-work probe's CPU cost.
2. Whether the per-core bar strip, which ships on by default today, moves into the CPU
   expanded state and so leaves the default view.
3. Whether the per-interface network breakdown, which renders unconditionally today,
   moves into the NET expanded state and so leaves the default view.

Questions 2 and 3 are gated by `rules/no-silent-ui-surface-deletion.md`: both surfaces
appeared in owner-reviewed rounds, so moving them out of the default view needs the
owner's approval rather than a plan sentence.

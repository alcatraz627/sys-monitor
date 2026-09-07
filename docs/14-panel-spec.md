# The panel: product spec, principles, and what it is for

Describes the dropdown panel as built at `fix/accuracy-and-fit` HEAD, the reasoning
that produced its current shape, and the job it does. Written to be held against the
running app: every claim below names where it lives, so a reviewer can falsify it
rather than agree with it.

Scope is the panel and the menu-bar glyph that opens it. Architecture, module map and
sampling internals are in [`00-overview.md`](00-overview.md) and not repeated here.

## 1. What the panel is

A 360 pt dropdown under a menu-bar glyph, showing what the machine is doing right now
and which processes are doing it. It has no window of its own, no Dock icon, and no
history beyond a rolling window measured in minutes. It is not Activity Monitor and
does not try to be: Activity Monitor is where you go to investigate, and this is where
you go to find out whether investigating is worth it.

The panel answers one question in three widening steps:

1. From the menu bar, without clicking: is anything wrong?
2. From the collapsed panel: which resource, and how bad?
3. From an expansion or the process list: what specifically, and can I act on it?

Every design decision below follows from keeping those three steps distinct, and from
making step 1 cost nothing.

## 2. Guiding principles

These are the rules the build actually follows. Each names the consequence you can see
in the product, because a principle with no visible consequence is decoration.

### 2.1 A light exists to be believed

Colour fires on evidence that the machine is in trouble, never on a number crossing a
line. The owner's own framing: the lights confirm a felt experience, so a steady amber
during ordinary operation is a failed trigger rather than a preference.

The consequence is two severity policies that are deliberately not percentages, both in
[`RateMath.swift`](../Sources/sys-monitor/Sampling/RateMath.swift):

- `memorySeverity` keys on reclaim evidence, meaning sustained page stalls, with the
  kernel's own `memorystatus` level acting as a floor that can raise the verdict but
  never lower it. Percent used stays the bar fill and the number, and colours nothing.
- `cpuSeverity` takes utilisation as a gate and the run queue as the confirmer. Neither
  works alone and both failures were measured. Utilisation alone calls a machine at 94%
  doing exactly what you asked it to alarming. Run queue alone is worse, because Darwin's
  `getloadavg` is a 1-minute average that took 21 s to cross the line under a 2x step and
  still read 0.80x cores a full minute after the load stopped.

The gate fixes the fall and not the rise. A hitch shorter than the averaging window still
reads calm. That is a known and accepted limit, recorded here rather than hidden: the only
instrument measured to catch it costs about 10% of a core continuously, which a monitor
should not spend.

### 2.2 One policy, every surface

The glyph, the panel, and the notification all ask the same function what colour a metric
is. This exists because they diverged twice and both times the product lied. The glyph
routes CPU through `RateMath.cpuSeverity` at
[`GlyphRenderer.swift:555`](../Sources/sys-monitor/Shell/GlyphRenderer.swift), and alerts
are gated on the same `MetricSeverity` rather than on raw fractions.

A reviewer should treat any fourth surface that computes its own colour as a defect,
whatever the code around it says.

### 2.3 Cost is paid only while you are looking

Two sampling tiers. Closed, the app samples only what the glyph needs. Open, it adds
process enumeration, power, battery, storage, load and per-interface network. Process
enumeration is the expensive operation and runs only in the open tier
(`SamplingCoordinator.swift:541`).

Rates always divide by measured `CLOCK_MONOTONIC` elapsed, never by nominal cadence, so
a tier switch or a timer stall cannot manufacture a spike. Each metric owns its own
clock (`RateMath.SampleClock`), which is what stops a panel reopen from dividing a whole
closed period of bytes by one tick.

### 2.4 Detail is opt-in, and the default view has a fixed budget

The panel's vertical space is the scarce resource. Four sections can expand, and the
collapsed height is treated as a budget that expansion may not spend. The heatmap alone
costs 125 pt against a 464 pt collapsed panel, which is the entire argument for
disclosure rather than always-on.

The tension this creates is real and worth stating plainly: a surface behind a caret is
a surface most users never see. Section 7 returns to it.

### 2.5 Aesthetic is settled and out of scope

Material, corner radius, padding, the 360 pt width, the identity colours per metric and
the green-amber-red ramp are fixed. Owner ruling, verbatim: the work is about what
information is shown, not about how it looks. A change that improves the look while
altering any of those is out of scope, not an improvement.

### 2.6 Say "not measured", never imply zero

`Metric<T>` is `.ok`, `.measuring`, or `.unavailable`, and the distinction is carried to
the surface rather than flattened. A private-framework failure degrades one feature and
leaves the rest working. The coverage row states how many processes the app cannot see
rather than quietly ranking the ones it can.

## 3. The flow

```
 menu bar glyph  ──click──▶  collapsed panel  ──click a header──▶  expansion
   is anything                which resource,                       what specifically
   wrong?                     how bad?                              is doing it
       │                            │                                     │
       │                            └──────── process list ───────────────┤
       │                              sort · filter · pin · expand · kill  │
       └── right-click ──▶ top consumer, without opening anything          ▼
                                                                       act or dismiss
```

The glyph is a live-drawn `NSImage`, not a `MenuBarExtra` label, because a plain
`MenuBarExtra` cannot render a custom per-tick glyph. It carries a user-chosen ordered
set of cells (CPU, MEM, NET, DISK, battery), each cell being a value plus a severity
colour, and it has a per-display width profile because the built-in display gives status
items 664 pt against an ultrawide's 3440.

Opening the panel switches the coordinator to the open tier. Closing it returns to idle
and drops per-core and per-process state so a stale value cannot be reused.

## 4. Surface spec

Each section: what it shows, where the number comes from, and what it costs.

### 4.1 Section headers

All four expandable sections use one `SectionHeader`
([`PanelRootView.swift`](../Sources/sys-monitor/UI/PanelRootView.swift)). The contract:

| Property | Value | Why |
|---|---|---|
| Caret position | Leading, before the label, in all four | The eye finds one control in one place. Before this was shared, CPU and MEM put it far right and NET and DISK put it after the label. |
| Hit target | The whole row | A 10 pt caret is not a hit target. |
| Hover | Row shades to `Color.primary.opacity(0.07)`, 12 ms ease | Nothing else said the header was clickable. |
| Layout impact | None | The shade is a background inset outward, not padding, so adopting it moved no pixel. |
| Expanded state | Persisted per section in `SettingsStore` | The panel reopens as you left it. |

### 4.2 CPU

Collapsed: label, pin toggle, current percentage coloured by `cpuSeverity`, a sparkline
of the history window on a fixed 0 to 100% scale, and a per-core bar strip.

Expanded: a per-core heatmap over the history window, one row per core, grouped by the
machine's real performance clusters read from `hw.perflevelN` rather than a hardcoded P
and E guess. On this machine that reports Super with 6 cores and Performance with 12,
which the conventional guess gets wrong in both the naming and the counts.

The sparkline and the heatmap answer different questions and that is why both exist. The
sparkline is aggregate shape over time. The heatmap is which core, and it is the only
encoding tested that makes a parked cluster read as a block rather than averaging away.

### 4.3 MEM

Collapsed: percentage and absolute used against total, coloured by `memorySeverity`, an
auto-scaled sparkline with range labels, and a text subtitle carrying swap, reclaim state
and kernel pressure.

The subtitle is text only. No dot, no second bar, no badge: the colour on the value is
the only visual signifier memory gets, and the subtitle says why that colour fired, which
a percentage cannot.

Expanded: the five pools as a composition bar plus figures. App is `internalBytes` and
never `activeBytes`, wired is `wiredBytes`, compressed is `compressedBytes`, cached files
is `externalBytes + purgeableBytes`, free is `freeBytes − speculativeBytes`. Naming the
wrong source here is how a previously fixed bug returns, so the sources are pinned by the
suite.

### 4.4 NET and DISK

One row, two independent cells, each with its own caret. They share a row but not a
question: one is about which process is talking, the other about which is reading.

Collapsed: directional throughput with coloured arrows, and a log-scaled sparkline.
Expanded: the top consuming processes for that metric.

Per-process network comes from the private NetworkStatistics framework behind a
degrade-to-unavailable adapter.

### 4.5 Storage, energy, load

Storage is a fill bar and free space from `statfs`, refreshed each open sweep. Energy is
system watts split CPU, GPU and ANE from IOReport. The load line carries the three load
averages and uptime. None of these expand; the plan specifies no content for their
expansions, so building one means designing it first.

### 4.6 Processes

The working area. A search field, a five-segment sort control (CPU, MEM, DISK, NET, PWR),
and a scrolling list.

| Capability | Detail |
|---|---|
| Sort | Any of the five metrics. PWR is per-process watts from `ri_energy_nj`, readable without root. |
| Filter | Free text on the name, or a threshold expression `>N:metric` / `<N:metric` where metric is cpu, mem, disk, net or pwr. Bare `>N` means CPU percent. Memory, disk and net take MB or MB/s; pwr takes watts. |
| Grouping | Optional collapse into process trees by root ancestor. |
| Pin | A pinned pid stays at the top of the list across sorts. |
| Row expansion | Per-process detail: owner, threads, parent, path, icon. |
| Kill | Real signal, from the row. |
| Hover | Freezes order, not values, so a row does not move out from under the pointer while its numbers keep updating. |
| Coverage | A status line states how many processes the app cannot see, rather than implying the visible set is everything. |

### 4.7 Panel behaviour

| Interaction | Behaviour |
|---|---|
| Click outside, Esc, Space switch | Closes, unless pinned |
| Pin | Holds the panel open against all three |
| Drag bottom edge | Resizes height, 320 to 900 pt, persisted. Width is locked at 360. |
| Double click anywhere | Nothing. `.resizable` is in the style mask for the height drag and brings AppKit's zoom with it, which re-framed the panel against its min and max and dropped it in the screen centre. `DropPanel.zoom` is overridden to a no-op. |
| Global hotkey | Opt-Cmd-M |
| Right-click the glyph | A menu headed by the current top consumer |
| Copy button | The whole current reading as text to the pasteboard |

## 5. Severity, stated once

| Metric | Colour keys on | Does not key on |
|---|---|---|
| CPU | Utilisation above the gate, confirmed by run queue per core | Utilisation alone |
| MEM | Sustained page stalls, floored by kernel pressure level | Percent used |
| Per-core strip | The `cpuWarn` and `cpuCritical` ramp | The two-signal policy above |

The third row is an inconsistency, not a design. It is listed here so a reviewer finds it
already named rather than discovering it as news. See section 8.

## 6. Non-goals

- Historical data beyond the rolling window. There is no database and no retention.
- Process management beyond kill. No renice, no suspend, no priority editing.
- Remote or multi-machine monitoring.
- Replacing Activity Monitor for investigation.
- Any change to the settled aesthetic in 2.5.

## 7. What it is for

The product has one job, and the several ways it gets used are the same job at different
depths rather than separate features.

You keep a machine under sustained load: builds, containers, a dev server, a browser with
too much in it. The failure this creates is not that the machine breaks. It is that the
machine gets slower and you do not notice, or you notice and cannot tell whether it is the
machine or the thing you are working on. That uncertainty is expensive, because the
cheapest response to a slow machine is to wait, and waiting is only correct if the
slowness is real and temporary.

So the glyph is a resting-state instrument. It sits in the menu bar and is meant to be
ignorable, which is exactly why 2.1 matters so much: an indicator that cries wolf gets
tuned out within a week and then the product has negative value, because you now believe
you have a monitor and do not. When it goes amber, the claim being made is specific. For
memory it is that the machine is faulting pages back in, which is the mechanism by which
a Mac with free-looking memory feels slow. For CPU it is that work is queuing rather than
merely running, which is the difference between a busy machine and an overloaded one.

Having believed the glyph, you open the panel, and the question changes from whether to
which. The collapsed view is sized for exactly that: four metrics with current value,
recent shape, and a plain-language subtitle where a number would be ambiguous. Most
openings end here, which is why the collapsed height has a budget and expansions are
opt-in.

When the collapsed view is not enough it is usually because an aggregate is hiding the
structure. This is the case the expansions exist for and each one targets a specific way
an average lies. A machine at 34% CPU may have one saturated cluster and one parked, and
the aggregate cannot show that while the heatmap shows it as a block. Memory at 81% means
nothing until you know whether it is your applications, the kernel's wired pages, or the
file cache doing its job, which is what the pools split answers. Throughput at 12 MB/s is
only actionable once you know which process owns it.

Then the process list is where you do something, and it is deliberately the largest part
of the panel. Sorting by the metric that is actually red gets you to the offender in one
click. Filtering by threshold gets you to it without reading. Pinning holds a suspect in
view while you work. Expanding a row tells you what the thing actually is when a name
like `node` or `mdworker` is not enough. Killing it ends the session without a trip to
another app.

The through-line is that every layer exists to make the next layer unnecessary. The glyph
should mean you do not open the panel. The collapsed panel should mean you do not expand.
The expansion should mean you do not need Activity Monitor. A layer that fires when it
should not, or hides what you needed, breaks the chain at that point and pushes the cost
up to you.

## 8. Known divergences from this spec

Listed so a reviewer can go past them rather than rediscover them.

1. **Expansions are collapsed on first run and nothing announces them.** `SettingsStore`
   reads the stored set as `?? []`, so a new install shows none of section 4's expanded
   content. Section 2.4's budget argument justifies opt-in detail; it does not justify a
   first run in which the flagship surface is undiscoverable.
2. **The per-core heatmap is empty when you open it.** `perCoreHistory` is appended only
   in `readFullCPU`, which only `openTick` calls, so nothing accrues while the panel is
   closed. At one column per second against a default 60 s window, or 120 s if configured,
   the heatmap needs the panel held open that long before it looks like section 4.2
   describes.
3. **The per-core strip uses the old ramp.** Section 5, row three. The strip predates the
   two-signal policy and still colours on `cpuWarn` and `cpuCritical`.
4. **`cpuWarn` carries two unrelated meanings.** It is the severity gate and the per-core
   strip's warn threshold, under one label that names one of them.
5. **`memWarn` and `memCritical` are orphaned.** Their sliders were removed when
   `memorySeverity` replaced the percent ramp, but the keys are still persisted and still
   read as the glyph's fallback when the memory sample is not `.ok`.
6. **NET and DISK cannot distinguish no traffic from not measured.** Section 2.6 states
   the principle; `ThroughputCell` does not receive the `Metric` state that would let it
   honour it.
7. **GPU memory is specified and not built.** `IOAccelerator` exposes allocated and
   in-use system memory sudolessly, and on unified memory that is a distinct claim on the
   same pool. Nothing in `Sources/` reads it.
8. **`--probe-panel` reports success for files it never wrote.** `main.swift:348` writes
   with `try?` and prints unconditionally, and nothing creates the target directory. This
   matters to a reviewer because it is the tool most likely to be used as evidence about
   the surfaces above.

## 9. How to check any of this

```bash
./build.sh --install                 # the copy launch-at-login resolves
sys-monitor --self-test              # math, persistence, sampler invariants, alerts
sys-monitor --probe-panel <existing dir>   # renders the panel cases to PNG
sys-monitor --probe                  # headless sampler readout
defaults read dev.sys-monitor.menubar      # what the running app actually persists
```

Two warnings about evidence. `--probe-panel` force-sets the expanded set and supplies a
synthetic pre-filled history, so it renders the ideal state of every surface and can never
fail on divergences 1 or 2. And a claim about what the app does is only true of
`~/Applications/sys-monitor.app`, which is the copy the login item resolves; verifying the
repo copy has produced a wrong answer before.

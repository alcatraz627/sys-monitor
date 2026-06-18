<div align="center">
  <img src="assets/cover.svg" alt="sys-monitor — htop-inspired macOS menu-bar system monitor" width="900">
</div>

<h1 align="center">sys-monitor</h1>

<p align="center">
  An htop-inspired macOS menu-bar system monitor — live CPU, memory, processes,
  network, disk, power and battery, in a tiny agent that stays out of its own way.
</p>

<p align="center">
  <img alt="Swift 5.9" src="https://img.shields.io/badge/Swift-5.9-orange?logo=swift&logoColor=white">
  <img alt="macOS 13+" src="https://img.shields.io/badge/macOS-13%2B-007AFF?logo=apple&logoColor=white">
  <img alt="Architecture" src="https://img.shields.io/badge/arch-Apple%20Silicon%20%7C%20Intel-555">
  <img alt="Idle CPU" src="https://img.shields.io/badge/idle%20CPU-~0%25-success">
  <img alt="Footprint" src="https://img.shields.io/badge/footprint-~60%20MB-3ddb84">
  <img alt="License" src="https://img.shields.io/badge/license-MIT-blue">
</p>

---

## What it is

A small, native macOS app that lives entirely in the menu bar. The icon is a
**live, configurable readout** — pick any of CPU, memory, network, disk, and
battery and order them however you like. Click it for a SwiftUI panel with what
htop puts on one screen — overall + per-core CPU, memory + swap + pressure,
top processes, network and disk throughput, storage, Apple-Silicon power, and
battery — plus rolling sparklines and a process list you can sort, filter, pin,
and act on.

It's designed to be **left running all day without measurably adding to the
load it measures**. The sampling is two-tier: a cheap always-on tick that feeds
only the menu-bar glyph, and an expensive tick that runs **only while the panel
is open**. Idle CPU is effectively zero; the footprint is ~60 MB. (See
[`docs/11-perf-audit.md`](docs/11-perf-audit.md) for the measured numbers.)

No external dependencies — just AppKit, SwiftUI, Combine, IOKit, and Darwin.
One binary, no sandbox (a deliberate trade for unrestricted process
enumeration), no root, no entitlements.

---

## Install

Three ways in, depending on what you want.

### 1. Just run it (download)

Grab the latest `sys-monitor-X.Y.Z.zip` from the
[**Releases**](https://github.com/alcatraz627/sys-monitor/releases/latest) page,
unzip, and move `sys-monitor.app` to **`/Applications`** (or `~/Applications` —
a stable location keeps Launch-at-Login valid).

> **Gatekeeper note.** Unless a release is explicitly marked *notarized*, the
> build is ad-hoc signed, so macOS quarantines downloaded copies. Clear it once:
> ```bash
> xattr -dr com.apple.quarantine /Applications/sys-monitor.app
> ```
> (Or right-click the app → **Open** → **Open**.) This is a one-time step per
> download; nothing about the app needs root or special permissions.

Open it — a gauge appears in the menu bar. Click it to drop the panel.

### 2. Build it from source

You need the **Xcode Command Line Tools** (`xcode-select --install`) — full
Xcode is not required. macOS 13 (Ventura) or newer.

```bash
git clone https://github.com/alcatraz627/sys-monitor.git
cd sys-monitor
./build.sh --run            # compile → assemble .app → ad-hoc sign → launch
cp -R sys-monitor.app /Applications/   # optional: keep it for Launch-at-Login
```

A locally-built app isn't quarantined, so there's no Gatekeeper step. Build
takes a few seconds; `./build.sh` (no `--run`) just produces the bundle.

### 3. Develop on it

```bash
./build.sh --dev            # isolated dev instance (separate bundle, "·dev"
                            # badge, auto-quits) — won't disturb a running copy
./build.sh --dev-stop       # quit the dev instance
sys-monitor --self-test     # the regression suite (math, settings, samplers)
sys-monitor --probe         # headless sampler readout
tools/drills/               # timed behavioral drills
```

Start with [`docs/README.md`](docs/README.md) for the design docs. The dev
build is fully isolated from any copy you run day-to-day; see
[`RELEASING.md`](RELEASING.md) for cutting a release.

**Requirements:** macOS 13+. Apple Silicon gets everything; on Intel the power
and per-cluster signals report "unavailable" and the rest works normally — the
private-framework readers degrade gracefully if a source isn't present.

---

## Features

**Menu bar.** Choose and reorder any of CPU · Memory · Network · Disk ·
Battery. CPU/MEM render as icon · progress-bar · `%`; NET/DISK as icon · ↓ / ↑
throughput; Battery as a level glyph · `%`. Fixed identity colors per metric so
the cells read like wifi/battery icons; load colors (green → orange → red) at
**adjustable** thresholds; optional compact density; throughput in **bytes/s or
bits/s**. Right-click for a menu with the current top CPU consumer + Settings +
Quit. A **global hotkey (⌥⌘M)** toggles the panel from anywhere.

**Panel.** CPU (value + sparkline + per-core strip), memory + swap + pressure,
system network + disk throughput (with a **per-interface breakdown** when more
than one interface is active), **storage** (free / total on the boot volume),
**energy** (per-block power in watts on Apple Silicon + battery state), a
**process list**, a load-average + uptime footer, and a self-cost readout (the
monitor's own honest footprint — the budget canary).

**Process list.** Top-N by CPU / memory / disk / network. **Filter** by name,
pid, or threshold (`>5:cpu`, `<300:mem`, `>1:disk`, `>1:net`). **Pin** a process
to keep it on top regardless of rank. Expand a row for its path + actions:
**Terminate / Force-Kill** (two-step; falls back to copying the `sudo`
command if denied), **Focus** the app, **Copy path**, **Reveal in Finder**.
EMA-smoothed ranking so the tail doesn't slot-machine; freeze-on-hover pauses
re-sorting while you read.

**Alerts.** Opt-in notifications when CPU or memory stays above a threshold for
a sustained window — the one thing that's useful while the panel is closed.
Debounced + cooldown so it speaks once, not every tick.

**Footer actions.** Settings · copy a text snapshot of all readings · open
Activity Monitor · quit.

**Settings** (all live, no apply step): sampling cadences, menu-bar cells +
order, throughput unit, severity thresholds, alerts, process count + default
sort, sparkline history window (60–300 s), panel display toggles (sparklines,
per-core strip, coverage row, compact glyph), launch-at-login, reset-to-defaults.

**Lifecycle.** Sleep/wake and display-sleep re-baseline so the first sample
after a gap never shows a bogus spike; occlusion drops to the idle tier without
dismissing.

---

## Architecture (short version)

```
┌──────────────── sys-monitor.app (.accessory, LSUIElement) ────────────────┐
│  AppKit shell (main thread)            Sampling core (serial bg queue)     │
│  ┌─────────────────────────┐           ┌──────────────────────────────┐    │
│  │ NSStatusItem            │   tier    │ SamplingCoordinator          │    │
│  │  └ button.image =       │   cmds    │  ├ idle / open timers        │    │
│  │    GlyphRenderer.draw()  │◀────────▶│  ├ rate math vs measured Δt   │   │
│  │ NSPanel + NSHostingView │           │  └ samplers (raw counters):   │    │
│  │  └ SwiftUI PanelRootView│           │     CPU·Mem·Proc·Net·Disk·     │    │
│  └────────────┬────────────┘           │     Power·Battery·Storage·Load │   │
│               │ Combine sink            └──────────────┬───────────────┘    │
│  ┌────────────▼────────────────────────────────────────▼─────────────┐    │
│  │ MetricsStore @MainActor → @Published snapshot (immutable, Sendable)│    │
│  └────────────────────────────────────────────────────────────────────┘    │
└──────────────────────────────────────────────────────────────────────────┘
```

Load-bearing decisions: a hybrid `NSStatusItem`-glyph + SwiftUI-panel shell (a
plain `MenuBarExtra` can't render a live custom glyph); all sampling isolated on
one serial queue with only an immutable `MetricsSnapshot` crossing to the main
thread; every rate divided by *measured* `CLOCK_MONOTONIC` elapsed (not nominal
cadence) so tier switches and jitter are correct by construction; private
frameworks reached via `dlsym` behind degrade-to-unavailable adapters.
Full detail in [`docs/03-implementation.md`](docs/03-implementation.md).

---

## Performance

Idle (panel closed) CPU is ~0%; open-tier CPU is sub-1%; footprint is ~60 MB
(physical, the number Activity Monitor shows), with no leak — RSS shrinks back
when the panel closes. The expensive work (process enumeration, power) runs
only while the panel is open. Full measured breakdown and the ranked findings
are in [`docs/11-perf-audit.md`](docs/11-perf-audit.md).

---

## Documentation

[`docs/README.md`](docs/README.md) indexes everything — the current references
(spec, behavior, implementation, manual-checks, perf audit) and the historical
design records (v2 / v2.1 plans, audits, external research). Runtime regression
coverage is `sys-monitor --self-test` plus the drills in `tools/drills/`.

---

## Status

v1, v2, and v2.1 shipped — the full feature set above is live. The one piece
held back: a **per-cluster CPU-frequency (GHz) panel row** — the IOReport
engine and a `--probe-freq` validation tool exist, but the residency→frequency
alignment needs validation against `powermetrics` before it's wired, so it
isn't shown rather than risk a misleading number (see the perf audit + the
spike notes). The App Store is a non-goal: the private APIs that power the
power and per-process-network features are load-bearing and wouldn't pass
review, but they're fine for direct distribution.

---

## License

[MIT](LICENSE) — use, modify, and distribute freely. If you distribute a built
`.app` to non-technical users without the quarantine step, notarize it with
your own Developer ID (see [`RELEASING.md`](RELEASING.md)).

---

## Acknowledgements

- [`htop`](https://htop.dev/) — the interaction model and information-density target.
- [`exelban/stats`](https://github.com/exelban/stats) — reference for the mach-API sampling patterns.
- [`macmon`](https://github.com/vladkens/macmon) / socpowerbud — the sudoless IOReport power + frequency call sequence.
- The Apple Developer Forums threads on `host_processor_info` / `IOBlockStorageDriver` / `proc_pidinfo` — the honest source on which APIs work from user space without the sandbox.

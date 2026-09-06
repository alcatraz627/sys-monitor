# Parity baseline, before the accuracy and fit work

Captured 2026-09-06 on the tree at `4ddfac6`, branch `fix/accuracy-and-fit`, before any
change. This is what the validation gate measures against. Anything recorded here as
working must still work afterwards; anything recorded as wrong is what the work is for.

Machine: Apple M5 Pro, 18 logical cores, 64 GiB, macOS 26.6.2, uid 501, no root.
Binary: ad-hoc signed, unsandboxed, `LSUIElement`.

## Green baseline

```
.build/release/sys-monitor --self-test   ->  ALL PASS, 115 assertions
swift build -c release                   ->  Build complete
```

115 is the number to beat. A later run with fewer passing assertions means something was
dropped, not that the suite got faster.

## Behaviour that must survive unchanged

These are correct today. The gate should try to break them.

| Surface | Current behaviour | Evidence |
|---|---|---|
| Per-process CPU | Δ(`pti_total_user`+`pti_total_system`) / Δwall in ns, fraction of one core, may exceed 1.0 | `SamplingCoordinator.swift:709`; audit finding 10 |
| Overall CPU | Equal-weight mean across 18 cores, 15.32% vs `top` 15.35% | audit finding 10, CONFIRMED |
| Process rate clock | `readProcesses` keeps its own elapsed clock, not the shared per-tick one | `SamplingCoordinator.swift:659` |
| Tick wrap | `RateMath.cpuUtilization` deltas with `&-` | audit cleared list |
| Elapsed | `CLOCK_MONOTONIC`, never nominal cadence | `RateMath` header |
| Per-core dealloc | `vm_deallocate` of the kernel array every open tick | `CPUSampler.swift` defer block |
| Display name | `NSRunningApplication.localizedName`, then path-walk past version-like segments | `PanelRootView.resolveDisplayName` |
| Self footprint | Reads `phys_footprint`, not RSS | commit `566d9bc` |
| Disk row | Sums all `IOBlockStorageDriver` nodes, op counts match `top` to 115 | audit finding 11 |
| Power row | `CPU Energy` equals MCPU0+MCPU1+PCPU exactly; GPU nJ and mJ agree to 0.4% | audit finding 9 |
| Glyph render skip | Identical frames skip the `NSImage` rebuild via `renderKey` | `StatusItemController.swift` |
| Width stability | Glyph width does not change with value magnitude | `GlyphRenderer` reserved columns |

That last row is the one most at risk from the menu-bar work. Narrowing the glyph must
not reintroduce per-tick width jitter, because a status item that changes width shifts
every neighbour on every tick.

## Behaviour that is wrong, with the number to move

| # | Surface | Now | Target |
|---|---|---|---|
| 2 | Per-process memory | `pti_resident_size` (RSS) | `ri_phys_footprint` |
| 3 | System memory used | `active+wired+compressed` = 30.47 GiB | `(internal−purgeable)+wired+compressed` = 32.89 GiB |
| 6 | NET/DISK first tick after reopen | all bytes since close ÷ ≤2 s; measured 10741 MB/s disk, 308 MB/s net | true rate, or `.measuring` |
| 7 | Per-process net after reopen | flows open at close read 0 B; qbittorrent 7.3 MB/s read 0 for 13 s | keeps counting |
| 9 | Glyph on notched display | 411 pt against a 664 pt strip, 62% | fits with room |
| 12 | Process attribution | flat list; Chrome 3853 MB across 41 procs shows as 245 MB | rolled up |
| 13 | Process coverage | 620 of 941 pids; comment claims "ALL processes" | stated honestly |
| 14 | CPU colour | fires on utilisation, so 94% busy and responsive reads alarming | run queue above a utilisation gate |
| 15 | Memory colour | fires at 75% used, so 71% while thrashing reads calm | reclaim evidence, no percent trigger |

### Confirmed live, 2026-09-06

Row 3 shipped and was checked against the running app rather than the suite.
With `vm_stat` reading app 1588915, wired 237502, compressor-occupied 1523
pages at 16 KiB, the new build's glyph read 44% and the old build's read 35%
on the same machine at the same moment. The old formula was under-reporting by
5.4 GiB.

Rows 14 and 15 shipped the same day. The instrument behind row 14 was measured
before it was trusted: `getloadavg` on Darwin took 21 s to cross the saturation
line under a 2x step load and still read 0.80x cores a full minute after the
load stopped. That decay is why the trigger is gated on utilisation rather than
driven by the queue alone; a quiet machine drops below the gate within one tick
and the colour clears regardless of what the one-minute average still says.
Mach's `PROCESSOR_SET_LOAD_INFO` was tried as a faster source and rejected:
`processor_set_statistics` segfaults on the unprivileged name port.

### Reference measurements at baseline

Per-process, RSS against `/usr/bin/footprint -p`, same second:

| pid | process | RSS | footprint | ratio |
|---|---|---|---|---|
| 1519 | Firefox GPU Helper | 167 MB | 599 MB | 0.28 |
| 735 | WallpaperMacintoshExtension | 34 MB | 355 MB | 0.09 |
| 680 | ghostty | 326 MB | 430 MB | 0.76 |
| 17714 | Google Chrome | 1022 MB | 540 MB | 2.02 |
| 925 | mediaanalysisd | 366 MB | 19 MB | 19.41 |

Ratio spans 0.09 to 19.41 and crosses 1.0, so no scale factor can fix it.

System memory, from `vm_stat` at 16384-byte pages:

```
active 1789887  inactive 1727985  speculative 342149  wired 204953
anonymous 1981932  file-backed 1878089  purgeable 33630  compressor-occupied 2045

app formula  : 1789887 + 204953 + 2045 = 1996885 pages = 30.47 GiB
Activity Mon : (1981932 - 33630) + 204953 + 2045 = 2155300 pages = 32.89 GiB
identity     : active + inactive + speculative = 3860021 = anonymous + file-backed  (exact)
```

Process coverage:

```
total pids listed : 941
taskinfo SUCCEEDS : 620
taskinfo FAILS    : 321
  pid 1   launchd      DENIED
  pid 401 WindowServer DENIED
```

Glyph widths, computed from `GlyphDensity` and confirmed against a menu-bar screenshot
(measured span ≈395 pt for the 4-cell standard configuration):

| config | standard | compact |
|---|---|---|
| `[cpu,mem]` | 161 pt | 119 pt |
| `[cpu,mem,net,disk]` | 411 pt | 321 pt |
| `[cpu,mem,net,disk,battery]` | 458 pt | 353 pt |

Display geometry:

```
LG ULTRAWIDE        3440 x 1440, safeAreaInsets.top 0.0,  no notch
Built-in Retina     1512 x  982, safeAreaInsets.top 32.0, notch 185 pt
                    auxiliaryTopLeftArea 663 pt · auxiliaryTopRightArea 664 pt
```

## Cost of the changes, measured

Process grouping added a third `proc_pidinfo` call per pid
(`PROC_PIDT_SHORTBSDINFO`, for `ppid`) alongside the existing taskinfo and
rusage calls. Measured over 12 full enumerations of ~620 visible pids:

```
machine busy   1.57 -> 1.66 ms   (+0.08 ms, +5%)
quiet          1.11 -> 1.18 ms   (+0.08 ms, +7%)
quiet          1.02 -> 1.10 ms   (+0.08 ms, +8%)
quiet          0.97 -> 1.05 ms   (+0.07 ms, +8%)
duty cycle at one enumeration per 2 s: about 0.05% -> 0.055% of one core
```

**Quote the absolute figure, not the percentage.** The added cost is a stable
+0.07 to +0.08 ms per enumeration across every run. The RATIO is not a property of
the change: it moves from 5% to 8% purely because a loaded machine inflates the
baseline it is divided by. An earlier draft of this doc reported "+5%" from a single
busy-machine run, which understated it.

A concurrent reviewer measured +0.15 to +0.3 ms by comparing medians of separate
with-and-without runs. That method is exposed to drift between runs; the figures above
interleave both variants inside one process so drift cancels. The disagreement is
methodological rather than a dispute about the code, and the interleaved absolute
number reproduced four times across different machine loads.

Process enumeration runs on the open tier only, so the idle budget that the
leave-it-running requirement protects is untouched. The memory fixes add no
syscalls at all: `ri_phys_footprint` rides the `proc_pid_rusage` call the
sampler already made, and the system formula reads four more fields from the
`vm_statistics64` struct already fetched.

## Deliberate non-goals

Recorded so the gate does not flag them as omissions.

- Fan control. Needs a signed SMJobBless helper, which collides with the ad-hoc unsigned
  distribution decision. Reading sensors is in scope later; control is not.
- Full process coverage. Needs the `com.apple.system-task-ports.read` entitlement. Out
  of scope; the fix is to state the limit, not remove it.
- Absolute frequency validation. Needs `sudo powermetrics`.
- The module seam refactor and new capabilities. Sequenced after this work.

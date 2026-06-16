# Behavioral drills

Committed, repeatable versions of the runtime checks that exercise the
**running** app and assert on its `os.Logger` output — the things the
build-time `--self-test` suite can't reach (tier transitions, induced-state
response, suspend/resume, soak stability).

Before this directory existed, every drill was hand-built in a shell and
discarded; each session re-derived the same scaffolding. These are the
durable form.

## Run

```sh
./build.sh                    # required — drills use .build/release/sys-monitor
tools/drills/run-all.sh       # the log-assertable suite
tools/drills/soak.sh 300      # individual drill (5-min soak)
```

| Drill | Asserts | Notes |
|-------|---------|-------|
| `transitions.sh` | NET/DISK never blank on a tier transition (FB-2/FB-4) | the recurring regression |
| `pressure.sh` | app observes `pressure -> warn` then `-> normal` | uses `memory_pressure -l warn` (no root) |
| `display-sleep.sh` | sampling suspends on display sleep, resumes on wake | **really sleeps your display ~2 s** |
| `soak.sh [secs]` | no crash, no out-of-order drops, RSS bounded | pre-commit safety net |

## What these do NOT cover (by design)

- **Pixels.** Whether the POWER row / sparklines / self-cost / coverage row
  actually *render* is a human glance — drills assert behavior via logs, not
  appearance. Keep using the human-glance checklist for visual confirmation.
- **High-rate network attribution.** Needs a real (un-throttled) network and
  is subject to the relay-attribution platform limit; verify by hand.
- **Pure math** (RateMath, formatBps, gap logic) — covered by
  `sys-monitor --self-test`, which is cheaper and runs at build time.

## Conventions (the hard-won bits)

- The app must be launched with `SYSMON_TEST_HOOKS=1` (enables the SIGUSR1
  panel toggle) and `SYSMON_DEBUG=1` (per-tick state log). `lib.sh` does this.
- Assert on the `tier=open|idle` log field, **never** on SIGUSR1 toggle
  count — the toggle is parity-blind (a stray click flips intent).
- `/usr/bin/log stream` (not `log show`) for `os.Logger`; `/usr/bin/log` and
  `/bin/cat` explicitly, since this machine aliases `cat`→glow / shadows `log`.
- New field bug → add its reproducing drill here before the fix (the
  bug→drill discipline). The fix is proven by the drill flipping, not by
  re-reading the diff.

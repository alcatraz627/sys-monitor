# sys-monitor docs

**Start here:** [`00-overview.md`](00-overview.md) — the current architecture and
module map (what the code is *today*).

The rest splits into the **v1 design narrative** (the planning-first record the
project was built from — accurate as history, but predates v2/v2.1 features) and
**specialized current references**.

## Current

| Doc | What it is |
|-----|------------|
| [00-overview.md](00-overview.md) | **Current** architecture + per-module map + feature→file index |
| [09-manual-checks.md](09-manual-checks.md) | The human-glance checklist — pixel/interaction items automated checks can't cover |
| [11-perf-audit.md](11-perf-audit.md) | Measured footprint + ranked findings (2026-06-18) |

Runtime regression coverage is the binary itself: `sys-monitor --self-test`
(math, settings persistence, sampler invariants, alert state machine) and the
timed drills in `tools/drills/`.

## v1 design narrative (planning-first record)

These describe the v1 build's *intent*; their module inventories are superseded
by `00-overview.md` but the reasoning is still the best "why is it like this."

| Doc | What it is |
|-----|------------|
| [01-spec.md](01-spec.md) | v1 goals, non-goals, requirements, data sources |
| [02-behavior.md](02-behavior.md) | v1 state machine: idle ↔ open tier, re-baseline triggers, every flow |
| [03-implementation.md](03-implementation.md) | v1 module breakdown, sampler protocol, publish path, panel event routing |

## Historical (point-in-time, not maintained)

| Doc | What it was |
|-----|-------------|
| [04-acceptance.md](04-acceptance.md) | v1 acceptance sweep (superseded by 09 + 11) |
| [05-v2-plan.md](05-v2-plan.md) | v2 roadmap — all phases shipped |
| [06-architecture-audit.md](06-architecture-audit.md) | v2 independent architecture audit |
| [07-perf-ux-findings.md](07-perf-ux-findings.md) | v2 perf/UX findings sweep |
| [08-external-research.md](08-external-research.md) | Survey of other monitors (stats, htop, macmon, etc.) |
| [10-v2.1-plan.md](10-v2.1-plan.md) | v2.1 scope — all items shipped (one deferred: the per-cluster GHz panel row) |

## Installing / releasing

- End users and builders: the top-level [README](../README.md).
- Cutting a release (signing, notarization, GitHub Releases): [RELEASING.md](../RELEASING.md).

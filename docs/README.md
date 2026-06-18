# sys-monitor docs

Two kinds of document live here: **current references** that describe how the
app works today, and **historical records** (dated design docs and plans) kept
for provenance. If you're contributing, read the current set; the historical
set explains *why* things are the way they are.

## Current (describes the app as it is)

| Doc | What it is |
|-----|------------|
| [01-spec.md](01-spec.md) | Goals, non-goals, requirements, data sources |
| [02-behavior.md](02-behavior.md) | State machine: idle ↔ open tier, re-baseline triggers, every flow |
| [03-implementation.md](03-implementation.md) | Module breakdown, sampler protocol, publish path, panel event routing |
| [09-manual-checks.md](09-manual-checks.md) | The human-glance checklist — pixel/interaction items automated checks can't cover |
| [11-perf-audit.md](11-perf-audit.md) | Measured footprint + ranked findings (2026-06-18) |

Runtime regression coverage is the binary itself: `sys-monitor --self-test`
(the math + settings persistence + sampler invariants) and `tools/drills/`
(timed behavioral drills).

## Historical (provenance — point-in-time, not maintained)

| Doc | What it was |
|-----|-------------|
| [04-acceptance.md](04-acceptance.md) | v1 acceptance sweep (superseded by 09 + 11) |
| [05-v2-plan.md](05-v2-plan.md) | v2 roadmap — all phases shipped |
| [06-architecture-audit.md](06-architecture-audit.md) | v2 independent architecture audit |
| [07-perf-ux-findings.md](07-perf-ux-findings.md) | v2 perf/UX findings sweep |
| [08-external-research.md](08-external-research.md) | Survey of other monitors (stats, htop, macmon, etc.) |
| [10-v2.1-plan.md](10-v2.1-plan.md) | v2.1 scope — all items shipped (one deferred: the per-cluster GHz panel row) |

## Installing / releasing

- End users and builders: see the top-level [README](../README.md).
- Cutting a release (signing, notarization, GitHub Releases): [RELEASING.md](../RELEASING.md).

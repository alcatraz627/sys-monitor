#!/usr/bin/env bash
# FB-2 / FB-4 regression drill: a tier transition must NOT blank NET/DISK.
# Opens and closes the panel and asserts that, across the captured ticks,
# no OPEN-tier tick reports net=meas or disk=meas after the baseline — the
# signature of the transition-gap misclassification that blanked the
# throughput cells on panel-open and settings-change.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
source ./lib.sh
trap drill_cleanup EXIT
drill_require_bin

start_app
toggle_panel                     # → open (parity-blind; we assert on tier=, not count)
wait_for_log "tier=open" 10 || { fail "panel never entered open tier"; exit 1; }
sleep 5                          # let several open ticks accrue
toggle_panel                     # → close
sleep 3

# Drop the first two open ticks (legitimate baseline), then assert the rest
# kept net/disk = ok (never flipped to meas mid-open).
open_ticks=$(log_lines "tier=open")
bad=$(echo "$open_ticks" | tail -n +3 | rg -c "net=meas|disk=meas" || true)
echo "--- open-tier ticks captured ---"; echo "$open_ticks" | sed -E 's/.*sampling\] //' | tail -6

if [ "${bad:-0}" -eq 0 ]; then
    pass "no NET/DISK blanking on transition (FB-2/FB-4 held)"
else
    fail "$bad open-tier tick(s) blanked NET/DISK — transition-gap regression"
fi
exit $DRILL_FAILED

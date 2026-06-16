#!/usr/bin/env bash
# Memory-pressure drill (Phase 1.1): induce real warn-level pressure and
# assert the app's sysctl poll observes the transition, then the relief.
# Uses `memory_pressure -l warn` (real allocation, unprivileged) — NOT -S
# (which needs root). Reaches kernel warn in ~20–40 s on a large-RAM Mac.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
source ./lib.sh
trap 'kill $MP 2>/dev/null; drill_cleanup' EXIT
drill_require_bin

start_app
memory_pressure -l warn > /dev/null 2>&1 &
MP=$!

if wait_for_log "pressure -> warn" 45; then
    pass "observed pressure -> warn"
else
    fail "never observed warn (machine may not have reached warn in 45s)"
fi
kill "$MP" 2>/dev/null
if wait_for_log "pressure -> normal" 20; then
    pass "observed pressure -> normal after relief"
else
    fail "never returned to normal"
fi
echo "--- pressure transitions ---"; log_lines "pressure ->" | sed -E 's/.*sampling\] //'
exit $DRILL_FAILED

#!/usr/bin/env bash
# Run the behavioral drill suite in sequence; non-zero if any drill fails.
# Each drill launches the app, drives it, and asserts on its log output.
# These are the log-assertable behaviors; purely-visual checks (does the
# POWER row render?) stay in the human-glance checklist, not here.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

[ -x "../../.build/release/sys-monitor" ] || { echo "run ./build.sh first"; exit 2; }

drills=(transitions.sh pressure.sh display-sleep.sh soak.sh)
fails=0
for d in "${drills[@]}"; do
    echo "════════════════════════════════════════════  $d"
    bash "./$d" || { fails=$((fails+1)); echo ">>> $d FAILED"; }
    echo
done
echo "════════════════════════════════════════════"
if [ "$fails" -eq 0 ]; then echo "ALL DRILLS PASSED"; else echo "$fails DRILL(S) FAILED"; fi
exit $((fails > 0 ? 1 : 0))

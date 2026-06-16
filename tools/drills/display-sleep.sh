#!/usr/bin/env bash
# Display-sleep drill (Phase 2.4): sampling must suspend when the display
# sleeps and resume (re-baselined) on wake. `pmset displaysleepnow` blanks
# the display; `caffeinate -u` wakes it. WARNING: this really sleeps your
# display for a couple seconds.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
source ./lib.sh
trap drill_cleanup EXIT
drill_require_bin

start_app
sleep 2
pmset displaysleepnow
sleep 4
caffeinate -u -t 2
sleep 4

if log_lines "sampling suspended" | rg -q .; then pass "suspended on display sleep"
else fail "no suspend logged"; fi
if log_lines "sampling resumed" | rg -q .; then pass "resumed on display wake"
else fail "no resume logged"; fi
echo "--- suspend/resume ---"; log_lines "suspended|resumed" | sed -E 's/.*sampling\] //'
exit $DRILL_FAILED

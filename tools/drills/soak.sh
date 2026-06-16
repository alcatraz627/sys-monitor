#!/usr/bin/env bash
# Soak drill: run with the panel open for N seconds (default 180) and assert
# stability — no crash report, no out-of-order snapshot drops, RSS bounded.
# The pre-commit safety net. Usage: ./soak.sh [seconds]
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
source ./lib.sh
trap drill_cleanup EXIT
drill_require_bin

DUR="${1:-180}"
START=$(date +%s)
start_app
toggle_panel                     # open tier — the expensive path
wait_for_log "tier=open" 10 || echo "  (note: panel didn't open; soaking idle tier)"

rss0=$(ps -o rss= -p "$APP_PID" 2>/dev/null | xargs)
echo "soaking ${DUR}s (panel open)…  RSS0=${rss0}KB"
sleep "$DUR"

rss1=$(ps -o rss= -p "$APP_PID" 2>/dev/null | xargs)
alive=$(pgrep -x sys-monitor | head -1)
drops=$(log_lines "dropped out-of-order" | wc -l | xargs)
crash=$(crash_check "$START")

[ -n "$alive" ] && pass "still alive after ${DUR}s" || fail "process died during soak"
[ -z "$crash" ] && pass "no crash report" || fail "crash report: $crash"
[ "${drops:-0}" -eq 0 ] && pass "zero out-of-order snapshot drops" || fail "$drops ordering drops"
# RSS growth > 50% over a few minutes would signal a leak.
if [ -n "$rss0" ] && [ -n "$rss1" ] && [ "$rss0" -gt 0 ]; then
    grow=$(( (rss1 - rss0) * 100 / rss0 ))
    echo "  RSS ${rss0}KB → ${rss1}KB (${grow}%)"
    [ "$grow" -lt 50 ] && pass "RSS bounded (<50% growth)" || fail "RSS grew ${grow}% — possible leak"
fi
exit $DRILL_FAILED

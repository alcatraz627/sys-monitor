#!/usr/bin/env bash
# Shared helpers for the sys-monitor behavioral drills.
#
# These exercise the RUNNING app and assert on its os.Logger output — the
# things a unit test can't reach (tier transitions, induced-state response,
# suspend/resume, soak stability). They are the committed, repeatable form
# of the drills that were hand-built and discarded each session.
#
# Hard-won environment notes baked in here:
#   • os.Logger lines are STREAM-only — use `/usr/bin/log stream`, never
#     `log show`. And `/usr/bin/log` / `/bin/cat` explicitly: this machine
#     aliases `cat`→glow and shadows `log`, which mangles piped data.
#   • The panel toggle (SIGUSR1) is parity-BLIND — a stray click inverts
#     open/close intent. Never assert on toggle COUNT; assert on the
#     `tier=open|idle` field the debug log emits.
#   • Requires a build first: ./build.sh   (uses .build/release/sys-monitor)
set -uo pipefail

SUBSYS="dev.sys-monitor.menubar"
BIN="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/.build/release/sys-monitor"
LOG=""
APP_PID=""
STREAM_PID=""

drill_require_bin() {
    [ -x "$BIN" ] || { echo "FAIL: $BIN missing — run ./build.sh first"; exit 2; }
}

# start_app [extra-env...] — launch with test hooks + debug logging, return via $APP_PID
start_app() {
    pkill -x sys-monitor 2>/dev/null; sleep 1
    LOG="$(mktemp -t sysmon-drill)"
    /usr/bin/log stream --predicate "subsystem == \"$SUBSYS\"" --info --debug --style compact > "$LOG" 2>&1 &
    STREAM_PID=$!
    sleep 1
    SYSMON_TEST_HOOKS=1 SYSMON_DEBUG=1 "$BIN" > /dev/null 2>&1 &
    APP_PID=$!
    disown "$STREAM_PID" "$APP_PID" 2>/dev/null   # silence the shell's job-death notices on cleanup
    sleep 3
}

toggle_panel() { kill -USR1 "$APP_PID" 2>/dev/null; }

# wait_for_log <regex> <timeout_s> — true if the pattern appears in the stream
wait_for_log() {
    local pat="$1" timeout="${2:-15}" i=0
    while [ "$i" -lt "$timeout" ]; do
        rg -q "$pat" "$LOG" 2>/dev/null && return 0
        sleep 1; i=$((i+1))
    done
    return 1
}

log_lines() { rg "$1" "$LOG" 2>/dev/null; }

drill_cleanup() {
    kill "$APP_PID" "$STREAM_PID" 2>/dev/null
    [ -n "$LOG" ] && /bin/rm -f "$LOG" 2>/dev/null
    pkill -x sys-monitor 2>/dev/null
}

# crash_check — non-zero if a fresh crash report appeared during the drill
crash_check() {
    local since="$1"
    find "$HOME/Library/Logs/DiagnosticReports" -name 'sys-monitor-*.ips' -newermt "@$since" 2>/dev/null | head -1
}

pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; DRILL_FAILED=1; }
DRILL_FAILED=0

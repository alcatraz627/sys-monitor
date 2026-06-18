#!/bin/bash
# Build sys-monitor.app from the SwiftPM workspace.
#
# SPM emits a bare executable under .build/<config>/. Menu-bar apps need a
# real .app bundle so LSUIElement is honored (otherwise the app shows in
# the Dock). This script wraps the executable into Contents/MacOS plus
# Contents/Info.plist, then ad-hoc-signs so a quarantined unsigned bundle
# still launches.
#
# Usage:
#   ./build.sh                  release build, assembles ./sys-monitor.app
#   ./build.sh debug            debug build
#   ./build.sh --run            build + open ./sys-monitor.app
#   ./build.sh --dev            build + launch an ISOLATED dev instance
#                               (.build/dev/sys-monitor-dev.app, distinct bundle
#                               id + executable, auto-quits after a timeout) —
#                               never touches ./sys-monitor.app, so your own
#                               running instance is left alone
#   ./build.sh --dev-stop       quit the isolated dev instance (only it)
#
# Why --dev exists: re-signing/overwriting ./sys-monitor.app in place SIGKILLs a
# running instance (invalidated code signature), and a path-based pkill of the
# shared bundle kills your real widget too. --dev keeps all of that off in a
# separate bundle that also self-terminates, so it can't be left running.

set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="sys-monitor"
APP_DIR="${APP_NAME}.app"
EXEC_NAME="${APP_NAME}"

# Isolated dev bundle — distinct dir, executable name, and bundle id so neither
# launch nor pkill ever collides with the real ./sys-monitor.app.
DEV_DIR=".build/dev/sys-monitor-dev.app"
DEV_EXEC="sys-monitor-dev"
DEV_AUTOQUIT="${SYSMON_DEV_AUTOQUIT:-600}"   # seconds; the can't-be-left-running guard

CONFIG="release"
RUN_AFTER=0
DEV=0
DEV_STOP=0
for arg in "$@"; do
    case "$arg" in
        debug)      CONFIG="debug" ;;
        release)    CONFIG="release" ;;
        --run)      RUN_AFTER=1 ;;
        --dev)      DEV=1 ;;
        --dev-stop) DEV_STOP=1 ;;
        *) echo "Unknown arg: $arg"; exit 2 ;;
    esac
done

# --- Isolated dev modes (exit before touching ./sys-monitor.app) ---

if [[ "${DEV_STOP}" -eq 1 ]]; then
    if pkill -f "${DEV_EXEC}" 2>/dev/null; then
        echo "[build] dev instance stopped"
    else
        echo "[build] no dev instance running"
    fi
    exit 0
fi

if [[ "${DEV}" -eq 1 ]]; then
    echo "[build] Compiling ${APP_NAME} (debug, dev)"
    swift build -c debug --product "${APP_NAME}"
    DEV_BIN=".build/debug/${APP_NAME}"
    test -x "${DEV_BIN}" || { echo "[build] FAIL: ${DEV_BIN} missing"; exit 1; }

    echo "[build] Assembling isolated ${DEV_DIR}"
    rm -rf "${DEV_DIR}"
    mkdir -p "${DEV_DIR}/Contents/MacOS"
    cp -f "${DEV_BIN}" "${DEV_DIR}/Contents/MacOS/${DEV_EXEC}"
    # Distinct bundle id (so LaunchServices launches a NEW instance instead of
    # focusing the real app) + matching executable name in the plist.
    sed -e 's#dev\.sys-monitor\.menubar#dev.sys-monitor.menubar.dev#' \
        -e "s#<string>${APP_NAME}</string>#<string>${DEV_EXEC}</string>#" \
        Resources/Info.plist > "${DEV_DIR}/Contents/Info.plist"
    codesign --force --sign - "${DEV_DIR}" >/dev/null 2>&1 || true

    pkill -f "${DEV_EXEC}" 2>/dev/null || true   # only ever matches the dev exec
    sleep 0.3
    echo "[build] Launching isolated dev instance (auto-quits in ${DEV_AUTOQUIT}s)"
    open "${DEV_DIR}" --args --dev-autoquit "${DEV_AUTOQUIT}"
    echo "[build] dev up; stop anytime: ./build.sh --dev-stop  (or it self-quits)"
    exit 0
fi

echo "[build] Compiling ${APP_NAME} (${CONFIG})"
swift build -c "${CONFIG}" --product "${APP_NAME}"

BIN_PATH=".build/${CONFIG}/${APP_NAME}"
test -x "${BIN_PATH}" || { echo "[build] FAIL: expected binary missing: ${BIN_PATH}"; exit 1; }

echo "[build] Assembling ${APP_DIR}"
mkdir -p "${APP_DIR}/Contents/MacOS"
mkdir -p "${APP_DIR}/Contents/Resources"
cp -f "${BIN_PATH}" "${APP_DIR}/Contents/MacOS/${EXEC_NAME}"
cp -f Resources/Info.plist "${APP_DIR}/Contents/Info.plist"

# Ad-hoc sign so macOS does not refuse to launch unsigned + quarantined.
codesign --force --sign - "${APP_DIR}" >/dev/null 2>&1 || true

echo "[build] OK -> ${APP_DIR}"

if [[ "${RUN_AFTER}" -eq 1 ]]; then
    echo "[build] Launching ${APP_DIR}"
    pkill -f "${APP_DIR}/Contents/MacOS/${EXEC_NAME}" 2>/dev/null || true
    sleep 0.3
    open "${APP_DIR}"
fi

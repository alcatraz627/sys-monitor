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
#   ./build.sh                  release build, assembles .app
#   ./build.sh debug            debug build
#   ./build.sh --run            build + open the .app

set -euo pipefail
cd "$(dirname "$0")"

CONFIG="release"
RUN_AFTER=0
for arg in "$@"; do
    case "$arg" in
        debug)    CONFIG="debug" ;;
        release)  CONFIG="release" ;;
        --run)    RUN_AFTER=1 ;;
        *) echo "Unknown arg: $arg"; exit 2 ;;
    esac
done

APP_NAME="sys-monitor"
APP_DIR="${APP_NAME}.app"
EXEC_NAME="${APP_NAME}"

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

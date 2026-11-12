#!/bin/bash
# Build the Notification Centre widget and place it inside an app bundle.
#
#   Widget/build-widget.sh <path to .app>
#
# A widget is an app extension: a small sandboxed program that lives in the
# app's PlugIns folder and that macOS launches on its own schedule. Xcode
# normally builds one. This does the same by hand with swiftc, so the project
# keeps building with the command line tools alone.
#
# The widget compiles the app's own sampler sources, so both read memory,
# storage and battery through one implementation.
set -euo pipefail

APP="${1:?usage: Widget/build-widget.sh <path to .app>}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="${ROOT}/Sources/sys-monitor"
APPEX="${APP}/Contents/PlugIns/SysMonitorWidget.appex"
SDK="$(xcrun --show-sdk-path)"

mkdir -p "${APPEX}/Contents/MacOS"
cp -f "${ROOT}/Widget/Info.plist" "${APPEX}/Contents/Info.plist"

# -application-extension restricts the build to APIs an extension may call.
# The entry point is NSExtensionMain, which hands control to WidgetKit.
swiftc -O -parse-as-library -application-extension \
    -module-name SysMonitorWidget \
    -target arm64-apple-macos14.0 -sdk "${SDK}" \
    -Xlinker -e -Xlinker _NSExtensionMain \
    "${ROOT}/Widget/SysMonitorWidget.swift" \
    "${SRC}/Model/Raw.swift" \
    "${SRC}/Model/Samples.swift" \
    "${SRC}/Sampling/Sampler.swift" \
    "${SRC}/Sampling/RateMath.swift" \
    "${SRC}/Sampling/MemorySampler.swift" \
    "${SRC}/Sampling/DiskSpaceSampler.swift" \
    "${SRC}/Sampling/BatterySampler.swift" \
    "${SRC}/Sampling/LoadSampler.swift" \
    -o "${APPEX}/Contents/MacOS/SysMonitorWidget"

# macOS only loads a widget that is sandboxed, so the extension is signed with
# its entitlements first; the app that contains it is signed by the caller.
codesign --force --sign - \
    --entitlements "${ROOT}/Widget/Widget.entitlements" "${APPEX}"
echo "[widget] built -> ${APPEX}"

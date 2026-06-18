#!/bin/bash
# Package sys-monitor.app into a versioned zip for a GitHub release.
#
# This script builds + ad-hoc-signs + zips. Developer ID signing and
# notarization are a SEPARATE manual step (they need your Apple credentials)
# and are printed at the end. Without them, the download is ad-hoc-signed and
# users must clear the quarantine flag once after downloading — see RELEASING.md.
#
# Usage:  ./release.sh

set -euo pipefail
cd "$(dirname "$0")"

VER=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Resources/Info.plist)
APP="sys-monitor.app"
ZIP="sys-monitor-${VER}.zip"

echo "[release] building v${VER}"
./build.sh release

# ditto is Apple's recommended archiver — preserves the bundle's symlinks,
# resource forks, and signature (plain `zip` can corrupt a .app).
rm -f "${ZIP}"
ditto -c -k --keepParent "${APP}" "${ZIP}"
echo "[release] packaged ${ZIP} ($(du -h "${ZIP}" | cut -f1))"

cat <<EOF

────────────────────────────────────────────────────────────────────
Next steps
────────────────────────────────────────────────────────────────────
The zip is AD-HOC signed (no Developer ID, not notarized). Two paths:

  A. Ship as-is (free). Add this to the release notes so users can launch it:
       xattr -dr com.apple.quarantine /Applications/sys-monitor.app

  B. Notarize (Apple Developer Program, \$99/yr) so it launches with no
     friction — full steps in RELEASING.md (codesign --options runtime →
     notarytool submit → stapler staple → re-zip).

Cut the GitHub release:
     git tag v${VER} && git push origin v${VER}
     gh release create v${VER} ${ZIP} --title "v${VER}" --notes-file <notes>
────────────────────────────────────────────────────────────────────
EOF

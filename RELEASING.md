# Releasing sys-monitor

How to ship a build other people can run. The hard part on macOS isn't the
build — it's **Gatekeeper**: a `.app` downloaded from the internet is
quarantined, and macOS refuses to launch it unless it's either notarized by
Apple or the user manually clears the quarantine flag.

There are two release paths. Pick based on whether you have an Apple Developer
account.

| | **Path A — ad-hoc** | **Path B — notarized** |
|---|---|---|
| Cost | Free | Apple Developer Program, $99/yr |
| User experience | Clear quarantine once (`xattr` or right-click → Open) | Double-click, just works |
| Good for | Developers / technical users | Anyone, incl. non-technical |
| Effort per release | `./release.sh` | `./release.sh` + sign + notarize + staple |
| Trust shown by macOS | "unidentified developer" until cleared | "Notarized Developer ID" |

---

## Path A — free (ad-hoc signed, user clears quarantine once)

No Apple account, no cost. The trade is one extra step for each downloader.

```bash
./release.sh          # build + ad-hoc sign + zip → sys-monitor-<ver>.zip
git tag vX.Y.Z && git push origin vX.Y.Z
gh release create vX.Y.Z sys-monitor-X.Y.Z.zip --title "vX.Y.Z" --notes-file NOTES.md
```

In the release notes, tell users to run this once after unzipping (because the
app isn't notarized, Gatekeeper would otherwise block it):

```bash
xattr -dr com.apple.quarantine /Applications/sys-monitor.app
```

Or, GUI equivalent: right-click the app → **Open** → **Open** again at the
prompt (on macOS 15+ this moved to System Settings → Privacy & Security →
"Open Anyway").

This is fine for sharing with technically-comfortable Mac users.

---

## Path B — notarized (Apple Developer Program, $99/yr, zero user friction)

The app launches by double-click on any Mac, no quarantine dance. Required if
you want to hand it to non-technical people.

**One-time setup:**
1. Join the Apple Developer Program ($99/yr).
2. Create a **Developer ID Application** certificate (Xcode → Settings →
   Accounts → Manage Certificates, or developer.apple.com) and install it in
   your login keychain.
3. Store notarization credentials in the keychain:
   ```bash
   xcrun notarytool store-credentials sysmon-notary \
     --apple-id "you@example.com" --team-id "TEAMID" \
     --password "app-specific-password"   # appleid.apple.com → App-Specific Passwords
   ```

**Per release:**
```bash
./build.sh release

# 1. Re-sign with Developer ID + hardened runtime (notarization REQUIRES the
#    hardened runtime; the build.sh ad-hoc signature is replaced).
codesign --force --options runtime --timestamp \
  --sign "Developer ID Application: Your Name (TEAMID)" sys-monitor.app

# 2. Zip and submit for notarization (~1-3 min).
ditto -c -k --keepParent sys-monitor.app sys-monitor.zip
xcrun notarytool submit sys-monitor.zip --keychain-profile sysmon-notary --wait

# 3. Staple the ticket so it works offline, then re-zip the stapled app.
xcrun stapler staple sys-monitor.app
rm sys-monitor.zip && ditto -c -k --keepParent sys-monitor.app sys-monitor-X.Y.Z.zip

# 4. Verify it passes Gatekeeper as a downloaded app would.
spctl -a -vvv sys-monitor.app    # expect: "accepted, source=Notarized Developer ID"

gh release create vX.Y.Z sys-monitor-X.Y.Z.zip --title "vX.Y.Z" --notes-file NOTES.md
```

### Does notarization choke on the private frameworks?

No. sys-monitor uses private APIs via `dlsym` (IOReport for power; the
NetworkStatistics framework for per-process network). Those would fail **App
Store review**, but notarization is an automated *malware* scan, not an API
audit — `dlsym` of private symbols passes. (This is also why the App Store is a
non-goal: the private APIs are load-bearing for power + per-process network and
both degrade gracefully if absent.) No special entitlements are needed; the app
runs sudoless and unsandboxed by design.

---

## Versioning

Bump both keys in `Resources/Info.plist` before releasing:

```
CFBundleShortVersionString   # user-facing, e.g. 1.0.0
CFBundleVersion              # build number; can match, or monotonically increase
```

Tag `vX.Y.Z` to match. `release.sh` reads the version from the plist for the
zip name, so update the plist first.

---

## What the user does with the download

Either path ships a `sys-monitor.app`. Tell users to **move it to
`/Applications` (or `~/Applications`)** — that's where Launch-at-Login
(`SMAppService`) expects it, and a stable location keeps the login item valid
across launches. Then open it; the icon appears in the menu bar.

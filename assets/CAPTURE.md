# Capturing the README screenshots

Two images give the README its "here's what it looks like." Capture them on a
clean desktop (nothing private in the menu bar), then drop them in this folder
and un-comment the `<img>` block in the top-level `README.md` (the `## Screenshots`
section).

## 1. The panel → `assets/panel.png`

1. Open the panel (click the menu-bar glyph, or press ⌥⌘M).
2. **⌘⇧4**, then press **Space** — the cursor becomes a camera.
3. Click the panel. macOS captures just that window with its shadow.
4. Move the result to `assets/panel.png` (default lands on the Desktop):
   ```bash
   mv ~/Desktop/Screen\ Shot*.png assets/panel.png   # or whatever it's named
   ```

## 2. The menu-bar glyph → `assets/menubar.png`

1. **⌘⇧4** for a region selection.
2. Drag a tight rectangle around just the sys-monitor glyph in the menu bar
   (keep neighbours out — both for focus and to avoid showing other apps).
3. Move it to `assets/menubar.png`.

## 3. Wire them in

In `README.md`, replace the HTML comment in `## Screenshots` with the `<img>`
block it contains (it's already written, just un-comment). Or tell me and I'll
do it.

Tips: a Retina capture is ~2× — that's fine, GitHub scales it via the `width`
attribute. PNG over JPG (sharp text). Keep each under ~500 KB.

# Panel zoom: why it is off, and what would make it work

Zoom was built on 2026-09-07, failed in four distinct ways on the owner's display,
and was removed on 2026-09-08 (`b523f55`). This records what was tried, what killed
each attempt, and the one approach left. It exists so the next attempt starts from
the evidence rather than from the first plausible idea.

## The requirement

Owner, verbatim: "it is JUST the relative scaling of all elements and the spacing
around them that keeps getting messed up", and "ensure it doesn't misbehave or
distort the relative shape". Range 50% to 200% in steps of 10.

## The structural finding

`scaleEffect` is a Core Animation transform. It does not change the size a view
reports for layout, and `NSHostingController` sizes the window from that report.

That forces a choice, and both halves are needed:

- The window grows when a section opens. Requires the panel to report a natural
  height.
- Zoom is proportional across steps. Requires the panel to fill its container, so
  the scaled result matches the window.

No arrangement of `scaleEffect` gives both. Every attempt below traded one for the
other, which is why the symptom kept moving rather than going away.

## What was tried, and what killed it

| Approach | Killed by |
|---|---|
| `DropPanel.zoom` override | `zoom` and `performZoom` never fire. An instrumented build showed the real caller is `NSHostingView.updateWindowContentSizeExtremaIfNecessary`. The override was dead code. |
| Clear `NSHostingController.sizingOptions` | Holds the height perfectly and stops the content laying out. The panel opens blank. `fittingSize` reads 0x0. |
| Pin the height in `DropPanel.setFrame` | Clips. At a 505 pt panel an expanded CPU section needs about 666 and the process list floor is 140, so 160 pt has nowhere to go and the header goes off the top. |
| Measure height via a `PreferenceKey` | The measurement never arrived. `naturalHeight` stayed 0, the height frame fell to `nil`, and the panel reported its unscaled height at every zoom. This was the frozen-height bug itself. |
| `drawingGroup` before the transform | Did not resolve the sibling-size disagreement. |
| `scaleUnitSquare` on the hosting view | Ratios did become uniform, which was the point, and the render came back clipped and corrupt. SwiftUI fights an AppKit coordinate transform beneath it. |
| Container authoritative (`GeometryReader`, height ÷ zoom) | Passed the grid at all sixteen steps and still failed on the owner's screen. It also cost natural-size reporting: `--probe-resize` fittingSize went from `360x666` to `360x320`, so the window could no longer grow on expand. |

Symptoms the owner reported on the last build, all traceable to the transform: the
corner radius disappeared at some zooms (the transform clips outside the shaped
container), height did not scale with width (reported size is unscaled), text stayed
blurry on Retina (a raster is stretched rather than re-rendered), and a forced resize
arrived about two seconds later (the raster re-apply ran late).

## The remaining path

Metric scaling. One layout pass at true size, no transform anywhere. Nothing is
rasterised small and stretched, the reported size genuinely is the scaled size, and
proportions hold by construction because every metric is multiplied.

Census, 2026-09-08:

| Site | Count |
|---|---|
| Raw metric literals in `UI/PanelRootView.swift` | 132 |
| Raw metric literals in `UI/GraphView.swift` | 3 |
| `DesignTokens` fonts and `Space` | the token source |

The count is the risk. A conversion judged by eye converts what the author looked at,
so the done-condition is a grep returning zero unscaled literals, not a screenshot.

## Before any of that

**This development machine is a 1x display.** `--probe-live` reports
`backingScaleFactor 1.0`. Neither per-layer rounding nor Retina raster loss has any
signal here, and five claims were reported verified from this machine and then
falsified by the owner's screen.

So the first move is a capture from a 2x display, not a code edit.

## Instruments kept

| Command | What it answers |
|---|---|
| `--probe-zoom-grid <dir>` | Is each zoom the 100% render scaled by exactly its factor? Sixteen steps, exits non-zero on any that is not. |
| `--probe-live <out.png> [--zoom N]` | What did the window server actually composite? Writes the `cacheDisplay` render beside it for comparison. |
| `--probe-resize [--regress] [--break-content] [--shot <p>]` | Does the top edge hold, and does the content lay out? Both guards are mutation-proven. |

One trap, already paid for: `--probe-panel` draws through `cacheDisplay`, which
re-renders the whole tree in one pass at final resolution. It structurally cannot see
a transform artifact, and it reported "crisp" while the owner saw pixelation.

## What survives in the code

`SettingsStore.panelZoom`, `zoomRange`, `zoomStep`, `clampZoom` and `stepZoom` are
kept, with their nine assertions in `--self-test`. They are correct, cost nothing, and
the metric-scaling work will want them. Nothing reads `panelZoom` to render, so the
stored value is inert until that work lands.

# Lineup feature icons

Henrique selected simple planar symbols and the cheerful palette on 2026-10-14, after comparing
the supplied Raycast Settings reference. The family uses one clean, luminous hue per tool,
off-white bold symbols and modest gradients. Tangerine, sunny yellow and spring mint replace
the rejected earthy palette. The original enamel and earlier redesigns remain archived.

## Size and framing contract

Feature images have **zero outer padding**. Backgrounds reach every edge of the square canvas;
only the shared macOS corner mask cuts out transparency. Central motif spacing belongs to
composition and does not change the tile's visible size.

Every imageset has logical size 72 pt and exactly 72/144/216 px PNGs. All tools share the same
20 pt sidebar and 56 pt pane-header renderer. Selection and controls keep the existing brand
accent. Disabled Settings features use runtime grayscale at full opacity.

`manifest.json` owns identities, palette, subjects, selected masters and reference SHA-256.
It declares `style: "restrained-v1"`, `paletteVersion: "cheerful-v1"` and
`framing: "edge-to-edge"`. The structural style key keeps the shared planar/framing contract;
the palette version records the current colors. `paletteReferences` records the approved
tangerine, sunny-yellow and mint originals with their SHA-256 values. The exporter requires the structural style and edge-to-edge framing
for this family, verifies all source masters before writing, and rejects padded artwork or
detached edge pixels that disguise padding. Continuous central bands must reach each canvas
edge within one pixel. All corners must be transparent after native preparation.
Verification checks palette-reference hashes, the source/master/native-mask receipt chain and
exported pixels against the selected master. Channel differences of at most two levels allow
PNG premultiplication rounding; changed artwork or lighting is rejected.

## Generate a new feature

Use `$lineup-icons` with the tool's purpose. The [repo skill](../../.agents/skills/lineup-icons/SKILL.md)
routes generation and export. [system-prompt.txt](system-prompt.txt) is the durable visual
instruction; `prompt-template.txt` expands per-feature metadata.

```sh
swift Scripts/feature-icons.swift prompt <ToolID>
# Generate against the manifest's reference using built-in imagegen.
# Preserve a fully opaque square source, with transparent_background: false.
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift Scripts/prepare-feature-icon.swift <source-png> <new-output-directory> <ToolID>
# Record sourceMaster and prepared master in the manifest.
swift Scripts/feature-icons.swift export
swift Scripts/feature-icons.swift verify
swift Scripts/feature-icons.swift preview
```

Preparation preserves the source PNG inside an SVG layer and native `.icon` document,
applies the same macOS alpha mask and writes a 1024 px sRGB master without outer padding.
The native renderer adds visible edge lighting even with material effects disabled. Default
feature preparation therefore retains its raw render as mask evidence, takes only that alpha,
and composites the original artwork's resampled RGB. The native lighting never enters the
selected feature master. Feature preparation accepts only full-frame opaque sources.
The imageset exporter only resamples prepared masters to sRGB RGBA PNG.
Generated model/version is not exposed by the integrated tool; exact prompts, arguments,
original paths and hashes are preserved in `generation.json` and per-icon records.

## Review and integrate

The base ten-tool family is in `masters/cheerful-v1/`. The approved Menu Bar glyph refinement
is selected from `studies/icon-craft-v1/`; World Clock and Display Control retain their earlier
simple glyphs. Keep Awake uses the exact placement derivative in `masters/awake-centered-v1/`:
the approved composition moves down 16 source pixels, with existing top-edge pixels extended
to fill the square. Its glyph pixels and colors are preserved, and the generated original
is archived intact. The source and native disc bounds are vertically centered; export rounding
can move the whole-glyph threshold box by half a pixel. Five approved originals were
preserved; five remaining tools received palette-only imagegen edits. Root `generation.json`
records the selected hashes and integration checks. Per-icon receipts retain exact prompts
and upstream provenance. Historical studies and rejected candidates remain local archives.
Selected sources, native alpha renders, preparation receipts and final masters are versioned;
the preparer regenerates intermediate feature `.icon` documents in a new output directory.

Inspect actual 16/20/56 px exports on light and dark surfaces and in grayscale. Check open
Command loops, separate arrows, clock hands, viewfinder gaps and distinct menu-bar shapes.
`preview.png` and `index.html` show exported artwork; these do not execute app behavior.

Run the required test suite, build and host app packaging when integrating resources.
Compare bundled PNGs with selected exports. A package/resource check does not establish
acceptance in the running Settings window; follow AGENTS.md for manual app verification.

## Application icon

The app logo keeps its existing three-pane symbol and follows the
[separate native macOS app-icon workflow](../AppIcon/README.md).
Feature imageset framing must not be copied into the application's platform layout.
The monochrome menu-bar mark stays unchanged.

Archived `reference` manifests remain available to verify older padded artwork.
New feature sources use full-frame opaque preparation.

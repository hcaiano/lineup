# Lineup feature icons

The first family uses enamel: a colored tile, an ivory motif, shallow relief and one soft
highlight from the upper left. Henrique selected this material and one color per feature on
2026-10-01. Individual feature designs remain available for iteration.

The [Icon Museum wall](https://icon.museum/wall) informed the central composition, controlled
volume and clear silhouettes. These are original feature designs, with the selected Zones master
as the family's material reference. The supplied iOS Icon Generator workflow informed the PNG
imageset export; imagegen supplies the artwork instead of Iconify or SF Symbols.

## Visual standard

- A square master with actual alpha. Match the versioned reference's colored rounded tile,
  which occupies about 78% of the canvas, with equal transparent margins. The corner radius
  is about 22% of the tile side.
- A straight-on view, without perspective. A central motif occupies about 58% of the tile width.
- An opaque tile and ivory motif, with shallow bevels and short contact shadows. The external
  surround stays transparent. Avoid detached marks, external shadows and baked checkerboards.
- One hue per feature, a lighter top and deeper bottom, and the same lighting in every icon.
  Feature colors belong to artwork; selection and controls retain `Brand.blue`.
- Bold, simple geometry. The enamel exports serve onboarding and the application artwork.
  Settings uses the vector variant below. Names and accessibility labels carry the wording.

### Settings variant

Settings uses opaque vector tiles with a corner radius of 15% of the side and a white motif
occupying 68% of the side. A shallow color gradient replaces the enamel bevels and highlights.
There are no transparent margins. The 24 pt sidebar tile and 64 pt header tile preserve each
feature's assigned hue and recognizable motif. This makes both slightly larger on screen than
the previous enamel tiles, whose visible artwork occupied about 78% of their 20/72 pt canvases.

`ToolIcon.Style.settings` draws this variant with native shapes and SF Symbols. Zones reuses the
three-pane menu-bar silhouette; Menu Bar keeps its three-slot strip and downward chevron.
The default `ToolIcon` style still loads the enamel imagesets for onboarding. The application
icon and generated masters retain their selected artwork and export sizes.

Enabled features retain the source colors. Disabled features are fully grayscale in both Settings
positions at full opacity. `ToolIcon.isEnabled` applies the treatment at render time; the PNG
masters and imageset exports stay unchanged. Other surfaces, including onboarding, retain color.

`manifest.json` owns feature identity, subject, color, master path and logical export size.
`prompt-template.txt` owns the common generation instructions. `generation.json` preserves the
actual prompts and references used for this first family. `references/enamel-v1.png` is a versioned
copy of the selected Zones artwork, independent of editable feature masters. The manifest stores
its SHA-256, which the script checks before prompting or exporting. `studies/` contains the other
two requested material studies.

Use the repo skill with: `Use $lineup-icons to create an icon for <feature>, which <purpose>.`
The agent reads the feature metadata and the existing family, generates against the saved
reference, exports and verifies the imageset, then presents the visual comparison.

## Generate and export

From the repository root:

```sh
swift Scripts/feature-icons.swift prompt hyperkey
# Generate with imagegen, using references/enamel-v1.png and real transparency.
# Inspect the output and copy the selected PNG to the master path recorded in manifest.json.
swift Scripts/feature-icons.swift export
swift Scripts/feature-icons.swift preview
```

The exporter uses macOS AppKit, Core Graphics and CryptoKit. It adds no package dependencies or network access.
Masters stay unchanged. Derived output is sRGB RGBA PNG with original-color rendering:

```text
Sources/lineup/Resources/ToolIcons/FeatureIcons.xcassets/
  Contents.json
  feature-<ToolID>.imageset/
    Contents.json
    feature-<ToolID>.png       # 72 px, 1x
    feature-<ToolID>@2x.png    # 144 px, 2x
    feature-<ToolID>@3x.png    # 216 px, 3x
```

The script enforces the 72 pt enamel export size, independent of the Settings vector variant.
[Apple's imageset format](https://developer.apple.com/library/archive/documentation/Xcode/Reference/xcode_ref-Asset_Catalog_Format/ImageSetType.html)
defines the universal scale slots and original rendering metadata. This catalog can be imported
into Xcode. Lineup's current SwiftPM build copies it and loads its PNG representations directly.

These are feature image assets. The application reuses the Zones icon; its macOS PNG/ICNS exports
have their own [app icon standard](../AppIcon/README.md). A future layered icon follows
[Apple's separate app-icon guidance](https://developer.apple.com/design/human-interface-guidelines/app-icons).

## Review a family

Open `preview.png` for the complete light/dark comparison. Open `index.html` for larger artwork,
the three material studies, and an enamel size comparison using the exported PNGs. The gallery is
a design aid; it does not simulate tool behavior or permissions.
The PNG comparison reads the actual exports and adds rows automatically when new features enter
the manifest.

Check each @2x export. Compare framing, corner shape, motif size and light direction across all
features. At small sizes, check that arrows stay distinct, the Command knot stays open, the clock hands
remain clear, the scan brackets retain gaps, and the menu strip is distinct from its chevron.

Run `swift Scripts/feature-icons.swift verify` after asset edits. Its checks protect the actual
files and metadata. The exporter also measures the tile bounds at alpha >= 240 and checks their
width, height and center against the versioned reference. Masters have a tolerance of 1% of the
canvas; small exports compare against the reference resampled to the same size, allowing one
additional pixel for rounding. This catches a correctly sized PNG
whose visible tile is larger or off-center. Refine such artwork through imagegen instead of adding
a per-feature scale adjustment in the UI. Passing these checks does not establish visual acceptance. Build, run the existing
suite and assemble a host app when integrating resources. Inspect the final Settings state before
shipping a visual change. `LINEUP_RENDER_PREVIEW` renders the actual Settings panes in both
appearances, enabled and disabled, without starting tools; see [BUILDING.md](../../BUILDING.md).

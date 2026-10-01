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
  is about 12% of the tile side in the small-size refinement. The original material reference
  retains its 22% corners; its bounds, color treatment and relief remain the reference.
- A straight-on view, without perspective. A central motif occupies about 58% of the tile width.
- An opaque tile and ivory motif, with shallow bevels and short contact shadows. The external
  surround stays transparent. Avoid detached marks, external shadows and baked checkerboards.
- One hue per feature, a lighter top and deeper bottom, and the same lighting in every icon.
  Feature colors belong to artwork; selection and controls retain `Brand.blue`.
- Bold, simple geometry that reads in the 24 pt sidebar and 80 pt pane header. The
  same artwork serves both. Settings names and accessibility labels carry the wording.

Enabled features retain the source colors. Disabled features are fully grayscale in both Settings
positions at full opacity. `ToolIcon.isEnabled` applies the treatment at render time; the PNG
masters and imageset exports stay unchanged. Other surfaces, including onboarding, retain color.

`manifest.json` owns feature identity, subject, color, master path and logical export size.
`prompt-template.txt` owns the common generation instructions. `generation.json` preserves the
actual prompts and references used for the original family and refinements. `references/enamel-v1.png` is a versioned
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
Masters stay unchanged. With `normalizeFraming: true`, the exporter aligns each master's opaque tile
width, height and center to the versioned reference before resampling. It applies one affine transform
to the entire image, preserving the generated motif and material. This explicit mode was authorized
by Henrique on 2026-10-01 after repeated imagegen framing drift. Without that flag, masters must
already match the reference. Derived output is sRGB RGBA PNG with original-color rendering:

```text
Sources/lineup/Resources/ToolIcons/FeatureIcons.xcassets/
  Contents.json
  feature-<ToolID>.imageset/
    Contents.json
    feature-<ToolID>.png       # 72 px, 1x
    feature-<ToolID>@2x.png    # 144 px, 2x
    feature-<ToolID>@3x.png    # 216 px, 3x
```

The script enforces the 72 pt family size, independent of the slightly larger Settings display size. [Apple's imageset format](https://developer.apple.com/library/archive/documentation/Xcode/Reference/xcode_ref-Asset_Catalog_Format/ImageSetType.html)
defines the universal scale slots and original rendering metadata. This catalog can be imported
into Xcode. Lineup's current SwiftPM build copies it and loads its PNG representations directly.

These are feature image assets. The application reuses the Zones icon; its macOS PNG/ICNS exports
have their own [app icon standard](../AppIcon/README.md). A future layered icon follows
[Apple's separate app-icon guidance](https://developer.apple.com/design/human-interface-guidelines/app-icons).

## Review a family

Open `preview.png` for the complete light/dark comparison. Open `index.html` for larger artwork,
the three material studies, and a sidebar/header preview using the exported PNGs. The gallery is
a design aid; it does not simulate tool behavior or permissions.
The PNG comparison reads the actual exports and adds rows automatically when new features enter
the manifest.

Check each @2x export. Compare framing, corner shape, motif size and light direction across all
features. At 20 pt, check that arrows stay distinct, the Command knot stays open, the clock hands
remain clear, the scan brackets retain gaps, and the menu strip is distinct from its chevron.

Run `swift Scripts/feature-icons.swift verify` after asset edits. Its checks protect the actual
files and metadata. The exporter also measures the tile bounds at alpha >= 240 and checks their
width, height and center against the versioned reference. Normalized sources, or raw masters when normalization is off, have a tolerance of 1% of the
canvas; small exports compare against the reference resampled to the same size, allowing one
additional pixel for rounding. This catches a correctly sized PNG
whose visible tile is larger or off-center. Framing normalization belongs to the shared exporter;
there is no per-feature scale adjustment in the UI. Material and motif corrections still use imagegen. Passing these checks does not establish visual acceptance. Build, run the existing
suite and assemble a host app when integrating resources. Inspect the final Settings state before
shipping a visual change.

The debug preview command also renders actual Settings panes in light and dark appearance,
with enabled and disabled flags. See [BUILDING.md](../../BUILDING.md#preview-the-interface).

The existing `swift run lineup-tests` runner also exports isolated, off-center tile fixtures through
the real exporter. It checks both vertical directions for correct placement without clipping.

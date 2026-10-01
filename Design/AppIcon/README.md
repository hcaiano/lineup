# Lineup app icon

Henrique selected the existing Zones artwork for the Lineup application icon on 2026-10-01.
Reuse the exact feature master, including brand blue `#2F6BFF`, framing and enamel finish.
The menu bar uses the existing three-pane monochrome template. New logo work is deferred.

The current exports use the existing macOS 13+ PNG/ICNS packaging path. The selected master lives
at `Design/FeatureIcons/masters/zones.png`; the app exporter references it directly so there is
no separate app artwork to drift. A future native layered replacement follows the
[Apple Icon Composer contract](../../.agents/skills/lineup-icons/references/apple-icon-composer.md).
These flattened exports do not claim to be native Icon Composer output.

The manifest names Zones as the selected candidate. The saved Zones master reproduces all current
app exports; its generation record lives with the feature family.

Use the repo's [$lineup-icons](../../.agents/skills/lineup-icons/SKILL.md) skill:

> Usa $lineup-icons para refinar o app icon do Lineup: <alteração desejada>.

Keep the selected symbolic geometry when changing finish or spacing. A new logo is an explicit
design request. Preserve old master versions and record the complete prompt and actual tool used.
The built-in imagegen service manages the model; it does not expose a model selector.

## Export

```sh
./Scripts/make-icns.sh
swift Scripts/make-icon.swift verify
swift Scripts/make-icon.swift preview
```

The native exporter only resamples the selected master into sRGB RGBA PNGs. It checks the immutable
enamel reference's hash, a square master of at least 1024 px, transparent surrounds and corners,
every size/scale entry, and byte consistency between exports and the selected master.

- `Icon/icon-1024.png`: exact 1024 px application image, also used by the README and workspace icon.
- `Icon/AppIcon.xcassets/AppIcon.appiconset`: Xcode macOS app icon catalog.
- `Icon/AppIcon.iconset`: ignored intermediate files for `iconutil`.
- `Resources/AppIcon.icns`: application icon embedded by the existing app packager.
- `Design/AppIcon/preview.png`: selected Zones artwork and the feature family on light/dark surfaces.

| Point size | 1x pixels | 2x pixels |
| --- | --- | --- |
| 16 | 16 | 32 |
| 32 | 32 | 64 |
| 128 | 128 | 256 |
| 256 | 256 | 512 |
| 512 | 512 | 1024 |

The raster studies match the versioned family's visible tile footprint. This padding is a
repository design choice, not an Apple source-layer mask or safe-area requirement.
Inspect the 1024 px image for floating fragments, ragged edges or changes in the motif. Inspect
actual 16/32/64/128 px exports for clear geometry and gaps. If generation leaves detached pixels,
clean them through imagegen and retain the old master. Export never crops, masks, paints or
changes the source artwork.

The feature renderer remains 72 pt with 72/144/216 px imagesets. The application icon uses its
own pipeline. Lineup currently packages a raster ICNS for macOS 13+; this is not a layered icon.
Any future layered replacement uses Apple's [Icon Composer workflow](https://developer.apple.com/documentation/xcode/creating-your-app-icon-using-icon-composer)
and layered source files. Keep any iOS application icon on its platform export contract.

## Verify the bundle

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift run lineup-tests
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer UNIVERSAL=0 ./Scripts/build-app.sh .build/icon-review
codesign --verify --deep --strict .build/icon-review/Lineup.app
```

Check that the assembled `Contents/Resources/AppIcon.icns` matches the generated ICNS. Preview
its representations without launching Lineup or activating real user configuration. The menu-bar
mark uses native monochrome geometry and no tile, colors or lighting. Dock/Finder presentation on
the user's running app remains a separate visual acceptance check.

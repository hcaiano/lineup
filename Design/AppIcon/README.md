# Lineup app icon

The application icon is the native Icon Composer document [`Lineup.icon`](Lineup.icon). It keeps the
existing three-pane symbol in the restrained `raycast-v2-muted` style that Henrique approved on
2026-10-14. The menu bar keeps the monochrome three-pane template in
`Sources/lineup/App/Brand.swift`. New logo work is a separate design request.

Feature icons fill their whole tile with no outer padding. The app icon does not copy that framing:
Apple's renderer and compiler apply the macOS mask, grid margin and shadow. See
[the Apple contract](../../.agents/skills/lineup-icons/references/apple-icon-composer.md).

## Source

- `Lineup.icon/icon.json` uses fields from the installed Xcode macOS template and Apple's Landmarks
  sample. Supported platform: macOS squares.
- Background: a vertical `linear-gradient` from `#3F7EED` to `#2F69DF`, kept apart from the artwork.
- Foreground: one group with one layer, `Assets/panes.svg`. It holds three flat `#F2F5FA` rounded
  rectangles on the 1024 x 1024 canvas, unmasked and without shadows or lighting.
- Material: layer `glass` false, group shadow `none`, `specular` false, translucency disabled.

The SVG redraws the [approved artwork](../FeatureIcons/references/restrained-v1.png),
which stays unchanged; the manifest records its SHA-256. The panes keep the reference's proportions
of its full tile, scaled from 1254 to 1024 px and evened out to equal columns, rows and gaps.
[generation.json](generation.json) records the measurements. The canvas is the icon shape. The
macOS grid margin is added at compile time, so the source has no extra spacing.

Edit `Lineup.icon` in Icon Composer or as text, then run the export. Keep layer names and
`image-name` values in step with `Assets/`. Previous raster records stay in the manifest, in
`generation.json` and in local `prompt-template-enamel-*.txt` archives.

## Export

Run these commands with full Xcode 26 or later:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer ./Scripts/make-icns.sh
swift Scripts/make-icon.swift verify
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift Scripts/make-icon.swift preview
```

`export` (run by `make-icns.sh`) uses Icon Composer's `ictool` for previews and Xcode's `actool` for
compiled output. Both tools are required. A missing tool or an actool older than 26 stops the export;
no raster fallback is written.

| Output | Tool | What it is |
| --- | --- | --- |
| `masters/lineup-native.png` | ictool | Default rendition, current design generation, 1024 px |
| `renders/*.png` | ictool | Dark, TintedLight, TintedDark, ClearLight, ClearDark and macOS 26 `Default-26` |
| `Resources/AppIcon.icns` | actool | ICNS fallback with 16, 32, 128 and 256 px representations |
| `Icon/icon-1024.png` | actool | Largest flattened rendition from the compiled `Assets.car`, for the README and workspace |
| `receipt.json` | export | Source hash, minimum system, tool versions, arguments and output hashes |
| `preview.png` | preview | Renditions, actual 16/32/64/128 px samples and the feature family |

Previews and compiled output are framed differently:

- `ictool` renders the masked shape edge to edge on a 1024 canvas, with only the corners
  transparent. It is the per-appearance preview and is never placed in a bundle.
- `actool` compiles for `--minimum-deployment-target` from `LSMinimumSystemVersion` (13.0). Its
  `Assets.car` holds the layered icon for macOS 26+, plus flattened renditions for earlier releases.
  Those renditions and the ICNS place the shape at 824 of 1024 px with a drop shadow, Apple's macOS
  grid. `verify` checks both framings.

`verify` needs only Command Line Tools, and `swift run lineup-tests` runs it. It fails when
`Lineup.icon`, `LSMinimumSystemVersion` or any recorded output no longer matches the receipt.

## Bundle integration

`Scripts/build-app.sh` runs `swift Scripts/make-icon.swift compile .build/app-icon` on every build.
The step checks the receipt, then compiles a temporary copy named `AppIcon.icon`. actool names the
icon after the file, so the existing `CFBundleIconFile` and the app's `NSImage(named: "AppIcon")`
keep working. When the actool version matches the receipt, the fresh ICNS must be identical to the
committed one. The script copies `Assets.car` and `AppIcon.icns` into `Contents/Resources`, then
merges actool's `CFBundleIconName` into the bundle's Info.plist. `Resources/Info.plist` is unchanged.
Packaging therefore needs full Xcode 26+.

Inspect a built bundle without launching it:

```sh
/usr/libexec/PlistBuddy -c 'Print :CFBundleIconName' <app>/Contents/Info.plist
xcrun assetutil --info <app>/Contents/Resources/Assets.car
cmp <app>/Contents/Resources/AppIcon.icns Resources/AppIcon.icns
```

## Limits

- Liquid Glass is off for the panes, but macOS 26+ still draws its edge highlight on the icon shape.
  Dark, tinted and clear appearances use the system's automatic treatment; the source has no
  appearance overrides.
- The gap between panes is 36 of 1024 px, about half a pixel at 16 px. At that size the panes read
  as one light block with a faint split. A `.icon` has no per-size variant for macOS. Wider gaps
  would change the approved geometry.
- The `.icon` schema is not publicly documented. Fields come from the template and the Apple sample.
  Shadow `none` is a value ictool accepts: an unknown value fails to parse, and with glass on it
  renders differently from `neutral`.
- `Assets.car` is not byte-stable: actool writes new rendition identifiers on each run. It is
  built at packaging time and not committed.
- These checks do not cover the Dock, Finder and the app's own windows on the running app.

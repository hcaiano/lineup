---
name: lineup-icons
description: Create and refine Lineup feature icons with the approved cheerful palette and simple planar symbols, uniform exports without outer padding, and a separate native macOS app-logo workflow.
---

# Lineup icons

Henrique approved simple planar symbols and the cheerful palette on 2026-10-14.
For feature artwork, read [the system prompt](../../../Design/FeatureIcons/system-prompt.txt)
and [the manifest](../../../Design/FeatureIcons/manifest.json). The versioned source reference
named by the manifest is the visual authority. Preserve approved feature meanings.
For the app icon, follow the separate workflow below.

## Feature icons

1. Find the stable `ToolID` and purpose in the code. Add or update its manifest row using
   `feature-<ToolID>` as the asset name. Keep `style: "restrained-v1"`, `framing: "edge-to-edge"`
   and the shared 72 pt imageset size. Choose a clean, cheerful principal hue that sits with
   the selected family. Follow its tangerine, sunny yellow and fresh green palette references;
   previous terracotta, ochre and olive studies were rejected.
2. Inspect the versioned reference and current exports. Obtain the feature prompt with
   `swift Scripts/feature-icons.swift prompt <ToolID>`.
3. Generate one source per built-in imagegen call, passing the selected reference and the
   manifest's `paletteReferences` as style images and
   `transparent_background: false`. For a refinement, use the existing unmasked source as
   the edit target and preserve geometry outside the requested change. Save a fully opaque
   square of at least 1024 px; its background fills every edge and corner.
   When the user authorizes direct positioning, use a deterministic transform of the approved
   source rather than regenerating its glyph. Keep the generated original intact and label
   the transformed source as derived, with the exact operation and pixel-preservation evidence.
4. Preserve the original generated PNG byte for byte. Record the exact prompt, references,
   tool arguments, original path and SHA-256 in the generation record. The integrated service
   exposes no model selector or model version; record unknown versions honestly.
5. Prepare the shared native corner mask. With full Xcode selected, run:

   ```sh
   DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
     swift Scripts/prepare-feature-icon.swift <source-png> <new-output-directory> <ToolID>
   ```

   The default opaque-source mode preserves the artwork's RGB, uses the native renderer only
   for the shared corner alpha mask, and writes a 1024 px master whose colored tile reaches
   all four edges. Native renderer lighting must not enter feature artwork; inspect the
   outer edge pixels as well as the motif. The raw native render is retained as mask evidence.
   Record this prepared PNG as `master` and the original as `sourceMaster`.
6. Run `swift Scripts/feature-icons.swift export`, `verify` and `preview`.
   Inspect real 16/20/56 px samples on light and dark surfaces, including grayscale.
   Keep the same renderer size for every feature; repair artwork or source framing instead
   of adding per-feature UI scales.
   For symmetric motifs, measure the whole glyph and central shape against the canvas axes;
   verify their placement again after native preparation.

The exporter rejects missing/reference framing for `restrained-v1`, padded masters, detached
edge fragments, incompatible dimensions and incorrect imageset metadata before writing.
It produces 72/144/216 px sRGB PNGs for every tool. The 20 pt sidebar and 56 pt pane header share
these assets. The central motif has composition space; the colored tile has no outer margin.
Transparent native corner cutouts are part of the shape, not padding.

`--tile-reference` and reference-framing manifests are for archived padded artwork.
New restrained sources use the default full-frame preparation above.
Preserve old references and generation records when versioning the selected family.

## Application icon and menu-bar logo

Read [the app-icon standard](../../../Design/AppIcon/README.md),
[the application manifest](../../../Design/AppIcon/manifest.json) and
[the Apple native contract](references/apple-icon-composer.md).
Preserve the existing three-pane symbol and monochrome menu-bar geometry.

The application uses its own genuine 1024 px macOS Icon Composer document.
Keep editable foreground layers separate from native background and material settings.
Use Apple's installed template and supported renderer/compiler fields. Let the native
platform workflow own the application's mask, framing, appearances and compatibility exports.
The feature zero-padding rule does not determine the app icon's platform spacing.

Use the documented app export and verification commands, then assemble a host bundle.
Verify that the actual native source is compiled and its output is present in the bundle.
A masked feature PNG or ICNS conversion alone does not prove native app-icon integration.
Record settings, tool versions, source hashes, supported appearance previews and compiled outputs.

## Completion

For assets or code changes, run the repository's required build, tests and host packaging checks.
Compare bundled assets with selected exports. Preserve `ToolIcon` loading and grayscale behavior.
Present the real small-size artwork and state the scope of native UI evidence.
Follow AGENTS.md for app launches and external actions; icon work does not authorize release work.

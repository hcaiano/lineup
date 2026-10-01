---
name: lineup-icons
description: Create Lineup icons with the approved enamel reference, consistent feature imagesets, recognizable menu-bar geometry and Apple's native Icon Composer workflow for the app icon.
---

# Lineup icons

Read [the visual standard](../../../Design/FeatureIcons/README.md) and the manifest before
generating artwork. Work from the repository root. For the whole app's icon, also read
[the app icon standard](../../../Design/AppIcon/README.md) and the mandatory
[Apple Icon Composer contract](references/apple-icon-composer.md). Route feature requests through the
72 pt imageset exporter below; route final app icons through the native 1024 px Icon Composer workflow.

Invoke with: `Use $lineup-icons to create an icon for <feature>, which <purpose>.`
For the application: `Use $lineup-icons to refine the Lineup app icon: <requested change>.`
Infer the existing feature's metadata from the code. Ask only when its purpose or requested
direction cannot be established. A new icon keeps the selected family; changing the standard
is a separate explicit request.

Current app decision, 2026-10-01: reuse the existing Zones master for the application icon and
keep its pane-grid menu-bar template. New logo work is deferred. Do not generate a new logo or
resume the saved studies unless the user requests it. Export this selected artwork with
`./Scripts/make-icns.sh`, then verify and preview it with `Scripts/make-icon.swift`.
The shared Zones source is named by `Design/AppIcon/manifest.json`.

## Generate a feature

1. Find the feature's stable `ToolID` and purpose in the code. Add or update its entry in
   `Design/FeatureIcons/manifest.json`. Use `feature-<ToolID>` for the asset name.
2. Inspect the file named by `reference` in the manifest with `view_image`. It is a versioned
   copy of the selected enamel artwork, separate from editable feature masters. The script
   checks its SHA-256 before prompting or exporting. Inspect the family's preview to compare
   visual weight and spacing.
3. Obtain the prompt with `swift Scripts/feature-icons.swift prompt <ToolID>`. Use the built-in
   imagegen tool with `transparent_background: true` and that versioned reference in
   `referenced_image_paths` as a style reference. Keep the common prompt unchanged; the feature's
   subject and assigned hue provide the variation.
   Generate one icon per call. The built-in service chooses its model; record the actual tool
   used rather than inventing a model name. CLI/API fallback is a separate user choice.
4. For a new concept, compare alternative motifs in the same material. For a refinement, change
   the requested property and preserve framing, color, lighting and motif. Save versions beside
   the master until a preferred candidate is selected.
5. Inspect the actual output, then copy the selected PNG into the manifest's master path. Preserve
   the full generation prompt and reference path in `Design/FeatureIcons/generation.json`.
   Keep previous feature records and prompts when adding or refining an icon.
6. Run `swift Scripts/feature-icons.swift export`, then `swift Scripts/feature-icons.swift preview`.
   Inspect each @2x PNG and compare the family at 20 and 72 points on light and dark backgrounds.
   Refine artwork through imagegen if its motif, edges or spacing fail that comparison.

The exporter only resamples the supplied artwork into sRGB PNGs. It verifies real transparent
surrounds, transparent corners, dimensions, imageset metadata and visible tile framing against the
versioned reference. Masters must match its width, height and center within 1% of the canvas;
small exports allow one pixel of rounding. It does not judge style or
remove generation artifacts. Generation is stochastic; the saved master is the reproducible
source for all derived sizes.

Keep the family's logical size at 72 pt, producing 72/144/216 px at 1x/2x/3x. Generated master
dimensions may vary; only square masters with sufficient resolution and real alpha pass export.
For a new feature, choose a hue distinct from the closest existing tool while respecting
`PRODUCT.md`. Keep control accents unchanged. Copy and inspect new generation outputs before
replacing the selected master. An icon refinement leaves the versioned style reference unchanged.
Correct visible size in the artwork, preserving the shared 20/72 pt renderer. Matching PNG
dimensions alone does not establish matching tile size.

## Generate or refine the app icon and logo

1. Read the Apple contract above, `Design/AppIcon/manifest.json`, the app icon standard and
   `PRODUCT.md`. The app uses brand blue. Preserve an approved logo unless a new one is requested.
2. For a new logo, study the [Icon Museum wall](https://icon.museum/wall) for composition and
   recognizable silhouettes. Record which visual principles informed the proposal. Create original
   artwork. Compare each symbol as a monochrome 18 x 16 pt menu-bar template before decorating it.
   Reject a mark that depends on color, tiny details or a tile to be recognized.
3. For raster motifs use imagegen with real alpha, producing isolated flat foreground layers.
   Request no background tile, mask, gradients, lighting, shadows, bevels or texture in these
   source layers. For existing editable native vector geometry, edit the vector source directly.
   Keep versions, complete prompts, reference paths and actual tool in generation records.
4. Assemble the layers in a genuine Icon Composer document using Apple's current 1024 px Mac
   template. Configure background, groups and material there. Save its `.icon` source and assets.
   Reuse the same composition settings for approved variants; change only the requested properties.
   Use fields from the installed Apple template and official samples, and validate the document
   with Icon Composer and actool. Never guess fields; recheck native templates when Xcode changes.
5. Verify native macOS appearances, backgrounds, lighting and small sizes in Composer. Export
   app icon previews and keep the monochrome menu-bar geometry consistent with the same logo.
   Record the settings and evidence. Do not invent a `.icon` schema.
6. Integrate and compile the native icon for the current app target, then check its bundled output.
   A raster ICNS alone is a compatibility artifact. The existing `make-icon.swift` and
   `make-icns.sh` generate raster studies; use them when reviewing those studies, and report native
   integration pending until the actual Composer source is consumed by the build.

The menu-bar mark retains its simple template silhouette; material and lighting belong to the
app icon. Keep app-source rules separate from the repository's decorative feature-image exports.

## Completion

An icon is ready for review when its saved master, generation record, imageset and family preview
are present; export and verification pass; and its @2x PNG reads clearly at both existing UI sizes
in light and dark appearance. Compare tile footprint, centering, corner shape, ivory motif,
highlight direction and relief against the reference. Regenerate a mismatched candidate through
imagegen before reporting it ready. Fixed exports are reproducible; perfect aesthetic matching
cannot be established by dimensions or a prompt alone.

The user-selected interim Zones icon is complete through its existing PNG/ICNS export and
verified bundle path, with the matching pane-grid menu-bar template. New logo studies and a native
layered migration are deferred, so they do not block this selection.

For a future native app icon, require the saved `.icon`, source layers, generation record, settings,
appearance previews and compiled bundle output. PNG/ICNS studies must be identified as studies.
State whether the logo has the user's visual acceptance and whether native integration is complete.
Keep earlier concepts for comparison. A correctly sized file alone does not prove Apple compliance.

An intentional new material uses a new reference filename, style version and hash. Preserve
the old reference so existing generations remain attributable to their selected standard.

## Integrate and verify

`ToolIcon` loads `feature-<ToolID>.imageset` from the copied SwiftPM resource catalog. New registered
tools use that convention automatically; retain their SF Symbol fallback. Follow the repository's
normal build, test and packaging checks when resources or consuming code change. Use the same
`ToolIcon` component in feature headers and navigation rather than adding a second renderer.

Pass the feature's persisted enabled flag to `ToolIcon.isEnabled` in Settings. Disabled icons use
zero saturation at full opacity, with unchanged dimensions, margins and relief. Apply the same
rule to sidebar and header. Do not create grayscale PNG copies or use a permission/running flag
to decide whether a configured feature is off. Other surfaces retain full-color artwork by default.

Show the user the family and state which assets still need visual acceptance. Keep a change of
material or palette explicit; the selected v1 family uses enamel and one color per feature.

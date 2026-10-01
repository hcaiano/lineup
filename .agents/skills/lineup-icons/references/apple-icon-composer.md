# Apple app icon contract

Checked against Apple's live documentation on 2026-10-01. Recheck it before changing platform
exports or claiming compliance with a newer Xcode/macOS design generation.

Primary sources:

- [Creating your app icon using Icon Composer](https://developer.apple.com/documentation/xcode/creating-your-app-icon-using-icon-composer)
- [App icons, Human Interface Guidelines](https://developer.apple.com/design/human-interface-guidelines/app-icons)
- [Apple Design Resources](https://developer.apple.com/design/resources/)

## App icon source

Use Apple's current template and a 1024 x 1024 square canvas for Mac. Keep editable foreground
layers separate, name them in back-to-front order and prefer SVG for simple geometry. Transparent
PNG is suitable for raster foreground artwork. Keep the main motif centered and use Apple's grid.

Provide unmasked square layers. Configure background color or gradient in Icon Composer. Leave
blur, shadows, specular highlights and translucency to its material settings. Group related pieces
into at most four groups. Save the actual native `.icon` document with its assets.

Use the installed Xcode macOS template and fields from official examples such as
[Apple's Landmarks sample](https://developer.apple.com/documentation/swiftui/landmarks-building-an-app-with-liquid-glass).
Record the source, exact settings and tool version with the native document. The official renderer's
command syntax is available with `Icon Composer.app/Contents/Executables/ictool --help`.
Keep source layers unmasked; native materials and masking are applied by that renderer.

Inspect the supported platform and appearance variants, different backgrounds, lighting angles
and small sizes. Integrate the `.icon` source through the app target and verify the built output.
Xcode can derive older-platform representations from the native source. A `.icon` supersedes the
app icon catalog when configured as the target's app icon. See Apple's Composer guide for these
export and integration rules.

## Lineup rules

The following are this repository's choices, not Apple-mandated dimensions for feature art:

- The approved motif, optical scale, placement and material settings form one saved template.
  New features replace only the motif and assigned hue.
- Settings feature imagesets use 72/144/216 px exports and the shared 20/72 pt renderer. Compare
  actual tile bounds with the versioned reference. Never fix a large tile with a UI-only scale.
- The menu-bar mark must be recognizable as a single-color 18 x 16 pt template on light and dark
  backgrounds. Use clear silhouette and generous gaps; preserve the app logo's symbolic geometry.
- Test the menu-bar silhouette before decorating a proposed logo. Show it alongside the app icon.
  Reject candidates that depend on gradients, tiny details or a colored square for recognition.
- Keep the complete prompt, source layers, composition settings, native document and derived
  exports. Preserve previous approved versions.

## Existing raster studies

The current enamel PNGs and ICNS are raster studies and compatibility artifacts. Their baked
rounded tiles and highlights are not unmasked Icon Composer source layers. Keep them identified
as such while reviewing the proposed family. Use isolated foreground layers for the native source.
The 78% tile measurement describes the existing raster reference, not an Apple safe-area rule.

A final app icon requires a genuine `.icon` source, verified native previews and a compiled bundle
containing its output. PNG dimensions or an ICNS conversion alone do not meet that completion
gate. If the current SwiftPM packager cannot consume the native icon yet, report the integration
still pending and preserve the existing working bundle path. Do not invent a `.icon` schema or
silently substitute a flattened PNG and call it Icon Composer output.

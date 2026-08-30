# Product

## Register

product

## Users

Mac users who want their windows arranged without thinking about it. Two groups: Henrique (power
user, ultrawide monitor, keyboard-driven) and his non-technical friends (first macOS utility they
install by hand; they will not read documentation). Context: the app runs all day in the menu bar;
the only UI most users ever see is the on-screen layout editor (once) and the drag-snap highlight
(daily).

## Product Purpose

Lineup arranges windows with per-screen zones the user draws themselves. Zones replaces
Magnet/Rectangle with something you can shape: recursive layouts per display, snapping by
shift-drag or global shortcuts. The optional Tiles tool uses those same layouts for automatic
placement, four lightweight workspaces, and window stacks. Success: a first-time user builds a
multi-zone layout with no instructions, chooses manual or automatic placement, and the app then
disappears into muscle memory.

## Brand Personality

Native, precise, calm. One fixed brand blue (#2F6BFF, `Brand.blue` in
`Sources/lineup/App/Brand.swift`) carries the identity; everything else defers to macOS conventions
(system fonts, vibrancy, standard controls). The app should feel like Apple shipped it.

## Anti-references

- Amateur floating chrome: bare SF Symbol buttons in white boxes, mismatched sizes, arbitrary
  placement. The editor overlay must read as one designed surface, not controls sprinkled on glass.
- Electron-app density and web-style cards. No faux-material design on macOS.
- Red as an accent anywhere (explicit user rule). Warnings are orange; everything else is the blue.
- "AI-made" tells in copy or UI: em dashes, generic icon-plus-label grids, hedging microcopy.

## Design Principles

1. **The screen is the canvas.** The editor draws on the user's actual display; chrome floats only
   where it must, centered and reachable (a 49" ultrawide is the stress test).
2. **Show the result, not the words.** Split/merge controls depict the shape they produce; labels
   support, never substitute. Non-native English speakers must understand them.
3. **Numbers users can act on.** Pixel readouts, placed where the eye already is; no unit soup.
4. **Defer to the platform.** AppKit controls, system behaviors, native About/Settings idioms.
5. **One blue.** Selection, highlight, accent, icon: all `Brand.blue`. No second accent.

## Tiles Product Contract

- Tiles is a separate tool and is off by default.
- Zones owns layout geometry. Tiles never has a second layout editor.
- Each Zones leaf is one tile. Each tile can hold an ordered stack of windows.
- Four fixed workspaces switch as one context across all connected displays.
- Tiles uses only public Accessibility operations, never native Space control or off-screen hiding.
- Settings exposes the shared global switch, one fixed 8 pt tile-spacing switch, and editable
  shortcuts for workspaces, stacks, spatial focus, spatial movement, and split direction. There
  are no spacing values or layout policies to tune.
- On first activation or shortcut edit, Tiles materializes an adaptive preset from Hyperkey mode;
  stored shortcuts are never rewritten.
- In the recommended preset, number shortcuts switch Tiles workspaces and their physical
  Shift-number counterparts move the focused window; Include Shift leaves those move counterparts
  unassigned because the masks cannot be distinguished.
- A Zones quick action on a managed window snaps it, then temporarily floats/detaches it. Dropping
  it into a zone adopts it again.
- The Tiles Space shortcut toggles the focused window between its safe freeform frame and the
  active workspace tile.
- Zones quick-action arrows use Hyper+arrows. Fresh defaults follow Hyperkey mode (`6400` when
  Include Shift is off, `6912` when it is on); existing full-Hyper bindings require physical
  Shift in the compact mode and are never rewritten. A stored legacy Zones section with no
  shortcut fields keeps its historical full-Hyper defaults. Tiles H/J/K/L navigate focus between
  tiles.
- Cycler receives no new app bindings; H/J/K/L remain the recommended Tiles focus letters and
  existing Cycler rows keep their explicit conflicts. The shared shortcut vocabulary is: numbers
  for Tiles workspaces, letters for Cycler app groups, H/J/K/L for tile focus, arrows for Zones,
  and physical Shift for move or reverse actions.
- The full agreed behavior and safety gates are in `docs/tiles-implementation-plan.md`.

## Accessibility & Inclusion

Every control carries an accessibility label (SF Symbol `accessibilityDescription`, button titles).
Hover-revealed controls are also click-pinned so trackpad/switch users get a stable target. Esc
always cancels; Return always confirms. Color is never the only signal (active zones also get
thicker strokes). No motion beyond system defaults, so no reduced-motion variants are required.

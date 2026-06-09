# Lineup

A tiny, native macOS menu-bar window manager. Built to replace Magnet for one job:
**snap the focused window into precisely configurable columns** so window edges land
exactly on a monitor's physical vertical seams (e.g. the Samsung Odyssey G9). Driven
entirely by **Hyperkey + keys**.

- Native Swift + AppKit. No Electron, no background CPU, no third-party deps.
- Window moves via the Accessibility API. Global hotkeys via Carbon (no event tap).
- Column widths are config-driven (fractions, points, or physical pixels), so you can
  line a window edge up with a seam to the pixel.

## Default key bindings

Hyperkey = `⌃⌥⇧⌘` (most people map Caps Lock → Hyper via Karabiner Elements or `hidutil`).

| Shortcut       | Action                       |
|----------------|------------------------------|
| `Hyper + ↑`    | Full screen (usable area)    |
| `Hyper + ↓`    | Center column                |
| `Hyper + ←`    | Left column                  |
| `Hyper + →`    | Right column                 |
| `Hyper + [`    | Left half                    |
| `Hyper + ]`    | Right half                   |

Defaults are equal thirds + halves. Tune them to your seams in the config (below).

## Build & install

Requires the Xcode Command Line Tools (`xcode-select --install`). Full Xcode is **not**
required.

```sh
# Run the test suite (dependency-free, no XCTest/Xcode needed)
swift run lineup-tests

# Build Lineup.app into ./dist (or pass a target dir, e.g. ~/Applications)
./Scripts/build-app.sh ~/Applications

# Launch
open ~/Applications/Lineup.app
```

On first launch macOS will prompt for **Accessibility** permission
(System Settings → Privacy & Security → Accessibility). Grant it — that's what lets the
app move other apps' windows. Then disable Magnet so the shortcuts don't collide.

### Make the permission stick across rebuilds (recommended)

By default the app is ad-hoc signed, so its signature changes every rebuild and macOS
treats each build as a new app — you'd have to remove the old entry and re-grant
Accessibility each time. To fix that permanently, create a stable signing identity once:

```sh
./Scripts/setup-signing.sh          # one-time: makes a self-signed identity
./Scripts/build-app.sh ~/Applications
```

Now grant Accessibility one last time. Every future rebuild keeps the same identity, so
the permission persists. (Delete the "Lineup Self-Signed" cert from Keychain Access to
undo.)

## Setting column widths — the easy way

Click the menu bar icon → **Align dividers on screen…**. A transparent overlay covers the
G9 with two draggable red lines. Drag each line until it sits on a physical seam — the
live labels show each column's width in pixels — then press **Save** (or Return). The
divider positions are written to `~/.config/lineup/zones.json` in pixels, so the column
edges land exactly on the seams. Press **Cancel** or **Esc** to discard.

The `Hyper + [` / `Hyper + ]` half-split is set to the screen's physical center.

## Configuration file (optional)

You can also edit the config directly. Copy `zones.example.json` to
`~/.config/lineup/zones.json`, edit, then **Reload config** from the menu. If the file is
absent, equal thirds are used.

You don't set each column's width directly — you set the **divider lines** between them,
and the columns are just the regions in between. Because neighbouring columns share a
divider, **moving one divider resizes both columns on either side of it and they stay
glued — gaps and overlaps are impossible**. The columns always fill the whole width.

```json
{
  "dividers": [
    { "value": 0.3333, "unit": "fraction" },
    { "value": 0.6667, "unit": "fraction" }
  ],
  "halfDivider": { "value": 0.5, "unit": "fraction" }
}
```

- `dividers` — one entry per line *between* columns. Two dividers ⇒ three columns
  (`left | center | right`). The first divider is the left/center boundary; the second is
  the center/right boundary.
- `halfDivider` — where `Hyper + [` and `Hyper + ]` split the screen.
- `unit` is one of:
  - `fraction` — `0.0…1.0` of the display width.
  - `points`   — AppKit points from the left edge.
  - `pixels`   — **physical pixels** from the left edge. Use this to land a divider on a
    seam whose pixel position you know.

Think of a divider's value as "where the boundary sits". The widths follow:
left column width = `divider0`, center = `divider1 − divider0`, right = `1 − divider1`.
So to make the left column wider, increase `divider0` — the center column automatically
shrinks by the same amount, and nothing else moves.

The vertical extent always fills the usable area (`visibleFrame`), so windows never slide
under the menu bar or Dock.

### Aligning to Samsung G9 seams — example

On a 5120-px-wide panel with seams at, say, pixels 1707 and 3413, put the dividers right
on them so the column edges land exactly on the lines:

```json
{
  "dividers": [
    { "value": 1707, "unit": "pixels" },
    { "value": 3413, "unit": "pixels" }
  ],
  "halfDivider": { "value": 2560, "unit": "pixels" }
}
```

Replace those pixel values with your monitor's actual seam positions.

## Known limitations (v1)

- Code signing: ad-hoc by default (signature changes each rebuild → re-grant
  Accessibility). Run `./Scripts/setup-signing.sh` once for a stable self-signed identity
  so the permission persists across rebuilds.
- Column x-boundaries are computed against the full display width. A **bottom** Dock
  doesn't affect them (only height). A Dock pinned to the left/right edge will overlap a
  column; move it to the bottom for exact seam alignment.
- Launch-at-login is built in — toggle it from the menu (uses `SMAppService`). It only
  works when running the assembled `Lineup.app`, not the raw `swift run` binary.
- Exact seam landing depends on the app. macOS window sizing via Accessibility is
  advisory: apps with a minimum size or a fixed step (e.g. Terminal's character-cell
  grid) may not land pixel-exact on a seam. Most apps do; these are the exceptions.
- The **Align dividers on screen…** overlay configures the *widest* display (your G9) and
  saves divider positions in its physical pixels. That one layout is applied to other
  displays by scaling through their pixel width; per-display layouts are future work.
- If a Hyper shortcut does nothing, another app (often Magnet) already owns that combo.
  The menu shows `Hotkeys: N/6 FAILED` — disable the other app and click **Retry hotkey
  registration** (no restart needed).

## Project layout

```
Package.swift                 SwiftPM: LineupCore (lib) + lineup (agent) + lineup-tests (runner)
Sources/LineupCore/Geometry.swift   Coordinate flip (Cocoa↔AX) + screen picker (pure)
Sources/LineupCore/Zones.swift      Zone/boundary model + rect math + JSON config (pure)
Sources/lineup/main.swift           Menu-bar agent, config load, hotkey wiring
Sources/lineup/WindowMover.swift    Accessibility focused-window get/set
Sources/lineup/Hotkeys.swift        Carbon RegisterEventHotKey
Sources/lineup/AlignmentOverlay.swift  Drag-the-lines-onto-the-seams overlay
Sources/lineup-tests/main.swift     Dependency-free test harness
Scripts/build-app.sh              Build + assemble + sign Lineup.app
Scripts/setup-signing.sh          One-time stable self-signed identity
Scripts/make-icon.swift           Renders the app icon (1024 PNG)
Scripts/make-icns.sh              PNG -> AppIcon.icns
Resources/Info.plist              Bundle identity (LSUIElement, icon, stable id)
Resources/AppIcon.icns            App icon
zones.example.json                Config template
```

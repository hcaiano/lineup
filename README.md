<div align="center">

<img src="Icon/icon-1024.png" width="128" alt="Lineup icon">

# Lineup

**A private macOS menu-bar utility suite.**

</div>

---

Lineup is Henrique's personal macOS utility suite. It lives in the menu bar and bundles four
tools:

- **Zones** — draw your own window-snapping zone layouts, per screen, and drop windows into them
  with a drag or a keyboard shortcut.
- **Tiles** — automatically place windows in those Zones, with four lightweight workspaces,
  stacked windows, keyboard tile control, and optional 8 pt spacing.
- **Cycler** — cycle through apps and windows with keyboard shortcuts, including app groups and
  reverse cycling.
- **Hyperkey** — turn Caps Lock (or another key) into a "Hyper" key (Control + Option + Shift +
  Command), so a single keypress drives Lineup's shortcuts.

Each tool can be turned on or off independently in Settings. Zones is on by default. Tiles,
Cycler, and Hyperkey start off, so an automatic update never arranges windows or grabs new keys.

## Status

Lineup 2.0 is a **private** rewrite, developed on the `unified-app` branch. It is not distributed
or supported publicly. Lineup 1.x (the single-tool Zones app) was open source under the MIT
license; see [LICENSE](LICENSE) for how that history applies now.

## Build from source

```sh
git clone <this repo> && cd lineup
swift build                          # compiles all targets
swift run lineup-tests               # dependency-free test suite (no Xcode/XCTest needed)
./Scripts/setup-signing.sh           # one-time: stable signature so the macOS permission sticks
./Scripts/build-app.sh ~/Applications
open ~/Applications/Lineup.app
```

See [BUILDING.md](BUILDING.md) for the full project layout, packaging, notarization, and
auto-update setup.

## Configuration

Settings live at `~/.config/lineup/config.json`, one envelope with a section per tool. Lineup 1.x's
`~/.config/lineup/zones.json` is read once, on first launch of 2.0, to import an existing Zones
layout; it is never written to or deleted by 2.0.

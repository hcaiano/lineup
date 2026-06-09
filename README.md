<div align="center">

<img src="Icon/icon-1024.png" width="128" alt="Lineup icon">

# Lineup

**A tiny, native macOS window manager for ultrawide monitors.**

Snap windows into per-screen zones you design yourself — built for the Samsung Odyssey G9,
useful on any display.

</div>

---

Lineup replaces Magnet/Rectangle-style tools with something made for big screens: you draw a
**layout of zones** for each monitor, then snap windows into them by **dragging with a key
held** or with **global shortcuts**. Layouts are recursive (split a zone into columns or rows,
then split again), and each display remembers its own.

- **Native & tiny.** Swift + AppKit, menu-bar only, no Electron, no background CPU.
- **Per-screen layouts.** Your G9 can be three columns while your laptop is two — it switches
  automatically based on which screen a window is on.
- **Pixel-precise.** Column dividers can sit on exact pixels, so window edges land on a
  monitor's physical seams.

## Install

Requires the Xcode **Command Line Tools** (`xcode-select --install`). Full Xcode is not needed.

```sh
git clone https://github.com/hcaiano/lineup.git
cd lineup
./Scripts/setup-signing.sh            # one-time: stable signature so the macOS permission sticks
./Scripts/build-app.sh ~/Applications
open ~/Applications/Lineup.app
```

On first launch, grant **Accessibility** (System Settings → Privacy & Security → Accessibility)
— that's what lets Lineup move other apps' windows. If you use Magnet/Rectangle, disable it so
the shortcuts don't collide.

> Lineup is ad-hoc signed unless you run `setup-signing.sh`. Without it, macOS asks you to
> re-grant Accessibility after every rebuild; with it, you grant once.

## Design your layout

Click the menu-bar icon → **Edit Layout…**. An editor appears over your actual screen:

- **Hover a zone** to reveal its controls: **split side-by-side**, **split stacked**, or
  **merge**. (Icons, not words — split it however you like, as deep as you like.)
- **Drag a divider** to resize. The top-level dividers show a **pixel** readout (drag one onto a
  physical seam); inner dividers show a **percent**.
- Use the **display picker** to edit another monitor.
- **Done** saves; **Cancel**/**Esc** discards. Nothing is saved until you click Done.

Each leaf zone is numbered (1, 2, 3 …) — those numbers are what zone shortcuts target.

## Snap windows

**Drag with Shift held** — the zone under your cursor highlights; release to snap. Toggle it in
**Settings → General** (it's on by default).

**Global shortcuts** (Hyperkey = `⌃⌥⇧⌘`, e.g. Caps Lock remapped via Karabiner):

| Shortcut        | Action                                              |
| --------------- | --------------------------------------------------- |
| `Hyper + ←` / `→` | Left / right — **cycles** your column → ½ → ⅓ → ⅔  |
| `Hyper + ↑`     | Full screen                                         |
| `Hyper + ↓`     | Center                                             |
| `Hyper + [` / `]` | Left / right half                                |

These are the defaults. **Zone shortcuts (snap to Zone 1, 2, 3 …) start unassigned** so they
don't clash with combos you already use. Assign any of them in **Settings → Shortcuts**: click
**Record** and press a combo (Esc cancels, Delete clears). The arrow cycle resets if you pause,
switch windows, or move the window.

## Customize

**Settings…** has two tabs:

- **Shortcuts** — rebind every action (quick actions + each numbered zone) with the key recorder.
- **General** — shift-drag toggle, launch-at-login, Accessibility status.

Config lives at `~/.config/lineup/zones.json` (one layout per display, keyed to the monitor).
You normally never touch it — the editor writes it for you.

## Known limitations

- Window sizing via the Accessibility API is advisory: a few apps with a minimum size or a fixed
  step (e.g. Terminal's character grid) may not land pixel-exact on a seam. Most apps do.
- Top-level column dividers are pixel-exact; nested splits use fractions of their parent.
- The editor edits **connected** displays; a layout for an unplugged monitor is preserved but not
  editable until it's reconnected.

## Build from source

```sh
swift run lineup-tests      # dependency-free test suite (no Xcode/XCTest needed)
swift build -c release      # build the binary
./Scripts/build-app.sh DIR  # assemble + sign Lineup.app into DIR
```

```
Sources/LineupCore/         Pure, tested core (no AppKit)
  ZoneTree.swift            Recursive split-tree model + resolver + editor geometry
  LayoutEdit.swift          Pure split / merge / resize operations
  LineupConfig.swift        Per-screen schema-3 config + migration
  Shortcuts.swift           Shortcut bindings + conflicts + zone actions
  Cycle.swift               Left/right cycle steps + continuation predicate
Sources/lineup/             AppKit agent
  main.swift                Menu-bar app, hotkeys, config lifecycle
  LayoutEditorOverlay.swift The on-screen layout editor
  DragSnap.swift            Shift-drag-to-snap
  SettingsWindow.swift      Shortcuts + General
  WindowMover.swift         Accessibility window get/set
  ShortcutKit.swift         Defaults + Cocoa↔Carbon + combo strings
  Theme.swift               Brand colour + menu-bar logo
Scripts/                    build-app, setup-signing, make-icon, make-icns
```

## License

[MIT](LICENSE) © 2026 Henrique Caiano

<div align="center">

<img src="Icon/icon-1024.png" width="128" alt="Lineup icon">

# Lineup

**A native macOS menu-bar suite for window layouts and keyboard shortcuts.**

[Download](https://lineup.caiano.com) · [Build from source](BUILDING.md) ·
[Contribute](CONTRIBUTING.md)

</div>

![Lineup layout editor with three custom zones](docs/editor.png)

Lineup combines four tools. Enable only the tools you need:

- **Zones:** Draw a window layout on each display. Move windows with Shift-drag or a shortcut.
  Zone shortcuts are numbered across ALL your displays: each display's Settings group shows its
  global zone range, and `zone:N` moves the focused window to that global zone on its owning
  display — even across displays. Numbers belong to saved displays, so unplugging one keeps its
  range reserved (those shortcuts wait safely instead of moving a different display's windows).
  Note that adding or removing zones on an earlier display shifts the numbering of every later
  display, since each display's range follows the one before it.
- **Cycler:** Cycle through apps and windows with shortcuts, including app groups and
  reverse cycling.
- **Hyperkey:** Turn Caps Lock or another key into Control + Option + Shift + Command.
- **Menu Bar:** Reorder app icons and show or hide a selected group with one arrow. Requires
  macOS 27 and is off by default.

Lineup is built with Swift, AppKit, and SwiftUI. It requires macOS 13 or later.

## Install

1. Download the current version from [lineup.caiano.com](https://lineup.caiano.com).
2. Move Lineup to Applications and open it.
3. Allow Accessibility access when macOS asks. Lineup needs it to inspect and move windows.
4. If you enable Hyperkey, allow Input Monitoring when macOS asks. The other tools do not request
   this permission.

## Organize the menu bar

On macOS 27, enable **Menu Bar** in Settings and grant access to the Control Center settings
file shown by the file picker. Accessibility is needed to discover and reorder icons. Screen
Recording and Full Disk Access are not required.

Drag icons between **Visible Items** and **Hidden Items**, then click the arrow in the menu bar
to collapse or expand the selected group. Drag within a group to place an icon before another,
or use its context menu to move left or right. Command-dragging icons directly in the macOS
menu bar also works. Reordering uses a brief native Command-drag.

macOS 27 controls visibility per app: all icons from the same app hide together. System icons
stay visible, and Lineup does not reveal apps you had already disabled in macOS settings.
Lineup starts with the group expanded. Disabling Menu Bar or quitting restores the visibility
Lineup changed. A separate recovery process restores it after a crash; if access has been
revoked, grant it again and use **Restore Items**. Quit other menu bar managers before using
Lineup to avoid competing changes.

This tool depends on the macOS 27 Control Center preference format. Unrecognized formats block
changes. Menu Bar is unavailable on other macOS versions; the other tools still support macOS 13+.

## Update tracks

Stable is the default and receives tested public releases. Nightly is a public opt-in in General
settings for newer builds that may be less reliable. Returning to Stable stops Nightly updates and
waits for a newer Stable release; Lineup does not install an older Stable version as a downgrade.

## Build from source

```sh
git clone https://github.com/hcaiano/lineup.git
cd lineup
swift build
swift run lineup-tests
```

Building needs the macOS 26 SDK or later. Command Line Tools 26 are enough; with the macOS 27 SDK,
the app needs full Xcode 27. See [BUILDING.md](BUILDING.md) to assemble the app, keep a stable
local Accessibility grant, and understand the project layout.

## Contribute

Read [CONTRIBUTING.md](CONTRIBUTING.md) before you report a bug or open a pull request. New features
and behavior changes should start in [Discussions](https://github.com/hcaiano/lineup/discussions).

## License

Lineup is available under the [Apache License 2.0](LICENSE). Releases before 2.0.0 remain under
their [MIT License](LICENSE-1.x).

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
- **Text Capture:** Select a region on any display and copy its text, recognized locally in
  Portuguese and English.

Lineup is built with Swift, AppKit, and SwiftUI. It requires macOS 13 or later.

## Install

1. Download the current version from [lineup.caiano.com](https://lineup.caiano.com).
2. Move Lineup to Applications and open it.
3. Allow Accessibility access when macOS asks. Lineup needs it to inspect and move windows.
4. If you enable Hyperkey, allow Input Monitoring when macOS asks. The other tools do not request
   this permission.

## Copy text from the screen

1. Open Settings → Text Capture and enable the tool. It starts off, with no shortcut assigned.
2. Choose **Capture Text…** in the menu bar or Settings. You can also record a global shortcut
   in its settings. Conflicts with other Lineup tools or apps are reported there.
3. On the first capture, allow Screen Recording in macOS. Enabling the tool alone never asks for
   this permission. If access was denied or revoked, use **Open Screen Recording Settings…** in
   Text Capture or General → Permissions. Quit and reopen Lineup if macOS asks, then try again.
4. Drag around text on one display and release to copy it. Press Escape to cancel selection.
   A drag crossing a display edge is limited to the display where it started.
5. After **Text copied**, paste with Command-V in the destination app. Nothing is pasted automatically.

Empty captures, failed recognition, and cancellation leave the clipboard unchanged. Select a
larger region if small text is missed. The engine reads rows from top to bottom and fragments from
left to right; complex columns and tables may need separate captures. Portuguese and English
language support must both be available in the local macOS recognition engine. If either is
unavailable, Text Capture explains this without replacing the clipboard.

Invoking capture again during selection or recognition does not start another job. Use **Cancel
Text Capture** in the menu to stop pending work. Display changes, disabling the tool, and quitting
Lineup also cancel it. Captures stay in memory and are released after use; Lineup does not keep a
capture history, log the recognized text, or send it to a service. The copied text remains on the
system clipboard until another app or copy action replaces it.

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

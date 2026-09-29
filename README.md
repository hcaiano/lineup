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
- **Keep Awake:** Prevent idle sleep for 15 minutes, 30 minutes, 1 hour, or 2 hours.
  Choose separately whether the display should stay on.

Lineup is built with Swift, AppKit, and SwiftUI. It requires macOS 13 or later.

## Install

1. Download the current version from [lineup.caiano.com](https://lineup.caiano.com).
2. Move Lineup to Applications and open it.
3. Allow Accessibility access when macOS asks. Lineup needs it to inspect and move windows.
4. If you enable Hyperkey, allow Input Monitoring when macOS asks. The other tools do not request
   this permission.

## Keep Awake

Enable Keep Awake in Settings, then choose a duration from its menu-bar submenu or start a
session in Settings. The menu bar shows "Awake" while a session is active. Open its submenu
to see the remaining time or stop early.

"Keep display on" is off by default. Turning it on or off during a session keeps the original
deadline. Choosing another duration starts a new session. Expiration, stopping, disabling the
tool, sleeping the Mac, or quitting Lineup releases its power requests. Waking or restarting
Lineup never resumes a session. Only the duration and display preference are saved.

Keep Awake needs no extra permissions and does not change permanent macOS power settings.
You can still lock the screen or explicitly sleep the Mac. Closed-lid operation is not supported.

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

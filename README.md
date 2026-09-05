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
- **Cycler:** Cycle through apps and windows with shortcuts, including app groups and
  reverse cycling.
- **Hyperkey:** Turn Caps Lock or another key into Control + Option + Shift + Command.
- **Hints:** Press your own global shortcut to label the controls of the frontmost app and activate
  one from the keyboard. Disabled by default; you assign the activation shortcut. Covers
  Accessibility-exposed controls, best effort in Safari, Chromium, and Electron. See
  [docs/hints.md](docs/hints.md).

Lineup is built with Swift, AppKit, and SwiftUI. It requires macOS 13 or later.

## Install

1. Download the current version from [lineup.caiano.com](https://lineup.caiano.com).
2. Move Lineup to Applications and open it.
3. Allow Accessibility access when macOS asks. Zones, Cycler, and Hints use it to inspect windows
   and controls; Hyperkey does not.
4. If you enable Hyperkey, allow Input Monitoring when macOS asks. It is the only tool that needs
   this permission; Hints does not require it.

## Build from source

```sh
git clone https://github.com/hcaiano/lineup.git
cd lineup
swift build
swift run lineup-tests
```

Building needs the macOS 26 SDK. Command Line Tools 26 are enough; full Xcode is optional. See
[BUILDING.md](BUILDING.md) to assemble the app, keep a stable local Accessibility grant, and
understand the project layout.

## Contribute

Read [CONTRIBUTING.md](CONTRIBUTING.md) before you report a bug or open a pull request. New features
and behavior changes should start in [Discussions](https://github.com/hcaiano/lineup/discussions).

## License

Lineup is available under the [Apache License 2.0](LICENSE). Releases before 2.0.0 remain under
their [MIT License](LICENSE-1.x).

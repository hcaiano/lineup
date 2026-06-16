# Building Lineup

For contributors and anyone who wants to build from source. End users should just grab the DMG from
the [Releases page](https://github.com/hcaiano/lineup/releases/latest); see the [README](README.md).

## Requirements

- macOS 13 or later
- Xcode **Command Line Tools** (`xcode-select --install`). Full Xcode is not required.

## Build and run

```sh
git clone https://github.com/hcaiano/lineup.git && cd lineup
swift run lineup-tests              # dependency-free test suite (no Xcode/XCTest needed)
./Scripts/setup-signing.sh          # one-time: stable signature so the macOS permission sticks
./Scripts/build-app.sh ~/Applications
open ~/Applications/Lineup.app
```

A locally built app is ad-hoc signed, whose signature changes every build, so macOS keeps asking
you to re-grant Accessibility. `setup-signing.sh` creates a reused self-signed identity once, so
every build shares one stable signature and you grant Accessibility a single time. The same applies
to releases: build the release DMG on a machine where this has been run, so users authorize once
and updates keep working. Pass `REQUIRE_STABLE_SIGNATURE=1 ./Scripts/build-app.sh dist` to make a
release build fail loudly rather than ship an ad-hoc signature by accident.

## Package the installer

```sh
REQUIRE_STABLE_SIGNATURE=1 ./Scripts/build-app.sh dist   # refuses to build an ad-hoc release
./Scripts/make-dmg.sh dist          # -> dist/Lineup-<version>.dmg; also rejects an ad-hoc app
```

Both steps refuse an ad-hoc signature so a release can't accidentally ship one (which would
make every update drop the user's Accessibility grant). Run `setup-signing.sh` first. For a
throwaway local DMG you can bypass with `ALLOW_ADHOC_DMG=1 ./Scripts/make-dmg.sh dist`.

## Project layout

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
  ShortcutKit.swift         Defaults + Cocoa/Carbon + combo strings
  Theme.swift               Brand colour + menu-bar logo
Scripts/                    build-app, setup-signing, make-dmg, make-icon, make-icns
```

Config lives at `~/.config/lineup/zones.json` (one layout per display, keyed to the monitor). The
editor writes it for you.

## Notarized release (Developer ID)

With an Apple Developer account, a **Developer ID Application** certificate in the keychain
makes `build-app.sh` sign with it automatically (hardened runtime + secure timestamp), which
`notarize.sh` can then submit to Apple. Notarization removes the "unidentified developer"
prompt on first open. One-time credential setup (keeps secrets out of scripts):

```sh
xcrun notarytool store-credentials "lineup-notary" \
  --apple-id <your-apple-id> --team-id <TEAMID> --password <app-specific-password>
```

Release flow (the `REQUIRE_DEVELOPER_ID_SIGNATURE=1` gate fails fast if no Developer ID
identity is found, so a notarized release can't silently fall back to the self-signed cert):

```sh
REQUIRE_DEVELOPER_ID_SIGNATURE=1 ./Scripts/build-app.sh dist   # sign the app w/ Developer ID
./Scripts/notarize.sh dist/Lineup.app                          # notarize + staple the app
./Scripts/make-dmg.sh dist                                     # package it; signs the DMG too
./Scripts/notarize.sh dist/Lineup-<version>.dmg                # notarize + staple the DMG
```

Stapling the app makes the dragged-out copy pass Gatekeeper offline; notarizing the DMG makes
the download itself open cleanly. `notarytool` and `stapler` ship with the Command Line Tools,
so no full Xcode is needed.

# Lineup

Lineup is a native macOS 13+ menu-bar suite of independent tools (Zones,
Cycler, Hyperkey, World Clock, Keep Awake, Text Capture, Scroll).

Read [PRODUCT.md](PRODUCT.md) before changing user-visible behavior or design,
[BUILDING.md](BUILDING.md) for build, packaging and architecture, and
[CONTRIBUTING.md](CONTRIBUTING.md) before preparing or reviewing a pull request.
For feature or app icons, use [lineup-icons](.agents/skills/lineup-icons/SKILL.md).
To launch, drive and record the real app, use
[verify-lineup](.agents/skills/verify-lineup/SKILL.md).

## Protect user state and identity

1. `~/.config/lineup/config.json` is live user data. A failed load blocks
   writes, an explicit reset keeps the rejected bytes before replacing them,
   and writes stay atomic. Tests use temporary paths.
2. `~/.config/lineup/zones.json` and `~/.config/cycler/bindings.json` are
   read-only import sources: never change, move or delete them.
3. The bundle ID, hotkey signature, update feed and signing identity are
   compatibility anchors: keep `Sources/AppCore/Product.swift`,
   `Resources/Info.plist` and the scripts consistent, and the identity tests
   passing.
4. `web/appcast.xml`, `web/downloads/`, tags, notarization, signing keys and
   deployments are release state: change them only for requested release work.

If a task conflicts with one of these contracts, explain the conflict and get
maintainer approval before proceeding.

Launch Lineup on this Mac only when manual app verification is part of the
task: a launch uses the developer's real config, Accessibility grant, hotkeys
and input monitoring. `verify-lineup` runs it in a disposable VM instead. `Scripts/setup-signing.sh` changes the login keychain and needs
explicit intent.

## Verify

Run `swift run lineup-tests` and `swift build` for every code change, plus
`UNIVERSAL=0 ./Scripts/build-app.sh <output-directory>` for package or bundle
changes. With the macOS 27 SDK the app target needs full Xcode: when
`xcode-select -p` points at Command Line Tools, prefix `swift build` with
`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`, or with
`SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.sdk` without Xcode.
Packaging always needs full Xcode 26 or later. Keep `lineup-tests` free of
XCTest so it runs with Command Line Tools alone.

Check every affected path: enable, disable, startup, shutdown and live setting
changes; every entry point (menu bar, Settings, overlays, shortcuts, drag);
Accessibility denied or revoked, hotkey conflicts and missing windows; one and
several displays; and fresh, current, legacy, malformed and newer config.

Keep UI frameworks and system side effects in `Sources/lineup`, and testable
logic in the `*Core` modules. Keep one owner for shared config, hotkey
registration, permissions and tool lifecycle.

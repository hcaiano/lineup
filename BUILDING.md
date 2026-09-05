# Building Lineup

This guide covers local builds, packaging, architecture, and maintainer release tooling. See the
[README](README.md) for the product overview and [CONTRIBUTING.md](CONTRIBUTING.md) for the
contribution workflow.

## Requirements

- Swift 5.9 or later
- Xcode 26 or Xcode **Command Line Tools 26**, so the macOS 26 SDK is available. Full Xcode is
  optional. The built app still supports macOS 13 or later.

## Build and test

```sh
cd lineup
swift build
swift run lineup-tests              # dependency-free test suite (no Xcode/XCTest needed)
```

## Assemble and run the app

For a fast local build, assemble only the host architecture:

```sh
UNIVERSAL=0 ./Scripts/build-app.sh dist
open dist/Lineup.app
```

`build-app.sh` produces a **universal** (arm64 + x86_64) app by default when `UNIVERSAL` is not set,
so release builds run on every supported Mac. A universal build uses separate `--triple` builds and
combines them with `lipo`; it does not need full Xcode. The assembled app includes the Lineup and
Sparkle licence notices in `Contents/Resources`.

Without a stable identity, a local app is ad-hoc signed. Its signature changes every build, so
macOS keeps asking you to re-grant Accessibility. If you plan to launch repeated local builds, run
`./Scripts/setup-signing.sh` once. It adds a self-signed identity to your login Keychain. Each later
build then uses one stable signature. This step is optional for compilation and tests.

The same stable-signature rule applies to releases. Pass
`REQUIRE_STABLE_SIGNATURE=1 ./Scripts/build-app.sh dist` to make a release build fail rather than
ship an ad-hoc signature by accident.

## Package the installer

```sh
REQUIRE_STABLE_SIGNATURE=1 ./Scripts/build-app.sh dist   # refuses to build an ad-hoc release
./Scripts/make-dmg.sh dist          # -> dist/Lineup-<version>.dmg; also rejects an ad-hoc app
```

Both steps refuse an ad-hoc signature so a release can't accidentally ship one (which would
make every update drop the user's Accessibility grant). Run `setup-signing.sh` first. For a
throwaway local DMG you can bypass with `ALLOW_ADHOC_DMG=1 ./Scripts/make-dmg.sh dist`.

## Project layout

Lineup 2.0 is one app shell hosting four independent tools, on top of five pure ("core") modules
and one AppKit executable:

```
Sources/ZonesCore/          Pure, tested core for the Zones tool (no AppKit)
  ZoneTree.swift            Recursive split-tree model + resolver + editor geometry
  LayoutEdit.swift          Pure split / merge / resize operations
  LineupConfig.swift        Per-screen schema-3 config + migration (the legacy zones.json shape)
  Shortcuts.swift           Shortcut bindings + conflicts + zone actions
  Cycle.swift               Left/right cycle steps + continuation predicate
Sources/CyclerCore/         Pure, tested core for the Cycler tool
  WindowCycle.swift         Cycle-order math
  AppGroupCycle.swift       App-group cycling
  Bindings.swift            Legacy ~/.config/cycler/bindings.json model (CyclerConfig)
Sources/HyperkeyCore/       Pure, tested core for the Hyperkey tool
  TriggerKey.swift          Trigger key enum + display names
  HyperKeySettings.swift    Persisted Hyperkey settings + legacy-format migration
Sources/HintsCore/          Pure, tested core for the Hints tool (Foundation only)
  See docs/hints.md         Eligibility, labels, filter/search, session state, geometry, budgets
Sources/AppCore/            Pure. Product/tool identity, the unified config envelope, legacy import
  Product.swift             Identity constants (name, bundle ID, paths, update feed)
  LineupAppConfig.swift     ~/.config/lineup/config.json envelope schema
  LineupAppConfigStore.swift  Load/validate/atomic-write/backup discipline
  LegacyImport.swift        Reads 1.x zones.json + standalone Cycler's bindings.json, once
Sources/lineup/              AppKit agent (the app shell + the four tools)
  main.swift                 Bootstrap only
  App/                        Shell: menu bar, hotkey registry, permissions, activation policy,
                               termination, single-instance, launch-at-login, brand, About
  Settings/                    Settings window: sidebar shell + shared components
  Tools/Zones/                 Layout editor, drag-to-snap, window mover
  Tools/Cycler/                App/window cycling, app picker, cycle HUD
  Tools/Hyperkey/              Caps Lock remap controller, blocked-state pill, recovery
  Tools/Hints/                 AX scanning, per-display hint overlays, panel input, settings pane
Sources/lineup-tests/         Merged, dependency-free test runner (no Xcode/XCTest needed)
  main.swift                  Orchestrates the five suites below
  ZonesSuite.swift / CyclerSuite.swift / HyperkeySuite.swift / HintsSuite.swift / AppSuite.swift
Tests/                        macOS-only adapter XTests (not run by the dependency-free runner)
Scripts/                    build-app, setup-signing, make-dmg, icon and screenshot tools,
                            notarize, Sparkle key/appcast tools, legacy appcast publisher
```

Run the whole suite with `swift run lineup-tests`; it prints a combined pass/fail count across all
five suites.

Settings live at `~/.config/lineup/config.json` — one envelope, one section per tool
(`zones`/`cycler`/`hyperkey`/`hints`). Lineup 1.x's `~/.config/lineup/zones.json` is read once, on
first launch of 2.0, to import an existing Zones layout into that envelope; 2.0 **never writes to
it**. Hints keeps only its activation shortcut and label alphabet in its section.

### Downgrading from 2.0 to 1.9.x

Because 2.0 never touches `zones.json`, rolling back to a 1.9.x build (or older) just works: 1.9.x
reads `zones.json` exactly as 2.0 left it, since 2.0 never wrote to it in the first place. Anything
edited only in 2.0 — Zones changes made after the one-time import, plus all Cycler, Hyperkey, and
Hints settings — lives in `config.json` and does **not** carry back to 1.9.x; that data simply sits unread
until (if ever) 2.0 is reinstalled.

## Notarized release (Developer ID)

Lineup 2.x updates existing users through Sparkle. Every release must use the exact same Developer
ID identity as earlier releases. A different identity changes the app's codesign designated
requirement, and macOS then treats it as a different app for Accessibility purposes. Existing users
would have to grant Accessibility again. Before a release, confirm the signing identity matches the
established one. See `RELEASING.md` and the `security find-identity` step in
`.github/workflows/release.yml`.

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

## Auto-updates (Sparkle)

Lineup updates in place with [Sparkle](https://sparkle-project.org). `build-app.sh` embeds
`Sparkle.framework` and re-signs it inside-out with the same identity as the app; updates are
authenticated with an **EdDSA** signature so a tampered or man-in-the-middled download is
rejected. The feed is `web/appcast.xml`, served at `https://lineup.caiano.com/appcast.xml`, and
pointed to by `SUFeedURL` in `Resources/Info.plist`. Website deploys are currently
maintainer-controlled.

**One-time key setup** (do this once, ever — losing the key means you can't sign future
updates that existing installs will accept):

```sh
./Scripts/sparkle-keygen.sh         # private key -> your login Keychain (never committed)
```

Paste the printed public key into `Resources/Info.plist` under `SUPublicEDKey` (replacing the
placeholder). That's the only Sparkle value that ships in the app. The private key stays in
your Keychain, exactly like the notarization credential.

Downloads are **self-hosted** from 2.0.0 on: `sparkle-appcast.sh` stages the DMG into
`web/downloads/` and points the enclosure at `https://lineup.caiano.com/downloads/<file>`.
Installed copies do not depend on GitHub to fetch updates.

**Per release**, after notarizing *and stapling* the DMG:

```sh
./Scripts/sparkle-appcast.sh dist/Lineup-<version>.dmg   # EdDSA-signs the DMG, writes web/appcast.xml
(cd web && npx wrangler deploy)                          # publishes the feed + the download
git add web/appcast.xml web/downloads web/release-notes && git commit -m "Appcast: <version>"
```

Write the release notes first, as an HTML **fragment** in `web/release-notes/<version>.html`;
the script inlines it as the item `<description>` and links it from `sparkle:releaseNotesLink`.

Two rules the feed depends on:

- **`CFBundleVersion` must be strictly monotonic.** Sparkle offers an update only when the
  appcast's `sparkle:version` sorts above the running app's `CFBundleVersion`. 1.9.0 shipped as
  build 17, so 2.0.0 ships as 18; reusing a build number makes the release invisible to
  everyone who already has it.
- **Never delete a hosted DMG.** `web/downloads/` is committed because the Cloudflare asset
  manifest is the *whole* of `web/` — deploying from a checkout that lacks those files would
  unpublish them and break every older entry in the feed.

The full release sequence is therefore: `build-app.sh` → `notarize.sh` (app) → `make-dmg.sh` →
`notarize.sh` (DMG) → `sparkle-appcast.sh` → `wrangler deploy` → commit.

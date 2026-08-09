# Building Lineup

Lineup 2.0 is a **private** rewrite (branch `unified-app`); it is not distributed publicly. This
file is for building it from source. See the [README](README.md) for what the app does.

## Requirements

- macOS 13 or later
- Xcode **Command Line Tools** (`xcode-select --install`). Full Xcode is not required.

## Build and run

```sh
cd lineup
swift run lineup-tests              # dependency-free test suite (no Xcode/XCTest needed)
./Scripts/setup-signing.sh          # one-time: stable signature so the macOS permission sticks
./Scripts/build-app.sh ~/Applications
open ~/Applications/Lineup.app
```

`build-app.sh` produces a **universal** (arm64 + x86_64) app by default, so it runs on every
supported Mac. For faster local iteration, `UNIVERSAL=0 ./Scripts/build-app.sh …` builds the
host arch only. (One-shot `--arch` needs full Xcode; under Command Line Tools each slice is
built with `--triple` and combined with `lipo`.)

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

Lineup 2.0 is one app shell hosting three independent tools, on top of four pure ("core") modules
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
Sources/AppCore/            Pure. Product/tool identity, the unified config envelope, legacy import
  Product.swift             Identity constants (name, bundle ID, paths, update feed)
  LineupAppConfig.swift     ~/.config/lineup/config.json envelope schema
  LineupAppConfigStore.swift  Load/validate/atomic-write/backup discipline
  LegacyImport.swift        Reads 1.x zones.json + standalone Cycler's bindings.json, once
Sources/lineup/              AppKit agent (the app shell + the three tools)
  main.swift                 Bootstrap only
  App/                        Shell: menu bar, hotkey registry, permissions, activation policy,
                               termination, single-instance, launch-at-login, brand, About
  Settings/                    Settings window: sidebar shell + shared components
  Tools/Zones/                 Layout editor, drag-to-snap, window mover
  Tools/Cycler/                App/window cycling, app picker, cycle HUD
  Tools/Hyperkey/              Caps Lock remap controller, blocked-state pill, recovery
Sources/lineup-tests/         Merged, dependency-free test runner (no Xcode/XCTest needed)
  main.swift                  Orchestrates the four suites below
  ZonesSuite.swift / CyclerSuite.swift / HyperkeySuite.swift / AppSuite.swift
Scripts/                    build-app, setup-signing, make-dmg, make-icon, make-icns,
                            notarize, sparkle-keygen, sparkle-appcast
```

Run the whole suite with `swift run lineup-tests`; it prints a combined pass/fail count across all
four suites.

Settings live at `~/.config/lineup/config.json` — one envelope, one section per tool
(`zones`/`cycler`/`hyperkey`). Lineup 1.x's `~/.config/lineup/zones.json` is read once, on first
launch of 2.0, to import an existing Zones layout into that envelope; 2.0 **never writes to it**.

### Downgrading from 2.0 to 1.9.x

Because 2.0 never touches `zones.json`, rolling back to a 1.9.x build (or older) just works: 1.9.x
reads `zones.json` exactly as 2.0 left it, since 2.0 never wrote to it in the first place. Anything
edited only in 2.0 — Zones changes made after the one-time import, plus all Cycler and Hyperkey
settings — lives in `config.json` and does **not** carry back to 1.9.x; that data simply sits unread
until (if ever) 2.0 is reinstalled.

## Notarized release (Developer ID)

**2.0.0 ships to existing Lineup users as an automatic Sparkle update, not a fresh install.**
Shipping it requires signing with the exact **same Developer ID identity** used for 1.x releases.
A different identity changes the app's codesign designated requirement, and macOS then treats it
as a different app for Accessibility purposes — every existing user would have to re-grant
Accessibility by hand after the update, with no warning first. Before cutting a 2.0.0 release,
confirm the signing identity matches 1.x (see `RELEASING.md`'s `BUILD_CERTIFICATE_BASE64` secret
and the `security find-identity` step in `.github/workflows/release.yml`).

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
rejected. The feed is `web/appcast.xml`, served at `https://lineup.caiano.com/appcast.xml`
(auto-deployed from `web/`), and pointed to by `SUFeedURL` in `Resources/Info.plist`.

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
Nothing in the feed touches GitHub, so this repository can be private without breaking
auto-updates for installed copies.

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

The full release sequence is therefore: `build-app.sh` → `make-dmg.sh` → `notarize.sh` (DMG)
→ `sparkle-appcast.sh` → `wrangler deploy` → commit.

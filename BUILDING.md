# Building Lineup

This guide covers local builds, packaging, architecture, and maintainer release tooling. See the
[README](README.md) for the product overview and [CONTRIBUTING.md](CONTRIBUTING.md) for the
contribution workflow.

## Requirements

- Swift 5.9 or later
- The macOS 26 SDK or later. Xcode **Command Line Tools 26** are enough for the macOS 26 SDK; full
  Xcode is optional. The built app still supports macOS 13 or later.
- With the macOS 27 SDK, the app target needs full **Xcode 27**. That SDK makes SwiftUI's `@State`
  a macro whose compiler plugin ships only inside `Xcode.app`, so Command Line Tools 27 stop with
  `plugin for module 'SwiftUIMacros' not found`. Select Xcode once with
  `sudo xcode-select -s /Applications/Xcode.app/Contents/Developer`, or prefix a single command
  with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`. Without Xcode, build against the
  macOS 26 SDK that Command Line Tools 27 still include:
  `SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.sdk swift build`.
  `swift run lineup-tests` works with Command Line Tools 27 alone.

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
combines them with `lipo`, which ships with the Command Line Tools. The assembled app includes the
Lineup and Sparkle licence notices in `Contents/Resources`.

Without a stable identity, a local app is ad-hoc signed. Its signature changes every build, so
macOS keeps asking you to re-grant Accessibility. If you plan to launch repeated local builds, run
`./Scripts/setup-signing.sh` once. It adds a self-signed identity to your login Keychain. Each later
build then uses one stable signature. This step is optional for compilation and tests.

Stable is the default build and update track. To assemble a Nightly variant, pass explicit
overrides; the script keeps `CFBundleShortVersionString` in Apple's numeric `X.Y.Z` shape and puts
the prerelease value in the numeric-with-development-suffix `CFBundleVersion`:

```sh
LINEUP_BUILD_CHANNEL=nightly \
LINEUP_VERSION=2.0.3 \
LINEUP_BUILD_VERSION=20.02.42a001 \
UNIVERSAL=0 ./Scripts/build-app.sh dist/nightly
```

`LINEUP_BUILD_CHANNEL=nightly` without both overrides fails closed. Run
`./Scripts/nightly-release.sh` to resolve the next patch tag, date, sequence, and bundle version.
The Nightly marker is written only to the assembled bundle; the checked-in plist remains Stable.
Nightly assembly also embeds `LineupSourceCommit` from `git rev-parse HEAD` and requires a clean
checkout, so the marker proves the source used for the artifact. The script builds from a detached
Git worktree at that exact commit, with a new SwiftPM `.build` directory, so edits or stale output
in the caller's checkout cannot enter the artifact. `LINEUP_ALLOW_DIRTY=1` is a test-only escape
for local bundle inspection: it writes a `dirty-<sha>` source marker and `LineupSourceDirty=true`,
which the appcast gate rejects. It must never be used for a release. The source checkout is
rechecked after compilation and before the marker is written. `build-app.sh` rechecks the same HEAD
and checkout state; any concurrent change aborts the Nightly assembly.

The helper is read-only. It reads the public repository with `gh api`, never creates or uploads a
release, and never uses the moving `latest` alias. After the exact public prerelease exists and its
asset is attached by the maintainer, the Nightly appcast command runs this verification itself
before it can update the feed. Run `--verify` separately when an audit-only check is useful:

Nightly appcast publication accepts only the exact canonical public repository
`hcaiano/lineup`; a public fork or another repository is rejected even when its tag and asset
bytes match. The metadata helper's repository override remains for read-only audits and tests,
but it cannot bypass the appcast publication guard.

`--verify` requires GitHub to report `immutable=true` for the exact release and peels its Git tag
ref to the local source commit. Nightly publication fails closed until the maintainer enables
GitHub immutable releases. The scripts do not change repository settings.

For unattended publication after successful `main` CI, see [NIGHTLIES.md](NIGHTLIES.md).
The release-Mac service reuses these scripts, checkpoints each release and preserves the public
feed when publishing. Stable remains manual. Activating the service also makes its shared
`publish-web` command the required entry point for Stable and website deploys.

The default release audit and Nightly build refuse a dirty checkout; `LINEUP_ALLOW_DIRTY=1` is
reserved for explicitly read-only local tests and must not be used for a release plan or release
build. The appcast helper reads `LineupSourceCommit` from
the mounted DMG and passes it to `--expected-source-sha`; this permits an exact appcast rerun after
the feed commit changes the checkout, while still requiring the public tag to peel to the artifact's
source commit.

```sh
./Scripts/nightly-release.sh --verify v2.0.3-nightly.20260830.1
./Scripts/make-dmg.sh dist/nightly
mv dist/nightly/Lineup-2.0.3.dmg \
   dist/nightly/Lineup-2.0.3-nightly.20260830.1.dmg
./Scripts/sparkle-appcast.sh --nightly \
  dist/nightly/Lineup-2.0.3-nightly.20260830.1.dmg \
  https://github.com/hcaiano/lineup/releases/download/v2.0.3-nightly.20260830.1/Lineup-2.0.3-nightly.20260830.1.dmg \
  2.0.3-nightly.20260830.1 20.02.42a001
```

`make-dmg.sh` names the local image from the numeric bundle version. Rename it to
`Lineup-<nightly-version>.dmg` before attaching it to the public prerelease: this is the exact
asset name that `nightly-release.sh --verify` requires.

`CFBundleVersion` is deliberately based on the current Stable build. With Stable build `20`, the
pinned Sparkle comparator orders `20 < 20.00.01a001 < 20.00.01a002 < 20.01.00a001 < 21`.
The `a1...a255` suffix range is Apple-valid and leaves a later Stable build able to supersede
every Nightly build. The T3 Nightly version is used for the tag, asset name, and appcast
`sparkle:shortVersionString`; the bundled `CFBundleShortVersionString` stays numeric.

The same stable-signature rule applies to releases. Pass
`REQUIRE_STABLE_SIGNATURE=1 ./Scripts/build-app.sh dist` to make a release build fail rather than
ship an ad-hoc signature by accident.

## Package the installer

For feature artwork and the application icon, use the repository's
[lineup-icons skill](.agents/skills/lineup-icons/SKILL.md). `./Scripts/make-icns.sh` exports the
selected master from `Design/AppIcon/manifest.json` to a 1024 px PNG, a macOS Xcode appiconset
and `Resources/AppIcon.icns`. It does not redraw a missing master. See the
[app icon standard](Design/AppIcon/README.md) for sizes, visual checks and provenance.

```sh
REQUIRE_STABLE_SIGNATURE=1 ./Scripts/build-app.sh dist   # refuses to build an ad-hoc release
./Scripts/make-dmg.sh dist          # -> dist/Lineup-<version>.dmg; also rejects an ad-hoc app
```

Both steps refuse an ad-hoc signature so a release can't accidentally ship one (which would
make every update drop the user's Accessibility grant). Run `setup-signing.sh` first. For a
throwaway local DMG you can bypass with `ALLOW_ADHOC_DMG=1 ./Scripts/make-dmg.sh dist`.

## Project layout

Lineup is one app shell hosting nine independent tools, on top of eight pure ("core") modules
and one AppKit executable:

```
Sources/ZonesCore/          Pure, tested core for the Zones tool (no AppKit)
  ZoneTree.swift            Recursive split-tree model + resolver + editor geometry
  LayoutEdit.swift          Pure split / merge / resize operations
  LineupConfig.swift        Per-screen schema-3 config + migration (the legacy zones.json shape)
  Shortcuts.swift           Shortcut bindings + conflicts + zone actions
  Cycle.swift               Left/right cycle steps + continuation predicate
  AppZonePlacement.swift    Saved per-app targets and one-shot launch restoration state
Sources/CyclerCore/         Pure, tested core for the Cycler tool
  WindowCycle.swift         Cycle-order math
  AppGroupCycle.swift       App-group cycling
  Bindings.swift            Legacy ~/.config/cycler/bindings.json model (CyclerConfig)
Sources/HyperkeyCore/       Pure, tested core for the Hyperkey tool
  TriggerKey.swift          Trigger key enum + display names
  HyperKeySettings.swift    Persisted Hyperkey settings + legacy-format migration
Sources/KeyboardRemapCore/  Physical keys, device selection, map composition and ownership journal
Sources/WorldClockCore/     Place search, absolute-time simulation, formatting and solar math
Sources/TextCaptureCore/    Display-local capture geometry, reading order, and cancellation gate
Sources/ScrollCore/         Scroll device classification, gesture continuity and per-axis reversal
Sources/AppCore/            Pure. Product/tool identity, the unified config envelope, legacy import
  AwakeSession.swift        Timed power-request ownership and failure cleanup
  AwakeSettings.swift       Keep Awake preferences, with unknown-key preservation
  Product.swift             Identity constants (name, bundle ID, paths, update feed)
  LineupAppConfig.swift     ~/.config/lineup/config.json envelope schema
  LineupAppConfigStore.swift  Load/validate/atomic-write/backup discipline
  LegacyImport.swift        Reads 1.x zones.json + standalone Cycler's bindings.json, once
  WorldClockSettings.swift  Versioned clock section; preserves unknown place/settings fields
  TextCaptureSettings.swift  Optional shortcut in the existing opaque tool-section envelope
  MenuBarSettings.swift     Menu Bar settings, arrow-boundary groups and auto-hide policy
  MenuBarPreferences.swift  Selective native visibility edits and recovery journal model
  KeyboardRemapSettings.swift  Versioned per-keyboard rules in the existing config envelope
  ScrollSettings.swift      Scroll device and direction preferences, with unknown-key preservation
Sources/lineup/              AppKit agent (the app shell + the nine tools)
  main.swift                 Bootstrap only
  App/                        Shell: menu bar, hotkey registry, permissions, activation policy,
                               termination, single-instance, launch-at-login, brand, About
  Settings/                    Settings window: sidebar shell + shared components
  Tools/Zones/                 Layout editor, drag-to-snap, window mover
  Tools/Cycler/                App/window cycling, app picker, cycle HUD
  App/KeyboardMappingService.swift  Shared per-service HID map owner and recovery
  Tools/Hyperkey/              Hyperkey event tap, blocked-state pill, legacy ownership handoff
  Tools/KeyboardRemap/         Keyboard selection, physical key editor and layout-aware labels
  Tools/WorldClock/            Dedicated status item, popover, place management and Settings
  Tools/Awake/                 IOKit idle-sleep requests, menu countdown, session settings
  Resources/WorldClock/        Offline GeoNames city catalog and attribution
  Tools/TextCapture/           ScreenCaptureKit selection/capture, Vision OCR, clipboard, Settings
  Tools/MenuBar/               Menu bar inventory, arrow, native visibility and recovery
  Tools/Scroll/                Scroll event tap, device lookup and Settings
Sources/lineup-tests/         Merged, dependency-free test runner (no Xcode/XCTest needed)
  main.swift                  Orchestrates the suites below
  ZonesSuite.swift / CyclerSuite.swift / HyperkeySuite.swift / KeyboardRemapSuite.swift / WorldClockSuite.swift / AppSuite.swift / AwakeSuite.swift / TextCaptureSuite.swift / MenuBarSuite.swift / ScrollSuite.swift / NightlyAutomationSuite.swift
Scripts/                    build-app, setup-signing, make-dmg, icon and screenshot tools,
                            notarize, Sparkle key/appcast tools, legacy appcast publisher
```

### Keyboard maps and recovery

`KeyboardMappingService` owns every `UserKeyMapping` write. Hyperkey contributes Caps Lock to
F18 only while its Caps Lock trigger is available. Keyboard Remap contributes physical HID
pairs selected by a built-in flag or an external hardware fingerprint. Product names are labels;
external selection uses vendor/product IDs, transport and a serial number or location. Ambiguous
matches block the selected rule instead of applying it to several services.

The service uses Apple's per-service IOKit APIs from
[TN2450](https://developer.apple.com/library/archive/technotes/tn2450/_index.html).
It reads and validates each complete table, removes only exact journaled pairs, and composes
the desired rules with external pairs. A pre-existing identical pair remains externally owned.
Conflicting sources and incompatible F18 routes block application. Unreadable tables never
authorize a write. Enumeration, composition, writes and recovery run on one serial queue.
Wake and a three-second inventory refresh recover maps after sleep and reconnection.
The timer runs while Hyperkey is requested, nonempty remap rules are enabled, or a legacy
ownership claim or recovery is pending. It stops after idle cleanup. Startup, wake and explicit
Refresh still update the inventory. Requests made during a refresh coalesce into one more pass
after the current snapshot. A disconnected saved keyboard keeps its per-keyboard
status and waits for reconnection without raising an app-wide mapping warning.

`~/.config/lineup/keyboard-mappings-recovery.json` stores ownership independently of tool
preferences. Its boot-session identifier prevents replaying a RegistryID after reboot.
Transactions record old and proposed owned pairs atomically before writing, re-read the table
before applying, and verify the result before finalizing ownership. macOS provides no atomic
compare-and-swap for this property; the re-read detects intervening writes but cannot lock out
another remapper. Cleanup retains failed claims for retry and preserves changed destinations
and additional external pairs. A shared menu warning and Settings recovery action remain
available when a tool is disabled but its previous pairs could not be released.
The bounded exit cleanup releases journaled pairs after normal termination;
the next start recovers after an interruption.
Legacy ownership claims are acknowledged only after the current request journals them. A later
explicit claim is imported again even if an earlier claim was transferred in the same session.
An empty keyboard inventory leaves the claim pending for the next connected keyboard.

The existing schema-1 config envelope stores `tools.keyboardRemap` as an optional version-1
section. Settings saves through `ToolConfigScope` before changing runtime rules and preserves
unknown fields in settings, rules, selectors and pairs. Future or malformed sections block the
tool's editing and application. Other tools keep their own sections.

For visual inspection without starting tools or reading live config, the existing debug preview
command also renders empty and configured Keyboard Remap panes:

```sh
LINEUP_RENDER_PREVIEW=<existing-output-directory> swift run lineup
```

These panes use an in-memory config and an inventory-only mapping service. They do not prove
keyboard input behavior. Before release, verify the built-in ISO/grave swap alongside an
external keyboard, plain and Shift input, held-key repeat, wake, reconnect, live edits, every
Hyperkey/Keyboard Remap enable combination and quit. Check conflicts, denied or revoked Input
Monitoring for Hyperkey, and recovery after interruption with later external changes. Capture
the screenshots and keyboard-interaction video required by `CONTRIBUTING.md`.
Display geometry, window dragging and capture overlays do not apply to this tool.

### Menu Bar runtime and recovery

Menu Bar starts disabled and supports macOS 27 only. macOS 27 draws the whole menu bar in one
`MenuBarAgent` window, so widening a spacer or moving item windows no longer works. The tool
changes only selected `isAllowed` flags in Control Center's `trackedApplications` preference.
It does not use assessment-mode restrictions: those also suppress the native audio/video capture
control and block Notification Center.

`MenuBarPreferenceAccess` validates the selected-file bookmark, then resolves the private Core
Foundation container-preference functions at runtime. It reads and writes the
`group.com.apple.controlcenter` domain in its group container. Passing the plist's absolute path
as a preference domain can save flags without notifying MenuBarAgent. Missing functions or an
unrecognized preference format block writes. Only the tracked-app key changes; unknown records
and unrelated settings remain untouched. Bundle records are keyed by bundle ID, and supported
`adhocBinary` records by their absolute executable URL. URL records inside a selected app's bundle
include its tray helpers, so Synergy can be hidden or kept visible without affecting other apps.

The arrow is the group boundary. `MenuBarLayout` reads Accessibility menu-extra frames from an
expanded bar and compares them with the arrow's frame in the global top-left coordinates shared
by AX and Core Graphics. An app with an icon on each side stays visible; apps absent from the
arrow's display keep their remembered group. System owners never join the group. AX frames
outside the arrow's row are ignored, and reads wait 0.6 seconds after expansion for settlement.
The last group is saved atomically in `tools.menuBar.hiddenOwners` before hiding begins.

Before any native flag changes, a journal records the original allowed flags and a separate
`--menu-bar-recovery` process acknowledges its session. That helper restores only recorded flags
when the parent exits, including SIGKILL. Normal expansion, disabling and quitting restore the
same transaction. Startup restores an orphaned journal even when Menu Bar is disabled or config
writes are blocked. A failed restoration retains the journal and offers Restore Icons and Grant
Access. Apps already disabled by the user stay disabled. Newly registered hidden-app records
extend the same journal before their flags change; other new apps keep their native visibility.

Collapse happens at start, after wake, on the arrow, and 10 seconds after expansion.
`MenuBarAutoHide.shouldWait` postpones it while the pointer is on a menu bar or a hidden app has
a menu or popover below it, using window owner, layer and bounds without reading titles. Wake
restores flags and waits one second before rescanning and collapsing. Display changes restore
flags and rescan; an expanded group keeps its auto-hide delay, and hiding waits for interaction.
Accessibility revocation restores the current transaction. Lineup never posts input events or
moves the pointer; users arrange icons with Command-drag.

For interactive review, a **debug** build accepts `LINEUP_MENU_BAR_REVIEW_DIR=<scratch-directory>`.
It opens the real Menu Bar pane with `review-config.json` in that directory and does not run the
main shell or other tools. For an existing layout, use the production bundle identity in a signed
review bundle so macOS can reuse the arrow's saved position. Keep the review configuration separate
and run only one copy. A fresh bundle identity creates a separate arrow slot and needs manual
arrangement and an explicit permission grant. Never commit review recordings.
The review refuses to start alongside the installed Lineup, because its separate config cannot
isolate the Mac's menu bar. Quit Lineup for the review session, with the maintainer's agreement
to pause any live-build service that would reopen it. Restore the normal app after testing.

Run the whole suite with `swift run lineup-tests`; it prints a combined pass/fail count across all
registered suites.

Text Capture uses a one-frame `SCStream` so the capture path also works on macOS 13. The filter
excludes selection-window IDs before the overlays close. AppKit global coordinates become
display-local top-left points; output dimensions use that display's backing scale. Vision runs
off the main thread with revision 3 and locally supported Portuguese/English language codes.
Every asynchronous completion checks its invocation token, display topology, and permission
before the clipboard can change. Stopping the tool invalidates the token before cancelling the
stream and Vision request. No captured image or recognized text is persisted or logged.

For manual Text Capture verification, record this sequence on the actual app:

1. Enable it in Settings; verify no Screen Recording prompt appears. Assign a shortcut, including
   a conflicting shortcut to check the existing warning and retry path.
2. Capture Portuguese accents and English across multiple lines, then paste in a plain-text
   editor. Record selection, the copy notice, and the pasted result. Check VoiceOver's notice.
3. Start with a known clipboard value. Cancel a selection, capture an empty region, and deny
   Screen Recording. Each must preserve the value. Follow the Settings recovery action.
4. Repeat on Retina/scaled and secondary displays with negative or vertically offset origins.
   Change the display arrangement during selection; it must cancel without copying.
5. Invoke repeatedly during selection and recognition. Disable the tool and quit during pending
   work; no overlay or late clipboard write may survive. Re-enable and verify the saved shortcut.

The dependency-free suite checks geometry, reading order, settings persistence, and the clipboard
commit gate. It does not prove macOS permission prompts, live OCR quality, or compositor behavior.

Settings live at `~/.config/lineup/config.json` — one envelope, one section per tool
(`zones`/`cycler`/`hyperkey`/`keyboardRemap`/`worldClock`/`awake`/`textCapture`/`menuBar`/`scroll`). Lineup 1.x's `~/.config/lineup/zones.json` is read once, on first
launch of 2.0, to import an existing Zones layout into that envelope; 2.0 **never writes to it**.

### App launch placement

Zones stores an optional `appPlacements` map in its existing settings section. Older files need no
migration. The tool saves learned destinations through `ToolConfigScope` only after a successful
explicit move, and updates its in-memory config only after the atomic save succeeds. Learning waits
while no Zones section exists, preserving a deferred legacy import. A fresh installation already
has its default section seeded by the importer. The map uses bundle IDs and exact display keys. A target includes its layout tree and relative geometry, so it
cannot follow a reused zone number. Layout editor saves preserve the latest learned associations
and invalidate those on edited displays.

`AppLaunchPlacementController` listens to the workspace's launch and termination notifications.
It ignores processes already running when Zones starts. For a new associated app it reads existing
windows, observes AX window creation and focus changes, and briefly probes for windows while the
app initializes. AX discovery runs on a serial background queue per launch, so a busy app cannot
block the main run loop used by Hyperkey. Observer callbacks only enqueue discovery work.
A notified window is checked before querying the app's window list. Cancellation removes the
observer immediately and discards queued results, including results from an earlier process session. Those probes stop after five seconds; a supported AX observer can continue waiting
for the first document window. If the app supports neither notification, discovery ends after that
initial period. AX calls have a short timeout and startup retries back off to one second. After
the discovery deadline, a supported observer waits for the next notification only if the last
window list was readable. An unreadable window ends the attempt, and an unresolved list ends it
at the deadline. Closed windows and missing or unsupported role/subrole attributes remain ineligible rather
than cancelling the launch. This prevents a later document from consuming a missed first-window restore.
Only non-modal standard windows qualify. The controller removes observation before the move attempt,
including when the destination is unavailable. It does not subscribe to window movement or resizing.

For manual verification, record a zone shortcut or Shift-drag placement, quit the target app, then
relaunch it and show the first window returning. Open another window and move the restored window
freely to confirm there is no further enforcement. Repeat with the saved external display
disconnected, then reconnect it and relaunch the app to confirm the association was retained.
Use `--long-splash --busy-start` with the probe to delay its first document for eight seconds and
simulate an unresponsive app during startup. Keyboard input and the menu bar should remain responsive. For a repeatable live check, run
`./Scripts/placement-probe.sh --check-discovery`. It compiles the production launch controller,
launches only the document-free fixture, and verifies discovery after a long splash and a helper panel that closes immediately while a
main-run-loop timer stays responsive, then checks cancellation while the fixture is busy and verifies that an unreadable first
document cannot redirect restoration to its later window.
It requires existing Accessibility access and never edits
Lineup settings. Run it manually, outside the dependency-free test suite.
Use `./Scripts/placement-probe.sh` to build a document-free native test app in a fresh temporary
folder. Open the printed app path. It starts every process at a fixed frame and never saves window
positions, so an app's own restoration cannot masquerade as Lineup's behavior. Shift-Command-M moves
the focused window freely; Command-N opens a second window. Quit it, wait for the process to exit,
and run `open -n "<printed app path>" --args --splash` to show a transient panel for three seconds
before the first regular window. Discard the temporary bundle with `trash` when finished.

Also check a splash or sheet before the first regular window, Zones disabled, and Accessibility
revoked. Run these checks with a review build and collect before/after screenshots and a short video
as required by [CONTRIBUTING.md](CONTRIBUTING.md).

### World Clock data and lifecycle

`WorldClockCore` uses Foundation only. The app's existing resource bundle carries `WorldClock/`
alongside the tool icons; `build-app.sh` copies both into the assembled app. The catalog loader
handles missing resources without trapping and keeps time-zone-only search available.

To update city data, download `cities15000.zip` and `admin1CodesASCII.txt` from
<https://download.geonames.org/export/dump/>, then run:

```sh
python3 Scripts/import-clock-cities.py /path/to/cities15000.zip /path/to/admin1CodesASCII.txt
```

The generated notice records attribution, transformations and input hashes. Commit the catalog
and notice together. No runtime download or new package dependency is required. Solar estimates
use NOAA's fractional-year equations with a 0.833-degree apparent horizon; calculations search
absolute instants through the city's next day, including polar and date-line cases.

The tool owns its status item and observers. It refreshes on time-zone, locale, clock, display and
wake notifications. A minute timer exists only while a place is pinned or the popover is open.
Stopping removes those resources and retains saved places. The `worldClock` section has its own
version without changing the shared envelope schema. Unreadable or future settings block editing.
Unknown settings, place and coordinate fields survive supported edits. Removing a pinned place
also clears the pin in the same atomic save.

The parsed city catalog stays cached for the app session so reopening search does not reload it.
A load already in progress finishes into that cache when the panel closes. Search cancellation
discards stale results. If the shared configuration is reset after a failed load, editing becomes
available immediately. An unreadable World Clock section is left intact: quit Lineup, restore its
valid saved data, then reopen Lineup, or install a newer compatible version. There is no section-reset
action in this release.

### Downgrading from 2.0 to 1.9.x

Because 2.0 never touches `zones.json`, rolling back to a 1.9.x build (or older) just works: 1.9.x
reads `zones.json` exactly as 2.0 left it, since 2.0 never wrote to it in the first place. Anything
edited only in 2.0 — Zones changes made after the one-time import, plus all Cycler and Hyperkey
settings — lives in `config.json` and does **not** carry back to 1.9.x; that data simply sits unread
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

Stable and Nightly share that feed, public bundle ID, config file, and TCC identity. The General
settings window has one **Update track** picker. Stable is the default. A first Nightly install
follows its bundle marker, while an explicit choice in `config.json` wins across later installs.
Sparkle always includes the default channel; Nightly adds only `nightly` through its updater
delegate. Changing the track updates the delegate at once, so any feed read that has not been
filtered yet uses the new choice; the update-cycle reset waits until Sparkle is idle (it ignores a
reset during a session or its pre-schedule installer probe). Selecting Stable on a newer Nightly
build stops Nightly checks; Sparkle waits for a newer Stable build and does not auto-downgrade to
an older Stable item. An update already selected or shown finishes on its original track. One
exception outlives the switch: a Nightly the user downloaded and dismissed is resumed before the
feed is read, and one that began installing installs on quit. Settings then shows the switch to
Stable as pending until the user chooses Skip This Version.

**One-time key setup** (do this once, ever — losing the key means you can't sign future
updates that existing installs will accept):

```sh
./Scripts/sparkle-keygen.sh         # private key -> your login Keychain (never committed)
```

Paste the printed public key into `Resources/Info.plist` under `SUPublicEDKey` (replacing the
placeholder). That's the only Sparkle value that ships in the app. The private key stays in
your Keychain, exactly like the notarization credential.

Stable downloads are **self-hosted** from 2.0.0 on: `sparkle-appcast.sh` stages the DMG into
`web/downloads/` and points the enclosure at `https://lineup.caiano.com/downloads/<file>`.
Nightly appcast items are signed from the exact local DMG but point at the immutable, public
GitHub prerelease asset for their exact tag. Nightly DMGs are therefore not copied into git.
Installed Stable copies do not depend on GitHub to fetch updates.

**Per release**, after notarizing *and stapling* the DMG:

```sh
./Scripts/sparkle-appcast.sh dist/Lineup-<version>.dmg   # EdDSA-signs the DMG, writes web/appcast.xml
(cd web && npx wrangler deploy)                          # publishes the feed + the download
git add web/appcast.xml web/downloads web/release-notes && git commit -m "Appcast: <version>"
```

When the automatic Nightly service is active, replace the direct Wrangler command above with
`python3 Scripts/nightly-service.py publish-web web` on the release Mac. This uses the same
publication lock and preserves public Nightly entries; see [NIGHTLIES.md](NIGHTLIES.md).

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

## Scroll event tap

Scroll installs one active session event tap for scroll-wheel events only, appended after other
session taps, and only while the tool runs with a device and direction selected and Accessibility
is granted. The tap's run-loop source lives on a dedicated thread: every scroll on the Mac waits
for an active tap, so the main thread must not delay it. The callback always returns the original
event, modified in place; it never posts events. When macOS disables the tap for a timeout, the
callback re-enables it and events pass through unchanged meanwhile. A crash removes the tap with
the process.

Each event is attributed through its attached `IOHIDEvent`. `CGEventCopyIOHIDEvent` and
`IOHIDEventGetSenderID` are private, resolved with `dlsym`; when either is missing the tool reports
that it is unsupported and installs nothing. The sender is the registry ID of the HID service that
produced the event. `IORegistryEntryIDMatching` finds the service; its driver class,
`DeviceUsagePairs` and Apple vendor/product IDs decide mouse or trackpad in `ScrollDeviceDescriptor`.
Magic Mouse is checked before the touchpad usage it can report; built-in trackpads also report a
mouse usage. Answers are cached by registry ID, which macOS does not reuse while running, so the
cache needs no invalidation after sleep or reconnection. Events without HID data, such as those
posted by other apps, are never reversed and never join a gesture. A phased gesture keeps the
device that began it through its momentum, so inertia cannot flip direction if one of its HID
events has an unresolved sender.

Reversal negates the line, fixed-point and point deltas and the HID event's scroll values, which
WebKit reads. The line delta is written first because Core Graphics recomputes the other two from
it. Accelerated and raw delta fields are left untouched, as in other scroll utilities.

Accessibility grants and revocations are observed through the `com.apple.accessibility.api`
notification, rechecked a second later, and on activation and wake. While access is missing, a
two-second timer retries. Revocation removes the tap. The settings section uses the opaque tool
envelope; an unreadable section intercepts nothing and blocks edits.

For manual verification, use a wheel mouse, a Magic Mouse and a trackpad. With the defaults, record
mouse wheel and trackpad scrolling alternating in one window, then enable Horizontal and include
horizontal scrolling and a trackpad flick whose inertia keeps its direction. Repeat with the inverse
combination and each direction alone. Confirm that pinch, rotation, three- and four-finger swipes,
Mission Control and Notification Center behave as before, and that Safari's two-finger page swipe
changes only when horizontal reversal applies to that device. Sleep and wake, disconnect and reconnect a mouse, then scroll
again. Revoke Accessibility while scrolling: scrolling must keep working in the macOS direction, and
Settings must show recovery. Disable the tool and quit Lineup during inertia; the next scroll must
follow macOS.

## Keep Awake power requests

`AwakeSession` in AppCore owns request lifetime. `AwakePowerController` implements its power
interface with IOKit `PreventUserIdleSystemSleep` and the optional `PreventUserIdleDisplaySleep`.
Both use a system timeout with release-on-timeout. No user-activity assertion or permanent power
setting is used. The app uses `ContinuousClock` for elapsed time and a common-run-loop timer so
countdown and expiration also run while a menu is open. Explicit system sleep cancels the session;
wake only checks expiration and never acquires requests. Registry disable and termination use the
same cancellation path.

Preferences use the existing opaque `tools.awake` section without changing the envelope schema.
Unknown settings keys survive edits; malformed settings block editing. Active sessions are never
persisted.

For manual verification, compare `pmset -g assertions` before start, with the display option off,
with it on, and after stop, disable, and quit. Filter by the tested Lineup PID and the assertion name
`Lineup Keep Awake`; other apps may also prevent sleep. Capture the Settings and menu countdown,
and record a start/countdown/stop interaction. Physical idle sleep and display sleep still need an
unattended check under the machine's existing power settings.

# Lineup

Lineup is a native macOS 13+ menu-bar suite. It combines three tools that users can enable
independently:

- **Zones** arranges windows in per-screen layouts.
- **Cycler** moves through apps and windows with global shortcuts.
- **Hyperkey** maps one physical key to Control + Option + Shift + Command.

Read [PRODUCT.md](PRODUCT.md) before changing user-visible behavior or design. Read
[BUILDING.md](BUILDING.md) for build, package, and architecture details. Read
[RELEASING.md](RELEASING.md) only when inspecting the dormant 1.x CI release flow.
Read [CONTRIBUTING.md](CONTRIBUTING.md) before preparing or reviewing a pull request; it owns the
required evidence, review gates, and merge policy.

## Protect user state and identity

These contracts are more important than local convenience:

1. `~/.config/lineup/config.json` is live user data. A failed load must block writes. An explicit
   reset must preserve the rejected bytes before replacement, and normal writes must stay atomic.
   Use temporary paths in tests.
2. `~/.config/lineup/zones.json` and `~/.config/cycler/bindings.json` are read-only import sources.
   Lineup never changes, moves, or deletes them.
3. The bundle ID, hotkey signature, update feed, and signing identity are compatibility anchors.
   Keep `Sources/AppCore/Product.swift`, `Resources/Info.plist`, and the scripts consistent. The
   identity tests must pass.
4. `web/appcast.xml`, `web/downloads/`, tags, notarization, signing keys, and deployments are
   release state. Change or publish them only when the maintainer requests release work.

Do not launch Lineup as routine automated verification. A launch uses the developer's real config,
Accessibility grant, hotkeys, and input monitoring. Launch it only when manual app verification is
part of the task. `Scripts/setup-signing.sh` changes the login keychain and also needs explicit
intent.

Use `trash` instead of `rm -rf` for disposable bundles and directories. Keep every destructive
target explicit and verified.

## Hit every affected path

Before a change is complete, check each relevant path:

- **Lifecycle:** enabled, disabled, startup, shutdown, and live settings changes.
- **Entry points:** menu bar, Settings, overlays or HUDs, global shortcuts, and drag actions.
- **System state:** Accessibility denied or revoked, hotkey conflicts, missing apps or windows, and
  recovery after an error.
- **Displays:** one display, multiple displays, display changes, and different coordinate spaces.
- **Persistence:** fresh config, current config, legacy import, malformed data, and data from a newer
  schema.
- **Documentation:** update the user, contributor, architecture, or release document that owns the
  changed behavior.

State which paths do not apply when their omission is not obvious.

## Where code lives

- `Sources/ZonesCore`, `Sources/CyclerCore`, and `Sources/HyperkeyCore` contain testable tool logic.
- `Sources/AppCore` owns product identity, shared configuration, migration, and tool metadata.
- `Sources/lineup/App` contains the app shell and shared macOS services.
- `Sources/lineup/Settings` contains the SwiftUI settings interface.
- `Sources/lineup/Tools` contains each tool's AppKit and SwiftUI integration.
- `Sources/lineup-tests` is the dependency-free test runner.
- `Scripts` contains local build and maintainer release tools.
- `web` contains the static site, update feed, release notes, and hosted downloads.

Keep UI frameworks and operating-system side effects in `Sources/lineup`. Put deterministic logic in
a core module when it can be tested without launching the app. Preserve one owner for shared config,
hotkey registration, permissions, and tool lifecycle.

## Development and verification

The supported local loop is:

```sh
swift build
swift run lineup-tests
```

For every code change:

- Run `swift run lineup-tests`; add focused checks for new core behavior and regressions.
- Run `swift build` so the app target and all modules compile.
- For package or bundle changes, also run a host-architecture app build with
  `UNIVERSAL=0 ./Scripts/build-app.sh <output-directory>`.
- For visual changes, inspect the affected app state and collect the evidence required by
  `CONTRIBUTING.md`.

The test runner is intentionally independent of XCTest and full Xcode. Keep it usable with Xcode
Command Line Tools alone.

## Change discipline

- Prefer the smallest model that makes the behavior clear. Reuse native AppKit and SwiftUI patterns.
- Add a dependency only when the standard frameworks or current modules cannot meet the need.
- Comments explain invariants, macOS constraints, and non-obvious use. Keep routine behavior in code.
- Keep a pull request to one concern. Use a conventional, plain title such as
  `fix(zones): preserve layouts after a display change`.
- Keep temporary plans, logs, and agent scratch files out of the repository.
- Create commits, tags, releases, deployments, or pull requests only when the user asks.
- Treat a passing check as verification, not merge approval. Only `@hcaiano` approves and merges.

If a task conflicts with a contract in this file, explain the conflict and get maintainer approval
before proceeding.

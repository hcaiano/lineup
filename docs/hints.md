# Hints

Hints is Lineup's fourth tool. It is disabled by default. After you enable it in Settings and
assign it a global activation shortcut, pressing that shortcut shows short keyboard labels over the
actionable controls that the frontmost app exposes through the macOS Accessibility tree. Type to
filter labels or search accessible names, then confirm to activate the chosen control through its
advertised Accessibility action. Keyboard activation is best effort: when a target cannot be
activated safely, Hints cancels instead of guessing.

## Support contract

Hints works with controls that the frontmost app advertises through the macOS Accessibility tree.

- **Supported:** native controls in apps that expose standard Accessibility roles and actions
  (buttons, links, checkboxes, radio buttons, tabs, menu items and popups that advertise a
  supported action inside the app's windows, nonsecure editable fields that can take focus, and
  AX-exposed scroll regions in scroll mode).
- **Best effort:** Safari, Chromium, and Electron apps. Coverage is limited to the controls those
  apps expose through Accessibility and can change between versions. Standard popovers and their
  items are labeled only when they expose a supported Accessibility role and advertised action.
- **Excluded:** WebGL/canvas-only UI, owner-drawn surfaces without Accessibility data, the Touch
  Bar, menu bar extras (status items), and surfaces, submenus, and overlays that do not expose a
  safe, supported Accessibility target with an advertised action. Also excluded: pointer fallback,
  OCR or screen scraping, event taps or synthetic clicks, cross-app or global search, a multi-action
  chooser, settings personalization beyond the activation shortcut and label alphabet, and implicit
  sole-result activation (typing a full label selects a candidate; confirming it requires Return).

## Permissions

Hints uses Accessibility and nothing else. It does not use or require Input Monitoring; Hyperkey
remains the only Lineup tool that uses Input Monitoring. Hints never starts an AX scan, shows a
panel, or registers input handling while it is disabled, and no Lineup tool triggers a permission
prompt at attach or startup.

## Privacy

- Secure field values are never read.
- Control names, text values, typed queries, and raw target tokens are never logged or persisted.
- Hints config stores only the activation shortcut and the label alphabet.
- Hints is disabled by default in every build and never starts automatically after an update.

## Architecture

- `Sources/HintsCore` owns deterministic policy: eligibility, labels, filtering, search, session
  state, geometry, and scan budgets. It imports Foundation only and is covered by the portable
  checks in `swift run lineup-tests`.
- `Sources/lineup/Tools/Hints` owns the AppKit integration: the AX service, per-display overlay
  panels, modal input, session orchestration, Settings pane, and tool lifecycle.
- Adapter XTests under `Tests/HintsAdapterTests` cover macOS-only integration seams and are not run
  by the portable test runner.

There are no supported source-adaptation records yet; see the clean-room attestation below.

## Clean-room provenance

Attestation (recorded 2026-09-04): the current Hints source (Sources/HintsCore and
Sources/lineup/Tools/Hints) contains no code adapted from Hinto, Keyouse, or any other third-party
implementation, and therefore no third-party notice is bundled for it. If any upstream code is ever
adapted, record here, before merge: the pinned upstream commit, the exact files and functions used,
the copyright holder, the modifications made, and the retained license text, so the required
attribution can ship with the app.

## Status

Hints has not yet completed signed macOS validation. Native-app behavior on macOS 13 and the
current macOS is recorded as pending in `docs/plans/hints-macos-handoff.md`; do not rely on runtime
behavior claims beyond the support contract above.

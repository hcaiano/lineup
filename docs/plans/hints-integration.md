# Hints Integration Plan

Status: Phases 0 through 4 and Oracle Gates 1 through 5 passed; Phase 5 signed macOS validation has not run.
Date: 2026-09-04
Target: macOS 13+
Validation owner: parent orchestrator

## Objective

Add **Hints** as Lineup's fourth first-party tool. Hints lets the user invoke a global shortcut,
discover actionable controls exposed by the frontmost application's macOS Accessibility tree,
show short keyboard labels over those controls, filter or search them, and activate the chosen
control without reaching for the mouse.

The target is **HomeRow-like behavior on AX-exposed surfaces**, not integration with HomeRow's
proprietary implementation and not a promise that every custom-rendered interface is reachable.

## Confirmed product decisions

- Hints is a normal Lineup `Tool`, registered after Hyperkey.
- It is disabled by default for fresh and existing users.
- It uses the existing `Tool`/`ToolRegistry` lifecycle; the frozen `Tool` protocol is not widened.
- The implementation is Lineup-native and clean-room. Small MIT-licensed ideas or functions from
  Hinto or Keyouse may be adapted only after their exact sources are pinned, reviewed, approved, and
  recorded with attribution and provenance; the default is redevelopment without adaptation.
- HomeRow code and assets are not available for reuse. Vimac GPL-3 and Keyway AGPL code are
  reference-only and must not be copied.
- Hints is not added to the initial Welcome flow. Discovery happens through Settings, the menu,
  and release notes after the feature exists.
- Bundle ID, signing identity, hotkey signature, Sparkle feed, appcast, and release state remain
  unchanged.

## Council decision

The architecture council agreed on a dependency-free `HintsCore`, a tool-local serial AX service,
generation-based session orchestration, and nonactivating per-display overlays. The chosen input
strategy is **panel-only** for Linux-authored production: a nonactivating key-capable panel owns
modal input while the target app stays frontmost, and Carbon is used only for the assigned global
activation trigger. Modal Carbon registrations, a `CGEventTap`, Input Monitoring permission or
requests, and any fallback input path are out of scope until a future Phase 5 decision approves
them. Phase 5 signed panel validation must confirm this decision or force a recorded replacement.
No silent permission escalation and no Hyperkey event-broker refactor are allowed in this scope.

## Maintainer-directed sequencing

The maintainer has directed that production code may be authored on the current Linux session
before any signed macOS empirical validation happens. This is **deferred validation**, not a
passed gate. The rules that follow are binding for the entire implementation:

- Hints remains **default-off** in every build, including Linux-authored builds that cannot be
  exercised at runtime.
- Every unverified platform assumption (panel capture, Carbon behavior, AX traversal and
  invocation outcome, per-display overlays) must **fail closed** or be isolated behind the existing
  AX/Input/Presentation owning boundaries so the macOS stabilization phase can repair behavior
  without touching `HintsCore` contracts.
- **No one may claim feature completion or release readiness** until the full signed macOS
  acceptance matrix passes in Phase 5.

To keep this workable, Phase 0 shifts from executing macOS probes to **documenting assumptions,
safe-default decisions, and a macOS handoff** (`docs/plans/hints-macos-handoff.md`). The signed
empirical execution that originally lived in Phase 0 moves into Phase 5 as the **final
stabilization and evidence phase**. Where later phases previously read "Phase 0 proves X", read
"the Phase 0 recorded decision is safe-defaulted, and Phase 5 signed validation confirms it before
release". Production lanes build against the frozen safe defaults and must not widen behavior
beyond what a failed validation could confine or remove.

## Grounded repository context

- `Sources/lineup/App/Tool.swift` and `ToolRegistry.swift` already provide attach/start/stop,
  scoped hotkeys, permissions, settings panes, warnings, and teardown.
- `Sources/lineup/Tools/Zones/WindowMover.swift` contains AX messaging timeouts, coordinate
  conversion, hit-testing, and Electron `AXEnhancedUserInterface` handling.
- `Sources/lineup/Tools/Cycler/AppActivator.swift` contains AX window enumeration, filtering,
  activation, and action patterns.
- `Sources/lineup/Tools/Zones/LayoutEditorOverlay.swift` provides the existing one-window-per-
  display pattern and documents secondary-display placement hazards.
- `Sources/lineup/Tools/Cycler/CycleHUD.swift` provides the nonactivating, mouse-ignoring HUD
  pattern.
- `Sources/lineup/Tools/Hyperkey/HyperKeyController.swift` provides Secure Input handling,
  event-tap teardown, timeout behavior, and Lineup's synthetic-event marker convention.
- `Sources/AppCore/LineupAppConfig.swift` already preserves opaque and unknown tool sections, so
  `tools.hints` needs no envelope-schema migration.
- `Sources/lineup-tests/AppSuite.swift` and the tool suites contain fixed three-tool registrations,
  path lists, permission-site allowlists, and single-owner source scans that must be updated
  deliberately without weakening their original guarantees.

## Release behavior contract

### Included

1. A user-configurable global shortcut starts or cancels Hints.
2. Hints captures the frontmost PID and window context before showing any Lineup UI.
3. It scans the frontmost application's visible, non-minimized AX windows plus relevant sheets,
   popovers, menus, and controls across connected displays.
4. It recursively discovers enabled, visible, on-screen actionable controls within strict depth,
   count, timeout, and wall-clock budgets.
5. It displays deterministic, fixed-length, prefix-safe home-row labels. Labels remain stable
   within one scan generation.
6. Typing filters labels; accessible-name search uses AX title, label, and description metadata;
   Backspace edits; Escape and a repeated activation shortcut cancel.
7. Supported actions follow the frozen candidate/action matrix below: advertised `AXPress` for
   buttons, links, checkboxes, radio buttons, tabs, and menu items; advertised `AXShowMenu` for
   popups and menu triggers; focus for nonsecure editable controls only when the value is
   focusable; and scroll-region operations in scroll mode. No pointer synthesis of any
   kind ships in this release.
8. Primary activation goes through the advertised AX action only. Double-click, right-click, and
   modifier-click are not in this release and remain deferred until separately reopened after
   signed proof that they can be generated safely and predictably without arbitrary
   stale-coordinate clicking. The pointer/click allowlist is **empty**; no dormant unsafe
   abstraction is built ahead of that proof.
9. Scroll mode discovers AX-exposed scroll regions, supports nested-region selection, directional
   movement, Page Up/Down, Home/End, and key repeat, then rescans after visibility changes.
10. Menus, popovers, scrolling, display changes, and meaningful target-context changes trigger a
    bounded rescan or safe cancellation.
11. Hints supplies a Settings pane, shortcut conflict reporting, permission and configuration
    warnings, menu actions, lifecycle teardown, documentation, and automated core coverage.

### Explicitly deferred

- Browser extensions, DOM injection, and browser-specific native messaging.
- OCR, image matching, vision models, or a Screen Recording requirement.
- Guaranteed interaction with canvases, games, remote desktops, video surfaces, or other
  controls absent from the Accessibility tree.
- Scanning every running application or every Space.
- Dock and third-party status-item navigation.
- Drag-and-drop, arbitrary mouse grids, macros, scripting, and application launching.
- Broad continuous AX observers that keep scanning while Hints is idle.
- Guessing from cached coordinates after an AX element becomes stale.

Required wording in product documentation: Safari, Chromium, and Electron support is best effort
and limited to controls they expose through Accessibility.

## Architecture

```text
Carbon activation shortcut
          |
          v
HintSessionController (@MainActor)
          |
          +---- capture PID/windows/screens/session generation
          |
          +----> HintAXService (serial executor)
          |          |
          |          +-- bounded breadth-first AX traversal
          |          +-- session-owned AX target repository
          |          +-- pure candidates + opaque target tokens
          |          +-- revalidation and invocation
          |
          +----> HintsCore
          |          +-- eligibility/ranking policy
          |          +-- labels/filter/search/reducer
          |          +-- geometry and scan budgets
          |
          +----> HintOverlayController
          |          +-- one nonactivating window per display
          |          +-- custom-drawn labels/query state
          |
          +----> HintInputController
                     +-- panel-only modal input
                     +-- responder callbacks and committed panel text only
                     +-- no Carbon modal routing, event tap, or fallback path
```

### `Sources/HintsCore`

Foundation-only deterministic logic:

- `HintsSettings`: tool-local versioned settings and lenient validation.
- `HintCandidate` and `HintActionKind`: pure metadata, never `AXUIElement`.
- `HintEligibilityPolicy`: roles, subroles, actions, visibility, and ranking rules.
- `HintLabelMaker`: deterministic fixed-length labels for a configured alphabet.
- `HintFilter` and `HintSearch`: incremental label filtering and accessible-name matching.
- `HintSessionState`, events, effects, and reducer.
- `HintOverlayGeometry`: display assignment, clipping, clamping, and overlap inputs.
- `HintScanLimits` and truncation/result summaries.

`HintsCore` must not depend on AppKit, ApplicationServices, Carbon, ZonesCore, or AppCore.
`AppCore` must not depend on `HintsCore`.

### `Sources/lineup/Tools/Hints/AX`

`HintAXService` is the only Hints owner of `AXUIElement` values.

- Run recursive AX work on one serial executor or queue, never the main actor.
- Capture PID, visible target windows, screen geometry, mode, and generation before scanning.
- Traverse breadth-first with cycle, depth, node, candidate, per-call, and wall-clock limits.
- Start with typed individual attribute reads. `AXUIElementCopyMultipleAttributeValues` bulk
  optimization is deferred; it may be introduced later only after Phase 5 profiling shows measurable
  benefit, and even then a bulk read is never treated as a snapshot: every slot and type is
  independently validated. Apply the frozen 50 ms messaging timeout before querying each AX
  element.
- Keep raw elements in a session-scoped token repository and release all of them on cancellation,
  stop, timeout, target change, or invocation completion.
- Return pure candidate snapshots and opaque tokens to the main actor.
- Do not depend on Cycler's private `_AXUIElementGetWindow`; it is unnecessary for this feature.

Candidate policy must reject secure fields, disabled/hidden/zero-size/off-screen elements,
Lineup-owned windows, disconnected-display frames, and elements with no supported action. Dedupe
overlapping parent/child candidates by preferring the most specific actionable descendant.

Invocation order:

1. Revalidate PID, target window/context, token liveness, enabled state, action, and frame.
2. Hide overlays and relinquish modal input.
3. Dispatch the advertised AX action (`AXPress`, `AXShowMenu`, settable focus, or the scroll
   operation) **at most once**. A `kAXErrorCannotComplete` result has an unknown outcome: it is
   never retried, and only a fresh observational rescan under a new generation may follow.
4. Rescan under a new generation after menu/popover/reveal actions.
5. Cancel on stale or ambiguous state. Never click a remembered coordinate as a guess; this release
   performs no pointer synthesis at all.

### Session controller

```text
idle
  -> scanning(sessionID, context, mode)
  -> presenting(sessionID, snapshot, mode, query)
  -> invoking(sessionID, token)
  -> idle | scanning(next generation)
```

Every asynchronous result carries a session generation. Late results are discarded and their AX
repositories released. Every active state returns to `idle` on Escape, repeated shortcut, tool
disable, app termination, Accessibility revocation, Secure Input, target PID/window mismatch,
display topology change, capture loss, timeout, wake, or stale invocation.

### Input and permissions

Frozen safe default: **panel-only modal input, Accessibility only.**

- Accessibility is the only Hints permission. There is no permission prompt or request during
  attach or startup of any Lineup tool, including Hints. Input Monitoring is not used and is not
  requested anywhere in this release.
- Presentation owns the `NSPanel`, window, and key-window lifecycle. The input lane only
  translates responder callbacks and committed panel text into semantic events, waits for the
  activation modifiers to release before accepting input, and cancels before accepting input when
  Secure Input is active, capture fails, or capture is lost.
- Carbon is used only for the assigned global activation shortcut. No modal Carbon registration is
  created in this release.
- There is no event tap, no Input Monitoring permission, and no fallback input path in this
  release, and no dormant code implementing them. Introducing any of these requires a separate,
  maintainer-approved decision recorded in Phase 5; the panel behavior requirements below are the
  evidence that decision would be tested against.
- A nonactivating key-capable panel is required to work on macOS 13 and the current supported
  macOS, including fullscreen Spaces, multiple displays, Secure Input, physical modifiers, and
  activation through Lineup Hyperkey, with the target app frontmost and its exact context restored
  after the session. Until Phase 5 confirms this, everything above fails closed: on failed capture,
  capture loss, Secure Input, or display/panel uncertainty, Hints cancels and releases everything.
- If the panel route fails materially during Phase 5, stop and record the decision; repair stays
  inside the Presentation/Input owning boundaries and the maintainer decides whether a different
  capture strategy is proposed at all.

### Presentation and UX

**UI/UX work: route to `@designer`.** Later mechanical changes must preserve the selected overlay
layout, spacing, motion, hierarchy, contrast, and interaction behavior.

- One transparent, borderless, mouse-ignoring nonactivating panel per participating display.
- Custom-draw labels in one view per display rather than creating one view/window per candidate.
- Do not activate Lineup or retain `ActivationCoordinator` merely to show labels.
- Clamp labels to display bounds and handle negative display origins, Retina scaling, notches,
  straddling windows, fullscreen Spaces, and dense overlap deterministically.
- Use restrained system materials and the existing Lineup blue for active hint chrome; do not add
  a fourth neon accent merely to distinguish the tool.
- Support light/dark appearance, increased contrast, and Reduce Motion.
- Keep overlay windows out of Hints' own scan and out of VoiceOver's navigable hierarchy.
- Define visual states for scanning, active labels, filtering, no matches, truncated results,
  permission blocked, invocation failure, and cancellation.

### Configuration

- Add stable `ToolID.hints` with raw value `"hints"`, appended after Hyperkey.
- Store settings in the existing opaque `tools.hints` section; do not change the envelope schema.
- Set `defaultEnabled = false` and ensure an update never starts Hints automatically.
- Use an unassigned default activation shortcut so a disabled new tool does not reserve a
  global combination for every existing user. Settings and the menu provide the setup path.
- `persistedCombos()` must participate in cross-tool conflicts once the user records a shortcut.
- If Hints settings cannot be decoded, run no Hints side effects, preserve the rejected section,
  block Hints-specific writes, and leave sibling tools operational.
- Preserve unknown settings so downgrades and future schema additions do not lose data.
- Any Hints config reset path is either omitted from this release's scope, or it preserves the
  rejected Hints section bytes before replacement and aborts the reset if preservation fails. Normal
  writes stay atomic and a failed load blocks writes.

## Performance and privacy gates

Initial limits are frozen safe defaults to be confirmed in Phase 5 Finder/matrix profiling, not
permission to loosen safety after a slow scan:

| Measure | Initial gate |
|---|---:|
| Activation callback work | under 2 ms |
| Scanning indicator visible | under 50 ms |
| Native labels available | p50 under 150 ms; p95 under 400 ms |
| Large AX surface response | p95 under 750 ms |
| Hard scan completion/partial failure | under 1 second |
| Per AX call timeout | 50 ms |
| Maximum traversal depth | 40 |
| Maximum visited nodes | 4,000 |
| Maximum candidates | 1,500 |
| Scan wall-clock deadline | 750 ms |
| Filter/search redraw | p95 under 16 ms |
| Overlay redraw | under 33 ms |
| Invocation dispatch | under 50 ms |
| Idle cost | no polling, tap, overlays, or retained AX elements |

When a budget is reached, show the highest-ranked partial result and count-only truncation status.
Never log control names, text-field values, search queries, or raw UI content. Do not read secure
field values. Diagnostics may contain bundle ID, role counts, node counts, timings, errors, and
truncation reasons.

## Implementation phases

### Phase 0 - Assumptions, safe defaults, and macOS handoff (docs only)

**Purpose:** record every platform assumption that would otherwise force a late architectural
rewrite, choose safe defaults for each, and prepare the signed macOS handoff. Phase 0 does not
execute macOS probes on this session; under the maintainer-directed sequencing, signed empirical
execution of these assumptions moves to Phase 5.

**Write scope:** this plan and `docs/plans/hints-macos-handoff.md` only. No production source writes.

**Tasks:**

- Record each risky platform assumption in the assumption register table below with its provisional
  safe default, fail-closed behavior, owning boundary, and required Phase 5 evidence.
- Define the fail-closed behavior for every assumption so a Phase 5 failure cannot silently ship
  unsafe behavior.
- Record the clean-room posture: pin exact upstream commits before any review of adaptable MIT
  code; no upstream adaptation is included unless its sources are separately pinned, reviewed, and
  approved, and the default is full clean-room implementation.
- Freeze the release keyboard map, candidate/action matrix, and application tiers as recorded in
  this plan, subject to Phase 5 confirmation.
- Create `docs/plans/hints-macos-handoff.md` covering entry criteria, transfer, environments,
  evidence checklists, result fields, stop conditions, remediation routing, the Oracle final gate,
  and a resumption prompt template.

**Gate:** every assumption in the register has a recorded safe default and fail-closed path, the
keyboard map, candidate/action matrix, and application tiers are written down, and the handoff
document is complete. This is a documentation gate; it does not claim the platform behaviors have
been observed. Phase 1 may begin under the safe defaults, but release readiness may not be claimed
until Phase 5.

### Phase 1 - Pure Hints core and deterministic tests

**Owners and non-overlapping write scopes:**

- Core lane: `Sources/HintsCore/**` and `Sources/lineup-tests/HintsSuite.swift`.
- Shared-integration owner: minimal `Package.swift` target/dependency wiring and the Hints suite
  invocation in `Sources/lineup-tests/main.swift`. Reuse this same owner/session for Phase 4.

**Tasks:**

- Implement settings, candidate/action models, eligibility and ranking policy.
- Implement fixed-length label allocation, filtering, accessible-name search, and overflow.
- Implement the session reducer, normalized modal-input events, key/filter commands, geometry,
  scan budgets, truncation, and count-only diagnostics.
- Add exhaustive tests for uniqueness, stability, prefix safety, filtering, search determinism,
  cancellation, stale generations, role policy, geometry, limits, and settings validation.

**Gate:** `swift build --target HintsCore` and `swift run lineup-tests` pass where the Linux toolchain
supports them; any host or toolchain rejection is recorded as **blocked**, never counted as passed.
`HintsCore` imports Foundation only. The AppKit app target, full `swift build`, the host app
bundle, and signing remain explicitly uncompiled and unverified until the macOS environment.

### Phase 2 - AX, presentation, and input lanes

Three non-overlapping write scopes that may run in parallel after Phase 1, provided the Phase 0
safe defaults and owning boundaries are in place. If a lane discovers a shared `HintsCore`
contract must change, it requests that change from the Phase 1 core owner rather than editing the
shared scope concurrently. Signed manual validation for every lane is deferred to Phase 5; each
lane gate below covers only the automated checks the Linux host supports, and AppKit-target
compilation stays unverified and recorded as blocked until macOS.

#### 2A. AX scanner and invocation lane

**Write scope:** `Sources/lineup/Tools/Hints/AX/**` only.

**Tasks:** implement the serial AX service, bounded traversal, opaque target repository, candidate
conversion, context revalidation, advertised AX actions only, scroll backend, and deterministic
teardown. The pointer/click allowlist is empty; nothing in this lane synthesizes pointer input.
Use local patterns from `WindowMover` and `AppActivator`; do not edit or extract those files in
this phase.

**Gate:** the lane's sources pass the automated checks the Linux host supports, the recorded
budgets are retained, no AX element crosses the service boundary, and cancellation paths release
every target repository deterministically (tested through injected stubs). Every advertised action
dispatches at most once and `kAXErrorCannotComplete` is never retried. Deterministic policy remains
tested in `HintsCore`; this lane must not make the dependency-free runner import the AppKit target.
AppKit-target compilation and runtime behavior stay unverified until Phase 5.

#### 2B. Overlay and presentation lane

**Owner:** `@designer` for implementation; visual evidence is deferred to Phase 5.
**Write scope:** `Sources/lineup/Tools/Hints/Presentation/**` only.

**Tasks:** implement per-display panels, custom label canvas, query/search state, overlap handling,
truncation and error states, appearance/accessibility behavior, and deterministic animation.
Presentation owns the `NSPanel`, window, and key-window lifecycle end to end.

**Gate:** the lane's sources pass the automated checks the Linux host supports and render/geometry
inputs are testable against `HintsCore` geometry. Behavior gates for one display, two displays,
dense labels, light/dark, increased contrast, Reduce Motion, frontmost preservation, and pointer
pass-through are recorded as expectations here and verified in Phase 5. AppKit-target compilation
and runtime behavior stay unverified until Phase 5.

#### 2C. Modal input lane

**Write scope:** `Sources/lineup/Tools/Hints/Input/**` only.

**Tasks:** implement the panel-only capture strategy named by the Phase 0 recorded decision as a
thin layer over the normalized input events and reducer commands already owned by `HintsCore`.
Input only translates responder callbacks and committed panel text into semantic events, waits for
the activation modifiers to release before accepting input, and cancels before accepting input on
Secure Input, failed capture, or capture loss. No Carbon modal registration, event tap, or Input
Monitoring code exists in this lane.

**Gate:** the lane's sources pass the automated checks the Linux host supports; input implements
the full fail-closed surface (Secure Input, capture loss, tool stop, panel-creation uncertainty)
and is injectable for Phase 5 capture-matrix testing. Signed capture-matrix validation and Hyperkey
coexistence checks run in Phase 5 only; until then they are recorded as blocked.

### Phase 3 - Tool lifecycle and session orchestration with Settings

**Owners:** integration implementation lane; Settings pane work by `@designer` with copy reviewed
by the parent orchestrator.
**Write scopes:** lifecycle owner owns `Sources/lineup/Tools/Hints/HintSessionController.swift`,
`Sources/lineup/Tools/Hints/HintsTool.swift`, and Hints-local support files outside `AX`, `Input`,
and `Presentation`. The Settings owner owns `Sources/lineup/Tools/Hints/HintsSettingsPane.swift`
and Hints-specific Settings components/help strings only.

**Tasks (lifecycle):** connect scan/input/presentation effects; implement generation-aware
transitions, activation and cancel actions, rescan behavior, menu items, warnings,
`persistedCombos()`, hotkey restore failures, termination cleanup, disable-during-session
behavior, wake/display/app-change cancellation, and malformed-settings blocking.

**Tasks (Settings):** shortcut setup, mode/label/search/scroll preferences, permission and
malformed-config banners, conflict messaging, supported-surface explanation, and accessible
keyboard help. Use existing shared recorder and settings-store behavior rather than creating
alternate owners.

**Gate:** lifecycle transitions testable through injected services on the Linux host; `stop()` leaves no AX
repositories, windows, hotkeys, capture, timers, observers, or pending async effect; the pane
renders while disabled, blocked writes spring back without data loss, conflicts name Hints
correctly, and copy never promises universal application coverage. AppKit-target compilation and
runtime behavior stay unverified until Phase 5.

### Phase 4 - Shared integration, documentation, and provenance

**Owners:** one integration lane for shared wiring (no concurrent edits to that scope); a
documentation lane for docs and notices.
**Write scopes:** the integration lane owns `Sources/AppCore/ToolID.swift`, `Package.swift` final
wiring, `Sources/lineup/App/AppShell.swift`, `Sources/lineup/App/Brand.swift`,
`Sources/lineup/App/StatusItemController.swift`,
`Sources/lineup/Settings/Components/ToolIcon.swift`, relevant onboarding/discovery copy,
`Sources/lineup-tests/AppSuite.swift`, sibling suite source scans, and
`Sources/lineup-tests/main.swift`. The documentation lane owns `PRODUCT.md`, `README.md`,
`BUILDING.md`, `AGENTS.md`, Hints-owned documentation, third-party notice files, and
`Scripts/build-app.sh` only if MIT code is actually adapted.

**Tasks (integration):** append the stable ID, register Hints fourth, preserve default-off seeding,
add metadata and menu/settings discovery, revise inaccurate fixed “three tools” copy without
adding Hints to Welcome, and update every fixed registration/path/permission/single-owner
assertion. Preserve legacy-import tests that correctly expect only the three legacy-derived tool
sections.

**Tasks (docs):** document Hints' behavior, default-off posture, support matrix, permission use,
privacy, architecture, test commands, and explicit exclusions. Record exact upstream
commit/file/function, copyright, modifications, and retained license for every adapted MIT
component.

**Do not touch:** `web/appcast.xml`, `web/downloads/`, tags, release versions, notarization state,
or signing identities unless the maintainer separately requests release work.

**Gate:** no frozen `Tool` change; no duplicate permission/updater/activation/config owner; old and
unknown config sections survive; all source-scan invariants remain at least as strict as before;
docs and shipped notices match the recorded permission path and support contract with no claim of
observed macOS behavior beyond what Phase 5 has confirmed. Checks the Linux toolchain cannot run
are recorded as blocked until Phase 5.

### Phase 5 - macOS stabilization, signed evidence, and final validation

**Purpose:** execute the deferred signed empirical validation from Phase 0 and the full manual
matrix on real macOS hardware, confirm or repair every recorded assumption, and produce release
readiness evidence.

**Owner:** each defect returns to the owner of its write scope; command-only validation goes to the
validation lane.
**Write scope:** focused fixes in the owning phase's files, `docs/plans/hints-macos-handoff.md`,
and approved evidence locations only.

**Tasks:** open the new macOS chat from the handoff document. `swift run lineup-tests`, `swift
build`, and the host-architecture app build to an explicit temporary output are **mandatory** on
macOS before any manual test. Then execute the full signed matrices recorded in the handoff
document (panel capture, AX traversal and candidate coverage, per-display overlays, Hyperkey
coexistence, Secure Input, display changes), confirm or replace each Phase 0 safe default, profile
count-only timings, fix regressions without loosening safety limits, and collect the visual/manual
evidence required by `CONTRIBUTING.md`.

Rules for the matrix:

- Every required scenario must run on both macOS 13 and the currently supported macOS. An
  environment that cannot host a scenario marks that cell **blocked**, never silently skipped.
- Final TCC permission evidence requires the app built with the cert-based stable signature at a
  fixed app path. Ad-hoc or ephemeral signing runs are exploratory only and never satisfy the gate.
  If stable signing is not explicitly authorized on the macOS machine, the final gate is blocked.
- Permission state, config preservation, teardown completeness, input leakage, and wrong-target
  invocation are **non-waivable**; a failure in any of them fails the gate outright.
- Scope narrowing is accepted only after the failing behavior is removed or disabled, the docs are
  updated to match, and the reduced matrix is rerun, with maintainer approval.

**Gate:** every automated and manual acceptance criterion passes (or is explicitly narrowed per the
rule above) on both OS environments, and each Phase 0 assumption is confirmed or its remediation is
complete. Feature completion and release readiness are claimable only after this gate. A passing
check is verification, not merge approval; only the maintainer approves and merges.

## Execution order

```text
Phase 0 assumptions / safe defaults / handoff (docs)
        |
Phase 1 HintsCore/API freeze
        |
        +--- Phase 2A AX ---------+
        +--- Phase 2B UI ---------+--> Phase 3 orchestration + Settings
        +--- Phase 2C input ------+            |
                                               v
                                      Phase 4 shared integration + docs/provenance
                                               |
                                      Phase 5 macOS stabilization and signed evidence
```

- Phase 0 is sequential because the recorded assumptions, safe defaults, and owning boundaries
  constrain the production architecture, but it validates nothing on hardware.
- Phase 1 is sequential because all writer lanes depend on its pure contracts.
- Within Phase 1, the core lane and shared-integration owner have disjoint scopes; the latter must
  remain the owner of `Package.swift` and `lineup-tests/main.swift` when Phase 4 resumes.
- Phases 2A/2B/2C are safe in parallel because their write scopes do not overlap.
- Phase 3 waits for all three lanes so it integrates frozen implementations rather than changing
  their contracts concurrently.
- Phase 4's integration scope is intentionally serialized under one writer because fixed tool
  lists, registration, branding, and source scans are tightly coupled. Documentation waits for the
  recorded permission and support decisions so it cannot drift.
- Phase 5 is the only phase that runs on signed macOS hardware and it is the sole source of release
  readiness claims. Production phases 0 to 4 may proceed on the current Linux session, but a failed
  Phase 5 validation routes fixes back to the owning lane.

## Oracle gates

There are six mandatory Oracle gates, one per phase:

1. **Phase 0:** assumptions documented with safe defaults, fail-closed paths, provisional
   matrices, and a complete handoff document.
2. **Phase 1:** the supported `HintsCore` automated checks pass with Foundation-only imports and
   the pure contracts frozen; unsupported host checks recorded as blocked.
3. **Phase 2:** all three lanes pass the automated checks the Linux host supports, with recorded
    budgets retained, owning boundaries intact, and unsupported checks recorded as blocked.
4. **Phase 3:** lifecycle transitions testable through injected services and teardown complete.
5. **Phase 4:** shared integration and documentation invariants hold.
6. **Phase 5:** the signed macOS matrix, profiling, and visual/manual evidence all pass; only this
   gate may support a release-readiness claim.

## Verification plan

### Automated

Run what the Linux toolchain supports after every production phase:

```sh
swift build --target HintsCore
swift run lineup-tests
```

A host or toolchain rejection of either command is recorded as **blocked**, never as passed. The
AppKit app target, a full `swift build`, the host app bundle, and signing remain explicitly
uncompiled and unverified on Linux.

On macOS, before any manual test runs, all of the following are mandatory:

```sh
swift run lineup-tests
swift build
UNIVERSAL=0 ./Scripts/build-app.sh <temporary-output-directory>
```

Do not launch Lineup as routine automated verification.

Required automated coverage:

- Label uniqueness, fixed length, stability, configured alphabets, and overflow.
- Filter/search ordering, Backspace, exact/full-label activation, and no sole-result
  auto-invocation.
- Reducer transitions, cancellation from every active state, and stale-generation rejection.
- Candidate policy, secure/disabled/off-screen exclusion, parent-child dedupe, and scan truncation.
- Multi-display geometry with positive and negative origins and straddling frames.
- Fresh/current/malformed/newer Hints settings; default-off startup; unknown-key preservation.
- Shortcut reservation/conflicts while enabled and disabled after a user records a combo.
- Four-tool registration/attach/start/stop order and all existing unique-owner source scans.
- Legacy imports remain read-only and continue creating only Zones/Cycler/Hyperkey sections.

### Signed manual-app matrix (Phase 5)

Launching the app is permitted only for the Phase 5 explicit manual verification pass. It is
deferred validation on real macOS hardware, not covered by the Linux-authored phases. Every
required scenario below must run on both macOS 13 and the currently supported macOS; an
environment that cannot host a scenario makes that cell blocked, never silently skipped. Final TCC
evidence requires the cert-based stable signature at a fixed app path; ad-hoc or ephemeral runs are
exploratory only. Manual persistence scenarios run in a dedicated disposable macOS account, never
against the maintainer's live `~/.config/lineup/config.json`.

| Area | Required scenarios |
|---|---|
| Lifecycle | disabled startup, first enable, live disable during scan/presentation/invocation, repeated shortcut, quit, wake |
| Permissions | Accessibility denied, newly granted, revoked mid-session, with cert-signed app at a fixed path |
| Input | Escape, Backspace, repeat, modifiers released late, non-US/IME where available, Secure Input, failed capture, capture loss |
| Cross-tool | Hyperkey on/off and used as trigger, Zones drag/editor activity, Cycler HUD, Settings shortcut recorder open |
| Target safety | stale element, hung app, secure field, disabled/off-screen element, at-most-once dispatch with no retry after unknown outcome, app/window changes during invocation |
| Displays | one/multiple, negative origin, Retina scaling, rearrange, attach/remove, fullscreen, straddling window, panel-creation uncertainty cancellation |
| AX surfaces | Finder, System Settings, TextEdit, a deterministic signed SwiftUI fixture, Safari, Chrome, one pinned Electron app, sheets, menus, popovers |
| Behavior | labels, filter, `/` accessible-name search, advertised actions only, menu rescan, nested scroll regions, no-match and truncation states |
| Persistence | fresh/current/malformed/newer config in a disposable account, downgrade preservation, conflict restoration, failed-load write block, rejected-section preservation, zones.json/bindings.json checksums unchanged |
| Visual | light/dark, contrast, Reduce Motion, dense overlap, clamping, click-through, no app activation |

Non-waivable cells: permission state, config preservation, teardown completeness, input leakage,
and wrong-target invocation. A failure in any of them fails the gate outright; narrowing can never
waive them.

Collect before/after screenshots and a short keyboard-flow recording showing activation, filtering,
invocation, scrolling, cancellation, and a failure/partial-result state.

## Success criteria

- Hints remains entirely inert when disabled and adds no idle polling, event tap, overlays, or AX
  references.
- AX-exposed controls in the required native-app matrix are found and invoked within the stated
  budgets.
- Unsupported, truncated, hung, stale, secure, or revoked states fail closed without freezing the
  menu bar or invoking the wrong control.
- Input capture does not leak typed labels into the target app, latch modifiers, or interfere with
  Hyperkey, Zones, Cycler, or shortcut recording.
- The release uses Accessibility only as its TCC permission, shows no permission prompt at attach
  or startup, and makes no universal browser/custom-UI claim.
- Config and identity contracts remain intact; no legacy source is modified.
- Implementation is clean-room; unadapted code needs no provenance record, and any upstream
  adaptation requires separately pinned, reviewed, and approved sources with complete provenance
  and bundled attribution.
- `swift run lineup-tests`, `swift build`, the host-architecture app build, and the manual evidence
  matrix pass.

## Risks and stop conditions

1. **Modal input:** if the panel cannot capture reliably, stop and record the decision; do not
   invent a third global-input owner or introduce an event tap without a separate maintainer-approved
   decision.
2. **AX latency:** if native apps cannot produce useful partial results under the hard deadline,
   revisit candidate scope rather than raising timeouts until Lineup stalls.
3. **Invocation safety:** pointer/click variants are excluded from this release by frozen decision.
   Reopening them requires signed proof of target freshness and balanced input plus explicit
   maintainer approval; guessing is never acceptable.
4. **Browser expectations:** if AX coverage is insufficient, document the limitation; DOM/vision
   support requires a separate proposal.
5. **Licensing:** if provenance cannot be established for an adapted component, rewrite it or omit
   it.
6. **Visual density:** if 1,500 labels cannot remain usable, rank/cull or progressively reveal;
   do not create one window per hint.

## Effort estimate

Expected effort for the bounded AX-surface release is **5–9 engineering weeks** after requirements
are accepted. Reserve an additional **2–4 weeks** if Phase 5 validation requires changing the
frozen capture decision (a proposed event-tap or Carbon path) or substantial browser/Electron
compatibility remediation. Browser extensions or vision fallback
are separate multi-month projects and are not included.

## Assumption register and frozen safe defaults

These are the Phase 0 recorded **provisional** choices Phase 1 through 4 must respect. They are
**frozen pending Phase 5 confirmation, not open to production lanes**: each cell of required evidence below must pass on signed macOS
hardware before any code outside these defaults or any release-readiness claim is accepted. If
Phase 5 falsifies one, the stop conditions apply and a maintainer-approved replacement is
recorded here.

| Risky assumption | Provisional safe default | Fail-closed behavior | Owning boundary | Required Phase 5 evidence |
|---|---|---|---|---|
| A new tool can remain inert until deliberately configured | Disabled by default with an unassigned activation shortcut | Attach/startup performs no Hints AX, panel, input, timer, observer, or permission work | `HintsTool` lifecycle and Settings | Fresh/update startup and idle-cost checks on both OS versions; shortcut becomes active only after explicit assignment and enablement |
| A nonactivating panel can own modal input with the target app frontmost | Panel-only modal input; no event tap, Input Monitoring, or fallback path | Cancel on failed capture, capture loss, Secure Input, or panel-creation uncertainty; release everything | Presentation (`NSPanel`/window/key-window lifecycle) and Input (semantic events only) | Panel capture matrix on macOS 13 and current macOS, including fullscreen Spaces, multiple displays, physical modifiers, Hyperkey activation, and exact target-context restoration |
| Carbon is reliable for the global activation trigger | Carbon registers only the assigned activation shortcut; no modal Carbon registration exists | Unregister on stop; cancel if restore fails or registration cannot be verified | Presentation/Input and the shared hotkey owner in `AppShell` | `.hints` trigger fires and is cancellable on both OS versions, including from Spotlight, Login items, Launchpad, and fullscreen Spaces; Settings recorder suspension excludes it |
| Recursive AX traversal stays within usable-time budgets on real apps | Typed individual reads; 50 ms per-call timeout, depth 40, 4,000 nodes, 1,500 candidates, 750 ms wall clock | Truncated partial result with count-only status; no silent budget extension | `HintAXService` (per-call, traversal accounting) | Count-only p50/p95 profile rows on both OS versions across the application tiers |
| Every action/focus mutation reaches the intended element exactly once | Actions dispatch at most once after full revalidation | Unknown outcome (`kAXErrorCannotComplete`) is never retried; only a fresh observational rescan may follow | `HintAXService` | Stale-element, hung-app, and app/window-change scenarios show exactly one dispatch and zero retries on both OS versions |
| Advertised AX actions alone cover the released control set | Candidate/action matrix below; pointer allowlist empty | Rejected roles cannot become candidates; unsupported surfaces document gaps only | `HintsCore` policy plus `HintAXService` verification | Matrix applied on both OS versions across all application tiers with zero wrong-target invocations |
| Per-display nonactivating overlays are correct across display topology changes | One panel per participating display; cancel on topology or mapping uncertainty instead of guessing | Display change, rearrangement, removal, or failed panel creation cancels the session | Presentation with `HintsCore` geometry inputs | One/multiple displays, negative origin, Retina, attach/remove, rearrange, fullscreen, straddling window on both OS versions |
| Accessibility is the only required permission and no prompt appears at attach/startup | Accessibility only; Input Monitoring unused and unrequested | Revocation cancels immediately; granted-after-denial detection is observational | `AppShell` permission sites and `HintSessionController` | TCC states exercised against the stable-signature, fixed-path bundle on both OS versions; no TCC prompt occurs at quick enable |
| Secure Input and capture loss never leak input | Input cancels before accepting input in both cases | Everything typed stays inside the panel; never reaches the target app or disk/log | Input lane | Secure Input entry/exit, failed capture, and capture-loss scenarios on both OS versions with unchanged target app state |
| Upstream MIT code is reproducible and lawful | Clean-room implementation; no adaptation unless separately pinned, reviewed, and approved | Unpinned sources are not used; provenance gaps mean rewrite or omission | Phase 4 documentation lane | Provenance records for every adapted component, or an explicit clean-room attestation |
| Config preservation survives malformed or newer Hints sections and reset paths | Opaque `tools.hints` handling with failed-load write block; reset either out of scope or preservation-gated | Decode failure blocks Hints writes and side effects; failed preservation aborts reset | `AppCore` config owner with `HintsSettings` validation | Disposable-account persistence matrix on both OS versions, including zones.json/bindings.json checksum checks |

## Frozen release decisions

### Keyboard map

- Label alphabet: `ASDFGHJKL`, case-insensitive.
- Every generation uses the smallest uniform fixed length that covers the candidate count: one
  character up to 9 candidates, two up to 81, three up to 729, and four up to 1,500.
- A modifier-release barrier runs before modal input is accepted.
- Label characters filter the candidate set; typing a full label selects but never auto-invokes.
- Return confirms the selected candidate; Escape and a repeated activation shortcut cancel;
  Backspace deletes one character from the query.
- `/` enters accessible-name search using AX title, label, and description metadata; only committed
  panel text is consumed into the query.
- Space enters scroll-region selection; typed region labels choose a region, then arrow keys,
  Page Up, Page Down, Home, and End scroll it, with key repeat; a bounded rescan follows visibility
  changes.
- There is no sole-result auto-invocation.

### Candidate/action matrix

| Role class | Advertised action taken |
|---|---|
| Button, link, checkbox, radio button, tab, menu item | `AXPress` only when the role advertises it |
| Popup, menu trigger | `AXShowMenu` only when the role advertises it |
| Nonsecure editable control | Focus only when `kAXFocusedAttribute` is explicitly settable |
| Scroll region | The advertised AX scroll/value operation, in scroll mode only |
| Generic/page groups, static text, images, unknown or custom roles with no advertised capability | Excluded |

Every candidate additionally requires a fresh PID/context match, enabled, visible, and on-screen
state, a valid typed frame, and an advertised capability. Secure fields, disabled, hidden,
zero-size, and off-screen elements, Lineup-owned windows, and disconnected-display frames are
rejected.

### Application tiers

- **Functional release blockers on both macOS 13 and the current supported macOS:** Finder,
  System Settings, TextEdit, and a deterministic signed SwiftUI test fixture.
- **Best effort:** Safari, Google Chrome, and one pinned Electron application and version. Coverage
  gaps there are documentable, but a crash, input leakage, stale or wrong invocation, or permission
  violation still blocks the release.
- **Excluded:** every surface listed under "Explicitly deferred".

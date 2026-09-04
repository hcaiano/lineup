# Hints Integration Plan

Status: proposed; implementation has not started  
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
- The implementation is Lineup-native. Small MIT-licensed ideas or functions from Hinto or
  Keyouse may be adapted only after file-level review, attribution, and provenance recording.
- HomeRow code and assets are not available for reuse. Vimac GPL-3 and Keyway AGPL code are
  reference-only and must not be copied.
- Hints is not added to the initial Welcome flow. Discovery happens through Settings, the menu,
  and release notes after the feature exists.
- Bundle ID, signing identity, hotkey signature, Sparkle feed, appcast, and release state remain
  unchanged.

## Council decision

The architecture council agreed on a dependency-free `HintsCore`, a tool-local serial AX service,
generation-based session orchestration, and nonactivating per-display overlays. The chosen input
strategy is **panel-first**: prove that a nonactivating key-capable panel can reliably own modal
input while the target app stays frontmost. Carbon remains the activation mechanism and may
supplement modal routing if proven reliable. A session-only `CGEventTap` requiring lazy,
user-initiated Input Monitoring permission is an explicit fallback only if the signed panel spike
fails. No silent permission escalation and no Hyperkey event-broker refactor are allowed in this
scope.

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
7. Supported actions include AX press, show-menu, and focus for buttons, links, checkboxes, radio
   buttons, tabs, menu items, popups, and editable controls where the AX API exposes a safe action.
8. Primary activation is required. Double-click, right-click, and modifier-click join the release
   only if Phase 0 proves they can be generated safely and predictably without arbitrary stale-
   coordinate clicking.
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
                     +-- panel-first modal input
                     +-- validated Carbon support
                     +-- optional session event tap only after gate
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
- Prefer `AXUIElementCopyMultipleAttributeValues` when it measurably reduces round trips.
- Apply a short messaging timeout before querying each AX element.
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
3. Prefer `AXPress`, `AXShowMenu`, focus, and other explicit AX actions.
4. Use pointer synthesis only for an allowlisted action class proven in Phase 0, after confirming
   no physical mouse button is down; emit a balanced marked down/up pair without yielding.
5. Rescan under a new generation after menu/popover/reveal actions.
6. Cancel on stale or ambiguous state. Never click a remembered coordinate as a guess.

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

Baseline permission: Accessibility only.

Phase 0 must test a nonactivating key-capable panel on macOS 13 and the current supported macOS,
including fullscreen Spaces, multiple displays, Secure Input, physical modifiers, and activation
through Lineup Hyperkey. The target app must remain frontmost and regain its exact context after
the session.

Carbon owns only the global activation shortcut by default. Ephemeral Carbon registrations may be
used for modal hint keys only if the spike proves correct behavior for non-US layouts, IME input,
repeat, registration failure, and Settings recorder suspension.

If the panel/Carbon route fails materially, stop and record the decision before implementing a
temporary `CGEventTap`. The fallback must:

- Add Input Monitoring as an explicit Hints permission.
- Request it only after a user enables or invokes Hints, through `PermissionCenter`.
- Exist only during an active Hints session.
- Keep the callback O(1) and perform no AX or rendering work there.
- Ignore Lineup's synthetic marker and never swallow unmatched key-up or modifier events.
- Cancel on tap disablement, Secure Input, permission loss, or tool stop.
- Pass coexistence testing with Hyperkey before the feature proceeds.

No automatic or hidden fallback from panel capture to an event tap is permitted.

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
- Prefer an unassigned default activation shortcut so a disabled new tool does not reserve a
  global combination for every existing user. Settings and the menu provide the setup path.
- `persistedCombos()` must participate in cross-tool conflicts once the user records a shortcut.
- If Hints settings cannot be decoded, run no Hints side effects, preserve the rejected section,
  block Hints-specific writes, and leave sibling tools operational.
- Preserve unknown settings so downgrades and future schema additions do not lose data.

## Performance and privacy gates

Initial limits are hypotheses to validate in Phase 0, not permission to loosen safety after a slow
scan:

| Measure | Initial gate |
|---|---:|
| Activation callback work | under 2 ms |
| Scanning indicator visible | under 50 ms |
| Native labels available | p50 under 150 ms; p95 under 400 ms |
| Large AX surface response | p95 under 750 ms |
| Hard scan completion/partial failure | under 1 second |
| Per AX call timeout | 50–100 ms |
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

### Phase 0 — Platform, safety, and provenance gates

**Purpose:** settle assumptions that would otherwise force a late architectural rewrite.

**Write scope:** `temp/hints-spikes/**` only, or an external temporary workspace. Keep it
gitignored and delete it after the decisions are captured. No production source writes.

**Tasks:**

- Build a minimal signed probe for panel-first modal capture.
- Test Carbon supplementation separately; do not conflate its result with panel behavior.
- Benchmark bounded AX traversal and candidate coverage in Finder, System Settings, a native
  AppKit app, a SwiftUI app, Safari, Chrome, and one Electron app.
- Test AX actions and allowlisted click variants against stale targets and active mouse buttons.
- Test per-display overlays on one display, negative-origin secondary displays, Retina scaling,
  fullscreen Spaces, and display removal.
- Decide whether Input Monitoring/event-tap fallback is necessary.
- Pin exact upstream commits before inspecting adaptable MIT code. Record any proposed source-
  level adaptation and required notices; default to clean-room implementation.
- Freeze the release keyboard map, candidate-role matrix, supported-app matrix, and click-variant
  list.

**Gate:** signed probes pass required systems and the capture, AX, invocation, overlay, and license
decisions are recorded in this plan or an adjacent approved design note. If capture or safe
invocation cannot meet the contract, narrow the release scope with maintainer approval before
production work begins.

### Phase 1 — Pure Hints core and deterministic tests

**Owners and non-overlapping write scopes:**

- Core lane: `Sources/HintsCore/**` and `Sources/lineup-tests/HintsSuite.swift`.
- Shared-integration owner: minimal `Package.swift` target/dependency wiring and the Hints suite
  invocation in `Sources/lineup-tests/main.swift`. Reuse this same owner/session for Phase 5.

**Tasks:**

- Implement settings, candidate/action models, eligibility and ranking policy.
- Implement fixed-length label allocation, filtering, accessible-name search, and overflow.
- Implement the session reducer, normalized modal-input events, key/filter commands, geometry,
  scan budgets, truncation, and count-only diagnostics.
- Add exhaustive tests for uniqueness, stability, prefix safety, filtering, search determinism,
  cancellation, stale generations, role policy, geometry, limits, and settings validation.

**Gate:** `swift run lineup-tests` and `swift build` pass; `HintsCore` imports Foundation only.

### Phase 2A — AX scanner and invocation lane

**Owner:** macOS headless implementation lane.  
**Write scope:** `Sources/lineup/Tools/Hints/AX/**` only.

**Tasks:** implement the serial AX service, bounded traversal, opaque target repository, candidate
conversion, context revalidation, explicit AX actions, scroll backend, safe synthesis allowlist,
and deterministic teardown. Use local patterns from `WindowMover` and `AppActivator`; do not edit
or extract those files in this phase.

**Gate:** app target compiles, Phase 0 budgets are retained, no AX element crosses the service
boundary, and the signed manual probe confirms cancellation releases every target repository.
Deterministic policy remains tested in `HintsCore`; this lane must not make the dependency-free
runner import the AppKit target.

### Phase 2B — Overlay and presentation lane

**Owner:** `@designer` for implementation and visual evidence.  
**Write scope:** `Sources/lineup/Tools/Hints/Presentation/**` only.

**Tasks:** implement per-display panels, custom label canvas, query/search state, overlap handling,
truncation and error states, appearance/accessibility behavior, and deterministic animation.

**Gate:** render/geometry checks plus visual evidence for one display, two displays, dense labels,
light/dark, increased contrast, and Reduce Motion. The target app remains frontmost and overlays
never intercept pointer input.

### Phase 2C — Modal input lane

**Owner:** macOS input implementation lane.  
**Write scope:** `Sources/lineup/Tools/Hints/Input/**` only.

**Tasks:** implement the capture strategy selected in Phase 0 as a thin adapter over the normalized
input events and reducer commands already owned by `HintsCore`; add the modifier-release barrier,
IME/non-US adapter behavior, capture-loss cancellation, and an injectable event source. If the
approved strategy uses an event tap, keep every permission and coexistence requirement from the
input section above.

**Gate:** signed manual capture matrix passes; Hyperkey never receives a stuck modifier or leaked
synthetic event; Settings shortcut recording prevents Hints activation.

Phases 2A, 2B, and 2C may run in parallel after Phase 1, provided Phase 0 froze their interfaces.
If a lane discovers that a shared `HintsCore` contract must change, it requests that change from
the Phase 1 core owner rather than editing the shared scope concurrently.

### Phase 3 — Tool lifecycle and session orchestration

**Owner:** integration implementation lane.  
**Write scope:** `Sources/lineup/Tools/Hints/HintSessionController.swift`,
`Sources/lineup/Tools/Hints/HintsTool.swift`, and Hints-local support files outside `AX`, `Input`,
and `Presentation`.

**Tasks:** connect scan/input/presentation effects; implement generation-aware transitions,
activation and cancel actions, rescan behavior, menu items, warnings, `persistedCombos()`, hotkey
restore failures, termination cleanup, disable-during-session behavior, wake/display/app-change
cancellation, and malformed-settings blocking.

**Gate:** all lifecycle transitions are testable through injected services; `stop()` leaves no AX
repositories, windows, hotkeys, capture, timers, observers, or pending async effect.

### Phase 4 — Settings and interaction polish

**Owner:** `@designer`; copy reviewed by the parent orchestrator.  
**Write scope:** `Sources/lineup/Tools/Hints/HintsSettingsPane.swift` and Hints-specific Settings
components/help strings only.

**Tasks:** add shortcut setup, mode/label/search/scroll preferences, permission and malformed-
config banners, conflict messaging, supported-surface explanation, and accessible keyboard help.
Use existing shared recorder and settings-store behavior rather than creating alternate owners.

**Gate:** pane renders while disabled, blocked writes spring back without data loss, conflicts name
Hints correctly, and copy never promises universal application coverage.

### Phase 5 — Shared integration, one writer

**Owner:** one integration lane; no concurrent edits to this scope.  
**Write scope:** `Sources/AppCore/ToolID.swift`, `Package.swift` final wiring,
`Sources/lineup/App/AppShell.swift`, `Sources/lineup/App/Brand.swift`,
`Sources/lineup/App/StatusItemController.swift`, `Sources/lineup/Settings/Components/ToolIcon.swift`,
relevant onboarding/discovery copy, `Sources/lineup-tests/AppSuite.swift`, sibling suite source
scans, and `Sources/lineup-tests/main.swift`.

**Tasks:** append the stable ID, register Hints fourth, preserve default-off seeding, add metadata
and menu/settings discovery, revise inaccurate fixed “three tools” copy without adding Hints to
Welcome, and update every fixed registration/path/permission/single-owner assertion. Preserve
legacy-import tests that correctly expect only the three legacy-derived tool sections.

**Gate:** no frozen `Tool` change; no duplicate permission/updater/activation/config owner; old and
unknown config sections survive; all source-scan invariants remain at least as strict as before.

### Phase 6 — Documentation and provenance

**Owner:** documentation lane.  
**Write scope:** `PRODUCT.md`, `README.md`, `BUILDING.md`, `AGENTS.md`, Hints-owned documentation,
and third-party notice files plus `Scripts/build-app.sh` only if MIT code is actually adapted.

**Tasks:** document Hints' behavior, default-off posture, support matrix, permission use, privacy,
architecture, test commands, and explicit exclusions. Record exact upstream commit/file/function,
copyright, modifications, and retained license for every adapted MIT component.

**Do not touch:** `web/appcast.xml`, `web/downloads/`, tags, release versions, notarization state,
or signing identities unless the maintainer separately requests release work.

**Gate:** docs and shipped notices match the implemented permission path and support contract.

### Phase 7 — Stabilization and evidence

**Owner:** each defect returns to the owner of its write scope; command-only validation goes to the
validation lane.  
**Write scope:** focused fixes in the owning phase's files and approved evidence locations only.

**Tasks:** execute the full matrix below, profile count-only timings, fix regressions without
loosening safety limits, and collect the visual/manual evidence required by `CONTRIBUTING.md`.

**Gate:** every automated and manual acceptance criterion passes. A passing check is verification,
not merge approval; only the maintainer approves and merges.

## Execution order

```text
Phase 0 risk gates
       |
Phase 1 HintsCore/API freeze
       |
       +-------- Phase 2A AX --------+
       +-------- Phase 2B UI --------+--> Phase 3 orchestration
       +-------- Phase 2C input -----+            |
                                                   v
                                          Phase 4 settings/UI
                                                   |
                                          Phase 5 shared integration
                                                   |
                                          Phase 6 docs/provenance
                                                   |
                                          Phase 7 stabilization
```

- Phase 0 is sequential because input permission, invocation, and compatibility decisions define
  the production architecture.
- Phase 1 is sequential because all writer lanes depend on its pure contracts.
- Within Phase 1, the core lane and shared-integration owner have disjoint scopes; the latter must
  remain the owner of `Package.swift` and `lineup-tests/main.swift` when Phase 5 resumes.
- Phases 2A/2B/2C are safe in parallel because their write scopes do not overlap.
- Phase 3 waits for all three lanes so it integrates frozen implementations rather than changing
  their contracts concurrently.
- Phase 5 is intentionally serialized under one writer because fixed tool lists, registration,
  branding, and source scans are tightly coupled.
- Documentation waits for the actual permission and support decisions so it cannot drift.

## Verification plan

### Automated

Run after every production phase:

```sh
swift run lineup-tests
swift build
```

After bundle-impacting integration:

```sh
UNIVERSAL=0 ./Scripts/build-app.sh <temporary-output-directory>
```

Do not launch Lineup as routine automated verification.

Required automated coverage:

- Label uniqueness, fixed length, stability, configured alphabets, and overflow.
- Filter/search ordering, Backspace, exact/full-label activation, and no accidental sole-result
  auto-invocation unless explicitly approved.
- Reducer transitions, cancellation from every active state, and stale-generation rejection.
- Candidate policy, secure/disabled/off-screen exclusion, parent-child dedupe, and scan truncation.
- Multi-display geometry with positive and negative origins and straddling frames.
- Fresh/current/malformed/newer Hints settings; default-off startup; unknown-key preservation.
- Shortcut reservation/conflicts while enabled and disabled after a user records a combo.
- Four-tool registration/attach/start/stop order and all existing unique-owner source scans.
- Legacy imports remain read-only and continue creating only Zones/Cycler/Hyperkey sections.

### Signed manual-app matrix

Launching the app is permitted only for this explicit manual verification pass.

| Area | Required scenarios |
|---|---|
| Lifecycle | disabled startup, first enable, live disable during scan/presentation/invocation, repeated shortcut, quit, wake |
| Permissions | Accessibility denied, newly granted, revoked mid-session; conditional Input Monitoring denied/granted if selected |
| Input | Escape, Backspace, repeat, modifiers released late, non-US/IME where available, Secure Input, capture loss |
| Cross-tool | Hyperkey on/off and used as trigger, Zones drag/editor activity, Cycler HUD, Settings shortcut recorder open |
| Target safety | stale element, hung app, secure field, disabled/off-screen element, app/window changes during invocation |
| Displays | one/multiple, negative origin, Retina scaling, rearrange, attach/remove, fullscreen, straddling window |
| AX surfaces | Finder, System Settings, native AppKit, SwiftUI, Safari, Chrome, one Electron app, sheets, menus, popovers |
| Behavior | labels, filter, search, all approved actions, menu rescan, nested scroll regions, no-match and truncation states |
| Persistence | fresh/current/malformed/newer config, downgrade preservation, conflict restoration, failed-load write block |
| Visual | light/dark, contrast, Reduce Motion, dense overlap, clamping, click-through, no app activation |

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
- The release uses no unapproved TCC permission and makes no universal browser/custom-UI claim.
- Config and identity contracts remain intact; no legacy source is modified.
- Any adapted MIT code has complete provenance and bundled attribution.
- `swift run lineup-tests`, `swift build`, the host-architecture app build, and the manual evidence
  matrix pass.

## Risks and stop conditions

1. **Modal input:** if the panel cannot capture reliably and a session tap conflicts with Hyperkey,
   stop; do not invent a third global-input owner inside this change.
2. **AX latency:** if native apps cannot produce useful partial results under the hard deadline,
   revisit candidate scope rather than raising timeouts until Lineup stalls.
3. **Invocation safety:** if click variants cannot prove target freshness and balanced input, omit
   them with explicit maintainer approval instead of guessing.
4. **Browser expectations:** if AX coverage is insufficient, document the limitation; DOM/vision
   support requires a separate proposal.
5. **Licensing:** if provenance cannot be established for an adapted component, rewrite it or omit
   it.
6. **Visual density:** if 1,500 labels cannot remain usable, rank/cull or progressively reveal;
   do not create one window per hint.

## Effort estimate

Expected effort for the bounded AX-surface release is **5–9 engineering weeks** after requirements
are accepted. Reserve an additional **2–4 weeks** if Phase 0 forces Input Monitoring/event-tap work
or substantial browser/Electron compatibility remediation. Browser extensions or vision fallback
are separate multi-month projects and are not included.

## Open decisions resolved by Phase 0

- Nonactivating panel only, panel plus validated Carbon, or explicit session event-tap fallback.
- Exact keyboard map and whether the activation shortcut ships unassigned.
- Final candidate-role and supported-app matrices.
- Which click variants meet the safety gate.
- Whether any Hinto/Keyouse MIT code is worth adapting rather than rewriting.

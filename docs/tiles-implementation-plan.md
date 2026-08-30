# Tiles: implementation plan

Status: implemented and validated; agreed with Fable; accepted by Grok and Claude Opus
Date: 2026-08-30
Owner: Lineup team

## 1. Outcome

Add a fourth Lineup tool named **Tiles**.

Tiles automatically arranges normal application windows in the layouts already owned by Zones.
Each Zones leaf is one tile. Each tile is an ordered stack of windows. Tiles also provides four
lightweight workspaces that switch as one global desktop across all connected displays.

Tiles is off by default. Its Settings entry uses the shared `ToolPane` header and global switch.
The pane has no layout editor and no advanced behavior options.

The feature uses public macOS Accessibility operations for its own runtime. It does not control
native macOS Spaces, move windows off-screen, hide whole applications, change SIP, or use a Dock
scripting addition.

## 2. Research decision

The research is in [tiling-spaces-research.md](research/tiling-spaces-research.md).

The following ideas are adopted:

- Hyprland: automatic placement, workspace commands, and grouped windows.
- AeroSpace: separate the window tree from macOS Spaces and make workspace state explicit.
- Amethyst: calculate placement as pure assignments before mutating Accessibility elements.
- Rectangle: use bounded AX calls, confirm results, and fail visibly.
- Existing Lineup: keep `ZonesCore.Node` as the only layout geometry and keep the `Tool`
  lifecycle/config contracts unchanged.

The external research initially recommended no workspaces or automatic tiling because it used the
previous project goal as its product boundary. The new request explicitly replaces that boundary.
This plan still follows the safety part of the recommendation: no native Space control, private
Space API, off-screen staging, or persistent window identity.

## 3. Product contract

### 3.1 Names

- Tool and Settings label: `Tiles`
- Stable config ID: `tiles`
- User-facing context: `Workspace 1` through `Workspace 4`
- Internal model: `WorkspaceID` and `Workspace`
- Summary: `Automatically tile windows into your Zones, with workspaces and stacks.`

`Tiles` is direct and matches the user request. `Scenes` is not used in the UI because it hides
the main behavior. The pane explains once that a Tiles workspace is not a macOS Space.

### 3.2 Opinionated defaults

- Exactly four global workspaces.
- Workspace 1 is active at start.
- Current visible eligible windows are adopted into Workspace 1 when Tiles starts.
- New windows fill empty tiles in visual order.
- When every tile is occupied, a new window joins the focused tile on the same display.
- If no managed tile is focused, the shortest stack wins, with visual order as the tie-breaker.
- Every stack member in the active workspace stays unminimized at the same frame.
- The selected stack member is raised above the others.
- Managed windows in inactive workspaces are staged by Tiles when they are reachable.
- Tiles restores only state that Tiles changed.
- Four workspaces, placement rules, stack rules, and staging rules are not configurable.

### 3.3 Eligibility

Tiles manages a window only when all of these are true:

- It belongs to another regular application.
- Its role is `AXWindow` and its subrole is `AXStandardWindow`.
- It is currently visible and was not already minimized when first discovered.
- Position, size, and minimized state are readable.
- Position, size, and minimized state are settable.
- It intersects a connected display.
- It is not a native Full Screen window.

Sheets, dialogs, popovers, utility panels, Lineup windows, native Full Screen windows, and windows
with incomplete AX support remain unmanaged. This is a fixed safety policy, not an exclusion UI.

Tiles adopts only visible windows that public AX/CG correlation reports in the current native Space.
Correlation builds a PID/frame/title bipartite graph. A balanced component with a perfect matching
proves group reachability even when empty CG titles make the individual pairing ambiguous, as can
happen when a stack puts several windows of one app on the same frame. An unbalanced component is
ineligible. An unsupported optional `AXFullScreen` attribute counts as not Full Screen; other read
failures keep eligibility incomplete. After adoption, a retained minimized AX element remains a
valid mutation target even though it is absent from the on-screen CG snapshot. This lets a
destination workspace restore all of its Tiles-staged windows in one ordered plan. A non-minimized
managed window that becomes unreachable keeps its assignment and visibility state, but effects skip
it until it is reachable again. A native Space change, detected from application activation or
snapshot divergence, triggers one full reconciliation and never a placement mutation by itself.
Tiles does not counteract a native Space switch that macOS performs when it deminimizes a
Tiles-staged window. The intended workflow is to use Tiles workspaces instead of changing native
Spaces while Tiles is active.

## 4. Caller flows

### 4.1 Enable Tiles

1. The user opens Settings > Tiles and enables the shared header switch.
2. `ToolRegistry.setEnabled` persists `tools.tiles.enabled = true` before starting the tool.
3. `TilesTool.start` validates Tiles settings, the Zones layout snapshot, Accessibility access,
   and recovery-journal access.
4. It registers configured hotkeys and workspace/application/screen observers.
5. It starts one serial AX worker and performs a stable initial snapshot.
6. It adopts eligible on-screen windows into Workspace 1, stores their original frames, and
   applies the current Zones leaf frames.
7. It shows a short non-activating HUD for Workspace 1.

If a required preflight fails, Tiles acquires no window-management resources and shows an
actionable warning. A settings-save failure leaves the tool disabled.

### 4.2 Open a new window

1. An AX window-created event marks the application PID dirty.
2. Events for the same PID are coalesced for 120 ms.
3. The AX worker retries discovery up to three times while role and frame data settle.
4. The pure allocator places the new window in the active workspace and its current display.
5. It selects the first empty tile. If none is empty, it uses the focused tile on that display.
   If no managed tile is focused, it uses the shortest stack.
6. A journal intent is written before the frame changes.
7. The executor applies and verifies the tile frame. It raises the window when that window is
   already AX-focused or when it fills an empty tile. A background overflow window joins behind the
   selected stack member without raising or taking focus, so it cannot cover the window in use.
8. The reducer commits the assignment only after the required effects succeed.

Duplicate create events and a later full reconciliation must not create duplicate assignments.

### 4.3 Cycle the focused tile

1. The hotkey or menu sends `.cycleFocusedTile(.forward)`.
2. The reducer finds the focused managed window and its stack.
3. It selects the next eligible member with wrap-around.
4. The executor raises and focuses the target. It does not minimize the previous member.
5. The reducer commits the selected member after effect execution. Raise and focus are best-effort
   presentation effects and do not roll back the selection if macOS rejects them.
6. The HUD shows up to seven window titles and the selected position.

Cycling a stack with fewer than two eligible members is a no-op. A manually minimized member is
skipped until the user restores it.

### 4.4 Switch workspace

1. The user chooses Workspace 1...4 from the menu or dispatches next/previous.
2. The coordinator reconciles the current live snapshot.
3. It creates one transition plan and writes the complete staging intent to the recovery journal.
4. It desminimizes only windows previously staged by Tiles in the destination workspace. This
   happens before source minimization when the plan can do so, so the desktop is never empty during
   the transition. A target app that serializes these calls may require minimize-first for its own
   windows; that exception must be explicit in the effect plan.
5. It minimizes every managed visible window in the source workspace that is not shared with an
   in-flight destination effect.
6. It reapplies current Zones frames to destination stacks.
7. It raises each selected stack member, then focuses only the most recently focused member.
8. It verifies required effects and commits the active workspace.
9. It updates the journal and displays the workspace HUD.

The active workspace does not change in the model before required effects are confirmed. A failed
essential effect causes compensation. A window that closes during the plan is removed and does not
fail the whole transition.

### 4.5 Move a window to another workspace

1. The user chooses `Move Focused Window to Workspace` from the Tiles menu or uses the configured
   next-workspace action.
2. The reducer removes the focused window from its current stack.
3. It places the window in the first empty tile on the same display in the destination workspace,
   then uses the shortest stack fallback.
4. If the destination is inactive, Tiles journals and minimizes the window.
5. If the destination is active, Tiles applies the target frame and raises the window.
6. Closing the selected source member selects the nearest remaining member without rebalancing
   other stacks.

### 4.6 Use Zones while Tiles is active

Zones remains the layout owner and the manual placement tool.

- Editing a layout reflows all workspace stacks to the new leaves. Only the active workspace
  produces visible frame changes.
- Shift-drag or a direct Zone-N placement moves the managed window to that tile and selects it.
- Dropping onto an occupied tile adds the window to that stack.
- A freeform Zones quick action such as Full, Center, Left, or Right first snaps the managed window,
  then detaches it from Tiles for the current session. This is the automatic floating escape hatch.
- Shift-dragging a detached window into a zone adopts it again.
- The Tiles Space shortcut is a true toggle: a managed focused window is restored to its safe
  adoption frame and detached; a detached focused window is adopted into the active workspace and
  tiled. Every frame write is verified before the ownership mutation, and failures show HUD feedback.
- Zones quick-action arrows remain placement controls; Tiles H/J/K/L shortcuts navigate focus
  between tiles.
- A normal user drag whose center settles inside another leaf transfers the window to that tile.
- An external resize of a managed window is corrected to its tile after debounce.

This behavior needs an explicit placement event from Zones. Tiles must not infer every manual
Zones action from a delayed frame notification.

### 4.7 External activation and minimization

- If the user activates a managed window from an inactive workspace through any external path,
  including the Dock, Cmd-Tab, or Lineup's Cycler tool, Tiles switches to that workspace and
  selects the window. Cycler raise/focus actions count as external activation and follow the same
  rule, so the tools do not fight over staging.
- If the user manually minimizes a managed window, Tiles records `minimizedByUser`, keeps its
  assignment, excludes it from cycling, and never restores it automatically.
- If the user restores it, Tiles clears `minimizedByUser`, applies the current tile frame, and
  selects it.

### 4.8 Disable, quit, or crash

Normal stop is synchronous because the `Tool` contract is synchronous:

1. Stop accepting events.
2. Unregister hotkeys, notifications, observers, timers, and HUDs.
3. Ask the AX worker to restore within a short global deadline.
4. Desminimize only windows staged by Tiles.
5. Restore an original frame only when the current frame still matches the last frame applied by
   Tiles. Preserve a frame changed by the user.
6. Clear the journal only after verification.
7. Release all AX elements and runtime assignments.

If the deadline expires, stop returns with the journal intact. On crash or force quit, minimized
windows remain recoverable from the Dock. At the next start, conservative journal recovery runs
before a new session is adopted.

## 5. Architecture

```text
ToolRegistry / Settings / Menu
             |
         TilesTool
             |
      TilesCoordinator  <----- ZoneLayoutSource
         |        ^            WindowPlacementCenter
         v        |
      TilesCore reducer
         |
   immutable EffectPlan
         |
   AXWindowSystem (serial worker)
         |
 public Accessibility API
```

The reducer decides. The AX boundary executes. The coordinator commits only verified results.
Callbacks enqueue small events and never perform AX work inline.

### 5.1 SwiftPM targets

Add:

```swift
.target(name: "TilesCore", dependencies: ["ZonesCore"])
```

Add `TilesCore` to the `lineup` and `lineup-tests` dependencies. `TilesCore` imports Foundation and
ZonesCore only. It must not import AppKit, ApplicationServices, Carbon, or AppCore.

### 5.2 Pure model

```swift
public struct WorkspaceID: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: Int // 1...4
}

public struct WindowToken: RawRepresentable, Hashable, Sendable {
    public let rawValue: UUID // runtime only
}

public struct TileID: Equatable, Hashable, Sendable {
    public let screenKey: String
    public let leafIndex: Int
}

public struct TileAddress: Equatable, Sendable {
    public let id: TileID
    public let normalizedCenter: CGPoint // rebase data, never identity
}

public struct TileStack: Equatable, Sendable {
    public var address: TileAddress
    public private(set) var order: [WindowToken]
    public private(set) var selected: WindowToken?
}

public enum WindowVisibility: Equatable, Sendable {
    case visible
    case stagedByTiles
    case minimizedByUser
}

public struct ManagedWindow: Equatable, Sendable {
    public let token: WindowToken
    public var workspace: WorkspaceID
    public var tile: TileAddress
    public var visibility: WindowVisibility
    public var adoptionFrame: CGRect
    public var lastAppliedFrame: CGRect?
    public var focusEpoch: UInt64
}

public struct Workspace: Equatable, Sendable {
    public let id: WorkspaceID
    public var screens: [String: [TileStack]]
}

public struct TilesSession: Equatable, Sendable {
    public var activeWorkspace: WorkspaceID
    public var workspaces: [WorkspaceID: Workspace]
    public var windows: [WindowToken: ManagedWindow]
    public var nextFocusEpoch: UInt64
    public var transition: Transition?
}
```

The model does not persist `WindowToken`, membership, stack order, or selected windows.

### 5.3 Invariants

1. Exactly four workspaces exist and exactly one is active.
2. Every managed window occurs in one stack and one `ManagedWindow` record.
3. Stack order contains no duplicates.
4. `selected` is nil only for an empty stack and otherwise belongs to `order`.
5. Window workspace/tile values match their owning stack.
6. Every tile address resolves from the current Zones leaves for its display.
7. Inactive-workspace windows are staged by Tiles, manually minimized, or left untouched because
   they were unreachable when the workspace changed.
8. Tiles never restores a window recorded as manually minimized.
9. The session changes only through one coordinator.
10. Effects from an old mutation generation cannot commit.
11. A failed persisted-settings save cannot change live settings.
12. `stop` leaves no owned resource alive.

### 5.4 Pure decisions

```swift
public enum TileAllocator {
    public static func destination(
        stacks: [TileStack],
        focusedTile: TileAddress?
    ) -> TileAddress?
}

public enum LayoutRebase {
    public static func rebase(
        stacks: [TileStack],
        from oldLeaves: [NormalizedLeaf],
        to newLeaves: [NormalizedLeaf]
    ) -> [TileStack]
}

public enum TilesReducer {
    public static func plan(
        state: TilesSession,
        event: TilesEvent,
        snapshot: WindowSnapshot,
        layouts: LayoutSnapshot
    ) -> TilesPlan

    public static func commit(
        state: TilesSession,
        plan: TilesPlan,
        results: [WindowEffectResult]
    ) -> TilesSession
}
```

Rebase maps old stacks by normalized center and greatest intersection. A merge concatenates stack
orders in old visual order. The most recently focused member becomes selected. A split keeps the
old stack in the child containing the old normalized center and creates empty sibling stacks.

## 6. Integration contracts

### 6.1 Read-only Zones layout source

The shell owns and injects this capability. Tiles does not reach into `ZonesTool` or read another
tool through `ToolConfigScope`.

```swift
@MainActor
protocol ZoneLayoutSource: AnyObject {
    func snapshot(for screens: [LiveScreen]) throws -> LayoutSnapshot
    func observe(_ handler: @escaping () -> Void) -> ObservationToken
}
```

`PersistedZoneLayoutSource` decodes the authoritative Zones section from
`LineupAppConfigStore`, validates `LineupConfig`, and uses the same default layout as Zones when the
section is absent. An invalid Zones section pauses Tiles instead of silently changing geometry.

`LineupAppConfigStore` publishes changed `ToolID` values only after a successful atomic write.
The source reacts only to `.zones`.

### 6.2 Zones placement events

The shell creates one `WindowPlacementCenter` and injects it into Zones and Tiles.

```swift
@MainActor
struct WindowPlacementEvent {
    let window: AXUIElement
    let target: PlacementTarget
}

enum PlacementTarget {
    case zone(screenKey: String, index: Int, frame: CGRect)
    case freeform(frame: CGRect)
}
```

`WindowMover` returns the moved window and confirmed frame. `ZonesTool` and `DragSnapController`
publish only successful user placements. Tiles maps the AX element to its runtime token with
`CFEqual` and applies the behavior in section 4.6.

The event center is internal to the AppKit executable. `AXUIElement` never enters `TilesCore` and
is never persisted.

### 6.3 AX window system

```swift
protocol TilesWindowSystem: AnyObject {
    func start(_ receive: @escaping @Sendable (WindowSystemEvent) -> Void) throws
    func snapshot(_ scope: SnapshotScope) -> WindowSnapshot
    func apply(_ effects: [WindowEffect]) -> [WindowEffectResult]
    func stop()
}

enum WindowEffect: Equatable, Sendable {
    case setFrame(WindowToken, CGRect, MutationID)
    case setMinimized(WindowToken, Bool, MutationID)
    case raise(WindowToken, MutationID)
    case focus(WindowToken, MutationID)
}
```

`AXWindowSystem` owns retained AX elements, ephemeral token mapping, observers by PID, timeouts,
frame conversion, size-position-size writes, confirmation, and error classification. Its serial
worker is not the main queue. Immutable screen snapshots cross the boundary.

Use `AXUIElementSetMessagingTimeout` on every application and window element. Keep each call at or
below 250 ms. Distinguish `cannotComplete`, invalid element, unsupported attribute, rejected frame,
and gone window. No retry loop runs on the main actor.

Tiles does not reuse Cycler's private CGWindowID bridge. Removing that existing bridge is a
separate cleanup unless peer review proves it is required by this feature.

## 7. Observation and reconciliation

Observe:

- `NSWorkspace.didLaunchApplicationNotification`
- `NSWorkspace.didTerminateApplicationNotification`
- `NSWorkspace.didActivateApplicationNotification`
- `NSWorkspace.didHideApplicationNotification`
- `NSWorkspace.didUnhideApplicationNotification`
- `NSApplication.didChangeScreenParametersNotification`
- system wake
- per-app AX create, destroy, focus, move, resize, minimize, deminimize, and title changes when
  supported

One AX observer is required per application. Unsupported notification registration reduces event
coverage but does not block the PID.

Callbacks enqueue PID/token/type and return. Coalesce create events for 120 ms and move/resize
events for 150 ms. Reconcile fully at start, after workspace transitions, after app activation,
after layout/display changes, and with bounded healing passes at 250 ms, 1 s, and 3 s after a
mutation. Do not poll permanently.

Own mutations carry `MutationID`. Late notifications confirm or are ignored; they never produce a
second placement plan.

The current-native-Space rule from section 3.3 applies to every snapshot and effect. If a retained,
non-minimized AX element is no longer correlated with the current on-screen CG snapshot, mark it
unreachable and skip it. A retained minimized element stays a valid mutation target, so a workspace
transition restores all Tiles-staged destination windows in one ordered plan: deminimize first,
then frame, raise, and focus. The single-window barrier remains only for ownership drift, where
another actor unminimized a Tiles-staged window on a different native Space. If macOS changes native
Space as a result, accept the system change and run one new reconciliation.

## 8. Recovery journal

Use `~/.config/lineup/tiles-recovery.json`, schema 1, atomic writes, and file mode `0600`.

Persist only recovery data, never the live workspace model:

```swift
struct RecoveryRecord: Codable {
    var bundleIdentifier: String
    var pid: Int32
    var role: String
    var subrole: String
    var titleDigest: String
    var ordinalAmongExactPeers: Int
    var adoptionFrame: CGRect
    var lastAppliedFrame: CGRect?
    var stageIntent: Bool
}
```

Write `stageIntent = true` before the minimize call so no crash interval loses authorship. After a
confirmed restore, remove that record atomically.

Recovery matches only one strong candidate with the same running PID, bundle, role/subrole, title
digest, compatible frame, and ordinal. Ambiguous records do not mutate a window. They remain as an
actionable `Restore Windows` warning, while the user can always use the Dock.

Do not store raw window titles. Do not claim identity across logout, app relaunch, or reboot.

## 9. Settings, menu, HUD, and shortcuts

### 9.1 Settings pane

Register Tiles after Zones and before Cycler. The existing dynamic sidebar creates the new entry.
`ToolPane` provides the title, summary, icon, warning area, and global switch.

The content has three compact sections:

1. **Workspace**: four native buttons with the active one selected. Runtime actions are disabled
   while Tiles is off. A caption says `Uses your Zones layouts. Workspaces are separate from macOS Spaces. Use a Zones Hyper+arrow quick action to float a window.`
2. **Behavior**: one `Space between tiles` switch. On uses the fixed 8 pt product spacing; off
   uses the exact Zones frames. A caption explains the fixed fill-then-stack policy.
3. **Shortcuts**: recorder rows grouped as workspace and stacks, focus tile, move window, and
   layout. The groups include four numbered workspace actions, the three legacy workspace/stack
   actions, four focus directions, four move directions, Switch Split Direction, and Toggle Tiled /
   Freeform. Numbers switch workspaces; physical Shift-number moves the focused window without
   switching. Shift-Tab reverses the stack when that generated reverse is available.

Before first activation, Tiles has no settings section and shows its adaptive recommendation only
in memory, so a disabled never-activated tool reserves no shortcut combinations. On first
activation, Tiles writes an adaptive preset from the current Hyperkey mode. With
`includeShift=false`, numbered workspaces use mask `6400` plus 1/2/3/4, focus left/down/up/right
uses mask `6400` plus H/J/K/L, movement uses full Hyper mask `6912` plus H/J/K/L, and stack/split/
toggle uses mask `6400` plus Tab/Return/Space. The legacy relative workspace rows are unassigned.
With `includeShift=true`, numbered workspace rows still select their workspace with full Hyper but
do not generate a physical Shift move because that counterpart cannot be distinguished; focus uses
full Hyper plus H/J/K/L, movement uses full Hyper plus U/I/O/P, and stack/split/toggle use full
Hyper plus Tab/Return/Space. Existing settings,
including explicit null bindings, are never normalized; reset creates the current adaptive preset.
Only the three cyclic workspace/stack actions can generate a Shift reverse, and the UI shows hints
only for reverses that are available.

Cycler receives no new app bindings as part of this preset. H/J/K/L remain the recommended Tiles
focus letters; any existing Cycler rows remain explicit and win normal conflict checks.

Zones' fresh quick-action defaults use the current Hyperkey mask too: `6400` when Include Shift is
off and `6912` when it is on. Existing saved or legacy `6912` bindings are preserved; in compact
mode they therefore require a physical Shift with Caps+arrow. A live Include Shift change does not
rewrite or re-register an existing Zones section; the current mode is used when fresh defaults are
first registered or saved.

Only a genuinely absent Zones section uses these adaptive defaults. A stored legacy
`LineupConfig` whose `shortcuts` field is nil keeps the historical `ShortcutKit.defaults` full-Hyper
(`6912`) quick actions until the user explicitly changes or resets it.

The pane reuses `SettingsSectionView`, `SettingsRow`, `SettingsCaption`, `ShortcutRecorder`, and
`BlockedBanner`. It remains editable while the tool is off. It uses native controls, blue as the
only accent, explicit accessibility labels, and no nested `TabView`.

### 9.2 Menu

Tiles contributes one compact submenu:

- Workspace 1...4, with a check on the active workspace
- Move Focused Window to Workspace > 1...4
- Focus Tile > Left, Right, Up, Down
- Move Focused Window > Left, Right, Up, Down
- Switch Split Direction
- Toggle Tiled / Freeform
- Next Window in Tile

`Restore Windows` appears only when recovery is required. There is no healthy `Show All Windows`
row and no list of managed windows.

### 9.3 HUD

Use a non-activating, click-through `NSPanel` based on the existing Cycle HUD behavior.

- Workspace switch: large workspace number and four position indicators.
- Stack cycle: app icon, up to seven window titles, selected row, and position.
- Failure: short orange status that cannot be mistaken for success.
- Selection and progress use `Brand.blue` only.
- Use `HUDMotion`, `canJoinAllSpaces`, `fullScreenAuxiliary`, and `ignoresCycle`.
- Post an accessibility announcement such as `Workspace 2` or `Window 2 of 4`.

### 9.4 Tool icon

Use the existing generated `AppStyleIcon` path with a Tiles-specific SF Symbol and tool tint. Do
not add a new raster asset unless visual testing proves the fallback is inconsistent with the
other entries.

## 10. Persisted configuration

```swift
public struct TilesSettings: Codable, Equatable {
    public static let currentSchema = 1
    public var schemaVersion: Int
    public var tileSpacingEnabled: Bool
    public var workspace1: ShortcutBinding?
    public var workspace2: ShortcutBinding?
    public var workspace3: ShortcutBinding?
    public var workspace4: ShortcutBinding?
    public var nextWorkspace: ShortcutBinding?
    public var nextWindow: ShortcutBinding?
    public var moveWindowToNextWorkspace: ShortcutBinding?
    public var focusTileLeft: ShortcutBinding?
    public var focusTileRight: ShortcutBinding?
    public var focusTileUp: ShortcutBinding?
    public var focusTileDown: ShortcutBinding?
    public var moveWindowLeft: ShortcutBinding?
    public var moveWindowRight: ShortcutBinding?
    public var moveWindowUp: ShortcutBinding?
    public var moveWindowDown: ShortcutBinding?
    public var toggleSplitOrientation: ShortcutBinding?
    public var toggleTiled: ShortcutBinding?
}
```

The opaque tool section is:

```json
{
  "enabled": false,
  "settings": {
    "schemaVersion": 1,
    "tileSpacingEnabled": true,
    "workspace1": null,
    "workspace2": null,
    "workspace3": null,
    "workspace4": null,
    "nextWorkspace": null,
    "nextWindow": null,
    "moveWindowToNextWorkspace": null,
    "focusTileLeft": null,
    "focusTileRight": null,
    "focusTileUp": null,
    "focusTileDown": null,
    "moveWindowLeft": null,
    "moveWindowRight": null,
    "moveWindowUp": null,
    "moveWindowDown": null,
    "toggleSplitOrientation": null,
    "toggleTiled": null
  }
}
```

Do not increment the `LineupAppConfig` envelope schema. A missing section uses the current adaptive
defaults in memory and materializes them on first activation or save. An explicitly stored section,
including one with all-null shortcut fields, remains user state and is never normalized. A future or
invalid Tiles section runs no window mutations, preserves the rejected JSON, and offers the same
safe reset discipline as the current tools.

Missing shortcut fields decode as nil for compatibility with older settings; they are not filled in
or rewritten while stored state is loaded. The schema stays at `1`. `persistedCombos()` includes
generated reverse combos when they exist. Recording checks enabled and disabled sibling tools through
`boundCombos`. `start`, restore-after-recording,
activation, and the retry timer follow the current hotkey failure behavior.

## 11. File plan

```text
Package.swift
Sources/AppCore/ToolID.swift

Sources/TilesCore/
  TilesModel.swift
  TilesReducer.swift
  TileAllocator.swift
  LayoutRebase.swift
  TilesSettings.swift
  RecoveryModel.swift

Sources/lineup/App/
  ZoneLayoutSource.swift
  WindowPlacementCenter.swift

Sources/lineup/Tools/Tiles/
  TilesTool.swift
  TilesCoordinator.swift
  AXWindowSystem.swift
  TilesRecoveryJournalStore.swift
  TilesHUD.swift
  TilesSettingsPane.swift

Sources/lineup/Tools/Zones/
  ZonesTool.swift
  WindowMover.swift
  DragSnap.swift

Sources/lineup/Settings/Components/ToolIcon.swift
Sources/lineup/App/AppShell.swift
Sources/lineup/App/Brand.swift
Sources/lineup/App/OnboardingKit.swift

Sources/lineup-tests/
  TilesSuite.swift
  AppSuite.swift
  main.swift

PRODUCT.md
GOAL.md
README.md
docs/research/tiling-spaces-research.md
```

Do not split `AXWindowSystem` into many shallow wrappers. Discovery, observation, mutation, and
verification protect one difficult boundary and should remain cohesive.

## 12. Delivery phases and team ownership

Implementation starts only after Fable agrees with this plan.

### Phase 0: product contract

Root owner:

- Add the new phase to PRODUCT/GOAL without deleting the historical production-readiness goal.
- Record the final terms, non-goals, and acceptance criteria.
- Keep the research decision note aligned with the agreed plan.

Acceptance: no current document still presents automatic tiling as an active product non-goal.

### Phase 1: pure core

Core worker owns `TilesCore`, `TilesSuite.swift`, and required Package/test-runner wiring.

- Add model, invariants, allocator, reducer, rebase, cycle, and settings schema.
- Add deterministic tests before AppKit integration.

Acceptance: all pure state transitions and failure plans are covered; existing tests stay green.

### Phase 2: shell and Settings skeleton

UX worker owns ToolID, registry wiring, Settings pane, icon/tint, menu/HUD skeleton, and related
source-scan tests. It must not edit TilesCore or AX runtime files.

- Register Tiles disabled after Zones.
- Add the new pane with the shared switch and three sections.
- Implement config validation, recorders, conflict rules, and blocked states.

Acceptance: the packaged app shows a native Tiles entry, switch persistence works, and off owns
zero runtime resources. Validate this phase with Computer Use before proceeding.

### Phase 3: window boundary and one workspace

Runtime worker owns `AXWindowSystem`, coordinator, observer lifecycle, and recovery store. It uses
the approved TilesCore interfaces and does not edit Settings views.

- Implement public AX discovery and ephemeral identity.
- Implement adoption, placement, stack raise/focus, event coalescing, and bounded reconciliation.
- Implement journal-before-mutation and conditional restore.
- Start with one visible workspace. Do not add staging until placement is stable.

Acceptance: TextEdit, Finder, Terminal, and Chrome/Electron windows tile and cycle without main
thread stalls. Stop restores eligible original frames.

### Phase 4: workspaces and Zones integration

Root integrates the three owned areas. Runtime and integration workers make focused changes only
in their existing ownership.

- Add four-workspace transition, staging, compensation, and startup recovery.
- Add `ZoneLayoutSource`, changed-section notification, and layout rebase.
- Add `WindowPlacementCenter` and Zones placement results.
- Add multi-monitor topology settling and external-activation behavior.

Acceptance: layout edits reflow active windows; Zone drag moves/stacks; freeform actions detach;
workspace switch and crash injection never strand a window off-screen. A switch with at least ten
managed windows across two displays completes in under two seconds, leaves focus on the correct
window, and passes a UX review of Dock animation noise. If this gate fails, implementation stops
and the staging mechanism is re-decided before Phase 5.

### Phase 5: polish and hardening

Root coordinates fixes; original owners keep file ownership.

- Complete HUD and accessibility announcements.
- Add warnings, retry behavior, recovery action, and documentation.
- Run the full automated and manual matrix.
- Use Computer Use for Settings, menu, toggle, recorder, HUD, and keyboard flows.

Acceptance: all definition-of-done checks pass and the UI matches Lineup's native, precise, calm
design.

## 13. Automated verification

### 13.1 TilesCore

- Exactly four workspaces and one active workspace.
- New placement fills empty tiles, then focused tile, then shortest stack.
- Append/remove/select and forward/reverse cycle with wrap-around.
- One window cannot exist in two stacks.
- Closing selected chooses a deterministic neighbor.
- Move between workspaces preserves uniqueness.
- Activating the active workspace is a no-op.
- Split, merge, and reorder rebase without loss.
- Merge preserves visual order and most recent selection.
- Stale mutation generations cannot commit.
- Failed essential effects leave the prior active workspace.
- Compensation plans are deterministic.
- Settings and journal schema round-trip; future schemas reject safely.

### 13.2 Runtime with fakes

- Initial start stores the original frame before the first effect.
- Observer create plus reconciliation adopts once.
- Unstable new windows settle through bounded retry.
- Journal intent is durable before frame or minimize mutation.
- Workspace switch commits only after verified effects.
- Fault injection at each transition step compensates or leaves recovery data.
- User-minimized windows are never restored by Tiles.
- Stop restores only windows still at the last Tiles frame.
- Late self-generated notifications do not loop.
- Layout source change reflows once.
- Display change during transition cancels and replans.
- `start/stop/start` does not duplicate observers, timers, hotkeys, HUDs, or AX elements.
- Disabled Tiles owns zero resources.

### 13.3 Existing contracts

- `ToolID.all` and registry order are Zones, Tiles, Cycler, Hyperkey.
- Unknown tool sections and unknown keys survive config round-trips.
- Existing legacy import output remains unchanged.
- Shortcut conflicts include disabled tools and generated reverse bindings.
- Tool switch persists before lifecycle changes.
- `stop` unregisters all owned resources.
- Tiles requests Accessibility only.
- Tiles files contain no Space/SkyLight/CGS private API or off-screen staging.
- Settings accessibility labels, metrics, blocked banners, and navigation scans pass.
- References that incorrectly state there are only three tools are updated where semantically
  required, without rewriting unrelated uses of the number three.

Commands:

```sh
swift run lineup-tests
swift build
UNIVERSAL=0 ./Scripts/build-app.sh /tmp/lineup-tiles-build
```

## 14. Manual and Computer Use verification

Use a packaged app, not only `swift run`.

### Settings and lifecycle

- Open Settings from the status item.
- Confirm Tiles appears after Zones and uses the shared header switch.
- Toggle on/off and relaunch; confirm persistence.
- Confirm no window mutation before Accessibility and no extra permission request.
- Record, clear, cancel, conflict, and restore shortcuts with keyboard only.
- Inspect light/dark mode, narrow window, VoiceOver labels, and focus order.

### Window behavior

- TextEdit, Finder, Terminal, Chrome/Electron, and multiple windows from one app.
- Fill leaves, overflow into the focused stack, cycle, close selected, and restore.
- Move and resize manually; drag through Zones; run a freeform Zones quick action.
- Switch and move across all four workspaces.
- Toggle a focused managed window to its safe freeform frame and back with the Tiles Space
  shortcut; verify a detached window is adopted into the active workspace on the second press.
- Measure a switch with at least ten managed windows across two displays. It must complete in under
  two seconds, preserve the correct focus, and have acceptable Dock animation noise. If it fails,
  stop and redesign staging before more polish work.
- Use Dock and Cmd-Tab to activate an inactive-workspace window.
- Minimize and restore manually.
- Enable/disable Tiles with managed windows present.

### Displays and system modes

- Retina and non-Retina, negative origins, Dock positions, and menu bar changes.
- Connect/disconnect a display during idle and during transition.
- Native Spaces, Separate Spaces on/off, Mission Control, Stage Manager, and Full Screen as
  regression scenarios. The product does not promise control of these modes.

### Failure recovery

- Revoke Accessibility while running.
- Close an app during a transition.
- Simulate AX timeout and rejected resize.
- Terminate Lineup after journal intent and before minimize confirmation.
- Relaunch and verify conservative recovery.
- Confirm every failed case leaves windows reachable through the Dock.

Capture fresh Computer Use state before every interaction. Use screenshots to compare hierarchy,
spacing, states, and HUD placement. Do not use image inspection as a substitute for keyboard and
runtime checks.

## 15. Definition of done

- Tiles is a separate fourth tool named Tiles and is disabled by default.
- Settings has a dedicated Tiles entry with one global switch and no nested settings tabs.
- Tiles always derives tile geometry from current Zones layouts.
- New eligible windows are automatically placed by the agreed policy.
- Four global workspaces switch safely without native Space APIs.
- Every tile supports an ordered window stack and integrated cycling.
- Zones drag/direct placement can move and stack managed windows.
- Existing freeform Zones actions remain useful through session detachment.
- The Tiles Space shortcut toggles a focused window between its verified adoption frame and the
  active workspace tile.
- Config has one binary spacing choice and optional action shortcuts; workspace, placement, and
  stack policies are fixed.
- All mutations are planned, bounded, verified, and recoverable.
- Normal stop restores Tiles-owned minimize state and conditionally restores frames.
- No Tiles operation writes an off-screen frame or uses a private Space API.
- Existing Zones, Cycler, Hyperkey, config, import, onboarding, and menu behavior regressions are
  covered.
- Automated suites, release build, manual matrix, and Computer Use acceptance pass.
- Fable agrees with this plan before implementation.
- Grok and Claude Opus review the completed work in persistent pairs; accepted fixes are applied
  and revalidated.

## 16. Non-goals for v1

- Native macOS Space creation, deletion, switching, or window transfer.
- Independent active workspace per display.
- Configurable workspace count or names.
- Persistent workspace membership across Lineup or application restarts.
- Rules or exclusions by application.
- New master/dwindle/BSP layouts, custom or separate inner/outer gaps, borders, or animations.
- A second layout editor in Tiles.
- User-configurable stack policies.
- Managing sheets, dialogs, utility panels, Full Screen, or Stage Manager groups.
- CLI, IPC, scripting, or Hyprland-style configuration language.
- Replacing the existing app-centric Cycler tool.
- Refactoring Cycler's existing CGWindowID identity unless required by an implementation blocker.

## 17. Questions for Fable

Fable must challenge these exact choices before agreement:

1. Is `Tiles` the clearest tool name, with `Workspace` as the internal user term?
2. Are four global workspaces better than independent workspaces per display for this product?
3. Is minimizing only inactive workspaces, while overlapping active stack members, the best public
   API behavior?
4. Should first activation materialize the adaptive shortcut preset, or leave every row unassigned?
5. Is the recovery journal proportional to the risk, and is conservative title-digest matching
   sufficient?
6. Is automatic session detachment the right way to preserve freeform Zones actions?
7. Is the shell-owned `ZoneLayoutSource` plus placement event center the narrowest clean
   integration seam?
8. Should the existing private CGWindowID bridge in Cycler remain out of scope?

Agreement requires an explicit `AGREE` after all blocking issues are resolved.

## 18. Peer agreement

Fable reviewed this plan in session `ea4d052a-4c3f-4ec1-98af-91a6501eb5ad`.

First verdict: `CHANGES REQUIRED`. The plan was updated with a current-native-Space reachability
rule, a ten-window/two-display/two-second staging gate, explicit Cycler external activation, and
destination-first deminimize ordering. The identity and floating-discoverability improvements were
also applied.

Final verdict on 2026-08-30: `AGREE`. Blocking issues: none.

## 19. Essential keyboard controls extension

The follow-up research is in `docs/research/hyprland-essential-controls-research.md`. The inspected
Hyprland sample showed directional focus in 5/5 configurations, split orientation in 4/5,
directional move in at least 3/5, and explicit gap values in 4/6. Lineup implements the smallest
set that fits its Zones-owned layout model:

1. Focus the nearest available tile to the left, right, up, or down. Navigation is limited to the
   current display and does not wrap.
2. Move the focused window to the nearest tile in a direction. An occupied destination appends the
   window to its existing stack.
3. Switch the closest parent split between side by side and stacked. Zones performs and persists
   the tree edit; Tiles does not own a second geometry model.
4. Use one fixed 8 pt internal spacing switch. Off reproduces the exact Zones frames. Screen edges
   keep no outer gap.

The actions are available from the Tiles menu and shortcut rows. On first activation, the rows use
an adaptive preset that avoids Zones' Hyper plus arrow keys: the no-Shift Hyperkey mode uses
Control-Option-Command (`6400`) for numbered workspace selection, focus, and stack/split/toggle
actions; its physical Shift-number counterparts move the focused window, while full Hyper (`6912`)
plus H/J/K/L moves it spatially. The full-Shift mode uses full Hyper for focus, movement fallback
U/I/O/P, and stack/split/toggle; numbered workspace rows still select workspaces but have no
generated Shift move because that counterpart cannot be distinguished. Stored rows are preserved
when Hyperkey mode changes, and
reset uses the mode active at reset time. Shift reverse remains limited to the three cyclic actions
and is generated only for bindings that do not already include Shift.

Swap, divider nudging, cross-display navigation, and custom gap values remain deferred. Swap had
weak binding evidence in the inspected sample; divider nudging would extend the Zones editing
contract.

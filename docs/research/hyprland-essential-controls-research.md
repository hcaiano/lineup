# Research: essential Hyprland controls for Lineup Tiles

Date: 2026-08-30
Scope: controls and interaction patterns for the next Tiles phase
Status: research complete; implementation scope selected

## Decision in one paragraph

The next phase should make Tiles spatially operable from the keyboard while keeping Zones as
the source of geometry. The minimum useful set is: focus a neighbouring tile, move the focused
window to a neighbouring or explicitly selected tile, swap with a neighbouring tile, select one
of the four Lineup workspaces directly, toggle the focused split's orientation, and choose one
simple tile-spacing value. Keep stacks automatic when a destination is occupied. Do not add a
second automatic layout engine, native macOS Spaces, or a large Hyprland-style configuration
surface.

This is a product recommendation. Hyprland supplies the interaction vocabulary; it does not
define Lineup's template ownership, four-workspace model, or Accessibility limits.

The selected implementation slice is smaller than the full recommendation below. It includes
directional focus, directional move with automatic stacking, closest-parent orientation toggle,
and one fixed 8 pt spacing switch. Swap, divider nudging, direct numbered workspace shortcut rows,
and custom gap values are deferred to keep Zones as the only geometry owner and keep Settings
compact.

## Method and evidence rules

I checked current official Hyprland documentation, its public default configuration and source
tests, Apple public APIs, AeroSpace's macOS compatibility notes, and five public Hyprland
configurations. The public configurations are a convenience sample, not a prevalence study.
For the comparable frequency table, I used the official default plus four of those public files;
the A7R7 file is included as supplemental evidence for gaps and groups.

Each item below labels the type of evidence:

- **Fact** means that the linked project documents or implements the behavior.
- **Observed frequency** means that the behavior was present in the small sample inspected on
  2026-08-30. It is not a claim about all Hyprland users.
- **Inference** means a Lineup decision derived from the evidence and the current product model.

## What Lineup already has

Tiles is already a separate, opt-in tool. It owns four virtual workspaces and a stack of windows
per Zones leaf; the current shell exposes next-workspace, next-window-in-tile, and move-window-to-
next-workspace actions. See [`TilesTool.swift`](../../Sources/lineup/Tools/Tiles/TilesTool.swift),
[`TilesModel.swift`](../../Sources/TilesCore/TilesModel.swift), and the existing
[implementation plan](../tiles-implementation-plan.md).

Zones owns the template tree and its leaf geometry. Its current model distinguishes vertical
columns from horizontal rows and already has split/merge/divider editing. See
[`ZoneTree.swift`](../../Sources/ZonesCore/ZoneTree.swift) and
[`LayoutEdit.swift`](../../Sources/ZonesCore/LayoutEdit.swift).

The existing default Zones shortcuts use Hyper plus the arrow keys, `[`/`]`, and Delete. The
Tiles phase must not silently claim those combinations. On first activation, Tiles uses an
adaptive preset: no-Shift Hyperkey mode uses Control-Option-Command (`6400`) for focus/cyclic
actions and full Hyper (`6912`) for movement; full-Shift mode uses full Hyper throughout. See
[`ShortcutKit.swift`](../../Sources/lineup/App/ShortcutKit.swift).

## Evidence matrix

| Capability | Direct evidence | Observed frequency | Lineup decision |
| --- | --- | --- | --- |
| Focus a tile by direction | Hyprland's default binds map Super+arrow to `movefocus`; the dispatcher defines directional focus. [Default config](https://raw.githubusercontent.com/hyprwm/Hyprland/main/example/hyprland.lua) · [dispatchers](https://wiki.hypr.land/configuring/core/dispatchers/) | 5/5 inspected configs: official default, JeztC, gptlang, YodaEmbedding, JaKooLit | **P0.** Add left/right/up/down spatial focus. Use Zones leaf rectangles and no wrap at an edge. |
| Move a window by direction | Hyprland defines `move({ direction })`, including group-aware movement. [Dispatcher docs](https://wiki.hypr.land/configuring/core/dispatchers/) | At least 3/5 files in the comparable sample bind directional window movement; the exact key names vary | **P0.** Add move-left/right/up/down. A full destination tile keeps the moved window in that tile's stack. |
| Swap a window by direction | Hyprland defines `swap({ direction })`, plus target/next/previous variants. [Dispatcher docs](https://wiki.hypr.land/configuring/core/dispatchers/) | The exact `swapwindow` binding appeared in one inspected config; absence in the others is not evidence that users do not need it | **P0.** Add swap-left/right/up/down as an explicit, reversible operation. |
| Direct workspace selection | The official default binds Super+1…0 to workspace selection. [Default config](https://raw.githubusercontent.com/hyprwm/Hyprland/main/example/hyprland.lua) | 5/5 configs bind direct numbered workspace selection | **P0.** Add direct selection for Lineup workspaces 1…4, with conflict detection. |
| Move a window to a workspace | The official default binds Shift+Super+number to `movetoworkspace`; the dispatcher also supports `move({ workspace, follow? })`. [Default config](https://raw.githubusercontent.com/hyprwm/Hyprland/main/example/hyprland.lua) · [dispatchers](https://wiki.hypr.land/configuring/core/dispatchers/) | 5/5 configs expose a move-to-workspace family (direct or silent variants) | **P1.** Keep the existing next/previous actions and add a menu destination for workspace 1…4. Add direct bindings only when the recorder confirms no conflict. |
| Cycle workspace | Hyprland's default uses mouse-wheel workspace cycling; the dispatcher documents `workspace`, `previous`, and relative selection. [Default config](https://raw.githubusercontent.com/hyprwm/Hyprland/main/example/hyprland.lua) · [dispatchers](https://wiki.hypr.land/configuring/core/dispatchers/) | 5/5 configs provide previous, cycle, scroll, or equivalent | **Already covered / P0 check.** Keep next/previous in Tiles and expose both directions in the same shortcut row. |
| Toggle split orientation | Dwindle documents `togglesplit`; it changes the focused split when `preserve_split` is enabled. [Dwindle layout](https://wiki.hypr.land/0.56.0/Configuring/Layouts/Dwindle-Layout/) · [default config](https://raw.githubusercontent.com/hyprwm/Hyprland/main/example/hyprland.lua) | 4/5 inspected configs bind `togglesplit` or an equivalent orientation action | **P1.** Toggle the nearest parent split from vertical to horizontal and back, preserving boundaries and child order. |
| Rotate a split tree | Dwindle documents `rotatesplit`, which rotates split orientation in 90-degree steps. [Dwindle layout](https://wiki.hypr.land/0.56.0/Configuring/Layouts/Dwindle-Layout/) | Not counted as a common public binding in the sample | **P2.** Consider only after a simple toggle is reliable; a four-way rotation is harder to explain in a fixed template editor. |
| Change a divider / split ratio | Dwindle exposes `splitratio`; the default also enables a split-preserving behavior. [Dwindle layout](https://wiki.hypr.land/0.56.0/Configuring/Layouts/Dwindle-Layout/) | Public configs commonly bind resize actions; `resizeactive` appeared in at least 4/5 | **P1.** Add small grow/shrink divider nudges around the focused leaf. Keep the visual Zones divider editor as the canonical precise control. |
| Resize the active window | Hyprland documents `resizeactive`; it is used in several public binding sets. [Dispatcher docs](https://wiki.hypr.land/configuring/core/dispatchers/) · [gptlang config](https://raw.githubusercontent.com/gptlang/configs/main/hypr/hyprland.conf) · [YodaEmbedding config](https://raw.githubusercontent.com/YodaEmbedding/dotfiles/master/hypr/.config/hypr/hyprland.d/bindings.conf) | At least 4/5 inspected public configs expose resize bindings | **Defer as a separate action.** In Tiles, arbitrary window resize would fight the Zones template. Use divider nudge instead. |
| Stack/group cycle | Hyprland groups are tabbed containers occupying one window area; the dispatcher defines group `next`, `prev`, `active`, and `move_window`. [Groups dispatcher](https://wiki.hypr.land/configuring/core/dispatchers/) | Group toggle/cycle was explicit in 2/6 inspected files (official plus five public files); stack cycling is already in Tiles | **P0 check / P1.** Keep one automatic stack per occupied tile, make next/previous symmetric, and add move-earlier/later only if real workflows need it. |
| Move into or create a group | Hyprland exposes `move({ into_group })` and `move({ into_or_create_group })`. [Dispatcher docs](https://wiki.hypr.land/configuring/core/dispatchers/) | Not frequent enough to use as a default in the sample | **Already represented by Tiles placement.** Placement into an occupied leaf appends to that TileStack; do not expose a second group mode. |
| Inner and outer gaps | Hyprland exposes separate `gaps_in` and `gaps_out`; the default is 5 and 20. [Config options](https://wiki.hypr.land/configuring/core/config-options/) · [default config](https://raw.githubusercontent.com/hyprwm/Hyprland/main/example/hyprland.lua) | Explicit gap values appeared in 4/6 inspected files when the supplemental A7R7 file is included; one public file was binding-only, so this is not a prevalence measure. [A7R7 config](https://raw.githubusercontent.com/A7R7/hypr-config/main/hypr/hyprland.conf) | **P0.** Add one `Tile spacing` setting, default 8 pt, with `None` (0) as the explicit no-gap choice. Do not expose separate inner/outer values. |
| Workspace-specific gaps | Hyprland workspace rules can override both gap classes per workspace. [Workspace rules](https://wiki.hypr.land/configuring/core/workspace-rules/) | Not counted in the public sample | **Defer.** A single global Tiles spacing value is easier to understand and enough for this phase. |
| Preselect the next split | Dwindle documents `preselect`, a one-time direction hint for the next new window. [Dwindle layout](https://wiki.hypr.land/0.56.0/Configuring/Layouts/Dwindle-Layout/) | Not observed as a common binding | **Defer.** Tiles adopts windows into existing template leaves; there is no need to invent a dynamic insertion mode yet. |
| Floating / pseudo / fullscreen toggles | The official default binds floating, pseudo, and fullscreen-related actions. [Default config](https://raw.githubusercontent.com/hyprwm/Hyprland/main/example/hyprland.lua) | Common in configs, but they change window semantics rather than tile navigation | **Defer.** Keep existing Zones quick actions and native macOS behavior. Full Screen can create a native Space and must not be silently mixed with Tiles workspaces. |
| Mouse move/resize | Hyprland's default binds mouse movement and resize with a modifier. [Default config](https://raw.githubusercontent.com/hyprwm/Hyprland/main/example/hyprland.lua) | 5/5 inspected configs expose mouse move/resize | **Defer as a compositor feature.** Continue to support Lineup's existing drag/snap path; do not add a global event tap just for Tiles. |
| Focus follows mouse / activate policy | Hyprland documents `follow_mouse`, `focus_on_activate`, and `no_focus_fallback`. [Config options](https://wiki.hypr.land/configuring/core/config-options/) | Not a reliable binding-frequency signal | **Defer.** Accessibility focus, user activation, and reconciliation need explicit macOS policy first. |
| Gestures for workspaces | Hyprland documents three-finger horizontal workspace gestures. [Gestures](https://wiki.hypr.land/Configuring/Advanced-and-Cool/Gestures/) | No public config count taken | **Defer.** Let macOS own trackpad gestures; Tiles should not intercept them in this phase. |
| Named/special workspaces | Hyprland has special workspace dispatchers and default bindings. [Dispatcher docs](https://wiki.hypr.land/configuring/core/dispatchers/) · [default config](https://raw.githubusercontent.com/hyprwm/Hyprland/main/example/hyprland.lua) | Present in several public configs | **Defer.** Tiles' four workspaces are stable, app-independent model state; a scratchpad needs a separate persistence and UX design. |

## Frequency snapshot

The table below counts only whether a capability was visible in the official default plus four
public configs. The sources are direct files: [JeztC](https://raw.githubusercontent.com/JeztC/hyprland-config/master/hyprland.conf),
[gptlang](https://raw.githubusercontent.com/gptlang/configs/main/hypr/hyprland.conf),
[YodaEmbedding](https://raw.githubusercontent.com/YodaEmbedding/dotfiles/master/hypr/.config/hypr/hyprland.d/bindings.conf),
and [JaKooLit](https://raw.githubusercontent.com/JaKooLit/Hyprland-v3/main/config/hypr/configs/Keybinds.conf),
plus the [official default](https://raw.githubusercontent.com/hyprwm/Hyprland/main/example/hyprland.lua).

| Observed capability | Configs with an explicit action | Interpretation |
| --- | ---: | --- |
| Directional focus | 5/5 | Strong evidence for the primary navigation loop. |
| Direct workspace selection | 5/5 | Strong evidence for direct access, not only cycling. |
| Move to workspace | 5/5 | Strong evidence that moving the active window is separate from changing focus. |
| Workspace cycle / previous | 5/5 | Useful complement to direct selection. |
| Mouse move/resize | 5/5 | Common in Hyprland, but not a reason to add a macOS global hook to Tiles. |
| Orientation toggle | 4/5 | Good candidate for a fixed, simple action. |
| Explicit resize action | at least 4/5 | Translate to divider nudge because Zones owns geometry. |
| Directional move | at least 3/5 | Important enough for P0, even with naming differences. |
| Explicit group toggle/cycle | 2/6 inspected files | Stacks are a product primitive already, so the Lineup UX should be simpler than Hyprland groups. |
| Explicit gap values | 4/6 inspected files (supplemental A7R7 included) | Gap values are common, but their amount is a personal preference and one inspected file split general options from bindings. |

The sample is intentionally small. A 5/5 result means “present in this inspected sample”, not
“used by 100% of users”. A missing binding does not prove that the underlying operation is
unimportant.

## Recommended implementation scope

### P0: spatial navigation and placement

1. **Focus tile left/right/up/down.** Select the nearest candidate whose center is in the
   requested direction. Prefer candidates with a positive directional projection, then the
   smallest perpendicular distance. Do not wrap at an edge. If there is no candidate, keep focus
   unchanged and show `No tile in that direction`.

2. **Move focused window to a neighbouring tile.** Use the same candidate resolver as focus. When
   the destination already has windows, append to its existing `TileStack`, matching the current
   drag/drop meaning of “put this window in that tile”. Moving to the current tile is a no-op.
   This occupied-tile behavior is an inference for Lineup, not a claim that Hyprland has the same
   stack policy.

3. **Move focused window to an explicit tile.** Reuse the existing Zones positional Zone-N
   vocabulary. The runtime must receive an explicit placement event from the Zones seam; it must
   not infer a target from a delayed Accessibility frame callback. The menu can generate
   `Move Focused Window to Tile > Zone N` from the active layout, instead of adding one permanent
   settings row for every possible leaf.

4. **Swap with a neighbouring tile.** Exchange tile membership with the selected occupant of the
   nearest tile. If either side is stacked, preserve stable stack order and selection indices.
   Keep swap separate from move so a user can choose between “add here” and “exchange”.

5. **Direct workspace 1…4.** Keep four stable Lineup workspaces. Switching changes which model
   workspace is visible; it does not create, delete, reorder, or move native macOS Spaces. Add a
   destination menu for moving a window to a selected workspace. Keep next and previous as
   symmetric actions.

### P1: template editing from the keyboard

6. **Toggle the focused parent split orientation.** A vertical split is the Zones convention for
   left-to-right columns and a horizontal split is the convention for top-to-bottom rows. Toggle
   only the closest parent split. Preserve child order and relative boundaries. For a root split
   that stores pixel boundaries, convert boundaries to fractions before changing axis, because the
   current Zones validation permits absolute units only on the root vertical split. If the focused
   leaf has no split parent, report a no-op in the HUD.

7. **Nudge the focused divider.** Offer `Grow tile` and `Shrink tile` with a fixed step (for
   example, 4% or 32 pt), clamped by the same minimum sizes as the Zones editor. A held shortcut
   may repeat. The operation must edit the Zones layout, then reflow Tiles; it must not store a
   competing per-window size.

8. **Tile spacing.** Persist one setting with a small opinionated default (8 pt) and an explicit
   `None` value (0 pt). Apply the gap only between adjacent leaves; keep the outer screen edges
   unchanged. A stack uses one frame, so its members do not get internal spacing. Setting `None`
   must reproduce the existing gapless Zones rectangles exactly. Do not expose separate Hyprland
   `gaps_in` and `gaps_out`, per-workspace overrides, or smart-gap switches.

### Settings and shortcut UX

Keep the new Tiles tab concise, with three sections: `Navigation`, `Window movement`, and
`Layout`. Show the fixed workspace actions, focus/move/swap direction actions, orientation toggle,
divider nudge, and one spacing picker. Generate explicit Zone-N destinations from the active
template rather than presenting an unbounded configuration list.

The existing Hyper+arrow bindings belong to Zones, so Tiles must not claim them. On first
activation, no-Shift Hyperkey mode maps focus left/down/up/right to 6400+H/J/K/semicolon,
movement to 6912+H/J/K/semicolon, and the cyclic/split rows to 6400+Tab/grave/Space/Return.
Full-Shift mode maps focus to 6912+H/J/K/semicolon, movement to 6912+U/I/O/P, and the
cyclic/split rows to 6912+Tab/grave/Space/Return. Existing rows, including explicit nulls, remain
untouched when Hyperkey changes. Every failed registration must be shown as a specific conflict;
it must not silently replace another tool's binding.

Use one shortcut for an action family and generate its reverse with Shift where the existing
shortcut system supports that convention. Show confirmed feedback only after the runtime commits:
`Focus: Zone 2`, `Moved to Zone 3`, `Swapped with Zone 2`, `Orientation: horizontal`, or
`Spacing: none`. Never show a success HUD for an Accessibility timeout or a stale window.

The settings model must preserve existing rows. A missing Tiles settings section gets the adaptive
preset only when Tiles is first activated or edited; a missing field in an existing section remains
unassigned. An invalid field is rejected or repaired explicitly. Disabling Tiles must unregister
every shortcut and stop all runtime work exactly like the other tools.

## macOS constraints that change the design

Apple exposes Accessibility element attributes for position and size, but the operation is a
request to the target application and can fail or time out; it also requires the user's
Accessibility trust. See [AXUIElementSetAttributeValue](https://developer.apple.com/documentation/applicationservices/1460434-axuielementsetattributevalue),
[kAXPositionAttribute](https://developer.apple.com/documentation/applicationservices/kaxpositionattribute),
[kAXSizeAttribute](https://developer.apple.com/documentation/applicationservices/kaxsizeattribute),
and [AXIsProcessTrustedWithOptions](https://developer.apple.com/documentation/applicationservices/1459186-axisprocesstrustedwithoptions).

Core Graphics can enumerate window metadata, but its public window-list API is an inspection API,
not a replacement for Accessibility window mutation. See
[CGWindowListCopyWindowInfo](https://developer.apple.com/documentation/coregraphics/cgwindowlistcopywindowinfo%28_%3A_%3A%29).
The runtime therefore needs the existing serial AX worker, timeout handling, reconciliation, and
explicit placement events.

Screen frames and visible frames are dynamic. See [NSScreen.screens](https://developer.apple.com/documentation/appkit/nsscreen/screens)
and [NSScreen.visibleFrame](https://developer.apple.com/documentation/appkit/nsscreen/visibleframe).
Reflow must use the current Zones snapshot and must not persist a screen frame as tile identity.

macOS `NSWindow.CollectionBehavior` describes behavior of a Lineup-owned window; it does not
provide a public lifecycle for creating, deleting, or reordering Spaces. See
[NSWindow.CollectionBehavior](https://developer.apple.com/documentation/appkit/nswindow/collectionbehavior-swift.struct).
A macOS tiling tool's own virtual workspace model is therefore a deliberate compatibility choice;
AeroSpace documents the same native-Space limitation and its emulation approach in
[Emulation of virtual workspaces](https://nikitabobko.github.io/AeroSpace/guide#emulation-of-virtual-workspaces).

Accessibility notifications can report activation and other changes, but they are asynchronous;
the public observer API is [AXObserverCreate](https://developer.apple.com/documentation/applicationservices/1460133-axobservercreate)
plus [AXObserverAddNotification](https://developer.apple.com/documentation/applicationservices/1462089-axobserveraddnotification).
This supports a reducer/reconciliation model, not optimistic shortcut feedback.

## Explicitly defer

- A Dwindle or Master automatic layout mode, or a user-facing layout-mode switch. Zones templates
  already own the geometry.
- `preselect`, `smart_split`, `force_split`, split bias, and arbitrary dynamic insertion rules.
- Native Space creation, deletion, naming, scratchpads, or special workspaces.
- App/class/monitor workspace rules and persistent app placement. These require stable identity and
  a separate configuration model.
- Focus-follows-mouse, global mouse/trackpad gestures, and a compositor-wide event tap.
- Fullscreen, floating, and pseudo-tile policy changes beyond the existing Zones actions.
- Master-only controls such as `mfact`, promote-to-master, roll, and center orientation.
- Group locking, group bars, auto-group policy, and stack styling. Tiles stacks are already the
  simpler fixed-leaf grouping primitive.
- Animated compositor transitions and Hyprland border styling.
- Cross-monitor workspace relocation or swap until multi-display behavior has real QA coverage.

## Acceptance and test plan

### Pure Tiles/Zones tests

- Directional focus selects a deterministic nearest leaf, never wraps, and is a no-op at an edge.
- Focus, move, and swap work with one window, empty tiles, and stacked tiles.
- Moving into an occupied tile appends in stable order; swapping preserves stack order and selected
  members; moving to the current tile is idempotent.
- Explicit Zone-N placement and directional placement use the same reducer seam.
- Orientation toggling works for nested and root splits, preserves boundaries and order, converts
  root pixel boundaries safely, rejects a leaf with no parent, and leaves every tree valid.
- Divider nudges clamp at minimum sizes and produce deterministic repeated results.
- Spacing `0` reproduces the existing rectangles; spacing `8` creates the expected shared gaps,
  never changes outer edges, and gives every stack member the same tile frame.
- Workspace selection/move, settings migration, and shortcut conflict detection are covered.

### Runtime and UI tests

- No Accessibility grant, AX timeout, closed window, external activation, minimize/restore, manual
  drag, screen change, and fullscreen transition all reconcile without stale model state.
- Zones quick actions, drag placement, template edits, and Tiles keyboard placement converge to
  one layout and one stack model.
- Start/stop unregisters all new hotkeys and leaves the tool disabled with no runtime resource.
- Test a real macOS app visually for focus, move, swap, orientation, spacing, stack cycle, and
  workspace switching. If Computer Use is unavailable, mark the visual test `NOT-TESTED`; do not
  convert a pure reducer pass into UI acceptance.
- Test at least one resized display and one multi-display setup before claiming cross-monitor
  support. Until then, keep cross-monitor operations deferred.

## Source register

Primary Hyprland sources: [default config](https://raw.githubusercontent.com/hyprwm/Hyprland/main/example/hyprland.lua),
[default config embedding](https://raw.githubusercontent.com/hyprwm/Hyprland/main/src/config/lua/DefaultConfig.hpp),
[dispatchers](https://wiki.hypr.land/configuring/core/dispatchers/),
[binds](https://wiki.hypr.land/configuring/core/binds/),
[config options](https://wiki.hypr.land/configuring/core/config-options/),
[workspace rules](https://wiki.hypr.land/configuring/core/rules/workspace-rules/),
[Dwindle layout](https://wiki.hypr.land/0.56.0/Configuring/Layouts/Dwindle-Layout/),
[Master layout](https://wiki.hypr.land/Configuring/Layouts/Master-Layout/),
[groups source](https://github.com/hyprwm/Hyprland/blob/main/src/desktop/view/Group.cpp),
[Dwindle source](https://github.com/hyprwm/Hyprland/blob/main/src/layout/algorithm/tiled/dwindle/DwindleAlgorithm.cpp),
[Master source](https://github.com/hyprwm/Hyprland/blob/main/src/layout/algorithm/tiled/master/MasterAlgorithm.cpp),
and [Hyprtester layout tests](https://github.com/hyprwm/Hyprland/tree/main/hyprtester/src/tests/main).

Public configuration evidence: [JeztC](https://raw.githubusercontent.com/JeztC/hyprland-config/master/hyprland.conf),
[gptlang](https://raw.githubusercontent.com/gptlang/configs/main/hypr/hyprland.conf),
[YodaEmbedding](https://raw.githubusercontent.com/YodaEmbedding/dotfiles/master/hypr/.config/hypr/hyprland.d/bindings.conf),
[JaKooLit](https://raw.githubusercontent.com/JaKooLit/Hyprland-v3/main/config/hypr/configs/Keybinds.conf),
and [A7R7](https://raw.githubusercontent.com/A7R7/hypr-config/main/hypr/hyprland.conf).

macOS and compatibility sources: [AXUIElementSetAttributeValue](https://developer.apple.com/documentation/applicationservices/1460434-axuielementsetattributevalue),
[AXIsProcessTrustedWithOptions](https://developer.apple.com/documentation/applicationservices/1459186-axisprocesstrustedwithoptions),
[AX position](https://developer.apple.com/documentation/applicationservices/kaxpositionattribute),
[AX size](https://developer.apple.com/documentation/applicationservices/kaxsizeattribute),
[CG window info](https://developer.apple.com/documentation/coregraphics/cgwindowlistcopywindowinfo%28_%3A_%3A%29),
[NSScreen](https://developer.apple.com/documentation/appkit/nsscreen/screens),
[visibleFrame](https://developer.apple.com/documentation/appkit/nsscreen/visibleframe),
[collection behavior](https://developer.apple.com/documentation/appkit/nswindow/collectionbehavior-swift.struct),
[AX observer](https://developer.apple.com/documentation/applicationservices/1460133-axobservercreate),
[AX observer notifications](https://developer.apple.com/documentation/applicationservices/1462089-axobserveraddnotification),
and [AeroSpace virtual-workspace emulation](https://nikitabobko.github.io/AeroSpace/guide#emulation-of-virtual-workspaces).

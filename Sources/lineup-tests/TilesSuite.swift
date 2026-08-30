import CoreGraphics
import Foundation
import TilesCore
import ZonesCore

/// Deterministic, dependency-free checks for the pure Tiles state machine.
/// Accessibility and AppKit behavior belong to the shell tests; this suite
/// verifies decisions before any external effect is executed.
func runTilesTests() throws {
    func token(_ n: Int) -> WindowToken {
        let suffix = String(format: "%012d", n)
        return WindowToken(rawValue: UUID(uuidString: "00000000-0000-0000-0000-" + suffix)!)
    }

    func leaf(_ screen: String, _ index: Int, _ rect: CGRect) -> NormalizedLeaf {
        NormalizedLeaf(screenKey: screen, index: index, rect: rect)
    }

    func layout(_ screen: String = "main", count: Int = 3) -> LayoutSnapshot {
        let width = 1.0 / CGFloat(count)
        let leaves = (0..<count).map { index in
            leaf(screen, index, CGRect(x: CGFloat(index) * width, y: 0,
                                       width: width, height: 1))
        }
        return LayoutSnapshot(screens: [screen: leaves],
                              frames: [screen: (0..<count).map {
                                  CGRect(x: CGFloat($0) * 100, y: 0, width: 100, height: 100)
                              }],
                              primaryScreenKey: screen)
    }

    func entry(_ token: WindowToken, x: CGFloat, screen: String = "main",
               minimized: Bool = false, eligible: Bool = true,
               reachable: Bool = true) -> WindowSnapshotEntry {
        WindowSnapshotEntry(token: token,
                            frame: CGRect(x: x, y: 0, width: 80, height: 80),
                            screenKey: screen,
                            isVisible: !minimized,
                            isMinimized: minimized,
                            isEligible: eligible,
                            isReachable: reachable)
    }

    func successful(_ plan: TilesPlan) -> [WindowEffectResult] {
        plan.effects.map(WindowEffectResult.success)
    }

    // ---- fixed workspace model and stack invariants ----
    do {
        let state = TilesSession.empty
        check(state.workspaces.count == 4, "tiles: exactly four workspaces at start")
        check(state.activeWorkspace == .workspace1, "tiles: workspace 1 active at start")
        check(state.isValid, "tiles: empty session satisfies invariants")

        let a = token(1), b = token(2)
        let address = TileAddress(screenKey: "main", leafIndex: 0,
                                  normalizedCenter: CGPoint(x: 0.5, y: 0.5))
        var stack = TileStack(address: address)
        check(stack.append(a), "stack: first append succeeds")
        check(!stack.append(a), "stack: duplicate append is rejected")
        check(stack.append(b), "stack: second append succeeds")
        check(stack.selected == a, "stack: first member selected by default")
        _ = stack.select(b)
        _ = stack.remove(b)
        check(stack.selected == a, "stack: closing selected chooses nearest remaining member")
        _ = stack.remove(a)
        check(stack.order.isEmpty && stack.selected == nil, "stack: empty stack clears selection")

        var incomplete = TilesSession.empty
        incomplete.workspaces[.workspace4] = nil
        let repairPlan = TilesReducer.plan(
            state: incomplete,
            event: .switchWorkspace(.workspace4),
            snapshot: WindowSnapshot(),
            layouts: layout())
        let repaired = TilesReducer.commit(
            state: incomplete,
            plan: repairPlan,
            results: successful(repairPlan))
        check(repaired.activeWorkspace == .workspace4 && repaired.isValid,
              "tiles: planning repairs a missing workspace before switching")
    }

    // ---- allocator and cycle ----
    do {
        let stacks = (0..<3).map { index in
            TileStack(address: TileAddress(screenKey: "main", leafIndex: index,
                                           normalizedCenter: CGPoint(x: CGFloat(index) / 3 + 0.1, y: 0.5)))
        }
        check(TileAllocator.destinationIndex(stacks: stacks, focusedTile: nil)
                .map { stacks[$0].address.leafIndex } == 0,
              "allocator: first empty tile wins")

        let filled = stacks.map { TileStack(address: $0.address, order: [token($0.address.leafIndex + 1)]) }
        check(TileAllocator.destinationIndex(stacks: filled, focusedTile: filled[2].address)
                .map { filled[$0].address.leafIndex } == 2,
              "allocator: focused tile wins after all tiles are occupied")
        let uneven = [
            TileStack(address: stacks[0].address, order: [token(1), token(2)]),
            TileStack(address: stacks[1].address, order: [token(3)]),
            TileStack(address: stacks[2].address, order: [token(4)])
        ]
        check(TileAllocator.destinationIndex(stacks: uneven, focusedTile: nil)
                .map { uneven[$0].address.leafIndex } == 1,
              "allocator: shortest stack wins with visual tie-breaker")

        let cycleStack = TileStack(address: stacks[0].address,
                                   order: [token(1), token(2), token(3)], selected: token(1))
        check(TileCycle.next(in: cycleStack, direction: .forward) == token(2),
              "cycle: forward advances")
        check(TileCycle.next(in: cycleStack, direction: .reverse) == token(3),
              "cycle: reverse wraps")
        check(TileCycle.next(in: cycleStack, direction: .forward,
                             eligible: [token(1), token(3)]) == token(3),
              "cycle: manually unavailable members are skipped")
        check(TileCycle.next(order: [token(1)], selected: token(1), direction: .forward) == nil,
              "cycle: one eligible member is a no-op")
    }

    // ---- rebase: split, merge, no loss, and recent selection ----
    do {
        let a = token(10), b = token(11)
        let oldAddress = TileAddress(screenKey: "main", leafIndex: 0,
                                     normalizedCenter: CGPoint(x: 0.25, y: 0.5))
        let old = [TileStack(address: oldAddress, order: [a], selected: a, selectionEpoch: 1)]
        let split = [leaf("main", 0, CGRect(x: 0, y: 0, width: 0.5, height: 1)),
                     leaf("main", 1, CGRect(x: 0.5, y: 0, width: 0.5, height: 1))]
        let splitResult = LayoutRebase.rebase(
            stacks: old,
            from: [leaf("main", 0, CGRect(x: 0, y: 0, width: 1, height: 1))],
            to: split)
        check(splitResult.count == 2 && splitResult[0].order == [a] && splitResult[1].order.isEmpty,
              "rebase: split keeps stack in center child and creates empty sibling")

        let mergeOld = [
            TileStack(address: TileAddress(screenKey: "main", leafIndex: 0,
                                           normalizedCenter: CGPoint(x: 0.25, y: 0.5)),
                      order: [a], selected: a, selectionEpoch: 1),
            TileStack(address: TileAddress(screenKey: "main", leafIndex: 1,
                                           normalizedCenter: CGPoint(x: 0.75, y: 0.5)),
                      order: [b], selected: b, selectionEpoch: 2)
        ]
        let merged = LayoutRebase.rebase(
            stacks: mergeOld,
            from: split,
            to: [leaf("main", 0, CGRect(x: 0, y: 0, width: 1, height: 1))])
        check(merged.count == 1 && merged[0].order == [a, b],
              "rebase: merge concatenates old visual order")
        check(merged[0].selected == b, "rebase: merge keeps most recently focused member")

        let rotationOld = [
            leaf("main", 0, CGRect(x: 0, y: 0, width: 0.5, height: 1)),
            leaf("main", 1, CGRect(x: 0.5, y: 0, width: 0.5, height: 1))
        ]
        let rotationNew = [
            leaf("main", 0, CGRect(x: 0, y: 0.25, width: 1, height: 0.75)),
            leaf("main", 1, CGRect(x: 0, y: 0, width: 1, height: 0.25))
        ]
        let rotationStacks = [
            TileStack(address: rotationOld[0].address(), order: [a], selected: a,
                      selectionEpoch: 4),
            TileStack(address: rotationOld[1].address(), order: [b], selected: b,
                      selectionEpoch: 5)
        ]
        let rotated = LayoutRebase.rebase(stacks: rotationStacks,
                                          from: rotationOld, to: rotationNew)
        check(rotated.map(\.order) == [[a], [b]] && rotated.map(\.selected) == [a, b],
              "rebase: same tile IDs preserve stack order and selection")
        check(rotated.map(\.address.normalizedCenter) == rotationNew.map(\.center),
              "rebase: same tile IDs refresh only geometry after rotation")
    }

    // ---- spatial navigation and raw-vs-spaced geometry ----
    do {
        let source = TileAddress(screenKey: "main", leafIndex: 0,
                                 normalizedCenter: CGPoint(x: 0.5, y: 0.5))
        let leaves = [
            leaf("main", 0, CGRect(x: 40, y: 40, width: 20, height: 20)),
            leaf("main", 1, CGRect(x: 0, y: 40, width: 30, height: 20)),
            leaf("main", 2, CGRect(x: 60, y: 40, width: 20, height: 20)),
            leaf("main", 3, CGRect(x: 40, y: 70, width: 20, height: 20)),
            leaf("main", 4, CGRect(x: 40, y: 0, width: 20, height: 20)),
            // These diagonal candidates exercise perpendicular-overlap priority.
            leaf("main", 5, CGRect(x: 65, y: 75, width: 15, height: 15)),
            leaf("main", 6, CGRect(x: 0, y: 75, width: 20, height: 15)),
        ]
        let layouts = LayoutSnapshot(screens: ["main": leaves],
                                     frames: ["main": leaves.map(\.rect)],
                                     primaryScreenKey: "main")
        check(TileNavigation.nearest(from: source, direction: .left, in: layouts)?.leafIndex == 1,
              "navigation: left prefers a perpendicular-overlap candidate")
        check(TileNavigation.nearest(from: source, direction: .right, in: layouts)?.leafIndex == 2,
              "navigation: right prefers a perpendicular-overlap candidate")
        check(TileNavigation.nearest(from: source, direction: .up, in: layouts)?.leafIndex == 3,
              "navigation: up selects the nearest raw geometry")
        check(TileNavigation.nearest(from: source, direction: .down, in: layouts)?.leafIndex == 4,
              "navigation: down selects the nearest raw geometry")

        let edge = TileAddress(screenKey: "main", leafIndex: 6,
                               normalizedCenter: CGPoint(x: 0.1, y: 0.825))
        check(TileNavigation.nearest(from: edge, direction: .left, in: layouts) == nil,
              "navigation: edge does not wrap")

        let gapless = LayoutSnapshot(screens: ["main": leaves],
                                     frames: ["main": [
                                         CGRect(x: 0, y: 0, width: 100, height: 100),
                                         CGRect(x: 100, y: 0, width: 100, height: 100)
                                     ]],
                                     primaryScreenKey: "main", gapPoints: 0)
        check(gapless.rawFrame(for: TileAddress(screenKey: "main", leafIndex: 0,
                                                normalizedCenter: .zero)) ==
              CGRect(x: 0, y: 0, width: 100, height: 100),
              "spacing: rawFrame exposes the exact Zones rectangle")
        check(gapless.frame(for: TileAddress(screenKey: "main", leafIndex: 0,
                                             normalizedCenter: .zero)) ==
              gapless.rawFrame(for: TileAddress(screenKey: "main", leafIndex: 0,
                                                normalizedCenter: .zero)),
              "spacing: zero preserves the raw rectangle bit-for-bit")

        let spaced = LayoutSnapshot(
            screens: ["main": [
                leaf("main", 0, CGRect(x: 0, y: 0, width: 100, height: 100)),
                leaf("main", 1, CGRect(x: 100, y: 0, width: 100, height: 100))
            ]],
            frames: ["main": [
                CGRect(x: 0, y: 0, width: 100, height: 100),
                CGRect(x: 100, y: 0, width: 100, height: 100)
            ]], primaryScreenKey: "main", gapPoints: 8)
        check(spaced.frame(for: spaced.screens["main"]![0].address()) ==
              CGRect(x: 0, y: 0, width: 96, height: 100),
              "spacing: first tile gets only its shared-side inset")
        check(spaced.frame(for: spaced.screens["main"]![1].address()) ==
              CGRect(x: 104, y: 0, width: 96, height: 100),
              "spacing: exact eight-point gap has no outer margin")

        let tJunction = LayoutSnapshot(
            screens: ["main": [
                leaf("main", 0, CGRect(x: 0, y: 0, width: 100, height: 100)),
                leaf("main", 1, CGRect(x: 100, y: 50, width: 100, height: 50)),
                leaf("main", 2, CGRect(x: 100, y: 0, width: 100, height: 50))
            ]],
            frames: ["main": [
                CGRect(x: 0, y: 0, width: 100, height: 100),
                CGRect(x: 100, y: 50, width: 100, height: 50),
                CGRect(x: 100, y: 0, width: 100, height: 50)
            ]], primaryScreenKey: "main", gapPoints: 8)
        let big = tJunction.frame(for: tJunction.screens["main"]![0].address())!
        let top = tJunction.frame(for: tJunction.screens["main"]![1].address())!
        let bottom = tJunction.frame(for: tJunction.screens["main"]![2].address())!
        check(big.maxX == 96 && top.minX == 104 && bottom.minX == 104,
              "spacing: T-junction applies one safe shared-side gap")
        check(top.minY - bottom.maxY == 8,
              "spacing: T-junction also keeps the internal horizontal gap")

        let tiny = LayoutSnapshot(
            screens: ["main": [
                leaf("main", 0, CGRect(x: 0, y: 0, width: 4, height: 4)),
                leaf("main", 1, CGRect(x: 4, y: 0, width: 96, height: 4))
            ]],
            frames: ["main": [
                CGRect(x: 0, y: 0, width: 4, height: 4),
                CGRect(x: 4, y: 0, width: 96, height: 4)
            ]], primaryScreenKey: "main", gapPoints: 8)
        check(tiny.frame(for: tiny.screens["main"]![0].address())!.width >= 1,
              "spacing: a tiny tile is clamped to at least one point")
    }

    // ---- directional focus skips unavailable stacks and directional move preserves membership ----
    do {
        let source = token(60), unavailable = token(61)
        let leaves = (0..<3).map { index in
            leaf("main", index, CGRect(x: CGFloat(index) * 100, y: 0,
                                       width: 100, height: 100))
        }
        let layouts = LayoutSnapshot(screens: ["main": leaves],
                                     frames: ["main": leaves.map(\.rect)],
                                     primaryScreenKey: "main")
        func managed(_ token: WindowToken, _ tile: TileAddress) -> ManagedWindow {
            ManagedWindow(token: token, workspace: .workspace1, tile: tile,
                          adoptionFrame: .zero, focusEpoch: 1)
        }
        let stacks = [
            TileStack(address: leaves[0].address(), order: [source], selected: source,
                      selectionEpoch: 1),
            TileStack(address: leaves[1].address()),
            TileStack(address: leaves[2].address(), order: [unavailable], selected: unavailable,
                      selectionEpoch: 1)
        ]
        let workspace = Workspace(id: .workspace1, screens: ["main": stacks])
        let workspaces = Dictionary(uniqueKeysWithValues: WorkspaceID.all.map { id in
            (id, id == .workspace1 ? workspace : Workspace(id: id, screens: ["main":
                leaves.map { TileStack(address: $0.address()) }
            ]))
        })
        let initial = TilesSession(workspaces: workspaces,
                                   windows: [source: managed(source, leaves[0].address()),
                                             unavailable: managed(unavailable, leaves[2].address())],
                                   nextFocusEpoch: 2)
        let snapshot = WindowSnapshot([
            entry(source, x: 0),
            entry(unavailable, x: 200, minimized: true)
        ], focused: source)
        let skipped = TilesReducer.plan(state: initial, event: .focusTile(.right),
                                        snapshot: snapshot, layouts: layouts)
        check(skipped.isNoOp, "focus: empty and unavailable stacks are skipped")

        let usableSnapshot = WindowSnapshot([
            entry(source, x: 0), entry(unavailable, x: 200)
        ], focused: source)
        let focusedPlan = TilesReducer.plan(state: initial, event: .focusTile(.right),
                                            snapshot: usableSnapshot, layouts: layouts)
        check(focusedPlan.effects.allSatisfy { effect in
            if case .raise = effect { return true }
            if case .focus = effect { return true }
            return false
        }, "focus: emits only raise and focus effects")
        let focused = TilesReducer.commit(state: initial, plan: focusedPlan,
                                          results: successful(focusedPlan))
        check(focused.workspaces[.workspace1]?.screens["main"]?[2].selected == unavailable &&
              (focused.windows[unavailable]?.focusEpoch ?? 0) > 1,
              "focus: selects the reachable window in the nearest usable tile")

        let moveEmptyPlan = TilesReducer.plan(state: initial,
                                              event: .moveFocusedWindowToTile(.right),
                                              snapshot: usableSnapshot, layouts: layouts)
        let movedEmpty = TilesReducer.commit(state: initial, plan: moveEmptyPlan,
                                             results: successful(moveEmptyPlan))
        check(movedEmpty.windows[source]?.tile.leafIndex == 1,
              "move: focused window moves to an empty neighbouring tile")
        check(movedEmpty.isValid, "move: empty destination preserves unique membership")

        let moveOccupiedPlan = TilesReducer.plan(state: movedEmpty,
                                                 event: .moveFocusedWindowToTile(.right),
                                                 snapshot: usableSnapshot, layouts: layouts)
        let movedOccupied = TilesReducer.commit(state: movedEmpty, plan: moveOccupiedPlan,
                                                results: successful(moveOccupiedPlan))
        check(movedOccupied.workspaces[.workspace1]?.screens["main"]?[2].order ==
              [unavailable, source],
              "move: occupied destination appends to the existing stack")
        check(movedOccupied.isValid, "move: occupied destination keeps one-owner membership")
    }

    // ---- adoption, cycling, duplicate create, and verified commit ----
    do {
        let first = token(20), second = token(21)
        let snapshot = WindowSnapshot([
            entry(first, x: 10), entry(second, x: 20)
        ], focused: first)
        let layouts = layout(count: 1)
        let adopt = TilesReducer.plan(state: .empty, event: .adoptVisible,
                                      snapshot: snapshot, layouts: layouts)
        check(adopt.effects.contains { if case .setFrame = $0 { return true }; return false },
              "reducer: adoption plans frame effects")
        let adopted = TilesReducer.commit(state: .empty, plan: adopt,
                                          results: successful(adopt))
        check(adopted.windows.count == 2, "reducer: adopts eligible windows once")
        check(adopted.workspaces[.workspace1]?.screens["main"]?.first?.order == [first, second],
              "reducer: overflow joins the same focused/only tile in order")
        check(adopted.workspaces[.workspace1]?.screens["main"]?.first?.selected == first,
              "reducer: bulk adoption preserves the actually focused window")
        check(!adopt.effects.contains { effect in
            if case .raise(second, _) = effect { return true }
            return false
        }, "reducer: bulk adoption does not raise a non-selected overflow window")
        check(adopted.isValid, "reducer: adopted state satisfies membership invariants")

        let created = token(22)
        let createdSnapshot = WindowSnapshot([
            entry(first, x: 10), entry(second, x: 20), entry(created, x: 30)
        ], focused: first)
        let createdPlan = TilesReducer.plan(state: adopted, event: .windowCreated(created),
                                            snapshot: createdSnapshot, layouts: layouts)
        check(createdPlan.nextState.workspaces[.workspace1]?.screens["main"]?.first?.order ==
              [first, second, created] &&
              createdPlan.nextState.workspaces[.workspace1]?.screens["main"]?.first?.selected == created,
              "reducer: a new overflow window becomes the selected stack member")
        check(createdPlan.effects.contains { if case .raise(created, _) = $0 { return true }; return false } &&
              createdPlan.effects.contains { if case .focus(created, _) = $0 { return true }; return false },
              "reducer: a new overflow window is raised and focused")

        let bestEffortCommitted = TilesReducer.commit(
            state: .empty, plan: adopt,
            results: adopt.effects.map { effect in
                switch effect {
                case .raise, .focus:
                    return .failure(effect, .cannotComplete)
                default:
                    return .success(effect)
                }
            })
        check(bestEffortCommitted.windows.count == 2 && bestEffortCommitted.isValid,
              "reducer: frame commits survive best-effort raise/focus failures")

        let duplicate = TilesReducer.plan(state: adopted, event: .windowCreated(first),
                                          snapshot: snapshot, layouts: layouts)
        check(duplicate.isNoOp && duplicate.effects.isEmpty,
              "reducer: duplicate create event is a no-op")

        let cycleSnapshot = WindowSnapshot([
            entry(first, x: 10), entry(second, x: 20)
        ], focused: first)
        let cycle = TilesReducer.plan(state: adopted,
                                      event: .cycleFocusedTile(.forward),
                                      snapshot: cycleSnapshot, layouts: layouts)
        let cycled = TilesReducer.commit(state: adopted, plan: cycle,
                                         results: successful(cycle))
        check(cycled.workspaces[.workspace1]?.screens["main"]?.first?.selected == second,
              "reducer: cycle commits selected member after focus effects")
        check(!cycle.effects.contains { if case .setMinimized = $0 { return true }; return false },
              "reducer: cycling never minimizes previous member")

        let missedClose = TilesReducer.plan(
            state: adopted, event: .reconcile,
            snapshot: WindowSnapshot([entry(second, x: 20)], focused: second,
                                     goneTokens: [first]),
            layouts: layouts)
        let afterMissedClose = TilesReducer.commit(
            state: adopted, plan: missedClose, results: successful(missedClose))
        check(afterMissedClose.windows[first] == nil,
              "reducer: a confirmed-gone token is removed during reconcile")
        check(afterMissedClose.workspaces[.workspace1]?.screens["main"]?.first?.order == [second],
              "reducer: confirmed close frees its stack membership")
    }

    // ---- workspace staging, destination ordering, failure, and stale plans ----
    do {
        let first = token(30)
        let snapshot = WindowSnapshot([entry(first, x: 10)], focused: first)
        let layouts = layout(count: 1)
        let adopt = TilesReducer.plan(state: .empty, event: .adoptVisible,
                                      snapshot: snapshot, layouts: layouts)
        let state = TilesReducer.commit(state: .empty, plan: adopt,
                                        results: successful(adopt))
        let switchPlan = TilesReducer.plan(state: state,
                                           event: .switchWorkspace(.workspace2),
                                           snapshot: snapshot, layouts: layouts)
        check(switchPlan.nextState.activeWorkspace == .workspace2,
              "workspace: active model changes only in the plan")
        let sourceMinimize = switchPlan.effects.firstIndex {
            if case .setMinimized(first, true, _) = $0 { return true }
            return false
        }
        check(sourceMinimize != nil, "workspace: source window is staged")
        let switched = TilesReducer.commit(state: state, plan: switchPlan,
                                            results: successful(switchPlan))
        check(switched.activeWorkspace == .workspace2 &&
              switched.windows[first]?.visibility == .stagedByTiles,
              "workspace: verified switch commits staging")
        check(switched.isValid, "workspace: staged source satisfies invariants")

        let unreachableSnapshot = WindowSnapshot([
            entry(first, x: 10, reachable: false)
        ], focused: nil)
        let unreachableSwitch = TilesReducer.plan(
            state: state, event: .switchWorkspace(.workspace2),
            snapshot: unreachableSnapshot, layouts: layouts)
        check(unreachableSwitch.nextState.windows[first]?.visibility == .visible,
              "workspace: unreachable source keeps its visibility ownership")
        check(!unreachableSwitch.effects.contains {
            if case .setMinimized(first, true, _) = $0 { return true }
            return false
        }, "workspace: unreachable source is not falsely staged")
        check(unreachableSwitch.nextState.isValid,
              "workspace: an unreachable source may remain visible in an inactive workspace")

        let userMinimizedSource = WindowSnapshot([
            entry(first, x: 10, minimized: true, reachable: true)
        ], focused: nil)
        let switchAroundUserMinimize = TilesReducer.plan(
            state: state, event: .switchWorkspace(.workspace2),
            snapshot: userMinimizedSource, layouts: layouts)
        check(!switchAroundUserMinimize.effects.contains {
            if case .setMinimized(first, true, _) = $0 { return true }
            return false
        }, "workspace: a user-minimized source is not claimed as Tiles staging")
        check(switchAroundUserMinimize.nextState.windows[first]?.visibility == .visible,
              "workspace: source ownership waits for reconcile after a user minimize race")

        let returnSnapshot = WindowSnapshot([
            entry(first, x: 10, minimized: false, reachable: false)
        ], focused: nil)
        let returnPlan = TilesReducer.plan(
            state: switched, event: .switchWorkspace(.workspace1),
            snapshot: returnSnapshot, layouts: layouts)
        check(returnPlan.effects.contains {
            if case .setMinimized(first, false, _) = $0 { return true }
            return false
        }, "workspace: owned staging attempts restore across a native Space")
        check(returnPlan.nextState.activeWorkspace == .workspace2,
              "workspace: cross-Space restore is a barrier before source staging")
        let afterBarrier = TilesReducer.commit(
            state: switched, plan: returnPlan, results: successful(returnPlan))
        let freshReturnSnapshot = WindowSnapshot([
            entry(first, x: 10, minimized: false, reachable: true)
        ], focused: first)
        let finishReturn = TilesReducer.plan(
            state: afterBarrier, event: .switchWorkspace(.workspace1),
            snapshot: freshReturnSnapshot, layouts: layouts)
        check(finishReturn.nextState.activeWorkspace == .workspace1,
              "workspace: fresh snapshot completes a barriered switch")

        let second = token(31)
        let twoSnapshot = WindowSnapshot([
            entry(first, x: 10), entry(second, x: 20)
        ], focused: first)
        let twoAdopt = TilesReducer.plan(state: .empty, event: .adoptVisible,
                                         snapshot: twoSnapshot, layouts: layouts)
        let twoState = TilesReducer.commit(state: .empty, plan: twoAdopt,
                                           results: successful(twoAdopt))
        let twoSwitch = TilesReducer.plan(state: twoState,
                                          event: .switchWorkspace(.workspace2),
                                          snapshot: twoSnapshot, layouts: layouts)
        let twoSwitched = TilesReducer.commit(state: twoState, plan: twoSwitch,
                                              results: successful(twoSwitch))
        let bulkReturnSnapshot = WindowSnapshot([
            entry(first, x: 10, minimized: true, reachable: false),
            entry(second, x: 20, minimized: true, reachable: false)
        ], focused: nil)
        let bulkReturn = TilesReducer.plan(
            state: twoSwitched, event: .switchWorkspace(.workspace1),
            snapshot: bulkReturnSnapshot, layouts: layouts)
        let bulkRestores = bulkReturn.effects.filter {
            if case .setMinimized(_, false, _) = $0 { return true }
            return false
        }
        check(bulkReturn.nextState.activeWorkspace == .workspace1,
              "workspace: already-minimized staged windows do not create a Space barrier")
        check(bulkRestores.count == 2,
              "workspace: already-minimized staged windows restore in one bulk plan")

        let goneAndFailed = twoSwitch.effects.enumerated().map { offset, effect in
            offset == 0 ? WindowEffectResult.failure(effect, .goneWindow)
                        : WindowEffectResult.failure(effect, .rejectedFrame)
        }
        let partialWorkspaceFailure = TilesReducer.commit(
            state: twoState, plan: twoSwitch, results: goneAndFailed)
        check(partialWorkspaceFailure.mutationGeneration != twoSwitch.mutationID.rawValue &&
              partialWorkspaceFailure.windows[first] == nil &&
              partialWorkspaceFailure.windows[second] != nil,
              "workspace: gone window plus essential failure leaves mutation uncommitted")

        let failed = TilesReducer.commit(state: state, plan: switchPlan,
                                         results: switchPlan.effects.enumerated().map {
                                             $0.offset == 0
                                                 ? .failure($0.element, .rejectedFrame)
                                                 : .success($0.element)
                                         })
        check(failed == state && failed.activeWorkspace == .workspace1,
              "workspace: essential failure preserves prior active workspace")
        check(!switchPlan.compensation.isEmpty, "workspace: failure has deterministic compensation")

        var alreadyRestored = switched
        alreadyRestored.activeWorkspace = .workspace2
        let noOpRestoreSnapshot = WindowSnapshot([
            entry(first, x: 10, minimized: false, reachable: true)
        ], focused: nil)
        let noOpRestore = TilesReducer.plan(
            state: alreadyRestored, event: .switchWorkspace(.workspace1),
            snapshot: noOpRestoreSnapshot, layouts: layouts)
        check(!noOpRestore.compensation.contains { effect in
            if case .setMinimized(first, true, _) = effect { return true }
            return false
        }, "workspace: compensation never minimizes a destination that was already restored")

        let partialResults = switchPlan.effects.enumerated().map { offset, effect in
            offset == 0 ? WindowEffectResult.success(effect)
                        : WindowEffectResult.failure(effect, .cannotComplete)
        }
        let confirmedOnly = TilesReducer.compensation(
            for: switchPlan, results: partialResults,
            priorState: state, snapshot: snapshot)
        check(confirmedOnly.count <= 1,
              "workspace: rollback contains only confirmed effects")

        let pending = switchPlan.nextState
        let newer = TilesReducer.plan(state: pending, event: .switchWorkspace(.workspace3),
                                      snapshot: snapshot, layouts: layouts)
        check(TilesReducer.commit(state: pending, plan: switchPlan,
                                  results: successful(switchPlan)) == pending,
              "reducer: stale generation cannot commit over newer transition")
        let advanced = TilesReducer.commit(state: pending, plan: newer,
                                            results: successful(newer))
        check(advanced.activeWorkspace == .workspace3,
              "reducer: current transition generation commits")
    }

    // ---- moving and explicit Zones placement preserve one-owner membership ----
    do {
        let first = token(40), second = token(41)
        let snapshot = WindowSnapshot([
            entry(first, x: 10), entry(second, x: 200)
        ], focused: first)
        let layouts = layout(count: 2)
        let adopt = TilesReducer.plan(state: .empty, event: .adoptVisible,
                                      snapshot: snapshot, layouts: layouts)
        let state = TilesReducer.commit(state: .empty, plan: adopt,
                                        results: successful(adopt))
        let move = TilesReducer.plan(state: state,
                                     event: .moveFocusedWindow(to: .workspace2),
                                     snapshot: snapshot, layouts: layouts)
        let moved = TilesReducer.commit(state: state, plan: move,
                                        results: successful(move))
        check(moved.windows[first]?.workspace == .workspace2 &&
              moved.windows[first]?.visibility == .stagedByTiles,
              "move: focused window enters destination workspace as staged")
        check(moved.isValid, "move: source and destination keep unique membership")

        let unreachableMoveSnapshot = WindowSnapshot([
            entry(first, x: 10, reachable: false), entry(second, x: 200)
        ], focused: first)
        let unreachableMove = TilesReducer.plan(
            state: state, event: .moveFocusedWindow(to: .workspace2),
            snapshot: unreachableMoveSnapshot, layouts: layouts)
        check(unreachableMove.isNoOp && unreachableMove.nextState == state,
              "move: unreachable focused window is not assigned to staging Tiles did not perform")

        let changedLayout = layout(count: 3)
        let inactiveRebase = TilesReducer.plan(
            state: moved, event: .layoutChanged,
            snapshot: WindowSnapshot([
                entry(first, x: 10, minimized: true, reachable: false),
                entry(second, x: 200)
            ], focused: second), layouts: changedLayout)
        check(!inactiveRebase.isNoOp,
              "layout: an inactive workspace rebase commits without AX effects")
        let rebasedInactive = TilesReducer.commit(
            state: moved, plan: inactiveRebase, results: successful(inactiveRebase))
        check(rebasedInactive.workspaces[.workspace2]?.screens["main"]?.count == 3,
              "layout: inactive workspace receives the new Zones leaves")

        let destinationAddress = layouts.screens["main"]![1].address(screenKey: "main")
        let place = TilesReducer.plan(state: state, event: .place(first, at: destinationAddress),
                                      snapshot: snapshot, layouts: layouts)
        let placed = TilesReducer.commit(state: state, plan: place,
                                         results: successful(place))
        check(placed.windows[first]?.tile.id == destinationAddress.id,
              "placement: explicit Zones target updates the tile")
        check(placed.isValid, "placement: explicit move preserves invariants")
    }

    // ---- display disconnect follows the screen observed by macOS ----
    do {
        let first = token(50)
        let externalLayout = layout("external", count: 1)
        let externalSnapshot = WindowSnapshot([
            entry(first, x: 10, screen: "external")
        ], focused: first)
        let adopt = TilesReducer.plan(
            state: .empty, event: .adoptVisible,
            snapshot: externalSnapshot, layouts: externalLayout)
        let state = TilesReducer.commit(
            state: .empty, plan: adopt, results: successful(adopt))

        let primaryLayout = layout("main", count: 2)
        let movedBySystem = WindowSnapshot([
            entry(first, x: 20, screen: "main")
        ], focused: first)
        let topology = TilesReducer.plan(
            state: state, event: .layoutChanged,
            snapshot: movedBySystem, layouts: primaryLayout)
        check(topology.nextState.windows[first]?.tile.screenKey == "main",
              "display: orphaned assignment follows the screen observed by macOS")
        check(topology.nextState.workspaces[.workspace1]?.screens["external"] == nil,
              "display: empty disconnected screen is removed after relocation")
        check(topology.nextState.isValid,
              "display: disconnect keeps one-owner membership valid")
    }

    // ---- settings and recovery schema safety ----
    do {
        let settings = TilesSettings(nextWorkspace: ShortcutBinding(action: "nextWorkspace",
                                                                      keyCode: 17, modifiers: 256))
        let data = try settings.encoded()
        check(try TilesSettings.decode(data) == settings, "settings: schema 1 round-trips")
        let future = Data("{\"schemaVersion\":2}".utf8)
        if case .failure(.unsupportedSchema(2)) = TilesSettings.decodeSafely(future) {
            check(true, "settings: future schema is rejected safely")
        } else {
            check(false, "settings: future schema is rejected safely")
        }
        if case .failure(.invalidSchemaVersion(0)) = TilesSettings.decodeSafely(Data("{\"schemaVersion\":0}".utf8)) {
            check(true, "settings: invalid old schema is rejected safely")
        } else {
            check(false, "settings: invalid old schema is rejected safely")
        }

        let record = RecoveryRecord(bundleIdentifier: "com.example.Editor", pid: 42,
                                    role: "AXWindow", subrole: "AXStandardWindow",
                                    titleDigest: "digest", ordinalAmongExactPeers: 0,
                                    adoptionFrame: CGRect(x: 0, y: 0, width: 100, height: 100),
                                    lastAppliedFrame: CGRect(x: 10, y: 10, width: 100, height: 100),
                                    stageIntent: true)
        let journal = RecoveryJournal(records: [record])
        let journalData = try journal.encoded()
        check(try JSONDecoder().decode(RecoveryJournal.self, from: journalData) == journal,
              "recovery: schema 1 round-trips")
        let candidate = RecoveryCandidate(bundleIdentifier: "com.example.Editor", pid: 42,
                                          role: "AXWindow", subrole: "AXStandardWindow",
                                          titleDigest: "digest", ordinalAmongExactPeers: 0,
                                          frame: CGRect(x: 10, y: 10, width: 100, height: 100))
        check(RecoveryModel.match(record: record, candidates: [candidate]) == .unique(0),
              "recovery: one strong candidate matches")
        check(RecoveryModel.match(record: record, candidates: [candidate, candidate]).isAmbiguous,
              "recovery: ambiguous candidates are never auto-selected")
    }
}

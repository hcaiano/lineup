import Foundation

/// Pure state machine for Tiles.  It computes an immutable model/effect plan;
/// an AppKit shell executes the effects and calls `commit` with verification
/// results.  No method in this type touches an AX or AppKit object.
public enum TilesReducer {
    public static func plan(
        state: TilesSession,
        event: TilesEvent,
        snapshot: WindowSnapshot,
        layouts: LayoutSnapshot
    ) -> TilesPlan {
        let baseGeneration = state.transition?.mutationID.rawValue ?? state.mutationGeneration
        let mutationID = MutationID(rawValue: baseGeneration &+ 1)
        var baseline = state
        baseline.transition = nil
        baseline.ensureFourWorkspaces()
        var working = prepare(state: state, snapshot: snapshot, layouts: layouts)
        working.transition = nil
        let before = working
        var effects: [WindowEffect] = []

        switch event {
        case .reconcile:
            reconcileExisting(&working, snapshot: snapshot, layouts: layouts,
                              mutationID: mutationID, effects: &effects)
            adoptVisible(&working, tokens: nil, snapshot: snapshot, layouts: layouts,
                         mutationID: mutationID, effects: &effects,
                         selectNewlyAdopted: true)

        case .adoptVisible:
            adoptVisible(&working, tokens: nil, snapshot: snapshot, layouts: layouts,
                         mutationID: mutationID, effects: &effects)

        case let .adopt(token), let .windowCreated(token):
            adoptVisible(&working, tokens: [token], snapshot: snapshot, layouts: layouts,
                         mutationID: mutationID, effects: &effects,
                         selectNewlyAdopted: true)

        case let .windowClosed(token):
            removeToken(&working, token: token)

        case let .focus(token):
            focus(&working, token: token, snapshot: snapshot, layouts: layouts,
                  mutationID: mutationID, effects: &effects, external: false)

        case let .externalActivation(token):
            focus(&working, token: token, snapshot: snapshot, layouts: layouts,
                  mutationID: mutationID, effects: &effects, external: true)

        case let .cycleFocusedTile(direction):
            cycleFocusedTile(&working, direction: direction, snapshot: snapshot,
                             mutationID: mutationID, effects: &effects)

        case let .focusTile(direction):
            focusTile(&working, direction: direction, snapshot: snapshot,
                      layouts: layouts, mutationID: mutationID, effects: &effects)

        case let .switchWorkspace(destination):
            switchWorkspace(&working, to: destination, snapshot: snapshot, layouts: layouts,
                            mutationID: mutationID, effects: &effects)

        case .nextWorkspace:
            let destination = working.activeWorkspace.next
            switchWorkspace(&working, to: destination, snapshot: snapshot, layouts: layouts,
                            mutationID: mutationID, effects: &effects)

        case .previousWorkspace:
            let destination = working.activeWorkspace.previous
            switchWorkspace(&working, to: destination, snapshot: snapshot, layouts: layouts,
                            mutationID: mutationID, effects: &effects)

        case let .moveFocusedWindow(destination):
            moveFocusedWindow(&working, to: destination, snapshot: snapshot,
                              mutationID: mutationID, effects: &effects)

        case let .moveFocusedWindowToTile(direction):
            moveFocusedWindowToTile(&working, direction: direction, snapshot: snapshot,
                                    layouts: layouts, mutationID: mutationID, effects: &effects)

        case .toggleFocusedSplitOrientation:
            // The Zones tree is intentionally not duplicated in TilesCore.
            // The AppKit coordinator handles this event through the typed Zones
            // mutation seam and then publishes a fresh layout snapshot.
            break

        case let .minimize(token, byUser):
            minimize(&working, token: token, byUser: byUser)

        case let .restore(token):
            restore(&working, token: token, snapshot: snapshot, layouts: layouts,
                    mutationID: mutationID, effects: &effects)

        case let .place(token, address):
            place(&working, token: token, address: address, snapshot: snapshot,
                  layouts: layouts, mutationID: mutationID, effects: &effects)

        case let .detach(token):
            detach(&working, token: token)

        case .layoutChanged:
            reflowActive(&working, snapshot: snapshot, layouts: layouts,
                         mutationID: mutationID, effects: &effects)
        }

        let changed = working != baseline
        let noOp = !changed && effects.isEmpty
        if !noOp {
            let transition: Transition
            switch event {
            case let .switchWorkspace(destination):
                transition = Transition(mutationID: mutationID,
                                        from: before.activeWorkspace, to: destination)
            case .nextWorkspace:
                transition = Transition(mutationID: mutationID,
                                        from: before.activeWorkspace,
                                        to: before.activeWorkspace.next)
            case .previousWorkspace:
                transition = Transition(mutationID: mutationID,
                                        from: before.activeWorkspace,
                                        to: before.activeWorkspace.previous)
            default:
                transition = Transition(mutationID: mutationID)
            }
            working.transition = transition
        }

        let compensation = compensationEffects(for: effects, state: state, snapshot: snapshot)
        return TilesPlan(event: event,
                         baseGeneration: baseGeneration,
                         mutationID: mutationID,
                         effects: effects,
                         compensation: compensation,
                         nextState: working,
                         isNoOp: noOp)
    }

    /// Commit only a plan based on the current mutation generation and only
    /// after every required effect is confirmed.  A stale plan or an essential
    /// failure leaves the prior active workspace and assignments intact.
    public static func commit(
        state: TilesSession,
        plan: TilesPlan,
        results: [WindowEffectResult]
    ) -> TilesSession {
        guard isCurrent(plan: plan, for: state) else { return state }
        if plan.isNoOp {
            return state
        }

        let gone = plan.effects.compactMap { effect -> WindowToken? in
            guard let result = results.first(where: { $0.effect == effect }) else { return nil }
            return result.isGone ? effect.token : nil
        }
        // Frame and minimize writes are ownership boundaries: a failed one
        // must keep the prior model and trigger compensation. Raising and
        // focusing are advisory side effects, however. They can fail because
        // another app or native Space wins the race after the geometry/state
        // write was already verified, so they must not roll back that write.
        let essentialEffects = plan.effects.filter { !isBestEffort($0) }
        let allEssentialSucceeded = essentialEffects.allSatisfy { effect in
            guard let result = results.first(where: { $0.effect == effect }) else { return false }
            return result.succeeded || result.isGone
        }

        if !allEssentialSucceeded {
            // A window that closed during a transition is not an essential
            // failure.  Remove only those gone tokens; preserve the previous
            // active workspace and leave all remaining effects for recovery.
            var prior = state
            for token in gone { removeToken(&prior, token: token) }
            return prior
        }

        var committed = plan.nextState
        for token in gone { removeToken(&committed, token: token) }
        committed.transition = nil
        committed.mutationGeneration = plan.mutationID.rawValue
        return committed
    }

    /// Roll back only effects that the window boundary confirmed. A failed or
    /// skipped effect must never create a new mutation during compensation.
    public static func compensation(
        for plan: TilesPlan,
        results: [WindowEffectResult],
        priorState: TilesSession,
        snapshot: WindowSnapshot
    ) -> [WindowEffect] {
        let succeeded = results.filter(\.succeeded).map(\.effect)
        return compensationEffects(for: plan.effects.filter { succeeded.contains($0) },
                                   state: priorState, snapshot: snapshot)
    }

    private static func isCurrent(plan: TilesPlan, for state: TilesSession) -> Bool {
        if let transition = state.transition {
            return transition.mutationID.rawValue == plan.baseGeneration
        }
        return state.mutationGeneration == plan.baseGeneration
    }

    private static func isBestEffort(_ effect: WindowEffect) -> Bool {
        switch effect {
        case .raise, .focus:
            return true
        case .setFrame, .setMinimized:
            return false
        }
    }

    // MARK: - Preparation and layout

    private static func prepare(state: TilesSession, snapshot: WindowSnapshot,
                                 layouts: LayoutSnapshot) -> TilesSession {
        var result = state
        result.ensureFourWorkspaces()

        for id in WorkspaceID.all {
            guard var workspace = result.workspaces[id] else { continue }
            let keys = Set(workspace.screens.keys).union(layouts.screenKeys).sorted()
            for key in keys {
                guard let newLeaves = layouts.screens[key], !newLeaves.isEmpty else { continue }
                let oldStacks = workspace.screens[key] ?? []
                if oldStacks.isEmpty {
                    workspace.screens[key] = newLeaves.map { leaf in
                        TileStack(address: leaf.address(screenKey: key))
                    }
                    continue
                }
                let oldLeaves = oldStacks.map {
                    NormalizedLeaf(screenKey: key,
                                   index: $0.address.leafIndex,
                                   normalizedCenter: $0.address.normalizedCenter)
                }
                workspace.screens[key] = LayoutRebase.rebase(stacks: oldStacks,
                                                              from: oldLeaves,
                                                              to: newLeaves)
            }
            result.workspaces[id] = workspace
        }

        relocateOrphanedScreens(&result, snapshot: snapshot, layouts: layouts)

        // Rebase can change a tile's address but never changes token identity.
        // Refresh the denormalized ManagedWindow location after all workspaces
        // have been rebuilt.  One index pass keeps this linear in the number of
        // stack members instead of rescanning every workspace per window.
        var ownership: [WindowToken: (workspace: WorkspaceID, tile: TileAddress)] = [:]
        for id in WorkspaceID.all {
            guard let workspace = result.workspaces[id] else { continue }
            for stack in workspace.allStacks {
                // First occurrence wins, matching `locate`'s scan order.
                for token in stack.order where ownership[token] == nil {
                    ownership[token] = (id, stack.address)
                }
            }
        }
        for token in result.windows.keys {
            guard let owner = ownership[token] else { continue }
            result.windows[token]?.workspace = owner.workspace
            result.windows[token]?.tile = owner.tile
        }
        return result
    }

    private static func relocateOrphanedScreens(
        _ state: inout TilesSession,
        snapshot: WindowSnapshot,
        layouts: LayoutSnapshot
    ) {
        let validScreens = Set(layouts.screenKeys.filter {
            !(layouts.screens[$0] ?? []).isEmpty
        })
        guard !validScreens.isEmpty else { return }

        for workspaceID in WorkspaceID.all {
            guard var workspace = state.workspaces[workspaceID] else { continue }
            let orphanKeys = workspace.screens.keys.filter { !validScreens.contains($0) }.sorted()
            for orphanKey in orphanKeys {
                guard var orphanStacks = workspace.screens[orphanKey] else { continue }
                for orphanIndex in orphanStacks.indices {
                    let source = orphanStacks[orphanIndex]
                    for token in source.order {
                        let observed = snapshot.windows[token]?.screenKey
                        let destinationScreen = observed.flatMap {
                            validScreens.contains($0) ? $0 : nil
                        } ?? layouts.primaryScreenKey.flatMap {
                            validScreens.contains($0) ? $0 : nil
                        }
                        guard let destinationScreen,
                              let leaves = layouts.screens[destinationScreen], !leaves.isEmpty else { continue }
                        if workspace.screens[destinationScreen] == nil {
                            workspace.screens[destinationScreen] = leaves.map {
                                TileStack(address: $0.address(screenKey: destinationScreen))
                            }
                        }
                        guard var targetStacks = workspace.screens[destinationScreen],
                              let targetIndex = targetStacks.indices.min(by: { lhs, rhs in
                                  TileGeometry.distanceSquared(targetStacks[lhs].address.normalizedCenter,
                                                               source.address.normalizedCenter)
                                    < TileGeometry.distanceSquared(targetStacks[rhs].address.normalizedCenter,
                                                                   source.address.normalizedCenter)
                              }) else { continue }
                        let selectSource = source.selected == token &&
                            source.selectionEpoch >= targetStacks[targetIndex].selectionEpoch
                        _ = targetStacks[targetIndex].append(
                            token, selecting: selectSource,
                            epoch: max(source.selectionEpoch,
                                       state.windows[token]?.focusEpoch ?? 0))
                        workspace.screens[destinationScreen] = targetStacks
                        _ = orphanStacks[orphanIndex].remove(token)
                    }
                }
                let remaining = orphanStacks.filter { !$0.order.isEmpty }
                workspace.screens[orphanKey] = remaining.isEmpty ? nil : remaining
            }
            state.workspaces[workspaceID] = workspace
        }
    }

    private static func reflowActive(
        _ state: inout TilesSession,
        snapshot: WindowSnapshot,
        layouts: LayoutSnapshot,
        mutationID: MutationID,
        effects: inout [WindowEffect]
    ) {
        let active = state.activeWorkspace
        for (token, managed) in state.windows where managed.workspace == active {
            guard managed.visibility == .visible,
                  let entry = snapshot.windows[token], entry.isAvailableForPlacement,
                  let frame = layouts.frame(for: managed.tile) else { continue }
            if !RecoveryModel.compatibleFrame(entry.frame, with: frame, tolerance: 1) {
                effects.append(.setFrame(token, frame, mutationID))
                state.windows[token]?.lastAppliedFrame = frame
            }
        }
    }

    // MARK: - Adoption and reconciliation

    private static func adoptVisible(
        _ state: inout TilesSession,
        tokens: Set<WindowToken>?,
        snapshot: WindowSnapshot,
        layouts: LayoutSnapshot,
        mutationID: MutationID,
        effects: inout [WindowEffect],
        selectNewlyAdopted: Bool = false
    ) {
        let entries = snapshot.eligible
            .filter { tokens?.contains($0.token) ?? true }
            .filter(\.isAvailableForPlacement)
            .sorted {
                if $0.screenKey != $1.screenKey { return $0.screenKey < $1.screenKey }
                if $0.frame.minX != $1.frame.minX { return $0.frame.minX < $1.frame.minX }
                if $0.frame.minY != $1.frame.minY { return $0.frame.minY < $1.frame.minY }
                return $0.token.rawValue.uuidString < $1.token.rawValue.uuidString
            }

        for entry in entries where state.windows[entry.token] == nil {
            guard let leaves = layouts.screens[entry.screenKey], !leaves.isEmpty,
                  var workspace = state.workspaces[state.activeWorkspace] else { continue }
            if workspace.screens[entry.screenKey] == nil {
                workspace.screens[entry.screenKey] = leaves.map {
                    TileStack(address: $0.address(screenKey: entry.screenKey))
                }
            }
            guard var stacks = workspace.screens[entry.screenKey] else { continue }
            let focusedTile = focusedTile(in: state, snapshot: snapshot,
                                          screenKey: entry.screenKey)
            guard let destinationIndex = TileAllocator.destinationIndex(stacks: stacks,
                                                                          focusedTile: focusedTile)
            else { continue }

            let destination = stacks[destinationIndex].address
            let epoch = takeFocusEpoch(&state)
            let selectsNewWindow = selectNewlyAdopted || snapshot.focused == entry.token
            _ = stacks[destinationIndex].append(
                entry.token,
                selecting: selectsNewWindow,
                epoch: epoch)
            workspace.screens[entry.screenKey] = stacks
            state.workspaces[state.activeWorkspace] = workspace

            let frame = layouts.frame(for: destination) ?? entry.frame
            state.windows[entry.token] = ManagedWindow(
                token: entry.token,
                workspace: state.activeWorkspace,
                tile: destination,
                visibility: .visible,
                adoptionFrame: entry.frame,
                lastAppliedFrame: frame,
                focusEpoch: epoch)

            if entry.isReachable {
                effects.append(.setFrame(entry.token, frame, mutationID))
                if stacks[destinationIndex].selected == entry.token {
                    effects.append(.raise(entry.token, mutationID))
                }
                if selectsNewWindow {
                    effects.append(.focus(entry.token, mutationID))
                }
            }
        }
    }

    private static func reconcileExisting(
        _ state: inout TilesSession,
        snapshot: WindowSnapshot,
        layouts: LayoutSnapshot,
        mutationID: MutationID,
        effects: inout [WindowEffect]
    ) {
        for token in snapshot.goneTokens {
            removeToken(&state, token: token)
        }
        for token in state.windows.keys.sorted(by: { $0.rawValue.uuidString < $1.rawValue.uuidString }) {
            guard let entry = snapshot.windows[token], var managed = state.windows[token] else { continue }
            if entry.isMinimized {
                if managed.visibility == .visible {
                    managed.visibility = .minimizedByUser
                    state.windows[token] = managed
                }
                continue
            }
            if managed.visibility == .minimizedByUser, entry.isVisible {
                managed.visibility = .visible
                let epoch = takeFocusEpoch(&state)
                managed.focusEpoch = epoch
                state.windows[token] = managed
                select(&state, token: token, epoch: epoch)
                if managed.workspace == state.activeWorkspace, entry.isReachable {
                    let frame = layouts.frame(for: managed.tile) ?? entry.frame
                    effects.append(.setFrame(token, frame, mutationID))
                    effects.append(.raise(token, mutationID))
                    effects.append(.focus(token, mutationID))
                    state.windows[token]?.lastAppliedFrame = frame
                }
                continue
            }
            if managed.visibility == .visible,
               managed.workspace == state.activeWorkspace,
               entry.isReachable,
               let frame = layouts.frame(for: managed.tile),
               !RecoveryModel.compatibleFrame(entry.frame, with: frame, tolerance: 1) {
                effects.append(.setFrame(token, frame, mutationID))
                state.windows[token]?.lastAppliedFrame = frame
            }
        }
    }

    // MARK: - Focus and cycle

    private static func focus(
        _ state: inout TilesSession,
        token: WindowToken,
        snapshot: WindowSnapshot,
        layouts: LayoutSnapshot,
        mutationID: MutationID,
        effects: inout [WindowEffect],
        external: Bool
    ) {
        if state.windows[token] == nil {
            adoptVisible(&state, tokens: [token], snapshot: snapshot, layouts: layouts,
                         mutationID: mutationID, effects: &effects)
        }
        guard let managed = state.windows[token] else { return }
        if external && managed.workspace != state.activeWorkspace {
            switchWorkspace(&state, to: managed.workspace, snapshot: snapshot, layouts: layouts,
                            mutationID: mutationID, effects: &effects, forcedFocus: token)
            return
        }
        guard managed.workspace == state.activeWorkspace else { return }
        let epoch = takeFocusEpoch(&state)
        state.windows[token]?.focusEpoch = epoch
        select(&state, token: token, epoch: epoch)
        guard snapshot.windows[token]?.isReachable ?? true else { return }
        effects.append(.raise(token, mutationID))
        effects.append(.focus(token, mutationID))
    }

    /// Focus the nearest usable stack in a cardinal direction.  Geometry is
    /// resolved from the raw Zones rectangles; spacing is only a presentation
    /// concern and must not alter navigation.  Empty stacks and stacks whose
    /// members are unavailable are skipped while preserving the resolver's
    /// deterministic ranking.
    private static func focusTile(
        _ state: inout TilesSession,
        direction: TileDirection,
        snapshot: WindowSnapshot,
        layouts: LayoutSnapshot,
        mutationID: MutationID,
        effects: inout [WindowEffect]
    ) {
        guard let focused = snapshot.focused,
              snapshot.windows[focused]?.isAvailableForPlacement == true,
              let current = state.windows[focused],
              current.workspace == state.activeWorkspace,
              let workspace = state.workspaces[state.activeWorkspace] else { return }

        let candidates = TileNavigation.candidates(from: current.tile,
                                                   direction: direction,
                                                   in: layouts)
        guard let target = candidates.first(where: { address in
            guard let stack = workspace.stack(for: address) else { return false }
            return stack.order.contains { token in
                snapshot.windows[token]?.isAvailableForPlacement == true
            }
        }),
        let stack = workspace.stack(for: target) else { return }

        // A stack's selected member is its visible representative.  Keep that
        // choice when it is still usable; only fall back to stable stack order
        // when the selected window is unavailable.
        let token = stack.selected.flatMap { selected in
            snapshot.windows[selected]?.isAvailableForPlacement == true ? selected : nil
        } ?? stack.order.first(where: { candidate in
            snapshot.windows[candidate]?.isAvailableForPlacement == true
        })
        guard let token else { return }

        let epoch = takeFocusEpoch(&state)
        state.windows[token]?.focusEpoch = epoch
        select(&state, token: token, epoch: epoch)

        // Availability above includes reachability.  Keep the guard explicit
        // so this function never emits effects for a window that disappeared
        // between snapshot construction and planning.
        guard snapshot.windows[token]?.isReachable == true else { return }
        effects.append(.raise(token, mutationID))
        effects.append(.focus(token, mutationID))
    }

    private static func cycleFocusedTile(
        _ state: inout TilesSession,
        direction: TileCycleDirection,
        snapshot: WindowSnapshot,
        mutationID: MutationID,
        effects: inout [WindowEffect]
    ) {
        guard let focused = snapshot.focused,
              let managed = state.windows[focused],
              managed.workspace == state.activeWorkspace,
              let location = locate(state, token: focused),
              let stack = state.workspaces[location.workspace]?.screens[location.screen]?[location.index]
        else { return }

        let eligible = Set(stack.order.filter { token in
            guard let entry = snapshot.windows[token] else { return false }
            return entry.isAvailableForPlacement
        })
        // The live focused window is authoritative for the first cycle press;
        // the model's selected member can lag while an AX focus notification
        // is settling.
        guard let target = TileCycle.next(order: stack.order,
                                         selected: focused,
                                         direction: direction,
                                         eligible: eligible) else { return }
        let epoch = takeFocusEpoch(&state)
        state.windows[target]?.focusEpoch = epoch
        select(&state, token: target, epoch: epoch)
        guard snapshot.windows[target]?.isReachable ?? true else { return }
        effects.append(.raise(target, mutationID))
        effects.append(.focus(target, mutationID))
    }

    // MARK: - Workspace transitions

    private static func switchWorkspace(
        _ state: inout TilesSession,
        to destination: WorkspaceID,
        snapshot: WindowSnapshot,
        layouts: LayoutSnapshot,
        mutationID: MutationID,
        effects: inout [WindowEffect],
        forcedFocus: WindowToken? = nil
    ) {
        guard destination.isValid, destination != state.activeWorkspace else { return }
        let source = state.activeWorkspace

        if let forcedFocus,
           let managed = state.windows[forcedFocus], managed.workspace == destination {
            let epoch = takeFocusEpoch(&state)
            state.windows[forcedFocus]?.focusEpoch = epoch
            select(&state, token: forcedFocus, epoch: epoch)
        }

        // A staged destination can be on another native macOS Space. Restoring
        // one such window is a barrier because the public AX call may switch
        // Spaces and invalidate the rest of this snapshot. The coordinator
        // commits this ownership change, takes a fresh snapshot, and repeats
        // the same workspace action before any source window is staged.
        for stack in state.workspaces[destination]?.allStacks ?? [] {
            for token in stack.order {
                guard state.windows[token]?.visibility == .stagedByTiles,
                      let entry = snapshot.windows[token],
                      !entry.isMinimized, !entry.isReachable else { continue }
                effects.append(.setMinimized(token, false, mutationID))
                state.windows[token]?.visibility = .visible
                return
            }
        }

        // Destination effects are ordered first, so a successful transition
        // never needs to make the desktop empty.  User-minimized windows are
        // deliberately excluded from restoration.
        for stack in state.workspaces[destination]?.allStacks ?? [] {
            // Every member of a destination stack shares the current tile
            // frame.  Only the selected member is raised below.
            for token in stack.order {
                guard let managed = state.windows[token],
                      managed.visibility != .minimizedByUser else { continue }
                if managed.visibility == .stagedByTiles,
                   snapshot.windows[token] != nil {
                    effects.append(.setMinimized(token, false, mutationID))
                    state.windows[token]?.visibility = .visible
                }
                if let entry = snapshot.windows[token], entry.isReachable,
                   let frame = layouts.frame(for: managed.tile) {
                    effects.append(.setFrame(token, frame, mutationID))
                    state.windows[token]?.lastAppliedFrame = frame
                }
            }
        }

        // Raise each selected stack member, then focus only the most recently
        // focused member in the destination workspace.
        var focusCandidate: (token: WindowToken, epoch: UInt64, order: Int)?
        for (visualOrder, stack) in (state.workspaces[destination]?.allStacks ?? []).enumerated() {
            if let selected = stack.selected,
               let managed = state.windows[selected],
               managed.visibility != .minimizedByUser,
               snapshot.windows[selected]?.isReachable ?? false {
                // Avoid a duplicate raise if the frame loop already raised
                // this selected member.
                if !effects.contains(where: { $0 == .raise(selected, mutationID) }) {
                    effects.append(.raise(selected, mutationID))
                }
                let candidate = (token: selected, epoch: managed.focusEpoch, order: visualOrder)
                if focusCandidate == nil || candidate.epoch > focusCandidate!.epoch ||
                    (candidate.epoch == focusCandidate!.epoch && candidate.order > focusCandidate!.order) {
                    focusCandidate = candidate
                }
            }
        }
        if let forcedFocus,
           let entry = snapshot.windows[forcedFocus], entry.isReachable,
           state.windows[forcedFocus]?.workspace == destination {
            focusCandidate = (token: forcedFocus,
                              epoch: state.windows[forcedFocus]?.focusEpoch ?? 0,
                              order: Int.max)
        }
        if let focusCandidate {
            effects.append(.focus(focusCandidate.token, mutationID))
        }

        // Source staging happens after destination desminimization/frame work.
        for stack in state.workspaces[source]?.allStacks ?? [] {
            for token in stack.order {
                guard let managed = state.windows[token],
                      managed.visibility == .visible else { continue }
                if let entry = snapshot.windows[token], entry.isAvailableForPlacement {
                    effects.append(.setMinimized(token, true, mutationID))
                    state.windows[token]?.visibility = .stagedByTiles
                }
            }
        }
        state.activeWorkspace = destination
    }

    private static func moveFocusedWindow(
        _ state: inout TilesSession,
        to destination: WorkspaceID,
        snapshot: WindowSnapshot,
        mutationID: MutationID,
        effects: inout [WindowEffect]
    ) {
        guard destination.isValid, destination != state.activeWorkspace,
              let token = snapshot.focused,
              let entry = snapshot.windows[token], entry.isReachable,
              entry.isVisible, !entry.isMinimized,
              let managed = state.windows[token],
              managed.workspace == state.activeWorkspace,
              let location = locate(state, token: token),
              var sourceWorkspace = state.workspaces[location.workspace],
              var targetWorkspace = state.workspaces[destination]
        else { return }

        guard var sourceStacks = sourceWorkspace.screens[location.screen],
              location.index < sourceStacks.count,
              var targetStacks = targetWorkspace.screens[location.screen],
              let targetIndex = TileAllocator.destinationIndex(stacks: targetStacks, focusedTile: nil)
        else { return }

        _ = sourceStacks[location.index].remove(token)
        let targetAddress = targetStacks[targetIndex].address
        _ = targetStacks[targetIndex].append(token, selecting: true,
                                             epoch: takeFocusEpoch(&state))
        sourceWorkspace.screens[location.screen] = sourceStacks
        targetWorkspace.screens[location.screen] = targetStacks
        state.workspaces[location.workspace] = sourceWorkspace
        state.workspaces[destination] = targetWorkspace

        // The guard above rejects `destination == state.activeWorkspace`, so
        // the destination workspace is always inactive here and the window is
        // always staged rather than shown.
        state.windows[token]?.workspace = destination
        state.windows[token]?.tile = targetAddress
        state.windows[token]?.visibility = .stagedByTiles

        if snapshot.windows[token]?.isReachable ?? false {
            effects.append(.setMinimized(token, true, mutationID))
        }
    }

    /// Move the focused window to the nearest geometric tile in a cardinal
    /// direction.  The target is not filtered by occupancy: an empty tile is a
    /// valid destination and an occupied tile receives the window in its
    /// existing stack through the same placement mutation used by Zones.
    private static func moveFocusedWindowToTile(
        _ state: inout TilesSession,
        direction: TileDirection,
        snapshot: WindowSnapshot,
        layouts: LayoutSnapshot,
        mutationID: MutationID,
        effects: inout [WindowEffect]
    ) {
        guard let focused = snapshot.focused,
              let entry = snapshot.windows[focused],
              entry.isAvailableForPlacement,
              let managed = state.windows[focused],
              managed.workspace == state.activeWorkspace,
              let destination = TileNavigation.nearest(from: managed.tile,
                                                        direction: direction,
                                                        in: layouts),
              destination.id != managed.tile.id else { return }

        place(&state, token: focused, address: destination, snapshot: snapshot,
              layouts: layouts, mutationID: mutationID, effects: &effects)
    }

    // MARK: - Window and tile events

    private static func minimize(_ state: inout TilesSession, token: WindowToken, byUser: Bool) {
        guard state.windows[token] != nil else { return }
        state.windows[token]?.visibility = byUser ? .minimizedByUser : .stagedByTiles
    }

    private static func restore(
        _ state: inout TilesSession,
        token: WindowToken,
        snapshot: WindowSnapshot,
        layouts: LayoutSnapshot,
        mutationID: MutationID,
        effects: inout [WindowEffect]
    ) {
        guard let managed = state.windows[token],
              managed.workspace == state.activeWorkspace,
              managed.visibility == .minimizedByUser,
              let entry = snapshot.windows[token], !entry.isMinimized else { return }
        let epoch = takeFocusEpoch(&state)
        state.windows[token]?.visibility = .visible
        state.windows[token]?.focusEpoch = epoch
        select(&state, token: token, epoch: epoch)
        guard entry.isReachable else { return }
        let frame = layouts.frame(for: managed.tile) ?? entry.frame
        effects.append(.setFrame(token, frame, mutationID))
        effects.append(.raise(token, mutationID))
        effects.append(.focus(token, mutationID))
        state.windows[token]?.lastAppliedFrame = frame
    }

    private static func place(
        _ state: inout TilesSession,
        token: WindowToken,
        address: TileAddress,
        snapshot: WindowSnapshot,
        layouts: LayoutSnapshot,
        mutationID: MutationID,
        effects: inout [WindowEffect]
    ) {
        guard let managed = state.windows[token],
              managed.workspace == state.activeWorkspace,
              layouts.screens[address.screenKey]?.contains(where: { $0.index == address.leafIndex }) == true,
              let location = locate(state, token: token),
              var workspace = state.workspaces[state.activeWorkspace],
              var sourceStacks = workspace.screens[location.screen],
              var targetStacks = workspace.screens[address.screenKey]
        else { return }
        guard let sourceIndex = sourceStacks.firstIndex(where: { $0.contains(token) }),
              let targetIndex = targetStacks.firstIndex(where: { $0.address.id == address.id }) else { return }

        // A directional move can only target another leaf, but explicit Zone
        // placement may be asked to place a window in its current leaf.  Keep
        // that operation idempotent instead of perturbing stack order.
        guard sourceStacks[sourceIndex].address.id != targetStacks[targetIndex].address.id else {
            return
        }

        let destinationAddress: TileAddress
        let epoch = takeFocusEpoch(&state)
        if location.screen == address.screenKey {
            // Removing a window leaves its TileStack in place, so the target
            // index remains stable even when it follows the source.  Keep the
            // source's empty leaf in the layout rather than compacting tiles.
            _ = sourceStacks[sourceIndex].remove(token)
            destinationAddress = sourceStacks[targetIndex].address
            _ = sourceStacks[targetIndex].append(token, selecting: true, epoch: epoch)
            workspace.screens[location.screen] = sourceStacks
        } else {
            _ = sourceStacks[sourceIndex].remove(token)
            destinationAddress = targetStacks[targetIndex].address
            _ = targetStacks[targetIndex].append(token, selecting: true, epoch: epoch)
            workspace.screens[location.screen] = sourceStacks
            workspace.screens[address.screenKey] = targetStacks
        }
        state.workspaces[state.activeWorkspace] = workspace
        state.windows[token]?.tile = destinationAddress
        state.windows[token]?.visibility = .visible
        state.windows[token]?.focusEpoch = epoch
        select(&state, token: token, epoch: epoch)

        guard snapshot.windows[token]?.isReachable ?? true else { return }
        let frame = layouts.frame(for: destinationAddress) ?? snapshot.windows[token]?.frame ?? .zero
        effects.append(.setFrame(token, frame, mutationID))
        effects.append(.raise(token, mutationID))
        effects.append(.focus(token, mutationID))
        state.windows[token]?.lastAppliedFrame = frame
    }

    private static func detach(_ state: inout TilesSession, token: WindowToken) {
        removeToken(&state, token: token, removeManaged: true)
    }

    private static func removeToken(_ state: inout TilesSession,
                                    token: WindowToken,
                                    removeManaged: Bool = true) {
        for id in WorkspaceID.all {
            guard var workspace = state.workspaces[id] else { continue }
            for screen in workspace.screens.keys {
                guard var stacks = workspace.screens[screen] else { continue }
                for index in stacks.indices where stacks[index].contains(token) {
                    _ = stacks[index].remove(token)
                }
                workspace.screens[screen] = stacks
            }
            state.workspaces[id] = workspace
        }
        if removeManaged { state.windows.removeValue(forKey: token) }
    }

    // MARK: - Shared state helpers

    private static func locate(_ state: TilesSession, token: WindowToken)
        -> (workspace: WorkspaceID, screen: String, index: Int)? {
        for id in WorkspaceID.all {
            if let location = state.workspaces[id]?.location(of: token) {
                return (id, location.screenKey, location.index)
            }
        }
        return nil
    }

    private static func focusedTile(in state: TilesSession,
                                    snapshot: WindowSnapshot,
                                    screenKey: String) -> TileAddress? {
        guard let focused = snapshot.focused,
              let managed = state.windows[focused],
              managed.workspace == state.activeWorkspace,
              managed.tile.screenKey == screenKey else { return nil }
        return managed.tile
    }

    private static func select(_ state: inout TilesSession,
                               token: WindowToken,
                               epoch: UInt64? = nil) {
        guard let location = locate(state, token: token),
              var workspace = state.workspaces[location.workspace],
              var stacks = workspace.screens[location.screen],
              stacks.indices.contains(location.index) else { return }
        _ = stacks[location.index].select(token, epoch: epoch)
        workspace.screens[location.screen] = stacks
        state.workspaces[location.workspace] = workspace
    }

    private static func takeFocusEpoch(_ state: inout TilesSession) -> UInt64 {
        let result = state.nextFocusEpoch
        state.nextFocusEpoch = state.nextFocusEpoch == UInt64.max ? 0 : state.nextFocusEpoch + 1
        return result
    }

    private static func compensationEffects(for effects: [WindowEffect],
                                            state: TilesSession,
                                            snapshot: WindowSnapshot) -> [WindowEffect] {
        effects.reversed().compactMap { effect in
            switch effect {
            case let .setFrame(token, frame, mutationID):
                let previous = state.windows[token]?.lastAppliedFrame
                    ?? snapshot.windows[token]?.frame
                    ?? frame
                return .setFrame(token, previous, mutationID)
            case let .setMinimized(token, value, mutationID):
                guard let previous = snapshot.windows[token]?.isMinimized,
                      previous != value else { return nil }
                return .setMinimized(token, previous, mutationID)
            case .raise, .focus:
                return nil
            }
        }
    }
}

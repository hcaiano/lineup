import Foundation

/// Rebase stack assignments when Zones changes its leaves.  Geometry is
/// normalized per display, so this function does not need screen pixels and is
/// safe to run before any Accessibility effect is considered.
public enum LayoutRebase {
    /// Map old stacks to current leaves by normalized center and greatest
    /// intersection.  Every new leaf receives a stack, including empty
    /// siblings introduced by a split.  If several old stacks map to one leaf
    /// (a merge), their orders are concatenated in the supplied visual order.
    /// Duplicate tokens are ignored defensively; a valid session never has
    /// duplicates, but a rebase must not create new ones.
    public static func rebase(
        stacks: [TileStack],
        from oldLeaves: [NormalizedLeaf],
        to newLeaves: [NormalizedLeaf]
    ) -> [TileStack] {
        guard !newLeaves.isEmpty else { return stacks }

        // A layout can rotate or otherwise redraw the same leaves without
        // changing their identities.  In that case geometry is the only thing
        // that changed: preserve every stack by TileID, including its order,
        // selected member, and selection epoch.  The geometric matcher below
        // is reserved for real splits/merges where leaf identities differ.
        let fallbackScreenKey = stacks.first?.address.screenKey
            ?? oldLeaves.first(where: { !$0.screenKey.isEmpty })?.screenKey
            ?? newLeaves.first(where: { !$0.screenKey.isEmpty })?.screenKey
            ?? ""
        let oldIdentitySet = Set(oldLeaves.map {
            TileID(screenKey: $0.screenKey.isEmpty ? fallbackScreenKey : $0.screenKey,
                   leafIndex: $0.index)
        })
        let newIdentitySet = Set(newLeaves.map {
            TileID(screenKey: $0.screenKey.isEmpty ? fallbackScreenKey : $0.screenKey,
                   leafIndex: $0.index)
        })
        if !oldIdentitySet.isEmpty, oldIdentitySet == newIdentitySet {
            var oldStacksByID: [TileID: TileStack] = [:]
            for stack in stacks {
                oldStacksByID[stack.address.id] = stack
            }
            return newLeaves.map { leaf in
                let screen = leaf.screenKey.isEmpty ? fallbackScreenKey : leaf.screenKey
                let id = TileID(screenKey: screen, leafIndex: leaf.index)
                guard var stack = oldStacksByID[id] else {
                    return TileStack(address: TileAddress(id: id,
                                                          normalizedCenter: leaf.center))
                }
                stack.address = TileAddress(id: id, normalizedCenter: leaf.center)
                return stack
            }
        }

        struct Group {
            var address: TileAddress
            var orders: [[WindowToken]] = []
            var selections: [(token: WindowToken, epoch: UInt64, order: Int)] = []
        }

        var groups: [TileID: Group] = [:]

        for (stackOrder, stack) in stacks.enumerated() {
            guard let leaf = destinationLeaf(for: stack, oldLeaves: oldLeaves, newLeaves: newLeaves) else {
                continue
            }
            let screen = leaf.screenKey.isEmpty ? stack.address.screenKey : leaf.screenKey
            let id = TileID(screenKey: screen, leafIndex: leaf.index)
            let address = TileAddress(id: id, normalizedCenter: leaf.center)
            if groups[id] == nil {
                groups[id] = Group(address: address)
            }
            groups[id]?.orders.append(stack.order)
            if let selected = stack.selected {
                groups[id]?.selections.append((selected, stack.selectionEpoch, stackOrder))
            }
        }

        var result: [TileStack] = []
        result.reserveCapacity(newLeaves.count)
        for leaf in newLeaves {
            // A per-screen list may omit `screenKey`; preserve the screen key
            // from the old address where possible.
            let matchingID = TileID(screenKey: leaf.screenKey, leafIndex: leaf.index)
            let source: Group?
            if !leaf.screenKey.isEmpty {
                source = groups[matchingID]
            } else {
                source = groups.first(where: { $0.key.leafIndex == leaf.index })?.value
            }

            let screen = leaf.screenKey.isEmpty
                ? (source?.address.screenKey ?? stacks.first?.address.screenKey ?? "")
                : leaf.screenKey
            let address = TileAddress(
                id: TileID(screenKey: screen, leafIndex: leaf.index),
                normalizedCenter: leaf.center)

            guard let source else {
                result.append(TileStack(address: address))
                continue
            }

            var order: [WindowToken] = []
            for oldOrder in source.orders {
                for token in oldOrder where !order.contains(token) {
                    order.append(token)
                }
            }

            var selected: WindowToken?
            if !order.isEmpty, !source.selections.isEmpty {
                // A non-zero epoch is authoritative.  Epoch zero is used by
                // callers constructing fixtures, where the final selected
                // member in visual order is the deterministic best proxy.
                let maxEpoch = source.selections.map(\.epoch).max() ?? 0
                let candidates = source.selections.filter { $0.epoch == maxEpoch && order.contains($0.token) }
                selected = candidates.last?.token
            }
            if selected == nil { selected = order.first }
            result.append(TileStack(address: address, order: order,
                                    selected: selected,
                                    selectionEpoch: source.selections.map(\.epoch).max() ?? 0))
        }

        return result
    }

    private static func destinationLeaf(
        for stack: TileStack,
        oldLeaves: [NormalizedLeaf],
        newLeaves: [NormalizedLeaf]
    ) -> NormalizedLeaf? {
        let oldLeaf = oldLeaves.first {
            $0.index == stack.address.leafIndex &&
            ($0.screenKey.isEmpty || stack.address.screenKey.isEmpty || $0.screenKey == stack.address.screenKey)
        }
        // The address carries the center of the stack's previous leaf and is
        // the strongest signal for a split.  `oldLeaves` may be a structural
        // snapshot whose geometric center differs (for example after an
        // earlier merge), so it must not override the stack center.
        let center = stack.address.normalizedCenter

        let candidates = newLeaves.enumerated().filter { _, leaf in
            leaf.screenKey.isEmpty || stack.address.screenKey.isEmpty || leaf.screenKey == stack.address.screenKey
        }
        guard !candidates.isEmpty else { return nil }

        // A split should keep the old stack in the child containing its old
        // center.  Boundaries are shared by adjacent leaves; selecting the
        // first visual leaf at an exact boundary is stable and matches Zones'
        // leaf ordering.
        if let containing = candidates.first(where: { _, leaf in containsInclusive(leaf.rect, point: center) }) {
            return containing.element
        }

        if let oldRect = oldLeaf?.rect, !oldRect.isNull, oldRect.width > 0, oldRect.height > 0 {
            let intersections = candidates.map { offset, leaf -> (Int, NormalizedLeaf, CGFloat) in
                (offset, leaf, TileGeometry.intersectionArea(oldRect, leaf.rect))
            }
            if let best = intersections.max(by: { lhs, rhs in
                if lhs.2 != rhs.2 { return lhs.2 < rhs.2 }
                return lhs.0 > rhs.0
            }), best.2 > 0 {
                return best.1
            }
        }

        // If a normalized snapshot only has centers, use nearest center as a
        // deterministic and lossless fallback.
        return candidates.min { lhs, rhs in
            let ld = TileGeometry.distanceSquared(lhs.element.center, center)
            let rd = TileGeometry.distanceSquared(rhs.element.center, center)
            if ld != rd { return ld < rd }
            return lhs.offset < rhs.offset
        }?.element
    }

    private static func containsInclusive(_ rect: CGRect, point: CGPoint) -> Bool {
        guard !rect.isNull else { return false }
        return point.x >= rect.minX && point.x <= rect.maxX &&
            point.y >= rect.minY && point.y <= rect.maxY
    }
}

import Foundation

/// Deterministic placement policy for a new window.
///
/// The input order is the visual order supplied by Zones.  The allocator does
/// not sort by a dictionary key, because a screen's leaf order is semantic and
/// must survive identical x coordinates in stacked layouts.
public enum TileAllocator {
    /// Select the first empty tile.  If all tiles are occupied, select the
    /// focused tile when it belongs to `stacks`; otherwise select the shortest
    /// stack.  Ties always retain visual input order.  The index form is the
    /// only form, because every caller must also update the chosen stack.
    public static func destinationIndex(
        stacks: [TileStack],
        focusedTile: TileAddress?
    ) -> Int? {
        guard !stacks.isEmpty else { return nil }
        if let index = stacks.firstIndex(where: { $0.order.isEmpty }) { return index }
        if let focusedTile,
           let index = stacks.firstIndex(where: { $0.address.id == focusedTile.id }) {
            return index
        }
        return stacks.enumerated().min {
            if $0.element.order.count != $1.element.order.count {
                return $0.element.order.count < $1.element.order.count
            }
            return $0.offset < $1.offset
        }?.offset
    }
}
/// Stack cycling is independent of AX focus.  The shell supplies eligibility
/// from its latest immutable snapshot, so manually minimized windows can be
/// skipped without mutating the live model during discovery.
public enum TileCycle {
    /// Return the next eligible member with wrap-around.  Fewer than two
    /// eligible members is a no-op, as cycling a one-window tile has no useful
    /// effect.  If `selected` is unavailable, forward starts at the first and
    /// reverse starts at the last eligible member.
    public static func next(
        order: [WindowToken],
        selected: WindowToken?,
        direction: TileCycleDirection,
        eligible: Set<WindowToken>? = nil
    ) -> WindowToken? {
        let candidates = order.filter { eligible?.contains($0) ?? true }
        guard candidates.count >= 2 else { return nil }

        guard let selected, let current = candidates.firstIndex(of: selected) else {
            return direction == .forward ? candidates.first : candidates.last
        }
        switch direction {
        case .forward:
            return candidates[(current + 1) % candidates.count]
        case .reverse:
            return candidates[(current - 1 + candidates.count) % candidates.count]
        }
    }

    public static func next(
        in stack: TileStack,
        direction: TileCycleDirection,
        eligible: Set<WindowToken>? = nil
    ) -> WindowToken? {
        next(order: stack.order, selected: stack.selected, direction: direction, eligible: eligible)
    }
}

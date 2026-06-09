import Foundation

/// Pure tree-editing operations used by the layout editor. A `path` is a list of child
/// indices from the root (e.g. `[1, 0]` = first child of the second child). All operations
/// return a NEW tree and are no-ops on invalid input, so the editor can call them freely.
public extension Node {
    /// The node at `path`, or nil if the path doesn't resolve.
    func node(at path: [Int]) -> Node? {
        guard let first = path.first else { return self }
        guard case let .split(_, _, children) = self, children.indices.contains(first) else { return nil }
        return children[first].node(at: Array(path.dropFirst()))
    }

    /// A copy with the subtree at `path` replaced by `replacement`.
    func replacingNode(at path: [Int], with replacement: Node) -> Node {
        guard let first = path.first else { return replacement }
        guard case let .split(axis, dividers, children) = self, children.indices.contains(first) else { return self }
        var newChildren = children
        newChildren[first] = children[first].replacingNode(at: Array(path.dropFirst()), with: replacement)
        return .split(axis: axis, dividers: dividers, children: newChildren)
    }
}

public enum LayoutEdit {
    /// Split the LEAF at `path` into two equal children along `axis`. No-op on non-leaves.
    public static func split(_ root: Node, at path: [Int], axis: Axis) -> Node {
        guard case .leaf = root.node(at: path) else { return root }
        let newSplit = Node.split(axis: axis, dividers: [Boundary(0.5, .fraction)], children: [.leaf, .leaf])
        return root.replacingNode(at: path, with: newSplit)
    }

    /// Merge: collapse the split that is the PARENT of `path` back to a single leaf (undo a
    /// split). If `path` is the root and the root is a split, collapse the root. No-op if
    /// there's nothing to merge.
    public static func merge(_ root: Node, at path: [Int]) -> Node {
        if path.isEmpty {
            if case .split = root { return .leaf }
            return root
        }
        let parentPath = Array(path.dropLast())
        guard case .split = root.node(at: parentPath) else { return root }
        return root.replacingNode(at: parentPath, with: .leaf)
    }

    /// Set divider `index` of the split at `path` to `fraction` of its container. The root
    /// vertical split keeps PIXEL units (seam precision) using `rootPixelsWide`; every other
    /// split uses fractions. The fraction is clamped to (0.01, 0.99) AND kept strictly
    /// between its neighbors, so dragging one divider past an adjacent one can never reorder
    /// the stored array relative to the sorted visual handles (which would make handles jump
    /// and resize the wrong boundary).
    /// `containerLength` (points along the split axis) lets `.points`-unit neighbors — legal
    /// on a root vertical split per `Node.validate`, so a hand-authored config may carry them —
    /// be normalized for clamping too. The on-screen editor passes its handle's container size;
    /// callers without geometry omit it (those flows never store points).
    public static func setDivider(_ root: Node, at path: [Int], index: Int, fraction: Double,
                                  rootPixelsWide: Int, containerLength: Double? = nil) -> Node {
        guard case let .split(axis, dividers, children) = root.node(at: path),
              dividers.indices.contains(index) else { return root }
        let isRootVertical = path.isEmpty && axis == .vertical
        // Express a sibling boundary as a fraction-of-container so neighbor clamping works
        // regardless of unit (root vertical stores pixels; nested/horizontal store fractions;
        // a root vertical split may also carry absolute points).
        func siblingFraction(_ b: Boundary) -> Double? {
            switch b.unit {
            case .fraction: return b.value
            case .pixels:   return rootPixelsWide > 0 ? b.value / Double(rootPixelsWide) : nil
            case .points:
                guard let len = containerLength, len > 0 else { return nil }
                return b.value / len
            }
        }
        let gap = 0.01
        var lower = 0.01, upper = 0.99
        if index > 0, let lf = siblingFraction(dividers[index - 1]) { lower = max(lower, lf + gap) }
        if index < dividers.count - 1, let uf = siblingFraction(dividers[index + 1]) { upper = min(upper, uf - gap) }
        if lower > upper { let mid = (lower + upper) / 2; lower = mid; upper = mid } // neighbors too close
        let f = min(max(fraction, lower), upper)
        let newBoundary: Boundary = isRootVertical
            ? Boundary(Double(Int((f * Double(rootPixelsWide)).rounded())), .pixels)
            : Boundary(f, .fraction)
        var newDividers = dividers
        newDividers[index] = newBoundary
        return root.replacingNode(at: path, with: .split(axis: axis, dividers: newDividers, children: children))
    }
}

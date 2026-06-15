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
    ///
    /// Every OTHER line stays exactly where it is. Moving a divider only resizes the two
    /// zones it touches; if an adjacent child is itself split, its inner lines are anchored
    /// in place (their fractions are recomputed for the child's new size) so they don't slide.
    /// The drag also stops at the nearest inner line, never crossing it — the same rule that
    /// already keeps flat sibling dividers from reordering.
    ///
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
        let leftEdge = index > 0 ? (siblingFraction(dividers[index - 1]) ?? 0) : 0
        let rightEdge = index < dividers.count - 1 ? (siblingFraction(dividers[index + 1]) ?? 1) : 1
        let oldX = siblingFraction(dividers[index])
        var lower = max(0.01, leftEdge + gap)
        var upper = min(0.99, rightEdge - gap)
        // Also stop at the nearest inner line of either adjacent child, so the drag can't push
        // a nested line out of its container (which would otherwise drag that line along). Each
        // child spans from the dragged line to its outer neighbour, so measure lines there.
        if let oldX {
            if let near = sameAxisLines(children[index], axis: axis, lo: leftEdge, hi: oldX).max() {
                lower = max(lower, near + gap)
            }
            if let near = sameAxisLines(children[index + 1], axis: axis, lo: oldX, hi: rightEdge).min() {
                upper = min(upper, near - gap)
            }
        }
        if lower > upper { let mid = (lower + upper) / 2; lower = mid; upper = mid } // neighbors too close
        let f = min(max(fraction, lower), upper)
        let newBoundary: Boundary = isRootVertical
            ? Boundary(Double(Int((f * Double(rootPixelsWide)).rounded())), .pixels)
            : Boundary(f, .fraction)
        var newDividers = dividers
        newDividers[index] = newBoundary

        // Anchor the inner lines of the two touched children: as each child's extent along
        // `axis` changes, recompute its same-axis dividers so their absolute positions hold.
        var newChildren = children
        if let oldX {
            newChildren[index] = anchorLines(children[index], axis: axis,
                                             from: (leftEdge, oldX), to: (leftEdge, f))
            newChildren[index + 1] = anchorLines(children[index + 1], axis: axis,
                                                 from: (oldX, rightEdge), to: (f, rightEdge))
        }
        return root.replacingNode(at: path, with: .split(axis: axis, dividers: newDividers, children: newChildren))
    }

    /// Absolute positions (in the same coords as `lo`/`hi`) of every divider line inside
    /// `node` that runs along `axis`, at any nesting depth. A same-axis split contributes its
    /// own lines; a cross-axis split passes the extent straight through (its dividers run the
    /// other way, so a change along `axis` never moves them). Nested same-axis dividers are
    /// always `.fraction` (only the root vertical split may carry pixels/points), so reading
    /// `.value` as a fraction of the child's extent is exact here.
    private static func sameAxisLines(_ node: Node, axis: Axis, lo: Double, hi: Double) -> [Double] {
        guard case let .split(splitAxis, dividers, children) = node else { return [] }
        let len = hi - lo
        guard len > 0 else { return [] }
        if splitAxis != axis {
            return children.flatMap { sameAxisLines($0, axis: axis, lo: lo, hi: hi) }
        }
        let lines = dividers.map { lo + $0.value * len }
        let edges = [lo] + lines + [hi]
        var out = lines
        for i in children.indices {
            out += sameAxisLines(children[i], axis: axis, lo: edges[i], hi: edges[i + 1])
        }
        return out
    }

    /// Rescale `node` so that, as its extent along `axis` moves from `old` to `new` (one end
    /// fixed), every same-axis line inside it keeps its absolute position. Same-axis splits get
    /// their fraction dividers recomputed against the new extent and recurse per child sub-range;
    /// cross-axis splits hand the whole extent change to every child (their own dividers, running
    /// the other way, don't move). Leaves are returned unchanged.
    private static func anchorLines(_ node: Node, axis: Axis,
                                    from old: (lo: Double, hi: Double),
                                    to new: (lo: Double, hi: Double)) -> Node {
        guard case let .split(splitAxis, dividers, children) = node else { return node }
        if splitAxis != axis {
            let kids = children.map { anchorLines($0, axis: axis, from: old, to: new) }
            return .split(axis: splitAxis, dividers: dividers, children: kids)
        }
        let oldLen = old.hi - old.lo, newLen = new.hi - new.lo
        guard oldLen > 0, newLen > 0 else { return node }
        let absLines = dividers.map { old.lo + $0.value * oldLen }     // nested same-axis -> .fraction
        let newDividers = absLines.map { Boundary(($0 - new.lo) / newLen, .fraction) }
        let oldEdges = [old.lo] + absLines + [old.hi]
        let newEdges = [new.lo] + absLines + [new.hi]                  // interior lines preserved
        var kids: [Node] = []
        for i in children.indices {
            kids.append(anchorLines(children[i], axis: axis,
                                    from: (oldEdges[i], oldEdges[i + 1]),
                                    to: (newEdges[i], newEdges[i + 1])))
        }
        return .split(axis: splitAxis, dividers: newDividers, children: kids)
    }
}

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
    /// split uses fractions. Fraction is clamped to (0.01, 0.99).
    public static func setDivider(_ root: Node, at path: [Int], index: Int, fraction: Double, rootPixelsWide: Int) -> Node {
        guard case let .split(axis, dividers, children) = root.node(at: path),
              dividers.indices.contains(index) else { return root }
        let f = min(max(fraction, 0.01), 0.99)
        let isRootVertical = path.isEmpty && axis == .vertical
        let newBoundary: Boundary = isRootVertical
            ? Boundary(Double(Int((f * Double(rootPixelsWide)).rounded())), .pixels)
            : Boundary(f, .fraction)
        var newDividers = dividers
        newDividers[index] = newBoundary
        return root.replacingNode(at: path, with: .split(axis: axis, dividers: newDividers, children: children))
    }
}

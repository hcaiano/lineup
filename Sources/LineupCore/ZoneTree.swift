import CoreGraphics
import Foundation

/// A split direction. `vertical` = columns side by side; `horizontal` = rows stacked.
public enum Axis: String, Codable {
    case vertical
    case horizontal
}

/// A recursive layout (PowerToys-style). A `leaf` is a final zone; a `split` divides its
/// container along `axis` by `dividers` into `children`, each itself a node. The set of
/// leaves are the snap zones.
///
/// `dividers.count == children.count - 1`. Divider values are distances from the reading
/// start of the axis (left for vertical, top for horizontal). Physical `.pixels` are
/// valid only at the root vertical split (the seams); nested/horizontal splits use
/// `.fraction` of their parent.
public indirect enum Node: Equatable {
    case leaf
    case split(axis: Axis, dividers: [Boundary], children: [Node])
}

// Stable, hand-readable JSON via a "type" discriminator.
extension Node: Codable {
    private enum CodingKeys: String, CodingKey { case type, axis, dividers, children }
    private enum Kind: String, Codable { case leaf, split }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(Kind.self, forKey: .type) {
        case .leaf:
            self = .leaf
        case .split:
            self = .split(
                axis: try c.decode(Axis.self, forKey: .axis),
                dividers: try c.decode([Boundary].self, forKey: .dividers),
                children: try c.decode([Node].self, forKey: .children))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .leaf:
            try c.encode(Kind.leaf, forKey: .type)
        case let .split(axis, dividers, children):
            try c.encode(Kind.split, forKey: .type)
            try c.encode(axis, forKey: .axis)
            try c.encode(dividers, forKey: .dividers)
            try c.encode(children, forKey: .children)
        }
    }
}

// MARK: - Validation

public enum LayoutError: Error, Equatable {
    /// A split must have >= 2 children and exactly `children.count - 1` dividers.
    case arity(dividers: Int, children: Int)
    /// Absolute units (.points/.pixels) are allowed ONLY on the root vertical split (the
    /// physical seams). Every nested split and every horizontal split must be fraction-only.
    case illegalUnit(axis: Axis, isRoot: Bool)
}

extension Node {
    /// Validate the tree's structure and unit rules. The resolver assumes valid input, so
    /// validation happens at the edges (config load + before save). `isRoot` is true only
    /// for the top node.
    public func validate(isRoot: Bool = true) throws {
        switch self {
        case .leaf:
            return
        case let .split(axis, dividers, children):
            guard children.count >= 2, dividers.count == children.count - 1 else {
                throw LayoutError.arity(dividers: dividers.count, children: children.count)
            }
            let absoluteAllowed = isRoot && axis == .vertical
            if !absoluteAllowed, dividers.contains(where: { $0.unit != .fraction }) {
                throw LayoutError.illegalUnit(axis: axis, isRoot: isRoot)
            }
            for child in children { try child.validate(isRoot: false) }
        }
    }
}

// MARK: - Seed layouts

extension Node {
    /// A vertical (columns) split from a list of dividers, all leaves.
    public static func columns(_ dividers: [Boundary]) -> Node {
        .split(axis: .vertical, dividers: dividers,
               children: Array(repeating: .leaf, count: dividers.count + 1))
    }

    /// Default seed for a new/unconfigured screen.
    public static var halves: Node { columns([Boundary(0.5, .fraction)]) }
    public static var thirds: Node { columns([Boundary(1.0 / 3.0, .fraction), Boundary(2.0 / 3.0, .fraction)]) }
}

// MARK: - Resolver

public enum Layout {
    /// The root container: full frame width (so columns land on physical seams) and the
    /// usable `visibleFrame` height (so zones never slide under the menu bar / Dock).
    public static func rootContainer(frame: CGRect, visibleFrame: CGRect) -> CGRect {
        CGRect(x: frame.minX, y: visibleFrame.minY, width: frame.width, height: visibleFrame.height)
    }

    /// All leaf zone rects in semantic visual order: a vertical split visits children
    /// left→right, a horizontal split visits top→bottom, recursing. For the canonical
    /// "left half + right-stacked" tree this yields [Left, Right-Top, Right-Bottom].
    public static func zones(_ root: Node, container: CGRect, pixelsWide: Int) -> [CGRect] {
        switch root {
        case .leaf:
            return [container]
        case let .split(axis, dividers, children):
            let rects = childRects(axis: axis, dividers: dividers,
                                   count: children.count, container: container, pixelsWide: pixelsWide)
            var out: [CGRect] = []
            for (child, rect) in zip(children, rects) {
                out.append(contentsOf: zones(child, container: rect, pixelsWide: pixelsWide))
            }
            return out
        }
    }

    /// Convenience: resolve zones for a screen.
    public static func zones(_ root: Node, frame: CGRect, visibleFrame: CGRect, pixelsWide: Int) -> [CGRect] {
        zones(root, container: rootContainer(frame: frame, visibleFrame: visibleFrame), pixelsWide: pixelsWide)
    }

    /// The index (Zone N-1) of the leaf containing a point, or nil if none.
    public static func zoneIndex(at point: CGPoint, root: Node, frame: CGRect, visibleFrame: CGRect, pixelsWide: Int) -> Int? {
        let rects = zones(root, frame: frame, visibleFrame: visibleFrame, pixelsWide: pixelsWide)
        return rects.firstIndex { $0.contains(point) }
    }

    /// The leaf rect at index `i` (0-based, semantic order), or nil if out of range.
    public static func zoneRect(index i: Int, root: Node, frame: CGRect, visibleFrame: CGRect, pixelsWide: Int) -> CGRect? {
        let rects = zones(root, frame: frame, visibleFrame: visibleFrame, pixelsWide: pixelsWide)
        return rects.indices.contains(i) ? rects[i] : nil
    }

    /// Sanitize raw pixel divider positions: clamp into `0...pixelsWide`, sort, and keep
    /// every column (including the two outer ones) at least `minColumn` pixels wide, so the
    /// seam overlay can't save a zero-width column. Pure so it's unit-tested.
    public static func clampPixelDividers(_ xs: [Double], pixelsWide: Int, minColumn: Double) -> [Double] {
        let maxX = Double(pixelsWide)
        let sorted = xs.map { Swift.min(Swift.max($0, 0), maxX) }.sorted()
        var out: [Double] = []
        var lower = minColumn
        for (i, x) in sorted.enumerated() {
            let remaining = Double(sorted.count - i - 1)
            let upper = maxX - minColumn * (remaining + 1)
            out.append(Swift.min(Swift.max(x, lower), Swift.max(lower, upper)))
            lower = out[i] + minColumn
        }
        return out
    }

    /// Leaf zones paired with their tree path (for the editor: click-to-select).
    public static func leaves(_ root: Node, container: CGRect, pixelsWide: Int, path: [Int] = []) -> [(path: [Int], rect: CGRect)] {
        switch root {
        case .leaf:
            return [(path, container)]
        case let .split(axis, dividers, children):
            let rects = childRects(axis: axis, dividers: dividers, count: children.count, container: container, pixelsWide: pixelsWide)
            var out: [(path: [Int], rect: CGRect)] = []
            for (i, child) in children.enumerated() where rects.indices.contains(i) {
                out += leaves(child, container: rects[i], pixelsWide: pixelsWide, path: path + [i])
            }
            return out
        }
    }

    /// A draggable divider handle: which split/divider it is, its axis, and the line's
    /// position + extent within the container (Cocoa coords) for hit-testing and dragging.
    public struct DividerHandle {
        public let path: [Int]
        public let index: Int
        public let axis: Axis
        /// The divider line as a thin rect (a vertical or horizontal sliver) for hit-testing.
        public let line: CGRect
        /// The container this divider lives in (used to convert a drag into a fraction).
        public let container: CGRect
    }

    public static func dividerHandles(_ root: Node, container: CGRect, pixelsWide: Int, path: [Int] = [], thickness: CGFloat = 8) -> [DividerHandle] {
        guard case let .split(axis, dividers, children) = root else { return [] }
        let rects = childRects(axis: axis, dividers: dividers, count: children.count, container: container, pixelsWide: pixelsWide)
        var out: [DividerHandle] = []
        // One handle per interior boundary (between consecutive children).
        for i in 0..<max(0, children.count - 1) where rects.indices.contains(i) {
            let line: CGRect
            if axis == .vertical {
                let x = rects[i].maxX
                line = CGRect(x: x - thickness / 2, y: container.minY, width: thickness, height: container.height)
            } else {
                let y = rects[i].minY // boundary between child i (top) and i+1 (below)
                line = CGRect(x: container.minX, y: y - thickness / 2, width: container.width, height: thickness)
            }
            out.append(DividerHandle(path: path, index: i, axis: axis, line: line, container: container))
        }
        for (i, child) in children.enumerated() where rects.indices.contains(i) {
            out += dividerHandles(child, container: rects[i], pixelsWide: pixelsWide, path: path + [i], thickness: thickness)
        }
        return out
    }

    /// The root's top-level column rects when the root is a vertical split (NOT recursed
    /// into nested zones), else nil. Used by quick actions (left/center/right) and the
    /// left/right cycle's first step so they honor the screen's seam-aligned columns.
    public static func rootColumns(_ root: Node, frame: CGRect, visibleFrame: CGRect, pixelsWide: Int) -> [CGRect]? {
        guard case let .split(.vertical, dividers, children) = root else { return nil }
        return childRects(axis: .vertical, dividers: dividers, count: children.count,
                          container: rootContainer(frame: frame, visibleFrame: visibleFrame), pixelsWide: pixelsWide)
    }

    /// Split a container into child rects, laid out in reading order (left→right for a
    /// vertical split, top→bottom for a horizontal one). Cocoa coords (origin bottom-left).
    private static func childRects(axis: Axis, dividers: [Boundary], count: Int, container: CGRect, pixelsWide: Int) -> [CGRect] {
        let isVertical = (axis == .vertical)
        let length = isVertical ? container.width : container.height
        let pixelsTotal = isVertical ? pixelsWide : 0  // pixels valid only on the (root) vertical axis

        let cuts = dividers
            .map { $0.distance(alongLength: length, pixelsTotal: pixelsTotal) }
            .map { min(max($0, 0), length) }
            .sorted()
        let segments = [0] + cuts + [length] // distances from reading start

        var rects: [CGRect] = []
        for i in 0..<min(count, segments.count - 1) {
            let a = segments[i], b = segments[i + 1]
            if isVertical {
                rects.append(CGRect(x: container.minX + a, y: container.minY,
                                    width: b - a, height: container.height))
            } else {
                // Reading start is the TOP (container.maxY); rows go downward.
                rects.append(CGRect(x: container.minX, y: container.maxY - b,
                                    width: container.width, height: b - a))
            }
        }
        return rects
    }
}

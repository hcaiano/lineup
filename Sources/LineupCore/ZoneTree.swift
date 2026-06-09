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

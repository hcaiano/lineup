import Foundation

/// A cardinal direction in the coordinate system used by display frames.
/// AppKit display coordinates grow upwards, so `up` means increasing Y.
public enum TileDirection: Equatable, Sendable {
    case left
    case right
    case up
    case down
}

/// Pure spatial navigation over the leaves supplied by Zones.
///
/// The resolver intentionally has no wrap-around and never crosses a display.
/// It ranks all candidates before choosing one, which is important for
/// irregular templates where repeatedly asking for a nearest neighbour would
/// otherwise make the answer depend on the order of intermediate calls.
public enum TileNavigation {
    /// Return all same-display leaves in deterministic nearest-first order.
    /// The source leaf is excluded.  Candidate centers must lie strictly in
    /// the requested half-plane.
    public static func candidates(from source: TileAddress,
                                  direction: TileDirection,
                                  in layouts: LayoutSnapshot) -> [TileAddress] {
        let leaves = layouts.leaves(for: source.screenKey)
        guard !leaves.isEmpty, let sourceFrame = layouts.rawFrame(for: source) else {
            return []
        }

        struct Ranked {
            let address: TileAddress
            let perpendicularOverlap: Bool
            let primaryEdgeDistance: CGFloat
            let perpendicularCenterDistance: CGFloat
            let totalDistance: CGFloat
        }

        let ranked = leaves.compactMap { leaf -> Ranked? in
            guard leaf.index != source.leafIndex,
                  leaf.screenKey.isEmpty || source.screenKey.isEmpty || leaf.screenKey == source.screenKey,
                  let frame = layouts.rawFrame(for: leaf.address(screenKey: source.screenKey)),
                  isInHalfPlane(frame: frame, relativeTo: sourceFrame, direction: direction) else {
                return nil
            }

            let address = leaf.address(screenKey: source.screenKey)
            return Ranked(address: address,
                          perpendicularOverlap: hasPerpendicularOverlap(sourceFrame, frame,
                                                                         direction: direction),
                          primaryEdgeDistance: primaryEdgeDistance(from: sourceFrame,
                                                                    to: frame,
                                                                    direction: direction),
                          perpendicularCenterDistance: perpendicularCenterDistance(
                            from: sourceFrame, to: frame, direction: direction),
                          totalDistance: distanceSquared(sourceFrame.midPoint, frame.midPoint))
        }

        return ranked.sorted { lhs, rhs in
            if lhs.perpendicularOverlap != rhs.perpendicularOverlap {
                return lhs.perpendicularOverlap && !rhs.perpendicularOverlap
            }
            if lhs.primaryEdgeDistance != rhs.primaryEdgeDistance {
                return lhs.primaryEdgeDistance < rhs.primaryEdgeDistance
            }
            if lhs.perpendicularCenterDistance != rhs.perpendicularCenterDistance {
                return lhs.perpendicularCenterDistance < rhs.perpendicularCenterDistance
            }
            if lhs.totalDistance != rhs.totalDistance {
                return lhs.totalDistance < rhs.totalDistance
            }
            if lhs.address.leafIndex != rhs.address.leafIndex {
                return lhs.address.leafIndex < rhs.address.leafIndex
            }
            return lhs.address.screenKey < rhs.address.screenKey
        }.map(\.address)
    }

    /// Return the nearest same-display leaf in the requested direction.
    public static func nearest(from source: TileAddress,
                               direction: TileDirection,
                               in layouts: LayoutSnapshot) -> TileAddress? {
        candidates(from: source, direction: direction, in: layouts).first
    }

    /// Readable alias for callers that model this operation as neighbour
    /// lookup rather than directional focus.
    public static func neighbor(of source: TileAddress,
                                direction: TileDirection,
                                in layouts: LayoutSnapshot) -> TileAddress? {
        nearest(from: source, direction: direction, in: layouts)
    }

    private static func isInHalfPlane(frame: CGRect,
                                      relativeTo source: CGRect,
                                      direction: TileDirection) -> Bool {
        switch direction {
        case .left: return frame.midX < source.midX
        case .right: return frame.midX > source.midX
        case .up: return frame.midY > source.midY
        case .down: return frame.midY < source.midY
        }
    }

    private static func hasPerpendicularOverlap(_ source: CGRect,
                                                _ candidate: CGRect,
                                                direction: TileDirection) -> Bool {
        switch direction {
        case .left, .right:
            return overlapLength(source.minY, source.maxY,
                                 candidate.minY, candidate.maxY) > 0
        case .up, .down:
            return overlapLength(source.minX, source.maxX,
                                 candidate.minX, candidate.maxX) > 0
        }
    }

    private static func primaryEdgeDistance(from source: CGRect,
                                             to candidate: CGRect,
                                             direction: TileDirection) -> CGFloat {
        switch direction {
        case .left:
            return max(0, source.minX - candidate.maxX)
        case .right:
            return max(0, candidate.minX - source.maxX)
        case .up:
            return max(0, candidate.minY - source.maxY)
        case .down:
            return max(0, source.minY - candidate.maxY)
        }
    }

    private static func perpendicularCenterDistance(from source: CGRect,
                                                     to candidate: CGRect,
                                                     direction: TileDirection) -> CGFloat {
        switch direction {
        case .left, .right:
            return abs(candidate.midY - source.midY)
        case .up, .down:
            return abs(candidate.midX - source.midX)
        }
    }

    private static func overlapLength(_ lhsMin: CGFloat, _ lhsMax: CGFloat,
                                     _ rhsMin: CGFloat, _ rhsMax: CGFloat) -> CGFloat {
        max(0, min(lhsMax, rhsMax) - max(lhsMin, rhsMin))
    }

    private static func distanceSquared(_ lhs: CGPoint, _ rhs: CGPoint) -> CGFloat {
        let dx = lhs.x - rhs.x
        let dy = lhs.y - rhs.y
        return dx * dx + dy * dy
    }
}

private extension CGRect {
    var midPoint: CGPoint { CGPoint(x: midX, y: midY) }
}

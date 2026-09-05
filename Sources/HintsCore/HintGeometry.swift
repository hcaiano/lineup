import Foundation

// Pure display-space geometry for Hints, local to HintsCore. HintsCore must not import
// CoreGraphics, so these primitives mirror the values AX/Presentation adapters hand over and
// keep every computation deterministic and testable without a display server.

public struct HintPoint: Hashable, Codable, Sendable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    public static let zero = HintPoint(x: 0, y: 0)
}

public struct HintSize: Hashable, Codable, Sendable {
    public var width: Double
    public var height: Double

    public init(width: Double, height: Double) {
        self.width = width
        self.height = height
    }

    public static let zero = HintSize(width: 0, height: 0)

    public var isZeroOrNegative: Bool { width <= 0 || height <= 0 }
}

public struct HintRect: Hashable, Codable, Sendable {
    public var origin: HintPoint
    public var size: HintSize

    public init(origin: HintPoint, size: HintSize) {
        self.origin = origin
        self.size = size
    }

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.init(origin: HintPoint(x: x, y: y), size: HintSize(width: width, height: height))
    }

    public var minX: Double { origin.x }
    public var minY: Double { origin.y }
    public var maxX: Double { origin.x + size.width }
    public var maxY: Double { origin.y + size.height }
    public var midX: Double { origin.x + size.width / 2 }
    public var midY: Double { origin.y + size.height / 2 }
    public var width: Double { size.width }
    public var height: Double { size.height }

    public var isEmpty: Bool { size.isZeroOrNegative }
    public var area: Double { max(0, size.width) * max(0, size.height) }

    public static let zero = HintRect(origin: .zero, size: .zero)

    /// Intersection; `nil` when there is no positive-area overlap.
    public func intersection(_ other: HintRect) -> HintRect? {
        let minX = Swift.max(self.minX, other.minX)
        let minY = Swift.max(self.minY, other.minY)
        let maxX = Swift.min(self.maxX, other.maxX)
        let maxY = Swift.min(self.maxY, other.maxY)
        guard maxX > minX, maxY > minY else { return nil }
        return HintRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// Positive overlap area with `other` (0 when disjoint).
    public func overlapArea(with other: HintRect) -> Double {
        intersection(other)?.area ?? 0
    }

    public func contains(_ point: HintPoint) -> Bool {
        point.x >= minX && point.x < maxX && point.y >= minY && point.y < maxY
    }

    /// Full containment of `other` (equal rects count as contained). Empty frames never
    /// contain or are considered handled by the caller's guards.
    public func contains(_ other: HintRect) -> Bool {
        guard !isEmpty, !other.isEmpty else { return false }
        return other.minX >= minX && other.maxX <= maxX && other.minY >= minY && other.maxY <= maxY
    }

    public func union(_ other: HintRect) -> HintRect {
        let minX = Swift.min(self.minX, other.minX)
        let minY = Swift.min(self.minY, other.minY)
        let maxX = Swift.max(self.maxX, other.maxX)
        let maxY = Swift.max(self.maxY, other.maxY)
        return HintRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}

/// Deterministic display assignment, validity classification, clamping, and label-anchor
/// inputs for the overlay lane. Pure: no display server, no CoreGraphics.
public enum HintRectValidity: Equatable, Sendable {
    case valid
    case nonFinite
    case nonPositiveSize
}

public enum HintOverlayGeometry {
    /// Non-finite coordinates are poison from any source; eligibility rejects them as
    /// invalid/off-screen. Progressive checks distinguish nonpositive size (empty) from
    /// non-finite values (invalid).
    public static func validity(of frame: HintRect) -> HintRectValidity {
        let finite = frame.origin.x.isFinite && frame.origin.y.isFinite
            && frame.size.width.isFinite && frame.size.height.isFinite
        if !finite { return .nonFinite }
        if frame.size.isZeroOrNegative { return .nonPositiveSize }
        return .valid
    }

    /// The display holding the largest overlap with `frame`. Ties keep the lowest display
    /// index. Frames with no positive overlap on any display return `nil` (disconnected or
    /// off-screen geometry), which eligibility treats as a rejection signal.
    public static func displayIndex(for frame: HintRect, screens: [HintRect]) -> Int? {
        if frame.isEmpty { return nil }
        var best: (index: Int, area: Double)?
        for (index, screen) in screens.enumerated() {
            let area = frame.overlapArea(with: screen)
            if area > 0 {
                if best == nil || area > best!.area {
                    best = (index, area)
                }
            }
        }
        return best?.index
    }

    /// Positive overlap area between a candidate frame and its assigned (or any) display.
    public static func onScreenArea(of frame: HintRect, in screen: HintRect) -> Double {
        frame.overlapArea(with: screen)
    }

    /// Shift `frame` so it lies fully inside `bounds`, preserving its size. If the frame is
    /// larger than `bounds` along an axis it is clamped to that axis' smaller extent (its
    /// size shrinks; the result never extends past the bounds).
    public static func clampedInside(_ frame: HintRect, in bounds: HintRect) -> HintRect {
        var size = frame.size
        size.width = Swift.min(size.width, bounds.size.width)
        size.height = Swift.min(size.height, bounds.size.height)
        var x = frame.origin.x
        var y = frame.origin.y
        if x < bounds.minX { x = bounds.minX }
        if y < bounds.minY { y = bounds.minY }
        if x + size.width > bounds.maxX { x = bounds.maxX - size.width }
        if y + size.height > bounds.maxY { y = bounds.maxY - size.height }
        if x < bounds.minX { x = bounds.minX } // degenerate: bounds smaller than size guards
        if y < bounds.minY { y = bounds.minY }
        return HintRect(origin: HintPoint(x: x, y: y), size: size)
    }

    /// Deterministic anchor point for a label drawn near the top-left of its candidate frame,
    /// clamped inside the owning display with a fixed inset. Negative display origins and
    /// straddling windows produce stable results because everything derives from the frame
    /// and the bounds alone.
    public static func labelAnchor(for frame: HintRect, in bounds: HintRect, inset: Double = 2) -> HintPoint {
        var x = frame.minX + inset
        var y = frame.minY + inset
        if x < bounds.minX + inset { x = bounds.minX + inset }
        if y < bounds.minY + inset { y = bounds.minY + inset }
        let maxX = bounds.maxX - inset
        let maxY = bounds.maxY - inset
        if x > maxX { x = maxX }
        if y > maxY { y = maxY }
        return HintPoint(x: x, y: y)
    }
}

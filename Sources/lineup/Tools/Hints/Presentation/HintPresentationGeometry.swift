import AppKit
import HintsCore

/// The explicit bridge between HintsCore's AX-style global coordinates (origin at the primary
/// display's top-left, y increasing downward) and AppKit's global/window coordinates (y increasing
/// upward). Keeping the conversion here prevents secondary-display origins from being applied
/// twice and makes the geometry inputs independently inspectable in Phase 5.
enum HintPresentationGeometry {
    static func accessibilityScreenFrame(from appKitFrame: NSRect, primaryMaxY: CGFloat) -> HintRect {
        HintRect(
            x: Double(appKitFrame.minX),
            y: Double(primaryMaxY - appKitFrame.maxY),
            width: Double(appKitFrame.width),
            height: Double(appKitFrame.height)
        )
    }

    static func localRect(from geometryRect: HintRect, in geometryBounds: HintRect) -> NSRect {
        NSRect(
            x: CGFloat(geometryRect.minX - geometryBounds.minX),
            y: CGFloat(geometryBounds.maxY - geometryRect.maxY),
            width: CGFloat(geometryRect.width),
            height: CGFloat(geometryRect.height)
        )
    }

    static func geometryRect(from localRect: NSRect, in geometryBounds: HintRect) -> HintRect {
        HintRect(
            x: geometryBounds.minX + Double(localRect.minX),
            y: geometryBounds.maxY - Double(localRect.maxY),
            width: Double(localRect.width),
            height: Double(localRect.height)
        )
    }

    static func safeGeometryBounds(
        screenFrame: NSRect,
        safeFrame: NSRect,
        geometryFrame: HintRect
    ) -> HintRect {
        HintRect(
            x: geometryFrame.minX + Double(safeFrame.minX - screenFrame.minX),
            y: geometryFrame.minY + Double(screenFrame.maxY - safeFrame.maxY),
            width: Double(safeFrame.width),
            height: Double(safeFrame.height)
        )
    }

    static func pixelAligned(_ rect: NSRect, scale: CGFloat) -> NSRect {
        let scale = max(scale, 1)
        let minX = (rect.minX * scale).rounded() / scale
        let minY = (rect.minY * scale).rounded() / scale
        let maxX = (rect.maxX * scale).rounded() / scale
        let maxY = (rect.maxY * scale).rounded() / scale
        return NSRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    static func approximatelyEqual(_ lhs: HintRect, _ rhs: HintRect, tolerance: Double = 1) -> Bool {
        abs(lhs.minX - rhs.minX) <= tolerance
            && abs(lhs.minY - rhs.minY) <= tolerance
            && abs(lhs.width - rhs.width) <= tolerance
            && abs(lhs.height - rhs.height) <= tolerance
    }
}

struct HintPresentationScreenDescriptor: Equatable {
    var geometryIndex: Int
    var screenNumber: UInt32
    var geometryFrame: HintRect
    var safeGeometryFrame: HintRect
    var panelFrame: NSRect
    var visibleLocalFrame: NSRect
    var backingScaleFactor: CGFloat
}

import Foundation
import CoreGraphics

/// ScreenCaptureKit takes display-local, top-left points and outputs pixels. AppKit selections
/// use global, bottom-left points. Never use the primary display's scale for another display.
public struct CaptureRegion: Equatable {
    public let sourceRect: CGRect
    public let pixelWidth: Int
    public let pixelHeight: Int

    public init?(selection: CGRect, displayFrame: CGRect, scale: CGFloat) {
        let values = [selection.origin.x, selection.origin.y, selection.width, selection.height,
                      displayFrame.origin.x, displayFrame.origin.y,
                      displayFrame.width, displayFrame.height, scale]
        guard values.allSatisfy(\.isFinite), scale > 0,
              displayFrame.width > 0, displayFrame.height > 0 else { return nil }
        let clipped = selection.standardized.intersection(displayFrame)
        guard !clipped.isNull, clipped.width >= 2, clipped.height >= 2 else { return nil }
        let left = floor((clipped.minX - displayFrame.minX) * scale)
        let top = floor((displayFrame.maxY - clipped.maxY) * scale)
        let right = ceil((clipped.maxX - displayFrame.minX) * scale)
        let bottom = ceil((displayFrame.maxY - clipped.minY) * scale)
        guard right - left < CGFloat(Int.max), bottom - top < CGFloat(Int.max) else { return nil }
        sourceRect = CGRect(x: left / scale, y: top / scale,
                            width: (right - left) / scale, height: (bottom - top) / scale)
        pixelWidth = Int(right - left)
        pixelHeight = Int(bottom - top)
    }
}

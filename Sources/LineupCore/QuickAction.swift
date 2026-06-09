import CoreGraphics

/// Edge-anchored "quick action" rects for the arrow shortcuts. These are NOT tree zones —
/// they're the Magnet-style directional behaviors. left/center/right honor the screen's
/// root columns when present (so they land on the seams); full/halves are simple fractions.
/// Cycling through fractions is layered on in a later phase; this resolves a single step.
public enum QuickAction {
    public static let ids = ["full", "left", "center", "right", "leftHalf", "rightHalf"]

    public static func rect(_ id: String, root: Node, frame: CGRect, visibleFrame: CGRect, pixelsWide: Int) -> CGRect? {
        let c = Layout.rootContainer(frame: frame, visibleFrame: visibleFrame)
        func frac(_ a: CGFloat, _ b: CGFloat) -> CGRect {
            CGRect(x: c.minX + a * c.width, y: c.minY, width: (b - a) * c.width, height: c.height)
        }
        let cols = Layout.rootColumns(root, frame: frame, visibleFrame: visibleFrame, pixelsWide: pixelsWide)

        switch id {
        case "full": return c
        case "leftHalf": return frac(0, 0.5)
        case "rightHalf": return frac(0.5, 1)
        case "left": return cols?.first ?? frac(0, 0.5)
        case "right": return cols?.last ?? frac(0.5, 1)
        case "center":
            if let cols, !cols.isEmpty { return cols[cols.count / 2] }
            return frac(0.25, 0.75)
        default:
            return nil
        }
    }
}

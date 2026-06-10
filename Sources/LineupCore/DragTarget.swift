import CoreGraphics

/// Resolves what a shift-drag should snap to, so one column can host two apps stacked
/// without editing the layout: the cursor in a zone's top or bottom 10% edge band targets
/// that HALF of the zone; the middle 80% targets the whole zone, keeping the common case
/// untouched. The highlight previews the target live, so crossing a band is self-evident.
/// Pure and tested; the AppKit drag controller just feeds it points.
public enum DragTarget {
    public static let defaultEdgeBand: CGFloat = 0.10

    /// `zone` and `cursor` are Cocoa coordinates (+y up).
    public static func rect(zone: CGRect, cursor: CGPoint,
                            edgeBand: CGFloat = DragTarget.defaultEdgeBand) -> CGRect {
        let half = zone.height / 2
        let band = zone.height * max(0, min(edgeBand, 0.5))
        if cursor.y >= zone.maxY - band {
            return CGRect(x: zone.minX, y: zone.midY, width: zone.width, height: half)  // top half
        }
        if cursor.y <= zone.minY + band {
            return CGRect(x: zone.minX, y: zone.minY, width: zone.width, height: half)  // bottom half
        }
        return zone
    }
}

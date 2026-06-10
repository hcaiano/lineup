import CoreGraphics

/// Resolves what a shift-drag should snap to, so complex arrangements come straight from
/// the drag with no layout editing: every edge of a zone has a 5% hot band. The top or
/// bottom band targets that vertical HALF, the left or right band targets that horizontal
/// half, and two bands at once (a corner) target that QUARTER. The middle of the zone
/// targets the whole zone, keeping the common case untouched. The highlight previews the
/// target live, so crossing a band is self-evident. Pure and tested; the AppKit drag
/// controller just feeds it points.
public enum DragTarget {
    public static let defaultEdgeBand: CGFloat = 0.05

    /// On a small zone, 5% is a sliver (a 200pt half-zone would get a 10pt band — about
    /// one mouse event at drag speed). Bands never shrink below this many points, and
    /// never grow past half the zone, so they stay hittable AND the middle stays open.
    public static let minBandPoints: CGFloat = 24

    /// `zone` and `cursor` are Cocoa coordinates (+y up). A cursor OUTSIDE the zone (the
    /// caller's nearest-zone fallback: menu bar, Dock gap, past the screen edge) always
    /// targets the whole zone — bands only mean something while you're actually inside.
    public static func rect(zone: CGRect, cursor: CGPoint,
                            edgeBand: CGFloat = DragTarget.defaultEdgeBand) -> CGRect {
        guard zone.contains(cursor) else { return zone }
        let band = max(0, min(edgeBand, 0.5))
        func points(_ dim: CGFloat) -> CGFloat {
            band > 0 ? min(max(dim * band, minBandPoints), dim / 2) : 0
        }
        let vBand = points(zone.height)
        let hBand = points(zone.width)
        let top = cursor.y >= zone.maxY - vBand
        let bottom = !top && cursor.y <= zone.minY + vBand
        let left = cursor.x <= zone.minX + hBand
        let right = !left && cursor.x >= zone.maxX - hBand

        var r = zone
        if top { r.origin.y = zone.midY; r.size.height = zone.height / 2 }
        if bottom { r.size.height = zone.height / 2 }
        if left { r.size.width = zone.width / 2 }
        if right { r.origin.x = zone.midX; r.size.width = zone.width / 2 }
        return r
    }
}

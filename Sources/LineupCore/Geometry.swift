import CoreGraphics

/// Coordinate-system conversions between Cocoa/AppKit space and Accessibility/CG space.
///
/// - **Cocoa space** (NSScreen / NSWindow): origin bottom-left, +Y points **up**,
///   one global plane spanning all displays.
/// - **AX space** (AXUIElement position/size, CGEvent, CGDisplay): origin top-left,
///   +Y points **down**, measured from the **primary** display's top edge.
///
/// Rule we enforce everywhere: do all layout math in Cocoa space, then flip exactly
/// once at the AX read/write boundary. `primaryMaxY` is `NSScreen.screens[0].frame.maxY`.
public enum Coord {

    /// Cocoa global rect -> AX global rect (the values you hand to kAXPosition/kAXSize).
    public static func axRect(fromCocoa rect: CGRect, primaryMaxY: CGFloat) -> CGRect {
        // In Cocoa, rect.maxY is the window's TOP edge. AX y is the distance from the
        // primary display's top down to that top edge.
        let axY = primaryMaxY - rect.maxY
        return CGRect(x: rect.origin.x, y: axY, width: rect.width, height: rect.height)
    }

    /// AX global rect -> Cocoa global rect (use after reading a window's AX frame).
    /// Note the transform is its own inverse: same formula in both directions.
    public static func cocoaRect(fromAX rect: CGRect, primaryMaxY: CGFloat) -> CGRect {
        let cocoaY = primaryMaxY - rect.maxY
        return CGRect(x: rect.origin.x, y: cocoaY, width: rect.width, height: rect.height)
    }
}

/// Placement for windows that can't take the zone's size: non-resizable windows
/// (Terminal's grid snap, fixed dialogs) and apps whose minimum size beats the zone.
/// Instead of leaving them half-applied wherever the resize gave up, center what the
/// window actually is inside the zone — then nudge it back inside `bounds` (the screen's
/// visible frame) so a too-big window near a screen edge never hangs off-screen. A size
/// larger than `bounds` itself centers its overflow.
public enum FixedPlacement {
    public static func center(size: CGSize, in zone: CGRect, boundedBy bounds: CGRect) -> CGRect {
        func axis(_ zoneMid: CGFloat, _ length: CGFloat, _ lo: CGFloat, _ hi: CGFloat) -> CGFloat {
            let centered = zoneMid - length / 2
            guard length <= hi - lo else { return (lo + hi) / 2 - length / 2 }
            return min(max(centered, lo), hi - length)
        }
        return CGRect(x: axis(zone.midX, size.width, bounds.minX, bounds.maxX),
                      y: axis(zone.midY, size.height, bounds.minY, bounds.maxY),
                      width: size.width, height: size.height)
    }
}

/// Pick the display a window belongs to by maximum area of intersection, falling back
/// to the display nearest the window's center (handles windows dragged into gaps /
/// negative-origin secondary displays). All rects are Cocoa-space.
public enum ScreenPicker {

    public static func bestScreenIndex(forWindow window: CGRect, screens: [CGRect]) -> Int? {
        guard !screens.isEmpty else { return nil }

        var bestIdx = 0
        var bestArea: CGFloat = -1
        for (i, s) in screens.enumerated() {
            let inter = s.intersection(window)
            let area = inter.isNull ? 0 : inter.width * inter.height
            if area > bestArea {
                bestArea = area
                bestIdx = i
            }
        }
        if bestArea > 0 { return bestIdx }

        // No overlap: choose the screen whose center is closest to the window center.
        let wc = CGPoint(x: window.midX, y: window.midY)
        var nearest = 0
        var nearestDist = CGFloat.greatestFiniteMagnitude
        for (i, s) in screens.enumerated() {
            let sc = CGPoint(x: s.midX, y: s.midY)
            let d = (sc.x - wc.x) * (sc.x - wc.x) + (sc.y - wc.y) * (sc.y - wc.y)
            if d < nearestDist {
                nearestDist = d
                nearest = i
            }
        }
        return nearest
    }
}

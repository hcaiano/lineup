import CoreGraphics

public enum Side { case left, right }

/// State carried between successive presses of a cycling shortcut, so repeated Hyper+←
/// advances through widths instead of re-applying step 0.
public struct CycleState: Equatable {
    public var action: String       // "left" / "right"
    public var stepIndex: Int
    public var lastTime: Double      // seconds (monotonic-ish; app passes Date-based value)
    public var screenKey: String
    public var lastRect: CGRect

    public init(action: String, stepIndex: Int, lastTime: Double, screenKey: String, lastRect: CGRect) {
        self.action = action
        self.stepIndex = stepIndex
        self.lastTime = lastTime
        self.screenKey = screenKey
        self.lastRect = lastRect
    }
}

/// Left/right edge cycling. Step 0 honors the screen's root seam column; later steps are
/// generic anchored fractions (1/2, 1/3, 2/3). Consecutive duplicate rects are removed so
/// a halves layout doesn't make the first two presses look identical.
public enum Cycle {
    public static func steps(_ side: Side, root: Node, frame: CGRect, visibleFrame: CGRect, pixelsWide: Int) -> [CGRect] {
        let c = Layout.rootContainer(frame: frame, visibleFrame: visibleFrame)
        func frac(_ a: CGFloat, _ b: CGFloat) -> CGRect {
            CGRect(x: c.minX + a * c.width, y: c.minY, width: (b - a) * c.width, height: c.height)
        }
        let cols = Layout.rootColumns(root, frame: frame, visibleFrame: visibleFrame, pixelsWide: pixelsWide)

        let raw: [CGRect]
        switch side {
        case .left:
            raw = [cols?.first ?? frac(0, 0.5), frac(0, 0.5), frac(0, 1.0 / 3.0), frac(0, 2.0 / 3.0)]
        case .right:
            raw = [cols?.last ?? frac(0.5, 1), frac(0.5, 1), frac(2.0 / 3.0, 1), frac(1.0 / 3.0, 1)]
        }
        var out: [CGRect] = []
        for r in raw where (out.last.map { !approxEqual($0, r) } ?? true) {
            out.append(r)
        }
        return out
    }

    /// The step to apply now. Advances only if this is a genuine continuation of the prior
    /// press: same action, within `timeout`, same screen, and the focused window is still
    /// where we last put it (within `tolerance`). Otherwise resets to step 0.
    public static func nextStep(
        action: String, now: Double, screenKey: String, focusedFrame: CGRect,
        prev: CycleState?, stepCount: Int, timeout: Double = 1.5, tolerance: CGFloat = 4
    ) -> Int {
        guard stepCount > 0 else { return 0 }
        guard let p = prev,
              p.action == action,
              (now - p.lastTime) <= timeout,
              p.screenKey == screenKey,
              approxEqual(focusedFrame, p.lastRect, tolerance: tolerance)
        else { return 0 }
        return (p.stepIndex + 1) % stepCount
    }

    static func approxEqual(_ a: CGRect, _ b: CGRect, tolerance: CGFloat = 1) -> Bool {
        abs(a.minX - b.minX) <= tolerance && abs(a.minY - b.minY) <= tolerance &&
        abs(a.width - b.width) <= tolerance && abs(a.height - b.height) <= tolerance
    }
}

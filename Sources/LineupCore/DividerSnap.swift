import CoreGraphics
import Foundation

/// Photoshop-style guides for divider drags in the layout editor: near a common fraction
/// of the container (quarters, thirds, half) — or the position that makes the two zones
/// flanking the divider equal — the divider snaps onto it exactly and the editor shows
/// which guide grabbed it. Drag past the threshold and it lets go, so custom layouts stay
/// fully free. Pure and tested.
public enum DividerSnap {
    /// A guide the divider can lock onto. `label` is what the editor shows ("½", "⅓", "=").
    public struct Guide: Equatable {
        public let fraction: Double
        public let label: String
        public init(fraction: Double, label: String) {
            self.fraction = fraction
            self.label = label
        }
    }

    /// The result of nudging a proposed drag fraction against the guides.
    public struct Result: Equatable {
        public let fraction: Double      // what setDivider should receive
        public let guide: Guide?         // non-nil when locked onto a guide
        public init(fraction: Double, guide: Guide?) {
            self.fraction = fraction
            self.guide = guide
        }
    }

    /// The common-fraction guides every divider gets.
    public static let commonFractions: [Guide] = [
        Guide(fraction: 1.0 / 4.0, label: "¼"),
        Guide(fraction: 1.0 / 3.0, label: "⅓"),
        Guide(fraction: 1.0 / 2.0, label: "½"),
        Guide(fraction: 2.0 / 3.0, label: "⅔"),
        Guide(fraction: 3.0 / 4.0, label: "¾"),
    ]

    /// Build the guide set for one divider. `neighborLower`/`neighborUpper` are the
    /// positions of the adjacent boundaries in the same split (container edges count as
    /// 0 and 1). Guides outside the neighbors' reach are dropped — `setDivider` clamps
    /// there anyway, and a badge must never claim a snap the layout can't take. The
    /// neighbors' midpoint is the "equal zones" guide ("="), the layout-editor
    /// equivalent of Photoshop's equal-spacing hint.
    public static func guides(neighborLower: Double = 0, neighborUpper: Double = 1,
                              gap: Double = 0.01) -> [Guide] {
        var out = commonFractions.filter {
            $0.fraction > neighborLower + gap && $0.fraction < neighborUpper - gap
        }
        let mid = (neighborLower + neighborUpper) / 2
        // Skip the midpoint when it coincides with a common fraction (e.g. 0/1 -> ½).
        if mid > neighborLower + gap, mid < neighborUpper - gap,
           !out.contains(where: { abs($0.fraction - mid) < 0.0001 }) {
            out.append(Guide(fraction: mid, label: "="))
        }
        return out
    }

    /// Snap `proposed` (a fraction of the container) onto the nearest guide within
    /// `threshold` (also in fraction units — the editor converts from screen points).
    /// Outside every threshold the proposal passes through untouched.
    public static func apply(_ proposed: Double, guides: [Guide], threshold: Double) -> Result {
        guard threshold > 0,
              let nearest = guides.min(by: { abs($0.fraction - proposed) < abs($1.fraction - proposed) }),
              abs(nearest.fraction - proposed) <= threshold
        else { return Result(fraction: proposed, guide: nil) }
        return Result(fraction: nearest.fraction, guide: nearest)
    }
}

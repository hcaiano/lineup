import CoreGraphics

/// The brief note shown near a coordinated move that did not apply. It says the windows were
/// put back only when compensation confirmed every attempted frame.
public enum ZoneNotice {
    public enum Context { case divider, share, fill }

    public static func text<Window>(for outcome: ExactCommit.Outcome<Window>, context: Context,
                                    appName: String?) -> (title: String, detail: String)? {
        let changed = "Couldn’t apply this change"
        switch outcome {
        case .committed:
            return nil
        case .rejected:
            return (changed, "Windows or the layout changed. Nothing moved.")
        case .recovery:
            return ("Window restoration incomplete", "Use Retry Restore in the Lineup menu or Zones settings.")
        case .rolledBack(.refused):
            let title = appName.map { "\($0) didn’t fit" } ?? "A window didn’t fit"
            switch context {
            case .divider: return (title, "Windows were put back. The layout wasn’t saved.")
            case .share: return (title, "Windows were put back.")
            case .fill: return (title, "The window was put back.")
            }
        case .rolledBack(.changed):
            return (changed, context == .fill ? "The window changed while moving. It was put back."
                                              : "Windows changed while moving. They were put back.")
        case .rolledBack(.notSaved):
            return ("Couldn’t save the layout", "Windows were put back.")
        }
    }
}

public extension ZoneNotice {
    /// Centered under the anchor, or above it when there is no room below, then kept on the
    /// anchor's display.
    static func frame(size: CGSize, anchor: CGPoint, visible: CGRect) -> CGRect {
        let bounds = visible.insetBy(dx: 12, dy: 12)
        let below = CGRect(x: anchor.x - size.width / 2, y: anchor.y - 24 - size.height,
                           width: size.width, height: size.height)
        let preferred = below.minY >= bounds.minY ? below : below.offsetBy(dx: 0, dy: size.height + 48)
        return preferred.clamped(into: bounds)
    }
}

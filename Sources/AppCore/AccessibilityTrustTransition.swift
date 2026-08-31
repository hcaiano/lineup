import Foundation

/// The change, if any, between two Accessibility trust observations.
///
/// Keeping this decision pure makes the permission watcher unable to label an initial
/// untrusted state as a revocation. The app can then reserve the stronger "removed" copy for a
/// real trusted to untrusted transition.
public enum AccessibilityTrustTransition: Equatable, Sendable {
    case granted
    case revoked
    case unchanged

    public static func from(previouslyTrusted: Bool,
                            currentlyTrusted: Bool) -> Self {
        switch (previouslyTrusted, currentlyTrusted) {
        case (false, true): return .granted
        case (true, false): return .revoked
        default: return .unchanged
        }
    }
}

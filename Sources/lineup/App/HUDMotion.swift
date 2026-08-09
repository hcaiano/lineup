import AppKit

/// The fade timings the two ambient overlays share (`CycleHUD`, `HyperKeyBlockedPill`).
///
/// They had four different numbers between them — 0.07/0.14 and 0.12/0.14 — which is visible when
/// both are on screen in the same session. One pair, and one place to honour Reduce Motion: with
/// it on, both overlays appear and disappear instantly rather than crossfading.
@MainActor
enum HUDMotion {
    static let fadeIn: TimeInterval = 0.12
    static let fadeOut: TimeInterval = 0.14

    /// Zero while the user has asked for reduced motion, so `NSAnimationContext` snaps instead of
    /// animating and every completion handler still runs exactly once.
    static func duration(_ base: TimeInterval) -> TimeInterval {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : base
    }
}

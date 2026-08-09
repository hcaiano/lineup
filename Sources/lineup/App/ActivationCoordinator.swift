import AppKit

/// The SOLE owner of `NSApp.setActivationPolicy`. Enforced by a source-scan check in `AppSuite`.
///
/// Lineup 1.x never changed the policy; Cycler flipped to `.regular` when Settings opened and
/// back to `.accessory` when it closed. Merged naively that regresses: closing Settings while
/// the Zones layout editor is open would drop the app to `.accessory` mid-edit and steal its
/// focus. So the policy is ref-counted by reason instead — `.regular` while ANY window that
/// needs real app focus is open, `.accessory` again only when the last one goes away.
///
/// Deliberately NOT retained by: the layout editor overlay, the cycle HUD, the Hyperkey blocked
/// pill. Those are transient, non-activating surfaces; making them `.regular` would put a Dock
/// icon up for a HUD.
@MainActor
final class ActivationCoordinator {
    static let shared = ActivationCoordinator()

    private var reasons: Set<String> = []
    private var baselineApplied = false

    /// Agent at rest: no Dock icon (also `LSUIElement` in Info.plist). Called once at launch.
    func applyBaseline() {
        baselineApplied = true
        if reasons.isEmpty { NSApp.setActivationPolicy(.accessory) }
    }

    /// Settings, About, Welcome, What's New.
    func retain(_ reason: String) {
        let wasEmpty = reasons.isEmpty
        reasons.insert(reason)
        if wasEmpty { NSApp.setActivationPolicy(.regular) }
    }

    func release(_ reason: String) {
        guard reasons.remove(reason) != nil else { return }
        if reasons.isEmpty, baselineApplied { NSApp.setActivationPolicy(.accessory) }
    }

    /// Test/diagnostic view of the outstanding reasons.
    var activeReasons: Set<String> { reasons }
}

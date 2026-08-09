import AppKit
import ApplicationServices
import CoreGraphics

/// Accessibility + Input Monitoring status, live watching, and the request/recovery paths.
///
/// Merges the identical Accessibility watch both 1.x apps had (distributed notification on
/// `com.apple.accessibility.api` plus a 1.5 s poll, bounded at 80 ticks, started ONLY when the
/// app launched untrusted) and adds Input Monitoring for the Hyperkey tool.
///
/// Input Monitoring is NEVER requested at launch. It is the one genuinely new permission for
/// existing Lineup users and must stay opt-in: it is requested lazily the first time Hyperkey is
/// enabled, and otherwise only surfaced in General › Permissions and the Hyperkey pane.
@MainActor
final class PermissionCenter {
    static let shared = PermissionCenter()

    /// Called whenever a permission's status changes, so the menu and Settings refresh live
    /// instead of waiting for a relaunch.
    var onChange: (() -> Void)?

    private var lastTrusted = AXIsProcessTrusted()
    private var trustTimer: Timer?
    private var trustPollTicks = 0
    private var watching = false

    // MARK: - Status

    var isAccessibilityTrusted: Bool { AXIsProcessTrusted() }
    var isInputMonitoringGranted: Bool { CGPreflightListenEventAccess() }

    func isGranted(_ permission: Permission) -> Bool {
        switch permission {
        case .accessibility: return isAccessibilityTrusted
        case .inputMonitoring: return isInputMonitoringGranted
        }
    }

    // MARK: - Watch

    /// macOS grants Accessibility while the app keeps running, but the menu was built once and
    /// would keep showing the "not granted" warning until a relaunch. Watch for the flip and
    /// refresh live.
    func startAccessibilityWatch() {
        guard !watching else { return }
        watching = true
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(accessibilityMaybeChanged),
            name: NSNotification.Name("com.apple.accessibility.api"), object: nil)
        // Distributed notifications can be coalesced or missed; poll as a safety net until
        // granted — but ONLY when we launched UNTRUSTED. An already-trusted launch (every
        // returning user) has nothing to wait for, and an unconditional poll would run
        // AXIsProcessTrusted() every 1.5 s forever and defeat App Nap. Revocation still arrives
        // via the notification.
        guard !lastTrusted else { return }
        trustTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { // Timer fires on the main run loop
                guard let self else { return }
                self.accessibilityMaybeChanged()
                // Bound the net at ~120 s: that covers the active granting window (prompt ->
                // System Settings -> toggle). After that rely on the notification, so an
                // installed-but-never-granted app doesn't poll forever.
                self.trustPollTicks += 1
                if self.trustTimer != nil, self.trustPollTicks >= 80 {
                    self.trustTimer?.invalidate(); self.trustTimer = nil
                }
            }
        }
    }

    @objc private func accessibilityMaybeChanged() {
        let trusted = AXIsProcessTrusted()
        guard trusted != lastTrusted else { return }
        lastTrusted = trusted
        onChange?()
        if trusted { trustTimer?.invalidate(); trustTimer = nil } // revocation still notifies
    }

    /// Called from `applicationDidBecomeActive`: coming back from System Settings is the moment
    /// an Input Monitoring grant becomes visible to us.
    func recheck() {
        accessibilityMaybeChanged()
        onChange?()
    }

    // MARK: - Request / recovery

    /// Fires the system Accessibility prompt. A no-op once the user has made a decision — macOS
    /// will not re-prompt — which is exactly why the recovery path below also opens the pane.
    func requestAccessibility() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    /// User-initiated recovery. Fire the prompt (harmless; ensures Lineup is listed) AND open the
    /// pane directly, so a user who once declined isn't stuck clicking a button that does nothing.
    func openAccessibilitySettings() {
        requestAccessibility()
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    /// Requested lazily, only when Hyperkey is first enabled.
    @discardableResult
    func requestInputMonitoring() -> Bool {
        CGRequestListenEventAccess()
    }

    func openInputMonitoringSettings() {
        _ = CGRequestListenEventAccess()
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")
    }

    func openSettings(for permission: Permission) {
        switch permission {
        case .accessibility: openAccessibilitySettings()
        case .inputMonitoring: openInputMonitoringSettings()
        }
    }

    private func open(_ urlString: String) {
        if let url = URL(string: urlString) { NSWorkspace.shared.open(url) }
    }
}

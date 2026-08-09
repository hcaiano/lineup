import AppCore
import Foundation
import ServiceManagement
import os

/// The login item, via `SMAppService.mainApp`. Both 1.x apps had the same three lines inline in
/// their delegates; the shell owns it now, and it is app-wide (not per tool).
///
/// The registration is keyed to the app bundle, so it survives a Sparkle update as long as the
/// bundle ID and signature don't move — see `signing-baseline.txt`.
enum LaunchAtLogin {
    private static let log = Logger(subsystem: Product.logSubsystem, category: "launch-at-login")

    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    /// Returns the resulting state, so a caller that failed doesn't advertise a change that
    /// didn't happen.
    @discardableResult
    static func toggle() -> Bool {
        do {
            if isEnabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            log.error("launch-at-login toggle failed: \(error, privacy: .public)")
        }
        return isEnabled
    }

    static func set(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        toggle()
    }
}

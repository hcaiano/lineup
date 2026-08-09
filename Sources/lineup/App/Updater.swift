import AppCore
import Foundation
import Sparkle

/// The app's Sparkle updater. One controller for the whole app: the menu's "Check for
/// Updates…" item and the Settings → About button both target it directly, so Sparkle owns
/// the update UI and the menu item's enabled state (via canCheckForUpdates). Scheduled
/// background checks and the feed/signing config come from Info.plist (SUFeedURL,
/// SUPublicEDKey, SUEnableAutomaticChecks). The EdDSA private key lives only in the
/// developer's Keychain and never ships; releases are signed with Scripts/sparkle-appcast.sh.
enum AppUpdater {
    /// True only when running from the assembled .app bundle. A bare `swift run` executable
    /// has no Info.plist, so starting Sparkle there fails and shows an
    /// "Unable to Check For Updates" alert on every launch.
    static let isBundled = Bundle.main.bundleIdentifier == Product.bundleID

    /// `startingUpdater: isBundled` begins scheduled update checks as soon as this is first
    /// touched (AppDelegate references it at launch); dev runs never start the updater.
    static let shared = SPUStandardUpdaterController(
        startingUpdater: isBundled,
        updaterDelegate: nil,
        userDriverDelegate: nil)
}

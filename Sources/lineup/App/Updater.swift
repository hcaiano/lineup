import Sparkle

/// The app's Sparkle updater. One controller for the whole app: the menu's "Check for
/// Updates…" item and the Settings → About button both target it directly, so Sparkle owns
/// the update UI and the menu item's enabled state (via canCheckForUpdates). Scheduled
/// background checks and the feed/signing config come from Info.plist (SUFeedURL,
/// SUPublicEDKey, SUEnableAutomaticChecks). The EdDSA private key lives only in the
/// developer's Keychain and never ships; releases are signed with Scripts/sparkle-appcast.sh.
enum AppUpdater {
    /// `startingUpdater: true` begins scheduled update checks as soon as this is first touched
    /// (AppDelegate references it at launch).
    static let shared = SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: nil,
        userDriverDelegate: nil)
}

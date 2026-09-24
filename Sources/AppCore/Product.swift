import Foundation

/// Identity constants. UNCHANGED from Lineup 1.x — the bundle ID is the TCC and Sparkle
/// anchor and must never move. Mirrored in Resources/Info.plist and Scripts/*.sh;
/// pinned 3-way by AppSuite.runIdentityTests().
public enum Product {
    public static let name = "Lineup"
    public static let bundleID = "com.caiano.lineup"
    public static let executableName = "lineup"
    public static let logSubsystem = bundleID
    /// Carbon hotkey namespace. Unchanged from 1.x — see App/HotkeyManager.swift.
    public static let hotkeySignatureString = "LNUP"
    public static let selfSignedIdentity = "Lineup Self-Signed"
    public static let feedURLString = "https://lineup.caiano.com/appcast.xml"
    /// The custom bundle marker written by `Scripts/build-app.sh`. It is deliberately separate
    /// from the public bundle ID and feed so Stable and Nightly remain one app identity.
    public static let buildChannelInfoPlistKey = BuildChannelMarker.infoPlistKey

    /// The channel compiled into the running app bundle. Missing or malformed metadata defaults
    /// to Stable so a packaging mistake cannot opt users into prerelease updates.
    public static var buildChannel: UpdateChannel {
        BuildChannelMarker.fromInfoPlist(Bundle.main.object(forInfoDictionaryKey: buildChannelInfoPlistKey))
    }

    public static var configDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/lineup")
    }

    /// The 2.0 unified config.
    public static var configURL: URL { configDirectory.appendingPathComponent("config.json") }

    /// Lineup 1.x zones. Read-only in 2.0 (import source + downgrade safety net) — it is
    /// deliberately never written, renamed, or deleted, so rolling back to 1.x just works.
    public static var legacyZonesURL: URL { configDirectory.appendingPathComponent("zones.json") }

    /// Standalone Cycler's config, if the user is coming from it. Read-only, never deleted.
    public static var legacyCyclerBindingsURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/cycler/bindings.json")
    }
}

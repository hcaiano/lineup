import Foundation

/// Stable string identity for a tool. Also the config-section key on disk —
/// NEVER change a raw value; doing so orphans every existing user's settings.
public struct ToolID: RawRepresentable, Hashable, Codable, Sendable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    public static let zones = ToolID(rawValue: "zones")
    public static let cycler = ToolID(rawValue: "cycler")
    public static let hyperkey = ToolID(rawValue: "hyperkey")
    /// Hints is disabled by default and its config section is seeded disabled by the registry.
    /// The ID itself is a stable compatibility anchor (config-section key on disk).
    public static let hints = ToolID(rawValue: "hints")

    /// Registry/sidebar order. Fixed: Zones, Cycler, Hyperkey, Hints.
    /// Appended LAST on purpose: `all` is append-only, so any read of a config written by a
    /// newer build stays deterministic and the order existing users learned never reshuffles.
    public static let all: [ToolID] = [.zones, .cycler, .hyperkey, .hints]
}

extension ToolID: CustomStringConvertible {
    public var description: String { rawValue }
}

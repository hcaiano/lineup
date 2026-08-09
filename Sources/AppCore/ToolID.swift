import Foundation

/// Stable string identity for a tool. Also the config-section key on disk —
/// NEVER change a raw value; doing so orphans every existing user's settings.
public struct ToolID: RawRepresentable, Hashable, Codable, Sendable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    public static let zones = ToolID(rawValue: "zones")
    public static let cycler = ToolID(rawValue: "cycler")
    public static let hyperkey = ToolID(rawValue: "hyperkey")

    /// Registry/sidebar order. Fixed: Zones, Cycler, Hyperkey.
    public static let all: [ToolID] = [.zones, .cycler, .hyperkey]
}

extension ToolID: CustomStringConvertible {
    public var description: String { rawValue }
}

import Foundation

/// Stable string identity for a tool. Also the config-section key on disk —
/// NEVER change a raw value; doing so orphans every existing user's settings.
public struct ToolID: RawRepresentable, Hashable, Codable, Sendable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    public static let zones = ToolID(rawValue: "zones")
    public static let cycler = ToolID(rawValue: "cycler")
    public static let hyperkey = ToolID(rawValue: "hyperkey")
    public static let worldClock = ToolID(rawValue: "worldClock")
    public static let awake = ToolID(rawValue: "awake")
    public static let textCapture = ToolID(rawValue: "textCapture")
    public static let menuBar = ToolID(rawValue: "menuBar")
    public static let scroll = ToolID(rawValue: "scroll")

    public var displayName: String {
        switch self {
        case .zones: return "Zones"
        case .cycler: return "Cycler"
        case .hyperkey: return "Hyperkey"
        case .worldClock: return "World Clock"
        case .awake: return "Keep Awake"
        case .menuBar: return "Menu Bar"
        case .textCapture: return "Text Capture"
        case .scroll: return "Scroll"
        default: return rawValue.capitalized
        }
    }

    /// Registry/sidebar order.
    public static let all: [ToolID] = [.zones, .cycler, .hyperkey, .worldClock, .awake, .textCapture, .menuBar, .scroll]
}

extension ToolID: CustomStringConvertible {
    public var description: String { rawValue }
}

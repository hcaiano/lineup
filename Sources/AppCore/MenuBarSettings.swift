import Foundation

/// Menu Bar owns one optional tool section. `hiddenOwners` is the last group read from the
/// menu bar, kept so apps that launch later start in the right group. `preferencesBookmark`
/// authorizes the native visibility preference and its recovery journal.
public struct MenuBarSettings: Codable, Equatable {
    public var hiddenOwners: Set<String>
    public var preferencesBookmark: Data?
    public var extra: [String: JSONValue]

    public init(hiddenOwners: Set<String> = [],
                extra: [String: JSONValue] = [:]) {
        self.hiddenOwners = hiddenOwners
        self.preferencesBookmark = nil
        self.extra = extra
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyCodingKey.self)
        let version = try c.decodeIfPresent(Int.self, forKey: AnyCodingKey("version")) ?? 1
        guard version == 1 else {
            throw DecodingError.dataCorruptedError(
                forKey: AnyCodingKey("version"), in: c,
                debugDescription: "Menu Bar settings require a newer version of Lineup.")
        }
        hiddenOwners = Set(try c.decodeIfPresent([String].self,
                            forKey: AnyCodingKey("hiddenOwners")) ?? [])
        preferencesBookmark = try c.decodeIfPresent(Data.self, forKey: AnyCodingKey("preferencesBookmark"))
        extra = try c.unknownValues(besides: ["version", "hiddenOwners", "preferencesBookmark"])
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: AnyCodingKey.self)
        try c.encode(1, forKey: AnyCodingKey("version"))
        try c.encode(hiddenOwners.sorted(), forKey: AnyCodingKey("hiddenOwners"))
        try c.encodeIfPresent(preferencesBookmark, forKey: AnyCodingKey("preferencesBookmark"))
        try c.encodeExtra(extra)
    }
}

/// The arrow is the boundary between the groups. macOS 27 hides whole apps, so an app with
/// items on both sides stays visible: an icon the user kept visible never hides with a sibling.
public enum MenuBarLayout {
    /// Apps to hide, read from an unrestricted bar. Apps without an item on the arrow's display
    /// keep their previous group, so a hidden app that is not running stays hidden.
    public static func hiddenOwners(items: [(owner: String, frame: CGRect)], arrow: CGRect,
                                    displayBounds: [CGRect], leftToRight: Bool,
                                    previous: Set<String>) -> Set<String> {
        let center = CGPoint(x: arrow.midX, y: arrow.midY)
        guard let display = displayBounds.first(where: { $0.contains(center) }) else { return previous }
        var visible = Set<String>(), hidden = Set<String>()
        for item in items where !item.owner.hasPrefix("com.apple.")
            && display.contains(CGPoint(x: item.frame.midX, y: item.frame.midY))
            && item.frame.maxY > arrow.minY && item.frame.minY < arrow.maxY {
            let hiddenSide = leftToRight ? item.frame.midX < arrow.midX : item.frame.midX > arrow.midX
            if hiddenSide { hidden.insert(item.owner) } else { visible.insert(item.owner) }
        }
        return previous.union(hidden).subtracting(visible).filter { !$0.hasPrefix("com.apple.") }
    }


}

/// An expanded group hides itself again unless the user may still be using one of its items.
public enum MenuBarAutoHide {
    public static let delay: TimeInterval = 10
    public static let retry: TimeInterval = 2

    public struct Window {
        public let pid: Int32
        public let layer: Int
        public let bounds: CGRect
        public init(pid: Int32, layer: Int, bounds: CGRect) {
            self.pid = pid
            self.layer = layer
            self.bounds = bounds
        }
    }

    /// Menus and popovers open directly below their menu bar item. Full-width overlays and
    /// ordinary windows from the same apps do not postpone hiding.
    public static func shouldWait(pointer: CGPoint, menuBars: [CGRect],
                                  windows: [Window], hiddenPIDs: Set<Int32>) -> Bool {
        if menuBars.contains(where: { $0.contains(pointer) }) { return true }
        return windows.contains { window in
            hiddenPIDs.contains(window.pid) && window.layer > 0 && menuBars.contains { bar in
                window.bounds.minY >= bar.maxY - 2 && window.bounds.minY <= bar.maxY + 16
                    && window.bounds.maxX > bar.minX && window.bounds.minX < bar.maxX
                    && window.bounds.width < bar.width * 0.9
            }
        }
    }
}

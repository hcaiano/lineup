import Foundation

/// Menu Bar owns one optional tool section. macOS 27 applies visibility to an
/// entire application, even when that application publishes several items.
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

    public mutating func setHidden(_ hidden: Bool, owner: String) {
        guard !owner.isEmpty else { return }
        if hidden { hiddenOwners.insert(owner) } else { hiddenOwners.remove(owner) }
    }
}

/// macOS owns the order; accept a drag only when the observed permutation matches.
public enum MenuBarOrder {
    public static func verifiesMove(_ item: String, before target: String,
                                    previous: [String], observed: [String]) -> Bool {
        guard item != target, Set(previous).count == previous.count,
              previous.contains(item), previous.contains(target) else { return false }
        var expected = previous.filter { $0 != item }
        expected.insert(item, at: expected.firstIndex(of: target)!)
        return observed == expected
    }
}

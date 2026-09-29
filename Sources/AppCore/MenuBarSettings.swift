import Foundation

/// Menu Bar owns one optional tool section. macOS 27 applies visibility to an
/// entire application, even when that application publishes several items.
public struct MenuBarSettings: Codable, Equatable {
    public var hiddenOwners: Set<String>
    public var itemOrder: [String]
    public var preferencesBookmark: Data?
    public var extra: [String: JSONValue]

    public init(hiddenOwners: Set<String> = [], itemOrder: [String] = [],
                extra: [String: JSONValue] = [:]) {
        self.hiddenOwners = hiddenOwners
        self.itemOrder = itemOrder
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
        itemOrder = try c.decodeIfPresent([String].self,
                            forKey: AnyCodingKey("itemOrder")) ?? []
        preferencesBookmark = try c.decodeIfPresent(Data.self, forKey: AnyCodingKey("preferencesBookmark"))
        extra = try c.unknownValues(besides: ["version", "hiddenOwners", "itemOrder", "preferencesBookmark"])
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: AnyCodingKey.self)
        try c.encode(1, forKey: AnyCodingKey("version"))
        try c.encode(hiddenOwners.sorted(), forKey: AnyCodingKey("hiddenOwners"))
        try c.encode(itemOrder, forKey: AnyCodingKey("itemOrder"))
        try c.encodeIfPresent(preferencesBookmark, forKey: AnyCodingKey("preferencesBookmark"))
        try c.encodeExtra(extra)
    }

    /// Unknown items remain in their observed order. Missing apps retain their
    /// saved identities so a layout edit does not discard them.
    public func orderedIDs(observed: [String]) -> [String] {
        var remaining = Set(observed)
        let saved = itemOrder.filter { remaining.remove($0) != nil }
        return saved + observed.filter { remaining.remove($0) != nil }
    }

    public mutating func move(_ item: String, before target: String?, observed: [String]) {
        guard observed.contains(item), target != item,
              target.map(observed.contains) ?? true else { return }
        var order = orderedIDs(observed: observed).filter { $0 != item }
        let index = target.flatMap { order.firstIndex(of: $0) } ?? order.endIndex
        order.insert(item, at: index)
        let absent = itemOrder.filter { !observed.contains($0) }
        itemOrder = order + absent
    }

    public mutating func setHidden(_ hidden: Bool, owner: String) {
        guard !owner.isEmpty else { return }
        if hidden { hiddenOwners.insert(owner) } else { hiddenOwners.remove(owner) }
    }
}

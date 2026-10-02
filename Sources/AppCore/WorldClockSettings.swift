import Foundation
import WorldClockCore

/// The envelope schema stays unchanged. Only this tool owns its versioned settings section.
public struct WorldClockSettings: Codable, Equatable {
    public var places: [ClockPlace]
    /// "local" follows the Mac; any other value is a saved place's stable id.
    public var pinnedID: String?
    /// All clocks remain in Lineup. This adds a separate icon or pinned live time.
    public var showSeparateMenuBarItem: Bool
    private var extra: [String: JSONValue] = [:]
    private var placeExtras: [String: [String: JSONValue]] = [:]

    public init(places: [ClockPlace] = [], pinnedID: String? = nil,
                showSeparateMenuBarItem: Bool = false) {
        self.places = places
        self.pinnedID = pinnedID
        self.showSeparateMenuBarItem = showSeparateMenuBarItem
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyCodingKey.self)
        let version = try c.decode(Int.self, forKey: AnyCodingKey("version"))
        guard version == 1 else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                debugDescription: "World Clock settings require a newer version of Lineup."))
        }
        let rawPlaces = try c.decode([JSONValue].self, forKey: AnyCodingKey("places"))
        places = try rawPlaces.map { try $0.decoded(ClockPlace.self) }
        pinnedID = try c.decodeIfPresent(String.self, forKey: AnyCodingKey("pinnedID"))
        // Existing installations already had a clock item. Keep it until the user chooses
        // Lineup alone, while a newly enabled clock defaults to the shared panel.
        showSeparateMenuBarItem = try c.decodeIfPresent(Bool.self,
            forKey: AnyCodingKey("showSeparateMenuBarItem")) ?? true
        guard isValid else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                debugDescription: "World Clock contains invalid or duplicate places."))
        }
        extra = try c.unknownValues(besides: ["version", "places", "pinnedID", "showSeparateMenuBarItem"])
        let known: Set<String> = ["id", "name", "timeZoneID", "coordinates", "region"]
        for (place, raw) in zip(places, rawPlaces) {
            var fields = raw.objectValue?.filter { !known.contains($0.key) } ?? [:]
            // Preserve future coordinate metadata too when only renaming/reordering a city.
            if let coordinates = raw["coordinates"]?.objectValue {
                let unknown = coordinates.filter { !["latitude", "longitude"].contains($0.key) }
                if !unknown.isEmpty { fields["coordinates"] = .object(unknown) }
            }
            if !fields.isEmpty { placeExtras[place.id] = fields }
        }
    }

    public func encode(to encoder: Encoder) throws {
        guard isValid else {
            throw EncodingError.invalidValue(places, .init(codingPath: encoder.codingPath,
                debugDescription: "World Clock contains invalid or duplicate places."))
        }
        var c = encoder.container(keyedBy: AnyCodingKey.self)
        try c.encode(1, forKey: AnyCodingKey("version"))
        try c.encodeIfPresent(pinnedID, forKey: AnyCodingKey("pinnedID"))
        try c.encode(showSeparateMenuBarItem, forKey: AnyCodingKey("showSeparateMenuBarItem"))
        let rawPlaces = try places.map { place -> JSONValue in
            var fields = placeExtras[place.id] ?? [:]
            let known = try JSONValue.encoding(place).objectValue ?? [:]
            let coordinateExtra = fields.removeValue(forKey: "coordinates")?.objectValue ?? [:]
            fields.merge(known) { _, new in new }
            if let coordinates = known["coordinates"]?.objectValue {
                fields["coordinates"] = .object(coordinateExtra.merging(coordinates) { _, new in new })
            }
            return .object(fields)
        }
        try c.encode(rawPlaces, forKey: AnyCodingKey("places"))
        try c.encodeExtra(extra)
    }

    private var isValid: Bool {
        places.allSatisfy { $0.isValid && $0.id != "local" }
            && Set(places.map(\.id)).count == places.count
            && (pinnedID == nil || pinnedID == "local" || places.contains { $0.id == pinnedID })
    }

    public mutating func removePlace(id: String) {
        places.removeAll { $0.id == id }
        if pinnedID == id { pinnedID = nil }
        placeExtras[id] = nil
    }
}

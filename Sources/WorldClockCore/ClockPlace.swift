import Foundation

public struct ClockCoordinates: Codable, Equatable, Sendable {
    public let latitude: Double
    public let longitude: Double

    public init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }

    public var isValid: Bool {
        latitude.isFinite && longitude.isFinite
            && (-90...90).contains(latitude) && (-180...180).contains(longitude)
    }
}

/// An IANA identifier is persisted, never a UTC offset: offsets change with the selected date.
public struct ClockPlace: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public var name: String
    public let timeZoneID: String
    public let coordinates: ClockCoordinates?
    public let region: String?

    public init(id: String, name: String, timeZoneID: String,
                coordinates: ClockCoordinates? = nil, region: String? = nil) {
        self.id = id
        self.name = name
        self.timeZoneID = timeZoneID
        self.coordinates = coordinates
        self.region = region
    }

    public var timeZone: TimeZone? { TimeZone(identifier: timeZoneID) }

    public var isValid: Bool {
        !id.isEmpty && !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !timeZoneID.isEmpty && (coordinates?.isValid ?? true)
    }
}

public struct ClockCatalog: Sendable {
    private struct Entry: Sendable {
        let place: ClockPlace
        let names: [String]
        let context: String
        let population: Int
    }
    private let entries: [Entry]

    /// Catalog rows: id, name, country, region, latitude, longitude, IANA zone, population, aliases.
    public init(tsv: String, timeZoneIDs: [String] = TimeZone.knownTimeZoneIdentifiers) {
        var entries: [Entry] = []
        let locale = Locale(identifier: "en_US_POSIX")
        for line in tsv.split(separator: "\n") {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard fields.count == 9, let latitude = Double(fields[4]),
                  let longitude = Double(fields[5]), let population = Int(fields[7]) else { continue }
            let country = locale.localizedString(forRegionCode: fields[2]) ?? fields[2]
            let region = [fields[3], country].filter { !$0.isEmpty }.joined(separator: ", ")
            let place = ClockPlace(id: "city:\(fields[0])", name: fields[1], timeZoneID: fields[6],
                                   coordinates: ClockCoordinates(latitude: latitude, longitude: longitude),
                                   region: region)
            guard place.isValid, place.timeZone != nil else { continue }
            let names = ([fields[1]] + fields[8].split(separator: "|").map(String.init)).map(Self.normalized)
            entries.append(Entry(place: place, names: names,
                                 context: Self.normalized("\(region) \(fields[2]) \(fields[6])"),
                                 population: population))
        }
        for zone in Set(timeZoneIDs + ["UTC"]).sorted() where TimeZone(identifier: zone) != nil {
            let name = zone.replacingOccurrences(of: "_", with: " ")
            entries.append(Entry(place: ClockPlace(id: "zone:\(zone)", name: name, timeZoneID: zone),
                                 names: [Self.normalized(name)], context: "time zone", population: -1))
        }
        self.entries = entries
    }

    public var cityCount: Int { entries.filter { $0.place.coordinates != nil }.count }

    public static func bundled(in roots: [URL]) -> ClockCatalog? {
        for root in roots {
            // SwiftPM's native builder emits a flat bundle; Xcode's builder emits a macOS bundle.
            // Avoid Bundle.module's fatalError when the catalog is missing from either shape.
            for directory in ["WorldClock", "Contents/Resources/WorldClock"] {
                let url = root.appendingPathComponent("lineup_lineup.bundle/\(directory)/cities.tsv")
                if let text = try? String(contentsOf: url, encoding: .utf8) { return ClockCatalog(tsv: text) }
            }
        }
        return nil
    }

    public func search(_ query: String, excluding ids: Set<String> = [], limit: Int = 30) -> [ClockPlace] {
        let query = Self.normalized(query.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !query.isEmpty, limit > 0 else { return [] }
        let words = query.split(whereSeparator: { $0.isWhitespace || $0 == "," }).map(String.init)
        guard !words.isEmpty else { return [] }
        return entries.compactMap { entry -> (Entry, Int)? in
            guard !ids.contains(entry.place.id) else { return nil }
            let matches = entry.names.contains { name in
                let text = name + " " + entry.context
                return words.allSatisfy { text.contains($0) }
            }
            guard matches else { return nil }
            let rank: Int
            if entry.names.first == query { rank = 0 }
            else if entry.names.contains(query) { rank = 1 }
            else if entry.names.first?.hasPrefix(query) == true { rank = 2 }
            else if entry.names.contains(where: { $0.hasPrefix(query) }) { rank = 3 }
            else { rank = 4 }
            return (entry, rank)
        }.sorted {
            if $0.1 != $1.1 { return $0.1 < $1.1 }
            if $0.0.population != $1.0.population { return $0.0.population > $1.0.population }
            return $0.0.place.id < $1.0.place.id
        }.prefix(limit).map { $0.0.place }
    }

    private static func normalized(_ value: String) -> String {
        value.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }
}

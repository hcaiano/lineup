import Foundation

public enum ClockRow: Identifiable, Equatable {
    case local
    case place(ClockPlace)

    public var id: String {
        switch self {
        case .local: return "local"
        case .place(let place): return place.id
        }
    }
}

public enum ClockOrdering {
    public static func rows(places: [ClockPlace], at date: Date, localZone: TimeZone) -> [ClockRow] {
        let entries = [(row: ClockRow.local, offset: localZone.secondsFromGMT(for: date), index: -1)]
            + places.enumerated().map { index, place in
                (row: ClockRow.place(place), offset: place.timeZone?.secondsFromGMT(for: date) ?? Int.max, index: index)
            }
        return entries.sorted {
            $0.offset == $1.offset ? $0.index < $1.index : $0.offset < $1.offset
        }.map(\.row)
    }

    /// Manual order only breaks ties; it cannot put an earlier clock below a later one.
    public static func neighbor(of id: String, by direction: Int, places: [ClockPlace], at date: Date) -> String? {
        guard direction == -1 || direction == 1,
              let place = places.first(where: { $0.id == id }),
              let offset = place.timeZone?.secondsFromGMT(for: date) else { return nil }
        let peers = places.filter { $0.timeZone?.secondsFromGMT(for: date) == offset }
        guard let index = peers.firstIndex(where: { $0.id == id }),
              peers.indices.contains(index + direction) else { return nil }
        return peers[index + direction].id
    }
}

import Foundation

public enum SolarEventKind: String, Equatable, Sendable {
    case sunrise, sunset
}

public enum SolarSummary: Equatable, Sendable {
    case event(SolarEventKind, Date)
    case continuousDaylight
    case continuousDarkness
}

public enum SolarClock {
    /// Approximate apparent rise/set, including the conventional 0.833° refraction/solar radius.
    /// NOAA's fractional-year equations: https://gml.noaa.gov/grad/solcalc/solareqns.PDF
    /// Work in absolute instants, so DST, UTC date boundaries and polar latitudes need no special
    /// offset arithmetic. Scan through tomorrow in the city's calendar, then bisect a crossing.
    public static func nextEvent(after date: Date, coordinates: ClockCoordinates,
                                 timeZone: TimeZone) -> SolarSummary? {
        guard coordinates.isValid else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        guard let end = calendar.date(byAdding: .day, value: 2, to: calendar.startOfDay(for: date)) else { return nil }
        var previous = date
        var previousAltitude = altitude(at: date, coordinates: coordinates) + 0.833
        while previous < end {
            let next = min(previous.addingTimeInterval(600), end)
            let nextAltitude = altitude(at: next, coordinates: coordinates) + 0.833
            if (previousAltitude > 0) != (nextAltitude > 0) {
                let rising = nextAltitude > previousAltitude
                var low = previous
                var high = next
                for _ in 0..<16 {
                    let mid = low.addingTimeInterval(high.timeIntervalSince(low) / 2)
                    let above = altitude(at: mid, coordinates: coordinates) + 0.833 > 0
                    if above == (previousAltitude > 0) { low = mid } else { high = mid }
                }
                return .event(rising ? .sunrise : .sunset, high)
            }
            previous = next
            previousAltitude = nextAltitude
        }
        return altitude(at: date, coordinates: coordinates) + 0.833 > 0
            ? .continuousDaylight : .continuousDarkness
    }

    private static func altitude(at date: Date, coordinates: ClockCoordinates) -> Double {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(secondsFromGMT: 0)!
        let parts = utc.dateComponents([.hour, .minute, .second], from: date)
        let day = utc.ordinality(of: .day, in: .year, for: date)!
        let days = utc.range(of: .day, in: .year, for: date)!.count
        let hour = Double(parts.hour!) + Double(parts.minute!) / 60 + Double(parts.second!) / 3600
        let gamma = 2 * Double.pi / Double(days) * (Double(day - 1) + (hour - 12) / 24)
        let equation = 229.18 * (0.000075 + 0.001868 * cos(gamma) - 0.032077 * sin(gamma)
                                - 0.014615 * cos(2 * gamma) - 0.040849 * sin(2 * gamma))
        let declination = 0.006918 - 0.399912 * cos(gamma) + 0.070257 * sin(gamma)
            - 0.006758 * cos(2 * gamma) + 0.000907 * sin(2 * gamma)
            - 0.002697 * cos(3 * gamma) + 0.00148 * sin(3 * gamma)
        let angle = (hour * 60 + equation + 4 * coordinates.longitude) / 4 - 180
        let radians = Double.pi / 180
        let latitude = coordinates.latitude * radians
        let sine = sin(latitude) * sin(declination) + cos(latitude) * cos(declination) * cos(angle * radians)
        return asin(min(1, max(-1, sine))) / radians
    }
}

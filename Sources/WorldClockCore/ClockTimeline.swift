import Foundation

/// Simulation stays at one absolute instant until the user changes it. Only live mode ticks.
public struct ClockTimeline: Equatable {
    public private(set) var anchor: Date
    public private(set) var selection: Date?
    public var isLive: Bool { selection == nil }
    public var range: ClosedRange<Date> { anchor.addingTimeInterval(-86400)...anchor.addingTimeInterval(86400) }

    public init(now: Date) { anchor = now }

    public func date(now: Date) -> Date { selection ?? now }

    public mutating func reset(now: Date) {
        anchor = now
        selection = nil
    }

    public mutating func select(_ date: Date) {
        selection = min(max(date, range.lowerBound), range.upperBound)
    }

    public mutating func scrub(steps: Double) {
        guard steps.isFinite else { return }
        select(anchor.addingTimeInterval(min(96, max(-96, steps.rounded())) * 900))
    }

    public var steps: Double { (selection ?? anchor).timeIntervalSince(anchor) / 900 }
}

public enum ClockPresentation {
    public static func time(_ date: Date, in zone: TimeZone, locale: Locale = .autoupdatingCurrent) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = zone
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    /// Compare wall-calendar dates, not elapsed 24-hour periods, including across the date line.
    public static func dayDifference(at date: Date, in zone: TimeZone, relativeTo localZone: TimeZone) -> Int {
        var local = Calendar(identifier: .gregorian)
        local.timeZone = localZone
        var remote = local
        remote.timeZone = zone
        var neutral = local
        neutral.timeZone = TimeZone(secondsFromGMT: 0)!
        let localDay = neutral.date(from: local.dateComponents([.year, .month, .day], from: date))!
        let remoteDay = neutral.date(from: remote.dateComponents([.year, .month, .day], from: date))!
        return neutral.dateComponents([.day], from: localDay, to: remoteDay).day ?? 0
    }

    public static func offset(at date: Date, in zone: TimeZone, relativeTo localZone: TimeZone) -> String {
        let minutes = (zone.secondsFromGMT(for: date) - localZone.secondsFromGMT(for: date)) / 60
        guard minutes != 0 else { return "Same time" }
        let absolute = abs(minutes)
        let hours = absolute / 60
        let remainder = absolute % 60
        let duration = remainder == 0 ? "\(hours)h" : hours == 0 ? "\(remainder)m" : "\(hours)h \(remainder)m"
        return "\(minutes < 0 ? "−" : "+")\(duration)"
    }
}

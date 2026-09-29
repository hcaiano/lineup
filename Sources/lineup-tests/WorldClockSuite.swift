import AppCore
import Foundation
import WorldClockCore

func runWorldClockTests() throws {
    let iso = ISO8601DateFormatter()
    func date(_ value: String) -> Date { iso.date(from: value)! }
    let utc = TimeZone(secondsFromGMT: 0)!
    let lisbon = TimeZone(identifier: "Europe/Lisbon")!
    let newYork = TimeZone(identifier: "America/New_York")!
    let losAngeles = TimeZone(identifier: "America/Los_Angeles")!
    let kathmandu = TimeZone(identifier: "Asia/Kathmandu")!

    // One absolute instant drives all rows, including staggered DST transitions and fractional offsets.
    for (instant, zone, reference, expected) in [
        ("2026-03-07T12:00:00Z", newYork, lisbon, "−5h"),
        ("2026-03-15T12:00:00Z", newYork, lisbon, "−4h"),
        ("2026-04-01T12:00:00Z", newYork, lisbon, "−5h"),
        ("2026-01-01T12:00:00Z", kathmandu, utc, "+5h 45m"),
        ("2026-01-01T12:00:00Z", TimeZone(identifier: "Asia/Kolkata")!, kathmandu, "−15m"),
        ("2026-01-01T12:00:00Z", utc, utc, "Same time"),
    ] {
        check(ClockPresentation.offset(at: date(instant), in: zone, relativeTo: reference) == expected,
              "clock offset at \(instant) for \(zone.identifier) relative to \(reference.identifier)")
    }
    for (instant, zone, reference, expected) in [
        ("2026-09-29T01:00:00Z", losAngeles, lisbon, -1),
        ("2026-09-29T23:30:00Z", TimeZone(identifier: "Asia/Tokyo")!, utc, 1),
        ("2026-09-29T12:00:00Z", losAngeles, lisbon, 0),
        ("2026-09-29T10:30:00Z", TimeZone(identifier: "Pacific/Kiritimati")!,
         TimeZone(identifier: "Pacific/Pago_Pago")!, 2),
    ] {
        check(ClockPresentation.dayDifference(at: date(instant), in: zone, relativeTo: reference) == expected,
              "clock dates compare calendar days across midnight and the date line")
    }
    let knownTime = date("2026-01-01T18:07:00Z")
    let usTime = ClockPresentation.time(knownTime, in: newYork, locale: Locale(identifier: "en_US"))
    let ptTime = ClockPresentation.time(knownTime, in: newYork, locale: Locale(identifier: "pt_PT"))
    check(usTime.contains("1:07") && usTime.contains("PM") && ptTime == "13:07",
          "clock formats time in the destination zone using the requested locale")

    let now = date("2026-03-29T00:45:00Z")
    var timeline = ClockTimeline(now: now)
    check(timeline.date(now: now.addingTimeInterval(60)) == now.addingTimeInterval(60), "live clock advances")
    timeline.scrub(steps: 2)
    check(timeline.date(now: now.addingTimeInterval(120)) == date("2026-03-29T01:15:00Z"),
          "simulated time stays fixed when the real clock ticks")
    check(ClockPresentation.time(timeline.date(now: now), in: lisbon, locale: Locale(identifier: "pt_PT")) == "02:15",
          "scrolling crosses the missing spring-forward hour as an absolute instant")
    timeline.scrub(steps: -1000)
    check(timeline.selection == now.addingTimeInterval(-86400), "scroll clamps its lower bound")
    timeline.select(now.addingTimeInterval(100000))
    check(timeline.selection == now.addingTimeInterval(86400), "exact time entry clamps its upper bound")
    timeline.select(now.addingTimeInterval(420))
    check(timeline.selection == now.addingTimeInterval(420), "exact time entry is not rounded to slider steps")
    timeline.reset(now: now.addingTimeInterval(3600))
    check(timeline.isLive && timeline.date(now: now.addingTimeInterval(3660)) == now.addingTimeInterval(3660),
          "returning to Now discards simulation and follows real time")
    let autumn = date("2026-10-25T00:30:00Z")
    timeline.reset(now: autumn)
    timeline.scrub(steps: 4)
    check(ClockPresentation.time(autumn, in: lisbon, locale: Locale(identifier: "pt_PT")) == "01:30"
          && ClockPresentation.time(timeline.date(now: autumn), in: lisbon, locale: Locale(identifier: "pt_PT")) == "01:30"
          && ClockPresentation.offset(at: timeline.date(now: autumn), in: lisbon, relativeTo: utc) == "Same time",
          "repeated autumn hour remains two distinct instants with different offsets")

    // Small representative source fixture exercises ranking, aliases, disambiguation and exclusion.
    let catalog = ClockCatalog(tsv: """
    3448439\tSão Paulo\tBR\tSão Paulo\t-23.55\t-46.63\tAmerica/Sao_Paulo\t12300000\tSao Paulo|Sampa
    2735943\tPorto\tPT\tPorto\t41.15\t-8.61\tEurope/Lisbon\t250000\tOporto
    1\tPorto Alegre\tBR\tRio Grande do Sul\t-30.03\t-51.23\tAmerica/Sao_Paulo\t1400000\t
    3\tBordeaux\tFR\tNouvelle-Aquitaine\t44.84\t-0.58\tEurope/Paris\t260000\tPorto
    2\tBroken\tXX\t\t100\t0\tUTC\t0\t
    malformed
    """, timeZoneIDs: ["Europe/Lisbon", "America/Sao_Paulo"])
    check(catalog.search("sao paulo").first?.name == "São Paulo", "search ignores accents and case")
    check(catalog.search("oporto").first?.name == "Porto", "search accepts alternate city names")
    check(catalog.search("Porto").first?.name == "Porto", "exact city name beats aliases and larger prefix matches")
    check(catalog.search("Porto Brazil").first?.name == "Porto Alegre", "country disambiguates a city search")
    check(catalog.search("Europe/Lisbon").contains { $0.coordinates == nil && $0.timeZoneID == "Europe/Lisbon" },
          "search can add a bare time zone without inventing solar coordinates")
    check(!catalog.search("Porto", excluding: ["city:2735943"]).contains { $0.id == "city:2735943" },
          "already-added cities are excluded from search")
    check(catalog.search(" ").isEmpty && catalog.search("Broken").isEmpty && catalog.search("Porto", limit: 1).count == 1,
          "search handles empty input, invalid coordinates and bounded result counts")

    // Independent approximate solar references for Boulder, Colorado, around the June solstice.
    let boulder = ClockCoordinates(latitude: 40.015, longitude: -105.2705)
    let denver = TimeZone(identifier: "America/Denver")!
    for (instant, kind, expected) in [
        ("2026-06-21T07:00:00Z", SolarEventKind.sunrise, "2026-06-21T11:32:00Z"),
        ("2026-06-21T18:00:00Z", SolarEventKind.sunset, "2026-06-22T02:33:00Z"),
        ("2026-06-22T04:00:00Z", SolarEventKind.sunrise, "2026-06-22T11:32:00Z"),
    ] {
        if case .event(let actualKind, let actualDate) = SolarClock.nextEvent(after: date(instant), coordinates: boulder, timeZone: denver) {
            check(actualKind == kind && abs(actualDate.timeIntervalSince(date(expected))) < 300,
                  "solar event after \(instant) matches the expected event within five minutes")
        } else { check(false, "Boulder has a next solar event") }
    }
    let tromso = ClockCoordinates(latitude: 69.65, longitude: 18.96)
    let oslo = TimeZone(identifier: "Europe/Oslo")!
    check(SolarClock.nextEvent(after: date("2026-06-21T12:00:00Z"), coordinates: tromso, timeZone: oslo) == .continuousDaylight,
          "polar summer has no fabricated sunset")
    check(SolarClock.nextEvent(after: date("2026-12-21T12:00:00Z"), coordinates: tromso, timeZone: oslo) == .continuousDarkness,
          "polar winter has no fabricated sunrise")
    check(SolarClock.nextEvent(after: now, coordinates: ClockCoordinates(latitude: .nan, longitude: 0), timeZone: utc) == nil,
          "invalid coordinates never become a solar time")
    let auckland = ClockCoordinates(latitude: -36.85, longitude: 174.76)
    if case .event(let kind, let instant) = SolarClock.nextEvent(after: date("2026-09-28T20:00:00Z"), coordinates: auckland,
                                                              timeZone: TimeZone(identifier: "Pacific/Auckland")!) {
        check(kind == .sunset && instant > date("2026-09-29T05:00:00Z") && instant < date("2026-09-29T07:00:00Z"),
              "solar events use the city date in the eastern hemisphere after DST")
    } else { check(false, "Auckland has a sunset") }

    try runWorldClockPersistenceTests()
    try runWorldClockResourceTests()
    runWorldClockOrderingTests()
}

private func runWorldClockOrderingTests() {
    let date = ISO8601DateFormatter().date(from: "2026-09-29T13:00:00Z")!
    let local = TimeZone(identifier: "Europe/Lisbon")!
    let sf = ClockPlace(id: "sf", name: "SF", timeZoneID: "America/Los_Angeles")
    let saoPaulo = ClockPlace(id: "sp", name: "São Paulo", timeZoneID: "America/Sao_Paulo")
    let porto = ClockPlace(id: "porto", name: "Porto", timeZoneID: "Europe/Lisbon")
    let dubai = ClockPlace(id: "dubai", name: "Dubai", timeZoneID: "Asia/Dubai")
    let kathmandu = ClockPlace(id: "ktm", name: "Kathmandu", timeZoneID: "Asia/Kathmandu")
    let london = ClockPlace(id: "london", name: "London", timeZoneID: "Europe/London")
    for (places, expected) in [
        ([dubai, porto, saoPaulo, sf], ["sf", "sp", "local", "porto", "dubai"]),
        ([kathmandu, dubai], ["local", "dubai", "ktm"]),
        ([saoPaulo, sf], ["sf", "sp", "local"]),
        ([porto, london], ["local", "porto", "london"]),
        ([london, porto], ["local", "london", "porto"]),
        ([], ["local"]),
    ] {
        check(ClockOrdering.rows(places: places, at: date, localZone: local).map(\.id) == expected,
              "Local is placed chronologically; equal offsets preserve the saved order: \(expected)")
    }
    let newYork = ClockPlace(id: "ny", name: "New York", timeZoneID: "America/New_York")
    let fixed = TimeZone(secondsFromGMT: -16_200)!
    let before = ISO8601DateFormatter().date(from: "2026-03-08T06:30:00Z")!
    let after = before.addingTimeInterval(3600)
    check(ClockOrdering.rows(places: [newYork], at: before, localZone: fixed).map(\.id) == ["ny", "local"]
          && ClockOrdering.rows(places: [newYork], at: after, localZone: fixed).map(\.id) == ["local", "ny"],
          "simulating across DST repositions Local using the selected instant's offsets")
    let unknown = ClockPlace(id: "future", name: "Future", timeZoneID: "Future/City")
    check(ClockOrdering.rows(places: [unknown, sf], at: date, localZone: local).map(\.id) == ["sf", "local", "future"],
          "unavailable zones remain visible after the ordered clocks")
    check(ClockOrdering.neighbor(of: porto.id, by: 1, places: [porto, dubai, london], at: date) == london.id,
          "manual ordering finds equal-time peers across the saved list")
    check(ClockOrdering.neighbor(of: dubai.id, by: -1, places: [porto, dubai, london], at: date) == nil,
          "manual ordering cannot cross different time offsets")
    check(ClockOrdering.neighbor(of: porto.id, by: -1, places: [porto, london], at: date) == nil,
          "manual ordering stops at the first equal-time peer")
}

private func runWorldClockResourceTests() throws {
    let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("lineup/Resources/WorldClock/cities.tsv")
    let shipped = try String(contentsOf: source, encoding: .utf8)
    let catalog = ClockCatalog(tsv: shipped, timeZoneIDs: [])
    check(catalog.cityCount == shipped.split(separator: "\n").count && catalog.cityCount > 0,
          "every shipped city record can be loaded on the supported platform")
    check(catalog.search("Porto").first?.timeZoneID == "Europe/Lisbon",
          "the shipped catalog resolves a known city to its IANA zone")
    check(catalog.search("Oranjestad").first?.region == "Aruba",
          "cities without a named region show the country without raw administrative codes")
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("lineup-clock-resources-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let city = "2735943\tPorto\tPT\tPorto\t41.15\t-8.61\tEurope/Lisbon\t250000\tOporto\n"
    for (build, folder) in [("packaged", "WorldClock"), ("development", "Contents/Resources/WorldClock")] {
        let root = directory.appendingPathComponent(build)
        let resource = root.appendingPathComponent("lineup_lineup.bundle/\(folder)")
        try FileManager.default.createDirectory(at: resource, withIntermediateDirectories: true)
        try city.write(to: resource.appendingPathComponent("cities.tsv"), atomically: true, encoding: .utf8)
        check(ClockCatalog.bundled(in: [root])?.search("Oporto").first?.name == "Porto",
              "\(build) resource bundle supplies searchable city data from its fixture")
    }
    check(ClockCatalog.bundled(in: [directory.appendingPathComponent("missing")]) == nil,
          "missing resource bundle returns no city data without trapping")
}

private func runWorldClockPersistenceTests() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("lineup-clock-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("config.json")
    let store = LineupAppConfigStore(url: url)
    store.load()
    try store.setEnabled(true, for: .worldClock)
    try store.setSettings(JSONValue.object(["untouched": .int(73)]), for: .zones)
    let original = Data(#"{"version":1,"future":"keep","pinnedID":"city:1","places":[{"id":"city:1","name":"Porto","timeZoneID":"Europe/Lisbon","coordinates":{"latitude":41.15,"longitude":-8.61,"altitude":100},"futurePlace":true},{"id":"zone:UTC","name":"UTC","timeZoneID":"UTC"}]}"#.utf8)
    var settings = try JSONDecoder().decode(WorldClockSettings.self, from: original)
    settings.places[0].name = "Home"
    settings.places.swapAt(0, 1)
    try store.setSettings(settings, for: .worldClock)
    let loaded = LineupAppConfigStore(url: url)
    loaded.load()
    let restored = try loaded.config.settings(WorldClockSettings.self, for: .worldClock)!
    check(restored.places.map(\.name) == ["UTC", "Home"] && restored.pinnedID == "city:1",
          "renaming, order and pin survive a real config save and reload")
    let raw = try JSONValue.encoding(restored)
    let rawPlaces: [JSONValue]
    if case .array(let values) = raw["places"] { rawPlaces = values } else { rawPlaces = [] }
    check(raw["future"] == .string("keep") && rawPlaces.last?["futurePlace"] == .bool(true)
          && rawPlaces.last?["coordinates"]?["altitude"] == .int(100),
          "editing places preserves unknown settings, place and coordinate fields")
    check(loaded.config.isEnabled(.worldClock) == true && loaded.config.section(for: .zones)?.settings["untouched"] == .int(73),
          "clock edits preserve enablement and sibling tool settings")
    settings.removePlace(id: "city:1")
    check(settings.pinnedID == nil && settings.places.map(\.id) == ["zone:UTC"], "removing a pinned city restores the icon")
    settings.pinnedID = "local"
    try store.setSettings(settings, for: .worldClock)
    loaded.load()
    check(try loaded.config.settings(WorldClockSettings.self, for: .worldClock)?.pinnedID == "local",
          "the automatic local clock can be pinned and persisted")
    for rejected in [
        #"{"version":2,"places":[]}"#,
        #"{"version":1,"places":[{"id":"x","name":"Bad","timeZoneID":"UTC","coordinates":{"latitude":91,"longitude":0}}]}"#,
        #"{"version":1,"places":[],"pinnedID":"missing"}"#,
        #"{"version":1,"places":[{"id":"x","name":"A","timeZoneID":"UTC"},{"id":"x","name":"B","timeZoneID":"UTC"}]}"#,
    ] {
        do {
            _ = try JSONDecoder().decode(WorldClockSettings.self, from: Data(rejected.utf8))
            check(false, "invalid or newer clock settings must fail to load")
        } catch { check(true, "invalid or newer clock settings are rejected") }
    }
    // An OS no longer recognizing a saved identifier should not lose all the user's cities.
    let unknownZone = try JSONDecoder().decode(WorldClockSettings.self, from:
        Data(#"{"version":1,"places":[{"id":"zone:future","name":"Future","timeZoneID":"Future/City"}]}"#.utf8))
    check(unknownZone.places.first?.timeZone == nil && unknownZone.places.first?.name == "Future",
          "unavailable time zones remain recoverable as saved places")
    let rejectedEnvelope = Data("not valid JSON".utf8)
    try rejectedEnvelope.write(to: url)
    store.load()
    do {
        try store.setSettings(settings, for: .worldClock)
        check(false, "clock writes must not replace a rejected envelope")
    } catch {
        check(try Data(contentsOf: url) == rejectedEnvelope, "failed clock save preserves the rejected bytes")
    }
}

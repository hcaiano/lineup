import AppCore
import Foundation
import SwiftUI
import WorldClockCore

@MainActor
final class WorldClockModel: ObservableObject {
    @Published private(set) var settings = WorldClockSettings()
    @Published private(set) var now = Date()
    @Published private(set) var timeline = ClockTimeline(now: Date())
    @Published var error: String?
    @Published private(set) var sectionLoadError: String?
    var sharedConfigBlockedMessage: (() -> String?)?
    @Published var isRunning = false
    @Published private(set) var searchResults: [ClockPlace] = []
    @Published private(set) var catalogLoading = false
    @Published private(set) var searching = false
    @Published private(set) var catalogError: String?
    var save: ((WorldClockSettings) throws -> Void)?
    var onChange: (() -> Void)?
    private var catalog: ClockCatalog?
    private var catalogTask: Task<Void, Never>?
    private var searchTask: Task<Void, Never>?
    private var query = ""
    private var solarCache: [String: SolarSummary] = [:]

    var canEdit: Bool { blockedMessage == nil && save != nil }
    var blockedMessage: String? { sharedConfigBlockedMessage?() ?? sectionLoadError }
    var selectedDate: Date { timeline.date(now: now) }
    var orderedRows: [ClockRow] {
        ClockOrdering.rows(places: settings.places, at: selectedDate, localZone: .autoupdatingCurrent)
    }

    func configure(settings: WorldClockSettings, sectionLoadError: String?) {
        self.settings = settings
        self.sectionLoadError = sectionLoadError
    }

    func tick(now: Date = Date()) {
        self.now = now
        if timeline.isLive { timeline.reset(now: now) }
        solarCache.removeAll()
    }

    func reset() {
        now = Date()
        timeline.reset(now: now)
        solarCache.removeAll()
    }

    func scrub(_ steps: Double) {
        timeline.scrub(steps: steps)
        solarCache.removeAll()
    }

    func select(_ date: Date) {
        timeline.select(date)
        solarCache.removeAll()
    }

    func solar(for place: ClockPlace) -> SolarSummary? {
        if let cached = solarCache[place.id] { return cached }
        guard let coordinates = place.coordinates, let zone = place.timeZone else { return nil }
        let result = SolarClock.nextEvent(after: selectedDate, coordinates: coordinates, timeZone: zone)
        solarCache[place.id] = result
        return result
    }

    @discardableResult
    private func edit(_ change: (inout WorldClockSettings) -> Void) -> Bool {
        guard canEdit, let save else { return false }
        var next = settings
        change(&next)
        guard next != settings else { return true }
        do {
            try save(next)
            settings = next
            error = nil
            solarCache.removeAll()
            onChange?()
            search(query)
            return true
        } catch {
            self.error = "Changes couldn’t be saved. \(error.localizedDescription)"
            return false
        }
    }

    func add(_ place: ClockPlace) -> Bool {
        guard !settings.places.contains(where: { $0.id == place.id }) else { return false }
        return edit { $0.places.append(place) }
    }

    func remove(_ id: String) { edit { $0.removePlace(id: id) } }

    func rename(_ id: String, to name: String) -> Bool {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return false }
        return edit { settings in
            if let index = settings.places.firstIndex(where: { $0.id == id }) { settings.places[index].name = name }
        }
    }

    func move(_ id: String, by offset: Int) {
        guard let neighbor = ClockOrdering.neighbor(of: id, by: offset, places: settings.places, at: selectedDate) else { return }
        edit { settings in
            guard let from = settings.places.firstIndex(where: { $0.id == id }),
                  let to = settings.places.firstIndex(where: { $0.id == neighbor }) else { return }
            settings.places.swapAt(from, to)
        }
    }

    func canMove(_ id: String, by offset: Int) -> Bool {
        ClockOrdering.neighbor(of: id, by: offset, places: settings.places, at: selectedDate) != nil
    }

    func pin(_ id: String) { edit { $0.pinnedID = $0.pinnedID == id ? nil : id } }

    func loadCatalog() {
        guard catalog == nil, catalogTask == nil else { return }
        catalogLoading = true
        catalogTask = Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                let roots = [Bundle.main.resourceURL, Bundle.main.bundleURL].compactMap { $0 }
                let catalog = ClockCatalog.bundled(in: roots)
                return (catalog ?? ClockCatalog(tsv: ""), catalog == nil)
            }.value
            guard !Task.isCancelled, let self else { return }
            self.catalog = result.0
            self.catalogError = result.1 || result.0.cityCount == 0
                ? "The city catalog is unavailable. You can still add a time zone." : nil
            self.catalogLoading = false
            self.catalogTask = nil
            self.search(self.query)
        }
    }

    func search(_ query: String) {
        self.query = query
        searchTask?.cancel()
        searchResults = []
        searching = false
        guard let catalog else { return }
        searching = !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let excluded = Set(settings.places.map(\.id))
        searchTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 120_000_000) } catch { return }
            let results = await Task.detached(priority: .userInitiated) {
                catalog.search(query, excluding: excluded)
            }.value
            guard !Task.isCancelled else { return }
            self?.searchResults = results
            self?.searching = false
        }
    }

    func cancelSearch() {
        searchTask?.cancel()
        searchTask = nil
        // Finish one catalog load into the cache, even if the panel closes in the meantime.
        // Reopening reuses it rather than starting another detached parse.
        query = ""
        searchResults = []
        searching = false
    }
}

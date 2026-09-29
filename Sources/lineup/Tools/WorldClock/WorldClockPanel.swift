import AppKit
import SwiftUI
import WorldClockCore

struct WorldClockPanel: View {
    @ObservedObject var model: WorldClockModel
    var maximumHeight: CGFloat = 560
    var close: () -> Void
    @State private var adding = false
    @State private var editing = false
    @State private var query = ""
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let message = model.blockedMessage {
                Label(message, systemImage: "exclamationmark.triangle").font(.caption).padding(12)
            }
            if let error = model.error {
                HStack(alignment: .top) {
                    Label(error, systemImage: "exclamationmark.triangle").font(.caption)
                    Button { model.error = nil } label: { Image(systemName: "xmark") }
                        .buttonStyle(.plain).accessibilityLabel("Dismiss error")
                }.padding(12)
            }
            if adding { search } else { clocks }
        }
        .frame(width: 352)
        .frame(maxHeight: maximumHeight)
        .tint(Color(nsColor: Brand.blue))
        .onExitCommand {
            if adding { adding = false } else if editing { editing = false } else { close() }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            if adding {
                Button { adding = false } label: { Image(systemName: "chevron.left") }
                    .buttonStyle(.plain).accessibilityLabel("Back to clocks")
            }
            Text(adding ? "Add a place" : "World Clock").font(.system(size: 13, weight: .semibold))
            Spacer()
            if !adding {
                Button(editing ? "Done" : "Edit") { editing.toggle() }
                    .buttonStyle(.borderless)
                    .disabled(!model.canEdit || model.settings.places.isEmpty)
                Button {
                    editing = false
                    query = ""
                    adding = true
                    model.loadCatalog()
                    model.search("")
                    searchFocused = true
                } label: { Image(systemName: "plus") }
                    .buttonStyle(.borderless)
                    .disabled(!model.canEdit)
                    .accessibilityLabel("Add a city or time zone")
                    .help("Add a city or time zone")
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 13)
    }

    private var clocks: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 0) {
                    let rows = model.orderedRows
                    ForEach(rows) { row in
                        if row.id != rows.first?.id { Divider().padding(.leading, 44) }
                        switch row {
                        case .local:
                            clockRow(id: "local", name: "Local", zone: .autoupdatingCurrent, place: nil)
                        case .place(let place):
                            if editing {
                                ClockPlaceEditor(place: place, model: model)
                            } else {
                                clockRow(id: place.id, name: place.name, zone: place.timeZone, place: place)
                            }
                        }
                    }
                    if model.settings.places.isEmpty {
                        Text("Add cities to compare their time with yours.")
                            .font(.callout).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 18).padding(.bottom, 18)
                    }
                }
            }
            .frame(height: min(CGFloat(model.settings.places.count + 1) * (editing ? 80 : 64)
                               + CGFloat(model.settings.places.count) + (model.settings.places.isEmpty ? 42 : 0),
                               max(74, maximumHeight - 205 - (model.blockedMessage == nil ? 0 : 90)
                                   - (model.error == nil ? 0 : 60))))
            Divider()
            timeControls
        }
    }

    private func clockRow(id: String, name: String, zone: TimeZone?, place: ClockPlace?) -> some View {
        HStack(spacing: 10) {
            let pinned = model.settings.pinnedID == id
            Button { model.pin(id) } label: {
                Image(systemName: pinned ? "pin.fill" : "pin")
                    .font(.system(size: 12))
                    .foregroundStyle(pinned ? Color(nsColor: Brand.blue) : .secondary)
                    .frame(width: 20, height: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain).disabled(!model.canEdit || (zone == nil && !pinned))
            .accessibilityLabel("\(pinned ? "Unpin" : "Pin") \(name)\(pinned ? "" : " to menu bar")")
            .help(pinned ? "Show the clock icon in the menu bar" : "Show \(name) in the menu bar")
            VStack(alignment: .leading, spacing: 5) {
                Text(name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                if let zone {
                    Text(detail(zone: zone, local: id == "local"))
                        .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                } else {
                    Label("Time zone unavailable", systemImage: "exclamationmark.triangle").font(.caption)
                }
            }
            Spacer(minLength: 6)
            if let zone {
                VStack(alignment: .trailing, spacing: 4) {
                    Text(ClockPresentation.time(model.selectedDate, in: zone))
                        .font(.system(size: 21, weight: .medium, design: .rounded)).monospacedDigit()
                        .lineLimit(1).minimumScaleFactor(0.8)
                    if let place, let solar = model.solar(for: place) {
                        solarLabel(solar, zone: zone)
                    } else {
                        Text(zone.abbreviation(for: model.selectedDate) ?? zone.identifier)
                            .font(.system(size: 11)).foregroundStyle(.tertiary)
                    }
                }
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .frame(height: 64)
        .accessibilityElement(children: .contain)
    }

    private func detail(zone: TimeZone, local: Bool) -> String {
        if local {
            return model.selectedDate.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
        }
        let days = ClockPresentation.dayDifference(at: model.selectedDate, in: zone, relativeTo: .autoupdatingCurrent)
        let day = days == 0 ? "Today" : days == -1 ? "Yesterday" : days == 1 ? "Tomorrow" : "\(days > 0 ? "+" : "")\(days) days"
        return "\(day) · \(ClockPresentation.offset(at: model.selectedDate, in: zone, relativeTo: .autoupdatingCurrent))"
    }

    private func solarLabel(_ summary: SolarSummary, zone: TimeZone) -> some View {
        let title: String
        let symbol: String
        switch summary {
        case .continuousDaylight:
            title = "Polar day"
            symbol = "sun.max"
        case .continuousDarkness:
            title = "Polar night"
            symbol = "moon"
        case .event(let kind, let date):
            symbol = kind == .sunrise ? "sunrise" : "sunset"
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = zone
            let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: model.selectedDate),
                                                to: calendar.startOfDay(for: date)).day ?? 0
            title = ClockPresentation.time(date, in: zone) + (days > 0 ? " +\(days)d" : "")
        }
        return Label(title, systemImage: symbol)
            .font(.system(size: 11)).foregroundStyle(.secondary)
            .help("Estimated next sunrise or sunset at the selected time")
            .accessibilityLabel(solarAccessibility(summary, zone: zone))
    }

    private func solarAccessibility(_ summary: SolarSummary, zone: TimeZone) -> String {
        switch summary {
        case .event(let kind, let date): return "Next \(kind.rawValue), \(ClockPresentation.time(date, in: zone))"
        case .continuousDaylight: return "Continuous daylight"
        case .continuousDarkness: return "Continuous darkness"
        }
    }

    private var timeControls: some View {
        VStack(spacing: 10) {
            HStack {
                Text(model.timeline.isLive ? "Now" : "Selected local time")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(model.timeline.isLive ? .secondary : Color(nsColor: Brand.blue))
                Spacer()
                if !model.timeline.isLive {
                    Button("Now") { model.reset() }.buttonStyle(.borderless)
                        .accessibilityLabel("Return to current time")
                }
            }
            HStack {
                Text(model.selectedDate.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)))
                    .font(.callout).foregroundStyle(.secondary)
                Spacer()
                DatePicker("Local time", selection: Binding(get: { model.selectedDate }, set: { model.select($0) }),
                           in: model.timeline.range, displayedComponents: .hourAndMinute)
                    .datePickerStyle(.field).labelsHidden().fixedSize()
                    .accessibilityLabel("Choose an exact local time")
            }
            ClockScrubber(steps: Binding(get: { model.timeline.steps }, set: { model.scrub($0) }))
                .frame(height: 28)
            HStack {
                Text("−24h")
                Spacer()
                Text("Time scroll")
                Spacer()
                Text("+24h")
            }.font(.system(size: 10)).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 18).padding(.vertical, 14)
    }

    private var search: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("City or time zone", text: $query)
                .textFieldStyle(.roundedBorder).focused($searchFocused)
                .onChange(of: query) { model.search($0) }
                .onSubmit {
                    if let first = model.searchResults.first, model.add(first) { adding = false }
                }
            if model.catalogLoading {
                HStack { ProgressView().controlSize(.small); Text("Loading cities…").font(.callout) }
            } else if model.searching {
                HStack { ProgressView().controlSize(.small); Text("Searching…").font(.callout) }
            }
            if let error = model.catalogError { Label(error, systemImage: "exclamationmark.triangle").font(.caption) }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(model.searchResults) { place in
                        Button {
                            if model.add(place) { adding = false }
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(place.name).font(.system(size: 13, weight: .medium))
                                    Text(place.region ?? "Time zone · no solar data")
                                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                    Text(place.timeZoneID).font(.system(size: 10)).foregroundStyle(.tertiary)
                                }
                                Spacer()
                                Image(systemName: "plus").foregroundStyle(Color(nsColor: Brand.blue))
                            }.padding(.vertical, 9).contentShape(Rectangle())
                        }.buttonStyle(.plain).disabled(!model.canEdit)
                        Divider()
                    }
                    if model.searchResults.isEmpty && !model.catalogLoading && !model.searching {
                        Text(query.isEmpty ? "Search cities worldwide, or enter a time zone such as Europe/Lisbon."
                             : "No matching places. Try a larger nearby city or its time zone. Added places are hidden.")
                            .font(.callout).foregroundStyle(.secondary).padding(.top, 10)
                    }
                }
            }.frame(height: max(100, maximumHeight - 180))
            Text("City data: GeoNames · CC BY 4.0").font(.system(size: 10)).foregroundStyle(.tertiary)
        }.padding(16)
    }
}

private struct ClockPlaceEditor: View {
    let place: ClockPlace
    @ObservedObject var model: WorldClockModel
    @State private var draft = ""

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                TextField("Place name", text: $draft).textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Name for \(place.name)")
                    .onSubmit { _ = model.rename(place.id, to: draft) }
                Button { _ = model.rename(place.id, to: draft) } label: { Image(systemName: "checkmark") }
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || draft == place.name)
                    .accessibilityLabel("Save name for \(place.name)")
            }
            HStack {
                Text(place.timeZoneID).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                if model.canMove(place.id, by: -1) || model.canMove(place.id, by: 1) {
                    Button { model.move(place.id, by: -1) } label: { Image(systemName: "chevron.up") }
                        .disabled(!model.canMove(place.id, by: -1)).accessibilityLabel("Move \(place.name) up")
                        .help("Reorder places with the same local time")
                    Button { model.move(place.id, by: 1) } label: { Image(systemName: "chevron.down") }
                        .disabled(!model.canMove(place.id, by: 1)).accessibilityLabel("Move \(place.name) down")
                        .help("Reorder places with the same local time")
                }
                Button { model.remove(place.id) } label: { Image(systemName: "minus.circle") }
                    .accessibilityLabel("Remove \(place.name)")
            }.buttonStyle(.borderless)
        }.padding(.horizontal, 18).padding(.vertical, 10)
            .disabled(!model.canEdit)
            .onAppear { draft = place.name }
            .onChange(of: place.name) { draft = $0 }
    }
}

private struct ClockScrubber: NSViewRepresentable {
    @Binding var steps: Double

    func makeNSView(context: Context) -> ClockSlider {
        let slider = ClockSlider()
        slider.minValue = -96
        slider.maxValue = 96
        slider.numberOfTickMarks = 49
        slider.tickMarkPosition = .below
        slider.isContinuous = true
        slider.target = context.coordinator
        slider.action = #selector(Coordinator.changed(_:))
        slider.setAccessibilityLabel("Time scroll in 15-minute steps")
        return slider
    }

    func updateNSView(_ slider: ClockSlider, context: Context) {
        context.coordinator.parent = self
        slider.doubleValue = steps
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject {
        var parent: ClockScrubber
        init(_ parent: ClockScrubber) { self.parent = parent }
        @objc func changed(_ sender: NSSlider) { parent.steps = sender.doubleValue.rounded() }
    }
}

private final class ClockSlider: NSSlider {
    private var scrollRemainder = 0.0

    override func scrollWheel(with event: NSEvent) {
        let delta = abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) ? event.scrollingDeltaX : -event.scrollingDeltaY
        scrollRemainder += Double(delta) / (event.hasPreciseScrollingDeltas ? 12 : 1)
        let steps = scrollRemainder.rounded(.towardZero)
        guard steps != 0 else { return }
        scrollRemainder -= steps
        doubleValue = min(maxValue, max(minValue, doubleValue + steps))
        sendAction(action, to: target)
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 123, 125: doubleValue = max(minValue, doubleValue - 1)
        case 124, 126: doubleValue = min(maxValue, doubleValue + 1)
        default: super.keyDown(with: event); return
        }
        sendAction(action, to: target)
    }
}

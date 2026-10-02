import AppKit
import SwiftUI
import WorldClockCore

struct WorldClockPanel: View {
    @ObservedObject var model: WorldClockModel
    var maximumHeight: CGFloat = 560
    var embedded = false
    var close: () -> Void
    @State private var adding = false
    @State private var editing = false
    @State private var editSession = PlaceEditSession()
    @State private var query = ""
    @FocusState private var searchFocused: Bool

    private static let rowHeight: CGFloat = 52
    private static let editingRowHeight: CGFloat = 44

    var body: some View {
        VStack(spacing: 0) {
            header
            if let message = model.blockedMessage {
                PanelWarning(text: message)
                    .padding(.horizontal, 16).padding(.bottom, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let error = model.error {
                HStack(alignment: .top) {
                    PanelWarning(text: error)
                    Spacer(minLength: 4)
                    Button { model.error = nil } label: { Image(systemName: "xmark") }
                        .buttonStyle(.borderless).accessibilityLabel("Dismiss error")
                }
                .padding(.horizontal, 16).padding(.bottom, 10)
            }
            Divider()
            if adding { search } else { clocks }
        }
        .frame(width: 352)
        .frame(maxHeight: maximumHeight)
        .onExitCommand {
            if adding {
                adding = false
            } else if editing {
                editSession.cancelled = true
                editing = false
            } else {
                close()
            }
        }
    }

    /// Pinning only changes the separate menu-bar item, so it is offered only while that item exists.
    private var canPin: Bool { model.settings.showSeparateMenuBarItem && model.canEdit }

    private var header: some View {
        HStack(spacing: 8) {
            if adding {
                Button { adding = false } label: {
                    Image(systemName: "chevron.left").frame(width: 20, height: 22).contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Back to clocks")
            }
            PanelHeader(title: adding ? "Add a Place" : "World Clock") {
                if !adding {
                    if !model.settings.places.isEmpty {
                        Button(editing ? "Done" : "Edit") {
                            editSession.cancelled = false
                            editing.toggle()
                        }
                            .buttonStyle(.borderless)
                            .disabled(!model.canEdit)
                    }
                    Button(action: startAdding) {
                        Image(systemName: "plus").frame(width: 22, height: 22).contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                    .disabled(!model.canEdit)
                    .accessibilityLabel("Add a city or time zone")
                    .help("Add a city or time zone")
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, embedded ? 12 : 14)
        .padding(.bottom, 10)
    }

    private func startAdding() {
        editing = false
        query = ""
        adding = true
        model.loadCatalog()
        model.search("")
        searchFocused = true
    }

    private var clocks: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 0) {
                    let rows = model.orderedRows
                    ForEach(rows) { row in
                        if row.id != rows.first?.id { Divider().padding(.leading, 16) }
                        switch row {
                        case .local:
                            clockRow(id: "local", name: "Local", zone: .autoupdatingCurrent, place: nil)
                        case .place(let place):
                            if editing {
                                ClockPlaceEditor(place: place, model: model, canPin: canPin,
                                                 session: editSession)
                                    .frame(height: Self.editingRowHeight)
                            } else {
                                clockRow(id: place.id, name: place.name, zone: place.timeZone, place: place)
                            }
                        }
                    }
                    if model.settings.places.isEmpty {
                        VStack(spacing: 10) {
                            Text("Add the cities you work with to compare their time with yours.")
                                .font(.callout).foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                                .fixedSize(horizontal: false, vertical: true)
                            Button("Add a City", action: startAdding)
                                .disabled(!model.canEdit)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, 24).padding(.top, 6).padding(.bottom, 16)
                    }
                }
            }
            .frame(height: min(listHeight, availableListHeight))
            Divider()
            timeControls
        }
    }

    private var listHeight: CGFloat {
        let places = CGFloat(model.settings.places.count)
        return Self.rowHeight + places * ((editing ? Self.editingRowHeight : Self.rowHeight) + 1)
            + (model.settings.places.isEmpty ? 84 : 0)
    }

    private var availableListHeight: CGFloat {
        max(Self.rowHeight + 20, maximumHeight - (embedded ? 130 : 140)
            - (model.blockedMessage == nil ? 0 : 60) - (model.error == nil ? 0 : 60))
    }

    private func clockRow(id: String, name: String, zone: TimeZone?, place: ClockPlace?) -> some View {
        let pinned = model.settings.showSeparateMenuBarItem && model.settings.pinnedID == id
        return HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Text(name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    if pinned {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(Color.accentColor)
                            .accessibilityLabel("Shown in the menu bar")
                            .help("Shown in the menu bar")
                    }
                }
                if let zone {
                    Text(detail(zone: zone, local: id == "local"))
                        .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                } else {
                    Label {
                        Text("Time zone unavailable").foregroundStyle(.secondary)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    }
                    .font(.system(size: 11))
                }
            }
            Spacer(minLength: 6)
            if let zone {
                if let place, let solar = model.solar(for: place) {
                    daylight(solar, zone: zone)
                }
                Text(ClockPresentation.time(model.selectedDate, in: zone))
                    .font(.system(size: 22, weight: .regular, design: .rounded)).monospacedDigit()
                    .lineLimit(1).minimumScaleFactor(0.8)
            }
        }
        .padding(.horizontal, 16)
        .frame(height: Self.rowHeight)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .contextMenu {
            if canPin, zone != nil || pinned {
                Button(pinned ? "Unpin from Menu Bar" : "Pin to Menu Bar") { model.pin(id) }
            }
            if let place {
                Button("Remove \(place.name)") { model.remove(place.id) }
                    .disabled(!model.canEdit)
            }
        }
    }

    private func detail(zone: TimeZone, local: Bool) -> String {
        if local {
            return model.selectedDate.formatted(.dateTime.weekday(.wide).day().month(.abbreviated))
        }
        let days = ClockPresentation.dayDifference(at: model.selectedDate, in: zone, relativeTo: .autoupdatingCurrent)
        let day = days == 0 ? "Today" : days == -1 ? "Yesterday" : days == 1 ? "Tomorrow" : "\(days > 0 ? "+" : "")\(days) days"
        return "\(day), \(ClockPresentation.offset(at: model.selectedDate, in: zone, relativeTo: .autoupdatingCurrent))"
    }

    /// Day or night at the selected time. The next sunrise or sunset is an estimate, offered on hover.
    private func daylight(_ summary: SolarSummary, zone: TimeZone) -> some View {
        let isDay: Bool
        let description: String
        switch summary {
        case .continuousDaylight:
            isDay = true
            description = "Polar day"
        case .continuousDarkness:
            isDay = false
            description = "Polar night"
        case .event(let kind, let date):
            isDay = kind == .sunset
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = zone
            let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: model.selectedDate),
                                                to: calendar.startOfDay(for: date)).day ?? 0
            let when = ClockPresentation.time(date, in: zone) + (days == 1 ? " tomorrow" : days > 1 ? " +\(days)d" : "")
            description = "\(kind == .sunrise ? "Sunrise" : "Sunset") at \(when)"
        }
        return Image(systemName: isDay ? "sun.max.fill" : "moon.fill")
            .font(.system(size: 11))
            .foregroundStyle(.tertiary)
            .help(description)
            .accessibilityLabel("\(isDay ? "Daytime" : "Night"). \(description), estimated")
    }

    private var timeControls: some View {
        VStack(spacing: 2) {
            ClockScrubber(steps: Binding(get: { model.timeline.steps }, set: { model.scrub($0) }))
                .frame(height: 26)
            HStack(spacing: 8) {
                if model.timeline.isLive {
                    Text("Now")
                        .foregroundStyle(.secondary)
                } else {
                    Text(offsetText)
                        .foregroundStyle(Color.accentColor)
                        .monospacedDigit()
                    Button("Back to Now") { model.reset() }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Return to current time")
                }
                Spacer(minLength: 4)
                // The scroll moves in 15-minute steps from now; the field reaches an exact time.
                DatePicker("Local time", selection: Binding(get: { model.selectedDate }, set: { model.select($0) }),
                           in: model.timeline.range, displayedComponents: .hourAndMinute)
                    .datePickerStyle(.field)
                    .labelsHidden()
                    .controlSize(.small)
                    .fixedSize()
                    .accessibilityLabel("Exact local time")
                    .help("Type an exact local time")
            }
            .font(.system(size: 11, weight: .medium))
            .frame(minHeight: 22)
        }
        .padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 10)
    }

    private var offsetText: String {
        let minutes = Int((model.timeline.steps * 15).rounded())
        let hours = abs(minutes) / 60
        let remainder = abs(minutes) % 60
        let duration = remainder == 0 ? "\(hours)h" : hours == 0 ? "\(remainder)m" : "\(hours)h \(remainder)m"
        return "\(minutes < 0 ? "−" : "+")\(duration) from now"
    }

    private var search: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("City or time zone", text: $query)
                .textFieldStyle(.roundedBorder).focused($searchFocused)
                .onChange(of: query) { model.search($0) }
                .onSubmit {
                    if let first = model.searchResults.first, model.add(first) { adding = false }
                }
                .padding(.horizontal, 16)
            if model.catalogLoading || model.searching {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small).scaleEffect(0.8)
                    Text(model.catalogLoading ? "Loading cities…" : "Searching…")
                        .font(.callout).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 16)
            }
            if let error = model.catalogError {
                PanelWarning(text: error).padding(.horizontal, 16)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(model.searchResults) { place in
                        Button {
                            if model.add(place) { adding = false }
                        } label: {
                            HStack(spacing: 10) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(place.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                                    Text(place.region ?? place.timeZoneID)
                                        .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer(minLength: 6)
                                if let zone = place.timeZone {
                                    Text(ClockPresentation.time(model.now, in: zone))
                                        .font(.system(size: 12)).monospacedDigit().foregroundStyle(.secondary)
                                }
                            }
                            .padding(.vertical, 5)
                        }
                        .buttonStyle(PanelRowButtonStyle())
                        .disabled(!model.canEdit)
                        .accessibilityHint("Adds \(place.name)")
                    }
                    if model.searchResults.isEmpty && !model.catalogLoading && !model.searching {
                        Text(query.isEmpty ? "Search for a city, or enter a time zone such as Europe/Lisbon."
                             : "No matches. Try a larger nearby city or a time zone.")
                            .font(.callout).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 8).padding(.top, 6)
                    }
                }
                .padding(.horizontal, 8)
            }
            // A steady height keeps the popover from jumping while results change under typing.
            .frame(height: min(300, max(100, maximumHeight - (embedded ? 150 : 160))))
            Text("City data: GeoNames, CC BY 4.0")
                .font(.system(size: 10)).foregroundStyle(.tertiary)
                .padding(.horizontal, 16)
        }
        .padding(.top, 10).padding(.bottom, 10)
    }
}

/// Escape ends editing without saving typed names; Done keeps them. A reference, because the
/// editors read it as they disappear, after the render that set it.
private final class PlaceEditSession {
    var cancelled = false
}

private struct ClockPlaceEditor: View {
    let place: ClockPlace
    @ObservedObject var model: WorldClockModel
    let canPin: Bool
    let session: PlaceEditSession
    @State private var draft = ""

    var body: some View {
        HStack(spacing: 6) {
            Button { model.remove(place.id) } label: {
                Image(systemName: "minus.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Remove \(place.name)")
            .help("Remove")
            TextField("Name", text: $draft)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Name for \(place.name)")
                .onSubmit(commit)
            if canPin {
                let pinned = model.settings.pinnedID == place.id
                Button { model.pin(place.id) } label: {
                    Image(systemName: pinned ? "pin.fill" : "pin")
                        .foregroundStyle(pinned ? Color.accentColor : .secondary)
                        .frame(width: 20, height: 22).contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(pinned ? "Unpin \(place.name) from the menu bar" : "Pin \(place.name) to the menu bar")
                .help(pinned ? "Unpin from Menu Bar" : "Pin to Menu Bar")
            }
            if model.canMove(place.id, by: -1) || model.canMove(place.id, by: 1) {
                Button { model.move(place.id, by: -1) } label: { Image(systemName: "chevron.up") }
                    .disabled(!model.canMove(place.id, by: -1)).accessibilityLabel("Move \(place.name) up")
                    .help("Reorder places with the same time")
                Button { model.move(place.id, by: 1) } label: { Image(systemName: "chevron.down") }
                    .disabled(!model.canMove(place.id, by: 1)).accessibilityLabel("Move \(place.name) down")
                    .help("Reorder places with the same time")
            }
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 16)
        .disabled(!model.canEdit)
        .onAppear { draft = place.name }
        .onChange(of: place.name) { draft = $0 }
        // Done keeps a typed name, as other macOS lists do; Escape discards it.
        .onDisappear { if !session.cancelled { commit() } }
    }

    private func commit() {
        let name = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != place.name else { return }
        _ = model.rename(place.id, to: name)
    }
}

private struct ClockScrubber: NSViewRepresentable {
    @Binding var steps: Double

    func makeNSView(context: Context) -> ClockSlider {
        let slider = ClockSlider()
        slider.minValue = -96
        slider.maxValue = 96
        // One mark every six hours keeps Now visibly centred without a dense ruler.
        slider.numberOfTickMarks = 9
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

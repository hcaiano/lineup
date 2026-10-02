import SwiftUI

struct WorldClockSettingsPane: View {
    @ObservedObject var model: WorldClockModel
    var openPanel: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SettingsMetrics.sectionSpacing) {
                if let message = model.blockedMessage {
                    BlockedBanner(message: message, systemImage: "exclamationmark.triangle.fill")
                }
                SettingsSectionView("Places") {
                    SettingsRow(title: placesTitle,
                                detail: "Add, rename and remove places in the Lineup panel.") {
                        Button("Open World Clock", action: openPanel)
                            .disabled(!model.isRunning)
                            .help(model.isRunning ? "" : "Turn on World Clock first")
                    }
                }
                SettingsSectionView("Menu bar") {
                    SettingsRow(title: "Separate clock", detail: "Adds a clock to the menu bar next to Lineup.") {
                        Toggle("Separate clock", isOn: Binding(
                            get: { model.settings.showSeparateMenuBarItem },
                            set: { model.setSeparateMenuBarItem($0) }))
                            .labelsHidden().toggleStyle(.switch)
                            .disabled(!model.canEdit)
                    }
                    if model.settings.showSeparateMenuBarItem {
                        SettingsRow(title: "Shows", detail: "A pinned place shows its name and live time.") {
                            Picker("Shows", selection: Binding(get: { model.settings.pinnedID },
                                                               set: { model.setPinned($0) })) {
                                Text("Clock icon").tag(String?.none)
                                Divider()
                                Text("Local").tag(Optional("local"))
                                ForEach(model.settings.places) { place in
                                    Text(place.name).tag(Optional(place.id))
                                }
                            }
                            .labelsHidden()
                            .frame(width: 180)
                            .disabled(!model.canEdit)
                        }
                    }
                }
                HStack(spacing: 4) {
                    Text("City data:")
                    Link("GeoNames", destination: URL(string: "https://www.geonames.org/")!)
                    Text("·")
                    Link("CC BY 4.0", destination: URL(string: "https://creativecommons.org/licenses/by/4.0/")!)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .frame(width: SettingsMetrics.contentWidth)
            .padding(.vertical, SettingsMetrics.panePaddingVertical)
            .frame(maxWidth: .infinity)
        }
    }

    private var placesTitle: String {
        switch model.settings.places.count {
        case 0: return "No places yet"
        case 1: return "1 place"
        default: return "\(model.settings.places.count) places"
        }
    }
}

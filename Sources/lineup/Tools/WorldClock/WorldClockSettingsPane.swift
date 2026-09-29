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
                SettingsSectionView("Menu bar") {
                    SettingsRow(title: "World Clock", detail: model.isRunning
                                ? "Open the clock to manage cities and compare times."
                                : "Enable World Clock to show its menu bar icon.") {
                        Button("Open World Clock", action: openPanel).disabled(!model.isRunning)
                    }
                    SettingsRow(title: "Pinned place", detail: "Pin one place in the panel to show its name and live time instead of the clock icon.") {
                        Text(pinnedName).foregroundStyle(.secondary)
                    }
                }
                SettingsSectionView("Time and places") {
                    SettingsCaption(text: "Clocks are ordered from earlier to later, with Local in its chronological position. Local follows your Mac; all clocks use its 12- or 24-hour format. The time scroll covers 24 hours in either direction and returns to Now when reopened.")
                        .padding(.vertical, 8)
                    SettingsCaption(text: "Cities and solar calculations work offline. Sunrise and sunset are estimates; a time zone without a city has no solar data.")
                        .padding(.vertical, 8)
                }
                HStack {
                    Link("City data: GeoNames", destination: URL(string: "https://www.geonames.org/")!)
                    Text("·").foregroundStyle(.secondary)
                    Link("CC BY 4.0", destination: URL(string: "https://creativecommons.org/licenses/by/4.0/")!)
                }.font(.caption)
            }
            .frame(width: SettingsMetrics.contentWidth)
            .padding(.vertical, SettingsMetrics.panePaddingVertical)
            .frame(maxWidth: .infinity)
        }
    }

    private var pinnedName: String {
        if model.settings.pinnedID == "local" { return "Local" }
        return model.settings.places.first { $0.id == model.settings.pinnedID }?.name ?? "None"
    }
}

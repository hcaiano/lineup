import AppCore
import SwiftUI

struct AwakeSettingsPane: View {
    @ObservedObject var tool: AwakeTool

    var body: some View {
        VStack(alignment: .leading, spacing: SettingsMetrics.sectionSpacing) {
            if let error = tool.configError ?? tool.message {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            SettingsSectionView("Session") {
                SettingsRow(title: "Duration") {
                    Picker("Duration", selection: Binding(get: { tool.settings.durationMinutes },
                                                         set: { tool.setDuration($0) })) {
                        ForEach(AwakeSettings.durations, id: \.self) { minutes in
                            Text(AwakeSettings.durationLabel(minutes)).tag(minutes)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 130)
                    .disabled(!tool.canEdit)
                }
                SettingsRow(title: "Keep display on", detail: "When off, the display can sleep while your Mac stays awake.") {
                    Toggle("Keep display on", isOn: Binding(get: { tool.settings.keepDisplayOn },
                                                           set: { tool.setDisplayOn($0) }))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .disabled(!tool.canEdit)
                }
                SettingsRow(title: tool.statusText) {
                    if tool.isActive {
                        Button("Stop") { tool.stopSession() }
                    } else {
                        Button("Start") { tool.startSession() }
                            .disabled(!tool.isRunning || !tool.canEdit)
                    }
                }
            }
            SettingsCaption(text: "Sleeping your Mac or quitting Lineup ends the session.")
        }
        .frame(width: SettingsMetrics.contentWidth, alignment: .leading)
        .padding(.vertical, SettingsMetrics.panePaddingVertical)
    }
}

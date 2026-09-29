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
            SettingsSectionView("Session", caption: "Start here or from the Lineup menu bar.") {
                SettingsRow(title: "Duration", detail: "Changing this restarts an active session.") {
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
                SettingsRow(title: "Keep display on", detail: "Off lets the display sleep while the Mac stays awake.") {
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
                        Button("Start session") { tool.startSession() }
                            .disabled(!tool.isRunning || !tool.canEdit)
                    }
                }
            }
            SettingsCaption(text: "You can still lock or sleep your Mac. Sleeping, disabling Keep Awake, or quitting Lineup ends the session. Sessions never resume after restarting Lineup.")
        }
        .frame(width: SettingsMetrics.contentWidth, alignment: .leading)
        .padding(.vertical, SettingsMetrics.panePaddingVertical)
    }
}

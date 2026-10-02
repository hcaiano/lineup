import AppCore
import SwiftUI

/// Idle shows the next session's choices; active leads with the countdown.
struct AwakeQuickPanel: View {
    @ObservedObject var tool: AwakeTool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            PanelHeader(title: "Keep Awake") {
                if !tool.isActive {
                    Text("Off")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }
            if tool.isActive { countdown }
            Picker("Duration", selection: Binding(get: { tool.settings.durationMinutes },
                                                  set: { tool.setDuration($0) })) {
                ForEach(AwakeSettings.durations, id: \.self) { minutes in
                    Text(minutes < 60 ? "\(minutes) min" : "\(minutes / 60) hr").tag(minutes)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: .infinity)
            .disabled(!tool.canEdit)
            .help(tool.isActive ? "Choosing a duration restarts the session" : "Session length")
            Toggle(isOn: Binding(get: { tool.settings.keepDisplayOn }, set: { tool.setDisplayOn($0) })) {
                Text("Keep display on")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            .disabled(!tool.canEdit)
            if let message = tool.configError ?? tool.message {
                PanelWarning(text: message)
            }
            Group {
                if tool.isActive {
                    Button { tool.stopSession() } label: {
                        Text("Stop").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                } else {
                    Button { tool.startSession() } label: {
                        Text("Start").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!tool.isRunning || !tool.canEdit)
                }
            }
            .controlSize(.large)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var countdown: some View {
        VStack(spacing: 2) {
            Text(timeText)
                .font(.system(size: 40, weight: .light, design: .rounded))
                .monospacedDigit()
                .accessibilityLabel("Time remaining")
                .accessibilityValue("\(tool.remainingSeconds / 60) minutes and \(tool.remainingSeconds % 60) seconds")
            Text("Awake until \(Date().addingTimeInterval(Double(tool.remainingSeconds)).formatted(date: .omitted, time: .shortened))")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.bottom, 4)
    }

    private var timeText: String {
        let seconds = tool.remainingSeconds
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, seconds % 60)
                         : String(format: "%02d:%02d", minutes, seconds % 60)
    }
}

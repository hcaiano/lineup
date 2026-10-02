import DisplayControlCore
import SwiftUI

/// Everyday display controls. The panel shows only controls the current connection supports;
/// Settings explains unsupported controls and owns the keyboard preferences.
struct DisplayControlQuickPanel: View {
    @ObservedObject var tool: DisplayControlTool
    @Environment(\.panelActions) private var panel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            PanelHeader(title: "Display Control") {
                if tool.isDiscovering {
                    ProgressView().controlSize(.small).scaleEffect(0.8)
                        .accessibilityLabel("Detecting displays")
                } else if tool.monitors.count == 1, let monitor = tool.monitors.first {
                    Text(monitor.name)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            if tool.monitors.isEmpty {
                if tool.isDiscovering {
                    Text("Detecting displays…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    PanelNotice(text: "No displays detected.", actionTitle: "Detect Again",
                                action: detectAgain)
                }
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(tool.monitors, id: \.connection) { monitor in
                        monitorControls(monitor)
                    }
                }
            }
            if tool.settings.brightnessKeys, tool.settings.synchronizeBrightness {
                HStack(spacing: 8) {
                    Text("Brightness keys synced")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Button("Calibrate…") { panel.openSettings(.displayControl) }
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                        .help("Adjust each display's minimum and maximum brightness in Settings")
                }
            }
            notes
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func monitorControls(_ monitor: DisplayControlMonitor) -> some View {
        let supported: [DisplayControl] = DisplayControl.allCases.filter { monitor[$0].isSupported }
        return VStack(alignment: .leading, spacing: 2) {
            if tool.monitors.count > 1 {
                HStack(spacing: 5) {
                    Text(monitor.name)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .accessibilityAddTraits(.isHeader)
                    if isKeyboardDestination(monitor) {
                        Image(systemName: "keyboard")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("Keyboard destination")
                            .help("Brightness or volume keys control this display")
                    }
                }
            }
            if tool.isBlackedOut(connection: monitor.connection) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Black screen")
                            .font(.callout)
                            .accessibilityLabel("Black screen on \(monitor.name)")
                        Text("Display stays powered on")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 4)
                    Button("Restore") { tool.restoreBrightnessVisibility(connection: monitor.connection) }
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                        .accessibilityLabel("Clear black screen on \(monitor.name)")
                        .help("Clear the black screen without changing hardware brightness")
                }
                .padding(.vertical, 4)
            }
            if supported.isEmpty {
                PanelNotice(text: "Controls aren’t available on this connection.",
                            detail: unsupportedReason(monitor),
                            actionTitle: "Detect Again", action: detectAgain)
                    .padding(.top, 2)
            }
            ForEach(supported, id: \.self) { control in
                DisplayControlQuickLevelRow(tool: tool, monitor: monitor, control: control)
            }
        }
    }

    @ViewBuilder
    private var notes: some View {
        if let error = tool.configError ?? tool.saveError {
            PanelWarning(text: error)
        }
        if let error = tool.keyFailure {
            PanelWarning(text: error, actionTitle: "Open Accessibility Settings", action: { tool.recoverKeys() })
        } else if let message = tool.keyMessage {
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        if let message = tool.blackScreenMessage {
            PanelWarning(text: message)
        }
    }

    private var detectAgain: (() -> Void)? {
        guard tool.isRunning, !tool.isDiscovering else { return nil }
        return { [weak tool] in tool?.rediscover() }
    }

    private func unsupportedReason(_ monitor: DisplayControlMonitor) -> String? {
        for control in DisplayControl.allCases {
            if case .unsupported(let reason) = monitor[control].availability { return reason }
        }
        return nil
    }

    private func isKeyboardDestination(_ monitor: DisplayControlMonitor) -> Bool {
        let brightness = tool.settings.brightnessKeys
            && (tool.settings.brightnessTarget == monitor.stableID
                || (tool.settings.synchronizeBrightness && monitor.brightness.isSupported
                    && tool.settings.monitors[monitor.stableID]?.brightnessKeys != false))
        return brightness
            || (tool.settings.volumeKeys && tool.settings.volumeTarget == monitor.stableID)
    }
}

private struct DisplayControlQuickLevelRow: View {
    @ObservedObject var tool: DisplayControlTool
    let monitor: DisplayControlMonitor
    let control: DisplayControl

    private var title: String { control == .brightness ? "Brightness" : "Volume" }

    var body: some View {
        let status = monitor[control]
        HStack(spacing: 10) {
            symbol(level: status.level?.normalized)
            if let level = status.level {
                let percent = Int((level.normalized * 100).rounded())
                Slider(value: Binding(
                    get: { tool.requestedLevel(connection: monitor.connection, control: control) ?? level.normalized },
                    set: { tool.setLevel($0, connection: monitor.connection, control: control) }), in: 0...1)
                    .controlSize(.small)
                    .disabled(!tool.isRunning)
                    .accessibilityLabel("\(monitor.name) \(title.lowercased())")
                    .accessibilityValue("\(percent) percent")
                Text("\(percent)%")
                    .font(.system(size: 12))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 36, alignment: .trailing)
                    .accessibilityHidden(true)
            } else {
                Text("Couldn’t read \(title.lowercased())")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .help(status.error ?? "")
                Spacer(minLength: 4)
                Button("Retry") { tool.refreshReadings() }
                    .controlSize(.small)
                    .disabled(!tool.isRunning)
                    .accessibilityLabel("Retry reading \(monitor.name) \(title.lowercased())")
            }
        }
        .frame(minHeight: 28)
    }

    /// The speaker reflects the confirmed level, as the system volume control does.
    private func symbol(level: Double?) -> some View {
        let name: String
        switch control {
        case .brightness: name = "sun.max.fill"
        case .volume: name = level == 0 ? "speaker.slash.fill" : "speaker.wave.3.fill"
        }
        return Image(systemName: name, variableValue: control == .volume ? level : nil)
            .font(.system(size: 13))
            .foregroundStyle(.secondary)
            .frame(width: 20, alignment: .center)
            .accessibilityHidden(true)
    }
}

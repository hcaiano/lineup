import AppCore
import DisplayControlCore
import SwiftUI

struct DisplayControlSettingsPane: View {
    @ObservedObject var tool: DisplayControlTool

    var body: some View {
        VStack(alignment: .leading, spacing: SettingsMetrics.sectionSpacing) {
            if let error = tool.configError ?? tool.saveError {
                BlockedBanner(message: error, systemImage: "exclamationmark.triangle.fill")
            }
            SettingsSectionView("Displays") {
                if !tool.isRunning {
                    SettingsCaption(text: "Turn on Display Control to detect your displays.")
                        .padding(.vertical, 10)
                } else if tool.monitors.isEmpty {
                    HStack(spacing: 8) {
                        if tool.isDiscovering { ProgressView().controlSize(.small) }
                        Text(tool.isDiscovering ? "Detecting displays…" : "No displays detected.")
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 12)
                }
                ForEach(tool.monitors, id: \.connection) { monitor in
                    DisplayControlMonitorView(tool: tool, monitor: monitor, showPreferences: true)
                        .padding(.vertical, 12)
                    Divider()
                }
            }
            HStack(alignment: .top, spacing: 18) {
                Text("Works with Apple displays and monitors that support DDC/CI. Some cables, docks and DisplayLink adapters block these controls.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button("Detect Displays") { tool.rediscover() }
                    .disabled(!tool.isRunning || tool.isDiscovering)
                    .help("Detect again after enabling DDC/CI on a monitor or changing its cable")
            }
            .padding(.top, -12)
            SettingsSectionView("Keyboard") {
                keyboardRows(.brightness, title: "Brightness keys")
                keyboardRows(.volume, title: "Volume keys")
            }
            if let error = tool.keyFailure {
                BlockedBanner(message: error, systemImage: "keyboard",
                              actionTitle: "Open Accessibility Settings", action: { tool.recoverKeys() })
            } else if let message = tool.keyMessage {
                SettingsCaption(text: message, systemImage: "info.circle")
            }
            if let message = tool.blackScreenMessage {
                BlockedBanner(message: message, systemImage: "exclamationmark.triangle.fill")
            }
        }
        .frame(width: SettingsMetrics.contentWidth, alignment: .leading)
        .padding(.vertical, SettingsMetrics.panePaddingVertical)
    }

    @ViewBuilder
    private func keyboardRows(_ control: DisplayControl, title: String) -> some View {
        let enabled = control == .brightness ? tool.settings.brightnessKeys : tool.settings.volumeKeys
        let target = control == .brightness ? tool.settings.brightnessTarget : tool.settings.volumeTarget
        SettingsRow(title: title, detail: "Requires Accessibility.") {
            Toggle(title, isOn: Binding(get: { enabled }, set: { tool.setKeys($0, control: control) }))
                .labelsHidden()
                .toggleStyle(.switch)
                .disabled(!tool.canEdit)
        }
        if enabled {
            if control == .brightness {
                SettingsRow(title: "Sync brightness across displays",
                            detail: "Brightness keys change compatible displays together. Sliders stay individual.") {
                    Toggle("Sync brightness across displays", isOn: Binding(
                        get: { tool.settings.synchronizeBrightness },
                        set: { tool.setBrightnessSynchronization($0) }))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .disabled(!tool.canEdit)
                }
                SettingsRow(title: "Black screen below minimum",
                            detail: "Press Brightness Down again at minimum. Brightness Up restores the picture. Escape clears all black screens. The display stays powered on.") {
                    Toggle("Black screen below minimum", isOn: Binding(
                        get: { tool.settings.blackScreenBelowMinimum },
                        set: { tool.setBlackScreenBelowMinimum($0) }))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .disabled(!tool.canEdit)
                }
            }
            let synchronized = control == .brightness && tool.settings.synchronizeBrightness
            let destinationTitle = synchronized ? "Reference display" : "\(title) control"
            SettingsRow(title: destinationTitle,
                        detail: synchronized ? "Its current brightness sets the shared level." : nil) {
                Picker(destinationTitle, selection: Binding<String?>(get: { target }, set: { tool.setTarget($0, control: control) })) {
                    Text("Display under pointer").tag(String?.none)
                    ForEach(uniqueMonitors, id: \.stableID) { monitor in
                        Text(monitor.name).tag(Optional(monitor.stableID))
                    }
                    if let target, !uniqueMonitors.contains(where: { $0.stableID == target }) {
                        Text("Disconnected display").tag(Optional(target))
                    }
                }
                .labelsHidden()
                .frame(width: 205)
                .disabled(!tool.canEdit)
                // A disconnected choice stays selected so keys never reach another display.
                .help("While the chosen display is disconnected, these keys change nothing.")
            }
        }
    }

    private var uniqueMonitors: [DisplayControlMonitor] {
        tool.monitors.filter { monitor in
            tool.monitors.filter { $0.stableID == monitor.stableID }.count == 1
        }
    }
}

struct DisplayControlMonitorView: View {
    @ObservedObject var tool: DisplayControlTool
    let monitor: DisplayControlMonitor
    var showPreferences = false
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(monitor.name).font(compact ? .subheadline.weight(.medium) : .headline)
                .accessibilityAddTraits(.isHeader)
            if !compact, let connection = tool.connectionDescriptions[monitor.connection] {
                Text(connection).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if tool.isBlackedOut(connection: monitor.connection) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Black screen")
                            .accessibilityLabel("Black screen on \(monitor.name)")
                        Text("Display stays powered on")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Restore") { tool.restoreBrightnessVisibility(connection: monitor.connection) }
                        .controlSize(.small)
                        .accessibilityLabel("Clear black screen on \(monitor.name)")
                        .help("Clear the black screen without changing hardware brightness")
                }
            }
            ForEach(DisplayControl.allCases.filter { !compact || monitor[$0].isSupported }, id: \.self) { control in
                levelRow(control)
            }
            if compact, !DisplayControl.allCases.contains(where: { monitor[$0].isSupported }) {
                Text("Controls unavailable for this connection. Check DDC/CI or try another cable.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if showPreferences {
                ForEach(DisplayControl.allCases.filter { monitor[$0].isSupported && keysEnabled($0) }, id: \.self) { control in
                    let preferences = tool.settings.monitors[monitor.stableID] ?? .init()
                    Toggle(control == .brightness ? "Brightness keys can change this display" : "Volume keys can change this display",
                           isOn: Binding(get: { control == .brightness ? preferences.brightnessKeys : preferences.volumeKeys },
                                         set: { tool.setMonitorKeys($0, stableID: monitor.stableID, control: control) }))
                        .disabled(!tool.canEdit || tool.monitors.filter { $0.stableID == monitor.stableID }.count != 1)
                }
                if tool.settings.brightnessKeys, tool.settings.synchronizeBrightness,
                   monitor.brightness.isSupported {
                    brightnessCalibration
                }
            }
        }
    }

    private var brightnessCalibration: some View {
        let preferences = tool.settings.monitors[monitor.stableID] ?? .init()
        let disabled = !tool.canEdit || !preferences.brightnessKeys
            || tool.monitors.filter { $0.stableID == monitor.stableID }.count != 1
        // Supported configs can contain a narrower range than the UI's one-percent step.
        let maximumLowerBound = min(1, max(0.05, preferences.brightnessMinimum + 0.01))
        return VStack(alignment: .leading, spacing: 4) {
            brightnessBoundLabel("Minimum brightness", value: preferences.brightnessMinimum)
            Slider(value: Binding(
                get: { tool.settings.monitors[monitor.stableID]?.brightnessMinimum ?? 0 },
                set: { tool.setBrightnessMinimum($0, stableID: monitor.stableID) }),
                   in: 0...(preferences.brightnessLimit - 0.01), step: 0.01)
                .disabled(disabled)
                .accessibilityLabel("\(monitor.name) minimum brightness")
                .accessibilityValue("\(Int((preferences.brightnessMinimum * 100).rounded())) percent")
            brightnessBoundLabel("Maximum brightness", value: preferences.brightnessLimit)
                .padding(.top, 4)
            Slider(value: Binding(
                get: { tool.settings.monitors[monitor.stableID]?.brightnessLimit ?? 1 },
                set: { tool.setBrightnessLimit($0, stableID: monitor.stableID) }),
                   in: maximumLowerBound...1, step: 0.01)
                .disabled(disabled || maximumLowerBound == 1)
                .accessibilityLabel("\(monitor.name) maximum brightness")
                .accessibilityValue("\(Int((preferences.brightnessLimit * 100).rounded())) percent")
            Text("Shared 0% uses the minimum; 100% uses the maximum. Match displays by eye. Changes apply on the next brightness key press.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 4)
    }

    private func brightnessBoundLabel(_ title: String, value: Double) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text("\(Int((value * 100).rounded()))%")
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
        }
    }

    private func keysEnabled(_ control: DisplayControl) -> Bool {
        control == .brightness ? tool.settings.brightnessKeys : tool.settings.volumeKeys
    }

    @ViewBuilder
    private func levelRow(_ control: DisplayControl) -> some View {
        let status = monitor[control]
        let title = control == .brightness ? "Brightness" : "Volume"
        let symbol = control == .brightness ? "sun.max" : "speaker.wave.2"
        switch status.availability {
        case .unsupported(let reason):
            VStack(alignment: .leading, spacing: 2) {
                Text("\(title) unavailable").font(.callout)
                Text(reason).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .supported:
            if let level = status.level {
                let requested = tool.requestedLevel(connection: monitor.connection, control: control) ?? level.normalized
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Label(title, systemImage: symbol)
                        Spacer()
                        Text("\(Int((level.normalized * 100).rounded()))%")
                            .monospacedDigit()
                            .accessibilityLabel("Confirmed \(title.lowercased()) \(Int((level.normalized * 100).rounded())) percent")
                    }
                    Slider(value: Binding(get: { requested }, set: { tool.setLevel($0, connection: monitor.connection, control: control) }), in: 0...1)
                        .disabled(!tool.isRunning)
                        .accessibilityLabel("\(monitor.name) \(title.lowercased())")
                    if abs(requested - level.normalized) > 0.001 {
                        Text("Setting \(Int((requested * 100).rounded()))%...")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            } else if compact {
                HStack {
                    Label("\(title) unavailable", systemImage: symbol)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Retry") { tool.refreshReadings() }
                        .controlSize(.small)
                        .accessibilityLabel("Retry reading \(monitor.name) \(title.lowercased())")
                        .help(status.error ?? "Read the display's current \(title.lowercased()) again.")
                }
            } else {
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(title): value unavailable")
                    if let error = status.error {
                        Text(error).font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Button("Retry reading \(title.lowercased())") { tool.refreshReadings() }
                }
            }
        }
    }
}

struct DisplayControlMenuView: View {
    @ObservedObject var tool: DisplayControlTool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if tool.isDiscovering { Text("Detecting displays...") }
                else if tool.monitors.isEmpty { Text("No connected displays") }
                ForEach(tool.monitors, id: \.connection) { monitor in
                    DisplayControlMonitorView(tool: tool, monitor: monitor)
                    Divider()
                }
                if let message = tool.keyMessage {
                    Text(message).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(14)
            .frame(width: 320, alignment: .leading)
        }
        .frame(width: 320, height: min(520, CGFloat(max(1, tool.monitors.count)) * 235 + 45))
    }
}

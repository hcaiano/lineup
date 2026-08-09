import AppCore
import HyperkeyCore
import SwiftUI

/// The Hyperkey pane's view model. The tool owns it and pushes `refresh()` on every state change,
/// because `HyperKeyController.apply()` settles asynchronously (hidutil runs on a background
/// queue) — reading status straight after an edit would show the previous state.
///
/// It also caches the orphaned-mapping answer: that probe spawns `hidutil`, so it must not be
/// re-run from a SwiftUI body.
@MainActor
final class HyperkeyPaneModel: ObservableObject {
    @Published private(set) var settings: HyperKeySettings = .disabled
    @Published private(set) var isRunning = false
    @Published private(set) var status: String?
    @Published private(set) var needsInputMonitoring = false
    @Published private(set) var inputMonitoringGranted = false
    @Published private(set) var orphanedMapping = false

    private weak var tool: HyperkeyTool?

    init(tool: HyperkeyTool) {
        self.tool = tool
        refresh()
    }

    func refresh() {
        guard let tool else { return }
        settings = tool.settings
        isRunning = tool.isRunning
        status = tool.statusText
        needsInputMonitoring = tool.needsInputMonitoring
        inputMonitoringGranted = tool.permissions?.isInputMonitoringGranted ?? false
        orphanedMapping = tool.orphanedMapping
    }

    /// Called when the pane appears or the app becomes active again — the two moments a grant or
    /// a leftover mapping can have changed behind our back. Activation is frequent, so only the
    /// pane opening forces the (subprocess-backed) mapping probe.
    func recheck(force: Bool = false) {
        tool?.refreshRecoveryState(force: force)
        refresh()
    }

    var trigger: Binding<TriggerKey> {
        Binding(get: { [weak self] in self?.settings.triggerKey ?? .capsLock },
                set: { [weak self] in self?.tool?.setTrigger($0) })
    }

    var includeShift: Binding<Bool> {
        Binding(get: { [weak self] in self?.settings.includeShift ?? true },
                set: { [weak self] in self?.tool?.setIncludeShift($0) })
    }

    func openInputMonitoringSettings() {
        tool?.permissions?.openInputMonitoringSettings()
        refresh()
    }

    func restoreCapsLock() {
        tool?.restoreCapsLock()
        refresh()
    }

    var blockedStatus: String? {
        guard let status, status.hasPrefix("Blocked") else { return nil }
        return status
    }

    var shortcutHint: String {
        settings.includeShift ? "Sends ⌃⌥⇧⌘ while held." : "Sends ⌃⌥⌘ while held; a physical ⇧ still passes through."
    }
}

/// Settings › Hyperkey. Derived from standalone Cycler's `HyperKeyTab`, rebuilt on the shared
/// `Settings/Components/*` so it matches the Zones and Cycler panes, plus three things Cycler had
/// no reason to show: the Input Monitoring permission row, the leftover-mapping recovery button,
/// and the cross-tool hint (plan §6.4).
///
/// There is no "Enable Hyper Key" toggle here on purpose — the sidebar row's switch is the single
/// authoritative control, and a second one would be two sources of truth for the same flag. The
/// pane stays editable while the tool is off so a trigger can be chosen before turning it on.
struct HyperkeySettingsPane: View {
    @ObservedObject var model: HyperkeyPaneModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                header

                SettingsSectionView("Hyper key") {
                    SettingsRow(title: "Trigger key",
                                detail: "Hold this key to send a Hyper modifier to every app.") {
                        Picker("", selection: model.trigger) {
                            ForEach(TriggerKey.pickerCases, id: \.self) { key in
                                Text(key.displayName).tag(key)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 190)
                    }
                    SettingsRow(title: "Include Shift (⇧)", detail: model.shortcutHint) {
                        Toggle("", isOn: model.includeShift)
                            .labelsHidden()
                            .toggleStyle(.switch)
                    }
                    if model.settings.triggerKey.needsCapsLockRemap {
                        SettingsRow(
                            title: "Caps Lock is remapped while Hyperkey runs",
                            detail: "Lineup restores it when you switch keys, turn Hyperkey off, or quit.") {
                            EmptyView()
                        }
                    }
                }

                if let blocked = model.blockedStatus {
                    SettingsSectionView("Status") {
                        SettingsRow(title: blocked,
                                    detail: model.needsInputMonitoring
                                        ? "Allow Lineup in System Settings, then come back — Hyperkey retries when the app becomes active."
                                        : nil) {
                            if model.needsInputMonitoring {
                                Button("Open Input Monitoring") { model.openInputMonitoringSettings() }
                            } else {
                                EmptyView()
                            }
                        }
                    }
                } else if model.isRunning, let status = model.status {
                    SettingsSectionView("Status") {
                        SettingsRow(title: status, detail: nil) { EmptyView() }
                    }
                }

                SettingsSectionView("Permission") {
                    SettingsRow(
                        title: "Input Monitoring",
                        detail: model.inputMonitoringGranted
                            ? "Granted. Hyperkey needs it to see the trigger key."
                            : "Not granted. Hyperkey can't see the trigger key without it. Lineup asks for this only when you turn Hyperkey on.") {
                        Button(model.inputMonitoringGranted ? "Open System Settings…" : "Grant…") {
                            model.openInputMonitoringSettings()
                        }
                    }
                }

                if model.orphanedMapping {
                    SettingsSectionView("Recovery") {
                        SettingsRow(
                            title: "Caps Lock is still remapped",
                            detail: "A Caps Lock → F18 mapping is applied that no running app claims — usually a Cycler install that quit without cleaning up. Restoring it is safe.") {
                            Button("Restore Caps Lock") { model.restoreCapsLock() }
                        }
                    }
                }

                hint
            }
            .frame(maxWidth: SettingsMetrics.contentWidth, alignment: .leading)
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .navigationTitle("Hyperkey")
        .onAppear { model.recheck() }
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification)) { _ in model.recheck() }
    }

    // MARK: - Chrome

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "capslock")
                    .foregroundStyle(Color(nsColor: Brand.hyperkeyAccent))
                Text("Hyperkey")
                    .font(.headline)
                if !model.isRunning {
                    Text("Off")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Text(model.isRunning
                 ? "One key, held, becomes a system-wide modifier no app uses by itself."
                 : "Turn Hyperkey on with the switch beside it in the sidebar. You can pick the trigger first.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Plan §6.4 — the one genuinely load-bearing cross-tool message in the suite: Zones' defaults
    /// and most Cycler bindings are ⌃⌥⇧⌘, and with Hyperkey off the user needs a hyper source from
    /// somewhere.
    private var hint: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "lightbulb")
                .foregroundStyle(.secondary)
            Text("Zones and Cycler shortcuts use ⌃⌥⇧⌘. Turn Hyperkey on to get that from Caps Lock without Karabiner or Raycast.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .textBackgroundColor).opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(Color.primary.opacity(0.08)))
    }
}

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
    struct AlertItem: Identifiable { let id = UUID(); let title: String; let message: String }

    @Published private(set) var settings: HyperKeySettings = .disabled
    @Published private(set) var isRunning = false
    @Published private(set) var status: String?
    @Published private(set) var needsInputMonitoring = false
    @Published private(set) var inputMonitoringGranted = false
    @Published private(set) var orphanedMapping = false
    /// False when the store refuses writes. The pane then shows a banner and disables the
    /// controls, the same way the Zones and Cycler panes do — a picker that silently discards the
    /// choice is worse than one that is visibly off.
    @Published private(set) var canEdit = true
    /// Why editing is off, if it is.
    @Published private(set) var blockedMessage: String?
    /// Whether the recovery reset itself can be written, which is a weaker gate than `canEdit`.
    @Published private(set) var canReset = false
    /// A refused or failed save, surfaced once (standalone Cycler alerted on this).
    @Published var alert: AlertItem?

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
        canEdit = tool.canPersist
        canReset = tool.canResetSection
        blockedMessage = tool.canPersist ? nil : (tool.configBlockedMessage
            ?? "Your settings file couldn’t be read. It was left untouched, so changes won’t be saved.")
    }

    /// Preserve the unreadable section and start again from a disabled Hyperkey. Offered by the
    /// pane's blocked banner, the same recovery the menu bar's warning row offers.
    func resetSection() {
        tool?.resetSection()
        refresh()
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
                set: { [weak self] value in self?.edit { $0.setTrigger(value) } })
    }

    var includeShift: Binding<Bool> {
        Binding(get: { [weak self] in self?.settings.includeShift ?? true },
                set: { [weak self] value in self?.edit { $0.setIncludeShift(value) } })
    }

    /// Run one edit and surface a failed save. Called from a control's setter — a user action —
    /// so publishing the alert here can never land inside a SwiftUI view update.
    private func edit(_ change: (HyperkeyTool) -> Void) {
        guard let tool else { return }
        change(tool)
        refresh()
        if let message = tool.takeSaveError() {
            alert = AlertItem(title: "Couldn’t save your Hyperkey settings.", message: message)
        }
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

    /// The standing fact about the chosen trigger, if it has one. Shown as the section's caption
    /// rather than as a row with no control in it.
    var triggerCaption: String? {
        if settings.triggerKey.needsCapsLockRemap {
            return "Caps Lock is remapped while Hyperkey runs. Lineup restores it when you switch "
                + "keys, turn Hyperkey off, or quit."
        }
        if settings.triggerKey.isFunctionKey {
            // Without the system setting the key sends its media action (brightness, volume) and
            // Hyperkey's tap never sees a plain F-key at all.
            return "Function keys need “Use F1, F2, etc. keys as standard function keys” in "
                + "System Settings > Keyboard."
        }
        return nil
    }
}

/// Settings › Hyperkey. Derived from standalone Cycler's `HyperKeyTab`, rebuilt on the shared
/// `Settings/Components/*` so it matches the Zones and Cycler panes, plus three things Cycler had
/// no reason to show: the Input Monitoring permission row, the leftover-mapping recovery button,
/// and the cross-tool hint (plan §6.4).
///
/// There is no title and no "Enable Hyper Key" toggle here on purpose — the shell's `ToolPane`
/// draws both, and a second copy of either would be two sources of truth for the same thing. The
/// pane stays editable while the tool is off so a trigger can be chosen before turning it on.
struct HyperkeySettingsPane: View {
    @ObservedObject var model: HyperkeyPaneModel

    var body: some View {
        VStack(spacing: 0) {
            // Same write-blocked treatment as the Zones and Cycler panes: one shared banner, say
            // why, offer the way out, and turn the controls off rather than let an edit vanish on
            // save. Pinned above the scroll view so it cannot scroll away from the dead controls
            // it explains.
            if let message = model.blockedMessage {
                PinnedBannerStrip {
                    BlockedBanner(message: message,
                                  actionTitle: "Reset Hyperkey Settings…",
                                  action: { model.resetSection() },
                                  actionEnabled: model.canReset)
                }
            }

            ScrollView {
                VStack(alignment: .leading, spacing: SettingsMetrics.sectionSpacing) {
                    SettingsSectionView("Hyper key", caption: model.triggerCaption) {
                        SettingsRow(title: "Trigger key",
                                    detail: "Hold this key to send a Hyper modifier to every app.") {
                            Picker("", selection: model.trigger) {
                                ForEach(TriggerKey.pickerCases, id: \.self) { key in
                                    Text(key.displayName).tag(key)
                                }
                            }
                            .labelsHidden()
                            .frame(width: 190)
                            .disabled(!model.canEdit)
                            // `labelsHidden()` leaves VoiceOver with the row's visual title only,
                            // which it does not read as this control's name.
                            .accessibilityLabel("Trigger key")
                        }
                        SettingsRow(title: "Include Shift (⇧)", detail: model.shortcutHint) {
                            Toggle("", isOn: model.includeShift)
                                .labelsHidden()
                                .toggleStyle(.switch)
                                .disabled(!model.canEdit)
                                .accessibilityLabel("Include Shift")
                        }
                    }

                    if let blocked = model.blockedStatus {
                        SettingsSectionView("Status") {
                            SettingsRow(title: blocked,
                                        detail: model.needsInputMonitoring
                                            ? "Allow Lineup in System Settings, then come back. Hyperkey retries when the app becomes active."
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
                            SettingsCaption(text: status, systemImage: "checkmark.circle")
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
                                detail: "A Caps Lock → F18 mapping is applied that no running app claims, usually a Cycler install that quit without cleaning up. Restoring it is safe.") {
                                Button("Restore Caps Lock") { model.restoreCapsLock() }
                            }
                        }
                    }

                    hint
                }
                .frame(width: SettingsMetrics.contentWidth, alignment: .leading)
                .padding(.vertical, SettingsMetrics.panePaddingVertical)
                .frame(maxWidth: .infinity, alignment: .center)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .navigationTitle("Hyperkey")
        .onAppear { model.recheck() }
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification)) { _ in model.recheck() }
        .alert(item: $model.alert) { a in
            Alert(title: Text(a.title), message: Text(a.message), dismissButton: .default(Text("OK")))
        }
    }

    // MARK: - Chrome

    /// Plan §6.4 — the one genuinely load-bearing cross-tool message in the suite: Zones' defaults
    /// and most Cycler bindings are ⌃⌥⇧⌘, and with Hyperkey off the user needs a hyper source from
    /// somewhere.
    ///
    /// Drawn as a caption, not as a card. It was the only card in the whole window, and its fill
    /// (`textBackgroundColor` at 50%) measured a 1.000 contrast ratio against the light window
    /// background — a card with no card in it. The section-caption treatment is what every other
    /// standing explanation in Settings uses.
    private var hint: some View {
        SettingsCaption(
            text: "Zones and Cycler shortcuts use ⌃⌥⇧⌘. Turn Hyperkey on to get that from Caps "
                + "Lock without Karabiner or Raycast.",
            systemImage: "lightbulb")
    }
}

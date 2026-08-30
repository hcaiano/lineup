import AppKit
import AppCore
import SwiftUI
import TilesCore

/// The small state bridge used by the Tiles pane. It owns no AppKit resources; recording is
/// delegated to `ShortcutRecorder`, and all runtime actions go back through `TilesTool`.
@MainActor
final class TilesSettingsModel: ObservableObject {
    struct AlertItem: Identifiable {
        let id = UUID()
        let title: String
        let message: String
    }

    @Published private(set) var activeWorkspace = 1
    @Published private(set) var tileSpacingEnabled = true
    @Published private(set) var canEdit = false
    @Published private(set) var canReset = false
    @Published private(set) var canUseRuntime = false
    @Published private(set) var blockedMessage: String?
    @Published private(set) var runtimeBlockedMessage: String?
    @Published private(set) var recoveryRequired = false
    @Published private(set) var isRestoringWindows = false
    @Published var alert: AlertItem?

    private weak var tool: TilesTool?
    /// Snapshot once per recording, not once per key. The list includes disabled tools.
    private(set) var boundCombos: [ToolCombo] = []
    /// The pane supplies the shell's user-facing tool names for conflict alerts.
    var toolDisplayName: (ToolID) -> String = { $0.rawValue.capitalized }
    /// The pane lends its recorder so model actions can cancel an active capture first.
    weak var recorder: ShortcutRecorder?
    var cancelRecording: (() -> Void)?

    init(tool: TilesTool) {
        self.tool = tool
        refresh()
    }

    func refresh() {
        guard let tool else { return }
        activeWorkspace = tool.activeWorkspace
        tileSpacingEnabled = tool.settings.tileSpacingEnabled
        canEdit = tool.canEdit
        canReset = tool.canReset
        canUseRuntime = tool.runtimeReady
        blockedMessage = tool.configBlockedMessage
        runtimeBlockedMessage = blockedMessage == nil ? tool.runtimeBlockedMessage : nil
        recoveryRequired = tool.recoveryRequired
        isRestoringWindows = tool.isRestoringWindows
    }

    var shortcutCaption: String? {
        guard let tool else { return nil }
        var hints: [String] = []
        if tool.anyWorkspaceMoveShortcutAvailable() {
            hints.append("Numbers switch workspaces; Shift-number moves the focused window.")
        } else if tool.hyperkeyIncludesShiftForSettings {
            hints.append("Turn off Hyperkey Include Shift to enable Shift-number window moves.")
        }
        if tool.nextWindowReverseShortcutAvailable() {
            hints.append("Shift-Tab reverses the stack.")
        } else if tool.anyReverseShortcutAvailable() {
            hints.append("Hold Shift with an available cyclic shortcut for previous.")
        }
        return hints.isEmpty ? nil : hints.joined(separator: " ")
    }

    var runtimeNeedsAccessibility: Bool {
        runtimeBlockedMessage?.localizedCaseInsensitiveContains("Accessibility") == true
    }

    func prepareForRecording(_ action: String? = nil) {
        tool?.refreshRecommendedDefaultsIfNeeded(excluding: action)
        boundCombos = tool?.boundCombos() ?? []
        refresh()
    }

    func selectWorkspace(_ workspace: Int) {
        guard canUseRuntime else { return }
        tool?.selectWorkspace(workspace)
        refresh()
    }

    func setTileSpacingEnabled(_ enabled: Bool) {
        guard canEdit else { return }
        tool?.setTileSpacingEnabled(enabled)
        refresh()
    }

    func openAccessibilitySettings() {
        tool?.openAccessibilitySettings()
    }

    func retryRuntime() {
        tool?.retryRuntime()
        refresh()
    }

    func restoreWindows() {
        tool?.restoreWindows()
        refresh()
    }

    func resetSection() {
        cancelRecording?()
        tool?.resetSection()
        refresh()
    }

    func applyCapture(_ capture: ShortcutRecorder.Capture, for action: String) {
        guard canEdit else { return }
        tool?.applyCapture(capture, for: action)
        refresh()
    }

    func shortcutText(for action: String) -> String {
        guard let binding = tool?.binding(for: action) else { return "" }
        return ShortcutKit.display(keyCode: binding.keyCode, modifiers: binding.modifiers)
    }

    func workspaceMoveShortcutState(for workspace: Int) -> TilesTool.WorkspaceMoveShortcutState {
        tool?.workspaceMoveShortcutState(for: workspace) ?? .workspaceShortcutMissing
    }

    func showAlert(title: String, message: String) {
        alert = AlertItem(title: title, message: message)
    }
}

/// Settings > Tiles. The shared `ToolPane` draws the title, summary, icon and global switch.
/// This view supplies the compact, opinionated sections from the product contract.
struct TilesSettingsPane: View {
    @ObservedObject var model: TilesSettingsModel
    @EnvironmentObject private var settings: SettingsStore

    var body: some View {
        TilesSettingsPaneBody(model: model, settings: settings)
    }
}

private struct TilesSettingsPaneBody: View {
    @ObservedObject var model: TilesSettingsModel
    @StateObject private var recorder: ShortcutRecorder
    private let settings: SettingsStore

    init(model: TilesSettingsModel, settings: SettingsStore) {
        self.model = model
        self.settings = settings
        _recorder = StateObject(wrappedValue: ShortcutRecorder(store: settings))
    }

    var body: some View {
        VStack(spacing: 0) {
            if let message = model.blockedMessage {
                PinnedBannerStrip {
                    BlockedBanner(message: message,
                                  actionTitle: "Reset Tiles Settings…",
                                  action: { model.resetSection() },
                                  actionEnabled: model.canReset)
                }
            }

            if let message = model.runtimeBlockedMessage {
                PinnedBannerStrip {
                    BlockedBanner(message: message,
                                  systemImage: "exclamationmark.triangle.fill",
                                  actionTitle: model.runtimeNeedsAccessibility
                                    ? "Open Accessibility Settings…" : "Retry",
                                  action: model.runtimeNeedsAccessibility
                                    ? { model.openAccessibilitySettings() }
                                    : { model.retryRuntime() })
                }
            }

            if model.recoveryRequired,
               model.blockedMessage == nil,
               model.runtimeBlockedMessage == nil {
                PinnedBannerStrip {
                    BlockedBanner(
                        message: !model.canUseRuntime
                            ? "Some windows still need to be restored. Turn Tiles on to restore them."
                            : model.isRestoringWindows
                            ? "Tiles is restoring windows from the previous session."
                            : "Some windows still need to be restored from the previous session.",
                        systemImage: "arrow.counterclockwise.circle.fill",
                        actionTitle: model.isRestoringWindows || !model.canUseRuntime
                            ? nil : "Restore Windows",
                        action: model.isRestoringWindows || !model.canUseRuntime
                            ? nil : { model.restoreWindows() })
                }
            }

            ScrollView {
                VStack(alignment: .leading, spacing: SettingsMetrics.sectionSpacing) {
                    SettingsSectionView("Workspace") {
                        Picker("", selection: Binding(
                            get: { model.activeWorkspace },
                            set: { model.selectWorkspace($0) })) {
                            ForEach(1...4, id: \.self) { workspace in
                                Text("\(workspace)")
                                    .tag(workspace)
                                    .accessibilityLabel("Workspace \(workspace)")
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .disabled(!model.canUseRuntime)
                        .accessibilityLabel(model.canUseRuntime
                                            ? "Active workspace"
                                            : "Starting workspace")

                        SettingsCaption(
                            text: model.canUseRuntime
                                ? "Uses your Zones layouts. Workspaces are separate from macOS Spaces. Use a Zones Hyper+arrow quick action to float a window."
                                : "Tiles starts in Workspace \(model.activeWorkspace). It uses your Zones layouts when enabled.",
                            systemImage: "square.grid.3x3")
                            .padding(.top, 8)
                    }

                    SettingsSectionView("Behavior") {
                        SettingsRow(title: "Space between tiles",
                                    detail: "Keep \(Int(TilesSettings.tileSpacingPoints)) pt between tiled windows.") {
                            Toggle("", isOn: Binding(get: { model.tileSpacingEnabled },
                                                     set: { model.setTileSpacingEnabled($0) }))
                                .labelsHidden()
                                .toggleStyle(.switch)
                                .disabled(!model.canEdit)
                                .accessibilityLabel("Space between tiles")
                                .accessibilityValue(model.tileSpacingEnabled ? "On" : "Off")
                        }
                        SettingsCaption(
                            text: "New windows fill empty tiles, then stack. Stacked windows cycle in the focused tile.",
                            systemImage: "square.stack.3d.up")
                    }

                    SettingsSectionView("Shortcuts", caption: model.shortcutCaption) {
                        shortcutGroup("Workspace and stacks", .workspaceAndStacks)
                        shortcutGroup("Focus tile", .focus)
                        shortcutGroup("Move window", .move)
                        shortcutGroup("Layout", .layout)
                    }
                }
                .frame(width: SettingsMetrics.contentWidth, alignment: .leading)
                .padding(.vertical, SettingsMetrics.panePaddingVertical)
                .frame(maxWidth: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .navigationTitle("Tiles")
        .onAppear {
            model.refresh()
            model.recorder = recorder
            model.cancelRecording = { [weak recorder] in recorder?.cancel() }
            model.toolDisplayName = { [weak settings] id in
                settings?.displayName(for: id) ?? id.rawValue.capitalized
            }
        }
        .onDisappear {
            recorder.cancel()
            guard model.recorder === recorder else { return }
            model.recorder = nil
            model.cancelRecording = nil
        }
        .alert(item: $model.alert) { item in
            Alert(title: Text(item.title), message: Text(item.message),
                  dismissButton: .default(Text("OK")))
        }
    }

    @ViewBuilder
    private func shortcutRow(_ row: TilesTool.Action) -> some View {
        HStack(spacing: 12) {
            Text(row.title)
            Spacer(minLength: 18)
            RecorderButton(
                text: model.shortcutText(for: row.rawValue),
                emptyText: "Set shortcut",
                isRecording: recorder.isRecording(row.rawValue),
                enabled: model.canEdit,
                accessibilityLabel: "Shortcut for \(row.title)",
                rejectionCount: recorder.rejectionCount,
                action: { record(row.rawValue) })
            CircleClearButton(
                help: "Clear shortcut",
                accessibilityLabel: "Clear shortcut for \(row.title)",
                disabled: !model.canEdit || model.shortcutText(for: row.rawValue).isEmpty,
                action: { clear(row.rawValue) })
        }
        .frame(minHeight: SettingsMetrics.shortcutRowHeight)
        .padding(.vertical, 3)
        Divider()
    }

    @ViewBuilder
    private func shortcutGroup(_ title: String, _ group: TilesTool.Action.Group) -> some View {
        Text(title)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 4)
        switch group {
        case .workspaceAndStacks:
            ForEach(TilesTool.Action.allCases.filter { $0.workspaceNumber != nil }, id: \.self) { row in
                shortcutRow(row)
            }
            ForEach(1...4, id: \.self) { workspace in
                workspaceMoveShortcutRow(workspace)
            }
            shortcutRow(.nextWindow)
        case .focus, .move, .layout:
            ForEach(TilesTool.Action.allCases.filter { $0.group == group }, id: \.self) { row in
                shortcutRow(row)
            }
        }
    }

    @ViewBuilder
    private func workspaceMoveShortcutRow(_ workspace: Int) -> some View {
        let title = "Move Window to Workspace \(workspace)"
        let state = model.workspaceMoveShortcutState(for: workspace)
        HStack(spacing: 12) {
            Text(title)
            Spacer(minLength: 18)
            Group {
                switch state {
                case .shortcut(let shortcut):
                    KeyCapRow(display: shortcut)
                case .workspaceShortcutMissing:
                    Text("Set Workspace \(workspace) first")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                case .unavailableWithIncludeShift:
                    Text("Unavailable with Include Shift")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(minWidth: 164)
            Color.clear
                .frame(width: 16, height: 16)
                .accessibilityHidden(true)
        }
        .frame(minHeight: SettingsMetrics.shortcutRowHeight)
        .padding(.vertical, 3)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(workspaceMoveAccessibilityValue(state, workspace: workspace))
        Divider()
    }

    private func workspaceMoveAccessibilityValue(
        _ state: TilesTool.WorkspaceMoveShortcutState,
        workspace: Int
    ) -> String {
        switch state {
        case .shortcut(let shortcut): return shortcut
        case .workspaceShortcutMissing:
            return "Unavailable until Workspace \(workspace) has a shortcut"
        case .unavailableWithIncludeShift:
            return "Unavailable while Hyperkey includes Shift"
        }
    }

    private func record(_ action: String) {
        guard model.canEdit else { return }
        model.prepareForRecording(action)
        recorder.toggle(action) { capture in
            model.applyCapture(capture, for: action)
        }
    }

    private func clear(_ action: String) {
        guard model.canEdit else { return }
        recorder.cancel()
        model.applyCapture(.clear, for: action)
    }
}

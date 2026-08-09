import AppKit
import AppCore
import SwiftUI

/// Sidebar destinations, in fixed order: General / Zones / Cycler / Hyperkey / About.
enum SettingsSection: Hashable {
    case general
    case tool(ToolID)
    case about
}

/// One sidebar row for a registered tool.
struct ToolRow: Identifiable, Equatable {
    let id: ToolID
    let name: String
    let summary: String
    let iconSymbol: String
    var isEnabled: Bool
    var isRunning: Bool
}

/// The Settings window's view model, and the owner of the GLOBAL recording suspension.
///
/// Every recorder in every pane routes through `beginRecording(_:cancel:)` / `endRecording(_:)`
/// — in practice through `ShortcutRecorder`, which wraps them — and those suspend and resume the
/// whole Carbon registry. That is what makes shortcut recording safe across three tools: while a
/// recorder is live, no tool's hotkey can fire, and an already-bound combo can be re-recorded.
/// Ref-counted in `HotkeyManager`, so overlapping recorders can't leave the registry suspended.
/// Panes must never call `HotkeyManager.suspendAll()` themselves.
@MainActor
final class SettingsStore: ObservableObject {
    @Published var selection: SettingsSection? = .general
    @Published private(set) var toolRows: [ToolRow] = []
    @Published private(set) var isAccessibilityTrusted: Bool
    @Published private(set) var isInputMonitoringGranted: Bool
    /// Mirrors `general.showMenuBarIcon`. The shell hands back what is ACTUALLY in force after the
    /// write, so a refused save puts the switch back instead of showing a preference the user does
    /// not have — the same self-correction `launchAtLogin` does below.
    @Published var showMenuBarIcon: Bool {
        didSet {
            guard showMenuBarIcon != oldValue else { return }
            let actual = onMenuBarIconChange(showMenuBarIcon)
            if actual != showMenuBarIcon { showMenuBarIcon = actual }
        }
    }
    @Published var launchAtLogin: Bool {
        didSet {
            guard launchAtLogin != oldValue else { return }
            LaunchAtLogin.set(launchAtLogin)
            let actual = LaunchAtLogin.isEnabled
            if actual != launchAtLogin { launchAtLogin = actual } // a failed toggle must not lie
        }
    }

    /// The last tool switch that could not be saved, surfaced by the pane. Cleared as soon as one
    /// succeeds, or when the user dismisses it.
    @Published private(set) var toolEnableError: String?

    private let registry: ToolRegistry
    private let permissions: PermissionCenter
    /// Returns the value that is actually in force after the write, which is the OLD one when the
    /// store refused it.
    private let onMenuBarIconChange: (Bool) -> Bool
    private var recordingDepth = 0
    /// Live recorders, keyed by object identity, each with the block that cancels its capture.
    /// The identity is what lets `stopAllRecording()` (blur, window close) tear down exactly the
    /// recorders that are open instead of only draining the suspension count.
    private var activeRecorders: [ObjectIdentifier: () -> Void] = [:]

    init(registry: ToolRegistry,
         permissions: PermissionCenter,
         showMenuBarIcon: Bool,
         onMenuBarIconChange: @escaping (Bool) -> Bool) {
        self.registry = registry
        self.permissions = permissions
        self.showMenuBarIcon = showMenuBarIcon
        self.onMenuBarIconChange = onMenuBarIconChange
        self.launchAtLogin = LaunchAtLogin.isEnabled
        self.isAccessibilityTrusted = permissions.isAccessibilityTrusted
        self.isInputMonitoringGranted = permissions.isInputMonitoringGranted
        refresh()
    }

    /// Recompute everything the window shows. Called on open and whenever the shell notices a
    /// change (permission granted, tool started/stopped, config saved).
    func refresh() {
        toolRows = registry.tools.map {
            ToolRow(id: $0.id, name: $0.displayName, summary: $0.summary,
                    iconSymbol: $0.iconSymbol, isEnabled: registry.isEnabled($0.id),
                    isRunning: $0.isRunning)
        }
        isAccessibilityTrusted = permissions.isAccessibilityTrusted
        isInputMonitoringGranted = permissions.isInputMonitoringGranted
        toolEnableError = registry.lastEnableError
        let login = LaunchAtLogin.isEnabled
        if login != launchAtLogin { launchAtLogin = login }
        objectWillChange.send()
    }

    /// Dismiss the failed-toggle message.
    func clearToolEnableError() {
        registry.clearEnableError()
        toolEnableError = nil
    }

    // MARK: - Tools

    /// The tool's display name, or its raw id when the tool isn't registered in this build —
    /// used by messages that name an owner (a restore failure, a cross-tool combo conflict).
    func displayName(for id: ToolID) -> String {
        toolRows.first { $0.id == id }?.name ?? id.rawValue.capitalized
    }

    /// Reads through to the registry, so a toggle the store refused to persist springs back on
    /// its own — `setEnabled` leaves the flag alone when the write fails.
    ///
    /// No `refresh()` here: `setEnabled` already calls the registry's `onSettingsChange`, which the
    /// shell wires straight to this window's refresh. Doing both rebuilt every row twice per click.
    func binding(forTool id: ToolID) -> Binding<Bool> {
        Binding(
            get: { [weak self] in self?.registry.isEnabled(id) ?? false },
            set: { [weak self] newValue in
                self?.registry.setEnabled(newValue, for: id)
            })
    }

    @ViewBuilder
    func pane(for section: SettingsSection?) -> some View {
        switch section {
        case .general, nil:
            GeneralPane(store: self, permissions: permissions,
                        requirements: registry.permissionRequirements())
        case .tool(let id):
            // The shell draws every tool's header and enable switch (see `ToolPane`); the tool
            // supplies only its own controls.
            //
            // The store is injected into the environment here, and that is the ONLY way a tool
            // pane gets one: `Tool.makeSettingsPane()` takes no arguments, and a pane that went
            // looking for the window itself would be reaching around the shell for the object that
            // owns the global recording suspension.
            if let tool = registry.tool(id) {
                ToolPane(id: id, title: tool.displayName, summary: tool.summary,
                         isOn: binding(forTool: id),
                         enableError: toolEnableError,
                         onDismissEnableError: { [weak self] in self?.clearToolEnableError() }) {
                    tool.makeSettingsPane()
                }
                .environmentObject(self)
            } else {
                PlaceholderPane(title: displayName(for: id))
            }
        case .about:
            AboutPane()
        }
    }

    // MARK: - Recording (global)

    /// Set by the shell to surface rows that failed to re-register after a recording — another
    /// app claimed the combo while we were suspended. Called with a non-empty list only.
    var onRecordingRestoreFailures: (([RestoreFailure]) -> Void)?

    typealias RestoreFailure = (owner: ToolID, keyCode: Int, modifiers: UInt32, status: OSStatus)

    var isRecording: Bool { recordingDepth > 0 }

    /// Whether this particular recorder is capturing. Panes go through `ShortcutRecorder`, which
    /// tracks the finer-grained per-field identity itself.
    func isRecording(_ recorder: AnyObject) -> Bool {
        activeRecorders[ObjectIdentifier(recorder)] != nil
    }

    /// Suspends EVERY tool's hotkeys so `recorder` receives the raw combo.
    ///
    /// `cancel` must abandon the capture without calling back into `endRecording` — it is invoked
    /// by `stopAllRecording()`, which drains the suspension itself. Re-registering an already
    /// live recorder only replaces its cancel block; the suspension is not double-counted.
    func beginRecording(_ recorder: AnyObject, cancel: @escaping () -> Void) {
        let key = ObjectIdentifier(recorder)
        guard activeRecorders.updateValue(cancel, forKey: key) == nil else { return }
        recordingDepth += 1
        HotkeyManager.shared.suspendAll()
    }

    /// Restores them. Returns the rows that failed to come back so the caller can surface them.
    /// A no-op (and empty) when `recorder` is not recording, so double-stopping is safe.
    @discardableResult
    func endRecording(_ recorder: AnyObject) -> [RestoreFailure] {
        guard activeRecorders.removeValue(forKey: ObjectIdentifier(recorder)) != nil else { return [] }
        return resumeOneLevel()
    }

    /// Called from `windowWillClose` and `windowDidResignKey` — a window closed or blurred
    /// mid-recording must leave neither a live event monitor nor a suspended registry.
    func stopAllRecording() {
        let cancels = Array(activeRecorders.values)
        activeRecorders.removeAll()
        for cancel in cancels { cancel() }
        while recordingDepth > 0 { _ = resumeOneLevel() }
    }

    private func resumeOneLevel() -> [RestoreFailure] {
        guard recordingDepth > 0 else { return [] }
        recordingDepth -= 1
        let failures = HotkeyManager.shared.resumeAll()
        guard !failures.isEmpty else { return [] }
        // Tell each OWNER first. The registry keeps a row that failed to come back with a nil
        // Carbon ref — recorded but dead — and a tool that never hears about it will not retry it,
        // so the alert below would be the only trace and the shortcut would stay broken for the
        // rest of the session. The tools put the rows back into their own blocked lists, which is
        // what arms their retry loops and their "Retry shortcuts" warning.
        for (owner, rows) in Dictionary(grouping: failures, by: \.owner) {
            registry.tool(owner)?.hotkeysFailedToRestore(rows.map {
                HotkeyRestoreFailure(keyCode: $0.keyCode, modifiers: $0.modifiers, status: $0.status)
            })
        }
        onRecordingRestoreFailures?(failures)
        return failures
    }

    // Cross-tool combo conflicts are NOT answered here. A pane's model gets the list from its
    // tool's `ToolServices.boundCombos()`, which reads every registered tool's persisted section
    // — the live Carbon registry this store talks to only knows about tools that are running.
}

/// Stand-in for a tool pane that hasn't landed yet (Phase 3 registers no tools at all).
struct PlaceholderPane: View {
    let title: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "wrench.and.screwdriver")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.system(size: 15, weight: .semibold))
            Text("This tool isn’t available in this build.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

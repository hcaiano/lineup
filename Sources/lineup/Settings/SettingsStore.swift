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
/// Every recorder in every pane routes through `beginRecording()` / `endRecording()`, which
/// suspend and resume the whole Carbon registry. That is what makes shortcut recording safe
/// across three tools: while a recorder is live, no tool's hotkey can fire, and an
/// already-bound combo can be re-recorded. Ref-counted in `HotkeyManager`, so overlapping
/// recorders can't leave the registry suspended.
@MainActor
final class SettingsStore: ObservableObject {
    @Published var selection: SettingsSection? = .general
    @Published private(set) var toolRows: [ToolRow] = []
    @Published private(set) var isAccessibilityTrusted: Bool
    @Published private(set) var isInputMonitoringGranted: Bool
    @Published var showMenuBarIcon: Bool {
        didSet { guard showMenuBarIcon != oldValue else { return }; onMenuBarIconChange(showMenuBarIcon) }
    }
    @Published var launchAtLogin: Bool {
        didSet {
            guard launchAtLogin != oldValue else { return }
            LaunchAtLogin.set(launchAtLogin)
            let actual = LaunchAtLogin.isEnabled
            if actual != launchAtLogin { launchAtLogin = actual } // a failed toggle must not lie
        }
    }

    private let registry: ToolRegistry
    private let permissions: PermissionCenter
    private let onMenuBarIconChange: (Bool) -> Void
    private var recordingDepth = 0

    init(registry: ToolRegistry,
         permissions: PermissionCenter,
         showMenuBarIcon: Bool,
         onMenuBarIconChange: @escaping (Bool) -> Void) {
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
        let login = LaunchAtLogin.isEnabled
        if login != launchAtLogin { launchAtLogin = login }
        objectWillChange.send()
    }

    // MARK: - Tools

    func binding(forTool id: ToolID) -> Binding<Bool> {
        Binding(
            get: { [weak self] in self?.registry.isEnabled(id) ?? false },
            set: { [weak self] newValue in
                self?.registry.setEnabled(newValue, for: id)
                self?.refresh()
            })
    }

    @ViewBuilder
    func pane(for section: SettingsSection?) -> some View {
        switch section {
        case .general, nil:
            GeneralPane(store: self, permissions: permissions,
                        requirements: registry.permissionRequirements())
        case .tool(let id):
            if let tool = registry.tool(id) {
                tool.makeSettingsPane()
            } else {
                PlaceholderPane(title: id.rawValue.capitalized)
            }
        case .about:
            AboutPane()
        }
    }

    // MARK: - Recording (global)

    var isRecording: Bool { recordingDepth > 0 }

    /// Suspends EVERY tool's hotkeys so the recorder receives the raw combo.
    func beginRecording() {
        recordingDepth += 1
        HotkeyManager.shared.suspendAll()
    }

    /// Restores them. Returns the rows that failed to come back (another app claimed the combo
    /// while we were suspended) so the caller can surface them.
    @discardableResult
    func endRecording() -> [(owner: ToolID, keyCode: Int, modifiers: UInt32, status: OSStatus)] {
        guard recordingDepth > 0 else { return [] }
        recordingDepth -= 1
        return HotkeyManager.shared.resumeAll()
    }

    /// Called from `windowWillClose` — a window closed mid-recording must not leave the registry
    /// suspended.
    func stopAllRecording() {
        while recordingDepth > 0 { _ = endRecording() }
    }

    /// Combos owned by tools other than `owner`, for cross-tool conflict messages in recorders.
    func foreignCombos(excluding owner: ToolID) -> [(owner: ToolID, keyCode: Int, modifiers: UInt32)] {
        HotkeyManager.shared.registeredCombos().filter { $0.owner != owner }
    }
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

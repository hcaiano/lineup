import AppCore
import SwiftUI

/// General: Startup · Menu bar · Permissions · Updates.
///
/// Built on the shared `SettingsSectionView` / `SettingsRow` pair rather than a pane-local card
/// style, so General, Zones, Cycler and Hyperkey all line up on the same content column and the
/// same row rhythm — whichever tool drew the pane. (This resolves Phase 7a's open question: the
/// card helper that lived here is gone; there is exactly one section style in the window.)
struct GeneralPane: View {
    @ObservedObject var store: SettingsStore
    let permissions: PermissionCenter
    /// Permission -> the tools that need it, so each row can say who it is for.
    let requirements: [(permission: Permission, tools: [String])]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                SettingsSectionView("Startup") {
                    SettingsRow(
                        title: "Launch at login",
                        detail: "Lineup lives in the menu bar. Starting it at login keeps your shortcuts live."
                    ) {
                        Toggle("", isOn: $store.launchAtLogin)
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .accessibilityLabel("Launch at login")
                    }
                }

                SettingsSectionView("Menu bar") {
                    SettingsRow(
                        title: "Show the menu bar icon",
                        detail: "With the icon hidden, open Lineup from Spotlight to get back to Settings."
                    ) {
                        Toggle("", isOn: $store.showMenuBarIcon)
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .accessibilityLabel("Show the menu bar icon")
                    }
                }

                SettingsSectionView("Permissions") {
                    if requirements.isEmpty {
                        SettingsRow(
                            title: "Nothing to grant",
                            detail: "No tool in this build needs a system permission."
                        ) { EmptyView() }
                    }
                    ForEach(requirements, id: \.permission) { requirement in
                        permissionRow(requirement.permission, neededBy: requirement.tools)
                    }
                }

                SettingsSectionView("Updates") {
                    SettingsRow(
                        title: "Software updates",
                        detail: "Lineup checks in the background and installs an update once you agree."
                    ) {
                        Button("Check for Updates…") { AppUpdater.shared.checkForUpdates(nil) }
                    }
                }
            }
            .frame(width: SettingsMetrics.contentWidth, alignment: .leading)
            .padding(.vertical, 24)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("General")
    }

    // MARK: - Rows

    /// One permission: status dot + word, the tools that need it, and the way to go grant it.
    ///
    /// The "Required by" line is computed from every registered tool's `requiredPermissions`, so
    /// it stays honest as tools are added — nothing here names Zones, Cycler or Hyperkey.
    @ViewBuilder
    private func permissionRow(_ permission: Permission, neededBy tools: [String]) -> some View {
        let granted = permission == .accessibility
            ? store.isAccessibilityTrusted
            : store.isInputMonitoringGranted
        SettingsRow(title: permission.displayName,
                    detail: "Required by \(tools.joined(separator: ", "))") {
            HStack(spacing: 12) {
                StatusDot(granted: granted)
                Button(granted ? "Open System Settings…" : "Grant…") {
                    permissions.openSettings(for: permission)
                }
            }
        }
    }
}

/// Green/orange dot plus one word. Deliberately not a red "error": a permission that has not been
/// granted yet is a state, not a failure — the menu's warning row is where the alarm belongs.
private struct StatusDot: View {
    let granted: Bool

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(granted ? Color.green : Color.orange)
                .frame(width: 7, height: 7)
            Text(granted ? "Granted" : "Not granted")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

extension Permission: Identifiable {
    var id: String { displayName }
}

import AppCore
import SwiftUI

/// General: Startup · Menu bar · Permissions · Updates.
///
/// Phase 3 builds this with plain SwiftUI so it does not pre-empt the shared
/// `Settings/Components/*` API that Phase 7a freezes; the visual pass happens there.
struct GeneralPane: View {
    @ObservedObject var store: SettingsStore
    let permissions: PermissionCenter
    /// Permission -> the tools that need it, so each row can say who it is for.
    let requirements: [(permission: Permission, tools: [String])]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                section("Startup") {
                    Toggle("Launch at login", isOn: $store.launchAtLogin)
                    caption("Lineup runs in the menu bar. Starting it at login keeps your shortcuts live.")
                }

                section("Menu bar") {
                    Toggle("Show the menu bar icon", isOn: $store.showMenuBarIcon)
                    caption("With the icon hidden, open Lineup from Spotlight to get back to Settings.")
                }

                section("Permissions") {
                    if requirements.isEmpty {
                        caption("No tools are enabled, so Lineup needs no permissions right now.")
                    }
                    ForEach(requirements, id: \.permission) { requirement in
                        permissionRow(requirement.permission, neededBy: requirement.tools)
                    }
                }

                section("Updates") {
                    Button("Check for Updates…") { AppUpdater.shared.checkForUpdates(nil) }
                    caption("Lineup checks for updates in the background and installs them when you agree.")
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle("General")
    }

    // MARK: - Rows

    @ViewBuilder
    private func permissionRow(_ permission: Permission, neededBy tools: [String]) -> some View {
        let granted = permission == .accessibility
            ? store.isAccessibilityTrusted
            : store.isInputMonitoringGranted
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(granted ? Color.green : Color.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(permission.displayName)
                Text(granted ? "Granted — required by \(tools.joined(separator: ", "))"
                             : "Not granted — required by \(tools.joined(separator: ", "))")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            Button(granted ? "Open System Settings…" : "Grant…") {
                permissions.openSettings(for: permission)
            }
        }
    }

    // MARK: - Layout helpers

    @ViewBuilder
    private func section<Content: View>(_ title: String,
                                        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .tracking(0.6)
            VStack(alignment: .leading, spacing: 10) { content() }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(nsColor: .textBackgroundColor).opacity(0.5))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.08)))
        }
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

extension Permission: Identifiable {
    var id: String { displayName }
}

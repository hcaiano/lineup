import AppCore
import SwiftUI

/// The Settings window's content: a fixed-order sidebar with a per-tool on/off switch, and the
/// selected pane on the right.
///
/// The tool rows carry the enable switch because that is the one control users look for first
/// after an update that added two tools they've never seen. Flipping it really starts or stops
/// the tool (`ToolRegistry.setEnabled`) — there is no "restart to apply".
struct SettingsRootView: View {
    @ObservedObject var store: SettingsStore

    var body: some View {
        NavigationSplitView {
            List(selection: $store.selection) {
                Label("General", systemImage: "gearshape")
                    .tag(SettingsSection.general)
                if !store.toolRows.isEmpty {
                    Section("Tools") {
                        ForEach(store.toolRows) { row in
                            ToolSidebarRow(row: row, isOn: store.binding(forTool: row.id))
                                .tag(SettingsSection.tool(row.id))
                        }
                    }
                }
                Label("About", systemImage: "info.circle")
                    .tag(SettingsSection.about)
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 190, ideal: 200, max: 240)
        } detail: {
            store.pane(for: store.selection)
        }
        .frame(minWidth: 760, minHeight: 520)
        .tint(Color(nsColor: Brand.blue))
    }
}

struct ToolSidebarRow: View {
    let row: ToolRow
    @Binding var isOn: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: row.iconSymbol)
                .frame(width: 18)
            Text(row.name)
            Spacer(minLength: 6)
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
                .accessibilityLabel("Enable \(row.name)")
        }
    }
}

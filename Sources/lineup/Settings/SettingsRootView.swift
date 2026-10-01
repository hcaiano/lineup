import AppCore
import SwiftUI

/// The Settings window's content: a fixed-order sidebar with a per-tool on/off switch, and the
/// selected pane on the right.
///
/// Order is fixed — General, then the tools in registry order (Zones, Cycler, Hyperkey), then
/// About — so the window never reshuffles under a user who has learned where things are.
///
/// The sidebar is a plain navigator: icon + name, nothing to hit by accident. The enable switch
/// lives at the top right of each tool's pane (`ToolPane`), where the user is already looking
/// when they ask "what is this and is it on?". Flipping it really starts or stops the tool
/// (`ToolRegistry.setEnabled`) — there is no "restart to apply".
struct SettingsRootView: View {
    @ObservedObject var store: SettingsStore

    var body: some View {
        NavigationSplitView {
            List(selection: $store.selection) {
                Label("General", systemImage: "gearshape")
                    .tag(SettingsSection.general)

                // Hidden entirely rather than shown as an empty header: an intermediate build
                // with no tools registered should not display a "Tools" heading over nothing.
                if !store.toolRows.isEmpty {
                    Section("Tools") {
                        ForEach(store.toolRows) { row in
                            ToolSidebarRow(row: row)
                                .tag(SettingsSection.tool(row.id))
                        }
                    }
                }

                // Its own (unlabelled) section purely for the gap: butted straight against the
                // tool rows, About reads as a fourth tool that is missing its switch.
                Section {
                    Label("About", systemImage: "info.circle")
                        .tag(SettingsSection.about)
                }
            }
            .listStyle(.sidebar)
            // The brand accent belongs to the SELECTION, and to nothing else. On the split view it
            // was inherited by every bordered button in every pane — "Open System Settings…",
            // "Check for Updates…", "Add Shortcut", the + and − in Cycler's rows — so the window
            // had a dozen equally blue buttons and no primary action anywhere. Secondary buttons
            // are neutral (system default) now; the panes tint only what is genuinely active.
            .tint(Color(nsColor: Brand.blue))
            .modifier(HiddenSidebarToggle()) // must sit on the SIDEBAR column, not the split view
            .navigationSplitViewColumnWidth(min: 190, ideal: 200, max: 240)
        } detail: {
            store.pane(for: store.selection)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 760, minHeight: 520)
    }
}

/// The sidebar is the window's only navigation; collapsing it would strand the user with no way
/// to switch panes. Drop the automatic toolbar button where the OS lets us (macOS 15+) so the
/// title bar stays as quiet as the rest of the window.
private struct HiddenSidebarToggle: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content.toolbar(removing: .sidebarToggle)
        } else {
            content
        }
    }
}

/// One tool in the sidebar: its app icon and its name.
///
/// Feature artwork uses the same enamel family as each tool's header. General and About keep
/// plain symbols because they describe the Settings window rather than individual tools.
///
/// A switched-off tool uses the shared grayscale treatment. Its label remains readable and
/// navigable, so the tool can still be configured before it is enabled.
struct ToolSidebarRow: View {
    let row: ToolRow

    var body: some View {
        // A Label, not a hand-rolled HStack: that is what keeps the tool icons on the same
        // baseline and the same x as General's and About's.
        Label {
            Text(row.name)
                .lineLimit(1)
                .truncationMode(.tail)
        } icon: {
            ToolIcon(id: row.id, size: 20, isEnabled: row.isEnabled)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .help(row.summary)
        // The muted icon is the only thing that says "off", and it says nothing to VoiceOver.
        .accessibilityValue(row.isEnabled ? "On" : "Off")
    }
}

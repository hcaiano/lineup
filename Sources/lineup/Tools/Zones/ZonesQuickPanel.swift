import SwiftUI

/// Zones in the shared panel: the layout editor and the drag-snap switch. Shortcuts stay in
/// Settings; this tab holds only what is changed day to day.
struct ZonesQuickPanel: View {
    let dragSnapOn: Bool
    /// The bind as key caps, e.g. `⇧`.
    let dragBind: String
    let canWrite: Bool
    let warnings: [ToolWarning]
    let editLayout: () -> Void
    let setDragSnap: (Bool) -> Void
    @Environment(\.panelActions) private var panel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            PanelHeader(title: "Zones") { EmptyView() }
            PanelWarnings(warnings: warnings)
            Button { panel.perform(editLayout) } label: {
                Label("Edit Layout…", systemImage: "square.grid.2x2")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .disabled(!canWrite)
            .help("Draw the zones windows snap into")
            Toggle(isOn: Binding(get: { dragSnapOn }, set: setDragSnap)) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Drag to snap")
                    HStack(spacing: 4) {
                        Text("Hold")
                        KeyCapRow(display: dragBind)
                        Text("while dragging a window")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            .disabled(!canWrite)
            .accessibilityHint("Hold \(ShortcutKit.keyCaps(dragBind).joined(separator: " ")) while dragging a window")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

import SwiftUI

/// Keyboard Remap in the shared panel: how many keys are remapped, and the way to edit them.
/// Choosing keys needs the keyboard picker and key editor, which live in Settings.
struct KeyboardRemapQuickPanel: View {
    @ObservedObject var tool: KeyboardRemapTool
    @Environment(\.panelActions) private var panel

    private var count: Int { tool.settings.rules.reduce(0) { $0 + $1.mappings.count } }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            PanelHeader(title: tool.displayName) { EmptyView() }
            PanelWarnings(warnings: tool.warnings)
            Text(count == 0 ? "No keys remapped yet."
                 : count == 1 ? "1 key mapping saved." : "\(count) key mappings saved.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Button { panel.openSettings(.keyboardRemap) } label: {
                Text(count == 0 ? "Add Mappings…" : "Edit Mappings…")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

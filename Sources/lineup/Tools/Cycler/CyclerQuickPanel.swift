import AppKit
import SwiftUI

/// Cycler in the shared panel: the user's app shortcuts at a glance. A row opens its app the way
/// its shortcut does; editing stays in Settings.
struct CyclerQuickPanel: View {
    struct Entry: Identifiable {
        let id: Int
        let title: String
        let icons: [NSImage]
        let shortcut: String
        let installed: Bool
        let open: () -> Void
    }

    let entries: [Entry]
    let warnings: [ToolWarning]
    @Environment(\.panelActions) private var panel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            PanelHeader(title: "Cycler") {
                if !entries.isEmpty {
                    Button("Edit") { panel.openSettings(.cycler) }
                        .buttonStyle(.borderless)
                        .help("Edit shortcuts in Settings")
                }
            }
            PanelWarnings(warnings: warnings)
            if entries.isEmpty {
                PanelNotice(text: "No app shortcuts yet.", actionTitle: "Add Shortcut…",
                            action: { panel.openSettings(.cycler) })
            } else {
                VStack(spacing: 0) {
                    ForEach(entries) { entry in
                        Button { panel.perform(entry.open) } label: {
                            HStack(spacing: 8) {
                                icons(entry.icons)
                                Text(entry.title)
                                    .font(.system(size: 13))
                                    .lineLimit(1)
                                    .foregroundStyle(entry.installed ? .primary : .secondary)
                                Spacer(minLength: 8)
                                KeyCapRow(display: entry.shortcut)
                            }
                        }
                        .buttonStyle(PanelRowButtonStyle())
                        .disabled(!entry.installed)
                        .accessibilityLabel(entry.title)
                        .accessibilityValue(entry.shortcut)
                        .accessibilityHint("Opens the app, like its shortcut")
                    }
                }
                .padding(.horizontal, -8)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Group icons overlap slightly, like a stack, so one row stays one row.
    private func icons(_ images: [NSImage]) -> some View {
        HStack(spacing: -6) {
            ForEach(Array(images.prefix(3).enumerated()), id: \.offset) { _, image in
                Image(nsImage: image).resizable().interpolation(.high).frame(width: 18, height: 18)
            }
        }
        .frame(minWidth: 18, alignment: .leading)
        .accessibilityHidden(true)
    }
}

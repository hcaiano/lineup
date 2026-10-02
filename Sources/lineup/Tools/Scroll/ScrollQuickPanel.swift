import SwiftUI

/// Scroll in the shared panel: one switch per device. The directions stay in Settings.
struct ScrollQuickPanel: View {
    @ObservedObject var tool: ScrollTool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            PanelHeader(title: "Scroll") { EmptyView() }
            PanelWarnings(warnings: tool.warnings)
            device("Reverse mouse", symbol: "computermouse",
                   isOn: tool.settings.reverseMouse, set: tool.setReverseMouse)
            device("Reverse trackpad", symbol: "rectangle.and.hand.point.up.left",
                   isOn: tool.settings.reverseTrackpad, set: tool.setReverseTrackpad)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func device(_ title: String, symbol: String, isOn: Bool,
                        set: @escaping (Bool) -> Void) -> some View {
        Toggle(isOn: Binding(get: { isOn }, set: set)) {
            HStack(spacing: 7) {
                // The two device glyphs differ in width; a fixed column keeps the titles aligned.
                Image(systemName: symbol)
                    .foregroundStyle(.secondary)
                    .frame(width: 20)
                Text(title)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .toggleStyle(.switch)
        .controlSize(.small)
        .disabled(!tool.canEdit)
    }
}

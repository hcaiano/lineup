import SwiftUI

/// Hyperkey in the shared panel: which key is Hyper, and what it sends.
struct HyperkeyQuickPanel: View {
    let trigger: String
    let modifiers: String
    let isActive: Bool
    let warnings: [ToolWarning]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            PanelHeader(title: "Hyperkey") { EmptyView() }
            PanelWarnings(warnings: warnings)
            HStack(spacing: 8) {
                KeyCapRow(display: trigger)
                Image(systemName: "arrow.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.tertiary)
                KeyCapRow(display: modifiers)
            }
            .opacity(isActive ? 1 : 0.5)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(spoken)
            Text("Hold \(trigger) and press another key.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var spoken: String {
        let words = ["⌃": "Control", "⌥": "Option", "⇧": "Shift", "⌘": "Command"]
        return "\(trigger) sends " + modifiers.compactMap { words[String($0)] }.joined(separator: ", ")
    }
}

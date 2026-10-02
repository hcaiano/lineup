import SwiftUI

/// Text Capture in the shared panel: the capture itself, and its shortcut when there is one.
struct TextCaptureQuickPanel: View {
    let isCapturing: Bool
    let isRunning: Bool
    /// Display string such as `⌃⇧2`, or empty when no shortcut is set.
    let shortcut: String
    let warnings: [ToolWarning]
    let capture: () -> Void
    let cancel: () -> Void
    @Environment(\.panelActions) private var panel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            PanelHeader(title: "Text Capture") { EmptyView() }
            PanelWarnings(warnings: warnings)
            Button {
                if isCapturing { cancel() } else { panel.perform(capture) }
            } label: {
                Label(isCapturing ? "Cancel Capture" : "Capture Text…",
                      systemImage: isCapturing ? "xmark" : "text.viewfinder")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .disabled(!isRunning)
            HStack(spacing: 6) {
                if shortcut.isEmpty {
                    Text("Drag around text, then paste it anywhere.")
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 6)
                    Button("Add Shortcut…") { panel.openSettings(.textCapture) }
                        .buttonStyle(.link)
                } else {
                    Text("Shortcut")
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 6)
                    KeyCapRow(display: shortcut)
                }
            }
            .font(.caption)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

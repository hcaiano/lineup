import SwiftUI

/// Lineup 1.x's shortcut recorder control: a fixed-width bordered button that shows the current
/// combo, "Click to set" when empty, and "Press keys..." while capturing.
///
/// Purely presentational — it owns no recording state. The pane drives `isRecording` from its
/// `ShortcutRecorder` and does the capture in `action`. Kept visually distinct from
/// `ShortcutField` on purpose: Zones uses this one, Cycler uses that one (plan § Phase 7b).
struct RecorderButton: View {
    var text: String
    var emptyText: String = "Click to set"
    var isRecording: Bool
    var enabled: Bool = true
    var accessibilityLabel: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(labelText)
                .font(.system(size: 13, weight: text.isEmpty ? .regular : .medium))
                .foregroundStyle(isRecording || !text.isEmpty ? .primary : .secondary)
                .lineLimit(1)
                .frame(width: 164)
        }
        .buttonStyle(.bordered)
        .controlSize(.regular)
        .disabled(!enabled)
        .help(isRecording ? "Press keys" : accessibilityLabel)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(isRecording ? "Recording" : (text.isEmpty ? "Not set" : text))
    }

    private var labelText: String {
        if isRecording { return "Press keys..." }
        return text.isEmpty ? emptyText : text
    }
}

/// The small circular ⊗ that sits beside a recorder to clear or reset the value it holds.
struct CircleClearButton: View {
    var help: String
    var accessibilityLabel: String
    var disabled: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark.circle.fill")
                .imageScale(.medium)
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .help(help)
        .disabled(disabled)
        .accessibilityLabel(accessibilityLabel)
    }
}

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
            label
                .frame(width: 164)
        }
        .buttonStyle(.bordered)
        .controlSize(.regular)
        .disabled(!enabled)
        .help(isRecording ? "Press keys" : accessibilityLabel)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(isRecording ? "Recording" : (text.isEmpty ? "Not set" : text))
    }

    /// An assigned shortcut renders as key caps; the two placeholder states stay plain text —
    /// "Click to set" is prose, not a key.
    @ViewBuilder
    private var label: some View {
        if isRecording {
            placeholder("Press keys...")
        } else if text.isEmpty {
            placeholder(emptyText)
        } else {
            KeyCapRow(display: text)
        }
    }

    private func placeholder(_ string: String) -> some View {
        Text(string)
            .font(.system(size: 13))
            .foregroundStyle(isRecording ? .primary : .secondary)
            .lineLimit(1)
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

import SwiftUI

/// Lineup 1.x's shortcut recorder control: a bordered button that shows the current combo,
/// "Click to set" when empty, and "Press keys…" while capturing.
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
    /// What VoiceOver should read instead of the glyphs. `⌃⌥` reads as nothing at all, so the drag
    /// bind hands over `ShortcutKit.modifierWords` here; a combo row's caps read fine as they are.
    var accessibilityValue: String?
    /// `ShortcutRecorder.rejectionCount`, so a refused keystroke is seen as well as heard.
    var rejectionCount: Int = 0
    var action: () -> Void

    /// Wide enough for a four-modifier combo, but a MINIMUM rather than a fixed width: a hard
    /// 164pt clipped the longer placeholders, and a bordered button that clips its own label
    /// reads as broken.
    private static let minWidth: CGFloat = 164

    var body: some View {
        Button(action: action) {
            label
                .frame(minWidth: Self.minWidth)
        }
        .buttonStyle(.bordered)
        .controlSize(.regular)
        // While capturing, the control is the only live thing on the pane; the accent border is
        // what says so at a glance, matching Cycler's ShortcutField.
        .tint(isRecording ? Color.accentColor : nil)
        .overlay {
            if isRecording {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(Color.accentColor, lineWidth: 1.5)
            }
        }
        .recordingRejectionShake(rejectionCount)
        .disabled(!enabled)
        .help(isRecording ? "Press keys" : accessibilityLabel)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(isRecording
                            ? "Recording"
                            : (text.isEmpty ? "Not set" : (accessibilityValue ?? text)))
    }

    /// An assigned shortcut renders as key caps; the two placeholder states stay plain text —
    /// "Click to set" is prose, not a key.
    @ViewBuilder
    private var label: some View {
        if isRecording {
            placeholder("Press keys…")
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

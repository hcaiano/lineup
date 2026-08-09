import AppKit
import SwiftUI

/// Cycler's shortcut recorder control: a large bordered button that tints to the pane's accent
/// while capturing. Deliberately NOT unified with `RecorderButton` — both styles coexist through
/// the merge (plan § Phase 7b), so Cycler's rows keep the look they shipped with.
///
/// Purely presentational. Pass `accent` the pane's colour, e.g.
/// `Color(nsColor: Brand.cyclerAccent)`; the default follows the window tint.
struct ShortcutField: View {
    var text: String
    var isRecording: Bool
    var emptyText: String = "Record Shortcut"
    var accent: Color = .accentColor
    var enabled: Bool = true
    var accessibilityLabel: String?
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 13, weight: text.isEmpty ? .regular : .semibold))
                .foregroundStyle(color)
                .frame(width: 150)
                .padding(.vertical, 5)
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
        .tint(isRecording ? accent : nil)
        .disabled(!enabled)
        .accessibilityLabel(accessibilityLabel ?? "Shortcut")
        .accessibilityValue(isRecording ? "Recording" : (text.isEmpty ? "Not set" : text))
    }

    private var label: String {
        if isRecording { return "Press keys…" }
        return text.isEmpty ? emptyText : text
    }

    private var color: Color {
        if isRecording { return accent }
        return text.isEmpty ? .secondary : .primary
    }
}

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
            label
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

    /// Same key caps as the Zones rows (`KeyCapRow`), so a shortcut reads identically in every
    /// pane; only the surrounding control differs between the two tools.
    @ViewBuilder
    private var label: some View {
        if isRecording {
            Text("Press keys…").font(.system(size: 13)).foregroundStyle(accent)
        } else if text.isEmpty {
            Text(emptyText).font(.system(size: 13)).foregroundStyle(.secondary)
        } else {
            KeyCapRow(display: text, size: .large)
        }
    }
}

import SwiftUI

/// A recorded shortcut drawn as key caps: one small rounded rect per modifier and per key, the way
/// Raycast (and macOS' own menu keyboard-shortcut chips) show them.
///
/// Shared on purpose, and at ONE size. Zones' rows use `RecorderButton` and Cycler's use
/// `ShortcutField` — two controls that stay visually distinct through the merge — but a shortcut
/// must read the SAME in both, or the window looks like two apps stitched together. The second,
/// "roomier" cap size this had did exactly that, so it is gone.
///
/// Purely presentational: it holds no state and never touches the recorder.
struct KeyCapRow: View {
    /// A rendered display string, e.g. `⌃⌥⇧⌘←`. Split by `ShortcutKit.keyCaps`.
    var display: String

    /// An explicit colour cannot be dimmed by `.disabled(_:)` the way an inherited one is, and a
    /// pane whose writes are blocked disables every recorder in it: without this the shortcut rows
    /// went on looking live under a banner saying nothing could be saved.
    @Environment(\.isEnabled) private var isEnabled

    private let font = Font.system(size: 12, weight: .medium)
    private let minWidth: CGFloat = 20
    private let height: CGFloat = 20
    private let horizontalPadding: CGFloat = 5

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Array(ShortcutKit.keyCaps(display).enumerated()), id: \.offset) { _, cap in
                Text(cap)
                    .font(font)
                    // `Color.primary`, not `.primary`: inside a bordered Button's label the
                    // hierarchical style can resolve to the button's tint, and a recording
                    // control tints. Key caps are neutral in every state.
                    .foregroundStyle(isEnabled ? Color.primary : Color.secondary)
                    .lineLimit(1)
                    .padding(.horizontal, horizontalPadding)
                    .frame(minWidth: minWidth, minHeight: height)
                    .background(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(Color.primary.opacity(isEnabled ? 0.07 : 0.04)))
                    .overlay(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
            }
        }
        // The caps are decorative; the control that owns them carries the accessibility value.
        .accessibilityHidden(true)
    }
}

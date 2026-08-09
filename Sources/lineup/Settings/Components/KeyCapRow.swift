import SwiftUI

/// A recorded shortcut drawn as key caps: one small rounded rect per modifier and per key, the way
/// Raycast (and macOS' own menu keyboard-shortcut chips) show them.
///
/// Shared on purpose. Zones' rows use `RecorderButton` and Cycler's use `ShortcutField` — two
/// controls that stay visually distinct through the merge — but a shortcut must read the SAME in
/// both, or the window looks like two apps stitched together. Both route their display string
/// through here.
///
/// Purely presentational: it holds no state and never touches the recorder.
struct KeyCapRow: View {
    /// A rendered display string, e.g. `⌃⌥⇧⌘←`. Split by `ShortcutKit.keyCaps`.
    var display: String
    /// Slightly larger caps for Cycler's roomier rows.
    var size: Size = .regular

    enum Size {
        case regular
        case large

        var font: Font {
            switch self {
            case .regular: return .system(size: 12, weight: .medium)
            case .large: return .system(size: 13, weight: .medium)
            }
        }

        var minWidth: CGFloat {
            switch self {
            case .regular: return 20
            case .large: return 22
            }
        }

        var height: CGFloat {
            switch self {
            case .regular: return 20
            case .large: return 22
            }
        }

        var horizontalPadding: CGFloat {
            switch self {
            case .regular: return 5
            case .large: return 6
            }
        }
    }

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Array(ShortcutKit.keyCaps(display).enumerated()), id: \.offset) { _, cap in
                Text(cap)
                    .font(size.font)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .padding(.horizontal, size.horizontalPadding)
                    .frame(minWidth: size.minWidth, minHeight: size.height)
                    .background(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(Color.primary.opacity(0.07)))
                    .overlay(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
            }
        }
        // The caps are decorative; the control that owns them carries the accessibility value.
        .accessibilityHidden(true)
    }
}

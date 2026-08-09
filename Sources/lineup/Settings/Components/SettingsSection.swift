import SwiftUI

/// Shared layout constants so every pane's content column lines up, whichever tool drew it.
/// Carried over from Lineup 1.x's Settings window.
enum SettingsMetrics {
    /// Width of a pane's content column inside the detail area.
    static let contentWidth: CGFloat = 540
    /// Height of a plain label + control row (`SettingsRow`), which usually carries a detail line.
    static let rowHeight: CGFloat = 44
    /// Height of a shortcut row. Deliberately denser than `rowHeight`: a shortcut row is one label
    /// and one recorder with no detail line, and Zones shows thirteen of them at once — at the
    /// default height the list needs scrolling for content that should fit in one look.
    static let shortcutRowHeight: CGFloat = 28
}

/// A titled group of rows. Lineup 1.x's section header + hairline-separated row stack, extracted
/// verbatim and made tool-agnostic — it carries no state of its own.
///
///     SettingsSectionView("Behavior") {
///         SettingsRow(title: "Drag to snap", detail: "…") { Toggle(…) }
///     }
struct SettingsSectionView<Content: View>: View {
    private let title: String
    /// A short line under the header explaining how the section's controls are used. It belongs
    /// to the header, not to the pane: a bare instruction floating between two sections reads as
    /// if it describes whichever one the eye lands on first.
    private let caption: String?
    private let content: Content

    init(_ title: String, caption: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.caption = caption
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.headline)
                if let caption {
                    Text(caption)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            VStack(spacing: 0) {
                content
            }
            .padding(.vertical, 2)
        }
    }
}

/// One labelled row inside a `SettingsSectionView`: title (+ optional detail line) on the left,
/// whatever control the pane supplies on the right, and a trailing divider.
struct SettingsRow<Content: View>: View {
    var title: String
    var detail: String?
    var content: Content

    init(title: String, detail: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.detail = detail
        self.content = content()
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 18) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                    if let detail {
                        Text(detail)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 24)
                content
            }
            .frame(minHeight: SettingsMetrics.rowHeight)
            .padding(.vertical, 6)

            Divider()
                .padding(.leading, 0)
        }
    }
}

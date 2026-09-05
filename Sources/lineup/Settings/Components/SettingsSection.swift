import SwiftUI

/// Shared layout constants so every pane's content column lines up, whichever tool drew it.
/// Carried over from Lineup 1.x's Settings window.
///
/// These are the ONLY numbers a pane should use for its outer rhythm. Multiple panes written
/// independently would otherwise each pick their own column width and gap between sections, making
/// the window read as several windows, which is exactly what the 2.0 design review measured.
enum SettingsMetrics {
    /// Width of a pane's content column inside the detail area. A `width`, never a `maxWidth`:
    /// a pane that only caps its width centres its content on a different gutter than its
    /// neighbours as the window grows.
    static let contentWidth: CGFloat = 540
    /// Gap between two `SettingsSectionView`s in a pane.
    static let sectionSpacing: CGFloat = 26
    /// Space above the first section and below the last one.
    static let panePaddingVertical: CGFloat = 24
    /// Height of a plain label + control row (`SettingsRow`), which usually carries a detail line.
    static let rowHeight: CGFloat = 44
    /// Height of a shortcut row. Deliberately denser than `rowHeight`: a shortcut row is one label
    /// and one recorder with no detail line, and Zones shows sixteen of them at once (7 quick
    /// actions + 9 zones) — at the default height the list needs scrolling for content that
    /// should fit in one look.
    static let shortcutRowHeight: CGFloat = 28
    /// A `Divider`'s thickness, used to trim the one after a section's last row.
    static let dividerThickness: CGFloat = 1
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
                    // A real step above a row title (13pt body): at `.headline` the header and the
                    // rows under it were the same size and weight, and the sections stopped
                    // reading as groups at a glance.
                    .font(.system(size: 15, weight: .semibold))
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
            // Every `SettingsRow` draws a trailing hairline, which left a rule hanging under the
            // last row of every section with nothing below it to separate. Shrinking the box by
            // exactly one divider and clipping is what drops that last one without making each
            // row know whether it is the last: the rows are built by `ForEach` in four panes.
            //
            // Order matters. The trim has to happen while the divider is still the bottom-most
            // pixel of the box; with the 2pt breathing room applied first it ate the padding and
            // left the hairline exactly where it was.
            .padding(.bottom, -SettingsMetrics.dividerThickness)
            .clipped()
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

/// A line of explanation that is not a row: the same treatment a section caption gets, used for
/// standing facts ("Caps Lock is remapped while Hyperkey runs") that used to be drawn as a
/// `SettingsRow` with an `EmptyView()` control — a row shape promising a control that never came.
struct SettingsCaption: View {
    var text: String
    var systemImage: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            if let systemImage {
                Image(systemName: systemImage)
                    .foregroundStyle(.secondary)
            }
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

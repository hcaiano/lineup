import SwiftUI

/// The ONE banner a pane shows when it cannot save: why, and the way out.
///
/// It replaces three hand-rolled variants — Zones drew an orange `lock.fill` label at the top of
/// its scroll content, Hyperkey drew the same label with different spacing, Cycler drew a grey
/// `info.circle.fill` pinned above its list — which between them gave the SAME condition three
/// severities and three positions.
///
/// Two rules the variants broke, both measured in the 2.0 design review:
///
///   * **The text is `.primary`, never orange.** `Color.orange` on the light window background
///     measures 2.34:1, well under the 4.5:1 body-text floor. The SF Symbol keeps the orange —
///     it is a glyph, not a sentence, so it only has to be noticed.
///   * **It is pinned, not scrolled.** A pane whose controls are all disabled must say why in
///     the same look that shows them disabled; inside the scroll view the explanation slid away
///     and left a dead pane behind it.
///
/// `actionTitle`/`action` carry the tool's own recovery (each tool exposes a `resetSection`), so
/// the banner is never a dead end.
struct BlockedBanner: View {
    var message: String
    /// Orange by convention; the glyph is the only coloured thing in the banner.
    var systemImage: String = "lock.fill"
    var actionTitle: String?
    var action: (() -> Void)?
    /// False when even the recovery cannot be written (the store itself refuses writes).
    var actionEnabled: Bool = true

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 9) {
            Image(systemName: systemImage)
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 8) {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let actionTitle, let action {
                    Button(actionTitle, action: action)
                        .controlSize(.small)
                        .disabled(!actionEnabled)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(Color.orange.opacity(0.10)))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .strokeBorder(Color.orange.opacity(0.25)))
        // One element, one sentence: VoiceOver reads the message, not "warning image, text, button".
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Warning. \(message)")
    }
}

/// The banner in the place every pane puts it: pinned above the scroll view, on the shared
/// content column so it lines up with the sections below rather than spanning the whole pane.
struct PinnedBannerStrip<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(spacing: 8) {
            content()
        }
        .frame(width: SettingsMetrics.contentWidth, alignment: .leading)
        .frame(maxWidth: .infinity)
        .padding(.bottom, 12)
    }
}

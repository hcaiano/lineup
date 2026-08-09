import AppCore
import SwiftUI

/// About: brand mark, version, build date, the site, and the same Sparkle check the menu offers.
///
/// Lineup 2.0 is a private build: no source-repository link and no open-source licence line
/// (1.x's About offered both). The product site stays — it is where the appcast and the download
/// live, so it is the one link that still means something to a user.
///
/// This and `AboutWindowController` must agree: they are two renderings of the same facts, and
/// a user who opens both should not be told two different stories about the licence.
struct AboutPane: View {
    /// Nil outside the assembled bundle (a bare `swift run` has no Info.plist): better to show
    /// nothing than a version line with nothing in it.
    private var version: String? {
        guard let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
              let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String else { return nil }
        return "Version \(short) (\(build))"
    }

    /// The same "Built <date>" line the About window shows, so neither one carries a fact the
    /// other is missing. Nil when the executable can't be dated.
    private var buildDate: String? { AboutFacts.buildDateLine() }

    var body: some View {
        // One centred block, top and bottom spacers equal. Pinning the copyright to the bottom of
        // an 800pt-tall detail area left ~400pt of nothing between it and the rest — a pane that
        // looked like it had failed to load its content.
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            VStack(spacing: 14) {
                // The REAL app icon, exactly as the About window shows it. The tinted menu-bar
                // glyph is a status-bar mark, not the product's face, and the two Abouts showing
                // different artwork was the last place they still disagreed.
                Image(nsImage: AppIconImage.shared)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(width: 84, height: 84)
                    .accessibilityHidden(true)
                VStack(spacing: 4) {
                    Text(Product.name)
                        .font(.system(size: 22, weight: .semibold))
                    Text("Window snapping, app cycling, and a hyper key in one menu-bar app.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                // Version and build date are one fact in two lines, so they sit tighter than the
                // 14pt the rest of the stack uses.
                VStack(spacing: 2) {
                    if let version {
                        Text(version)
                    }
                    if let buildDate {
                        Text(buildDate)
                    }
                }
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                HStack(spacing: 10) {
                    Button("Check for Updates…") { AppUpdater.shared.checkForUpdates(nil) }
                    Link("lineup.caiano.com", destination: URL(string: "https://lineup.caiano.com")!)
                }
                .padding(.top, 4)
                Text(AboutFacts.copyright)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .padding(.top, 8)
            }
            .frame(width: SettingsMetrics.contentWidth)
            Spacer(minLength: 0)
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("About")
    }
}

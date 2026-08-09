import AppCore
import SwiftUI

/// About: brand mark, version, the site, and the same Sparkle check the menu offers.
///
/// Lineup 2.0 is a private build: no source-repository link and no open-source licence line
/// (1.x's About offered both). The product site stays — it is where the appcast and the download
/// live, so it is the one link that still means something to a user.
struct AboutPane: View {
    /// Nil outside the assembled bundle (a bare `swift run` has no Info.plist): better to show
    /// nothing than "Version — (—)".
    private var version: String? {
        guard let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
              let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String else { return nil }
        return "Version \(short) (\(build))"
    }

    var body: some View {
        VStack(spacing: 14) {
            Spacer(minLength: 0)
            Image(nsImage: Brand.menuBarLogo())
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(width: 54, height: 48)
                .foregroundStyle(Color(nsColor: Brand.blue))
                .accessibilityHidden(true)
            Text(Product.name)
                .font(.system(size: 22, weight: .semibold))
            Text("Window snapping, app cycling, and a hyper key — in one menu-bar app.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if let version {
                Text(version)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 10) {
                Button("Check for Updates…") { AppUpdater.shared.checkForUpdates(nil) }
                Link("lineup.caiano.com", destination: URL(string: "https://lineup.caiano.com")!)
            }
            .padding(.top, 4)
            Spacer(minLength: 0)
            Text("© 2026 Henrique Caiano. All rights reserved.")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("About")
    }
}

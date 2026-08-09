import AppCore
import SwiftUI

/// About: brand mark, version, the site, and the same Sparkle check the menu offers.
struct AboutPane: View {
    private var version: String {
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"
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
            Text(Product.name)
                .font(.system(size: 22, weight: .semibold))
            Text("Window snapping, app cycling, and a hyper key — in one menu-bar app.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Text(version)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            HStack(spacing: 10) {
                Button("Check for Updates…") { AppUpdater.shared.checkForUpdates(nil) }
                Link("lineup.caiano.com", destination: URL(string: "https://lineup.caiano.com")!)
            }
            .padding(.top, 4)
            Spacer(minLength: 0)
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("About")
    }
}

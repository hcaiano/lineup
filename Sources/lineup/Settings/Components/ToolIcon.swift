import AppKit
import AppCore
import SwiftUI

/// A rounded-square fallback for a tool whose artwork is unavailable.
///
/// Proportions follow the macOS app-icon idiom rather than SwiftUI defaults — corner radius at
/// 22% of the side, glyph at ~52% — so a drawn tile sits next to a real `.icns` in the sidebar
/// without looking like a different kind of thing.
struct AppStyleIcon: View {
    let symbol: String
    let tint: NSColor
    var size: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
            .fill(LinearGradient(
                colors: [Color(nsColor: tint.blended(withFraction: 0.30, of: .white) ?? tint),
                         Color(nsColor: tint)],
                startPoint: .top, endPoint: .bottom))
            .overlay(
                Image(systemName: symbol)
                    .font(.system(size: size * 0.52, weight: .semibold))
                    .foregroundStyle(.white)
            )
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// Shared feature icons, with vector tiles in Settings and enamel artwork in onboarding.
/// Legacy artwork and a drawn tile cover missing resource catalogs.
struct ToolIcon: View {
    enum Style {
        case artwork
        case settings
    }

    let id: ToolID
    var size: CGFloat
    var isEnabled: Bool = true
    var style: Style = .artwork

    var body: some View {
        artwork
            .saturation(isEnabled ? 1 : 0)
    }

    @ViewBuilder
    private var artwork: some View {
        if style == .settings {
            SettingsIconTile(id: id, size: size)
        } else if let image = ToolIconLibrary.artwork(for: id) {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: size, height: size)
                .accessibilityHidden(true)
        } else {
            AppStyleIcon(symbol: ToolIconLibrary.fallbackSymbol(for: id),
                         tint: Brand.accent(for: id),
                         size: size)
        }
    }
}

/// Settings uses opaque vector tiles: no transparent margins or relief to shrink the motif.
/// The same proportions work in navigation and headers, including on non-Retina displays.
private struct SettingsIconTile: View {
    let id: ToolID
    let size: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.15, style: .continuous)
            .fill(LinearGradient(
                colors: [Color(nsColor: tint.blended(withFraction: 0.12, of: .white) ?? tint),
                         Color(nsColor: tint)],
                startPoint: .top, endPoint: .bottom))
            .overlay {
                motif
                    .foregroundStyle(.white)
                    .frame(width: size * 0.68, height: size * 0.68)
            }
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private var motif: some View {
        switch id {
        case .zones:
            Image(nsImage: Brand.menuBarLogo())
                .resizable()
                .scaledToFit()
        case .menuBar:
            VStack(spacing: size * 0.08) {
                HStack(spacing: size * 0.055) {
                    ForEach(0..<3) { _ in
                        RoundedRectangle(cornerRadius: size * 0.015)
                            .fill(Color(nsColor: tint))
                    }
                }
                .padding(size * 0.055)
                .frame(height: size * 0.25)
                .background(.white, in: RoundedRectangle(cornerRadius: size * 0.035))
                Image(systemName: "chevron.down")
                    .font(.system(size: size * 0.23, weight: .bold))
            }
        default:
            Image(systemName: id == .hyperkey ? "command" : ToolIconLibrary.fallbackSymbol(for: id))
                .resizable()
                .scaledToFit()
                .fontWeight(.semibold)
        }
    }

    private var tint: NSColor {
        switch id {
        case .worldClock: return NSColor(srgbRed: 13 / 255, green: 143 / 255, blue: 155 / 255, alpha: 1)
        case .awake: return NSColor(srgbRed: 193 / 255, green: 127 / 255, blue: 8 / 255, alpha: 1)
        case .textCapture: return NSColor(srgbRed: 22 / 255, green: 133 / 255, blue: 107 / 255, alpha: 1)
        case .menuBar: return NSColor(srgbRed: 77 / 255, green: 97 / 255, blue: 122 / 255, alpha: 1)
        default: return Brand.accent(for: id)
        }
    }
}

/// Loads (once) the artwork behind `ToolIcon`.
enum ToolIconLibrary {
    static func artwork(for id: ToolID) -> NSImage? {
        if let image = featureArtwork[id] { return image }
        switch id {
        case .zones: return appIcon
        case .cycler: return cyclerIcon
        default: return nil
        }
    }

    /// The SF Symbol used when there is no artwork. Also what a tool's sidebar row would show in
    /// a build where the resource bundle failed to ship.
    static func fallbackSymbol(for id: ToolID) -> String {
        switch id {
        case .zones: return "square.grid.2x2.fill"
        case .cycler: return "arrow.triangle.2.circlepath"
        case .hyperkey: return "capslock.fill"
        case .worldClock: return "clock"
        case .awake: return "sun.max.fill"
        case .textCapture: return "text.viewfinder"
        case .menuBar: return "menubar.rectangle"
        default: return "wrench.and.screwdriver.fill"
        }
    }

    /// The running app's own icon. Nil before `NSApp` exists (never, in this window's lifetime).
    private static let appIcon: NSImage? = {
        // NSApp.applicationIconImage is the bundle's icon in a real .app and the generic
        // executable icon under `swift run`; either way it is the honest "this is Lineup" mark.
        NSApp?.applicationIconImage ?? NSImage(named: NSImage.applicationIconName)
    }()

    private static let cyclerIcon: NSImage? = bundled("cycler-icon")

    private static let featureArtwork: [ToolID: NSImage] = {
        Dictionary(uniqueKeysWithValues: ToolID.all.compactMap { id in
            featureIcon(for: id).map { (id, $0) }
        })
    }()

    private static func featureIcon(for id: ToolID) -> NSImage? {
        let name = "feature-\(id.rawValue)"
        let image = NSImage(size: NSSize(width: 72, height: 72))
        for scale in 1...3 {
            let suffix = scale == 1 ? "" : "@\(scale)x"
            for root in resourceURLs {
                let url = root.appendingPathComponent("ToolIcons/FeatureIcons.xcassets/\(name).imageset/\(name)\(suffix).png")
                if let data = try? Data(contentsOf: url), let rep = NSBitmapImageRep(data: data) {
                    rep.size = image.size
                    image.addRepresentation(rep)
                    break
                }
            }
        }
        return image.representations.isEmpty ? nil : image
    }

    private static var resourceRoots: [URL] {
        var roots: [URL] = []
        if let resourceURL = Bundle.main.resourceURL { roots.append(resourceURL) }
        roots.append(Bundle.main.bundleURL)
        return roots
    }

    private static var resourceURLs: [URL] {
        resourceRoots.flatMap { root in
            let bundle = root.appendingPathComponent("lineup_lineup.bundle", isDirectory: true)
            // SwiftPM's native Xcode builder makes a macOS bundle with Contents/Resources;
            // older builds place the copied resources directly in the bundle directory.
            return [Bundle(url: bundle)?.resourceURL, bundle].compactMap { $0 }
        }
    }

    private static func bundled(_ name: String) -> NSImage? {
        // Do not use SwiftPM's generated `Bundle.module` accessor here. It traps when the
        // resource bundle is missing, which turns an optional icon into a launch crash. The
        // assembled app stores the bundle in Contents/Resources; a bare `swift run` keeps it
        // beside the executable. Search both locations and let the caller draw its fallback.
        for root in resourceURLs {
            // `.copy("Resources/ToolIcons")` keeps ToolIcons; `.process` would flatten it.
            for relativePath in [
                "ToolIcons/\(name).png",
                "Resources/ToolIcons/\(name).png",
                "\(name).png",
            ] {
                let url = root.appendingPathComponent(relativePath)
                if let image = NSImage(contentsOf: url) { return image }
            }
        }
        return nil
    }
}

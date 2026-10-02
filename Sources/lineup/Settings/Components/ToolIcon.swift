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

/// Shared feature artwork for navigation and headers, with legacy artwork and a drawn tile
/// as fallbacks when the copied resource catalog is unavailable.
struct ToolIcon: View {
    let id: ToolID
    var size: CGFloat
    var isEnabled: Bool = true

    var body: some View {
        artwork
            .saturation(isEnabled ? 1 : 0)
    }

    @ViewBuilder
    private var artwork: some View {
        if let image = ToolIconLibrary.artwork(for: id) {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: size, height: size)
                .accessibilityHidden(true)
        } else {
            AppStyleIcon(symbol: ToolIconLibrary.fallbackSymbol(for: id),
                         tint: fallbackTint,
                         size: size)
        }
    }

    private var fallbackTint: NSColor {
        let tint = Brand.accent(for: id)
        return isEnabled ? tint : (tint.usingColorSpace(.genericGray) ?? .gray)
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
        case .keyboardRemap: return "keyboard"
        case .worldClock: return "clock"
        case .awake: return "sun.max.fill"
        case .textCapture: return "text.viewfinder"
        case .menuBar: return "menubar.rectangle"
        case .scroll: return "arrow.up.arrow.down"
        case .displayControl: return "display"
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
            for root in resourceRoots {
                let url = root.appendingPathComponent("lineup_lineup.bundle/ToolIcons/FeatureIcons.xcassets/\(name).imageset/\(name)\(suffix).png")
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

    private static func bundled(_ name: String) -> NSImage? {
        // Do not use SwiftPM's generated `Bundle.module` accessor here. It traps when the
        // resource bundle is missing, which turns an optional icon into a launch crash. The
        // assembled app stores the bundle in Contents/Resources; a bare `swift run` keeps it
        // beside the executable. Search both locations and let the caller draw its fallback.
        for root in resourceRoots {
            let bundle = root.appendingPathComponent("lineup_lineup.bundle", isDirectory: true)
            // `.copy("Resources/ToolIcons")` keeps ToolIcons; `.process` would flatten it.
            for relativePath in [
                "ToolIcons/\(name).png",
                "Resources/ToolIcons/\(name).png",
                "\(name).png",
            ] {
                let url = bundle.appendingPathComponent(relativePath)
                if let image = NSImage(contentsOf: url) { return image }
            }
        }
        return nil
    }
}

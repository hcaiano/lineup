import AppKit
import AppCore
import SwiftUI

/// A rounded-square "app icon" tile drawn in code: the fallback for a tool that has no artwork,
/// and the template every future tool starts from.
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

/// The icon for one tool, at any size: the real app artwork where it exists, a drawn tile where
/// it does not.
///
/// - Zones is Lineup itself (window snapping was 1.x's whole product), so it uses the running
///   app's own icon — correct in the bundle and in a bare `swift run`.
/// - Cycler ships the standalone app's icon as a package resource.
/// - Hyperkey never had an app, so it gets an `AppStyleIcon`.
///
/// Every branch falls back to a drawn tile, so a missing resource degrades to something that
/// still reads as an icon instead of an empty gap.
struct ToolIcon: View {
    let id: ToolID
    var size: CGFloat

    var body: some View {
        if let image = ToolIconLibrary.artwork(for: id) {
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

/// Loads (once) the artwork behind `ToolIcon`.
enum ToolIconLibrary {
    static func artwork(for id: ToolID) -> NSImage? {
        switch id {
        case .zones: return appIcon
        case .cycler: return cyclerIcon
        default: return nil // Hyperkey and any future tool: drawn tile
        }
    }

    /// The SF Symbol used when there is no artwork. Also what a tool's sidebar row would show in
    /// a build where the resource bundle failed to ship.
    static func fallbackSymbol(for id: ToolID) -> String {
        switch id {
        case .zones: return "square.grid.2x2.fill"
        case .cycler: return "arrow.triangle.2.circlepath"
        case .hyperkey: return "capslock.fill"
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

    private static func bundled(_ name: String) -> NSImage? {
        // Do not use SwiftPM's generated `Bundle.module` accessor here. It traps when the
        // resource bundle is missing, which turns an optional icon into a launch crash. The
        // assembled app stores the bundle in Contents/Resources; a bare `swift run` keeps it
        // beside the executable. Search both locations and let the caller draw its fallback.
        var roots: [URL] = []
        if let resourceURL = Bundle.main.resourceURL { roots.append(resourceURL) }
        roots.append(Bundle.main.bundleURL)

        for root in roots {
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

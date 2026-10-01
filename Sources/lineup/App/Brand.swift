import AppKit
import AppCore

/// Single source of brand visuals: the fixed brand colours (so the product reads as one brand
/// regardless of the user's system accent) and the menu-bar logo.
///
/// The app icon and template menu-bar mark share Zones' pane grid. Feature artwork uses the
/// enamel family; the menu bar keeps only the silhouette so macOS can tint it naturally.
enum Brand {
    /// #2F6BFF — the app accent, and the Zones tool's accent.
    static let blue = NSColor(srgbRed: 0.184, green: 0.420, blue: 1.0, alpha: 1)

    /// Zones' accent is the app accent: window snapping is what Lineup has always been.
    static let zonesBlue = blue

    /// #F2580E — Cycler's warm orange, sampled from the standalone app's icon gradient. Deep
    /// enough that white text stays legible on a filled row (the cycle HUD's selection).
    static let cyclerAccent = NSColor(srgbRed: 0.949, green: 0.345, blue: 0.055, alpha: 1)

    /// #FA3C28 — the red end of that gradient, for accents that want the hotter hue.
    static let cyclerAccentHot = NSColor(srgbRed: 0.980, green: 0.235, blue: 0.157, alpha: 1)

    /// Hyperkey's accent: violet, distinct from both of the above.
    static let hyperkeyAccent = NSColor(srgbRed: 0.502, green: 0.353, blue: 0.937, alpha: 1)

    /// A tool's accent, for its Settings sidebar icon and any pane chrome that wants it.
    ///
    /// The three tools are told apart by colour + SF Symbol rather than by three separate marks:
    /// the menu-bar logo stays Lineup's, so the suite still reads as one app. Unknown ids (a
    /// future tool, or a section written by a newer build) fall back to the app accent.
    static func accent(for id: ToolID) -> NSColor {
        switch id {
        case .zones: return zonesBlue
        case .cycler: return cyclerAccent
        case .hyperkey: return hyperkeyAccent
        default: return blue
        }
    }

    /// Monochrome **template** menu-bar mark: the Zones motif (one tall left pane and two
    /// stacked right panes) drawn as three solid rounded pieces. Template
    /// = the system tints it (white on the dark menu bar, dark on light, highlighted when open).
    /// Solid fills with a small gutter so it reads at ~18 pt.
    static func menuBarLogo() -> NSImage {
        let size = NSSize(width: 18, height: 16)
        let img = NSImage(size: size, flipped: false) { rect in
            let box = rect.insetBy(dx: 1, dy: 1.5)
            let gap: CGFloat = 1.4
            let colW = (box.width - gap) / 2
            let rowH = (box.height - gap) / 2
            let radius: CGFloat = 1.3
            let leftPane = NSRect(x: box.minX, y: box.minY, width: colW, height: box.height)
            let rightX = box.minX + colW + gap
            let bottomRight = NSRect(x: rightX, y: box.minY, width: colW, height: rowH)
            let topRight = NSRect(x: rightX, y: box.minY + rowH + gap, width: colW, height: rowH)
            NSColor.black.setFill()
            for cell in [leftPane, bottomRight, topRight] {
                NSBezierPath(roundedRect: cell, xRadius: radius, yRadius: radius).fill()
            }
            return true
        }
        img.isTemplate = true // tints to the menu bar (light/dark, highlighted)
        return img
    }
}

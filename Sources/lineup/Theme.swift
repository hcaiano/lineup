import AppKit

/// Single source of brand visuals: the fixed brand blue (so the product reads as one brand
/// regardless of the user's system accent) and the menu-bar logo.
enum Brand {
    /// #2F6BFF
    static let blue = NSColor(srgbRed: 0.184, green: 0.420, blue: 1.0, alpha: 1)

    /// Monochrome **template** menu-bar mark: the app-icon motif (a tall pane on the left, a
    /// right column split into two stacked cells) drawn as three solid rounded zones. Template
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
            // Left: one tall pane, full height. Right: two stacked cells.
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

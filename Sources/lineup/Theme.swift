import AppKit

/// Single source of brand visuals: the fixed brand blue (so the product reads as one brand
/// regardless of the user's system accent) and the menu-bar logo.
enum Brand {
    /// #2F6BFF
    static let blue = NSColor(srgbRed: 0.184, green: 0.420, blue: 1.0, alpha: 1)

    /// Monochrome **template** menu-bar mark: a rounded "screen" split into three unequal
    /// columns (the lineup motif). Solid fills so it reads at ~18 pt; the system tints it.
    static func menuBarLogo() -> NSImage {
        let size = NSSize(width: 18, height: 16)
        let img = NSImage(size: size, flipped: false) { rect in
            let box = rect.insetBy(dx: 1, dy: 1.5)
            let gap: CGFloat = 1.6
            let usable = box.width - gap * 2
            let widths = [0.30, 0.40, 0.30].map { $0 * usable }
            NSColor.black.setFill()
            var x = box.minX
            for w in widths {
                NSBezierPath(roundedRect: NSRect(x: x, y: box.minY, width: w, height: box.height),
                             xRadius: 1.4, yRadius: 1.4).fill()
                x += w + gap
            }
            return true
        }
        img.isTemplate = true // tints to the menu bar (light/dark, highlighted)
        return img
    }
}

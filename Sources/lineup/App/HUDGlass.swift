import AppKit

/// The dark glass surface Lineup's on-screen overlays share: Liquid Glass on macOS 26 and later,
/// dark vibrancy before. Overlay text is white, so the surface is pinned dark whatever the
/// desktop or system appearance, as `CycleHUD` and the Hyperkey pill already do.
///
/// Frame-based on purpose: the overlays that use it lay out with frames.
@MainActor
enum HUDGlass {
    /// A plain container with the glass behind its subviews. Add content to the returned view.
    static func container(frame: NSRect, cornerRadius: CGFloat, tint: CGFloat = 0.42) -> NSView {
        let container = NSView(frame: frame)
        let surface = surface(size: frame.size, cornerRadius: cornerRadius, tint: tint)
        surface.autoresizingMask = [.width, .height]
        container.addSubview(surface)
        return container
    }

    private static func surface(size: NSSize, cornerRadius: CGFloat, tint: CGFloat) -> NSView {
        let frame = NSRect(origin: .zero, size: size)
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView(frame: frame)
            glass.style = .regular
            glass.cornerRadius = cornerRadius
            glass.tintColor = NSColor(white: 0, alpha: tint)
            glass.appearance = NSAppearance(named: .darkAqua)
            return glass
        }
        let blur = NSVisualEffectView(frame: frame)
        blur.material = .hudWindow
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.appearance = NSAppearance(named: .vibrantDark)
        blur.wantsLayer = true
        blur.layer?.cornerRadius = cornerRadius
        blur.layer?.masksToBounds = true
        return blur
    }
}

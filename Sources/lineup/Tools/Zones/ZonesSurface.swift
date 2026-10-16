import AppKit

@MainActor
enum ZonesSurface {
    /// Make `root` the window's content view and add controls to `content`. `NSGlassEffectView`
    /// only guarantees that its `contentView` sits inside the glass, not arbitrary subviews.
    static func container(size: CGSize, cornerRadius: CGFloat, scale: CGFloat) -> (root: NSView, content: NSView) {
        let root = NSView(frame: CGRect(origin: .zero, size: size))
        root.wantsLayer = true
        root.layer?.cornerRadius = cornerRadius
        root.layer?.masksToBounds = true
        let content = NSView(frame: root.bounds)
        content.autoresizingMask = [.width, .height]
        let surface: NSView
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView(frame: root.bounds)
            glass.style = .regular; glass.cornerRadius = cornerRadius
            glass.contentView = content
            surface = glass
        } else {
            let blur = NSVisualEffectView(frame: root.bounds)
            blur.material = .popover; blur.blendingMode = .behindWindow; blur.state = .active
            blur.maskImage = HUDGlass.roundedMask(radius: cornerRadius)
            blur.wantsLayer = true
            blur.layer?.cornerRadius = cornerRadius
            blur.layer?.borderWidth = 1 / scale
            blur.layer?.borderColor = NSColor.separatorColor.cgColor
            blur.addSubview(content)
            surface = blur
        }
        surface.autoresizingMask = [.width, .height]
        root.addSubview(surface)
        return (root, content)
    }
}

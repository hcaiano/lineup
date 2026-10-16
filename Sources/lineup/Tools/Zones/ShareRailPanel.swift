import AppKit
import ZonesCore

@MainActor
final class ShareRailPanel: NSPanel {
    private let tiles = [ShareTile(axis: .vertical), ShareTile(axis: .horizontal)]
    private let caption = NSTextField(labelWithString: "Share zone")
    private var targets: [ShareTarget] = []
    private var active: ShareTarget?

    init() {
        super.init(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
        isOpaque = false; backgroundColor = .clear
        ignoresMouseEvents = true; hasShadow = true
        hidesOnDeactivate = false
        level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
        collectionBehavior = [.stationary]
        // Concentric with the tiles, which sit 6 points inside and round at 8.
        let surface = ZonesSurface.container(size: .zero, cornerRadius: 14, scale: NSScreen.main?.backingScaleFactor ?? 2)
        caption.font = .systemFont(ofSize: 11, weight: .semibold)
        caption.alignment = .center
        caption.textColor = .labelColor
        for tile in tiles { surface.content.addSubview(tile) }
        surface.content.addSubview(caption)
        contentView = surface.root
    }

    func show(targets: [ShareTarget], active: ShareTarget? = nil) {
        guard !targets.isEmpty else { orderOut(nil); return }
        prepare(targets: targets, active: active)
        orderFront(nil)
    }

    func prepare(targets: [ShareTarget], active: ShareTarget?) {
        guard let first = targets.first else { return }
        if self.targets != targets {
            self.targets = targets
            let union = targets.reduce(first.rect) { $0.union($1.rect) }
            let frame = CGRect(x: union.minX - 6, y: union.minY - 24,
                               width: union.width + 12, height: union.height + 30)
            setFrame(frame, display: true)
            invalidateShadow()
            for tile in tiles {
                let target = targets.first { $0.axis == tile.axis }
                tile.isHidden = target == nil
                if let target { tile.frame = target.rect.offsetBy(dx: -frame.minX, dy: -frame.minY) }
            }
            caption.frame = CGRect(x: 0, y: 6, width: frame.width, height: 16)
        }
        if self.active != active {
            self.active = active
            for tile in tiles { tile.isActive = active?.axis == tile.axis }
            caption.stringValue = active.map { $0.axis == .vertical ? "Side by side" : "Stacked" } ?? "Share zone"
            caption.textColor = .labelColor
        }
    }
}

@MainActor
private final class ShareTile: NSView {
    let axis: Axis
    var isActive = false { didSet { if oldValue != isActive { needsDisplay = true } } }
    private let glyph: NSImage?

    init(axis: Axis) {
        self.axis = axis
        let description = axis == .vertical
            ? "Share zone side by side. Your window takes the right half."
            : "Share zone stacked. Your window takes the bottom half."
        glyph = NSImage(systemSymbolName: axis == .vertical ? "rectangle.righthalf.filled" : "rectangle.bottomhalf.filled",
                        accessibilityDescription: description)?
            .withSymbolConfiguration(.init(pointSize: 15, weight: .medium))
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel(description)
    }
    required init?(coder: NSCoder) { nil }

    override func draw(_ dirtyRect: NSRect) {
        (isActive ? NSColor.tertiaryLabelColor : .quaternaryLabelColor).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8).fill()
        let rect = CGRect(x: bounds.midX - 11, y: bounds.midY - 8, width: 22, height: 16)
        let ink: NSColor = isActive ? .labelColor : .secondaryLabelColor
        if let glyph {
            let tinted = NSImage(size: rect.size, flipped: false) { bounds in
                glyph.draw(in: bounds)
                ink.setFill(); bounds.fill(using: .sourceIn)
                return true
            }
            tinted.draw(in: rect)
        } else {
            ink.setStroke(); ink.setFill()
            let border = NSBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 1), xRadius: 2, yRadius: 2)
            border.lineWidth = 1.5; border.stroke()
            let half = axis == .vertical
                ? CGRect(x: rect.midX, y: rect.minY + 2, width: rect.width / 2 - 2, height: rect.height - 4)
                : CGRect(x: rect.minX + 2, y: rect.minY + 2, width: rect.width - 4, height: rect.height / 2 - 2)
            half.fill()
        }
    }
}

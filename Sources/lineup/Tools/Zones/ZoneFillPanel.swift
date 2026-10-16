import AppKit
import ZonesCore

@MainActor
final class ZoneFillPanel: NSPanel {
    struct Candidate {
        let app: String
        let title: String
        let display: String?
        let icon: NSImage?
    }

    override var canBecomeKey: Bool { true }
    private let selectCandidate: (Int) -> Void
    private let cancel: () -> Void
    private var columns = 3
    private var cards: [CandidateCard] = []
    private(set) var selectedIndex = 0
    private let heading = NSTextField(labelWithString: "Fill this zone")
    private let close = FirstMouseButton(title: "Close", target: nil, action: nil)
    private let scopeLabel = NSTextField(labelWithString: "Visible windows on this desktop")
    private let grid = GridView()
    private let scroll = NSScrollView()

    init(select: @escaping (Int) -> Void, cancel: @escaping () -> Void) {
        selectCandidate = select; self.cancel = cancel
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false; backgroundColor = .clear; hasShadow = true
        hidesOnDeactivate = false; level = .floating; collectionBehavior = [.stationary]
        autorecalculatesKeyViewLoop = true
        acceptsMouseMovedEvents = true
        animationBehavior = .none
    }

    func show(_ candidates: [Candidate], free: CGRect, filled: CGRect, visible: CGRect) {
        prepare(candidates, free: free, filled: filled, visible: visible)
        orderFront(nil)
    }

    func prepare(_ candidates: [Candidate], free: CGRect, filled: CGRect, visible: CGRect) {
        // Resolve columns for the actual bounded panel before choosing its row count.
        columns = ZoneFillLayout.columns(panelWidth: ZoneFillLayout.chooserFrame(
            free: free, filled: filled, visible: visible, rows: 1).width)
        let target = ZoneFillLayout.chooserFrame(free: free, filled: filled, visible: visible,
                                                 rows: max(1, (candidates.count + columns - 1) / columns))
        let display = NSScreen.screens.first { $0.frame.contains(CGPoint(x: target.midX, y: target.midY)) }
        let surface = ZonesSurface.container(size: .zero, cornerRadius: 16, scale: display?.backingScaleFactor ?? 2)
        heading.font = .systemFont(ofSize: 13, weight: .semibold)
        heading.textColor = .labelColor
        close.target = self; close.action = #selector(closeClicked)
        close.bezelStyle = .circular
        close.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close")?
            .withSymbolConfiguration(.init(pointSize: 10, weight: .bold))
        close.imagePosition = close.image == nil ? .noImage : .imageOnly
        close.contentTintColor = .secondaryLabelColor
        close.toolTip = "Close (Esc)"
        close.setAccessibilityLabel("Cancel window selection")
        scopeLabel.font = .systemFont(ofSize: 11); scopeLabel.textColor = .secondaryLabelColor
        scopeLabel.lineBreakMode = .byTruncatingTail
        scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true; scroll.drawsBackground = false
        scroll.documentView = grid
        for view in [heading, close, scopeLabel, scroll] { surface.content.addSubview(view) }
        contentView = surface.root
        cards.forEach { $0.removeFromSuperview() }
        cards = candidates.enumerated().map { index, candidate in
            let card = CandidateCard(candidate, target: self, action: #selector(candidateClicked(_:)))
            card.isSelectedCandidate = index == 0
            card.pointerMoved = { [weak self] in self?.hoverSelection(index) }
            grid.addSubview(card)
            return card
        }
        selectedIndex = 0
        layout(target)
        scroll.contentView.scroll(to: .zero)
        alphaValue = 1
        if isKeyWindow { makeFirstResponder(cards.first ?? close) }
    }

    func setThumbnail(_ image: CGImage?, at index: Int) {
        guard cards.indices.contains(index) else { return }
        cards[index].setThumbnail(image)
    }

    private func layout(_ frame: CGRect) {
        columns = ZoneFillLayout.columns(panelWidth: frame.width)
        setFrame(frame, display: true)
        invalidateShadow()
        let width = frame.width, height = frame.height
        let margin = min(ZoneFillLayout.margin, max(0, (width - 28) / 2))
        heading.frame = CGRect(x: margin, y: max(0, height - 34), width: max(0, width - 2 * margin - 40), height: min(16, height))
        scopeLabel.frame = CGRect(x: margin, y: max(0, height - 50), width: max(0, width - 2 * margin - 40), height: min(14, height))
        close.frame = CGRect(x: max(0, width - margin - 28), y: max(0, height - 48),
                             width: min(28, width), height: min(28, height))
        scroll.frame = CGRect(x: 0, y: min(ZoneFillLayout.bottom, height), width: width,
                              height: max(0, height - ZoneFillLayout.header - ZoneFillLayout.bottom))
        let cardWidth = min(ZoneFillLayout.thumbnail.width, max(1, scroll.contentSize.width - 2 * margin))
        let step = cardWidth + ZoneFillLayout.gap
        for (index, card) in cards.enumerated() {
            card.frame = CGRect(x: margin + CGFloat(index % columns) * step,
                                y: ZoneFillLayout.inset + CGFloat(index / columns) * (ZoneFillLayout.cardHeight + ZoneFillLayout.gap),
                                width: cardWidth, height: ZoneFillLayout.cardHeight)
        }
        let cardRows = (cards.count + columns - 1) / columns
        grid.frame = CGRect(x: 0, y: 0, width: scroll.contentSize.width,
                            height: 2 * ZoneFillLayout.inset + CGFloat(cardRows) * ZoneFillLayout.cardHeight
                                + CGFloat(max(0, cardRows - 1)) * ZoneFillLayout.gap)
    }

    @discardableResult
    override func makeFirstResponder(_ responder: NSResponder?) -> Bool {
        let changed = super.makeFirstResponder(responder)
        if changed, let index = cards.firstIndex(where: { $0 === firstResponder }) {
            selectedIndex = index
            for (position, card) in cards.enumerated() { card.isSelectedCandidate = position == index }
        }
        cards.forEach { $0.needsDisplay = true }
        return changed
    }
    override func becomeKey() {
        super.becomeKey()
        if firstResponder === self, cards.indices.contains(selectedIndex) { makeFirstResponder(cards[selectedIndex]) }
        cards.forEach { $0.needsDisplay = true }
    }
    override func resignKey() { super.resignKey(); cards.forEach { $0.needsDisplay = true } }

    override func sendEvent(_ event: NSEvent) {
        guard event.type == .keyDown else { return super.sendEvent(event) }
        switch event.keyCode {
        case 53: cancel()
        case 36, 76: confirm()
        case 49 where firstResponder === close: cancel()
        case 123: moveSelection(-1)
        case 124: moveSelection(1)
        case 126: moveSelection(-columns)
        case 125: moveSelection(columns)
        default: super.sendEvent(event)
        }
    }

    private func confirm() {
        let responder = firstResponder
        if responder === close { cancel(); return }
        if let index = cards.firstIndex(where: { $0 === responder }) { selectCandidate(index); return }
        if cards.indices.contains(selectedIndex) { selectCandidate(selectedIndex) } else { cancel() }
    }

    private func hoverSelection(_ index: Int) {
        let cardHadFocus = cards.contains { $0 === firstResponder }
        selectedIndex = index
        for (position, card) in cards.enumerated() { card.isSelectedCandidate = position == index }
        if cardHadFocus { makeFirstResponder(cards[index]) }
    }

    private func moveSelection(_ delta: Int) {
        guard !cards.isEmpty else { return }
        selectedIndex = min(max(selectedIndex + delta, 0), cards.count - 1)
        for (index, card) in cards.enumerated() { card.isSelectedCandidate = index == selectedIndex }
        makeFirstResponder(cards[selectedIndex])
        grid.scrollToVisible(cards[selectedIndex].frame.insetBy(dx: -6, dy: -6))
    }

    @objc private func closeClicked() { cancel() }
    @objc private func candidateClicked(_ sender: NSButton) {
        if let index = cards.firstIndex(where: { $0 === sender }) { selectCandidate(index) }
    }
}

@MainActor
private final class GridView: NSView {
    override var isFlipped: Bool { true }
}

@MainActor
private class FirstMouseButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

@MainActor
private final class CandidateCard: FirstMouseButton {
    private enum Preview { case pending, loaded(NSImage), unavailable }
    var isSelectedCandidate = false { didSet { if oldValue != isSelectedCandidate { needsDisplay = true } } }
    var pointerMoved: (() -> Void)?
    private var preview = Preview.pending
    private let icon: NSImage?
    private let app: NSTextField
    private let name: NSTextField
    private let display: NSTextField?
    override var isFlipped: Bool { true }
    override var wantsDefaultClipping: Bool { false }

    init(_ candidate: ZoneFillPanel.Candidate, target: AnyObject, action: Selector) {
        icon = candidate.icon
        app = NSTextField(labelWithString: candidate.app)
        name = NSTextField(labelWithString: candidate.title)
        display = candidate.display.map { NSTextField(labelWithString: $0) }
        super.init(frame: CGRect(origin: .zero, size: CGSize(width: ZoneFillLayout.thumbnail.width, height: ZoneFillLayout.cardHeight)))
        self.target = target; self.action = action
        title = ""; isBordered = false; bezelStyle = .regularSquare; focusRingType = .none
        app.font = .systemFont(ofSize: 12, weight: .semibold); app.lineBreakMode = .byTruncatingTail
        name.font = .systemFont(ofSize: 11); name.textColor = .secondaryLabelColor; name.lineBreakMode = .byTruncatingMiddle
        display?.font = .systemFont(ofSize: 11); display?.textColor = .secondaryLabelColor; display?.lineBreakMode = .byTruncatingTail
        for label in [app, name] + (display.map { [$0] } ?? []) {
            label.setAccessibilityElement(false); addSubview(label)
        }
        setAccessibilityLabel([candidate.app, candidate.title].joined(separator: ", ") + (candidate.display.map { ", on \($0)" } ?? ""))
        setAccessibilityValue("Loading preview")
    }
    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        app.frame = CGRect(x: 20, y: 102, width: max(0, bounds.width - 20), height: 16)
        name.frame = CGRect(x: 0, y: 118, width: bounds.width, height: 14)
        display?.frame = CGRect(x: 16, y: 132, width: max(0, bounds.width - 16), height: 14)
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.activeAlways, .mouseMoved, .inVisibleRect], owner: self))
    }
    override func mouseMoved(with event: NSEvent) { pointerMoved?() }
    override func highlight(_ flag: Bool) { super.highlight(flag); needsDisplay = true }
    override func becomeFirstResponder() -> Bool { let result = super.becomeFirstResponder(); needsDisplay = true; return result }
    override func resignFirstResponder() -> Bool { let result = super.resignFirstResponder(); needsDisplay = true; return result }
    override func hitTest(_ point: NSPoint) -> NSView? { super.hitTest(point) == nil ? nil : self }

    func setThumbnail(_ image: CGImage?) {
        preview = image.map { .loaded(NSImage(cgImage: $0, size: CGSize(width: $0.width, height: $0.height))) } ?? .unavailable
        setAccessibilityValue(image == nil ? "Preview unavailable" : "")
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let well = CGRect(x: 0, y: 0, width: bounds.width, height: ZoneFillLayout.thumbnail.height)
        let path = NSBezierPath(roundedRect: well, xRadius: 8, yRadius: 8)
        NSColor.quaternaryLabelColor.setFill(); path.fill()
        NSGraphicsContext.saveGraphicsState()
        path.addClip()
        func drawImage(_ image: NSImage, in rect: CGRect, fraction: CGFloat = 1) {
            let size = ThumbnailSize.fit(image.size, maximum: rect.size)
            image.draw(in: CGRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2, width: size.width, height: size.height),
                       from: .zero, operation: .sourceOver, fraction: fraction, respectFlipped: true, hints: nil)
        }
        switch preview {
        case .loaded(let image): drawImage(image, in: well)
        case .pending:
            if let icon { drawImage(icon, in: CGRect(x: well.midX - 16, y: well.midY - 16, width: 32, height: 32), fraction: 0.55) }
        case .unavailable:
            let fallback = NSImage(systemSymbolName: "macwindow", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 24, weight: .regular))
            if let image = icon ?? fallback.map({ tinted($0, color: .tertiaryLabelColor) }) {
                drawImage(image, in: CGRect(x: well.midX - 16, y: 24, width: 32, height: 32))
            }
            let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor]
            let label = "Preview unavailable"; let size = label.size(withAttributes: attributes)
            label.draw(at: CGPoint(x: well.midX - size.width / 2, y: 72), withAttributes: attributes)
        }
        if isHighlighted { NSColor.labelColor.withAlphaComponent(0.14).setFill(); well.fill() }
        NSGraphicsContext.restoreGraphicsState()
        NSColor.separatorColor.setStroke(); path.lineWidth = 0.5; path.stroke()
        if let icon { drawImage(icon, in: CGRect(x: 0, y: 102, width: 16, height: 16)) }
        if display != nil {
            let glyph = NSImage(systemSymbolName: "display", accessibilityDescription: nil)
                ?? NSImage(systemSymbolName: "rectangle", accessibilityDescription: nil)
            if let glyph { drawImage(tinted(glyph, color: .secondaryLabelColor), in: CGRect(x: 0, y: 133, width: 12, height: 12)) }
        }
        if isSelectedCandidate {
            let contrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
            let focused = window?.isKeyWindow == true && window?.firstResponder === self
            (focused ? NSColor.controlAccentColor : .tertiaryLabelColor).setStroke()
            let inset: CGFloat = contrast ? 4 : 3.5
            let ring = NSBezierPath(roundedRect: well.insetBy(dx: -inset, dy: -inset), xRadius: 8 + inset, yRadius: 8 + inset)
            ring.lineWidth = contrast ? 4 : 3; ring.stroke()
        }
    }

    private func tinted(_ image: NSImage, color: NSColor) -> NSImage {
        NSImage(size: image.size, flipped: false) { rect in
            image.draw(in: rect); color.setFill(); rect.fill(using: .sourceIn)
            return true
        }
    }
}

import AppKit
import LineupCore

/// Full-screen, WYSIWYG layout editor. Opens an editor over EVERY connected display at once, each
/// showing that display's own layout (no picker to get confused by). Hover a zone to reveal labeled
/// split/merge controls, drag the grip handles to resize, and Save (bottom-center, reachable even on
/// a very wide screen). Esc/Cancel discards. Commits all changed displays atomically on Save.
final class LayoutEditorOverlayController {
    private var windows: [EditorWindow] = []
    private var canvases: [EditorCanvas] = []
    private var errorBanners: [NSView] = []
    private var previousApp: NSRunningApplication?

    private let screens: [(screen: NSScreen, info: ScreenInfo)]
    private var drafts: [String: Node] = [:]            // per-screen edited layout (draft)
    private let baseConfig: LineupConfig
    private let canWrite: Bool
    private let blockedMessage: String?
    private let commit: ([(screen: ScreenInfo, layout: Node)]) -> Bool
    private let onClose: () -> Void

    init(config: LineupConfig,
         canWrite: Bool,
         blockedMessage: String?,
         commit: @escaping ([(screen: ScreenInfo, layout: Node)]) -> Bool,
         onClose: @escaping () -> Void) {
        self.baseConfig = config
        self.canWrite = canWrite
        self.blockedMessage = blockedMessage
        self.commit = commit
        self.onClose = onClose
        self.screens = NSScreen.screens.map { ($0, ScreenIdentity.info(for: $0)) }
    }

    func show() {
        guard !screens.isEmpty else { onClose(); return }
        previousApp = NSWorkspace.shared.frontmostApplication
        for (screen, info) in screens { openWindow(for: screen, info: info) }
        NSApp.activate(ignoringOtherApps: true)
        windows.first?.makeKeyAndOrderFront(nil)
        if let cv = canvases.first { windows.first?.makeFirstResponder(cv) }
    }

    private func draft(for info: ScreenInfo) -> Node { drafts[info.key] ?? baseConfig.layout(forKey: info.key) }

    private func openWindow(for screen: NSScreen, info: ScreenInfo) {
        let win = EditorWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false, screen: screen)
        win.isOpaque = false
        win.backgroundColor = NSColor.black.withAlphaComponent(0.001)
        win.level = .screenSaver
        win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        win.ignoresMouseEvents = false
        win.acceptsMouseMovedEvents = true

        let container = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
        let cv = EditorCanvas(frame: container.bounds, screenFrame: screen.frame, visibleFrame: screen.visibleFrame, info: info)
        cv.autoresizingMask = [.width, .height]
        cv.editable = canWrite
        cv.root = draft(for: info)
        cv.onChange = { [weak self] node in self?.drafts[info.key] = node }
        cv.onCancel = { [weak self] in self?.cancelTapped() }
        cv.onCommit = { [weak self] in self?.doneTapped() }
        container.addSubview(cv)
        canvases.append(cv)

        addChrome(to: container, screenSize: screen.frame.size, label: info.label)
        win.contentView = container
        windows.append(win)
        win.orderFrontRegardless()
    }

    private func addChrome(to container: NSView, screenSize: CGSize, label: String) {
        // Top-center: short instruction (or the blocked reason).
        let hint = NSTextField(labelWithString:
            canWrite ? "Hover a zone to split or merge it. Drag a handle to resize."
                     : (blockedMessage ?? "Editing is disabled."))
        hint.alignment = .center
        hint.textColor = canWrite ? .white : .systemOrange
        hint.font = .systemFont(ofSize: 14, weight: canWrite ? .regular : .semibold)
        let hp = panel(NSRect(x: screenSize.width / 2 - 320, y: screenSize.height - 72, width: 640, height: 44))
        hint.frame = NSRect(x: 14, y: 11, width: 612, height: 22)
        hp.addSubview(hint); container.addSubview(hp)

        // Inline save-failure banner (hidden). An NSAlert would render behind the overlay.
        let err = panel(NSRect(x: screenSize.width / 2 - 300, y: 150, width: 600, height: 40))
        err.layer?.backgroundColor = NSColor.systemOrange.withAlphaComponent(0.92).cgColor // warning, never red
        let errLabel = NSTextField(labelWithString: "Couldn’t save — your changes are still here. Try Save again.")
        errLabel.frame = NSRect(x: 12, y: 9, width: 576, height: 22)
        errLabel.alignment = .center; errLabel.textColor = .white; errLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        err.addSubview(errLabel); err.isHidden = true
        container.addSubview(err); errorBanners.append(err)

        // Bottom-CENTER: Cancel + Save (reachable on very wide displays, unlike a corner).
        let barW: CGFloat = 300, barH: CGFloat = 60
        let bar = panel(NSRect(x: screenSize.width / 2 - barW / 2, y: 36, width: barW, height: barH))
        container.addSubview(bar)
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelTapped))
        cancel.keyEquivalent = "\u{1b}"; cancel.bezelStyle = .rounded
        cancel.frame = NSRect(x: 18, y: 16, width: 120, height: 28)
        bar.addSubview(cancel)
        let save = NSButton(title: canWrite ? "Save" : "Reset…", target: self,
                            action: canWrite ? #selector(doneTapped) : #selector(cancelTapped))
        save.keyEquivalent = "\r"; save.bezelStyle = .rounded
        save.contentTintColor = Brand.blue
        save.frame = NSRect(x: 162, y: 16, width: 120, height: 28)
        bar.addSubview(save)
    }

    private func panel(_ frame: NSRect) -> NSView {
        let v = NSView(frame: frame); v.wantsLayer = true
        v.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.58).cgColor
        v.layer?.cornerRadius = 12
        return v
    }

    @objc private func doneTapped() {
        let changes: [(screen: ScreenInfo, layout: Node)] = screens.compactMap { (_, info) in
            guard let edited = drafts[info.key], edited != baseConfig.layout(forKey: info.key) else { return nil }
            return (info, edited)
        }
        if changes.isEmpty { close(); return }
        if commit(changes) {
            close()
        } else {
            errorBanners.forEach { $0.isHidden = false } // surface inline; NSAlert would hide behind the overlay
        }
    }

    @objc private func cancelTapped() { close() }

    private func close() {
        windows.forEach { $0.orderOut(nil) }
        windows.removeAll(); canvases.removeAll(); errorBanners.removeAll()
        if let prev = previousApp, prev != NSRunningApplication.current {
            if #available(macOS 14.0, *) { prev.activate() } else { prev.activate(options: []) }
        }
        previousApp = nil
        onClose()
    }
}

final class EditorWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

// MARK: - Canvas

private final class EditorCanvas: NSView {
    var root: Node = .halves { didSet { rebuildIfNeeded() } }
    var onChange: ((Node) -> Void)?
    var onCancel: (() -> Void)?
    var onCommit: (() -> Void)?
    var editable = true

    private let screenFrame: CGRect
    private let visibleFrame: CGRect
    private let info: ScreenInfo

    private var activePath: [Int]?
    private var pinned = false
    private var dragging: Layout.DividerHandle?
    private var tracking: NSTrackingArea?

    private let controlBar = ZoneControlBar()

    init(frame: NSRect, screenFrame: CGRect, visibleFrame: CGRect, info: ScreenInfo) {
        self.screenFrame = screenFrame
        self.visibleFrame = visibleFrame
        self.info = info
        super.init(frame: frame)
        controlBar.isHidden = true
        controlBar.onSplitV = { [weak self] in self?.splitV() }
        controlBar.onSplitH = { [weak self] in self?.splitH() }
        controlBar.onMerge = { [weak self] in self?.mergeZone() }
        addSubview(controlBar)
    }
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { false }
    override var acceptsFirstResponder: Bool { true }

    // MARK: geometry (overlay is 1:1 over the screen; subtract the screen origin)
    private func viewRect(_ globalCocoa: CGRect) -> CGRect {
        CGRect(x: globalCocoa.minX - screenFrame.minX, y: globalCocoa.minY - screenFrame.minY,
               width: globalCocoa.width, height: globalCocoa.height)
    }
    private var container: CGRect { Layout.rootContainer(frame: screenFrame, visibleFrame: visibleFrame) }
    private func leaves() -> [(path: [Int], rect: CGRect)] {
        Layout.leaves(root, container: container, pixelsWide: info.pixelsWide)
    }
    private func handles() -> [Layout.DividerHandle] {
        Layout.dividerHandles(root, container: container, pixelsWide: info.pixelsWide)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds, options: [.activeAlways, .mouseMoved, .mouseEnteredAndExited], owner: self)
        addTrackingArea(t); tracking = t
    }

    override func resetCursorRects() {
        guard editable else { return }
        for h in handles() {
            let r = viewRect(h.line).insetBy(dx: h.axis == .vertical ? -5 : 0, dy: h.axis == .vertical ? 0 : -5)
            addCursorRect(r, cursor: h.axis == .vertical ? .resizeLeftRight : .resizeUpDown)
        }
    }

    private func rebuildIfNeeded() { positionControls(); needsDisplay = true; window?.invalidateCursorRects(for: self) }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.20).setFill(); bounds.fill()
        let lv = leaves()
        for (i, leaf) in lv.enumerated() {
            let r = viewRect(leaf.rect).insetBy(dx: 3, dy: 3)
            let isActive = leaf.path == activePath
            (isActive ? Brand.blue.withAlphaComponent(0.30) : Brand.blue.withAlphaComponent(0.12)).setFill()
            let p = NSBezierPath(roundedRect: r, xRadius: 10, yRadius: 10); p.fill()
            (isActive ? Brand.blue : Brand.blue.withAlphaComponent(0.55)).setStroke()
            p.lineWidth = isActive ? 3 : 1.5; p.stroke()
            drawNumber(i + 1, in: r)
            drawSize(of: leaf.rect, in: r, controlsShown: isActive && !controlBar.isHidden)
        }
        if editable {
            for h in handles() { drawHandle(h) }
        }
    }

    /// Every zone shows its size in physical pixels, centered — the one number that matters,
    /// where the eye already is. It updates live while a divider drags. (Replaces the old
    /// px-on-root / %-on-nested divider pills, which mixed units across the same screen.)
    /// Conversion uses the SCREEN frame's points→pixels scale on both axes; the layout
    /// container is shorter than the screen (visibleFrame height), so scaling by container
    /// height would overstate a full-height zone by the menu bar/Dock.
    private func drawSize(of globalRect: CGRect, in viewR: CGRect, controlsShown: Bool) {
        let pxPerPtX = CGFloat(info.pixelsWide) / max(screenFrame.width, 1)
        let pxPerPtY = CGFloat(info.pixelsHigh) / max(screenFrame.height, 1)
        let w = Int((globalRect.width * pxPerPtX).rounded())
        let h = Int((globalRect.height * pxPerPtY).rounded())
        let s = NSAttributedString(string: "\(w) × \(h) px", attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 14, weight: .semibold),
            .foregroundColor: NSColor.white])
        let sz = s.size()
        let pad: CGFloat = 8
        // Centered; while this zone's control bar is up, sit just below it instead.
        let cy = controlsShown ? viewR.midY - 56 - sz.height : viewR.midY
        let pill = CGRect(x: viewR.midX - sz.width / 2 - pad, y: cy - sz.height / 2 - pad / 2,
                          width: sz.width + pad * 2, height: sz.height + pad)
        guard pill.width < viewR.width - 8 else { return } // zone too small for a readout
        NSColor.black.withAlphaComponent(0.55).setFill()
        NSBezierPath(roundedRect: pill, xRadius: 7, yRadius: 7).fill()
        s.draw(at: NSPoint(x: pill.midX - sz.width / 2, y: pill.midY - sz.height / 2))
    }

    /// A divider: a soft line plus a clearly-grabbable grip pill with dots. (Sizes live in
    /// the zones themselves — see drawSize — so the handle carries no readout.)
    private func drawHandle(_ h: Layout.DividerHandle) {
        let r = viewRect(h.line)
        let vertical = h.axis == .vertical
        // The line.
        NSColor.white.withAlphaComponent(0.9).setFill()
        NSBezierPath(roundedRect: r.insetBy(dx: vertical ? 0 : 2, dy: vertical ? 2 : 0), xRadius: 2, yRadius: 2).fill()
        // The grip pill at the divider's middle.
        let gripL: CGFloat = 44, gripT: CGFloat = 16
        let grip = vertical
            ? NSRect(x: r.midX - gripT / 2, y: r.midY - gripL / 2, width: gripT, height: gripL)
            : NSRect(x: r.midX - gripL / 2, y: r.midY - gripT / 2, width: gripL, height: gripT)
        NSColor.white.setFill()
        NSBezierPath(roundedRect: grip, xRadius: gripT / 2, yRadius: gripT / 2).fill()
        Brand.blue.setStroke()
        let gp = NSBezierPath(roundedRect: grip.insetBy(dx: 0.5, dy: 0.5), xRadius: gripT / 2, yRadius: gripT / 2)
        gp.lineWidth = 1.5; gp.stroke()
        // Three grip dots.
        Brand.blue.withAlphaComponent(0.8).setFill()
        for k in -1...1 {
            let d: CGFloat = 3.2
            let c = vertical ? CGPoint(x: grip.midX, y: grip.midY + CGFloat(k) * 8)
                             : CGPoint(x: grip.midX + CGFloat(k) * 8, y: grip.midY)
            NSBezierPath(ovalIn: CGRect(x: c.x - d / 2, y: c.y - d / 2, width: d, height: d)).fill()
        }
    }

    private func drawNumber(_ n: Int, in r: CGRect) {
        let s = NSAttributedString(string: "\(n)", attributes: [
            .font: NSFont.systemFont(ofSize: 24, weight: .bold),
            .foregroundColor: NSColor.white.withAlphaComponent(0.85)])
        let sz = s.size()
        s.draw(at: NSPoint(x: r.midX - sz.width / 2, y: r.maxY - sz.height - 12))
    }

    // MARK: controls

    private func positionControls() {
        guard editable, let path = activePath, let rect = leaves().first(where: { $0.path == path })?.rect else {
            controlBar.isHidden = true
            return
        }
        let vr = viewRect(rect)
        controlBar.showsMerge = !path.isEmpty
        let size = controlBar.preferredSize
        // Centered in the zone; hide rather than overflow a zone too small to host it.
        guard vr.width > size.width + 16, vr.height > size.height + 60 else {
            controlBar.isHidden = true
            return
        }
        controlBar.frame = NSRect(x: vr.midX - size.width / 2, y: vr.midY - size.height / 2,
                                  width: size.width, height: size.height)
        controlBar.isHidden = false
    }

    private func setActive(_ path: [Int]?, pinned: Bool) {
        activePath = path; self.pinned = pinned
        positionControls(); needsDisplay = true
    }

    override func mouseMoved(with event: NSEvent) {
        guard editable, !pinned else { return }
        let p = convert(event.locationInWindow, from: nil)
        setActive(leaves().first(where: { $0.rect.contains(globalPoint(p)) })?.path, pinned: false)
    }
    override func mouseExited(with event: NSEvent) {
        guard !pinned else { return }
        setActive(nil, pinned: false)
    }

    private func globalPoint(_ viewPoint: CGPoint) -> CGPoint {
        CGPoint(x: viewPoint.x + screenFrame.minX, y: viewPoint.y + screenFrame.minY)
    }

    override func mouseDown(with event: NSEvent) {
        guard editable else { return }
        let p = convert(event.locationInWindow, from: nil)
        for h in handles() {
            if viewRect(h.line).insetBy(dx: -6, dy: -6).contains(p) { dragging = h; return }
        }
        if let path = leaves().first(where: { $0.rect.contains(globalPoint(p)) })?.path {
            setActive(path, pinned: true)
        } else {
            setActive(nil, pinned: false)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let h = dragging else { return }
        let gp = globalPoint(convert(event.locationInWindow, from: nil))
        let frac: Double = h.axis == .vertical
            ? Double((gp.x - h.container.minX) / max(h.container.width, 1))
            : Double((h.container.maxY - gp.y) / max(h.container.height, 1))
        let containerLength = Double(h.axis == .vertical ? h.container.width : h.container.height)
        let updated = LayoutEdit.setDivider(root, at: h.path, index: h.index, fraction: frac,
                                            rootPixelsWide: info.pixelsWide, containerLength: containerLength)
        if updated != root { root = updated; onChange?(root) }
    }

    override func mouseUp(with event: NSEvent) { dragging = nil }

    override func cancelOperation(_ sender: Any?) { onCancel?() }
    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: onCancel?()          // Esc
        case 36, 76: onCommit?()      // Return / Enter
        default: super.keyDown(with: event)
        }
    }

    @objc private func splitV() { edit { LayoutEdit.split($0, at: activePath ?? [], axis: .vertical) } }
    @objc private func splitH() { edit { LayoutEdit.split($0, at: activePath ?? [], axis: .horizontal) } }
    @objc private func mergeZone() { edit { LayoutEdit.merge($0, at: activePath ?? []) } }

    private func edit(_ op: (Node) -> Node) {
        guard editable, activePath != nil else { return }
        let updated = op(root)
        guard updated != root else { return }
        root = updated
        onChange?(root)
        setActive(nil, pinned: false) // structure changed; re-hover to act again
    }
}

// MARK: - Zone control bar

/// One HUD bar per active zone: Split ▯|▯ · Split ▯/▯ · Merge. Same dark material as the rest
/// of the overlay chrome (one component vocabulary), glyphs that depict the result, hover
/// highlight in the brand blue. Replaces the old floating white chips.
private final class ZoneControlBar: NSView {
    var onSplitV: () -> Void = {}
    var onSplitH: () -> Void = {}
    var onMerge: () -> Void = {}
    var showsMerge = true { didSet { mergeButton.isHidden = !showsMerge; relayout() } }

    var preferredSize: NSSize {
        let count = showsMerge ? 3 : 2
        return NSSize(width: CGFloat(count) * segmentW + 2 * padding, height: segmentH + 2 * padding)
    }

    private let segmentW: CGFloat = 86, segmentH: CGFloat = 58, padding: CGFloat = 6
    private var splitVButton: GlyphButton!
    private var splitHButton: GlyphButton!
    private var mergeButton: GlyphButton!

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.72).cgColor
        layer?.cornerRadius = 14
        splitVButton = GlyphButton(title: "Split", kind: .splitVertical) { [weak self] in self?.onSplitV() }
        splitHButton = GlyphButton(title: "Stack", kind: .splitHorizontal) { [weak self] in self?.onSplitH() }
        mergeButton = GlyphButton(title: "Merge", kind: .merge) { [weak self] in self?.onMerge() }
        for b in [splitVButton!, splitHButton!, mergeButton!] { addSubview(b) }
        relayout()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func relayout() {
        var x = padding
        for b in [splitVButton!, splitHButton!, mergeButton!] where !b.isHidden {
            b.frame = NSRect(x: x, y: padding, width: segmentW, height: segmentH)
            x += segmentW
        }
    }

    /// A segment: a glyph that shows the resulting shape, over a short label. Hover fills the
    /// segment with the brand blue; the glyph and label stay white throughout.
    private final class GlyphButton: NSView {
        enum Kind { case splitVertical, splitHorizontal, merge }
        private let kind: Kind
        private let title: String
        private let action: () -> Void
        private var hovered = false { didSet { needsDisplay = true } }

        init(title: String, kind: Kind, action: @escaping () -> Void) {
            self.kind = kind
            self.title = title
            self.action = action
            super.init(frame: .zero)
            setAccessibilityElement(true)
            setAccessibilityRole(.button)
            setAccessibilityLabel(accessibilityText)
            toolTip = accessibilityText
        }
        required init?(coder: NSCoder) { fatalError() }

        private var accessibilityText: String {
            switch kind {
            case .splitVertical: return "Split into two, side by side"
            case .splitHorizontal: return "Split into two, stacked"
            case .merge: return "Merge back into one zone"
            }
        }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach(removeTrackingArea)
            addTrackingArea(NSTrackingArea(rect: bounds, options: [.activeAlways, .mouseEnteredAndExited], owner: self))
        }
        override func mouseEntered(with event: NSEvent) { hovered = true }
        override func mouseExited(with event: NSEvent) { hovered = false }
        override func mouseDown(with event: NSEvent) { action() }
        override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }

        override func draw(_ dirtyRect: NSRect) {
            if hovered {
                Brand.blue.setFill()
                NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: 10, yRadius: 10).fill()
            }
            // Glyph: a 30×22 rounded rect depicting the result, centered above the label.
            let gw: CGFloat = 30, gh: CGFloat = 22
            let g = NSRect(x: bounds.midX - gw / 2, y: bounds.midY - gh / 2 + 7, width: gw, height: gh)
            let white = NSColor.white
            white.setStroke()
            let outline = NSBezierPath(roundedRect: g, xRadius: 4, yRadius: 4)
            outline.lineWidth = 2
            outline.stroke()
            let line = NSBezierPath()
            switch kind {
            case .splitVertical:
                line.move(to: NSPoint(x: g.midX, y: g.minY + 2)); line.line(to: NSPoint(x: g.midX, y: g.maxY - 2))
            case .splitHorizontal:
                line.move(to: NSPoint(x: g.minX + 2, y: g.midY)); line.line(to: NSPoint(x: g.maxX - 2, y: g.midY))
            case .merge:
                // Two halves becoming one: a dashed center line fading out reads as "remove the split".
                line.move(to: NSPoint(x: g.midX, y: g.minY + 3)); line.line(to: NSPoint(x: g.midX, y: g.maxY - 3))
                line.setLineDash([2, 3], count: 2, phase: 0)
            }
            line.lineWidth = 2
            line.stroke()
            // Label.
            let s = NSAttributedString(string: title, attributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
                .foregroundColor: white])
            let sz = s.size()
            s.draw(at: NSPoint(x: bounds.midX - sz.width / 2, y: bounds.minY + 6))
        }
    }
}

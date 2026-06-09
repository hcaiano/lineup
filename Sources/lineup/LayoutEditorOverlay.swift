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

    private let splitVBtn = EditorCanvas.controlButton("rectangle.split.2x1", "Side by side")
    private let splitHBtn = EditorCanvas.controlButton("rectangle.split.1x2", "Stacked")
    private let mergeBtn = EditorCanvas.controlButton("arrow.down.right.and.arrow.up.left", "Merge")

    init(frame: NSRect, screenFrame: CGRect, visibleFrame: CGRect, info: ScreenInfo) {
        self.screenFrame = screenFrame
        self.visibleFrame = visibleFrame
        self.info = info
        super.init(frame: frame)
        for b in [splitVBtn, splitHBtn, mergeBtn] { b.isHidden = true; addSubview(b) }
        splitVBtn.target = self; splitVBtn.action = #selector(splitV)
        splitHBtn.target = self; splitHBtn.action = #selector(splitH)
        mergeBtn.target = self; mergeBtn.action = #selector(mergeZone)
    }
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { false }
    override var acceptsFirstResponder: Bool { true }

    /// A labeled control chip (icon above a short word), big enough to read and tap.
    private static func controlButton(_ symbol: String, _ title: String) -> NSButton {
        let b = NSButton()
        b.bezelStyle = .regularSquare
        b.isBordered = false
        b.imagePosition = .imageAbove
        b.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        b.symbolConfiguration = .init(pointSize: 22, weight: .semibold)
        b.attributedTitle = NSAttributedString(string: title, attributes: [
            .foregroundColor: NSColor.black.withAlphaComponent(0.75),
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold)])
        b.contentTintColor = Brand.blue
        b.toolTip = title
        b.wantsLayer = true
        b.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.96).cgColor
        b.layer?.cornerRadius = 12
        b.layer?.shadowColor = NSColor.black.cgColor
        b.layer?.shadowOpacity = 0.25; b.layer?.shadowRadius = 8; b.layer?.shadowOffset = .init(width: 0, height: -2)
        return b
    }

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
        }
        if editable {
            for h in handles() { drawHandle(h) }
        }
    }

    /// A divider: a soft line plus a clearly-grabbable grip pill with dots, and a readout.
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
        drawDividerReadout(h, viewLine: r, grip: grip)
    }

    /// Root vertical dividers show physical pixels (seam alignment); nested/horizontal show a percent.
    private func drawDividerReadout(_ h: Layout.DividerHandle, viewLine: CGRect, grip: CGRect) {
        let text: String
        if h.path.isEmpty && h.axis == .vertical {
            let pointsFromLeft = h.line.midX - h.container.minX
            let pixels = pointsFromLeft / max(h.container.width, 1) * CGFloat(info.pixelsWide)
            text = "\(Int(pixels.rounded())) px"
        } else if h.axis == .vertical {
            let pct = (h.line.midX - h.container.minX) / max(h.container.width, 1) * 100
            text = "\(Int(pct.rounded()))%"
        } else {
            let pct = (h.container.maxY - h.line.midY) / max(h.container.height, 1) * 100
            text = "\(Int(pct.rounded()))%"
        }
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .bold),
            .foregroundColor: NSColor.white]
        let s = NSAttributedString(string: text, attributes: attrs)
        let sz = s.size()
        let pad: CGFloat = 7
        let pillW = sz.width + pad * 2, pillH = sz.height + pad
        // Place the readout just beside the grip so it's clearly tied to the handle you're moving.
        let center = h.axis == .vertical
            ? CGPoint(x: grip.midX, y: grip.maxY + pillH / 2 + 6)
            : CGPoint(x: grip.maxX + pillW / 2 + 6, y: grip.midY)
        let pill = CGRect(x: center.x - pillW / 2, y: center.y - pillH / 2, width: pillW, height: pillH)
        NSColor.black.withAlphaComponent(0.72).setFill()
        NSBezierPath(roundedRect: pill, xRadius: 6, yRadius: 6).fill()
        s.draw(at: NSPoint(x: pill.midX - sz.width / 2, y: pill.midY - sz.height / 2))
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
            for b in [splitVBtn, splitHBtn, mergeBtn] { b.isHidden = true }
            return
        }
        let vr = viewRect(rect)
        let w: CGFloat = 92, hgt: CGFloat = 72, gap: CGFloat = 14
        let cx = vr.midX, cy = vr.midY
        splitVBtn.frame = NSRect(x: cx - w - gap / 2, y: cy - hgt / 2, width: w, height: hgt)
        splitHBtn.frame = NSRect(x: cx + gap / 2, y: cy - hgt / 2, width: w, height: hgt)
        let mergeEnabled = !path.isEmpty
        mergeBtn.isHidden = !mergeEnabled
        mergeBtn.frame = NSRect(x: cx - w / 2, y: cy - hgt / 2 - hgt - 12, width: w, height: hgt)
        for b in [splitVBtn, splitHBtn] { b.isHidden = false }
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
        let updated = LayoutEdit.setDivider(root, at: h.path, index: h.index, fraction: frac, rootPixelsWide: info.pixelsWide)
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

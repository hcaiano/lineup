import AppKit
import LineupCore

/// Full-screen, WYSIWYG layout editor — the ONE place to shape a per-screen layout. Shows
/// the display's actual zones (the whole recursive tree, so nested splits render correctly),
/// reveals visual split/merge controls on hover, drags dividers, and commits a DRAFT on Done
/// (Esc/Cancel discards). Replaces the old root-only "align dividers" overlay.
final class LayoutEditorOverlayController {
    private var window: EditorWindow?
    private var canvas: EditorCanvas?
    private var previousApp: NSRunningApplication?

    private let screens: [(screen: NSScreen, info: ScreenInfo)]
    private var currentIndex: Int
    private var drafts: [String: Node] = [:]          // per-screen edited layouts (draft)
    private let baseConfig: LineupConfig
    private let canWrite: Bool
    private let blockedMessage: String?
    private let commit: ([(screen: ScreenInfo, layout: Node)]) -> Bool
    private let onClose: () -> Void

    private let picker = NSPopUpButton(frame: .zero, pullsDown: false)
    private var errorPanel: NSView?  // inline save-failure banner (NSAlert would hide behind the overlay)

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
        // Open on the display under the pointer; widest as fallback.
        let mouse = NSEvent.mouseLocation
        let underPointer = screens.firstIndex { NSMouseInRect(mouse, $0.screen.frame, false) }
        let widest = screens.enumerated().max { $0.element.info.pixelsWide < $1.element.info.pixelsWide }?.offset
        self.currentIndex = underPointer ?? widest ?? 0
    }

    func show() {
        guard !screens.isEmpty else { onClose(); return }
        previousApp = NSWorkspace.shared.frontmostApplication
        openWindow(for: currentIndex)
    }

    private func draft(for info: ScreenInfo) -> Node {
        drafts[info.key] ?? baseConfig.layout(forKey: info.key)
    }

    private func openWindow(for index: Int) {
        window?.orderOut(nil)
        currentIndex = index
        let (screen, info) = screens[index]

        let win = EditorWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false, screen: screen)
        win.isOpaque = false
        win.backgroundColor = NSColor.black.withAlphaComponent(0.001) // catch clicks, see-through
        win.level = .screenSaver
        win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        win.ignoresMouseEvents = false
        win.acceptsMouseMovedEvents = true // hover is the primary reveal path

        let container = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
        let cv = EditorCanvas(frame: container.bounds, screenFrame: screen.frame, visibleFrame: screen.visibleFrame, info: info)
        cv.autoresizingMask = [.width, .height]
        cv.editable = canWrite
        cv.root = draft(for: info)
        cv.onChange = { [weak self] node in self?.drafts[info.key] = node }
        cv.onCancel = { [weak self] in self?.cancelTapped() }
        container.addSubview(cv)
        self.canvas = cv

        addChrome(to: container, screenSize: screen.frame.size, info: info)
        win.contentView = container
        window = win

        NSApp.activate(ignoringOtherApps: true)
        win.makeKeyAndOrderFront(nil)
        win.makeFirstResponder(cv)
    }

    private func addChrome(to container: NSView, screenSize: CGSize, info: ScreenInfo) {
        // Top-left: "Editing: <Display>" + display picker, on a dark panel.
        let topPanel = panel(NSRect(x: 24, y: screenSize.height - 76, width: 460, height: 52))
        container.addSubview(topPanel)
        let title = NSTextField(labelWithString: "Editing layout")
        title.frame = NSRect(x: 16, y: 16, width: 110, height: 20)
        title.textColor = .white; title.font = .systemFont(ofSize: 13, weight: .semibold)
        topPanel.addSubview(title)
        picker.removeAllItems()
        for (i, s) in screens.enumerated() { picker.addItem(withTitle: s.info.label); picker.lastItem?.tag = i }
        picker.selectItem(at: currentIndex)
        picker.target = self; picker.action = #selector(pickerChanged)
        picker.frame = NSRect(x: 132, y: 12, width: 300, height: 26)
        topPanel.addSubview(picker)

        // Top-center hint or blocked banner.
        let hint = NSTextField(labelWithString:
            canWrite ? "Hover a zone, then split it ▮▮ / ▬▬ or merge. Drag a divider to resize."
                     : (blockedMessage ?? "Editing is disabled."))
        hint.alignment = .center
        hint.textColor = canWrite ? .white : .systemOrange
        hint.font = .systemFont(ofSize: 13, weight: canWrite ? .regular : .semibold)
        let hp = panel(NSRect(x: screenSize.width / 2 - 320, y: screenSize.height - 70, width: 640, height: 40))
        hint.frame = NSRect(x: 12, y: 9, width: 616, height: 22)
        hp.addSubview(hint); container.addSubview(hp)

        // Inline save-failure banner (hidden). An NSAlert would render behind the
        // .screenSaver-level overlay, so failures must surface in-chrome.
        let err = panel(NSRect(x: screenSize.width / 2 - 300, y: 96, width: 600, height: 40))
        err.layer?.backgroundColor = NSColor.systemOrange.withAlphaComponent(0.92).cgColor // warning, never red
        let errLabel = NSTextField(labelWithString: "Couldn’t save — your changes are still here. Try Done again.")
        errLabel.frame = NSRect(x: 12, y: 9, width: 576, height: 22)
        errLabel.alignment = .center; errLabel.textColor = .white; errLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        err.addSubview(errLabel); err.isHidden = true
        container.addSubview(err)
        errorPanel = err

        // Bottom-right: Done + Cancel (Done disabled when blocked).
        let bottom = panel(NSRect(x: screenSize.width - 320, y: 28, width: 296, height: 56))
        container.addSubview(bottom)
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelTapped))
        cancel.keyEquivalent = "\u{1b}"; cancel.bezelStyle = .rounded
        cancel.frame = NSRect(x: 16, y: 14, width: 120, height: 28)
        bottom.addSubview(cancel)
        let done = NSButton(title: canWrite ? "Done" : "Reset…", target: self,
                            action: canWrite ? #selector(doneTapped) : #selector(resetTapped))
        done.keyEquivalent = "\r"; done.bezelStyle = .rounded
        done.frame = NSRect(x: 160, y: 14, width: 120, height: 28)
        bottom.addSubview(done)
    }

    private func panel(_ frame: NSRect) -> NSView {
        let v = NSView(frame: frame); v.wantsLayer = true
        v.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.55).cgColor
        v.layer?.cornerRadius = 12
        return v
    }

    @objc private func pickerChanged() {
        let idx = picker.selectedItem?.tag ?? currentIndex
        guard idx != currentIndex, screens.indices.contains(idx) else { return }
        openWindow(for: idx) // drafts persist per-screen in `drafts`
    }

    @objc private func doneTapped() {
        // Collect every screen whose draft differs, then save ATOMICALLY (one write).
        let changes: [(screen: ScreenInfo, layout: Node)] = screens.compactMap { (_, info) in
            guard let edited = drafts[info.key], edited != baseConfig.layout(forKey: info.key) else { return nil }
            return (info, edited)
        }
        if changes.isEmpty { close(); return }
        if commit(changes) {
            close()
        } else {
            // Save failed — keep the draft, stay open, surface it INLINE (an NSAlert would
            // hide behind the .screenSaver-level overlay).
            errorPanel?.isHidden = false
        }
    }

    @objc private func resetTapped() { close() } // blocked state: Reset lives on the menu

    @objc private func cancelTapped() { close() }

    private func close() {
        window?.orderOut(nil); window = nil; canvas = nil
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
    var editable = true

    private let screenFrame: CGRect
    private let visibleFrame: CGRect
    private let info: ScreenInfo

    private var activePath: [Int]?
    private var pinned = false
    private var dragging: Layout.DividerHandle?
    private var tracking: NSTrackingArea?

    private let splitVBtn = EditorCanvas.iconButton("rectangle.split.2x1", "Split side by side")
    private let splitHBtn = EditorCanvas.iconButton("rectangle.split.1x2", "Split stacked")
    private let mergeBtn = EditorCanvas.iconButton("arrow.down.right.and.arrow.up.left", "Merge")

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

    private static func iconButton(_ symbol: String, _ label: String) -> NSButton {
        let b = NSButton()
        b.bezelStyle = .regularSquare
        b.isBordered = true
        b.imagePosition = .imageOnly
        b.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        b.symbolConfiguration = .init(pointSize: 22, weight: .semibold)
        b.contentTintColor = Brand.blue
        b.toolTip = label
        b.wantsLayer = true
        b.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.92).cgColor
        b.layer?.cornerRadius = 10
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

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds, options: [.activeAlways, .mouseMoved, .mouseEnteredAndExited], owner: self)
        addTrackingArea(t); tracking = t
    }

    private func rebuildIfNeeded() { positionControls(); needsDisplay = true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.18).setFill(); bounds.fill()
        let lv = leaves()
        for (i, leaf) in lv.enumerated() {
            let r = viewRect(leaf.rect).insetBy(dx: 3, dy: 3)
            let isActive = leaf.path == activePath
            (isActive ? Brand.blue.withAlphaComponent(0.28) : Brand.blue.withAlphaComponent(0.12)).setFill()
            let p = NSBezierPath(roundedRect: r, xRadius: 10, yRadius: 10); p.fill()
            (isActive ? Brand.blue : Brand.blue.withAlphaComponent(0.5)).setStroke()
            p.lineWidth = isActive ? 3 : 1.5; p.stroke()
            drawNumber(i + 1, in: r)
        }
        if editable {
            for h in Layout.dividerHandles(root, container: container, pixelsWide: info.pixelsWide) {
                let r = viewRect(h.line)
                NSColor.white.withAlphaComponent(0.85).setFill()
                NSBezierPath(roundedRect: r.insetBy(dx: r.width > r.height ? 0 : 2, dy: r.width > r.height ? 2 : 0), xRadius: 2, yRadius: 2).fill()
                drawDividerReadout(h, viewLine: r)
            }
        }
    }

    /// Root vertical dividers show their physical pixel x (seam alignment); nested/horizontal
    /// dividers show a percent of their parent.
    private func drawDividerReadout(_ h: Layout.DividerHandle, viewLine: CGRect) {
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
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: NSColor.white]
        let s = NSAttributedString(string: text, attributes: attrs)
        let sz = s.size()
        let pad: CGFloat = 5
        let pillW = sz.width + pad * 2, pillH = sz.height + pad
        // vertical divider -> label near top; horizontal -> near left.
        let center = h.axis == .vertical
            ? CGPoint(x: viewLine.midX, y: viewLine.maxY - pillH / 2 - 10)
            : CGPoint(x: viewLine.minX + pillW / 2 + 10, y: viewLine.midY)
        let pill = CGRect(x: center.x - pillW / 2, y: center.y - pillH / 2, width: pillW, height: pillH)
        NSColor.black.withAlphaComponent(0.6).setFill()
        NSBezierPath(roundedRect: pill, xRadius: 5, yRadius: 5).fill()
        s.draw(at: NSPoint(x: pill.midX - sz.width / 2, y: pill.midY - sz.height / 2))
    }

    private func drawNumber(_ n: Int, in r: CGRect) {
        let s = NSAttributedString(string: "\(n)", attributes: [
            .font: NSFont.systemFont(ofSize: 22, weight: .bold),
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
        let size: CGFloat = 52, gap: CGFloat = 14
        let cx = vr.midX, cy = vr.midY
        splitVBtn.frame = NSRect(x: cx - size - gap / 2, y: cy - size / 2, width: size, height: size)
        splitHBtn.frame = NSRect(x: cx + gap / 2, y: cy - size / 2, width: size, height: size)
        let mergeEnabled = !path.isEmpty
        mergeBtn.isHidden = !mergeEnabled
        mergeBtn.frame = NSRect(x: cx - 22, y: cy - size / 2 - 40, width: 44, height: 30)
        mergeBtn.symbolConfiguration = .init(pointSize: 14, weight: .regular)
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
        // Divider drag first.
        for h in Layout.dividerHandles(root, container: container, pixelsWide: info.pixelsWide) {
            if viewRect(h.line).insetBy(dx: -4, dy: -4).contains(p) { dragging = h; return }
        }
        // Else pin the clicked zone (stable target for trackpad users).
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

    // Robust dismissal independent of button key-equivalent routing on a borderless overlay.
    override func cancelOperation(_ sender: Any?) { onCancel?() }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onCancel?() } else { super.keyDown(with: event) } // Esc
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

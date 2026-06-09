import AppKit
import ApplicationServices
import LineupCore

/// Hooks the Settings window needs from the app.
struct SettingsContext {
    var config: () -> LineupConfig
    var applyLayout: (Node, ScreenInfo) -> Void          // validate + persist per-screen
    var canWrite: () -> Bool                             // false when config writes are blocked
    var blockedMessage: () -> String?                    // why editing is disabled, if so
    var isDragSnapOn: () -> Bool
    var toggleDragSnap: () -> Void
    var isLaunchAtLoginOn: () -> Bool
    var toggleLaunchAtLogin: () -> Void
    var isTrusted: () -> Bool
    var requestAccessibility: () -> Void
}

/// The Settings window: a Layout tab (per-screen visual editor) and a General tab.
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private let window: NSWindow
    private let ctx: SettingsContext
    var onClose: (() -> Void)?

    init(context: SettingsContext) {
        self.ctx = context
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 520),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Lineup Settings"
        window.isReleasedWhenClosed = false
        super.init()
        window.delegate = self

        let tabs = NSTabView(frame: window.contentView!.bounds)
        tabs.autoresizingMask = [.width, .height]
        let layoutItem = NSTabViewItem(identifier: "layout")
        layoutItem.label = "Layout"
        layoutItem.view = LayoutEditorView(context: context)
        let generalItem = NSTabViewItem(identifier: "general")
        generalItem.label = "General"
        generalItem.view = GeneralView(context: context)
        tabs.addTabViewItem(layoutItem)
        tabs.addTabViewItem(generalItem)
        window.contentView?.addSubview(tabs)
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        window.center()
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) { onClose?() }
}

// MARK: - Layout editor tab

private final class LayoutEditorView: NSView {
    private let ctx: SettingsContext
    private let screenPicker = NSPopUpButton(frame: .zero, pullsDown: false)
    private let canvas: LayoutCanvasView
    private let hint = NSTextField(labelWithString: "")
    private var screens: [(screen: NSScreen, info: ScreenInfo)] = []
    private var splitColsBtn: NSButton!
    private var splitRowsBtn: NSButton!
    private var mergeBtn: NSButton!
    private var resetBtn: NSButton!
    private let defaultHint = "Click a zone to select it, then split or merge. Drag a divider to resize. Changes save automatically."

    init(context: SettingsContext) {
        self.ctx = context
        self.canvas = LayoutCanvasView()
        super.init(frame: NSRect(x: 0, y: 0, width: 640, height: 492))
        autoresizingMask = [.width, .height]
        buildUI()
        reloadScreens()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func buildUI() {
        let pickerLabel = NSTextField(labelWithString: "Display:")
        pickerLabel.frame = NSRect(x: 16, y: 452, width: 60, height: 22)
        addSubview(pickerLabel)
        screenPicker.frame = NSRect(x: 80, y: 450, width: 360, height: 26)
        screenPicker.target = self
        screenPicker.action = #selector(screenChanged)
        screenPicker.autoresizingMask = [.width]
        addSubview(screenPicker)

        canvas.frame = NSRect(x: 16, y: 92, width: 608, height: 344)
        canvas.autoresizingMask = [.width, .height]
        canvas.onSelect = { [weak self] _ in self?.updateButtons() }
        canvas.onChange = { [weak self] node in self?.apply(node) }
        addSubview(canvas)

        func makeButton(_ title: String, _ sel: Selector) -> NSButton {
            let b = NSButton(title: title, target: self, action: sel)
            b.bezelStyle = .rounded
            b.sizeToFit()
            b.frame.size.height = 28
            b.frame.size.width += 16
            addSubview(b)
            return b
        }
        splitColsBtn = makeButton("Split into Columns", #selector(splitCols))
        splitRowsBtn = makeButton("Split into Rows", #selector(splitRows))
        mergeBtn = makeButton("Merge", #selector(merge))
        resetBtn = makeButton("Reset to halves", #selector(resetHalves))
        var x: CGFloat = 16
        for b in [splitColsBtn!, splitRowsBtn!, mergeBtn!, resetBtn!] {
            b.frame.origin = CGPoint(x: x, y: 52)
            x += b.frame.width + 12
        }

        hint.frame = NSRect(x: 16, y: 16, width: 608, height: 28)
        hint.autoresizingMask = [.width]
        hint.textColor = .secondaryLabelColor
        hint.font = .systemFont(ofSize: 11)
        hint.stringValue = defaultHint
        addSubview(hint)
    }

    private func reloadScreens() {
        screens = NSScreen.screens.map { ($0, ScreenIdentity.info(for: $0)) }
        screenPicker.removeAllItems()
        for (i, s) in screens.enumerated() {
            let mark = s.info.keyIsStable ? "" : " (unrecognized)"
            screenPicker.addItem(withTitle: "\(s.info.label) — \(s.info.pixelsWide)×\(s.info.pixelsHigh)\(mark)")
            screenPicker.lastItem?.tag = i
        }
        // Default to the widest (the G9).
        if let widest = screens.enumerated().max(by: { $0.element.info.pixelsWide < $1.element.info.pixelsWide }) {
            screenPicker.selectItem(at: widest.offset)
        }
        screenChanged()
    }

    @objc private func screenChanged() {
        guard let sel = currentScreen() else { return }
        canvas.configure(root: ctx.config().layout(forKey: sel.info.key),
                         pixelsWide: sel.info.pixelsWide, aspect: sel.screen.frame.size)
        updateButtons()
    }

    private func currentScreen() -> (screen: NSScreen, info: ScreenInfo)? {
        let idx = screenPicker.selectedItem?.tag ?? 0
        return screens.indices.contains(idx) ? screens[idx] : screens.first
    }

    private func updateButtons() {
        let writable = ctx.canWrite()
        canvas.isEditable = writable
        splitColsBtn.isEnabled = writable && canvas.selectedIsLeaf
        splitRowsBtn.isEnabled = writable && canvas.selectedIsLeaf
        mergeBtn.isEnabled = writable && canvas.selectedCanMerge
        resetBtn.isEnabled = writable
        if writable {
            hint.stringValue = defaultHint
            hint.textColor = .secondaryLabelColor
        } else {
            hint.stringValue = ctx.blockedMessage() ?? "Editing is disabled."
            hint.textColor = .systemOrange
        }
    }

    private func apply(_ node: Node) {
        guard let sel = currentScreen() else { return }
        ctx.applyLayout(node, sel.info)
    }

    @objc private func splitCols() { canvas.splitSelected(axis: .vertical) }
    @objc private func splitRows() { canvas.splitSelected(axis: .horizontal) }
    @objc private func merge() { canvas.mergeSelected() }
    @objc private func resetHalves() { canvas.replaceRoot(.halves) }
}

// MARK: - Canvas (draw + select + drag)

private final class LayoutCanvasView: NSView {
    var onSelect: (([Int]?) -> Void)?
    var onChange: ((Node) -> Void)?
    var isEditable = true

    private var root: Node = .halves
    private var pixelsWide = 0
    private var aspect = CGSize(width: 16, height: 9)
    private var selectedPath: [Int]?
    private var dragging: Layout.DividerHandle?

    override var isFlipped: Bool { false }

    /// True only when a leaf zone is selected (so Split is valid).
    var selectedIsLeaf: Bool {
        guard let p = selectedPath, case .leaf = root.node(at: p) else { return false }
        return true
    }
    /// True when the selected leaf has a parent split that can be merged.
    var selectedCanMerge: Bool {
        guard let p = selectedPath, !p.isEmpty, case .leaf? = root.node(at: p) else { return false }
        return true
    }

    func configure(root: Node, pixelsWide: Int, aspect: CGSize) {
        self.root = root
        self.pixelsWide = pixelsWide
        self.aspect = aspect.width > 0 && aspect.height > 0 ? aspect : CGSize(width: 16, height: 9)
        self.selectedPath = nil
        onSelect?(nil)
        needsDisplay = true
    }

    func replaceRoot(_ node: Node) {
        guard isEditable else { return }
        root = node; clearSelection(); needsDisplay = true; onChange?(root)
    }

    func splitSelected(axis: Axis) {
        guard isEditable, let path = selectedPath, selectedIsLeaf else { return }
        let updated = LayoutEdit.split(root, at: path, axis: axis)
        if updated != root { root = updated; clearSelection(); needsDisplay = true; onChange?(root) }
    }

    func mergeSelected() {
        guard isEditable, let path = selectedPath, !path.isEmpty else { return }
        let updated = LayoutEdit.merge(root, at: path)
        if updated != root { root = updated; clearSelection(); needsDisplay = true; onChange?(root) }
    }

    private func clearSelection() { selectedPath = nil; onSelect?(nil) }

    // Virtual container (config coords) and its mapping into the view.
    private var virtualContainer: CGRect { CGRect(origin: .zero, size: aspect) }
    private func viewRect(for v: CGRect, scale: CGFloat, offset: CGPoint) -> CGRect {
        CGRect(x: offset.x + v.minX * scale, y: offset.y + v.minY * scale, width: v.width * scale, height: v.height * scale)
    }
    private func fit() -> (scale: CGFloat, offset: CGPoint) {
        let inset = bounds.insetBy(dx: 8, dy: 8)
        let s = min(inset.width / aspect.width, inset.height / aspect.height)
        let w = aspect.width * s, h = aspect.height * s
        return (s, CGPoint(x: inset.midX - w / 2, y: inset.midY - h / 2))
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill(); bounds.fill()
        let (scale, offset) = fit()
        let vc = virtualContainer

        let leaves = Layout.leaves(root, container: vc, pixelsWide: pixelsWide)
        for (i, leaf) in leaves.enumerated() {
            let r = viewRect(for: leaf.rect, scale: scale, offset: offset).insetBy(dx: 1, dy: 1)
            let isSel = leaf.path == selectedPath
            (isSel ? NSColor.controlAccentColor.withAlphaComponent(0.30) : NSColor.controlAccentColor.withAlphaComponent(0.10)).setFill()
            let p = NSBezierPath(roundedRect: r, xRadius: 6, yRadius: 6)
            p.fill()
            (isSel ? NSColor.controlAccentColor : NSColor.tertiaryLabelColor).setStroke()
            p.lineWidth = isSel ? 2.5 : 1
            p.stroke()
            drawLabel("\(i + 1)", in: r)
        }

        // Divider handles.
        for h in Layout.dividerHandles(root, container: vc, pixelsWide: pixelsWide) {
            let r = viewRect(for: h.line, scale: scale, offset: offset)
            NSColor.secondaryLabelColor.withAlphaComponent(0.6).setFill()
            NSBezierPath(roundedRect: r.insetBy(dx: r.width > r.height ? 0 : 1.5, dy: r.width > r.height ? 1.5 : 0), xRadius: 2, yRadius: 2).fill()
        }
    }

    private func drawLabel(_ s: String, in r: CGRect) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 17, weight: .semibold),
            .foregroundColor: NSColor.labelColor.withAlphaComponent(0.7),
        ]
        let str = NSAttributedString(string: s, attributes: attrs)
        let sz = str.size()
        str.draw(at: NSPoint(x: r.midX - sz.width / 2, y: r.midY - sz.height / 2))
    }

    // MARK: Interaction

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let (scale, offset) = fit()
        let vp = CGPoint(x: (p.x - offset.x) / scale, y: (p.y - offset.y) / scale)

        // Divider first (drag to resize) — only when editing is allowed.
        if isEditable {
            for h in Layout.dividerHandles(root, container: virtualContainer, pixelsWide: pixelsWide) {
                if viewRect(for: h.line, scale: scale, offset: offset).insetBy(dx: -3, dy: -3).contains(p) {
                    dragging = h
                    return
                }
            }
        }
        // Else select the leaf under the cursor.
        let leaves = Layout.leaves(root, container: virtualContainer, pixelsWide: pixelsWide)
        selectedPath = leaves.first(where: { $0.rect.contains(vp) })?.path
        onSelect?(selectedPath)
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let h = dragging else { return }
        let p = convert(event.locationInWindow, from: nil)
        let (scale, offset) = fit()
        let vp = CGPoint(x: (p.x - offset.x) / scale, y: (p.y - offset.y) / scale)
        let frac: Double
        if h.axis == .vertical {
            frac = Double((vp.x - h.container.minX) / max(h.container.width, 1))
        } else {
            // top-to-bottom: fraction measured from the top (container.maxY) downward
            frac = Double((h.container.maxY - vp.y) / max(h.container.height, 1))
        }
        let updated = LayoutEdit.setDivider(root, at: h.path, index: h.index, fraction: frac, rootPixelsWide: pixelsWide)
        if updated != root { root = updated; needsDisplay = true }
    }

    override func mouseUp(with event: NSEvent) {
        if dragging != nil { dragging = nil; onChange?(root) }
    }
}

// MARK: - General tab

private final class GeneralView: NSView {
    private let ctx: SettingsContext
    init(context: SettingsContext) {
        self.ctx = context
        super.init(frame: NSRect(x: 0, y: 0, width: 640, height: 492))
        autoresizingMask = [.width, .height]
        build()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func build() {
        var y: CGFloat = 430
        let ax = NSTextField(labelWithString: ctx.isTrusted() ? "Accessibility: granted" : "Accessibility: NOT granted")
        ax.frame = NSRect(x: 24, y: y, width: 400, height: 22); addSubview(ax)
        if !ctx.isTrusted() {
            let b = NSButton(title: "Request Accessibility permission…", target: self, action: #selector(reqAX))
            b.bezelStyle = .rounded; b.sizeToFit(); b.frame = NSRect(x: 360, y: y - 3, width: b.frame.width + 16, height: 26)
            addSubview(b)
        }
        y -= 44
        addCheck("Shift-drag to snap", y: y, on: ctx.isDragSnapOn(), action: #selector(toggleDrag))
        y -= 32
        addCheck("Launch at login", y: y, on: ctx.isLaunchAtLoginOn(), action: #selector(toggleLogin))
    }

    private func addCheck(_ title: String, y: CGFloat, on: Bool, action: Selector) {
        let c = NSButton(checkboxWithTitle: title, target: self, action: action)
        c.state = on ? .on : .off
        c.frame = NSRect(x: 24, y: y, width: 400, height: 22)
        addSubview(c)
    }

    @objc private func reqAX() { ctx.requestAccessibility() }
    @objc private func toggleDrag() { ctx.toggleDragSnap() }
    @objc private func toggleLogin() { ctx.toggleLaunchAtLogin() }
}

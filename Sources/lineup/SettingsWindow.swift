import AppKit
import ApplicationServices
import LineupCore

/// Hooks the Settings window needs from the app.
struct SettingsContext {
    var config: () -> LineupConfig
    var canWrite: () -> Bool                             // false when config writes are blocked
    var blockedMessage: () -> String?                    // why editing is disabled, if so
    var shortcuts: () -> Shortcuts                       // effective shortcut set
    var setShortcuts: (Shortcuts) -> Void                // persist + re-register hotkeys
    var setRecording: (Bool) -> Void                     // suspend global hotkeys while capturing a combo
    var isDragSnapOn: () -> Bool
    var toggleDragSnap: () -> Void
    var isLaunchAtLoginOn: () -> Bool
    var toggleLaunchAtLogin: () -> Void
    var isTrusted: () -> Bool
    var requestAccessibility: () -> Void
}

/// The Settings window: a Shortcuts tab and a General tab. (Layout editing lives in the
/// on-screen overlay, opened from the menu's Edit Layout… — not here.)
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private let window: NSWindow
    private let ctx: SettingsContext
    private let generalView: GeneralView
    var onClose: (() -> Void)?

    init(context: SettingsContext) {
        self.ctx = context
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 520),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Lineup Settings"
        window.isReleasedWhenClosed = false
        self.generalView = GeneralView(context: context)
        super.init()
        window.delegate = self

        let tabs = NSTabView(frame: window.contentView!.bounds)
        tabs.autoresizingMask = [.width, .height]
        let shortcutsItem = NSTabViewItem(identifier: "shortcuts")
        shortcutsItem.label = "Shortcuts"
        shortcutsItem.view = ShortcutsView(context: context)
        let generalItem = NSTabViewItem(identifier: "general")
        generalItem.label = "General"
        generalItem.view = generalView
        tabs.addTabViewItem(shortcutsItem)
        tabs.addTabViewItem(generalItem)
        let aboutItem = NSTabViewItem(identifier: "about")
        aboutItem.label = "About"
        aboutItem.view = AboutTabView()
        tabs.addTabViewItem(aboutItem)
        window.contentView?.addSubview(tabs)
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        window.center()
        window.makeKeyAndOrderFront(nil)
    }

    /// Called when the app detects Accessibility was granted/revoked while Settings is open.
    func refreshAccessibility() { generalView.refresh() }

    func windowWillClose(_ notification: Notification) { onClose?() }
}


// MARK: - A click-to-record shortcut field

/// Looks like a rounded text field but is the record trigger: click it to start capturing a
/// combo (people reach for the field, not a separate "Record" button). Highlights blue while
/// recording.
private final class RecorderField: NSView {
    var onClick: () -> Void = {}
    var isRecording = false { didSet { needsDisplay = true } }
    var text = "" { didSet { needsDisplay = true } }      // the combo, or "" when unassigned
    var enabled = true { didSet { needsDisplay = true } }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 1, dy: 1)
        let path = NSBezierPath(roundedRect: r, xRadius: 7, yRadius: 7)
        (isRecording ? Brand.blue.withAlphaComponent(0.12) : NSColor.textBackgroundColor).setFill()
        path.fill()
        (isRecording ? Brand.blue : NSColor.separatorColor).setStroke()
        path.lineWidth = isRecording ? 2 : 1
        path.stroke()

        let str: String, color: NSColor, weight: NSFont.Weight
        if isRecording { str = "Press keys…"; color = Brand.blue; weight = .regular }
        else if text.isEmpty { str = "Click to set a shortcut"; color = .secondaryLabelColor; weight = .regular }
        else { str = text; color = enabled ? .labelColor : .disabledControlTextColor; weight = .medium }
        let s = NSAttributedString(string: str, attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: weight), .foregroundColor: color])
        let sz = s.size()
        s.draw(at: NSPoint(x: r.midX - sz.width / 2, y: r.midY - sz.height / 2))
    }

    override func mouseDown(with event: NSEvent) { if enabled { onClick() } }
    override func resetCursorRects() { if enabled { addCursorRect(bounds, cursor: .pointingHand) } }
}


// MARK: - Shortcuts tab (key recorder)

private final class ShortcutsView: NSView {
    private let ctx: SettingsContext
    private var rows: [(action: String, field: RecorderField, clear: NSButton)] = []
    private let header = NSTextField(labelWithString:
        "Click a shortcut, then press a key combo (must include a modifier). Esc cancels, Delete clears.")
    private let banner = NSTextField(labelWithString: "")
    private var recordingAction: String?
    private var monitor: Any?

    init(context: SettingsContext) {
        self.ctx = context
        super.init(frame: NSRect(x: 0, y: 0, width: 640, height: 492))
        autoresizingMask = [.width, .height]
        build()
        refresh()
    }
    required init?(coder: NSCoder) { fatalError() }

    deinit {
        if let m = monitor { NSEvent.removeMonitor(m) }
        NotificationCenter.default.removeObserver(self)
    }

    // Stop recording when the window loses key/closes (the local monitor only fires while key,
    // so a stuck "Press…" state would otherwise linger and hotkeys would stay suspended).
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self)
        guard let w = window else { return }
        for name in [NSWindow.didResignKeyNotification, NSWindow.willCloseNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(windowLeft), name: name, object: w)
        }
        refresh()
    }
    @objc private func windowLeft() { stopRecording() }

    private func build() {
        header.frame = NSRect(x: 20, y: 462, width: 600, height: 20)
        header.font = .systemFont(ofSize: 11); header.textColor = .secondaryLabelColor
        header.lineBreakMode = .byTruncatingTail
        header.autoresizingMask = [.width, .minYMargin]
        addSubview(header)

        banner.frame = header.frame
        banner.font = .systemFont(ofSize: 11); banner.textColor = .systemOrange
        banner.autoresizingMask = [.width, .minYMargin]; banner.isHidden = true
        addSubview(banner)

        let scroll = NSScrollView(frame: NSRect(x: 12, y: 12, width: 616, height: 442))
        scroll.autoresizingMask = [.width, .height]
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false

        var actions: [(id: String, label: String)] = ShortcutKit.quickActions
        for i in 1...ShortcutKit.zoneRows { actions.append((ZoneAction.id(i), "Zone \(i)")) }

        let rowH: CGFloat = 40
        let doc = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: CGFloat(actions.count) * rowH))
        for (i, a) in actions.enumerated() {
            let y = doc.frame.height - CGFloat(i + 1) * rowH + 6
            let label = NSTextField(labelWithString: a.label)
            label.frame = NSRect(x: 12, y: y + 5, width: 140, height: 20)
            doc.addSubview(label)

            let field = RecorderField(frame: NSRect(x: 160, y: y, width: 322, height: 30))
            let action = a.id
            field.onClick = { [weak self] in self?.fieldClicked(action) }
            doc.addSubview(field)

            let clear = NSButton(title: "✕", target: self, action: #selector(clearTapped(_:)))
            clear.bezelStyle = .circular; clear.frame = NSRect(x: 496, y: y + 1, width: 28, height: 28)
            clear.tag = i; clear.toolTip = "Clear this shortcut"
            doc.addSubview(clear)

            rows.append((a.id, field, clear))
        }
        scroll.documentView = doc
        doc.scroll(NSPoint(x: 0, y: doc.frame.height)) // start at top
        addSubview(scroll)
    }

    private func refresh() {
        let sc = ctx.shortcuts()
        let writable = ctx.canWrite()
        for row in rows {
            let bound = sc.binding(for: row.action)
            row.field.text = bound.map { ShortcutKit.display(keyCode: $0.keyCode, modifiers: $0.modifiers) } ?? ""
            row.field.isRecording = (row.action == recordingAction)
            row.field.enabled = writable
            row.clear.isEnabled = writable && bound != nil
        }
        if writable {
            banner.isHidden = true
            header.isHidden = false
        } else {
            banner.isHidden = false
            header.isHidden = true // banner shares the frame; don't overlap
            banner.stringValue = ctx.blockedMessage() ?? "Editing is disabled."
        }
    }

    private func fieldClicked(_ action: String) {
        guard ctx.canWrite() else { return }
        if recordingAction == action { stopRecording(); return }
        startRecording(action)
    }

    @objc private func clearTapped(_ sender: NSButton) {
        guard ctx.canWrite() else { return }
        let action = rows[sender.tag].action
        // End ANY in-flight recording (not just this row's): setShortcuts re-registers the
        // global hotkeys, which would silently re-arm them while another row still shows
        // "Press keys…" — the next combo would fire a window move instead of recording.
        if recordingAction != nil { stopRecording() }
        ctx.setShortcuts(ctx.shortcuts().removing(action: action))
        refresh()
    }

    private func startRecording(_ action: String) {
        guard ctx.canWrite() else { return }
        if recordingAction != nil { stopRecording() } // only one row records at a time
        recordingAction = action
        ctx.setRecording(true) // suspend global hotkeys so the combo reaches us (and doesn't move a window)
        if monitor == nil {
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
                self?.handle(event) == true ? nil : event
            }
        }
        refresh()
        window?.makeFirstResponder(self)
    }

    private func stopRecording() {
        let wasRecording = recordingAction != nil
        recordingAction = nil
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
        if wasRecording { ctx.setRecording(false) } // restore global hotkeys
        refresh()
    }

    /// Returns true if the event was consumed by the recorder.
    private func handle(_ event: NSEvent) -> Bool {
        guard let action = recordingAction else { return false }
        guard ctx.canWrite() else { stopRecording(); return true }
        let keyCode = Int(event.keyCode)
        // Bare Esc cancels and bare Delete clears — but ONLY bare: with modifiers held
        // they're recordable combos like any other (Hyper+Delete is the Restore default).
        let bare = !ShortcutKit.hasModifier(event.modifierFlags)
        if keyCode == 53, bare { stopRecording(); return true }       // Esc cancels
        if keyCode == 51, bare {                                      // Delete clears
            ctx.setShortcuts(ctx.shortcuts().removing(action: action)); stopRecording(); return true
        }
        guard ShortcutKit.hasModifier(event.modifierFlags) else { NSSound.beep(); return true } // need a modifier
        let mods = ShortcutKit.carbonModifiers(from: event.modifierFlags)

        // Stop recording (remove the monitor, restore hotkeys) BEFORE any modal alert, so the
        // alert's own Return/Esc keys aren't swallowed by the recorder.
        stopRecording()

        let existing = ctx.shortcuts()
        let conflicts = existing.conflicts(keyCode: keyCode, modifiers: mods, excluding: action)
        if !conflicts.isEmpty, !confirmConflict(conflicts) { return true }

        // Take the combo; clear it from any conflicting action so there's no duplicate.
        var updated = existing
        for c in conflicts { updated = updated.removing(action: c) }
        updated = updated.setting(action: action, keyCode: keyCode, modifiers: mods)
        ctx.setShortcuts(updated)
        refresh()
        return true
    }

    private func confirmConflict(_ conflicts: [String]) -> Bool {
        // Show the labels users see in the list, never raw action ids like "leftHalf".
        let names = conflicts.map { id in
            ShortcutKit.quickActions.first(where: { $0.id == id })?.label
                ?? ZoneAction.zeroBasedIndex(from: id).map { "Zone \($0 + 1)" }
                ?? id
        }
        let alert = NSAlert()
        alert.messageText = "Shortcut already in use"
        alert.informativeText = "This combo is assigned to: \(names.joined(separator: ", ")). Reassign it here? The other action becomes unassigned."
        alert.addButton(withTitle: "Reassign")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }
}

// MARK: - About tab

/// Hosts the shared About content (icon, version, links, license) plus the update check —
/// the same panel as the menu's About window, embedded per the Settings convention.
private final class AboutTabView: NSView {
    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 640, height: 492))
        autoresizingMask = [.width, .height]
        // The About content has a fixed internal layout designed at 420×430 — embed it at its
        // natural size, pinned to the top, with the update button in the strip below it.
        let aboutSize = NSSize(width: 420, height: 430)
        let about = AboutWindowController.makeEmbeddedContent(size: aboutSize)
        about.frame = NSRect(x: (640 - aboutSize.width) / 2, y: 492 - aboutSize.height,
                             width: aboutSize.width, height: aboutSize.height)
        about.autoresizingMask = [.minXMargin, .maxXMargin, .minYMargin]
        addSubview(about)

        let update = NSButton(title: "Check for Updates…", target: self, action: #selector(checkUpdates))
        update.bezelStyle = .rounded
        update.sizeToFit()
        update.frame = NSRect(x: (640 - update.frame.width - 24) / 2, y: 12,
                              width: update.frame.width + 24, height: 30)
        update.autoresizingMask = [.minXMargin, .maxXMargin, .maxYMargin]
        addSubview(update)
    }
    required init?(coder: NSCoder) { fatalError() }

    @objc private func checkUpdates() { UpdateChecker.checkInteractively() }
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

    /// Rebuild (e.g. after Accessibility is granted while this is open).
    func refresh() {
        subviews.forEach { $0.removeFromSuperview() }
        build()
    }

    private func build() {
        var y: CGFloat = 440
        let granted = ctx.isTrusted()
        let ax = NSTextField(labelWithString: granted ? "Accessibility: granted" : "Accessibility: not granted")
        ax.frame = NSRect(x: 24, y: y, width: 580, height: 22)
        ax.textColor = granted ? .secondaryLabelColor : .systemOrange
        addSubview(ax)
        if !granted {
            y -= 32 // button on its own line below the label (no overlap)
            let b = NSButton(title: "Open Accessibility settings…", target: self, action: #selector(reqAX))
            b.bezelStyle = .rounded; b.sizeToFit()
            b.frame = NSRect(x: 24, y: y, width: b.frame.width + 24, height: 28)
            addSubview(b)
        }
        y -= 46
        addCheck("Shift-drag to snap", y: y, on: ctx.isDragSnapOn(), action: #selector(toggleDrag))
        y -= 34
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

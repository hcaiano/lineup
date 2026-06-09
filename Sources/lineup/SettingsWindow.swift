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
        // Layout editing lives in the on-screen "Edit Layout…" overlay, not here.
        let shortcutsItem = NSTabViewItem(identifier: "shortcuts")
        shortcutsItem.label = "Shortcuts"
        shortcutsItem.view = ShortcutsView(context: context)
        let generalItem = NSTabViewItem(identifier: "general")
        generalItem.label = "General"
        generalItem.view = GeneralView(context: context)
        tabs.addTabViewItem(shortcutsItem)
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


// MARK: - Shortcuts tab (key recorder)

private final class ShortcutsView: NSView {
    private let ctx: SettingsContext
    private var rows: [(action: String, field: NSTextField, record: NSButton, clear: NSButton)] = []
    private let banner = NSTextField(labelWithString: "")
    private let header = NSTextField(labelWithString: "Click Record, then press a key combo (must include a modifier). Esc cancels, Delete clears.")
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

    // Stop recording when the window loses key/closes (the local monitor only fires while
    // key, so a stuck "Press…" state would otherwise linger).
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
        header.frame = NSRect(x: 16, y: 460, width: 608, height: 20)
        header.font = .systemFont(ofSize: 11); header.textColor = .secondaryLabelColor
        header.autoresizingMask = [.width]
        addSubview(header)

        banner.frame = NSRect(x: 16, y: 460, width: 608, height: 20)
        banner.font = .systemFont(ofSize: 11); banner.textColor = .systemOrange
        banner.autoresizingMask = [.width]; banner.isHidden = true
        addSubview(banner)

        let scroll = NSScrollView(frame: NSRect(x: 12, y: 12, width: 616, height: 440))
        scroll.autoresizingMask = [.width, .height]
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false

        var actions: [(id: String, label: String)] = ShortcutKit.quickActions
        for i in 1...ShortcutKit.zoneRows { actions.append((ZoneAction.id(i), "Zone \(i)")) }

        let rowH: CGFloat = 34
        let doc = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: CGFloat(actions.count) * rowH))
        for (i, a) in actions.enumerated() {
            let y = doc.frame.height - CGFloat(i + 1) * rowH + 4
            let label = NSTextField(labelWithString: a.label)
            label.frame = NSRect(x: 8, y: y + 4, width: 150, height: 20)
            doc.addSubview(label)

            let field = NSTextField(frame: NSRect(x: 170, y: y + 2, width: 200, height: 24))
            field.isEditable = false; field.alignment = .center; field.placeholderString = "Unassigned"
            doc.addSubview(field)

            let record = NSButton(title: "Record", target: self, action: #selector(recordTapped(_:)))
            record.bezelStyle = .rounded; record.frame = NSRect(x: 382, y: y, width: 90, height: 28)
            record.tag = i
            doc.addSubview(record)

            let clear = NSButton(title: "Clear", target: self, action: #selector(clearTapped(_:)))
            clear.bezelStyle = .rounded; clear.frame = NSRect(x: 478, y: y, width: 70, height: 28)
            clear.tag = i
            doc.addSubview(clear)

            rows.append((a.id, field, record, clear))
        }
        scroll.documentView = doc
        doc.scroll(NSPoint(x: 0, y: doc.frame.height)) // start at top
        addSubview(scroll)
    }

    private func refresh() {
        let sc = ctx.shortcuts()
        let writable = ctx.canWrite()
        for row in rows {
            if let b = sc.binding(for: row.action) {
                row.field.stringValue = ShortcutKit.display(keyCode: b.keyCode, modifiers: b.modifiers)
            } else {
                row.field.stringValue = ""
            }
            row.record.title = (row.action == recordingAction) ? "Press…" : "Record"
            row.record.isEnabled = writable
            row.clear.isEnabled = writable
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

    @objc private func recordTapped(_ sender: NSButton) {
        guard ctx.canWrite() else { return }
        let action = rows[sender.tag].action
        if recordingAction == action { stopRecording(); return }
        startRecording(action)
    }

    @objc private func clearTapped(_ sender: NSButton) {
        guard ctx.canWrite() else { return }
        let action = rows[sender.tag].action
        ctx.setShortcuts(ctx.shortcuts().removing(action: action))
        refresh()
    }

    private func startRecording(_ action: String) {
        guard ctx.canWrite() else { return }
        recordingAction = action
        refresh()
        if monitor == nil {
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
                self?.handle(event) == true ? nil : event
            }
        }
    }

    private func stopRecording() {
        recordingAction = nil
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
        refresh()
    }

    /// Returns true if the event was consumed by the recorder.
    private func handle(_ event: NSEvent) -> Bool {
        guard let action = recordingAction else { return false }
        guard ctx.canWrite() else { stopRecording(); return true }
        let keyCode = Int(event.keyCode)
        if keyCode == 53 { stopRecording(); return true }            // Esc cancels
        if keyCode == 51 {                                            // Delete clears
            ctx.setShortcuts(ctx.shortcuts().removing(action: action)); stopRecording(); return true
        }
        guard ShortcutKit.hasModifier(event.modifierFlags) else { NSSound.beep(); return true } // need a modifier
        let mods = ShortcutKit.carbonModifiers(from: event.modifierFlags)

        // Stop recording (remove the local monitor) BEFORE any modal alert, so the alert's
        // own Return/Esc keys aren't swallowed by the recorder.
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
        let alert = NSAlert()
        alert.messageText = "Shortcut already in use"
        alert.informativeText = "This combo is assigned to: \(conflicts.joined(separator: ", ")). Reassign it here? The other action becomes unassigned."
        alert.addButton(withTitle: "Reassign")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
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

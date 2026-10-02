import AppKit

struct TextCaptureDisplay: Equatable {
    let id: CGDirectDisplayID
    let frame: CGRect
    let scale: CGFloat

    @MainActor static func current() -> [TextCaptureDisplay] {
        NSScreen.screens.compactMap { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
            else { return nil }
            return TextCaptureDisplay(id: number.uint32Value, frame: screen.frame,
                                      scale: screen.backingScaleFactor)
        }.sorted { $0.id < $1.id }
    }
}

@MainActor
final class TextCaptureOverlay {
    private var windows: [TextCaptureSelectionWindow] = []
    private var keyMonitor: Any?

    var windowIDs: Set<CGWindowID> { Set(windows.map { CGWindowID($0.windowNumber) }) }

    func show(displays: [TextCaptureDisplay], select: @escaping (TextCaptureDisplay, CGRect) -> Void,
              cancel: @escaping () -> Void) {
        for display in displays {
            // Without screen:, contentRect is global; passing both would double the origin.
            let window = TextCaptureSelectionWindow(contentRect: display.frame, styleMask: [.borderless, .nonactivatingPanel],
                                                    backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.hidesOnDeactivate = false
            window.isOpaque = false
            window.backgroundColor = .clear
            window.level = .screenSaver
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            window.acceptsMouseMovedEvents = true
            let canvas = TextCaptureCanvas(frame: CGRect(origin: .zero, size: display.frame.size))
            canvas.onSelection = { rect in
                select(display, rect.offsetBy(dx: display.frame.minX, dy: display.frame.minY))
            }
            window.contentView = canvas
            windows.append(window)
            window.orderFrontRegardless()
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 { cancel() }
            return nil
        }
        let target = windows.first { $0.frame.contains(NSEvent.mouseLocation) } ?? windows.first
        target?.makeKeyAndOrderFront(nil)
        target?.makeFirstResponder(target?.contentView)
    }

    func close() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        for window in windows { window.close() }
        windows.removeAll()

    }
}

private final class TextCaptureSelectionWindow: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

private final class TextCaptureCanvas: NSView {
    var onSelection: ((CGRect) -> Void)?
    private var start: CGPoint?
    private var selection = CGRect.zero

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Text Capture. Drag to select text. Press Escape to cancel.")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }

    override func mouseDown(with event: NSEvent) {
        window?.makeKey()
        start = convert(event.locationInWindow, from: nil)
        selection = .zero
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start else { return }
        let end = convert(event.locationInWindow, from: nil)
        selection = CGRect(x: min(start.x, end.x), y: min(start.y, end.y),
                           width: abs(start.x - end.x), height: abs(start.y - end.y)).intersection(bounds)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard start != nil else { return }
        mouseDragged(with: event)
        start = nil
        // A click is not a capture; leave the selection open for another drag.
        if selection.width >= 2, selection.height >= 2 { onSelection?(selection) }
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.22).setFill()
        let shade = NSBezierPath(rect: bounds)
        shade.appendRect(selection)
        shade.windingRule = .evenOdd
        shade.fill()
        if !selection.isEmpty {
            NSColor.white.setStroke()
            let outline = NSBezierPath(rect: selection)
            outline.lineWidth = 4
            outline.stroke()
            Brand.blue.setStroke()
            outline.lineWidth = 2
            outline.stroke()
        }
        let hint = "Drag to select text · Esc to cancel" as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 15, weight: .medium), .foregroundColor: NSColor.white,
        ]
        let size = hint.size(withAttributes: attributes)
        let rect = CGRect(x: (bounds.width - size.width) / 2, y: bounds.height - 64,
                          width: size.width, height: size.height)
        NSColor.black.withAlphaComponent(0.8).setFill()
        NSBezierPath(roundedRect: rect.insetBy(dx: -16, dy: -10), xRadius: 10, yRadius: 10).fill()
        hint.draw(in: rect, withAttributes: attributes)
    }
}

@MainActor
final class TextCaptureNotice {
    private var panel: NSPanel?
    private var dismissal: Task<Void, Never>?

    /// A brief confirmation or problem near the bottom of the active display. The glyph says
    /// which it is, so colour is never the only signal.
    func show(_ message: String, success: Bool = false) {
        hide()
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) })
                ?? NSScreen.main else { return }
        // Sized to the message: a fixed box cut off the last line of longer failures and left
        // one-line confirmations sitting at its top.
        let width: CGFloat = 420, textX: CGFloat = 46
        let label = NSTextField(wrappingLabelWithString: message)
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = .white
        label.preferredMaxLayoutWidth = width - textX - 18
        let textHeight = ceil(label.fittingSize.height)
        let height = max(44, textHeight + 24)
        label.frame = CGRect(x: textX, y: (height - textHeight) / 2, width: width - textX - 18, height: textHeight)
        let panel = NSPanel(contentRect: CGRect(x: screen.visibleFrame.midX - width / 2,
                                               y: screen.visibleFrame.minY + 70, width: width, height: height),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.ignoresMouseEvents = true
        let background = HUDGlass.container(frame: CGRect(x: 0, y: 0, width: width, height: height),
                                            cornerRadius: min(height / 2, 16))
        let icon = NSImageView(frame: CGRect(x: 16, y: (height - 20) / 2, width: 20, height: 20))
        icon.image = NSImage(systemSymbolName: success ? "checkmark.circle.fill" : "exclamationmark.triangle.fill",
                             accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 16, weight: .semibold))
        icon.contentTintColor = success ? .systemGreen : .systemOrange
        background.addSubview(icon)
        background.addSubview(label)
        panel.contentView = background
        self.panel = panel
        panel.orderFrontRegardless()
        NSAccessibility.post(element: panel, notification: .announcementRequested, userInfo: [
            .announcement: message, .priority: NSAccessibilityPriorityLevel.high.rawValue,
        ])
        dismissal = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 4_000_000_000) } catch { return }
            self?.hide()
        }
    }

    #if DEBUG
    /// The visible notice, for the isolated design review's capture.
    var reviewView: NSView? { panel?.contentView }
    #endif

    func hide() {
        dismissal?.cancel()
        dismissal = nil
        panel?.orderOut(nil)
        panel = nil
    }
}

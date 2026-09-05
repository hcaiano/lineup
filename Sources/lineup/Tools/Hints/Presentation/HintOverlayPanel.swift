import AppKit

/// A full-display nonactivating panel. It may become key only for the externally supplied Hints
/// input responder; it never becomes main, activates Lineup, or participates in pointer handling.
@MainActor
final class HintOverlayPanel: NSPanel {
    init(frame: NSRect, canvas: HintCanvasView) {
        // As in LayoutEditorOverlay, this rect is already in global AppKit coordinates. Passing an
        // NSScreen to the initializer would apply a secondary display's origin a second time.
        super.init(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .stationary]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        ignoresMouseEvents = true
        acceptsMouseMovedEvents = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isMovable = false
        isMovableByWindowBackground = false
        animationBehavior = .none
        isRestorable = false
        isExcludedFromWindowsMenu = true
        tabbingMode = .disallowed
        becomesKeyOnlyIfNeeded = false
        contentView = canvas

        setAccessibilityElement(false)
        setAccessibilityChildren([])
        canvas.setAccessibilityElement(false)
        canvas.setAccessibilityChildren([])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

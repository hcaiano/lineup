import AppKit
import ApplicationServices
import LineupCore

/// Moves/resizes the frontmost window of the frontmost app via the Accessibility API.
/// All public input is Cocoa-space; the single AX coordinate flip happens here.
enum WindowMover {

    /// Snap the focused window into `zoneID` on the screen it currently occupies.
    /// Returns false (silently) if there's no focused window or AX isn't trusted.
    @discardableResult
    static func snapFocusedWindow(to zoneID: String, config: ColumnConfig) -> Bool {
        guard AXIsProcessTrusted() else { return false }
        guard let window = focusedWindow() else { return false }

        // Current window frame in Cocoa space, to decide which screen it's on.
        guard let currentCocoa = currentCocoaFrame(of: window) else { return false }
        guard let screen = screen(for: currentCocoa) else { return false }

        let pixelsWide = pixelsWide(of: screen)
        guard let target = config.rect(
            for: zoneID,
            frame: screen.frame,
            visibleFrame: screen.visibleFrame,
            pixelsWide: pixelsWide) else { return false }

        setFrame(target, of: window)
        return true
    }

    // MARK: - AX element access

    private static func focusedWindow() -> AXUIElement? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        // Never target our own UI (e.g. the alignment overlay while it's frontmost).
        if app.bundleIdentifier == Bundle.main.bundleIdentifier { return nil }
        let appEl = AXUIElementCreateApplication(app.processIdentifier)
        var winRef: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(appEl, kAXFocusedWindowAttribute as CFString, &winRef)
        guard err == .success, let win = winRef else { return nil }
        // Force-cast: AX focused-window attribute is always an AXUIElement.
        return (win as! AXUIElement)
    }

    /// Read the window's AX frame and convert to Cocoa space.
    private static func currentCocoaFrame(of window: AXUIElement) -> CGRect? {
        guard let pos = axPoint(window, kAXPositionAttribute),
              let size = axSize(window, kAXSizeAttribute)
        else { return nil }
        let axRect = CGRect(origin: pos, size: size)
        return Coord.cocoaRect(fromAX: axRect, primaryMaxY: primaryMaxY())
    }

    /// Apply a Cocoa-space rect to the window. Order size -> position -> size makes
    /// cross-display moves and apps that clamp size-before-position behave (Rectangle).
    private static func setFrame(_ cocoa: CGRect, of window: AXUIElement) {
        let ax = Coord.axRect(fromCocoa: cocoa, primaryMaxY: primaryMaxY())
        setSize(window, kAXSizeAttribute, ax.size)
        setPoint(window, kAXPositionAttribute, ax.origin)
        setSize(window, kAXSizeAttribute, ax.size)
    }

    // MARK: - Screen helpers

    private static func primaryMaxY() -> CGFloat {
        // NSScreen.screens[0] is always the primary (menu-bar) display.
        NSScreen.screens.first?.frame.maxY ?? 0
    }

    private static func screen(for cocoaWindow: CGRect) -> NSScreen? {
        let screens = NSScreen.screens
        let frames = screens.map { $0.frame }
        guard let idx = ScreenPicker.bestScreenIndex(forWindow: cocoaWindow, screens: frames) else {
            return screens.first
        }
        return screens[idx]
    }

    static func pixelsWide(of screen: NSScreen) -> Int {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        guard let num = screen.deviceDescription[key] as? NSNumber else {
            return Int(screen.frame.width) // fallback: assume 1:1 (non-retina)
        }
        let displayID = CGDirectDisplayID(num.uint32Value)
        let px = CGDisplayPixelsWide(displayID)
        return px > 0 ? px : Int(screen.frame.width)
    }

    // MARK: - AXValue glue (concrete value types — no generics, so the compiler can
    // prove there's no object reference under the raw pointer).

    private static func axPoint(_ el: AXUIElement, _ attr: String) -> CGPoint? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &ref) == .success,
              let value = ref else { return nil }
        var point = CGPoint.zero
        guard AXValueGetValue(value as! AXValue, .cgPoint, &point) else { return nil }
        return point
    }

    private static func axSize(_ el: AXUIElement, _ attr: String) -> CGSize? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &ref) == .success,
              let value = ref else { return nil }
        var size = CGSize.zero
        guard AXValueGetValue(value as! AXValue, .cgSize, &size) else { return nil }
        return size
    }

    private static func setPoint(_ el: AXUIElement, _ attr: String, _ point: CGPoint) {
        var p = point
        guard let axv = AXValueCreate(.cgPoint, &p) else { return }
        AXUIElementSetAttributeValue(el, attr as CFString, axv)
    }

    private static func setSize(_ el: AXUIElement, _ attr: String, _ size: CGSize) {
        var s = size
        guard let axv = AXValueCreate(.cgSize, &s) else { return }
        AXUIElementSetAttributeValue(el, attr as CFString, axv)
    }
}

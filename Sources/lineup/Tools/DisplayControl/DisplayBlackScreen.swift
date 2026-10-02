import AppKit
import CoreGraphics

/// Owned windows make the image black without changing gamma, display power or arrangement.
/// WindowServer removes them if the process exits, including a crash or Force Quit.
@MainActor
final class DisplayBlackScreen {
    private var panels: [CGDirectDisplayID: BlackScreenPanel] = [:]

    /// Returns only displays with a window actually covering their current full screen frame.
    @discardableResult
    func apply(displayIDs: Set<CGDirectDisplayID>) -> Set<CGDirectDisplayID> {
        let screens = NSScreen.screens.reduce(into: [CGDirectDisplayID: NSScreen]()) { result, screen in
            if let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value {
                result[id] = screen
            }
        }
        for id in Array(panels.keys) where !displayIDs.contains(id) || screens[id] == nil {
            panels.removeValue(forKey: id)?.close()
        }
        for id in displayIDs {
            guard let screen = screens[id], CGDisplayIsActive(id) != 0, CGDisplayIsInMirrorSet(id) == 0,
                  screen.frame.width > 0, screen.frame.height > 0 else {
                panels.removeValue(forKey: id)?.close()
                continue
            }
            let panel = panels[id] ?? makePanel()
            panels[id] = panel
            // Include the menu bar and Dock, and preserve negative origins on secondary screens.
            panel.setFrame(screen.frame, display: true)
            panel.orderFrontRegardless()
        }
        return Set(panels.keys)
    }

    func hideAll() {
        for panel in panels.values { panel.close() }
        panels.removeAll()
    }

    private func makePanel() -> BlackScreenPanel {
        let panel = BlackScreenPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                                     backing: .buffered, defer: false)
        panel.title = "Lineup black screen"
        panel.backgroundColor = .black
        panel.isOpaque = true
        panel.hasShadow = false
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .stationary]
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.setAccessibilityElement(false)
        return panel
    }
}

private final class BlackScreenPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

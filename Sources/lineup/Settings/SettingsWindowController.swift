import AppKit
import AppCore
import SwiftUI

/// The one Settings window. Retains `.regular` activation while it is open (so it can take
/// focus and show a Dock icon) and releases it on close — always through `ActivationCoordinator`,
/// which is the sole owner of the app's activation policy. That is what stops closing Settings
/// from dropping the app to `.accessory` while the Zones layout editor is still open.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    let store: SettingsStore
    var onClose: (() -> Void)?

    private static let activationReason = "settings"

    init(store: SettingsStore) {
        self.store = store
        super.init()
    }

    func show() {
        store.refresh()
        if window == nil { window = makeWindow() }
        guard let window else { return }
        placeWindowIfNeeded(window)
        ActivationCoordinator.shared.retain(Self.activationReason)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 820, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.title = "\(Product.name) Settings"
        window.isReleasedWhenClosed = false // we keep the controller; AppKit must not free it
        window.delegate = self
        window.contentView = NSHostingView(rootView: SettingsRootView(store: store))
        window.center()
        return window
    }

    /// A window restored onto a display that is no longer connected opens off-screen and looks
    /// like nothing happened. Pull it back onto a real screen. (Carried over from Cycler, which
    /// hit this with a docked laptop.)
    private func placeWindowIfNeeded(_ window: NSWindow) {
        let visible = NSScreen.screens.map(\.visibleFrame)
        guard !visible.contains(where: { $0.intersects(window.frame) }) else { return }
        window.center()
    }

    func windowWillClose(_ notification: Notification) {
        store.stopAllRecording() // never leave the hotkey registry suspended
        ActivationCoordinator.shared.release(Self.activationReason)
        onClose?()
    }

    /// The shell calls this when a permission flips or a tool starts/stops.
    func refresh() {
        store.refresh()
    }
}

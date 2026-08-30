import AppKit
import AppCore
import SwiftUI

/// A window whose title AppKit and SwiftUI cannot change out from under us.
///
/// `NSHostingView` writes the detail column's `navigationTitle` straight into the host window's
/// title, so the title bar would read "General", then "Zones", then whatever a tool's pane
/// happens to set. The panes still declare a `navigationTitle` (it labels the pane for
/// accessibility), but the window itself stays "Lineup Settings".
private final class PinnedTitleWindow: NSWindow {
    var pinnedTitle = "" {
        didSet { super.title = pinnedTitle }
    }

    override var title: String {
        get { super.title }
        set { super.title = pinnedTitle.isEmpty ? newValue : pinnedTitle }
    }
}

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

    /// One alert at a time: a recorder that captured several combos can produce a burst of
    /// failures, and stacking sheets on the Settings window would be unusable.
    private var restoreAlertShowing = false

    init(store: SettingsStore) {
        self.store = store
        super.init()
        // A recorder holds the whole Carbon registry while it captures. If another app grabs one
        // of our combos in that window, the re-registration afterwards silently fails and the
        // user's shortcut is simply dead. Say so, naming the combo and the tool that lost it.
        store.onRecordingRestoreFailures = { [weak self] failures in
            self?.presentRestoreFailures(failures)
        }
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
        let window = PinnedTitleWindow(
            contentRect: NSRect(x: 0, y: 0, width: 820, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.pinnedTitle = "\(Product.name) Settings"
        window.isReleasedWhenClosed = false // we keep the controller; AppKit must not free it
        // The window is kept between openings, so without this it stays on the Space it was first
        // opened on and choosing Settings from another Space yanks the user across. (From Cycler.)
        window.collectionBehavior = [.moveToActiveSpace]
        window.delegate = self
        let controller = NSHostingController(rootView: SettingsRootView(store: store))
        // `sizingOptions = []` is what stops SwiftUI's ideal height from resizing the window — but
        // it also switches OFF the minimum size AppKit would have taken from the root view, so the
        // `frame(minWidth:minHeight:)` in SettingsRootView never reached the window and the user
        // could drag it down to a sliver. Set the floor on the window itself.
        if #available(macOS 13.0, *) { controller.sizingOptions = [] }
        window.contentViewController = controller
        window.contentMinSize = NSSize(width: 760, height: 520)
        window.setContentSize(NSSize(width: 820, height: 560))
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

    /// Losing focus mid-capture must end the capture: the local event monitor only sees this
    /// app's events, so a recorder left open would sit there claiming to record while the user
    /// types somewhere else. (Carried over from 1.x.)
    func windowDidResignKey(_ notification: Notification) {
        store.stopAllRecording()
    }

    func windowWillClose(_ notification: Notification) {
        store.stopAllRecording() // never leave the hotkey registry suspended
        ActivationCoordinator.shared.release(Self.activationReason)
        onClose?()
    }

    /// The shell calls this when a permission flips or a tool starts/stops.
    func refresh(updateChannel: UpdateChannel? = nil) {
        store.refresh(updateChannel: updateChannel)
    }

    // MARK: - Recording restore failures

    private func presentRestoreFailures(_ failures: [SettingsStore.RestoreFailure]) {
        guard !failures.isEmpty, !restoreAlertShowing else { return }
        restoreAlertShowing = true
        // Deferred: this arrives from inside the recorder's key handling, and running a modal
        // sheet from there would re-enter the event path that is still unwinding.
        DispatchQueue.main.async { [weak self] in
            self?.showRestoreAlert(failures)
        }
    }

    private func showRestoreAlert(_ failures: [SettingsStore.RestoreFailure]) {
        // A pane's own conflict prompt (Zones runs `NSAlert.runModal()`) spins a NESTED modal
        // loop, and the block queued above runs inside it — a sheet begun now lands on a window
        // the modal has disabled, so it can neither be read nor dismissed. Wait the modal out.
        // `restoreAlertShowing` stays true meanwhile, so nothing else queues a second copy.
        guard NSApp.modalWindow == nil else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                self?.showRestoreAlert(failures)
            }
            return
        }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = failures.count == 1
            ? "A shortcut couldn’t be restored"
            : "\(failures.count) shortcuts couldn’t be restored"
        alert.informativeText = """
            Another app claimed \(failures.count == 1 ? "it" : "them") while you were recording. \
            \(failures.count == 1 ? "It won’t" : "They won’t") fire until you quit that app or \
            pick a different combination.

            \(failureLines(failures).joined(separator: "\n"))
            """
        alert.addButton(withTitle: "OK")
        let finish: (NSApplication.ModalResponse) -> Void = { [weak self] _ in
            self?.restoreAlertShowing = false
        }
        if let window, window.isVisible {
            alert.beginSheetModal(for: window, completionHandler: finish)
        } else {
            finish(alert.runModal())
        }
    }

    private func failureLines(_ failures: [SettingsStore.RestoreFailure]) -> [String] {
        // Cap the list: a pathological case (a rival app grabbing a whole modifier layer) should
        // not produce an alert taller than the screen.
        let shown = failures.prefix(6).map { failure in
            "• \(ShortcutKit.display(keyCode: failure.keyCode, modifiers: failure.modifiers)) (\(self.store.displayName(for: failure.owner)))"
        }
        guard failures.count > shown.count else { return shown }
        return shown + ["• …and \(failures.count - shown.count) more"]
    }
}

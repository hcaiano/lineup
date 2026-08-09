import AppKit
import Carbon.HIToolbox
import SwiftUI

/// Drives shortcut capture for one pane.
///
/// It owns the local `NSEvent` monitor and applies the capture rules both 1.x apps already
/// shared — Esc cancels, Delete clears, a bare key beeps, modifier-only combos settle after a
/// short pause — and it routes the global hotkey suspension through `SettingsStore`. Panes must
/// never touch `HotkeyManager` directly: `SettingsStore` is what keeps the suspension ref-counted
/// and what `windowWillClose` / `windowDidResignKey` can cancel.
///
/// One recorder per pane, many fields. `activeID` names the field capturing right now, so the
/// pane renders "Press keys…" on exactly one row and a blur cancels exactly that row. Use any
/// `Hashable` as the id — Zones passes its action strings, Cycler passes row `UUID`s.
///
///     @StateObject private var recorder: ShortcutRecorder   // init(store:)
///     ShortcutField(text: row.shortcutText, isRecording: recorder.isRecording(row.id)) {
///         recorder.toggle(row.id) { capture in … }
///     }
@MainActor
final class ShortcutRecorder: ObservableObject {

    /// What a completed capture produced. `cancel` is never delivered — a cancelled capture just
    /// clears `activeID`, matching 1.x, where Esc left the previous value untouched.
    enum Capture: Equatable {
        /// A key plus at least one modifier. `modifiers` is a Carbon mask (canonical `UInt32`);
        /// callers that persist `Int` modifiers convert at the boundary.
        case combo(keyCode: Int, modifiers: UInt32)
        /// Modifiers held on their own, delivered after `modifierOnlyDelay`. Only possible when
        /// `Options.allowsModifierOnly` — Zones' drag bind is the only user today.
        case modifiersOnly(UInt32)
        /// The user pressed Delete: unbind this field.
        case clear
    }

    /// Per-field capture rules.
    struct Options: Equatable {
        /// Also watch `.flagsChanged` and allow a modifiers-only result (Zones' drag bind).
        var allowsModifierOnly = false
        /// How long modifiers must be held before they settle into `.modifiersOnly`.
        var modifierOnlyDelay: TimeInterval = 0.35

        /// Key + modifiers only. The default, and what both Cycler and Zones' shortcut rows want.
        static let combo = Options()
        /// Key + modifiers, or modifiers on their own.
        static let comboOrModifiers = Options(allowsModifierOnly: true)
    }

    /// The field currently capturing, or `nil`. Published so panes re-render on start/stop.
    @Published private(set) var activeID: AnyHashable?

    private unowned let store: SettingsStore
    private var monitor: Any?
    private var handler: ((Capture) -> Void)?
    private var options = Options.combo
    private var modifierOnlyTimer: Timer?
    private var pendingModifierOnly: UInt32?

    init(store: SettingsStore) {
        self.store = store
    }

    deinit {
        modifierOnlyTimer?.invalidate()
        if let monitor { NSEvent.removeMonitor(monitor) }
    }

    // MARK: - State

    var isRecording: Bool { activeID != nil }
    func isRecording(_ id: some Hashable) -> Bool { activeID == AnyHashable(id) }

    // MARK: - Control

    /// Click behaviour for a recorder control: start capturing `id`, or stop if it already is.
    func toggle(_ id: some Hashable, options: Options = .combo,
                onCapture: @escaping (Capture) -> Void) {
        if activeID == AnyHashable(id) {
            cancel()
        } else {
            begin(id, options: options, onCapture: onCapture)
        }
    }

    /// Start capturing for `id`, cancelling any capture already in flight.
    func begin(_ id: some Hashable, options: Options = .combo,
               onCapture: @escaping (Capture) -> Void) {
        cancel()
        activeID = AnyHashable(id)
        self.options = options
        handler = onCapture
        store.beginRecording(self) { [weak self] in self?.teardown() }
        let mask: NSEvent.EventTypeMask = options.allowsModifierOnly ? [.keyDown, .flagsChanged]
                                                                     : [.keyDown]
        monitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            guard let self else { return event }
            let consumed = MainActor.assumeIsolated { self.handle(event) }
            return consumed ? nil : event
        }
    }

    /// Stop without delivering anything. Idempotent, and safe to call when idle — this is what
    /// Esc, a blur, and closing the window all end up in.
    func cancel() {
        guard activeID != nil else { return }
        teardown()
        store.endRecording(self)
    }

    // MARK: - Capture

    private func finish(_ capture: Capture) {
        let handler = self.handler
        teardown()
        // Hand the hotkeys back BEFORE the pane reacts: a conflict alert runs a modal loop, and
        // 1.x deliberately restored the registry first so shortcuts stayed live behind it.
        store.endRecording(self)
        handler?(capture)
    }

    private func teardown() {
        activeID = nil
        handler = nil
        pendingModifierOnly = nil
        modifierOnlyTimer?.invalidate()
        modifierOnlyTimer = nil
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }

    /// Returns true when the event was consumed and must not reach the rest of the app.
    private func handle(_ event: NSEvent) -> Bool {
        guard activeID != nil else { return false }

        switch event.type {
        case .keyDown:
            let keyCode = Int(event.keyCode)
            // Modifier keys normally arrive as .flagsChanged; swallow any that leak through so
            // they can never be recorded as the key of a combo.
            if Self.isModifierKeyCode(keyCode) { return true }

            let bare = !ShortcutKit.hasModifier(event.modifierFlags)
            if keyCode == kVK_Escape, bare { cancel(); return true }
            if keyCode == kVK_Delete, bare { finish(.clear); return true }
            guard !bare else { NSSound.beep(); return true }

            finish(.combo(keyCode: keyCode,
                          modifiers: ShortcutKit.carbonModifierMask(from: event.modifierFlags)))
            return true

        case .flagsChanged:
            guard options.allowsModifierOnly else { return false }
            let mods = ShortcutKit.carbonModifierMask(from: event.modifierFlags)
            guard mods != 0 else {
                // All modifiers released. Releasing early commits what was held, so a quick tap
                // works as well as a hold.
                if let pending = pendingModifierOnly {
                    finish(.modifiersOnly(pending))
                } else {
                    modifierOnlyTimer?.invalidate()
                    modifierOnlyTimer = nil
                }
                return true
            }

            // Growing chords win: ⌥ then ⌥⌘ records ⌥⌘, not ⌥.
            pendingModifierOnly = Self.preferredModifierOnly(current: pendingModifierOnly, new: mods)
            modifierOnlyTimer?.invalidate()
            modifierOnlyTimer = Timer.scheduledTimer(withTimeInterval: options.modifierOnlyDelay,
                                                     repeats: false) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.activeID != nil,
                          let mods = self.pendingModifierOnly else { return }
                    self.finish(.modifiersOnly(mods))
                }
            }
            return true

        default:
            return false
        }
    }

    private static func preferredModifierOnly(current: UInt32?, new: UInt32) -> UInt32 {
        guard let current else { return new }
        return new.nonzeroBitCount >= current.nonzeroBitCount ? new : current
    }

    private static func isModifierKeyCode(_ keyCode: Int) -> Bool {
        switch keyCode {
        case kVK_Command, kVK_Shift, kVK_CapsLock, kVK_Option, kVK_Control,
             kVK_RightCommand, kVK_RightShift, kVK_RightOption, kVK_RightControl, kVK_Function:
            return true
        default:
            return false
        }
    }
}

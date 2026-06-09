import AppKit
import Carbon.HIToolbox

/// Global hotkeys via Carbon RegisterEventHotKey. Zero deps, no event tap / Input
/// Monitoring. We register with raw Carbon modifier masks (not NSEvent flags).
final class HotkeyManager {
    static let shared = HotkeyManager()

    /// Hyperkey = ⌃⌥⇧⌘. Carbon masks, OR'd. (Karabiner/hidutil usually produces this
    /// from Caps Lock; we just listen for the 4-modifier combo.)
    static let hyper: UInt32 =
        UInt32(controlKey) | UInt32(optionKey) | UInt32(shiftKey) | UInt32(cmdKey)

    private var actions: [UInt32: () -> Void] = [:]
    private var refs: [EventHotKeyRef?] = []
    private var nextID: UInt32 = 1
    private var handlerInstalled = false
    // FourCharCode 'LNUP' (Lineup) — internal namespace for this app's Carbon hotkeys.
    private let signature: FourCharCode =
        (FourCharCode(UInt8(ascii: "L")) << 24) |
        (FourCharCode(UInt8(ascii: "N")) << 16) |
        (FourCharCode(UInt8(ascii: "U")) << 8) |
        FourCharCode(UInt8(ascii: "P"))

    /// Register a global hotkey. `keyCode` is a Carbon virtual key (kVK_*).
    /// Returns true on success. The action is stored ONLY if registration succeeded, so
    /// the menu never advertises a binding that isn't actually live (e.g. Magnet still
    /// owns the combo).
    @discardableResult
    func register(keyCode: Int, modifiers: UInt32 = HotkeyManager.hyper, action: @escaping () -> Void) -> Bool {
        installHandlerIfNeeded()
        let id = nextID
        nextID += 1

        var ref: EventHotKeyRef?
        let hkID = EventHotKeyID(signature: signature, id: id)
        let status = RegisterEventHotKey(
            UInt32(keyCode), modifiers, hkID, GetApplicationEventTarget(), 0, &ref)
        guard status == noErr else {
            FileHandle.standardError.write(Data("RegisterEventHotKey failed (\(status)) for key \(keyCode)\n".utf8))
            return false
        }
        actions[id] = action
        refs.append(ref)
        return true
    }

    /// Tear down all registered hotkeys (used before a clean retry).
    func unregisterAll() {
        for ref in refs where ref != nil {
            UnregisterEventHotKey(ref!)
        }
        refs.removeAll()
        actions.removeAll()
        nextID = 1
    }

    private func installHandlerIfNeeded() {
        guard !handlerInstalled else { return }
        handlerInstalled = true
        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(
            GetApplicationEventTarget(),
            { (_, event, _) -> OSStatus in
                var hkID = EventHotKeyID()
                GetEventParameter(
                    event, EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID), nil,
                    MemoryLayout<EventHotKeyID>.size, nil, &hkID)
                HotkeyManager.shared.actions[hkID.id]?()
                return noErr
            },
            1, &spec, nil, nil)
    }
}

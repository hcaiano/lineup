import AppKit
import AppCore
import Carbon.HIToolbox

/// Global hotkeys via Carbon `RegisterEventHotKey`. Zero deps, no event tap / Input Monitoring.
/// Registers with raw Carbon modifier masks (not NSEvent flags).
///
/// One registry for all tools. Every row records its owning `ToolID`, which buys three
/// things the two 1.x managers couldn't do:
/// - `unregisterAll(owner:)`, so a tool's `stop()` can't take a sibling's hotkeys down with it;
/// - a pre-Carbon duplicate check, so a Zones/Cycler collision reports `.ownedByTool` instead of
///   an opaque `eventHotKeyExistsErr`;
/// - `suspendAll()`/`resumeAll()`, one ref-counted mechanism replacing lineup's `setRecording`
///   (unregister + rebuild) and cycler's `hotkeysSuspended` flag, so a Settings recorder can
///   capture a combo any tool owns and hand it back without involving the tools at all.
///
/// The Carbon signature stays `'LNUP'` — unchanged from Lineup 1.x.
@MainActor
final class HotkeyManager {
    static let shared = HotkeyManager()

    /// Hyperkey = ⌃⌥⇧⌘. Carbon masks, OR'd. (Karabiner/hidutil — or Lineup's own Hyperkey tool —
    /// usually produces this from Caps Lock; we just listen for the 4-modifier combo.)
    nonisolated static let hyper: UInt32 = ShortcutKit.hyper

    /// Opaque handle to one registration. Only the owning tool should hold one.
    struct Token: Hashable { fileprivate let raw: UInt32 }

    private struct Registration {
        let owner: ToolID
        let keyCode: Int
        let modifiers: UInt32
        var ref: EventHotKeyRef?
        let action: () -> Void
    }

    private struct Combo: Hashable {
        let keyCode: Int
        let modifiers: UInt32
    }

    private var registrations: [UInt32: Registration] = [:]
    private var byOwner: [ToolID: Set<UInt32>] = [:]
    private var byCombo: [Combo: UInt32] = [:]
    private var nextID: UInt32 = 1
    private var suspendDepth = 0
    private var handlerInstalled = false

    /// FourCharCode `'LNUP'` (Lineup) — this app's Carbon hotkey namespace, unchanged from 1.x.
    /// Derived from `Product.hotkeySignatureString` so the constant has exactly one home;
    /// pinned by `AppSuite`.
    nonisolated static let signature: FourCharCode = fourCharCode(Product.hotkeySignatureString)

    nonisolated static func fourCharCode(_ s: String) -> FourCharCode {
        s.utf8.prefix(4).reduce(FourCharCode(0)) { ($0 << 8) | FourCharCode($1) }
    }

    // MARK: - Register

    /// Registers under `'LNUP'`. The action is stored ONLY on success, so no UI ever advertises
    /// a dead binding. A combo another Lineup tool already owns is rejected BEFORE hitting
    /// Carbon, so the failure can be attributed precisely.
    @discardableResult
    func register(owner: ToolID, keyCode: Int, modifiers: UInt32,
                  action: @escaping () -> Void) -> Result<Token, HotkeyFailure> {
        let combo = Combo(keyCode: keyCode, modifiers: modifiers)
        if let existingID = byCombo[combo], let existing = registrations[existingID] {
            return .failure(.ownedByTool(existing.owner))
        }

        let id = nextID
        nextID += 1

        var ref: EventHotKeyRef?
        if suspendDepth == 0 {
            installHandlerIfNeeded()
            let status = carbonRegister(keyCode: keyCode, modifiers: modifiers, id: id, ref: &ref)
            guard status == noErr else { return .failure(.carbon(status)) }
        }
        // While suspended the row is recorded but NOT live; resumeAll() installs it and reports
        // any row that has since been taken by another app.
        registrations[id] = Registration(owner: owner, keyCode: keyCode, modifiers: modifiers,
                                         ref: ref, action: action)
        byOwner[owner, default: []].insert(id)
        byCombo[combo] = id
        return .success(Token(raw: id))
    }

    // MARK: - Unregister

    func unregister(_ token: Token) {
        removeRegistration(token.raw)
    }

    /// MUST be called from `Tool.stop()`.
    func unregisterAll(owner: ToolID) {
        for id in byOwner[owner] ?? [] { removeRegistration(id, skipOwnerIndex: true) }
        byOwner[owner] = nil
    }

    func unregisterAll() {
        for id in Array(registrations.keys) { removeRegistration(id, skipOwnerIndex: true) }
        byOwner.removeAll()
    }

    private func removeRegistration(_ id: UInt32, skipOwnerIndex: Bool = false) {
        guard let reg = registrations.removeValue(forKey: id) else { return }
        if let ref = reg.ref { UnregisterEventHotKey(ref) }
        byCombo[Combo(keyCode: reg.keyCode, modifiers: reg.modifiers)] = nil
        if !skipOwnerIndex {
            byOwner[reg.owner]?.remove(id)
            if byOwner[reg.owner]?.isEmpty == true { byOwner[reg.owner] = nil }
        }
    }

    // MARK: - Suspend / resume

    /// Suspend the WHOLE registry without losing the table, so a Settings recorder can capture
    /// combos any tool owns and restore them without involving the tools. Ref-counted; nested
    /// suspends are safe.
    func suspendAll() {
        suspendDepth += 1
        guard suspendDepth == 1 else { return }
        for (id, reg) in registrations {
            if let ref = reg.ref { UnregisterEventHotKey(ref) }
            registrations[id]?.ref = nil
        }
    }

    /// Re-installs every suspended row. Returns the rows that FAILED to come back — another app
    /// may have claimed the combo while we were suspended — so the caller can warn about them.
    @discardableResult
    func resumeAll() -> [(owner: ToolID, keyCode: Int, modifiers: UInt32, status: OSStatus)] {
        guard suspendDepth > 0 else { return [] }
        suspendDepth -= 1
        guard suspendDepth == 0 else { return [] }
        installHandlerIfNeeded()
        var failures: [(owner: ToolID, keyCode: Int, modifiers: UInt32, status: OSStatus)] = []
        for (id, reg) in registrations where reg.ref == nil {
            var ref: EventHotKeyRef?
            let status = carbonRegister(keyCode: reg.keyCode, modifiers: reg.modifiers, id: id, ref: &ref)
            if status == noErr {
                registrations[id]?.ref = ref
            } else {
                failures.append((reg.owner, reg.keyCode, reg.modifiers, status))
            }
        }
        return failures
    }

    var isSuspended: Bool { suspendDepth > 0 }

    // MARK: - Introspection

    func registeredCombos() -> [(owner: ToolID, keyCode: Int, modifiers: UInt32)] {
        registrations.values.map { ($0.owner, $0.keyCode, $0.modifiers) }
    }

    // MARK: - Carbon

    private func carbonRegister(keyCode: Int, modifiers: UInt32, id: UInt32,
                                ref: inout EventHotKeyRef?) -> OSStatus {
        let hkID = EventHotKeyID(signature: Self.signature, id: id)
        return RegisterEventHotKey(UInt32(keyCode), modifiers, hkID,
                                   GetApplicationEventTarget(), 0, &ref)
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
                // Carbon delivers application-target events on the main event loop; the C
                // callback just can't prove it to the compiler.
                MainActor.assumeIsolated {
                    HotkeyManager.shared.registrations[hkID.id]?.action()
                }
                return noErr
            },
            1, &spec, nil, nil)
    }
}

extension HotkeyFailure {
    /// Human wording for a menu/pane row. `-9878` is `eventHotKeyExistsErr`.
    var displayReason: String {
        switch self {
        case .ownedByTool(let id): return "already used by \(id.rawValue.capitalized)"
        case .carbon(let status): return status == -9878 ? "already in use" : "status \(status)"
        }
    }
}

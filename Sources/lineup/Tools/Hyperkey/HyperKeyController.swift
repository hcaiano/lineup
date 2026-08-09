import AppCore
import Carbon.HIToolbox
import CoreGraphics
import Foundation
import HyperkeyCore
import os

private let log = Logger(subsystem: Product.logSubsystem, category: "hyperkey")

/// NOT @MainActor: hidutil work runs on `hidutilQueue` with completions hopped back to main,
/// so this class manages its own threading. All instance state is only touched on the main
/// thread (apply/stop from HyperkeyTool, the event tap on the main run loop).
///
/// Copied from standalone Cycler and retargeted for Lineup 2.0: the logger subsystem, the
/// `hidutil` queue label and the Caps Lock ownership flag are all Lineup's now. The ownership
/// handoff from a previous Cycler install lives in `CapsLockHandoff`.
final class HyperKeyController {
    enum State: Equatable {
        case disabled
        case active
        case blocked(String)
    }

    static let capsLockHID: UInt64 = 0x700000039
    static let f18HID: UInt64 = 0x70000006D
    private static let capsLockKeyCode = 57
    /// The ownership flag lives in Lineup's own defaults domain. `CapsLockHandoff` owns the
    /// constant so the legacy Cycler key it supersedes has exactly one mention in the tree.
    private static var ownsCapsLockMappingKey: String { CapsLockHandoff.newKey }
    private static let inputMonitoringBlockedMessage = "Input Monitoring permission required"
    private static let secureInputBlockedMessage =
        "Secure Input is active; if this persists, quit and reopen your password app. Hyper Key will retry automatically"
    /// Set on the standalone Cycler.app guard (see `HyperkeyTool.apply()`); its own tap and its
    /// own Caps Lock remap would fight ours.
    static let standaloneCyclerBlockedMessage = "Cycler is running — quit it to use Hyperkey here"
    private static let syntheticEventMarker: Int64 = 0x4C4E_4850 // "LNHP" — Lineup's own events
    private static let hidutilQueue = DispatchQueue(label: Product.bundleID + ".hidutil")
    private static var clearOnExit = false
    private static var installedAtexit = false

    /// Set by `HyperkeyTool` immediately before each `apply()`: standalone Cycler.app is alive and
    /// holds (or will grab) the same Caps Lock -> F18 mapping. Checked only for triggers that need
    /// the remap; a function-key trigger never collides with it.
    var blockedByStandaloneCycler = false

    /// The keycode the event tap watches for each trigger. Caps Lock is remapped to F18 via
    /// `hidutil`, so it shares F18's keycode; the function keys report their own.
    private static func watchKeyCode(for trigger: TriggerKey) -> Int64 {
        switch trigger {
        case .capsLock, .f18: return 79 // kVK_F18 (Caps Lock arrives here after the hidutil remap)
        case .leftControl: return 59
        case .leftShift: return 56
        case .leftOption: return 58
        case .leftCommand: return 55
        case .rightControl: return 62
        case .rightShift: return 60
        case .rightOption: return 61
        case .rightCommand: return 54
        case .f1: return 122
        case .f2: return 120
        case .f3: return 99
        case .f4: return 118
        case .f5: return 96
        case .f6: return 97
        case .f7: return 98
        case .f8: return 100
        case .f9: return 101
        case .f10: return 109
        case .f11: return 103
        case .f12: return 111
        case .f19: return 80 // kVK_F19
        case .f20: return 90 // kVK_F20
        }
    }

    /// Fired on the main thread whenever `state` settles — `apply()` resolves asynchronously
    /// (hidutil runs on a background queue), so the menu must refresh on this callback rather
    /// than by reading `state` right after `apply()` returns.
    var onStateChange: ((State) -> Void)?

    private(set) var state: State = .disabled {
        didSet {
            guard oldValue != state else { return }
            onStateChange?(state)
        }
    }
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var triggerDown = false
    private var syntheticModifierKeyCodesDown: [CGKeyCode] = []
    private var didApplyMapping = false
    private var includeShift = true
    private var activeTrigger: TriggerKey?
    private var triggerKeyCode: Int64 = 79
    private var hidutilOperationID = 0
    private var appliedSettings = HyperKeySettings.disabled
    private var secureInputTimer: Timer?

    var menuStatus: String? {
        switch state {
        case .disabled:
            return nil
        case .active:
            return "Hyper Key active"
        case .blocked(let message):
            return "⚠︎ Hyper Key blocked: \(message)"
        }
    }

    var settingsStatus: String? {
        switch state {
        case .disabled:
            return nil
        case .active:
            return "Active"
        case .blocked(let message):
            return "Blocked: \(message)"
        }
    }

    var needsInputMonitoring: Bool {
        state == .blocked(Self.inputMonitoringBlockedMessage)
    }

    func apply(_ settings: HyperKeySettings) {
        appliedSettings = settings
        updateSecureInputWatch(enabled: settings.enabled)
        let operationID = nextHidutilOperationID()
        guard settings.enabled else {
            stop(invalidatingPending: false)
            Self.clearKnownOwnedMappingAsync()
            state = .disabled
            return
        }

        let secureInputActive = IsSecureEventInputEnabled()

        guard !secureInputActive else {
            stop(invalidatingPending: false)
            Self.clearKnownOwnedMappingAsync()
            state = .blocked(Self.secureInputBlockedMessage)
            return
        }

        // Standalone Cycler.app owns the same remap and installs its own tap; two hyper providers
        // on one Caps Lock is a guaranteed fight, and its ownership flag would strand the mapping.
        // Same shape as the Raycast block, and it recovers on didBecomeActive once Cycler quits.
        if settings.triggerKey.needsCapsLockRemap, blockedByStandaloneCycler {
            stop(invalidatingPending: false)
            Self.clearKnownOwnedMappingAsync()
            state = .blocked(Self.standaloneCyclerBlockedMessage)
            return
        }

        // Raycast only matters when Lineup also wants Caps Lock; function keys never collide with it.
        if settings.triggerKey.needsCapsLockRemap, Self.raycastCapsHyperEnabled() {
            stop(invalidatingPending: false)
            Self.clearKnownOwnedMappingAsync()
            state = .blocked("Raycast is using Caps Lock")
            return
        }

        // A function-key trigger never uses hidutil; clear only a Caps Lock remap that Lineup knows
        // it created in this or a previous crashed run. A user-owned CapsLock->F18 mapping has the
        // same shape, so shape alone must not be treated as ownership.
        if !settings.triggerKey.needsCapsLockRemap {
            Self.clearKnownOwnedMappingAsync()
        }

        start(trigger: settings.triggerKey, includeShift: settings.includeShift, operationID: operationID)
    }

    private func updateSecureInputWatch(enabled: Bool) {
        guard enabled else {
            secureInputTimer?.invalidate()
            secureInputTimer = nil
            return
        }
        guard secureInputTimer == nil else { return }
        secureInputTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            self?.reconcileSecureInput()
        }
        secureInputTimer?.tolerance = 0.5
    }

    private func reconcileSecureInput() {
        guard appliedSettings.enabled else { return }
        let secureInputActive = IsSecureEventInputEnabled()
        if secureInputActive, state != .blocked(Self.secureInputBlockedMessage) {
            apply(appliedSettings)
        } else if !secureInputActive, state == .blocked(Self.secureInputBlockedMessage) {
            apply(appliedSettings)
        }
    }

    private enum StartResult {
        case started
        case blocked(String)
    }

    private enum MappingResult {
        case ready(createdMapping: Bool)
        case blocked(String)
    }

    private func nextHidutilOperationID() -> Int {
        hidutilOperationID += 1
        return hidutilOperationID
    }

    private func start(trigger: TriggerKey, includeShift: Bool, operationID: Int) {
        // A live tap bound to a different trigger must be torn down so we re-apply the right mapping
        // and watch the right keycode; same-trigger reconfig only needs the live includeShift update.
        if tap != nil, activeTrigger != trigger {
            stop(invalidatingPending: false)
        }
        self.includeShift = includeShift

        guard Self.ensureListenEventAccess() else {
            if tap != nil { stop(invalidatingPending: false) }
            state = .blocked(Self.inputMonitoringBlockedMessage)
            return
        }

        if trigger.needsCapsLockRemap {
            Self.ensureCapsLockMappingAsync { [weak self] result in
                guard let self, self.hidutilOperationID == operationID else { return }
                switch result {
                case .ready(let createdMapping):
                    if createdMapping || Self.ownsCapsLockMapping {
                        self.didApplyMapping = true
                        if createdMapping {
                            Self.setOwnsCapsLockMapping(true)
                        }
                        Self.clearOnExit = true
                        Self.installAtexit()
                    }
                    self.finishStart(self.startTap(trigger: trigger))
                case .blocked(let message):
                    if self.tap != nil { self.stop(invalidatingPending: false) }
                    self.state = .blocked(message)
                }
            }
            return
        }

        finishStart(startTap(trigger: trigger))
    }

    private func startTap(trigger: TriggerKey) -> StartResult {
        if tap != nil {
            return .started
        }

        triggerKeyCode = Self.watchKeyCode(for: trigger)

        let mask: CGEventMask = (
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.keyUp.rawValue) |
            (1 << CGEventType.flagsChanged.rawValue) |
            (1 << CGEventType.tapDisabledByTimeout.rawValue) |
            (1 << CGEventType.tapDisabledByUserInput.rawValue)
        )
        guard let created = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: hyperKeyControllerTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            stop(invalidatingPending: false)
            return .blocked("CGEvent.tapCreate failed")
        }

        tap = created
        source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, created, 0)
        if let source {
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        }
        CGEvent.tapEnable(tap: created, enable: true)
        activeTrigger = trigger
        return .started
    }

    private func finishStart(_ result: StartResult) {
        switch result {
        case .started:
            state = .active
        case .blocked(let message):
            state = .blocked(message)
        }
    }

    private static func ensureCapsLockMapping() -> MappingResult {
        let mapping = Self.currentMapping()
        let mappingIsOurs = Self.isMappingOurs(mapping)
        guard Self.isMappingEmpty(mapping) || mappingIsOurs else {
            return .blocked("existing hidutil UserKeyMapping is not Lineup's CapsLock->F18 mapping")
        }
        var createdMapping = false
        if !mappingIsOurs {
            guard Self.applyCapsLockToF18() else {
                return .blocked("hidutil failed to apply CapsLock->F18")
            }
            createdMapping = true
            Self.setOwnsCapsLockMapping(true)
            Self.clearOnExit = true
            Self.installAtexit()
        } else if Self.ownsCapsLockMapping {
            Self.clearOnExit = true
            Self.installAtexit()
        }
        return .ready(createdMapping: createdMapping)
    }

    func stop() {
        secureInputTimer?.invalidate()
        secureInputTimer = nil
        appliedSettings = .disabled
        stop(invalidatingPending: true)
    }

    private func stop(invalidatingPending: Bool) {
        if invalidatingPending {
            _ = nextHidutilOperationID()
        }
        releaseSyntheticModifiers()
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
        }
        tap = nil
        source = nil
        triggerDown = false
        activeTrigger = nil

        if didApplyMapping {
            didApplyMapping = false
            Self.clearKnownOwnedMappingAsync()
        }
        if state != .disabled {
            state = .disabled
        }
    }

    fileprivate func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            triggerDown = false
            releaseSyntheticModifiers()
            if let tap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        if event.getIntegerValueField(.eventSourceUserData) == Self.syntheticEventMarker {
            return Unmanaged.passUnretained(event)
        }

        if type == .flagsChanged,
           keyCode == triggerKeyCode,
           let modifierBit = activeTrigger?.deviceModifierRawBit {
            let isDown = event.flags.rawValue & modifierBit != 0
            guard isDown != triggerDown else { return nil }
            triggerDown = isDown
            if isDown {
                pressSyntheticModifiers()
            } else {
                releaseSyntheticModifiers()
            }
            return nil
        }

        if type == .keyDown, keyCode == triggerKeyCode {
            if !triggerDown {
                triggerDown = true
                pressSyntheticModifiers()
            }
            return nil
        }
        if type == .keyUp, keyCode == triggerKeyCode {
            triggerDown = false
            releaseSyntheticModifiers()
            return nil
        }

        if triggerDown && (type == .keyDown || type == .keyUp) {
            Self.replaceModifierFlags(on: event, with: hyperFlags(preservingPhysicalModifiersFrom: event.flags))
            return Unmanaged.passUnretained(event)
        }
        return Unmanaged.passUnretained(event)
    }

    private func pressSyntheticModifiers() {
        guard syntheticModifierKeyCodesDown.isEmpty else { return }
        let keyCodes = Self.modifierKeyCodes(includeShift: includeShift)
        var activeKeyCodes: [CGKeyCode] = []
        for keyCode in keyCodes {
            activeKeyCodes.append(keyCode)
            Self.postSyntheticModifier(keyCode, keyDown: true, activeKeyCodes: activeKeyCodes)
        }
        syntheticModifierKeyCodesDown = keyCodes
    }

    private func releaseSyntheticModifiers() {
        guard !syntheticModifierKeyCodesDown.isEmpty else { return }
        var activeKeyCodes = syntheticModifierKeyCodesDown
        for keyCode in syntheticModifierKeyCodesDown.reversed() {
            activeKeyCodes.removeAll { $0 == keyCode }
            Self.postSyntheticModifier(keyCode, keyDown: false, activeKeyCodes: activeKeyCodes)
        }
        syntheticModifierKeyCodesDown = []
    }

    private static func modifierKeyCodes(includeShift: Bool) -> [CGKeyCode] {
        var keyCodes: [CGKeyCode] = [59, 58] // Control, Option
        if includeShift { keyCodes.append(56) }
        keyCodes.append(55) // Command
        return keyCodes
    }

    private static func postSyntheticModifier(_ keyCode: CGKeyCode, keyDown: Bool, activeKeyCodes: [CGKeyCode]) {
        guard let event = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: keyDown) else {
            return
        }
        replaceModifierFlags(on: event, with: modifierFlags(for: activeKeyCodes))
        event.setIntegerValueField(.eventSourceUserData, value: syntheticEventMarker)
        event.post(tap: .cghidEventTap)
    }

    private var hyperFlags: CGEventFlags {
        Self.modifierFlags(for: Self.modifierKeyCodes(includeShift: includeShift))
    }

    private func hyperFlags(preservingPhysicalModifiersFrom currentFlags: CGEventFlags) -> CGEventFlags {
        var raw = hyperFlags.rawValue
        if !includeShift, currentFlags.rawValue & Self.shiftModifierRawValue != 0 {
            raw |= Self.shiftModifierRawValue
        }
        return CGEventFlags(rawValue: raw)
    }

    private static func modifierFlags(for keyCodes: [CGKeyCode]) -> CGEventFlags {
        let raw = keyCodes.reduce(UInt64(0)) { $0 | modifierFlagRawValue(for: $1) }
        return CGEventFlags(rawValue: raw)
    }

    private static func replaceModifierFlags(on event: CGEvent, with flags: CGEventFlags) {
        let base = event.flags.rawValue & ~modifierMaskRawValue
        event.flags = CGEventFlags(rawValue: base | flags.rawValue)
    }

    private static var modifierMaskRawValue: UInt64 {
        CGEventFlags.maskControl.rawValue |
            CGEventFlags.maskAlternate.rawValue |
            CGEventFlags.maskShift.rawValue |
            CGEventFlags.maskCommand.rawValue |
            0x2b
    }

    private static var shiftModifierRawValue: UInt64 {
        modifierFlagRawValue(for: 56)
    }

    private static func modifierFlagRawValue(for keyCode: CGKeyCode) -> UInt64 {
        switch keyCode {
        case 59: return CGEventFlags.maskControl.rawValue | 0x1
        case 58: return CGEventFlags.maskAlternate.rawValue | 0x20
        case 56: return CGEventFlags.maskShift.rawValue | 0x2
        case 55: return CGEventFlags.maskCommand.rawValue | 0x8
        default: return 0
        }
    }

    private static func ensureListenEventAccess() -> Bool {
        if CGPreflightListenEventAccess() { return true }
        return CGRequestListenEventAccess()
    }

    // `currentMapping` / `isMappingOurs` / `clearIfMappingIsOurs` / the ownership accessors are
    // internal rather than private: `CapsLockHandoff` needs exactly these to adopt a mapping a
    // previous standalone-Cycler run left behind, to spot an orphaned one, and to restore it on
    // request. Nothing else in the target may touch hidutil.
    static func currentMapping() -> String {
        runHidutil(arguments: ["property", "--get", "UserKeyMapping"]).output
    }

    static func isMappingEmpty(_ output: String) -> Bool {
        let compact = output.filter { !$0.isWhitespace }.lowercased()
        return compact == "()" || compact == "(null)" || compact == "null"
    }

    static func isMappingOurs(_ output: String) -> Bool {
        // `hidutil property --get` prints a CoreFoundation description whose key quoting/spacing
        // isn't guaranteed. Match the structure plus our two exact HID usage values.
        output.components(separatedBy: "HIDKeyboardModifierMappingSrc").count == 2
            && output.components(separatedBy: "HIDKeyboardModifierMappingDst").count == 2
            && output.contains("\(capsLockHID)")
            && output.contains("\(f18HID)")
    }

    private static func applyCapsLockToF18() -> Bool {
        let json = """
        {"UserKeyMapping":[{"HIDKeyboardModifierMappingSrc":\(capsLockHID),"HIDKeyboardModifierMappingDst":\(f18HID)}]}
        """
        let result = runHidutil(arguments: ["property", "--set", json])
        if result.status != 0 {
            log.error("hidutil apply failed \(result.status, privacy: .public): \(result.error, privacy: .public)")
            return false
        }
        return true
    }

    @discardableResult
    static func clearIfMappingIsOurs() -> Bool {
        guard isMappingOurs(currentMapping()) else { return false }
        let result = runHidutil(arguments: ["property", "--set", #"{"UserKeyMapping":[]}"#])
        if result.status != 0 {
            log.error("hidutil clear failed \(result.status, privacy: .public): \(result.error, privacy: .public)")
            return false
        }
        return true
    }

    private static func clearKnownOwnedMapping() -> Bool {
        guard ownsCapsLockMapping else { return false }
        guard isMappingOurs(currentMapping()) else {
            setOwnsCapsLockMapping(false)
            clearOnExit = false
            return false
        }
        let cleared = clearIfMappingIsOurs()
        if cleared {
            setOwnsCapsLockMapping(false)
            clearOnExit = false
        }
        return cleared
    }

    private static func ensureCapsLockMappingAsync(completion: @escaping (MappingResult) -> Void) {
        // Install the exit hook BEFORE queueing: if the process exits while the remap is still
        // in flight, atexit must already exist to drain the queue and clean up.
        installAtexit()
        hidutilQueue.async {
            let result = ensureCapsLockMapping()
            DispatchQueue.main.async {
                completion(result)
            }
        }
    }

    private static func clearKnownOwnedMappingAsync() {
        // Same exit discipline as the apply path: the atexit drain must be installed before
        // queueing, so a quit right after a startup/disable-triggered clear still runs it.
        installAtexit()
        hidutilQueue.async {
            _ = clearKnownOwnedMapping()
        }
    }

    static var ownsCapsLockMapping: Bool {
        UserDefaults.standard.bool(forKey: ownsCapsLockMappingKey)
    }

    static func setOwnsCapsLockMapping(_ owns: Bool) {
        if owns {
            UserDefaults.standard.set(true, forKey: ownsCapsLockMappingKey)
        } else {
            UserDefaults.standard.removeObject(forKey: ownsCapsLockMappingKey)
        }
    }

    /// The mapping is gone (a user-triggered restore, or an adoption that found nothing applied):
    /// drop ownership AND the exit hook's arming flag, so the `atexit` drain doesn't try to clear
    /// a mapping we no longer own.
    static func releaseOwnedMapping() {
        setOwnsCapsLockMapping(false)
        clearOnExit = false
    }

    /// Adoption: a mapping that is already applied becomes ours, so our teardown clears it.
    /// Arms the exit hook exactly as the create path does.
    static func adoptAppliedMapping() {
        setOwnsCapsLockMapping(true)
        clearOnExit = true
        installAtexit()
    }

    /// Internal, not private: Raycast's own Hyper Key installs the SAME CapsLock->F18 mapping, so
    /// `CapsLockHandoff` has to ask this before calling a mapping orphaned — otherwise Lineup would
    /// offer to "restore" Caps Lock out from under a perfectly healthy Raycast.
    static func raycastCapsHyperEnabled() -> Bool {
        guard let value = CFPreferencesCopyAppValue(
            "raycast_hyperKey_state" as CFString,
            "com.raycast.macos" as CFString
        ) as? [String: Any] else {
            return false
        }

        let enabled: Bool
        if let bool = value["enabled"] as? Bool {
            enabled = bool
        } else if let number = value["enabled"] as? NSNumber {
            enabled = number.boolValue
        } else {
            enabled = false
        }

        let keyCode: Int?
        if let int = value["keyCode"] as? Int {
            keyCode = int
        } else if let number = value["keyCode"] as? NSNumber {
            keyCode = number.intValue
        } else {
            keyCode = nil
        }

        return enabled && keyCode == capsLockKeyCode
    }

    private static func installAtexit() {
        guard !installedAtexit else { return }
        installedAtexit = true
        atexit {
            // Drain in-flight hidutil work first: quitting right after enabling the hyper key
            // must wait for the remap (and its ownership recording) to finish, or the mapping
            // would outlive the process with no cleanup path. The queue never blocks on main,
            // so this cannot deadlock.
            HyperKeyController.hidutilQueue.sync {}
            if HyperKeyController.clearOnExit {
                _ = HyperKeyController.clearKnownOwnedMapping()
            }
        }
    }

    private static func runHidutil(arguments: [String]) -> (status: Int32, output: String, error: String) {
        let process = Process()
        let out = Pipe()
        let err = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hidutil")
        process.arguments = arguments
        process.standardOutput = out
        process.standardError = err

        do {
            try process.run()
            process.waitUntilExit()
            let output = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            let error = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            return (process.terminationStatus, output, error)
        } catch {
            return (127, "", String(describing: error))
        }
    }
}

private func hyperKeyControllerTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let controller = Unmanaged<HyperKeyController>.fromOpaque(userInfo).takeUnretainedValue()
    return controller.handle(type: type, event: event)
}

import AppCore
import Carbon.HIToolbox
import CoreGraphics
import Foundation
import HyperkeyCore
import os

private let log = Logger(subsystem: Product.logSubsystem, category: "hyperkey")

/// The event tap and trigger state live on the main run loop. KeyboardMappingService owns
/// keyboard maps and all IOKit work; this controller only consumes the remapped trigger.
@MainActor
final class HyperKeyController {
    enum State: Equatable {
        case disabled
        case active
        case blocked(String)
    }

    static let capsLockHID = CapsLockMapping.capsLockHID
    static let f18HID = CapsLockMapping.f18HID
    private static let capsLockKeyCode = 57
    private static let inputMonitoringBlockedMessage = "Input Monitoring permission required"
    private static let secureInputBlockedMessage =
        "Secure Input is active; if this persists, quit and reopen your password app. Hyper Key will retry automatically"
    /// Set on the standalone Cycler.app guard (see `HyperkeyTool.apply()`); its own tap and its
    /// own Caps Lock remap would fight ours.
    static let standaloneCyclerBlockedMessage = "Cycler is running. Quit it to use Hyperkey here"
    private static let syntheticEventMarker: Int64 = 0x4C4E_4850 // "LNHP" — Lineup's own events
    /// Set by `HyperkeyTool` immediately before each `apply()`: standalone Cycler.app is alive and
    /// holds (or will grab) the same Caps Lock -> F18 mapping. Checked only for triggers that need
    /// the remap; a function-key trigger never collides with it.
    var blockedByStandaloneCycler = false

    /// The keycode the event tap watches for each trigger. Caps Lock is remapped to F18 via
    /// the shared mapping service, so it shares F18’s keycode; function keys report their own.
    private static func watchKeyCode(for trigger: TriggerKey) -> Int64 {
        switch trigger {
        case .capsLock, .f18: return 79 // kVK_F18 (Caps Lock arrives here after the HID remap)
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
    /// (keyboard maps apply on a background queue), so the menu must refresh on this callback rather
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
    private var mappingOperationID = 0
    private var keyboardMappings = KeyboardMappingService.shared
    private var mappingObserver: UUID?
    private var appliedSettings = HyperKeySettings.disabled
    private var inputStateTimer: Timer?

    func useKeyboardMappings(_ service: KeyboardMappingService) {
        if let mappingObserver { keyboardMappings.removeObserver(mappingObserver) }
        keyboardMappings = service
        mappingObserver = service.observe { [weak self] in self?.reconcileMappingState() }
    }

    private func reconcileMappingState() {
        guard appliedSettings.enabled, appliedSettings.triggerKey.needsCapsLockRemap,
              keyboardMappings.hyperkeyRequested else { return }
        if let message = keyboardMappings.hyperkeyStatus {
            stop(invalidatingPending: false, settingState: .blocked(message), releaseMapping: false)
        } else if keyboardMappings.hyperkeyReady {
            didApplyMapping = true
            finishStart(startTap(trigger: appliedSettings.triggerKey))
        }
    }

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

    /// True when the tap is already live for exactly these settings and the Caps Lock remap (if
    /// this trigger needs one) is already applied. The activation path skips redundant work;
    /// wake and settings changes always reconcile the shared service.
    ///
    /// Secure Input is deliberately NOT part of this: its own 2s timer owns that transition and
    /// calls `apply()` directly, so gating on it here would only duplicate the check.
    func isSettled(for settings: HyperKeySettings) -> Bool {
        guard settings.enabled, state == .active, tapIsHealthy else { return false }
        guard activeTrigger == settings.triggerKey, includeShift == settings.includeShift else { return false }
        guard settings.triggerKey.needsCapsLockRemap else { return true }
        return didApplyMapping && !blockedByStandaloneCycler
    }

    private var tapIsHealthy: Bool {
        guard let tap else { return false }
        return CFMachPortIsValid(tap) && CGEvent.tapIsEnabled(tap: tap)
    }

    func apply(_ settings: HyperKeySettings) {
        appliedSettings = settings
        updateInputStateWatch(enabled: settings.enabled)
        let operationID = nextMappingOperationID()
        guard settings.enabled else {
            stopAndClearMapping(settingState: .disabled)
            return
        }

        let secureInputActive = IsSecureEventInputEnabled()

        guard !secureInputActive else {
            stopAndClearMapping(settingState: .blocked(Self.secureInputBlockedMessage))
            return
        }

        // Standalone Cycler.app owns the same remap and installs its own tap; two hyper providers
        // on one Caps Lock is a guaranteed fight, and its ownership flag would strand the mapping.
        // Same shape as the Raycast block, and it recovers on didBecomeActive once Cycler quits.
        if settings.triggerKey.needsCapsLockRemap, blockedByStandaloneCycler {
            stopAndClearMapping(settingState: .blocked(Self.standaloneCyclerBlockedMessage))
            return
        }

        // Raycast only matters when Lineup also wants Caps Lock; function keys never collide with it.
        if settings.triggerKey.needsCapsLockRemap, Self.raycastCapsHyperEnabled() {
            stopAndClearMapping(settingState: .blocked("Raycast is using Caps Lock"))
            return
        }

        // A physical modifier or function-key trigger needs no HID contribution. Other tools’
        // rules, and external tables, stay under the shared service’s ownership discipline.
        if !settings.triggerKey.needsCapsLockRemap {
            keyboardMappings.setHyperkeyEnabled(false) { _ in }
        }

        start(trigger: settings.triggerKey, includeShift: settings.includeShift, operationID: operationID)
    }

    /// A gate closed: tear the tap down, give the mapping back, and settle on the reason — in ONE
    /// state transition, so the menu and the pill don't flash "disabled" on the way to "blocked".
    private func stopAndClearMapping(settingState newState: State) {
        stop(invalidatingPending: false, settingState: newState)
        keyboardMappings.setHyperkeyEnabled(false) { _ in }
    }

    private func updateInputStateWatch(enabled: Bool) {
        guard enabled else {
            inputStateTimer?.invalidate()
            inputStateTimer = nil
            return
        }
        guard inputStateTimer == nil else { return }
        // `.common` mode, not the default one: a tracking run loop (a menu held open, a window
        // drag) would otherwise stall Secure Input and tap recovery for as long as it lasts.
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.reconcileInputState() }
        }
        timer.tolerance = 0.5
        RunLoop.main.add(timer, forMode: .common)
        inputStateTimer = timer
    }

    private func reconcileInputState() {
        guard appliedSettings.enabled else { return }
        let secureInputActive = IsSecureEventInputEnabled()
        if secureInputActive, state != .blocked(Self.secureInputBlockedMessage) {
            apply(appliedSettings)
        } else if !secureInputActive, state == .blocked(Self.secureInputBlockedMessage) {
            apply(appliedSettings)
        } else if state == .active, tap != nil, !tapIsHealthy {
            // An invalid port cannot deliver a disabled-tap callback. Recover without requiring
            // app activation, while leaving permission-blocked states to their explicit retry.
            resetTriggerState()
            apply(appliedSettings)
        }
    }

    private enum StartResult {
        case started
        case blocked(String)
    }

    private func nextMappingOperationID() -> Int {
        mappingOperationID += 1
        return mappingOperationID
    }

    private func start(trigger: TriggerKey, includeShift: Bool, operationID: Int) {
        // A live tap bound to a different trigger must be torn down so we re-apply the right mapping
        // and watch the right keycode; same-trigger reconfig only needs the live includeShift update.
        if tap != nil, activeTrigger != trigger {
            stop(invalidatingPending: false, settingState: state) // mid-reconfigure: no state flash
        }
        self.includeShift = includeShift

        guard Self.ensureListenEventAccess() else {
            stop(invalidatingPending: false, settingState: .blocked(Self.inputMonitoringBlockedMessage))
            return
        }

        if trigger.needsCapsLockRemap {
            keyboardMappings.setHyperkeyEnabled(true) { [weak self] message in
                guard let self, self.mappingOperationID == operationID else { return }
                if let message {
                    self.stop(invalidatingPending: false, settingState: .blocked(message), releaseMapping: false)
                } else if self.keyboardMappings.hyperkeyReady {
                    self.didApplyMapping = true
                    self.finishStart(self.startTap(trigger: trigger))
                }
            }
            return
        }

        finishStart(startTap(trigger: trigger))
    }

    private func startTap(trigger: TriggerKey) -> StartResult {
        if let tap, !CFMachPortIsValid(tap) {
            // Keep the confirmed keyboard mapping while replacing only the invalid event tap.
            stopTap()
        }
        if let tap {
            // A live tap is not necessarily an ENABLED one: the system disables it on timeout, on
            // a user-input storm, and across sleep. Without this check the wake re-apply — the
            // whole reason `didWakeNotification` is observed — was a no-op and the hyper key
            // stayed dead until the tool was toggled off and on.
            if !CGEvent.tapIsEnabled(tap: tap) {
                resetTriggerState()
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            guard tapIsHealthy else {
                stop(invalidatingPending: false, settingState: state)
                return .blocked("CGEvent.tapEnable failed")
            }
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
            stop(invalidatingPending: false, settingState: state) // finishStart reports the block
            return .blocked("CGEvent.tapCreate failed")
        }

        tap = created
        source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, created, 0)
        if let source {
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        }
        CGEvent.tapEnable(tap: created, enable: true)
        guard tapIsHealthy else {
            stop(invalidatingPending: false, settingState: state)
            return .blocked("CGEvent.tapEnable failed")
        }
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

    func stop() {
        inputStateTimer?.invalidate()
        inputStateTimer = nil
        appliedSettings = .disabled
        stop(invalidatingPending: true)
    }

    /// Sleep can swallow the key-up for a held trigger, so the synthetic ⌃⌥⇧⌘ would stay latched
    /// for the rest of the session — every keystroke arriving as a hyper chord. The wake handler
    /// calls this before re-applying.
    func resetTriggerState() {
        triggerDown = false
        releaseSyntheticModifiers()
    }

    private func stop(invalidatingPending: Bool, settingState newState: State = .disabled, releaseMapping: Bool = true) {
        if invalidatingPending {
            _ = nextMappingOperationID()
        }
        stopTap()

        let hadMapping = didApplyMapping
        didApplyMapping = false
        // Cancellation also removes a contribution whose asynchronous apply has not completed.
        if releaseMapping && (hadMapping || invalidatingPending || keyboardMappings.hyperkeyRequested) {
            keyboardMappings.setHyperkeyEnabled(false) { _ in }
        }
        if state != newState {
            state = newState
        }
    }

    private func stopTap() {
        resetTriggerState()
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let source {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
            CFRunLoopSourceInvalidate(source)
        }
        tap = nil
        source = nil
        activeTrigger = nil
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

    /// Internal, not private: Raycast's own Hyper Key installs the SAME CapsLock->F18 mapping, so
    /// legacy recovery has to ask this before transferring a claim — otherwise Lineup would
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

}

private func hyperKeyControllerTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let controller = Unmanaged<HyperKeyController>.fromOpaque(userInfo).takeUnretainedValue()
    return MainActor.assumeIsolated { controller.handle(type: type, event: event) }
}

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

    static let capsLockHID = CapsLockMapping.capsLockHID
    static let f18HID = CapsLockMapping.f18HID
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
    /// `clearOnExit` and `installedAtexit` are read and written from BOTH the main thread and
    /// `hidutilQueue` (the mapping work runs there, and so does the adoption probe), so they are
    /// behind a lock rather than bare statics.
    private static let staticsLock = NSLock()
    private static var clearOnExitStorage = false
    private static var installedAtexit = false

    private static var clearOnExit: Bool {
        get { staticsLock.withLock { clearOnExitStorage } }
        set { staticsLock.withLock { clearOnExitStorage = newValue } }
    }

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

    /// True when the tap is already live for exactly these settings and the Caps Lock remap (if
    /// this trigger needs one) is already applied — so a re-apply would only re-run the `hidutil`
    /// probe, which is a subprocess. `HyperkeyTool` asks this before its activation-triggered
    /// re-applies; the wake path and every settings edit re-apply regardless.
    ///
    /// Secure Input is deliberately NOT part of this: its own 2s timer owns that transition and
    /// calls `apply()` directly, so gating on it here would only duplicate the check.
    func isSettled(for settings: HyperKeySettings) -> Bool {
        guard settings.enabled, state == .active, tap != nil else { return false }
        guard activeTrigger == settings.triggerKey, includeShift == settings.includeShift else { return false }
        guard settings.triggerKey.needsCapsLockRemap else { return true }
        return didApplyMapping && !blockedByStandaloneCycler
    }

    func apply(_ settings: HyperKeySettings) {
        appliedSettings = settings
        updateSecureInputWatch(enabled: settings.enabled)
        let operationID = nextHidutilOperationID()
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

        // A function-key trigger never uses hidutil; clear only a Caps Lock remap that Lineup knows
        // it created in this or a previous crashed run. A user-owned CapsLock->F18 mapping has the
        // same shape, so shape alone must not be treated as ownership.
        if !settings.triggerKey.needsCapsLockRemap {
            Self.clearKnownOwnedMappingAsync()
        }

        start(trigger: settings.triggerKey, includeShift: settings.includeShift, operationID: operationID)
    }

    /// A gate closed: tear the tap down, give the mapping back, and settle on the reason — in ONE
    /// state transition, so the menu and the pill don't flash "disabled" on the way to "blocked".
    private func stopAndClearMapping(settingState newState: State) {
        stop(invalidatingPending: false, settingState: newState)
        Self.clearKnownOwnedMappingAsync()
    }

    private func updateSecureInputWatch(enabled: Bool) {
        guard enabled else {
            secureInputTimer?.invalidate()
            secureInputTimer = nil
            return
        }
        guard secureInputTimer == nil else { return }
        // `.common` mode, not the default one: a tracking run loop (a menu held open, a window
        // drag) would otherwise stall the Secure Input reconcile for as long as it lasts.
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            self?.reconcileSecureInput()
        }
        timer.tolerance = 0.5
        RunLoop.main.add(timer, forMode: .common)
        secureInputTimer = timer
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
            stop(invalidatingPending: false, settingState: state) // mid-reconfigure: no state flash
        }
        self.includeShift = includeShift

        guard Self.ensureListenEventAccess() else {
            stop(invalidatingPending: false, settingState: .blocked(Self.inputMonitoringBlockedMessage))
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
                    self.stop(invalidatingPending: false, settingState: .blocked(message))
                }
            }
            return
        }

        finishStart(startTap(trigger: trigger))
    }

    private func startTap(trigger: TriggerKey) -> StartResult {
        if let tap {
            // A live tap is not necessarily an ENABLED one: the system disables it on timeout, on
            // a user-input storm, and across sleep. Without this check the wake re-apply — the
            // whole reason `didWakeNotification` is observed — was a no-op and the hyper key
            // stayed dead until the tool was toggled off and on.
            if !CGEvent.tapIsEnabled(tap: tap) {
                CGEvent.tapEnable(tap: tap, enable: true)
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

    /// Sleep can swallow the key-up for a held trigger, so the synthetic ⌃⌥⇧⌘ would stay latched
    /// for the rest of the session — every keystroke arriving as a hyper chord. The wake handler
    /// calls this before re-applying.
    func resetTriggerState() {
        triggerDown = false
        releaseSyntheticModifiers()
    }

    private func stop(invalidatingPending: Bool, settingState newState: State = .disabled) {
        if invalidatingPending {
            _ = nextHidutilOperationID()
        }
        releaseSyntheticModifiers()
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
        triggerDown = false
        activeTrigger = nil

        let hadMapping = didApplyMapping
        didApplyMapping = false
        // `didApplyMapping` is set in the hidutil completion, which `invalidatingPending` has just
        // cancelled — but the background `ensureCapsLockMapping` may already have applied the
        // mapping and recorded ownership. Toggling Hyperkey off inside that window would then
        // leave Caps Lock remapped for the rest of the session with nothing left to clean it up.
        // The clear self-gates on the persisted ownership flag, so asking unconditionally is free.
        if hadMapping || invalidatingPending {
            Self.clearKnownOwnedMappingAsync()
        }
        if state != newState {
            state = newState
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

    /// `hidutil` is a subprocess and every caller is on the main thread (launch, the menu's
    /// recovery probe, the pane's button). Same queue as the mapping work, so a probe queued
    /// before an apply is guaranteed to be answered first.
    static func currentMappingAsync(completion: @escaping (String) -> Void) {
        hidutilQueue.async {
            let mapping = currentMapping()
            DispatchQueue.main.async { completion(mapping) }
        }
    }

    static func isMappingEmpty(_ output: String) -> Bool {
        CapsLockMapping.isEmpty(output)
    }

    /// Shape only — the pair is parsed Src-with-its-own-Dst, so a REVERSED F18 -> Caps Lock
    /// mapping (same two numbers) is never claimed as ours. See `CapsLockMapping`.
    static func isMappingOurs(_ output: String) -> Bool {
        CapsLockMapping.isLineupMapping(output)
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

    /// Off-main variant of `clearIfMappingIsOurs()`, for the pane's "Restore Caps Lock" button.
    static func clearIfMappingIsOursAsync(completion: @escaping (Bool) -> Void) {
        installAtexit()
        hidutilQueue.async {
            let cleared = clearIfMappingIsOurs()
            DispatchQueue.main.async { completion(cleared) }
        }
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

    /// Probe AND adopt in one step on the hidutil queue, so a `start()` that queues its own
    /// mapping work immediately afterwards is guaranteed to see the ownership flag already set.
    /// Splitting the two across a main-thread hop would race with `ensureCapsLockMapping`.
    static func adoptAppliedMappingIfPresentAsync(completion: @escaping (Bool) -> Void) {
        installAtexit()
        hidutilQueue.async {
            let present = isMappingOurs(currentMapping())
            if present { adoptAppliedMapping() }
            DispatchQueue.main.async { completion(present) }
        }
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

    /// How long the exit hook waits for in-flight `hidutil` work before giving up on it.
    private static let atexitDrainTimeout: DispatchTimeInterval = .seconds(3)

    private static func installAtexit() {
        staticsLock.lock()
        let alreadyInstalled = installedAtexit
        installedAtexit = true
        staticsLock.unlock()
        guard !alreadyInstalled else { return }
        atexit {
            // Drain in-flight hidutil work first: quitting right after enabling the hyper key
            // must wait for the remap (and its ownership recording) to finish, or the mapping
            // would outlive the process with no cleanup path.
            //
            // BOUNDED, never a blocking drain of the whole queue: a wedged `hidutil` would
            // otherwise hang quit forever, with no window and no menu bar icon left to explain
            // it. Past the timeout we skip the cleanup rather than hold the process hostage.
            let drained = DispatchSemaphore(value: 0)
            HyperKeyController.hidutilQueue.async { drained.signal() }
            let deadline = DispatchTime.now() + HyperKeyController.atexitDrainTimeout
            guard drained.wait(timeout: deadline) == .success else { return }
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
            // Drain BOTH pipes before waiting. `waitUntilExit()` first would deadlock on any
            // output past the 64KB pipe buffer — the child blocks writing, we block waiting —
            // and the atexit drain would then inherit that wedge. stderr is read concurrently
            // for the same reason: draining it only after stdout has the identical failure mode.
            let errorSink = DataSink()
            let errorRead = DispatchSemaphore(value: 0)
            DispatchQueue.global(qos: .userInitiated).async {
                errorSink.data = err.fileHandleForReading.readDataToEndOfFile()
                errorRead.signal()
            }
            let outputData = out.fileHandleForReading.readDataToEndOfFile()
            errorRead.wait()
            process.waitUntilExit()
            return (process.terminationStatus,
                    String(decoding: outputData, as: UTF8.self),
                    String(decoding: errorSink.data, as: UTF8.self))
        } catch {
            return (127, "", String(describing: error))
        }
    }
}

/// Handoff for the concurrently-read stderr in `runHidutil`: written on the reader queue, read
/// only after its semaphore has been signalled.
private final class DataSink: @unchecked Sendable {
    var data = Data()
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

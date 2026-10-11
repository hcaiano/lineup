import AppKit
import AppCore
import Carbon.HIToolbox
import HyperkeyCore
import SwiftUI

@MainActor private var carbonHandler: EventHandlerUPP?
@MainActor private var carbonRows: [UInt32: (key: Int, modifiers: UInt32)] = [:]
@MainActor private var deliveredID = EventHotKeyID()
@MainActor private var conflictingKeys: Set<Int> = []
@MainActor private var registeredSignatures: [FourCharCode] = []

func GetApplicationEventTarget() -> EventTargetRef! { EventTargetRef(bitPattern: 1) }
@MainActor
func RegisterEventHotKey(_ code: UInt32, _ modifiers: UInt32, _ id: EventHotKeyID,
                         _ target: EventTargetRef?, _ options: OptionBits,
                         _ ref: UnsafeMutablePointer<EventHotKeyRef?>?) -> OSStatus {
    guard !conflictingKeys.contains(Int(code)) else { return -9878 }
    registeredSignatures.append(id.signature)
    carbonRows[id.id] = (Int(code), modifiers)
    ref?.pointee = EventHotKeyRef(bitPattern: UInt(id.id))
    return noErr
}
@MainActor
@discardableResult
func UnregisterEventHotKey(_ ref: EventHotKeyRef?) -> OSStatus {
    if let ref { carbonRows[UInt32(UInt(bitPattern: ref))] = nil }
    return noErr
}
@MainActor
@discardableResult
func InstallEventHandler(_ target: EventTargetRef?, _ handler: EventHandlerUPP?,
                         _ count: Int, _ types: UnsafePointer<EventTypeSpec>?,
                         _ data: UnsafeMutableRawPointer?, _ ref: UnsafeMutablePointer<EventHandlerRef?>?) -> OSStatus {
    precondition(count == 1 && types?.pointee.eventKind == UInt32(kEventHotKeyPressed))
    carbonHandler = handler
    return noErr
}
@MainActor
@discardableResult
func GetEventParameter(_ event: EventRef?, _ name: EventParamName, _ type: EventParamType,
                       _ actualType: UnsafeMutablePointer<EventParamType>?, _ size: Int,
                       _ actualSize: UnsafeMutablePointer<Int>?, _ output: UnsafeMutableRawPointer?) -> OSStatus {
    output?.storeBytes(of: deliveredID, as: EventHotKeyID.self)
    return noErr
}

@MainActor final class PermissionCenter {
    static let shared = PermissionCenter()
    func openInputMonitoringSettings() { fatalError("No permissions may be requested") }
}
@MainActor final class ActivationCoordinator {}
struct MediaKeyScope { let owner: ToolID }
@MainActor final class TerminationCoordinator {
    private var cleanups: [ToolID: () -> Void] = [:]
    func addCleanup(_ id: ToolID, _ action: @escaping () -> Void) { cleanups[id] = action }
    func removeCleanup(_ id: ToolID) { cleanups[id] = nil }
    func terminate() { for action in Array(cleanups.values) { action() } }
}
@MainActor final class KeyboardMappingService {
    static let shared = KeyboardMappingService()
    var hyperkeyReady = false
    var table = ["external mapping", "owned Caps to F18"]
    private var observers: [UUID: () -> Void] = [:]
    func observe(_ action: @escaping () -> Void) -> UUID {
        let id = UUID(); observers[id] = action; return id
    }
    func notify() { for action in Array(observers.values) { action() } }
    func retry() { notify() }
}
@MainActor enum CapsLockHandoff {
    static func adoptLegacyOwnershipIfNeeded(using service: KeyboardMappingService) {}
    static func orphanedMappingDetected(using service: KeyboardMappingService, completion: (Bool) -> Void) { completion(false) }
    static func restoreCapsLock(using service: KeyboardMappingService, completion: (Bool) -> Void) { completion(false) }
}
@MainActor enum SingleInstance {
    static func standaloneCyclerIsRunning() -> NSRunningApplication? { nil }
}
@MainActor final class HyperKeyController {
    enum State: Equatable { case disabled, active, blocked(String) }
    static var latest: HyperKeyController?
    static var initialState = State.blocked("Secure Input")
    var state = State.disabled { didSet { if oldValue != state { onStateChange?(state) } } }
    var onStateChange: ((State) -> Void)?
    var blockedByStandaloneCycler = false
    private var applied = HyperKeySettings.disabled
    init() { Self.latest = self }
    var currentTriggerKeyCode: Int {
        switch applied.triggerKey {
        case .capsLock, .f18: return 79
        case .f1: return 122
        case .f2: return 120
        case .leftControl: return 59
        default: fatalError("Unsupported probe trigger")
        }
    }
    var isBlockedBySecureInput: Bool { state == .blocked("Secure Input") }
    var needsInputMonitoring: Bool { state == .blocked("Input Monitoring permission required") }
    var menuStatus: String? { if case .blocked(let message) = state { return message }; return nil }
    var settingsStatus: String? { menuStatus }
    func useKeyboardMappings(_ service: KeyboardMappingService) {}
    func isSettled(for settings: HyperKeySettings) -> Bool { state == .active && applied == settings }
    func apply(_ settings: HyperKeySettings) { applied = settings; state = Self.initialState }
    func stop() { state = .disabled }
    func resetTriggerState() {}
}
@MainActor enum SecureInputDiagnostics {
    static var samples = 0
    static var name: String? = "Safari"
    static func sample() -> SecureInputDiagnostic { samples += 1; return .init(suspectedAppName: name) }
}
@MainActor final class HyperkeyPaneModel {
    init(tool: HyperkeyTool) {}
    func refresh() {}
}
struct HyperkeySettingsPane: View {
    let model: HyperkeyPaneModel
    var body: some View { EmptyView() }
}
struct HyperkeyQuickPanel: View {
    let trigger: String
    let modifiers: String
    let isActive: Bool
    let warnings: [ToolWarning]
    var body: some View { EmptyView() }
}
@MainActor enum ToolMenu { static func info(_ text: String) -> NSMenuItem { NSMenuItem(title: text, action: nil, keyEquivalent: "") } }

@main struct HyperkeyBlockedAttemptProbe {
    @MainActor static func main() throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        var failures = 0
        var checks = 0
        func expect(_ value: Bool, _ message: String) {
            checks += 1
            if !value { failures += 1; print("FAIL: \(message)") }
        }
        func pump(_ seconds: TimeInterval = 0.2) {
            RunLoop.main.run(until: Date().addingTimeInterval(seconds))
        }
        func deliver(_ id: UInt32) {
            deliveredID = EventHotKeyID(signature: HotkeyManager.signature, id: id)
            _ = carbonHandler?(nil, nil, nil)
        }
        func hyperkeyID() -> UInt32? {
            carbonRows.first { $0.value.modifiers == 0 && [79, 122, 120].contains($0.value.key) }?.key
        }
        func hyperkeyKeys() -> [Int] {
            HotkeyManager.shared.registeredCombos().filter { $0.owner == .hyperkey }.map(\.keyCode).sorted()
        }
        func visiblePanel() -> NSWindow? { NSApp.windows.first { $0 is NSPanel && $0.isVisible } }
        func labels(_ view: NSView) -> [String] {
            (view as? NSTextField).map { [$0.stringValue] } ?? view.subviews.flatMap(labels)
        }

        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("lineup-attempt-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let store = LineupAppConfigStore(url: temporary.appendingPathComponent("config.json"))
        try store.setSettings(HyperKeySettings(enabled: true, triggerKey: .f1), for: .hyperkey)
        let mapping = KeyboardMappingService()
        let originalTable = mapping.table
        let termination = TerminationCoordinator()
        let services = ToolServices(id: .hyperkey, config: .init(owner: .hyperkey, store: store),
            permissions: .shared, activation: ActivationCoordinator(), termination: termination,
            refreshMenu: {}, refreshSettings: {}, peers: { [:] }, keyboardMappings: mapping)
        let tool = HyperkeyTool()
        tool.attach(services)
        expect(hyperkeyKeys().isEmpty && SecureInputDiagnostics.samples == 0, "attaching the disabled caller registers nothing and samples no diagnostics")
        var siblingPresses = 0
        let sibling = HotkeyScope(owner: .zones)
        guard case .success(let siblingToken) = sibling.register(keyCode: 7, modifiers: 256, action: { siblingPresses += 1 }) else { fatalError("Missing sibling token") }
        let siblingID = carbonRows.first { $0.value.key == 7 }!.key
        defer { sibling.unregister(siblingToken) }
        tool.start(services)
        pump()
        let first = hyperkeyID()!
        let panel = visiblePanel()!
        expect(hyperkeyKeys() == [122] && panel.isVisible, "blocked running F1 owns exactly one unmodified scoped registration and shows the native warning")
        expect(registeredSignatures.allSatisfy { $0 == HotkeyManager.signature }, "all registrations use the existing LNUP namespace")
        let samples = SecureInputDiagnostics.samples
        SecureInputDiagnostics.name = "Another App"
        deliver(first)
        pump(4.4)
        expect(!panel.isVisible && SecureInputDiagnostics.samples == samples + 1, "an explicit callback refreshes diagnostics without extending the visible warning past four seconds")
        expect(!tool.warnings.isEmpty && tool.statusText?.contains("Another App") == true, "dismissal leaves persistent menu and Settings status")
        deliver(first)
        pump()
        expect(panel.isVisible && labels(panel.contentView!).contains("Possibly Another App. Details in Lineup Settings."), "a simulated Carbon callback after dismissal reopens the shipping native warning with fresh diagnostics")

        HyperKeyController.latest!.state = .active
        expect(hyperkeyKeys().isEmpty && carbonRows[first] == nil, "recovery synchronously releases the token before another callback")
        let afterRecovery = SecureInputDiagnostics.samples
        deliver(first)
        pump()
        expect(!panel.isVisible && SecureInputDiagnostics.samples == afterRecovery, "a stale callback after recovery cannot show or sample")
        HyperKeyController.latest!.state = .blocked("Secure Input")
        let restarted = hyperkeyID()!
        deliver(first)
        expect(SecureInputDiagnostics.samples == afterRecovery + 1, "the old identity cannot deliver into a new blocked registration")
        tool.setTrigger(.f2)
        let second = hyperkeyID()!
        let beforeOldSetting = SecureInputDiagnostics.samples
        deliver(restarted)
        expect(hyperkeyKeys() == [120] && carbonRows[restarted] == nil && SecureInputDiagnostics.samples == beforeOldSetting, "a settings trigger change releases F1 and rejects its old callback")
        tool.setIncludeShift(false)
        expect(hyperkeyKeys() == [120] && hyperkeyID() == second, "include-Shift edits preserve the single eligible trigger token")
        tool.setTrigger(.leftControl)
        expect(hyperkeyKeys().isEmpty && carbonRows[second] == nil && !tool.warnings.isEmpty, "modifier-only settings register no unrelated chord and retain persistent blocked status")

        tool.setTrigger(.capsLock)
        expect(hyperkeyKeys().isEmpty && mapping.table == originalTable, "pending or unowned preexisting Caps remaps cannot register or claim mapping ownership")
        var capsSiblingPresses = 0
        guard case .success(let capsSiblingToken) = sibling.register(keyCode: 79, modifiers: 0, action: { capsSiblingPresses += 1 }) else { fatalError("Missing Caps sibling token") }
        let capsSiblingID = carbonRows.first { $0.value.key == 79 }!.key
        mapping.hyperkeyReady = true
        mapping.notify()
        deliver(capsSiblingID)
        expect(hyperkeyKeys().isEmpty && capsSiblingPresses == 1 && mapping.table == originalTable,
               "a sibling-owned F18 conflict leaves its registration and mapping ownership untouched")
        sibling.unregister(capsSiblingToken)
        mapping.notify()
        let caps = hyperkeyID()!
        expect(hyperkeyKeys() == [79] && mapping.table == originalTable, "confirmed owned Caps mapping registers F18 without changing any mapping bytes")
        mapping.hyperkeyReady = false
        let beforeInvalidMapping = SecureInputDiagnostics.samples
        deliver(caps)
        expect(SecureInputDiagnostics.samples == beforeInvalidMapping, "callback rechecks mapping readiness even before observer reconciliation")
        mapping.notify()
        expect(hyperkeyKeys().isEmpty && carbonRows[caps] == nil, "loss of confirmed Caps mapping releases the token")
        mapping.hyperkeyReady = true
        mapping.notify()
        let suspendedCaps = hyperkeyID()!
        HotkeyManager.shared.suspendAll()
        deliver(suspendedCaps)
        expect(carbonRows.isEmpty && SecureInputDiagnostics.samples == beforeInvalidMapping, "recorder suspension prevents blocked attempts and native registrations")
        expect(HotkeyManager.shared.resumeAll().isEmpty && carbonRows[suspendedCaps] != nil, "successful recorder resume restores the original scoped token")
        deliver(suspendedCaps)
        expect(SecureInputDiagnostics.samples == beforeInvalidMapping + 1, "resumed registration delivers a new explicit attempt")
        HotkeyManager.shared.suspendAll()
        conflictingKeys.insert(79)
        let restored = HotkeyManager.shared.resumeAll()
        tool.hotkeysFailedToRestore(restored.filter { $0.owner == .hyperkey }.map { .init(keyCode: $0.keyCode, modifiers: $0.modifiers, status: $0.status) })
        let beforeDead = SecureInputDiagnostics.samples
        deliver(suspendedCaps)
        expect(restored.count == 1 && hyperkeyKeys().isEmpty && SecureInputDiagnostics.samples == beforeDead, "resume failure removes the dead owned row and rejects stale delivery")
        deliver(siblingID)
        expect(siblingPresses == 1 && carbonRows[siblingID] != nil, "failure and cleanup preserve sibling shortcuts")
        tool.retry()
        expect(hyperkeyKeys().isEmpty && mapping.table == originalTable, "a Carbon conflict is not advertised as a live observer or resolved by mapping writes")
        conflictingKeys.remove(79)
        tool.retry()
        expect(hyperkeyKeys() == [79], "existing explicit retry restores the attempt observer after a conflict clears")
        tool.stop()
        pump()
        expect(hyperkeyKeys().isEmpty && !panel.isVisible && mapping.table == originalTable, "disable releases the observer and notice without touching mappings or siblings")
        let samplesAfterStop = SecureInputDiagnostics.samples
        deliver(suspendedCaps)
        mapping.notify()
        expect(hyperkeyKeys().isEmpty && SecureInputDiagnostics.samples == samplesAfterStop,
               "mapping notifications and stale callbacks after disable cannot register or sample")
        try store.setSettings(HyperKeySettings(enabled: true, triggerKey: .f1), for: .hyperkey)
        let other = HyperkeyTool()
        other.attach(services)
        HotkeyManager.shared.suspendAll()
        other.start(services)
        expect(hyperkeyKeys() == [122] && carbonRows.isEmpty,
               "starting blocked during recorder suspension owns one deferred row without claiming native delivery")
        expect(HotkeyManager.shared.resumeAll().isEmpty && hyperkeyKeys() == [122],
               "recorder resume installs the deferred blocked-attempt registration")
        let terminated = hyperkeyID()!
        termination.terminate()
        deliver(terminated)
        pump()
        expect(hyperkeyKeys().isEmpty && !panel.isVisible && carbonRows[siblingID] != nil, "termination unregisters before controller cleanup and cannot reopen a warning")
        other.stop()
        expect(mapping.table == originalTable, "all caller paths leave simulated mapping ownership intact")

        HyperKeyController.initialState = .blocked("Input Monitoring permission required")
        let permissionBlocked = HyperkeyTool()
        permissionBlocked.attach(services)
        permissionBlocked.start(services)
        let withoutSecureInput = SecureInputDiagnostics.samples
        deliver(hyperkeyID()!)
        expect(hyperkeyKeys() == [122] && SecureInputDiagnostics.samples == withoutSecureInput
               && permissionBlocked.warnings.first?.actionTitle == "Grant Input Monitoring…",
               "non-Secure-Input blocks can reshow while preserving their permission action and avoiding inactive diagnostics")
        permissionBlocked.stop()

        let eligibleTriggers: Set<TriggerKey> = [.capsLock, .f1, .f2, .f3, .f4, .f5, .f6,
                                                .f7, .f8, .f9, .f10, .f11, .f12, .f18, .f19, .f20]
        for trigger in TriggerKey.allCases {
            let snapshot = HyperkeyBlockedAttemptObserver.Snapshot(isRunning: true, isBlocked: true,
                trigger: trigger, keyCode: 79, capsMappingReady: true)
            expect((snapshot.eligibleKey != nil) == eligibleTriggers.contains(trigger),
                   "eligible trigger \(trigger.rawValue) follows ordinary-key Carbon coverage without unrelated modifier chords")
        }

        print("\(failures == 0 ? "PASS" : "FAIL"): \(checks) shipping blocked-attempt caller/registry/panel checks; Carbon callbacks and controller/mapping are simulated, no physical keystroke or Secure Input proof")
        exit(failures == 0 ? 0 : 1)
    }
}

import AppCore
import CoreGraphics
import Foundation
import HyperkeyCore
import KeyboardRemapCore

@MainActor
final class CFMachPort {
    var valid = true
    var enabled = false
    var deliver: ((CGEventType) -> Void)?
}

final class CFRunLoopSource {}

@MainActor
final class CGEvent {
    static var taps: [CFMachPort] = []
    var flags: CGEventFlags = []

    init() {}

    init?(keyboardEventSource: CGEventSource?, virtualKey: CGKeyCode, keyDown: Bool) {
        fatalError("The Secure Input probe must not synthesize input")
    }

    static func tapCreate(tap: CGEventTapLocation, place: CGEventTapPlacement,
                          options: CGEventTapOptions, eventsOfInterest: CGEventMask,
                          callback: @escaping (CGEventTapProxy, CGEventType, CGEvent, UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>?,
                          userInfo: UnsafeMutableRawPointer?) -> CFMachPort? {
        let port = CFMachPort()
        port.deliver = { type in
            _ = callback(CGEventTapProxy(bitPattern: 1)!, type, CGEvent(), userInfo)
        }
        taps.append(port)
        return port
    }

    static func tapEnable(tap: CFMachPort, enable: Bool) { tap.enabled = enable }
    static func tapIsEnabled(tap: CFMachPort) -> Bool { tap.enabled }
    func getIntegerValueField(_ field: CGEventField) -> Int64 { fatalError("No input is delivered") }
    func setIntegerValueField(_ field: CGEventField, value: Int64) { fatalError("No input is delivered") }
    func post(tap: CGEventTapLocation) { fatalError("No input may be posted") }
}

@MainActor func CFMachPortIsValid(_ port: CFMachPort) -> Bool { port.valid }
@MainActor func CFMachPortInvalidate(_ port: CFMachPort) { port.valid = false }
func CFMachPortCreateRunLoopSource(_ allocator: CFAllocator?, _ port: CFMachPort, _ order: CFIndex) -> CFRunLoopSource? { CFRunLoopSource() }
func CFRunLoopAddSource(_ loop: CFRunLoop?, _ source: CFRunLoopSource?, _ mode: CFRunLoopMode?) {}
func CFRunLoopRemoveSource(_ loop: CFRunLoop?, _ source: CFRunLoopSource?, _ mode: CFRunLoopMode?) {}
func CFRunLoopSourceInvalidate(_ source: CFRunLoopSource) {}

@MainActor private var secureInput = false
@MainActor let IsSecureEventInputEnabled: () -> Bool = { secureInput }
let CGPreflightListenEventAccess: () -> Bool = { true }
let CGRequestListenEventAccess: () -> Bool = { fatalError("No permissions may be requested") }
let CFPreferencesCopyAppValue: (CFString, CFString) -> CFPropertyList? = { _, _ in nil }

@MainActor
final class KeyboardMappingService {
    static let shared = KeyboardMappingService()
    private struct Request {
        let generation: Int
        let enabled: Bool
        let completion: (String?) -> Void
    }
    private var generation = 0
    private var requests: [Request] = []
    private var observers: [UUID: () -> Void] = [:]
    private(set) var hyperkeyRequested = false
    private(set) var hyperkeyReady = false
    var hyperkeyStatus: String? { nil }
    private(set) var table: [KeyMapping] = []
    private var owned: [KeyMapping] = []
    var remappings: [KeyMapping] = []

    func observe(_ callback: @escaping () -> Void) -> UUID {
        let id = UUID()
        observers[id] = callback
        return id
    }
    func removeObserver(_ id: UUID) { observers.removeValue(forKey: id) }

    func setHyperkeyEnabled(_ enabled: Bool, completion: @escaping (String?) -> Void) {
        generation += 1
        hyperkeyRequested = enabled
        hyperkeyReady = false
        requests.append(Request(generation: generation, enabled: enabled, completion: completion))
    }

    func reconcileNextAndDeferCompletion() throws -> (() -> Void)? {
        guard !requests.isEmpty else { return nil }
        let request = requests.removeFirst()
        let plan = try KeyboardMappingPlanner.plan(current: table, owned: owned,
            hyperkey: request.enabled ? KeyMapping(source: 0x700000039, destination: 0x70000006D) : nil,
            remappings: remappings)
        table = plan.table
        owned = plan.owned
        if request.generation == generation {
            hyperkeyReady = request.enabled
            notifyObservers()
        }
        return { request.completion(nil) }
    }

    func drain() throws {
        while let completion = try reconcileNextAndDeferCompletion() { completion() }
    }
    func notifyObservers() { Array(observers.values).forEach { $0() } }
}

@main
struct HyperkeySecureInputProbe {
    @MainActor
    static func main() throws {
        let caps = HyperKeySettings(enabled: true, triggerKey: .capsLock, includeShift: true)
        let capsToF18 = KeyMapping(source: 0x700000039, destination: 0x70000006D)
        let remap = KeyMapping(source: 0x700000064, destination: 0x700000035)
        var failures = 0
        func expect(_ condition: Bool, _ message: String) {
            if !condition { failures += 1; print("FAIL: \(message)") }
        }
        func blocked(_ controller: HyperKeyController) -> Bool {
            if case .blocked(let message) = controller.state { return message.contains("Secure Input") }
            return false
        }
        func hasLiveTap() -> Bool { CGEvent.taps.contains { $0.valid && $0.enabled } }

        let mappings = KeyboardMappingService()
        mappings.remappings = [remap]
        let controller = HyperKeyController()
        controller.useKeyboardMappings(mappings)
        controller.apply(caps)
        try mappings.drain()
        expect(controller.state == .active && hasLiveTap() && mappings.table == [capsToF18, remap],
               "baseline must activate the shipping controller and install Caps Lock to F18 beside Keyboard Remap")

        secureInput = true
        controller.apply(caps)
        expect(blocked(controller) && !hasLiveTap(), "Secure Input must block Hyperkey and tear down its tap")
        expect(mappings.hyperkeyRequested, "Secure Input must retain the Caps Lock remap request; observed false")
        try mappings.drain()
        expect(mappings.table == [capsToF18, remap],
               "Secure Input must keep Caps Lock mapped to F18; observed \(mappings.table)")
        mappings.notifyObservers()
        expect(blocked(controller) && !hasLiveTap(), "a mapping observer must not restart the tap during Secure Input")

        secureInput = false
        controller.apply(caps)
        try mappings.drain()
        expect(controller.state == .active && hasLiveTap() && mappings.table == [capsToF18, remap],
               "leaving Secure Input must restore the tap with the remap intact")
        for type in [CGEventType.tapDisabledByTimeout, .tapDisabledByUserInput] {
            guard let tap = CGEvent.taps.last else { fatalError("The active controller must have a tap") }
            CGEvent.tapEnable(tap: tap, enable: false)
            secureInput = true
            tap.deliver?(type)
            expect(blocked(controller) && !hasLiveTap() && mappings.hyperkeyRequested,
                   "disabled-tap recovery must preserve the map and respect Secure Input for \(type)")
            secureInput = false
            controller.apply(caps)
            try mappings.drain()
            expect(controller.state == .active && hasLiveTap() && mappings.table == [capsToF18, remap],
                   "disabled-tap recovery must resume after Secure Input for \(type)")
        }
        controller.apply(.disabled)
        try mappings.drain()
        expect(controller.state == .disabled && !hasLiveTap() && mappings.table == [remap],
               "disabling Hyperkey must remove only its contribution")

        secureInput = true
        controller.apply(caps)
        try mappings.drain()
        expect(blocked(controller) && !hasLiveTap() && !mappings.hyperkeyRequested && mappings.table == [remap],
               "initial Secure Input startup must not acquire Caps Lock ownership")
        secureInput = false
        controller.apply(caps)
        try mappings.drain()
        expect(controller.state == .active && mappings.table == [capsToF18, remap],
               "initially blocked startup must recover when Secure Input ends")
        secureInput = true
        controller.apply(caps)
        controller.apply(HyperKeySettings(enabled: true, triggerKey: .f18, includeShift: true))
        try mappings.drain()
        expect(blocked(controller) && !hasLiveTap() && !mappings.hyperkeyRequested && mappings.table == [remap],
               "switching away from Caps Lock during Secure Input must release only Hyperkey's contribution")
        controller.stop()
        try mappings.drain()

        secureInput = false
        controller.apply(caps)
        let disabledCompletion = try mappings.reconcileNextAndDeferCompletion()
        expect(controller.state == .active && mappings.table == [capsToF18, remap],
               "deferred completion must begin with an active Caps Lock mapping")
        secureInput = true
        controller.apply(caps)
        controller.apply(.disabled)
        try mappings.drain()
        disabledCompletion?()
        mappings.notifyObservers()
        expect(controller.state == .disabled && !hasLiveTap() && !mappings.hyperkeyRequested && mappings.table == [remap],
               "disable while Secure Input is blocked must release its map and reject stale delivery")

        secureInput = false
        let pendingMappings = KeyboardMappingService()
        pendingMappings.remappings = [remap]
        let pendingController = HyperKeyController()
        pendingController.useKeyboardMappings(pendingMappings)
        pendingController.apply(caps)
        secureInput = true
        pendingController.apply(caps)
        try pendingMappings.drain()
        expect(blocked(pendingController) && !hasLiveTap(),
               "an in-flight mapping completion must not start a tap during Secure Input")
        expect(pendingMappings.table == [capsToF18, remap],
               "Secure Input must retain an in-flight Caps Lock remap; observed \(pendingMappings.table)")
        pendingController.stop()
        try pendingMappings.drain()
        pendingMappings.notifyObservers()
        expect(pendingController.state == .disabled && !hasLiveTap() && !pendingMappings.hyperkeyRequested && pendingMappings.table == [remap],
               "stop while Secure Input is blocked must release only Hyperkey's contribution and stay disabled")

        secureInput = false
        let lateMappings = KeyboardMappingService()
        let lateController = HyperKeyController()
        lateController.useKeyboardMappings(lateMappings)
        lateController.apply(caps)
        let lateCompletion = try lateMappings.reconcileNextAndDeferCompletion()
        expect(lateController.state == .active && hasLiveTap(), "snapshot acceptance must establish the late-callback baseline")
        secureInput = true
        lateController.apply(caps)
        try lateMappings.drain()
        lateCompletion?()
        lateMappings.notifyObservers()
        expect(blocked(lateController) && !hasLiveTap(),
               "a late completion and observer must leave Hyperkey blocked during Secure Input")
        lateController.stop()
        try lateMappings.drain()

        secureInput = false
        let racingMappings = KeyboardMappingService()
        let racingController = HyperKeyController()
        racingController.useKeyboardMappings(racingMappings)
        racingController.apply(caps)
        secureInput = true
        let racingCompletion = try racingMappings.reconcileNextAndDeferCompletion()
        expect(!hasLiveTap(), "a ready observer must recheck Secure Input before creating a tap")
        racingCompletion?()
        expect(!hasLiveTap(), "a mapping completion must recheck Secure Input before creating a tap")
        expect(racingMappings.table == [capsToF18], "a Secure Input race must retain Caps Lock suppression")
        racingController.stop()
        try racingMappings.drain()

        if failures > 0 { print("\(failures) Secure Input regression checks failed"); exit(1) }
        print("PASS: shipping Hyperkey controller retains Caps Lock suppression through Secure Input and asynchronous mapping delivery")
    }
}

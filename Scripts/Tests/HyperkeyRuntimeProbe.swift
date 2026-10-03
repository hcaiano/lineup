import AppKit
import CoreGraphics
import HyperkeyCore

// Compiled with the production controller by `lineup-tests --input-recovery`.
// This opt-in probe owns only an F19 tap and never posts input or writes keyboard maps.
@main
struct HyperkeyRuntimeProbe {
    @MainActor
    static func main() {
        guard CGPreflightListenEventAccess() else {
            print("Input recovery checks require an existing Input Monitoring grant; no permission was requested.")
            exit(1)
        }
        let mappings = KeyboardMappingService(readOnly: true)
        let controller = HyperKeyController()
        controller.useKeyboardMappings(mappings)
        let settings = HyperKeySettings(enabled: true, triggerKey: .f19, includeShift: true)
        var failures = 0
        func expect(_ condition: Bool, _ message: String) {
            if !condition { failures += 1; print("FAIL: \(message)") }
        }
        func currentTap() -> CFMachPort? {
            // Discover the native port by type, without exposing a production test hook.
            guard let value = Mirror(reflecting: controller).children.first(where: {
                type(of: $0.value) == Optional<CFMachPort>.self
            })?.value else { return nil }
            return value as! CFMachPort?
        }
        func waitForRecovery() {
            let deadline = Date(timeIntervalSinceNow: 5)
            while !controller.isSettled(for: settings), Date() < deadline {
                RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
            }
        }
        for (name, invalidate, force) in [
            ("disabled tap", false, false),
            ("invalid tap recovered by the watchdog", true, false),
            ("invalid tap recovered by applying settings", true, true),
        ] {
            controller.apply(settings)
            guard let tap = currentTap(), CFMachPortIsValid(tap), CGEvent.tapIsEnabled(tap: tap) else {
                expect(false, "could not establish the native tap for \(name)")
                break
            }
            if invalidate { CFMachPortInvalidate(tap) }
            else { CGEvent.tapEnable(tap: tap, enable: false) }
            expect(!controller.isSettled(for: settings), "\(name) must not be reported as healthy")
            if force { controller.apply(settings) }
            waitForRecovery()
            let recovered = currentTap().map { CFMachPortIsValid($0) && CGEvent.tapIsEnabled(tap: $0) } ?? false
            expect(recovered && controller.isSettled(for: settings), "\(name) must recover without restarting")
            controller.stop()
        }
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 2.6))
        expect(controller.state == .disabled && currentTap() == nil,
               "disabling Hyperkey must prevent the watchdog from recreating its tap")
        mappings.shutdown()
        if failures > 0 { exit(1) }
        print("Native Hyperkey recovery and shutdown checks passed")
    }
}

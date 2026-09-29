import AppCore
import Foundation
import IOKit.pwr_mgt
import os

final class AwakePowerController: AwakePowerRequests {
    private let log = Logger(subsystem: Product.logSubsystem, category: "awake-power")

    func acquire(_ kind: AwakeRequestKind, timeout: TimeInterval) throws -> UInt32 {
        let type = kind == .system
            ? kIOPMAssertionTypePreventUserIdleSystemSleep : kIOPMAssertionTypePreventUserIdleDisplaySleep
        var id: IOPMAssertionID = 0
        // A system-owned timeout also releases the request if our run loop stalls.
        let result = IOPMAssertionCreateWithDescription(
            type as CFString, "Lineup Keep Awake" as CFString,
            "Timed session started by the user" as CFString, nil, nil,
            timeout, kIOPMAssertionTimeoutActionRelease as CFString, &id)
        guard result == kIOReturnSuccess else { throw PowerError(code: result) }
        return id
    }

    func release(_ id: UInt32) {
        let result = IOPMAssertionRelease(id)
        // NotFound is expected after the system-owned timeout has already released it.
        if result != kIOReturnSuccess && result != kIOReturnNotFound {
            log.error("Could not release Keep Awake request \(id): \(result)")
        }
    }

    private struct PowerError: LocalizedError {
        let code: IOReturn
        var errorDescription: String? { "macOS refused the power request (\(code))." }
    }
}

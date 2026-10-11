import AppKit
import Carbon.HIToolbox
import Darwin
import HyperkeyCore
import IOKit

@MainActor
enum SecureInputDiagnostics {
    static func sample() -> SecureInputDiagnostic {
        guard IsSecureEventInputEnabled() else { return SecureInputDiagnostic() }
        let root = IORegistryGetRootEntry(kIOMainPortDefault)
        guard root != IO_OBJECT_NULL else { return SecureInputDiagnostic() }
        defer { IOObjectRelease(root) }
        let users = IORegistryEntryCreateCFProperty(root, "IOConsoleUsers" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue()
        let pid = SecureInputDiagnostic.suspectedPID(in: users, currentUID: getuid())
        let name = pid.flatMap { NSRunningApplication(processIdentifier: $0)?.localizedName }
        // https://github.com/lionheart/openradar-mirror/issues/21098
        guard IsSecureEventInputEnabled() else { return SecureInputDiagnostic() }
        return SecureInputDiagnostic(suspectedAppName: name)
    }
}

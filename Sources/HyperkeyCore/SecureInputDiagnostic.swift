import CoreFoundation
import Foundation

/// Registry attribution is a hint, not proof of which app enabled Secure Input.
public struct SecureInputDiagnostic: Equatable {
    public let suspectedAppName: String?

    public init(suspectedAppName: String? = nil) {
        let cleaned = suspectedAppName?.unicodeScalars.map {
            CharacterSet.controlCharacters.contains($0) || CharacterSet.whitespacesAndNewlines.contains($0)
                ? " " : String($0)
        }.joined().split(whereSeparator: { $0.isWhitespace }).joined(separator: " ") ?? ""
        self.suspectedAppName = cleaned.isEmpty ? nil : Self.abbreviate(cleaned, limit: 80)
    }

    public var attribution: String {
        suspectedAppName.map { "Possibly \($0)." } ?? "App unknown."
    }

    public var notice: String {
        let hint = suspectedAppName.map { "Possibly \(Self.abbreviate($0, limit: 40))." } ?? "App unknown."
        return "\(hint) Details in Lineup Settings."
    }

    public var recovery: String {
        "Leave password fields first. If it persists, quit and reopen "
            + (suspectedAppName ?? "the app holding Secure Input")
            + ". Hyperkey resumes automatically."
    }

    public var detail: String { "\(attribution) \(recovery)" }

    /// Only one current, on-console session with a valid PID can supply a hint.
    public static func suspectedPID(in consoleUsers: Any?, currentUID: UInt32) -> Int32? {
        guard let sessions = consoleUsers as? [[String: Any]] else { return nil }
        let current = sessions.filter { session in
            guard let onConsole = session["kCGSSessionOnConsoleKey"] as? NSNumber,
                  CFGetTypeID(onConsole) == CFBooleanGetTypeID(), onConsole.boolValue,
                  let uid = integer(session["kCGSSessionUserIDKey"]), uid == Int64(currentUID) else { return false }
            return true
        }
        guard current.count == 1,
              let value = integer(current[0]["kCGSSessionSecureInputPID"]),
              let pid = Int32(exactly: value), pid > 0 else { return nil }
        return pid
    }

    private static func integer(_ value: Any?) -> Int64? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue == Double(number.int64Value) else { return nil }
        return number.int64Value
    }

    private static func abbreviate(_ value: String, limit: Int) -> String {
        value.count > limit ? String(value.prefix(limit - 1)) + "…" : value
    }
}

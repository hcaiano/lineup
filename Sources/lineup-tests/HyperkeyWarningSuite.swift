import Foundation
import HyperkeyCore

func runHyperkeyWarningTests() {
    let known = SecureInputDiagnostic(suspectedAppName: "Safari")
    check(known.notice == "Possibly Safari. Details in Lineup Settings.",
          "Secure Input notice describes a suspected app without claiming attribution")
    check(known.detail == "Possibly Safari. Leave password fields first. If it persists, quit and reopen Safari. Hyperkey resumes automatically.",
          "known app details retain password-field recovery and automatic resumption")
    let unknown = SecureInputDiagnostic()
    check(unknown.notice == "App unknown. Details in Lineup Settings.",
          "unknown Secure Input app keeps a Settings destination")
    check(unknown.detail == "App unknown. Leave password fields first. If it persists, quit and reopen the app holding Secure Input. Hyperkey resumes automatically.",
          "unknown Secure Input details do not invent a password app")
    check(SecureInputDiagnostic(suspectedAppName: " \nSafari\t\u{202E} Browser\0 ").suspectedAppName == "Safari Browser",
          "app labels cannot inject control characters, bidi overrides or extra lines")
    check(SecureInputDiagnostic(suspectedAppName: "\n\t\0").notice == unknown.notice,
          "empty sanitized app names stay unknown")
    let long = SecureInputDiagnostic(suspectedAppName: String(repeating: "x", count: 200))
    check(long.suspectedAppName == String(repeating: "x", count: 79) + "…",
          "diagnostic app labels are bounded so they cannot consume the Settings status")
    check(long.notice == "Possibly " + String(repeating: "x", count: 39) + "…. Details in Lineup Settings.",
          "long app names leave the short notice destination readable")
    check(long.recovery.hasPrefix("Leave password fields first.")
          && long.recovery.hasSuffix("Hyperkey resumes automatically."),
          "long app labels retain the basic recovery instructions")

    func session(uid: Any = 501, onConsole: Any = true, pid: Any = 42) -> [String: Any] {
        ["kCGSSessionUserIDKey": uid, "kCGSSessionOnConsoleKey": onConsole,
         "kCGSSessionSecureInputPID": pid]
    }
    check(SecureInputDiagnostic.suspectedPID(in: [session(), session(uid: 502, pid: 99)], currentUID: 501) == 42,
          "only the current on-console user's Secure Input PID is a candidate")
    for records: Any in [NSNull(), "unreadable", [session(uid: 502)], [session(onConsole: false)],
                         [session(), session(pid: 43)], [session(), session()],
                         [session(), session(pid: 0)]] {
        check(SecureInputDiagnostic.suspectedPID(in: records, currentUID: 501) == nil,
              "missing, other-user, off-console or ambiguous sessions cannot supply an app hint")
    }
    for pid: Any in [0, -1, Int64(Int32.max) + 1, true, "42", 42.5, Double.nan, Double.infinity, NSNull()] {
        check(SecureInputDiagnostic.suspectedPID(in: [session(pid: pid)], currentUID: 501) == nil,
              "a Secure Input PID must be a positive Int32 integer, observed \(pid)")
    }
    for uid: Any in [true, "501", 501.5, -1, UInt64.max] {
        check(SecureInputDiagnostic.suspectedPID(in: [session(uid: uid)], currentUID: 501) == nil,
              "invalid console user identifiers cannot match the current user")
    }
    check(SecureInputDiagnostic.suspectedPID(in: [session(onConsole: 1)], currentUID: 501) == nil,
          "the on-console flag must be an actual boolean")
    check(SecureInputDiagnostic.suspectedPID(in: [session(pid: Int32.max)], currentUID: 501) == Int32.max,
          "the maximum valid positive Int32 PID is accepted")
}

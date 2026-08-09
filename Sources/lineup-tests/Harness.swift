import CoreGraphics
import Foundation

// Minimal, dependency-free assertion harness so the suite runs under Command Line
// Tools (XCTest needs full Xcode). Shared by every suite; main.swift reports the total.
//
// The suites were merged from two runners (lineup's and cycler's), each of which used to
// own this harness at top level. Only one `main.swift` is allowed per SwiftPM target, so
// the harness moved here and each suite became a function.

var failures = 0
var checks = 0

func check(_ cond: Bool, _ name: String) {
    checks += 1
    if !cond {
        failures += 1
        FileHandle.standardError.write(Data("FAIL: \(name)\n".utf8))
    }
}

func eq(_ a: CGFloat, _ b: CGFloat, _ name: String, accuracy: CGFloat = 0.001) {
    check(abs(a - b) <= accuracy, "\(name) (got \(a), want \(b))")
}

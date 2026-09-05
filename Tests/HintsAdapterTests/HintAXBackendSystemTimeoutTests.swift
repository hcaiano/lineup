import ApplicationServices
import XCTest
@testable import lineup
import HintsCore

// ============================================================================
// The settled (Phase 2A remediation) production backend's fail-closed timeout
// stamping, exercised EXACTLY as implemented through the internal seam:
//
//     let backend = SystemHintAXBackend()
//     backend.timeoutInstaller.install = { _ in false }
//
// With a FAILED stamp the backend must issue NO AX message on any path:
// every required read returns `.unknown`, every optional read stays `.unknown`
// (never collapsed to a known absence), the pid query returns nil, and every
// mutation PRIMITIVE returns `.cannotComplete` WITHOUT dispatching — at the
// service layer that maps to an unknown/failed outcome that can never become
// `.applied`/`.succeeded`. The installer is counted: exactly ONE stamp attempt
// per message attempt (composites issue exactly their stamped sub-reads).
//
// Safety: elements are created with `AXUIElementCreateApplication` (an inert
// opaque identity); because every stamp fails first, NO real AX query or
// mutation is ever issued, so no Accessibility permission is consulted or
// needed. Elements are never Lineup's own.
// ============================================================================

final class HintAXBackendSystemTimeoutTests: XCTestCase {

    /// The seam drives the settled stamp-first discipline on inert elements: a failed
    /// stamp blocks every message, and the one-installer-call-per-message-attempt count
    /// is asserted after each block. macOS-only backend; macOS-only test target.
    func testFailedTimeoutStampFailsClosedEverywhereWithoutAnyMessage() {
        let backend = SystemHintAXBackend()
        var installCalls = 0
        backend.timeoutInstaller.install = { _ in
            installCalls += 1
            return false
        }

        // Inert identities only: creation is not an AX message and consults no
        // Accessibility grant.
        let app = AXUIElementCreateApplication(9_900_001)
        let element = AXUIElementCreateApplication(9_900_002)

        // Element acquisition stamps eagerly: exactly one stamp.
        _ = backend.applicationElement(pid: 9_900_003)
        XCTAssertEqual(installCalls, 1)

        // Required reads: unknown (transport failure), exactly one stamp each.
        // (Counts in trailing comments; `installCalls` reached 17 after this block.)
        XCTAssertNil(backend.pid(of: element)) // 2
        XCTAssertTrue(backend.windows(of: app).isUnknown, "the required enumeration fails closed") // 3
        XCTAssertTrue(backend.children(of: element).isUnknown) // 4
        XCTAssertEqual(backend.role(of: element), HintAXRead<String>.unknown) // 5
        XCTAssertEqual(backend.subrole(of: element), HintAXRead<String?>.unknown) // 6
        XCTAssertEqual(backend.enabled(element), HintAXRead<Bool>.unknown) // 7
        XCTAssertEqual(backend.minimized(element), HintAXRead<Bool>.unknown) // 8
        XCTAssertEqual(backend.title(of: element), HintAXRead<String?>.unknown) // 9
        XCTAssertEqual(backend.accessibleDescription(of: element), HintAXRead<String?>.unknown) // 10
        XCTAssertEqual(backend.isFocusedSettable(element), HintAXRead<Bool>.unknown) // 11
        XCTAssertEqual(backend.isValueSettable(element), HintAXRead<Bool>.unknown) // 12
        XCTAssertTrue(backend.frame(of: element, boundary: { true }).isUnknown) // 13

        // Optional reads: a FAILED stamp is a transport failure — `.unknown`, never a
        // known absence; unknown is never collapsed to nil.
        XCTAssertTrue(backend.menuBar(of: app).isUnknown) // 14
        XCTAssertTrue(backend.owningWindow(of: element).isUnknown) // 15
        XCTAssertTrue(backend.parent(of: element).isUnknown) // 16
        XCTAssertTrue(backend.topLevelUIElement(of: element).isUnknown) // 17
        XCTAssertEqual(installCalls, 17, "exactly one stamp per single-message read")

        // Composite helpers, audited per their settled implementation:
        // scrollbars = two stamped optional reads; pageStepper = one stamped children
        // read; scrollCapabilities = one bounded scrollbars walk; numericRange = two
        // stamped optional reads (min then max, both attempted before the result check).
        XCTAssertTrue(backend.scrollbars(of: element, boundary: { true }).isUnknown)
        XCTAssertEqual(installCalls, 17 + 2)
        XCTAssertTrue(backend.pageStepper(of: element, increment: false, boundary: { true }).isUnknown)
        XCTAssertEqual(installCalls, 17 + 3)
        XCTAssertTrue(backend.scrollCapabilities(of: element, boundary: { true }).isUnknown)
        XCTAssertEqual(installCalls, 17 + 5)
        XCTAssertTrue(backend.numericRange(of: element, boundary: { true }).isUnknown)
        XCTAssertEqual(installCalls, 17 + 7)

        // Mutation primitives: a failed stamp returns `.cannotComplete` WITHOUT
        // dispatching — nothing at the service layer can map this into an applied or
        // succeeded dispatch outcome. Exactly one stamp each, no retry.
        XCTAssertEqual(backend.performAction(kAXPressAction as String, on: element), .cannotComplete)
        XCTAssertEqual(backend.setFocused(true, on: element), .cannotComplete)
        XCTAssertEqual(backend.setNumericValue(1, on: element), .cannotComplete)
        XCTAssertEqual(installCalls, 17 + 7 + 3, "exactly one stamp attempt per message attempt")

        // The seam itself was truly exercised from the start (never silently bypassed).
        XCTAssertGreaterThan(installCalls, 0)
    }
}

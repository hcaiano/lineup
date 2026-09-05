import ApplicationServices
import XCTest
@testable import lineup
import HintsCore

/// Direct, deterministic traversal-level evidence (Gate 3 evidence C, focused part):
/// cancellation publishes nothing and the serialized generation cleanup removes the
/// minted repository payload; unknown subrole admission fails closed with no candidate.
final class HintAXTraversalTests: XCTestCase {

    private let factory = SequentialTokenFactory()
    private let backend = StubAXBackend()
    private let clock = FixedClock()
    private let key = HintSessionKey(id: 21, generation: 0)
    private let targetPid: Int32 = StubSeams.targetPid()

    /// A single-window fixture whose one child is a pressable button.
    private func buttonRoot(buttonConfig: (StubNode) -> Void) -> AXUIElement {
        let app = backend.makeApplication(pid: targetPid)
        let window = backend.makeRoot(under: app, role: "AXGroup", kind: .window)
        _ = backend.makeChild(under: window, configure: buttonConfig)
        return window
    }

    private func run(
        _ window: AXUIElement, repository: HintAXTokenRepository,
        key: HintSessionKey, limits: HintScanLimits = .standard,
        clock: HintScanClock, wallDeadlineMs: Int64 = 750, shouldAbort: @escaping () -> Bool
    ) -> HintAXTraversalOutcome? {
        HintAXTraversal.run(
            roots: [(window, HintAXRootID(factory.mint()))],
            repository: repository,
            key: key, limits: limits, clock: clock, wallDeadlineMs: wallDeadlineMs,
            screens: StubSeams.screens, backend: backend,
            tokenFactory: factory, targetPid: targetPid, lineupPid: 1,
            shouldAbort: shouldAbort
        )
    }

    func testMidScanCancellationPublishesNothingAndCleanupRemovesPayload() {
        let window = buttonRoot(
            buttonConfig: { node in
                node.role = .value(kAXButtonRole as String)
                node.actionNames = .value([kAXPressAction as String])
            }
        )
        let repository = HintAXTokenRepository()
        // Cancel deterministically at the boundary right after the root node's role read:
        // the root token has already been minted into the repository.
        let outcome = run(
            window, repository: repository, key: key, clock: clock,
            shouldAbort: { self.backend.axMessageCount >= 2 }
        )
        XCTAssertNil(outcome, "a cancelled scan has NO published result")
        XCTAssertEqual(repository.count, 1, "exactly the root token was minted before the abort")
        // THE cleanup contract: one serialized exact-key release drops the whole payload.
        XCTAssertEqual(repository.release(fullKey: key), 1)
        XCTAssertEqual(repository.count, 0)
        // Idempotent.
        XCTAssertEqual(repository.release(fullKey: key), 0)
    }

    func testImmediatelyCancelledTraversalMintsNothing() {
        let window = buttonRoot(buttonConfig: { _ in })
        let repository = HintAXTokenRepository()
        let outcome = run(window, repository: repository, key: key, clock: clock, shouldAbort: { true })
        XCTAssertNil(outcome)
        XCTAssertEqual(repository.count, 0, "cancel before any AX message mints no payload")
    }

    func testUnknownSubroleYieldsNoCandidate() {
        let window = buttonRoot(
            buttonConfig: { node in
                node.role = .value(kAXButtonRole as String)
                node.subrole = .unknown // transport/decoding failure: fail closed
                node.actionNames = .value([kAXPressAction as String])
            }
        )
        let repository = HintAXTokenRepository()
        guard let outcome = run(
            window, repository: repository, key: key, clock: clock, shouldAbort: { false }
        ) else { return XCTFail("no cancellation here") }
        XCTAssertTrue(outcome.candidates.isEmpty, "unknown subrole is never collapsed to a candidate")
        XCTAssertEqual(outcome.discoveredCandidates, 0)
        // Traversal continuity: the subtree was still walked, the candidate admission
        // alone failed closed — root plus the walked child both minted tokens.
        XCTAssertEqual(repository.count, 2)
    }

    func testWallClockBudgetBreaksWithCountOnlyTruncation() {
        let window = buttonRoot(
            buttonConfig: { node in
                node.role = .value(kAXButtonRole as String)
                node.actionNames = .value([kAXPressAction as String])
            }
        )
        // Deadline already passed at the first frontier boundary: count-only truncation
        // with nothing to publish as candidates.
        guard let outcome = run(
            window, repository: HintAXTokenRepository(), key: key,
            clock: FixedClock(value: 800), wallDeadlineMs: 750, shouldAbort: { false }
        ) else { return XCTFail("deadline is truncation, not cancellation") }
        XCTAssertTrue(outcome.candidates.isEmpty)
        XCTAssertTrue(outcome.truncationReasons.contains(.wallClockExceeded))
    }
}

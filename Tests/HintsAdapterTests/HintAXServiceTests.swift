import ApplicationServices
import XCTest
@testable import lineup
import HintsCore

/// Service-level, fully deterministic Gate 3 evidence (C + D): a complete stub seam
/// (no Accessibility permission, no real AX state, inert `AXUIElement` identities only)
/// drives `captureContext → adoptCapture → scan → invoke` end to end.
final class HintAXServiceTests: XCTestCase {

    // MARK: Harness

    /// Per-test harness: fresh service, backend, clock, tokens, and fixture key. The
    /// registry inside the service is per-instance, so tests never interfere.
    private final class Harness {
        let backend: StubAXBackend
        let clock: TripClock
        let service: HintAXService
        let targetPid: Int32
        let key = HintSessionKey(id: 7, generation: 0)
        let screens = StubSeams.screens

        init(limits: HintScanLimits = .standard) {
            let pid = StubSeams.targetPid()
            let seam = StubAXBackend()
            let seamClock = TripClock(backend: seam)
            self.backend = seam
            self.clock = seamClock
            self.targetPid = pid
            self.service = HintAXService(
                limits: limits,
                backend: seam,
                frontmost: FixedFrontmost(pid: pid),
                tokenFactory: SequentialTokenFactory(),
                clock: seamClock
            )
        }

        /// One window root with `count` pressable button children (distinct frames,
        /// deterministic reading order). No menu bar (a known absence is acceptable).
        @discardableResult
        func makeGraph(buttons: Int, subroleUnknown: Bool = false) -> AXUIElement {
            let app = backend.makeApplication(pid: targetPid)
            let window = backend.makeRoot(under: app, role: "AXGroup", kind: .window)
            for index in 0..<buttons {
                _ = backend.makeChild(under: window) { node in
                    StubSeams.pressButtonConfig(pid: self.targetPid)(node)
                    node.frame = CGRect(x: 10 + index * 40, y: 10, width: 30, height: 20)
                    if subroleUnknown { node.subrole = .unknown }
                }
            }
            return window
        }

        /// captureContext + adoptCapture for the fresh generation-0 key.
        func captureAndAdopt() async -> HintCapturedContext? {
            guard let captured = await service.captureContext(
                targetPid: targetPid, screens: screens
            ) else { return nil }
            guard await service.adoptCapture(
                id: captured.pendingID, for: key, matching: captured.context
            ) else { return nil }
            return captured
        }

        /// scan(plan:) pinned to the service's own limits (exact-gate requirement).
        func scan(captured: HintCapturedContext, key: HintSessionKey) async -> HintScanResult? {
            await service.scan(plan: HintScanPlan(
                key: key, context: captured.context, limits: service.limits
            ))
        }
    }

    // MARK: Happy path + at-most-once dispatch

    func testAdoptScanInvokeHappyPathDispatchesExactlyOnce() async {
        let harness = Harness()
        harness.makeGraph(buttons: 1)
        guard let captured = await harness.captureAndAdopt() else {
            return XCTFail("capture and adoption must succeed for the stub fixture")
        }
        guard let result = await harness.scan(captured: captured, key: harness.key) else {
            return XCTFail("the scan must publish for the exact active key")
        }
        XCTAssertEqual(result.candidates.count, 1)
        XCTAssertEqual(result.candidates.first?.role, .button)
        XCTAssertEqual(result.candidates.first?.advertisedActions, [.press])
        XCTAssertEqual(result.summary.retainedCandidates, 1)

        let outcome = await harness.service.invoke(
            token: result.candidates[0].token, action: .press, key: harness.key
        )
        XCTAssertEqual(outcome, .succeeded)
        XCTAssertEqual(harness.backend.dispatchCount, 1, "an advertised action dispatches exactly once")
        await harness.service.stop()
    }

    func testCannotCompleteYieldsUnknownOutcomeWithoutRetry() async {
        let harness = Harness()
        harness.makeGraph(buttons: 1)
        guard let captured = await harness.captureAndAdopt() else {
            return XCTFail("capture and adoption must succeed")
        }
        guard let result = await harness.scan(captured: captured, key: harness.key) else {
            return XCTFail("the scan must publish")
        }
        harness.backend.nextDispatchError = .cannotComplete
        let outcome = await harness.service.invoke(
            token: result.candidates[0].token, action: .press, key: harness.key
        )
        XCTAssertEqual(outcome, .unknownOutcome, "cannotComplete is an unknown outcome, never retried")
        XCTAssertEqual(harness.backend.dispatchCount, 1, "exactly one dispatch attempt, no retry")
        await harness.service.stop()
    }

    // MARK: Candidate matrix evidence through the service

    func testUnknownSubroleYieldsNoCandidatesAtServiceLevel() async {
        let harness = Harness()
        harness.makeGraph(buttons: 1, subroleUnknown: true)
        guard let captured = await harness.captureAndAdopt() else {
            return XCTFail("capture and adoption must succeed")
        }
        guard let result = await harness.scan(captured: captured, key: harness.key) else {
            return XCTFail("the scan itself is not cancelled")
        }
        XCTAssertTrue(result.candidates.isEmpty, "an unknown subrole must not produce a candidate")
        XCTAssertEqual(result.summary.discoveredCandidates, 0)
        XCTAssertEqual(result.summary.retainedCandidates, 0)
        await harness.service.stop()
    }

    func testCandidateCapAfterRankWhileSummaryPreservesPreCapCounts() async {
        let limits = HintScanLimits(maxCandidates: 2)
        let harness = Harness(limits: limits)
        harness.makeGraph(buttons: 5)
        guard let captured = await harness.captureAndAdopt() else {
            return XCTFail("capture and adoption must succeed")
        }
        guard let result = await harness.scan(captured: captured, key: harness.key) else {
            return XCTFail("the scan must publish")
        }
        // Rank-before-cap: only maxCandidates reach the published list…
        XCTAssertEqual(result.candidates.count, limits.maxCandidates)
        // …while the count-only summary preserves the larger pre-cap picture.
        XCTAssertEqual(result.summary.discoveredCandidates, 5)
        XCTAssertEqual(result.summary.acceptedCandidates, 5)
        XCTAssertEqual(result.summary.retainedCandidates, limits.maxCandidates)
        XCTAssertTrue(result.summary.truncationReasons.contains(.candidateCapReached))
        await harness.service.stop()
    }

    // MARK: Capture deadline at the final publication recheck (fix 3)

    func testCaptureDeadlineAtFinalPublicationPublishesNothing() async {
        let harness = Harness()
        harness.makeGraph(buttons: 1)
        // Expire deterministically right AFTER the last pre-publication AX message (the
        // menu-bar lookup, the 7th and final AX message of this fixture): the capture's
        // boundary recheck at publication must fail CLOSED — neither isStopped alone nor
        // anything else publishes. No earlier boundary can explain the nil: every one of
        // them runs while fewer than 7 AX messages have been recorded.
        harness.clock.trip = { $0.axMessages >= 7 }
        let expiredCapture = await harness.service.captureContext(
            targetPid: harness.targetPid, screens: StubSeams.screens
        )
        XCTAssertNil(
            expiredCapture,
            "a deadline-expired capture publishes no pending state"
        )
        // The expired capture is clean: disarming the clock lets an identical capture
        // publish, proving the nil came from the deadline and not the fixture.
        harness.clock.disarm()
        guard let captured = await harness.service.captureContext(
            targetPid: harness.targetPid, screens: StubSeams.screens
        ) else { return XCTFail("the fixture itself must capture cleanly") }
        XCTAssertEqual(captured.context.pid, harness.targetPid)
        await harness.service.stop()
    }

    // MARK: Adoption deadline at the final publication recheck (fix 3)

    func testAdoptionDeadlineAtFinalPublicationRejectsThenIdempotentRetryAdopts() async {
        let harness = Harness()
        harness.makeGraph(buttons: 1)
        guard let captured = await harness.service.captureContext(
            targetPid: harness.targetPid, screens: StubSeams.screens
        ) else { return XCTFail("the fixture must capture cleanly (clock armed later)") }

        // Expire the adoption exactly at its FINAL publication recheck. Re-audited
        // against the settled adoption path: the fixture's capture issues 7 AX messages
        // and the single-window adoption issues 4 more (pid/role/minimized/frame). The
        // adoption's clock reads are: deadline init (1) + the seven per-window-root
        // boundary checks (2–8: before pid, before/after role, before/after minimized,
        // before/after frame) + the final publication recheck (9). The trip is armed
        // at calls >= 9 with ALL 11 messages already issued, so it fires exactly at the
        // publication guard — after every per-root boundary (call 8) and the frame read,
        // but before any session mutation. Both counters are asserted so any fixture
        // drift fails loudly, not silently.
        harness.clock.restartCounter()
        harness.clock.trip = { $0.calls >= 9 && $0.axMessages >= 7 + 4 }
        let rejected = await harness.service.adoptCapture(
            id: captured.pendingID, for: harness.key, matching: captured.context
        )
        XCTAssertFalse(rejected, "a deadline-expired adoption never publishes")
        XCTAssertEqual(harness.clock.callCount, 9, "clock reads stop at the final publication recheck")
        XCTAssertEqual(harness.backend.axMessageCount, 11)

        // A failed NON-cancelled validation retains the pending capture; the same exact
        // key binds idempotently and adoption succeeds on retry.
        harness.clock.disarm()
        let adopted = await harness.service.adoptCapture(
            id: captured.pendingID, for: harness.key, matching: captured.context
        )
        XCTAssertTrue(adopted, "idempotent exact-key retry adopts after the deadline cleared")
        await harness.service.stop()
    }

    // MARK: Exact-key regression (fix 1 + D)

    func testStaleKeyReleasesCannotDestroyAdvancedKeyState() async {
        let harness = Harness()
        harness.makeGraph(buttons: 1)
        guard let captured = await harness.captureAndAdopt() else {
            return XCTFail("capture and adoption must succeed")
        }
        guard let generation0 = await harness.scan(captured: captured, key: harness.key) else {
            return XCTFail("generation 0 must scan")
        }
        // Authorized release: advances the binding to key1 (serialized cleanup releases
        // exactly generation 0).
        await harness.service.releaseGeneration(harness.key)
        let key1 = harness.key.nextGeneration

        // STALE releases under key0: neither may destroy the advanced key's context,
        // targets, snapshot, roots, or active binding.
        await harness.service.releaseSession(harness.key)
        await harness.service.releaseGeneration(harness.key)

        // key1 remains fully invokable: scan and invoke against the exact key1.
        guard let generation1 = await harness.scan(captured: captured, key: key1) else {
            return XCTFail("key1 must remain scannable after stale releases")
        }
        XCTAssertEqual(generation1.candidates.count, generation0.candidates.count)
        let outcome = await harness.service.invoke(
            token: generation1.candidates[0].token, action: .press, key: key1
        )
        XCTAssertEqual(outcome, .succeeded, "key1's targets survived every stale release")
        XCTAssertEqual(harness.backend.dispatchCount, 1)
        await harness.service.stop()
    }
}

import ApplicationServices
import XCTest
@testable import lineup
import HintsCore

// ============================================================================
// Gate 3 contract pins through the service with the injected stub backend:
//
//   * Invocation's live ancestry proof must reach the token's STORED
//     provenance root — not merely any retained root — so a surface
//     reparented under a different retained root fails closed (settled
//     production: the graph walk + exact-root comparison enforce this).
//   * The mutation gate (generation snapshot equality) must fail closed on
//     ANY window-set change after the scan, INCLUDING participation/ sponsor
//     drift that leaves the identity set unchanged (settled production: the
//     complete transient participation classification rides the snapshot).
//   * Scroll dispatch is at most once with no retry; `.unknownOutcome` leaves
//     the generation reusable; unsupported operations never dispatch.
//   * An authorized mid-scan release cancels the scan deterministically (via
//     a one-shot backend hook + semaphore), publishes nothing, and the
//     serialized cleanup leaves the next generation scannable.
//   * The candidate cap keeps the RANKED head (y, then x), not the
//     discovery-order head, and pruned tokens are inert without AX traffic.
//
// Safety: inert AXUIElement identities only, stub-table answers only, all
// stub mutations strictly happen-after an awaited service step.
// ============================================================================

final class HintAXLifecycleContractTests: XCTestCase {

    // MARK: Harness (same discipline as HintAXServiceTests.Harness)

    private final class Harness {
        let backend: StubAXBackend
        let clock: TripClock
        let service: HintAXService
        let targetPid: Int32
        let key = HintSessionKey(id: 9, generation: 0)
        let screens = StubSeams.screens
        /// ONE application element per fixture: all windows live under it, matching what
        /// the captured session is validated against.
        let app: AXUIElement

        init(limits: HintScanLimits = .standard) {
            let pid = StubSeams.targetPid()
            let seam = StubAXBackend()
            let seamClock = TripClock(backend: seam)
            self.backend = seam
            self.clock = seamClock
            self.targetPid = pid
            self.app = seam.makeApplication(pid: pid)
            self.service = HintAXService(
                limits: limits,
                backend: seam,
                frontmost: FixedFrontmost(pid: pid),
                tokenFactory: SequentialTokenFactory(),
                clock: seamClock
            )
        }

        /// One window root under the fixture application with `buttons` pressable children
        /// (distinct frames, deterministic child order).
        @discardableResult
        func makeWindow(
            role: String = "AXGroup",
            minimized: Bool = false,
            buttons: [(x: CGFloat, y: CGFloat)] = []
        ) -> (window: AXUIElement, buttons: [AXUIElement]) {
            let window = backend.makeRoot(
                under: app, role: role, kind: .window
            ) { node in
                node.minimized = .value(minimized)
                node.frame = StubSeams.onscreenFrame
            }
            var buttonElements: [AXUIElement] = []
            for point in buttons {
                let element = backend.makeChild(under: window) { child in
                    StubSeams.pressButtonConfig(pid: self.targetPid)(child)
                    child.frame = CGRect(x: point.x, y: point.y, width: 30, height: 20)
                }
                buttonElements.append(element)
            }
            return (window, buttonElements)
        }

        func captureAndAdopt() async -> HintCapturedContext? {
            guard let captured = await service.captureContext(
                targetPid: targetPid, screens: screens
            ) else { return nil }
            guard await service.adoptCapture(
                id: captured.pendingID, for: key, matching: captured.context
            ) else { return nil }
            return captured
        }

        func scan(captured: HintCapturedContext, key: HintSessionKey) async -> HintScanResult? {
            await service.scan(plan: HintScanPlan(
                key: key, context: captured.context, limits: service.limits
            ))
        }

        func nextKey(after key: HintSessionKey) -> HintSessionKey { key.nextGeneration }

        /// Deterministic "cut between consecutive reads" (no concurrency): the trip clock
        /// starts failing every boundary check once `delta` FURTHER AX messages have been
        /// issued on the serial executor, so a fixed mutation/classification sequence is
        /// cut after exactly that many subsequent messages. Cancellation landing elsewhere
        /// is covered by the hook-interleaved release tests below; this seam proves the
        /// NO-next-message contract with counters only.
        @discardableResult
        func armBoundaryCut(afterAnotherMessages delta: Int) -> Int {
            let baseline = backend.axMessageCount
            clock.trip = { $0.axMessages >= baseline + delta }
            return baseline
        }
    }

    // MARK: Reparenting across retained roots (exact provenance-root contract)

    /// Pinned (settled production): the invocation's ancestry proof must reach the
    /// token's STORED provenance root. The candidate's provenance root is window A, but
    /// after the scan its chain is rewired to reach window B — ALSO retained. Production's
    /// graph walk (`uniqueRetainedRoot` + exact-root comparison) must reject with NO AX
    /// mutation.
    func testReparentingAcrossRetainedRootsRejectsInvocation() async {
        let harness = Harness()
        let first = harness.makeWindow(buttons: [(x: 10, y: 10)])
        let second = harness.makeWindow(buttons: [])
        guard let captured = await harness.captureAndAdopt() else {
            return XCTFail("capture and adoption must succeed")
        }
        guard let result = await harness.scan(captured: captured, key: harness.key) else {
            return XCTFail("the scan must publish for the exact active key")
        }
        guard let token = result.candidates.first?.token else {
            return XCTFail("the scan must retain the reparented candidate")
        }
        // Rewire the surface's provenance: its parent chain now reaches root B, which is
        // ALSO retained. Window-set membership, roles, minimized state, and geometry stay
        // identical, so only the provenance-root rule can explain the outcome below.
        harness.backend.node(first.buttons[0]).parent = .value(second.window)
        let outcome = await harness.service.invoke(token: token, action: .press, key: harness.key)
        XCTAssertEqual(
            outcome, .failed,
            "an ancestry proof reaching a root OTHER than the provenance root must fail closed"
        )
        XCTAssertEqual(harness.backend.dispatchCount, 0, "reparenting drift must never dispatch")
        await harness.service.stop()
    }

    // MARK: Snapshot drift — window-set changes after the scan

    /// Pinned (already enforced): a NON-minimized window appearing in the enumeration after
    /// the scan grows the identity set; the invocation must fail closed with zero AX
    /// mutations.
    func testWindowAppearingAfterScanFailsInvocationClosed() async {
        let harness = Harness()
        _ = harness.makeWindow(buttons: [(x: 10, y: 10)])
        guard let captured = await harness.captureAndAdopt() else {
            return XCTFail("capture and adoption must succeed")
        }
        guard let result = await harness.scan(captured: captured, key: harness.key) else {
            return XCTFail("the scan must publish")
        }
        guard let token = result.candidates.first?.token else {
            return XCTFail("the scan must retain the candidate")
        }
        // A new visible window joins the enumeration after the scan.
        _ = harness.backend.addWindow(to: harness.app)
        let outcome = await harness.service.invoke(token: token, action: .press, key: harness.key)
        XCTAssertEqual(outcome, .failed, "any window-set growth after the scan fails closed")
        XCTAssertEqual(harness.backend.dispatchCount, 0, "drift must never reach a dispatch")
        await harness.service.stop()
    }

    /// Pinned (already enforced): a participating window LEAVING the enumeration after the
    /// scan shrinks the identity set; the invocation on the surviving window's token must
    /// still fail closed — "my own window is fine" is not the test.
    func testWindowDisappearingAfterScanFailsInvocationClosed() async {
        let harness = Harness()
        _ = harness.makeWindow(buttons: [(x: 10, y: 10)])
        let other = harness.makeWindow(buttons: [])
        guard let captured = await harness.captureAndAdopt() else {
            return XCTFail("capture and adoption must succeed")
        }
        guard let result = await harness.scan(captured: captured, key: harness.key) else {
            return XCTFail("the scan must publish")
        }
        guard let token = result.candidates.first?.token else {
            return XCTFail("the scan must retain the candidate")
        }
        // The OTHER window closes: the fresh enumeration loses an entry.
        harness.backend.removeWindow(other.window)
        let outcome = await harness.service.invoke(token: token, action: .press, key: harness.key)
        XCTAssertEqual(outcome, .failed, "any window-set shrink after the scan fails closed")
        XCTAssertEqual(harness.backend.dispatchCount, 0)
        await harness.service.stop()
    }

    /// Pinned (settled production, corrected fixture): a minimized surface with a VALID
    /// retained-root attachment (its upward owner link reaches root A from creation) is
    /// recorded at scan as `admitted=false, sponsor=nil`. Flipping it to participating —
    /// same AX identity, SAME enumeration membership, SAME valid attachment — changes the
    /// participation record to `admitted=true, sponsor=A`, so the snapshot equality at the
    /// mutation gate fails by PARTICIPATION DRIFT, demonstrably not by missing ancestry.
    func testMinimizedToParticipatingFlipFailsViaParticipationSnapshotDrift() async {
        let harness = Harness()
        let live = harness.makeWindow(buttons: [(x: 10, y: 10)])
        // The transient is minimized at capture (so it is NOT a baseline root) and carries
        // a valid owner link to root A the whole time; ancestry is never the failure cause.
        let transient = harness.backend.addWindow(to: harness.app, minimized: true)
        harness.backend.node(transient).owningWindow = .value(live.window)
        guard let captured = await harness.captureAndAdopt() else {
            return XCTFail("capture and adoption must succeed (a minimized enumeration entry is legal)")
        }
        guard let result = await harness.scan(captured: captured, key: harness.key) else {
            return XCTFail("the scan must publish (the minimized transient is skipped, not fatal)")
        }
        guard let token = result.candidates.first?.token else {
            return XCTFail("the scan must retain the candidate")
        }
        // Same enumeration membership, same proven attachment — only the participation
        // state flips from skipped to admitted.
        harness.backend.node(transient).minimized = .value(false)
        let outcome = await harness.service.invoke(token: token, action: .press, key: harness.key)
        XCTAssertEqual(
            outcome, .failed,
            "a minimized→participating flip must fail the mutation gate via participation snapshot drift"
        )
        XCTAssertEqual(harness.backend.dispatchCount, 0)
        await harness.service.stop()
    }

    /// Pinned (settled production): a transient ADMITTED with sponsor root A at scan keeps
    /// the same AX identity but is re-attached under retained root B after the scan; the
    /// fresh participation record (admitted, sponsor=B) differs from the stored one
    /// (admitted, sponsor=A), so the mutation fails closed before any dispatch.
    func testTransientSponsorChangeToAnotherRetainedRootFailsClosed() async {
        let harness = Harness()
        let first = harness.makeWindow(buttons: [(x: 10, y: 10)])
        let second = harness.makeWindow(buttons: [])
        // Minimized at capture (not a baseline root); visible under root A at scan.
        let transient = harness.backend.addWindow(to: harness.app, minimized: true)
        harness.backend.node(transient).owningWindow = .value(first.window)
        // The transient carries its own pressable child so a token minted under the
        // BORROWED sponsor root A exists to be invoked after the sponsor drifts.
        _ = harness.backend.makeChild(under: transient) { child in
            StubSeams.pressButtonConfig(pid: harness.targetPid)(child)
            child.frame = CGRect(x: 10, y: 40, width: 30, height: 20)
        }
        guard let captured = await harness.captureAndAdopt() else {
            return XCTFail("capture and adoption must succeed")
        }
        harness.backend.node(transient).minimized = .value(false)
        guard let result = await harness.scan(captured: captured, key: harness.key) else {
            return XCTFail("the scan must publish with the transient admitted under root A")
        }
        XCTAssertEqual(result.candidates.count, 2)
        // Select the transient's candidate by fixture identity (its distinctive
        // y=40 frame anchors it against the retained window's y=10 button), then use
        // the ACTUAL returned token for the mutation — no raw-token arithmetic.
        guard let transientCandidate = result.candidates.first(where: { $0.frame.minY == 40 }) else {
            return XCTFail("the transient's button must be retained under root A")
        }
        // Same AX identity, exact sponsor drift: the transient now reaches root B only.
        harness.backend.node(transient).owningWindow = .value(second.window)
        let outcome = await harness.service.invoke(
            token: transientCandidate.token, action: .press, key: harness.key
        )
        XCTAssertEqual(outcome, .failed, "an exact sponsor change fails closed even with unchanged identity")
        XCTAssertEqual(harness.backend.dispatchCount, 0)
        await harness.service.stop()
    }

    // MARK: Scroll matrix at the service level

    /// A window containing one AXScrollArea region with a vertical scrollbar and both
    /// increment/decrement freshly advertised (the up/down scroll lane's happy geometry).
    private func makeScrollHarness() -> (Harness, AXUIElement, AXUIElement) {
        let harness = Harness()
        let window = harness.backend.makeRoot(under: harness.app, role: "AXGroup", kind: .window)
        let region = harness.backend.makeChild(under: window) { node in
            node.pid = harness.targetPid
            node.role = .value(kAXScrollAreaRole as String)
            node.subrole = .value(nil)
            node.enabled = .value(true)
            node.frame = StubSeams.onscreenFrame
            node.actionNames = .value([])
        }
        let bar = harness.backend.makeChild(under: region) { node in
            node.pid = harness.targetPid
            node.role = .value("AXScrollBar")
            node.actionNames = .value([kAXDecrementAction as String, kAXIncrementAction as String])
        }
        harness.backend.node(region).scrollbars = (bar, nil)
        harness.backend.node(region).scrollCapabilities = [.down, .up]
        return (harness, window, region)
    }

    func testScrollCannotCompleteIsUnknownOutcomeWithSingleDispatchThenReusable() async {
        let (harness, _, _) = makeScrollHarness()
        guard let captured = await harness.captureAndAdopt() else {
            return XCTFail("capture and adoption must succeed")
        }
        guard let result = await harness.scan(captured: captured, key: harness.key) else {
            return XCTFail("the scan must publish the scroll region")
        }
        guard let scrollToken = result.candidates.first(where: { $0.role == .scrollRegion })?.token else {
            return XCTFail("the scroll region must be retained with a .scroll advertisement")
        }
        harness.backend.nextDispatchError = .cannotComplete
        let first = await harness.service.scroll(token: scrollToken, operation: .down, key: harness.key)
        XCTAssertEqual(first, .unknownOutcome, "cannotComplete dispatches once and reports an unknown outcome")
        XCTAssertEqual(harness.backend.dispatchCount, 1, "no retry after cannotComplete")
        // `.unknownOutcome` never poisons the generation: a follow-up scroll may dispatch.
        harness.backend.nextDispatchError = .success
        let second = await harness.service.scroll(token: scrollToken, operation: .up, key: harness.key)
        XCTAssertEqual(second, .applied)
        XCTAssertEqual(harness.backend.dispatchCount, 2)
        await harness.service.stop()
    }

    func testScrollUnsupportedOperationNeverDispatches() async {
        let (harness, _, _) = makeScrollHarness()
        guard let captured = await harness.captureAndAdopt() else {
            return XCTFail("capture and adoption must succeed")
        }
        guard let result = await harness.scan(captured: captured, key: harness.key) else {
            return XCTFail("the scan must publish the scroll region")
        }
        guard let scrollToken = result.candidates.first(where: { $0.role == .scrollRegion })?.token else {
            return XCTFail("the scroll region must be retained")
        }
        // pageUp has no proven steppers on this region: fail closed, zero dispatches.
        let outcome = await harness.service.scroll(token: scrollToken, operation: .pageUp, key: harness.key)
        XCTAssertEqual(outcome, .failed)
        XCTAssertEqual(harness.backend.dispatchCount, 0)
        await harness.service.stop()
    }

    // MARK: Deterministic mid-scan cancellation cleanup (service-integrated)

    /// Interleaving design: the traversal's children read of the FIRST root signals the
    /// test thread and sleeps while holding the serial AX queue. `releaseGeneration`'
    /// synchronous authorization runs on the test thread (registry micro-lock only —
    /// nothing blocks), and its serialized cleanup queues BEHIND the scan body, so the
    /// ordering is deterministic even though the wall sleep is not.
    func testMidScanAuthorizedReleaseCancelsScanAndKeepsNextGenerationScannable() async {
        let harness = Harness()
        let first = harness.makeWindow(buttons: [(x: 10, y: 10)])
        _ = harness.makeWindow(buttons: [(x: 10, y: 40)])
        guard let captured = await harness.captureAndAdopt() else {
            return XCTFail("capture and adoption must succeed")
        }
        let gate = DispatchSemaphore(value: 0)
        harness.backend.hookChildren(of: first.window, signal: gate)
        let scanTask = Task { await harness.scan(captured: captured, key: harness.key) }
        guard gate.wait(timeout: .now() + 5) == .success else {
            await harness.service.stop()
            return XCTFail("the scan traversal never reached the hooked children read")
        }
        await harness.service.releaseGeneration(harness.key)
        let cancelledScan = await scanTask.value
        XCTAssertNil(cancelledScan, "a cancelled scan publishes nothing")
        XCTAssertEqual(harness.backend.dispatchCount, 0, "cancellation never dispatches")
        // The authorized release advanced the binding; the NEXT generation scans cleanly.
        let key1 = harness.nextKey(after: harness.key)
        guard let generation1 = await harness.scan(captured: captured, key: key1) else {
            return XCTFail("key1 must remain scannable after the cancelled scan's cleanup")
        }
        XCTAssertEqual(generation1.candidates.count, 2)
        await harness.service.stop()
    }

    func testLateScanCancellationStillPublishesNothingAndCleansUp() async {
        let harness = Harness()
        _ = harness.makeWindow(buttons: [(x: 10, y: 10)])
        let second = harness.makeWindow(buttons: [(x: 10, y: 40)])
        guard let captured = await harness.captureAndAdopt() else {
            return XCTFail("capture and adoption must succeed")
        }
        // Hook the LAST root's children read: cancellation lands after most of the
        // traversal finished, just before the publication checks.
        let gate = DispatchSemaphore(value: 0)
        harness.backend.hookChildren(of: second.window, signal: gate)
        let scanTask = Task { await harness.scan(captured: captured, key: harness.key) }
        guard gate.wait(timeout: .now() + 5) == .success else {
            await harness.service.stop()
            return XCTFail("the late hook never fired")
        }
        await harness.service.releaseGeneration(harness.key)
        let cancelledScan = await scanTask.value
        XCTAssertNil(cancelledScan, "a late-cancelled scan still publishes nothing")
        XCTAssertEqual(harness.backend.dispatchCount, 0)
        let key1 = harness.nextKey(after: harness.key)
        guard let generation1 = await harness.scan(captured: captured, key: key1) else {
            return XCTFail("key1 must remain scannable after the late cancellation's cleanup")
        }
        XCTAssertEqual(generation1.candidates.count, 2)
        await harness.service.stop()
    }

    // MARK: Cap keeps the RANKED head, and pruned tokens are inert

    func testCandidateCapKeepsRankedHeadAndPrunedTokensInert() async {
        // Discovery order (child order) is the INVERSE of rank order (y, then x): the
        // child discovered FIRST has the LARGEST y, so the cap must drop the discovery
        // head and keep the ranked one.
        let harness = Harness(limits: HintScanLimits(maxCandidates: 2))
        _ = harness.makeWindow(buttons: [
            (x: 10, y: 50), (x: 10, y: 45), (x: 10, y: 40), (x: 10, y: 35), (x: 10, y: 30),
        ])
        guard let captured = await harness.captureAndAdopt() else {
            return XCTFail("capture and adoption must succeed")
        }
        guard let result = await harness.scan(captured: captured, key: harness.key) else {
            return XCTFail("the scan must publish")
        }
        XCTAssertEqual(result.candidates.count, 2)
        // Rank order ascending y; sequential mint arithmetic pins the discovery head:
        // the two windows + pending id take "1"–"3", so the five buttons minted "4".."8"
        // in child order and the ranked head "8" carries y=30. Any drift fails loudly.
        XCTAssertEqual(result.candidates[0].token.raw, "8")
        XCTAssertEqual(
            result.candidates.map(\.frame.minY), [30.0, 35.0],
            "the cap must keep the ranked head (smallest y), never the discovery-order head"
        )
        XCTAssertEqual(result.summary.discoveredCandidates, 5)
        XCTAssertEqual(result.summary.acceptedCandidates, 5)
        XCTAssertEqual(result.summary.retainedCandidates, 2)
        XCTAssertTrue(result.summary.truncationReasons.contains(.candidateCapReached))

        // The pruned discovery head ("4") is inert: invocation fails with NO AX traffic,
        // and the live generation stays untouched for a retained token.
        let prunedToken = HintTargetToken("4")
        let messagesBefore = harness.backend.axMessageCount
        let outcome = await harness.service.invoke(token: prunedToken, action: .press, key: harness.key)
        XCTAssertEqual(outcome, .failed, "a pruned token is unknown to the exact key")
        XCTAssertEqual(harness.backend.axMessageCount, messagesBefore, "an unknown token reads no AX state")
        // Retained tokens keep working; pruning never poisoned the live state.
        let outcome2 = await harness.service.invoke(
            token: result.candidates[0].token, action: .press, key: harness.key
        )
        XCTAssertEqual(outcome2, .succeeded)
        XCTAssertEqual(harness.backend.dispatchCount, 1)
        await harness.service.stop()
    }

    // MARK: Between-consecutive-read mutation boundaries (deterministic counters)

    // Message arithmetic for these fixtures (audited against the settled service code;
    // the deltas are asserted exactly so silent loosening of any boundary fails loudly):
    //   invoke/scroll prefix: element pid (1) + validateGeneration windows/hygiene/ root
    //   pid/role/minimized/frame (2–7) + ancestry owner/parent/top-level (8–10);
    //   invoke adds role (11); scroll adds role (11), subrole (12), enabled (13),
    //   frame (14), capability inspection (15) before the relationship lookups.

    /// invoke: the boundary planted after the role read must consume NO subrole read.
    func testInvokeBoundaryFailsClosedBetweenRoleAndSubroleRead() async {
        let harness = Harness()
        _ = harness.makeWindow(buttons: [(x: 10, y: 10)])
        guard let captured = await harness.captureAndAdopt() else {
            return XCTFail("capture and adoption must succeed")
        }
        guard let result = await harness.scan(captured: captured, key: harness.key) else {
            return XCTFail("the scan must publish")
        }
        guard let token = result.candidates.first?.token else {
            return XCTFail("the scan must retain the candidate")
        }
        let baseline = harness.armBoundaryCut(afterAnotherMessages: 11) // through the role read
        let outcome = await harness.service.invoke(token: token, action: .press, key: harness.key)
        XCTAssertEqual(outcome, .failed, "a boundary cut between role and subrole fails closed")
        XCTAssertEqual(harness.backend.axMessageCount, baseline + 11, "NO subrole message follows the cut")
        XCTAssertEqual(harness.backend.dispatchCount, 0, "no dispatch is reached from an unread subrole")
        await harness.service.stop()
    }

    /// scroll (.down): the boundary planted after the role read must consume NO subrole
    /// read on the scroll lane.
    func testScrollBoundaryFailsClosedBetweenRoleAndSubroleRead() async {
        let (harness, _, _) = makeScrollHarness()
        guard let captured = await harness.captureAndAdopt() else {
            return XCTFail("capture and adoption must succeed")
        }
        guard let result = await harness.scan(captured: captured, key: harness.key) else {
            return XCTFail("the scan must publish the scroll region")
        }
        guard let scrollToken = result.candidates.first(where: { $0.role == .scrollRegion })?.token else {
            return XCTFail("the scroll region must be retained")
        }
        let baseline = harness.armBoundaryCut(afterAnotherMessages: 11) // through the role read
        let outcome = await harness.service.scroll(token: scrollToken, operation: .down, key: harness.key)
        XCTAssertEqual(outcome, .failed, "a boundary cut between role and subrole fails closed")
        XCTAssertEqual(harness.backend.axMessageCount, baseline + 11, "NO subrole message follows the cut")
        XCTAssertEqual(harness.backend.dispatchCount, 0)
        await harness.service.stop()
    }

    /// Full-matrix scroll fixture: every operation provably supported, page steppers
    /// present, home/end range readable — so the boundary cuts below land exactly at the
    /// stated read pairs and nowhere earlier.
    private func makeFullScrollHarness() -> (Harness, AXUIElement, AXUIElement, AXUIElement) {
        let (harness, window, region) = makeScrollHarness()
        let bar = harness.backend.node(region).scrollbars.vertical!
        harness.backend.node(region).scrollCapabilities = [.down, .up, .pageUp, .pageDown, .home, .end]
        let stepper = harness.backend.makeChild(under: region) { node in
            node.pid = harness.targetPid
            node.role = .value("AXButton")
            node.subrole = .value(kAXDecrementPageSubrole as String)
            node.actionNames = .value([kAXPressAction as String])
        }
        harness.backend.node(region).pageSteppers = (stepper, stepper)
        harness.backend.node(bar).numericRange = (minimum: 0, maximum: 1_000)
        return (harness, window, region, bar)
    }

    /// scroll (.pageDown): the boundary planted after the page-stepper lookup consumes NO
    /// stepper pid read.
    func testScrollBoundaryBetweenPageStepperLookupAndPidReadFailsClosed() async {
        let (harness, _, _, _) = makeFullScrollHarness()
        guard let captured = await harness.captureAndAdopt() else {
            return XCTFail("capture and adoption must succeed")
        }
        guard let result = await harness.scan(captured: captured, key: harness.key) else {
            return XCTFail("the scan must publish the scroll region")
        }
        guard let scrollToken = result.candidates.first(where: { $0.role == .scrollRegion })?.token else {
            return XCTFail("the scroll region must be retained")
        }
        let baseline = harness.armBoundaryCut(afterAnotherMessages: 16) // through the stepper lookup
        let outcome = await harness.service.scroll(token: scrollToken, operation: .pageDown, key: harness.key)
        XCTAssertEqual(outcome, .failed, "a boundary cut before the stepper pid read fails closed")
        XCTAssertEqual(harness.backend.axMessageCount, baseline + 16, "NO stepper pid message follows the cut")
        XCTAssertEqual(harness.backend.dispatchCount, 0)
        await harness.service.stop()
    }

    /// scroll (.down): the boundary planted after the scrollbar lookup consumes NO
    /// scrollbar pid read.
    func testScrollBoundaryBetweenScrollbarLookupAndPidReadFailsClosed() async {
        let (harness, _, _, _) = makeFullScrollHarness()
        guard let captured = await harness.captureAndAdopt() else {
            return XCTFail("capture and adoption must succeed")
        }
        guard let result = await harness.scan(captured: captured, key: harness.key) else {
            return XCTFail("the scan must publish the scroll region")
        }
        guard let scrollToken = result.candidates.first(where: { $0.role == .scrollRegion })?.token else {
            return XCTFail("the scroll region must be retained")
        }
        let baseline = harness.armBoundaryCut(afterAnotherMessages: 16) // through the scrollbar lookup
        let outcome = await harness.service.scroll(token: scrollToken, operation: .down, key: harness.key)
        XCTAssertEqual(outcome, .failed, "a boundary cut before the scrollbar pid read fails closed")
        XCTAssertEqual(harness.backend.axMessageCount, baseline + 16, "NO scrollbar pid message follows the cut")
        XCTAssertEqual(harness.backend.dispatchCount, 0)
        await harness.service.stop()
    }

    /// scroll (.home): the boundary planted after the value-settability read consumes NO
    /// numeric-range read.
    func testScrollBoundaryBetweenSettabilityAndNumericRangeReadFailsClosed() async {
        let (harness, _, _, _) = makeFullScrollHarness()
        guard let captured = await harness.captureAndAdopt() else {
            return XCTFail("capture and adoption must succeed")
        }
        guard let result = await harness.scan(captured: captured, key: harness.key) else {
            return XCTFail("the scan must publish the scroll region")
        }
        guard let scrollToken = result.candidates.first(where: { $0.role == .scrollRegion })?.token else {
            return XCTFail("the scroll region must be retained")
        }
        let baseline = harness.armBoundaryCut(afterAnotherMessages: 18) // through the settability read
        let outcome = await harness.service.scroll(token: scrollToken, operation: .home, key: harness.key)
        XCTAssertEqual(outcome, .failed, "a boundary cut before the numeric-range read fails closed")
        XCTAssertEqual(harness.backend.axMessageCount, baseline + 18, "NO numeric-range message follows the cut")
        XCTAssertEqual(harness.backend.dispatchCount, 0)
        await harness.service.stop()
    }

    // MARK: Graph-proof ancestry regressions (all fail closed, zero dispatch)

    /// Conflicting live upward links: the graph walk explores ALL upward links, and the
    /// element here reaches TWO retained roots (owner → B, parent → A). The proof is
    /// ambiguous by construction → fail closed, NO dispatch.
    func testConflictingLiveUpwardLinksAmbiguousProofFailsClosed() async {
        let harness = Harness()
        let first = harness.makeWindow(buttons: [(x: 10, y: 10)])
        let second = harness.makeWindow(buttons: [])
        guard let captured = await harness.captureAndAdopt() else {
            return XCTFail("capture and adoption must succeed")
        }
        guard let result = await harness.scan(captured: captured, key: harness.key) else {
            return XCTFail("the scan must publish")
        }
        guard let token = result.candidates.first?.token else {
            return XCTFail("the scan must retain the candidate")
        }
        // Post-scan conflict wiring (window-set unchanged): owner → root B, parent → root A.
        harness.backend.node(first.buttons[0]).owningWindow = .value(second.window)
        let outcome = await harness.service.invoke(token: token, action: .press, key: harness.key)
        XCTAssertEqual(outcome, .failed, "two roots reached by one proof is a conflict")
        XCTAssertEqual(harness.backend.dispatchCount, 0)
        await harness.service.stop()
    }

    /// A cycle in the live upward links (self-referential parent) leaves the graph
    /// unresolved → fail closed, NO dispatch.
    func testAncestryCycleFailsClosedWithZeroDispatch() async {
        let harness = Harness()
        let live = harness.makeWindow(buttons: [(x: 10, y: 10)])
        guard let captured = await harness.captureAndAdopt() else {
            return XCTFail("capture and adoption must succeed")
        }
        guard let result = await harness.scan(captured: captured, key: harness.key) else {
            return XCTFail("the scan must publish")
        }
        guard let token = result.candidates.first?.token else {
            return XCTFail("the scan must retain the candidate")
        }
        harness.backend.node(live.buttons[0]).parent = .value(live.buttons[0])
        let outcome = await harness.service.invoke(token: token, action: .press, key: harness.key)
        XCTAssertEqual(outcome, .failed, "a cycle marks the ancestry proof unresolved")
        XCTAssertEqual(harness.backend.dispatchCount, 0)
        await harness.service.stop()
    }

    /// Depth exhaustion: an upward chain longer than the frozen `maxDepth` budget leaves
    /// the ancestry unresolved (never guessed) → fail closed, NO dispatch. Built AFTER the
    /// scan (baseline windows are not re-walked by preflight classification), so the
    /// failure provably comes from the graph proof alone.
    func testDepthExhaustionFailsClosedWithZeroDispatch() async {
        let harness = Harness()
        let live = harness.makeWindow(buttons: [(x: 10, y: 10)])
        guard let captured = await harness.captureAndAdopt() else {
            return XCTFail("capture and adoption must succeed")
        }
        guard let result = await harness.scan(captured: captured, key: harness.key) else {
            return XCTFail("the scan must publish")
        }
        guard let token = result.candidates.first?.token else {
            return XCTFail("the scan must retain the candidate")
        }
        // 42 intermediate links (budget is 40): a strand that would need the frontier
        // beyond `maxDepth` fails the proof instead of guessing upward.
        var previous = live.window
        var chainElements: [AXUIElement] = []
        for _ in 0..<42 {
            previous = harness.backend.makeChild(under: previous)
            chainElements.append(previous)
        }
        harness.backend.node(live.buttons[0]).parent = .value(chainElements.last!)
        let outcome = await harness.service.invoke(token: token, action: .press, key: harness.key)
        XCTAssertEqual(outcome, .failed, "a chain beyond the depth budget leaves ancestry unresolved")
        XCTAssertEqual(harness.backend.dispatchCount, 0)
        await harness.service.stop()
    }
}

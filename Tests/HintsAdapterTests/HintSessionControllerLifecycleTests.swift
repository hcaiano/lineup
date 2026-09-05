import AppKit
import Carbon.HIToolbox
import XCTest
@testable import lineup
import HintsCore

// ============================================================================
// Deterministic `HintSessionController` lifecycle tests (Phase 3, macOS-only).
//
// Driving model: every stub answer is immediate (unless a one-shot gate holds an
// adapter call), so tests only yield while MainActor tasks settle. Ordering is asserted
// through the shared trace; content assertions are count/type-only. No assertion
// contains an `await` (XCTest autoclosures are synchronous); every awaited check is
// snapshotted into a local first.
//
// INVENTORY (whole file): 28 lifecycle test methods. The Gate 3 adapter suites in this
// target (HintAX*/HintInput*) remain AX/Input-scoped and were not modified here.
//
// Contract coverage: strict initial order (capture → activateRequested → adopt gen 0 →
// scan), initial effect batch order, expected-hide order (relinquish → hide → invoke),
// rescan awaiting releaseGeneration with ONE responder install per presentation attach,
// scroll never touching invoke + exhaustive scroll mapping, invocation outcome
// interpretation, repeated activation (live session → Core `.cancel(.repeatedActivation)`
// with no new capture; capture slot in flight → synchronous runtime drain + fresh
// runtime, incl. a back-to-back `activate(); activate()` with NO intermediate yield),
// epoch-keyed capture slot (stale task/defer never clears a newer slot), epoch-keyed
// pump ownership (slot verified at entry and after every awaited effect; stale
// continuations/defers never clear or operate on a newer pump), epoch-tagged mailbox
// events (queued old-lifecycle events discarded on retirement), epoch-scoped
// `retireIfIdle` (stale async work is UNABLE to retire the current adapters), stop
// racing gated capture and gated invoke with immediate reactivation (drained lanes
// resolve their gated calls, the fresh runtime/reducer survive, no fresh adapter is
// retired), stale gated capture against a deliberately idle + gated fresh runtime
// (fresh slot reservation and idle lane preserved), stale gated adoption staying
// strictly local in both outcome branches (no fresh-state mutation, no stale
// `scanFailed`), nil-capture retirement under activation/lifecycle counter divergence,
// stale keyed outcomes, all cancellation sources, terminal retirement (input
// delegate detached BEFORE stop, retired counters checked against pre-retirement
// baselines, stopped callbacks judged by absence of delegate effects) without poisoning
// future activations, one display-snapshot provider call per activation with
// primary-anchored CGFloat conversion (display above primary), fail-closed adapter
// failures, and the hard-stop teardown + resurrection poisoning.
// ============================================================================

@MainActor
final class HintSessionControllerLifecycleTests: XCTestCase {

    /// Factory/storage state held in its OWN fully-initialized class, so the escaping
    /// dependency closures can capture it by a plain local reference. This satisfies
    /// definite initialization: no closure captures `self` (the Harness) before the
    /// Harness's stored properties (notably `controller`) are initialized.
    final class Factories {
        let trace = SessionTrace()
        private(set) var allTargets: [StubSessionTargets] = []
        private(set) var allPresentations: [StubSessionPresentation] = []
        private(set) var allInputs: [StubSessionInput] = []
        /// How many times the display-snapshot provider was consulted (blocker 1: one
        /// call per activation, never per presentation effect).
        private(set) var displaySnapshotCalls = 0

        // Templates: copied onto every fresh adapter instance at handout.
        /// `nil` makes the next handed-out instance FAIL its capture (tests the nil
        /// capture path); the default is a presentable fixture context.
        var targetsContext: HintTargetContext? = SessionFixtures.context()
        var targetsAdoptResult = true
        var scanAnswersTemplate: [HintScanResult?]? = nil
        var invocationAnswersTemplate: [HintInvocationOutcome] = []
        var mutationAnswersTemplate: [HintMutationOutcome] = []
        var presentationShowResult = true
        var presentationUpdateResult = true

        /// Pre-created instances handed to the controller on ITS FIRST factory call
        /// (they exist so gates and templates can be configured before activation).
        private var nextTargetsStub: StubSessionTargets?
        private var nextInputStub: StubSessionInput?
        private var nextPresentationStub: StubSessionPresentation?

        func makeTargets() -> StubSessionTargets {
            // Templates are applied at HANDOUT time (the controller provisions lazily,
            // so configuration must survive until the first activate()).
            if let pending = nextTargetsStub {
                pending.capturedContext = targetsContext
                pending.adoptResult = targetsAdoptResult
                pending.scanAnswers = scanAnswersTemplate ?? []
                nextTargetsStub = nil
                return pending
            }
            let stub = StubSessionTargets(trace: trace)
            stub.capturedContext = targetsContext
            stub.adoptResult = targetsAdoptResult
            stub.scanAnswers = scanAnswersTemplate ?? []
            allTargets.append(stub)
            return stub
        }

        func makeInput() -> StubSessionInput {
            if let pending = nextInputStub {
                nextInputStub = nil
                return pending
            }
            let stub = StubSessionInput(trace: trace)
            allInputs.append(stub)
            return stub
        }

        func makePresentation() -> StubSessionPresentation {
            if let pending = nextPresentationStub {
                pending.showResult = presentationShowResult
                pending.updateResult = presentationUpdateResult
                nextPresentationStub = nil
                return pending
            }
            let stub = StubSessionPresentation(trace: trace)
            stub.showResult = presentationShowResult
            stub.updateResult = presentationUpdateResult
            allPresentations.append(stub)
            return stub
        }

        /// The single per-activation display snapshot (one provider call counter).
        func newDisplaySnapshot() -> HintDisplaySnapshot {
            displaySnapshotCalls += 1
            return HintDisplaySnapshot(
                primaryMaxY: 0,
                accessibilityFrames: SessionFixtures.captureScreens,
                screens: SessionFixtures.screens
            )
        }

        /// Pre-create the Nth (non-first) targets instance for a planned later
        /// activation: the fresh runtime after an intermediate lifetime ends. The stub
        /// is appended to `allTargets` immediately (so tests can index it) AND seeded
        /// as the next handout (so gates/templates can be configured BEFORE the
        /// controller's lazy factory call; `makeTargets` hands it out without
        /// re-registering). Current templates are applied now AND at handout.
        func nextTargets() -> StubSessionTargets {
            let stub = StubSessionTargets(trace: trace)
            stub.capturedContext = targetsContext
            stub.adoptResult = targetsAdoptResult
            stub.scanAnswers = scanAnswersTemplate ?? []
            allTargets.append(stub)
            nextTargetsStub = stub
            return stub
        }

        /// Pre-create the FIRST adapter instances so tests can arm gates / flip flags
        /// deterministically BEFORE the first activation.
        func seedFirstInstances() {
            let firstTargets = StubSessionTargets(trace: trace)
            firstTargets.capturedContext = targetsContext
            allTargets.append(firstTargets)
            nextTargetsStub = firstTargets
            let firstInput = StubSessionInput(trace: trace)
            allInputs.append(firstInput)
            nextInputStub = firstInput
            let firstPresentation = StubSessionPresentation(trace: trace)
            firstPresentation.showResult = presentationShowResult
            firstPresentation.updateResult = presentationUpdateResult
            allPresentations.append(firstPresentation)
            nextPresentationStub = firstPresentation
        }
    }

    final class Harness {
        let controller: HintSessionController
        /// Every stub instance ever created by the factories, so tests can inspect BOTH
        /// the current (fresh) adapters and the retired ones.
        let factories: Factories

        var trace: SessionTrace { factories.trace }
        var allTargets: [StubSessionTargets] { factories.allTargets }
        var allPresentations: [StubSessionPresentation] { factories.allPresentations }
        var allInputs: [StubSessionInput] { factories.allInputs }
        var displaySnapshotCalls: Int { factories.displaySnapshotCalls }

        /// CURRENT targets instance (a fresh stub after every runtime retirement).
        var targets: StubSessionTargets { allTargets.last! }
        /// CURRENT presentation instance.
        var presentation: StubSessionPresentation { allPresentations.last! }
        /// CURRENT input instance.
        var input: StubSessionInput { allInputs.last! }

        // Template passthroughs tests configure before/during activation.
        var targetsAdoptResult: Bool {
            get { factories.targetsAdoptResult }
            set { factories.targetsAdoptResult = newValue }
        }
        var scanAnswersTemplate: [HintScanResult?]? {
            get { factories.scanAnswersTemplate }
            set { factories.scanAnswersTemplate = newValue }
        }
        var presentationUpdateResult: Bool {
            get { factories.presentationUpdateResult }
            set { factories.presentationUpdateResult = newValue }
        }

        init(frontPid: Int32? = SessionFixtures.targetPid, trusted: Bool = true) {
            let factories = Factories()
            factories.seedFirstInstances()
            let deps = HintSessionDependencies(
                limits: .standard,
                alphabet: HintsSettings.defaultAlphabet,
                activationModifierMask: UInt32(cmdKey) | UInt32(shiftKey),
                makeTargets: { factories.makeTargets() },
                makeInput: { factories.makeInput() },
                makePresentation: { factories.makePresentation() },
                frontmostPID: { frontPid },
                displaySnapshot: { factories.newDisplaySnapshot() },
                isAccessibilityTrusted: { trusted }
            )
            controller = HintSessionController(deps: deps)
            self.factories = factories
        }
    }

    // MARK: Harness helpers

    private func yieldUntil(
        _ condition: @escaping (Harness) -> Bool, harness: Harness, limit: Int = 1_000
    ) async -> Bool {
        var tries = 0
        while !condition(harness) && tries < limit {
            try? await Task.sleep(nanoseconds: 1_000_000)
            tries += 1
        }
        return condition(harness)
    }

    private func isPresenting(_ harness: Harness) -> Bool {
        if case .presenting = harness.controller.reducer.state { return true }
        return false
    }

    private func isIdle(_ harness: Harness) -> Bool {
        harness.controller.reducer.state == .idle
    }

    private func isInScrollMode(_ harness: Harness) -> Bool {
        if case .presenting(let presenting) = harness.controller.reducer.state {
            return presenting.mode == .scroll
        }
        return false
    }

    private func hasScrollSelection(_ harness: Harness) -> Bool {
        if case .presenting(let presenting) = harness.controller.reducer.state,
           presenting.mode == .scroll {
            return presenting.selectedIndex != nil
        }
        return false
    }

    private func isSettledPresenting(_ harness: Harness) -> Bool {
        if case .presenting(let presenting) = harness.controller.reducer.state {
            return presenting.awaitingModifierRelease == false && !presenting.candidates.isEmpty
        }
        return false
    }

    /// One activation, run to completion: presenting labels mode with the modifier
    /// barrier released (modal input armed).
    private func driveToPresenting(_ harness: Harness, result: HintScanResult? = nil) async {
        harness.scanAnswersTemplate = [result ?? SessionFixtures.scanResult(SessionFixtures.pressCandidate())]
        harness.controller.activate()
        let presented = await yieldUntil(isPresenting, harness: harness)
        XCTAssertTrue(presented, "never reached presenting: \(harness.trace.joined())")
        harness.input.deliver(.modifierBarrierReleased)
        let armed = await yieldUntil({ $0.input.beginInputCount == 1 }, harness: harness)
        XCTAssertTrue(armed, "barrier never released")
        harness.trace.append("mark.presenting")
    }

    /// Delivers `label` one character command at a time (the modal input path).
    private func deliver(_ harness: Harness, label: String) {
        for character in label {
            harness.input.deliver(.character(character))
        }
    }

    private func fullLabel(_ harness: Harness, of index: Int) -> String {
        guard case .presenting(let presenting) = harness.controller.reducer.state,
              presenting.candidates.indices.contains(index) else {
            XCTFail("no candidate at index \(index)")
            return "a"
        }
        return presenting.candidates[index].label
    }

    /// Index into the presenting candidates of the FIRST scroll region.
    private func scrollRegionIndex(_ harness: Harness) -> Int {
        guard case .presenting(let presenting) = harness.controller.reducer.state,
              let index = presenting.candidates.firstIndex(where: { $0.candidate.role == .scrollRegion }) else {
            XCTFail("no scroll region in the presenting pool")
            return 0
        }
        return index
    }

    /// Enters scroll mode and selects its first region by label.
    private func enterScrollModeAndSelect(_ harness: Harness) async {
        harness.input.deliver(.space)
        let entered = await yieldUntil(isInScrollMode, harness: harness)
        XCTAssertTrue(entered, "space did not enter scroll mode")
        deliver(harness, label: fullLabel(harness, of: scrollRegionIndex(harness)))
        let selected = await yieldUntil(hasScrollSelection, harness: harness)
        XCTAssertTrue(selected, "the full label did not bind the scroll target")
    }

    /// Enters scroll mode and dispatches one semantic scroll, awaiting the dispatch.
    private func dispatchScroll(_ harness: Harness, _ command: HintScrollCommand, mutation: HintMutationOutcome) async {
        await enterScrollModeAndSelect(harness)
        harness.targets.mutationAnswers = [mutation]
        harness.input.deliver(.scroll(command))
        let dispatched = await yieldUntil({ !$0.targets.scrolledOperations.isEmpty }, harness: harness)
        XCTAssertTrue(dispatched, "the scroll command never dispatched")
    }

    // MARK: Strict initial order

    func testActivationRunsCaptureThenReducerThenAdoptGen0ThenScan() async {
        let harness = Harness()
        await driveToPresenting(harness)

        XCTAssertEqual(harness.trace.position("targets.captureContext"), 0)
        XCTAssertLessThan(harness.trace.position("targets.captureContext")!, harness.trace.position("targets.adoptCapture")!)
        XCTAssertLessThan(harness.trace.position("targets.adoptCapture")!, harness.trace.position("targets.scan")!)
        XCTAssertEqual(harness.targets.adoptPlans.first?.generation, 0, "adoption binds the first generation")
        XCTAssertEqual(harness.controller.phase, .presenting)
        XCTAssertTrue(harness.controller.provisioned)
        XCTAssertEqual(harness.allTargets.count, 1, "no runtime replacement on a plain activation")
    }

    // MARK: Initial effect batch order

    func testInitialEffectsRunInRecordedBatchOrderAndBarrierGatesInput() async {
        let harness = Harness()
        await driveToPresenting(harness)

        let lines = harness.trace.lines
        let scanAt = lines.firstIndex(of: "targets.scan")!
        let updateAt = lines.firstIndex(of: "presentation.update")!
        let barrierAt = lines.firstIndex(of: "input.awaitModifierRelease")!
        let beginAt = lines.firstIndex(of: "input.beginInput")!
        // showOverlays runs after the scan and before the barrier arm; beginInput only
        // ever arrives from the barrier RELEASE event, never with the initial batch.
        XCTAssertLessThan(scanAt, updateAt)
        XCTAssertLessThan(updateAt, barrierAt)
        XCTAssertLessThan(barrierAt, beginAt)
        XCTAssertEqual(lines.filter { $0 == "input.beginInput" }.count, 1)
        // The install happens EXACTLY once for the initial scan. (The synchronous
        // capture confirm is window-gated in production; the stub has no window, so
        // "input.captureConfirmed" presence is not asserted here.)
        XCTAssertEqual(harness.presentation.installedResponderViews, 1)
        // Core's authoritative first snapshot reached the presentation lane.
        XCTAssertEqual(harness.presentation.snapshots.count, 1)
        XCTAssertEqual(harness.presentation.snapshots[0].mode, .labels)
        XCTAssertEqual(harness.presentation.snapshots[0].visible.count, 1)
        // The barrier mask is the conversion of the PERSISTED shortcut mask (⇧⌘ here).
        XCTAssertEqual(harness.input.awaitModifierMasks.count, 1)
        XCTAssertTrue(harness.input.awaitModifierMasks[0].contains(.command), "⌘ must cross the barrier")
        XCTAssertTrue(harness.input.awaitModifierMasks[0].contains(.shift), "⇧ must cross the barrier")
        XCTAssertFalse(harness.input.awaitModifierMasks[0].contains(.option), "no phantom modifiers")
    }

    // MARK: Expected-hide ordering

    func testSuccessfulInvocationRelinquishesHidesThenDispatchesAndEnds() async {
        let harness = Harness()
        await driveToPresenting(harness)
        harness.targets.invocationAnswers = [.succeeded]

        harness.input.deliver(.return) // query is empty: Return is inert; no dispatch
        try? await Task.sleep(nanoseconds: 2_000_000)
        XCTAssertNil(harness.trace.position("targets.invoke"), "Return with no selection must be inert")

        deliver(harness, label: fullLabel(harness, of: 0))
        harness.input.deliver(.return)
        let dispatched = await yieldUntil({ $0.trace.position("targets.invoke") != nil }, harness: harness)
        XCTAssertTrue(dispatched)
        let ended = await yieldUntil(isIdle, harness: harness)
        XCTAssertTrue(ended, "succeeded invocation should end the session")

        let lines = harness.trace.lines
        let hideAt = lines.firstIndex(of: "presentation.hide")!
        let invokeAt = lines.firstIndex(of: "targets.invoke")!
        XCTAssertLessThan(lines.firstIndex(of: "input.relinquish")!, hideAt, "input relinquishes FIRST")
        XCTAssertLessThan(hideAt, invokeAt, "overlays hide before the AX dispatch")
        XCTAssertEqual(harness.targets.releasedSessions.count, 1, "succeeded ends with one session release")
        XCTAssertEqual(harness.targets.releasedGenerations.count, 0, "no generation-only release on success")
        XCTAssertEqual(harness.controller.phase, .idle)
        // Terminal retirement: adapters destroyed, responder attachment cleared.
        XCTAssertEqual(harness.presentation.stopCount, 1)
        XCTAssertEqual(harness.input.stopCount, 1)
        XCTAssertEqual(harness.targets.stopAndWaitCount, 1)
        XCTAssertEqual(harness.presentation.installedResponderViews, 1, "one install for the whole session")
    }

    // MARK: Invocation outcome interpretation

    func testOutcomeDrivesExactlyOneRescanOrTerminalEnd() async {
        for outcome in [HintInvocationOutcome.succeeded, .succeededNeedsRescan, .unknownOutcome, .failed] {
            let harness = Harness()
            await driveToPresenting(harness)
            let expectedScans: Int = (outcome == .succeededNeedsRescan || outcome == .unknownOutcome) ? 2 : 1
            harness.targets.scanAnswers = [SessionFixtures.scanResult(SessionFixtures.pressCandidate())] // rescan answer if consumed
            harness.targets.invocationAnswers = [outcome]

            deliver(harness, label: fullLabel(harness, of: 0))
            harness.input.deliver(.return)
            let dispatched = await yieldUntil({ $0.trace.position("targets.invoke") != nil }, harness: harness)
            XCTAssertTrue(dispatched, "outcome \(outcome): invocation never dispatched")
            let scanned = await yieldUntil({ $0.targets.scanPlans.count == expectedScans }, harness: harness)
            XCTAssertTrue(
                scanned,
                "outcome \(outcome): expected \(expectedScans) scan(s), trace \(harness.trace.joined())")

            if expectedScans == 2 {
                let lines = harness.trace.lines
                XCTAssertLessThan(
                    lines.firstIndex(of: "targets.invoke")!,
                    lines.firstIndex(of: "targets.releaseGeneration")!,
                    "release waits for the invocation to land")
                let scanTracePositions = lines.enumerated().filter { $0.element == "targets.scan" }.map(\.offset)
                XCTAssertLessThan(
                    lines.firstIndex(of: "targets.releaseGeneration")!,
                    scanTracePositions[1],
                    "the rescan starts only after the generation release")
                XCTAssertEqual(harness.targets.releasedGenerations.count, 1)
                XCTAssertEqual(harness.targets.releasedSessions.count, 0)
                // The rescan plan carries the NEXT generation of the same session id.
                let firstKey = harness.targets.adoptPlans.first!
                XCTAssertEqual(harness.targets.scanPlans[1].key.generation, firstKey.generation + 1)
                // The rescan runs on a fresh canvas (the invocation hid the overlays):
                // the responder is installed once more, on the same lane instance.
                XCTAssertEqual(harness.presentation.installedResponderViews, 2)
            } else {
                let ended = await yieldUntil(isIdle, harness: harness)
                XCTAssertTrue(ended, "outcome \(outcome) must end the session")
                XCTAssertEqual(harness.targets.releasedGenerations.count, 0)
                XCTAssertEqual(harness.targets.releasedSessions.count, 1)
                XCTAssertEqual(harness.trace.count("targets.scan"), 1, "outcome \(outcome) never retries")
                // The rescan answer was left unconsumed: nothing extra ran.
                XCTAssertEqual(harness.targets.scanAnswers.count, 1)
            }
        }
    }

    // MARK: Scroll routing + responder retention across rescan

    func testScrollDispatchesOnlyThroughScrollSurfaceAndRescansWithRestoredSelection() async {
        let harness = Harness()
        let press = SessionFixtures.pressCandidate()
        let region = SessionFixtures.scrollRegionCandidate(continuity: "$cont.region.1")
        await driveToPresenting(harness, result: SessionFixtures.scanResult(press, region))
        // Pre-seed the rescan answer BEFORE the scroll dispatch: the stub answers
        // instantly, so the observational rescan can consume the queue before the test
        // resumes.
        harness.targets.scanAnswers = [SessionFixtures.scanResult(press, region)]
        let providerCallsAtPresentation = harness.displaySnapshotCalls

        await dispatchScroll(harness, .down, mutation: .applied)
        let secondScan = await yieldUntil({ $0.targets.scanPlans.count == 2 }, harness: harness)
        XCTAssertTrue(secondScan, "applied scroll rescans observationally")

        let lines = harness.trace.lines
        XCTAssertNil(lines.firstIndex(of: "targets.invoke"), "scroll NEVER routes through invoke")
        XCTAssertEqual(harness.targets.scrolledOperations, [.down])

        let releaseAt = lines.firstIndex(of: "targets.releaseGeneration")!
        let firstScan = harness.targets.scanPlans.first!
        XCTAssertEqual(harness.targets.releasedGenerations, [firstScan.key], "exactly the old generation is released")
        let scanTracePositions = lines.enumerated().filter { $0.element == "targets.scan" }.map(\.offset)
        XCTAssertLessThan(releaseAt, scanTracePositions[1], "the rescan started after the release")
        // Fresh generation reuses the session roots: same session id, generation + 1.
        XCTAssertEqual(harness.targets.scanPlans[1].key.generation, firstScan.key.generation + 1)
        // Same-session rescan (scroll): the overlay retained the responder → exactly one
        // install for the whole multi-generation session.
        XCTAssertEqual(harness.presentation.installedResponderViews, 1)
        // The per-activation snapshot was reused: no extra display-snapshot provider call.
        XCTAssertEqual(harness.displaySnapshotCalls, providerCallsAtPresentation)
        // The resume path restored scroll mode and, via adapter-proven continuity, the
        // selection.
        let restored = await yieldUntil(hasScrollSelection, harness: harness)
        XCTAssertTrue(restored, "continuity must restore the scroll selection after the rescan")
    }

    // MARK: Exhaustive vocabulary mappings (pure)

    func testScrollVocabularyMapsExhaustivelyInBothDirections() {
        let allCommands = HintScrollCommand.allCases
        XCTAssertEqual(allCommands.count, 8, "the frozen scroll vocabulary has 8 operations")
        for command in allCommands {
            XCTAssertEqual(command.mapped.mapped, command, "round trip failed for \(command)")
        }
        let allOperations: [HintScrollOperation] = [.up, .down, .left, .right, .pageUp, .pageDown, .home, .end]
        XCTAssertEqual(allOperations, HintScrollOperation.allCases)
        for operation in allOperations {
            XCTAssertEqual(operation.mapped.mapped, operation, "round trip failed for \(operation)")
        }
        // Action mapping: everything reachable dispatches; the unreachable fails closed.
        XCTAssertEqual(HintActionKind.press.mapped, .press)
        XCTAssertEqual(HintActionKind.showMenu.mapped, .showMenu)
        XCTAssertEqual(HintActionKind.focus.mapped, .focus)
        XCTAssertNil(HintActionKind.scroll.mapped, "scroll actions fail closed at the invoke boundary")
    }

    // MARK: Failed scroll

    func testFailedScrollCancelsSessionFailClosed() async {
        let harness = Harness()
        let region = SessionFixtures.scrollRegionCandidate()
        await driveToPresenting(harness, result: SessionFixtures.scanResult(SessionFixtures.pressCandidate(), region))
        await dispatchScroll(harness, .up, mutation: .failed)

        let ended = await yieldUntil(isIdle, harness: harness)
        XCTAssertTrue(ended, "a failed scroll cancels the session")

        let lines = harness.trace.lines
        XCTAssertNil(lines.firstIndex(of: "targets.invoke"), "a failed scroll still never routes through invoke")
        XCTAssertLessThan(lines.firstIndex(of: "targets.scroll")!, lines.firstIndex(of: "presentation.hide")!)
        XCTAssertLessThan(lines.firstIndex(of: "presentation.hide")!, lines.firstIndex(of: "targets.releaseSession")!)
        XCTAssertEqual(harness.targets.releasedSessions.count, 1)
        XCTAssertEqual(harness.targets.releasedGenerations.count, 0, "a failed scroll never rescans")
        // Terminal retirement: everything from this session is destroyed.
        XCTAssertEqual(harness.targets.stopAndWaitCount, 1)
        XCTAssertEqual(harness.presentation.stopCount, 1)
    }

    // MARK: Repeated activation (one-pending rule)

    func testRepeatedActivationWhileCaptureInFlightDrainsRuntimeAndReprovisions() async {
        let harness = Harness()
        harness.scanAnswersTemplate = [SessionFixtures.scanResult(SessionFixtures.pressCandidate())]
        harness.targets.armCaptureGate() // first targets instance (created by the factory below)
        harness.controller.activate()
        let firstCapture = await yieldUntil({ $0.trace.count("targets.captureContext") == 1 }, harness: harness)
        XCTAssertTrue(firstCapture)
        XCTAssertEqual(harness.allTargets.count, 1)
        let slotEpochAtCapture = harness.controller.captureSlotEpoch
        XCTAssertNotNil(slotEpochAtCapture, "the capture slot is reserved while the capture is in flight")

        // The replacement activation: Core is idle and a capture is in flight → the stale
        // runtime is drained SYNCHRONOUSLY and a FRESH runtime is provisioned first.
        harness.controller.activate()
        let replacement = await yieldUntil(
            { harness.allTargets.count == 2 && !harness.targets.adoptPlans.isEmpty }, harness: harness)
        XCTAssertTrue(replacement, "the replacement capture never adopted: \(harness.trace.joined())")

        // Fresh adapters served the replacement; the OLD AX lane was drained exactly once.
        XCTAssertEqual(harness.allTargets.count, 2)
        XCTAssertEqual(harness.allTargets[0].stopAndWaitCount, 1, "the stale runtime drains synchronously")
        XCTAssertEqual(harness.allTargets[1].stopAndWaitCount, 0, "the fresh runtime has not been drained")
        XCTAssertEqual(harness.allInputs.count, 2)
        XCTAssertEqual(harness.allPresentations.count, 2)

        // Only the replacement session adopts; exactly ONE scan starts.
        XCTAssertEqual(harness.targets.adoptPlans.count, 1)
        XCTAssertEqual(harness.trace.count("targets.scan"), 1)
        let presented = await yieldUntil(isPresenting, harness: harness)
        XCTAssertTrue(presented)
        harness.input.deliver(.modifierBarrierReleased)
        let settled = await yieldUntil(isSettledPresenting, harness: harness)
        XCTAssertTrue(settled)

        // The late gated capture resolves now — released SYNCHRONOUSLY by the drain
        // (`stopAndWait` resumes gated continuations, production-faithful). The drained
        // lane REJECTS the resumed capture (stopped recheck → nil), so the stale task
        // exits at its epoch guards without touching the fresh lane and without
        // retiring the fresh runtime (epoch-scoped retirement).
        harness.allTargets[0].releaseCapture()
        try? await Task.sleep(nanoseconds: 3_000_000)
        XCTAssertEqual(harness.allTargets.reduce(0) { $0 + $1.discardedCaptures.count }, 0,
                       "the drained lane rejected the resumed capture; nothing to discard")
        XCTAssertEqual(harness.allTargets.reduce(0) { $0 + $1.adoptPlans.count }, 1, "exactly one session ever adopted")
        let stillPresent = await yieldUntil(isSettledPresenting, harness: harness)
        XCTAssertTrue(stillPresent, "the live session was never touched by the stale capture")
        // The scan runner exited: no capture reservation stands while a session is live.
        try? await Task.sleep(nanoseconds: 2_000_000)
        XCTAssertNil(harness.controller.captureSlotEpoch, "the capture slot is released with the task that owns it")
        XCTAssertEqual(harness.allTargets[1].stopAndWaitCount, 0, "the fresh runtime was never retired by stale work")
    }

    func testRepeatedActivationWhilePresentingRoutesThroughCoreCancellation() async {
        let harness = Harness()
        await driveToPresenting(harness)
        let capturesBefore = harness.trace.count("targets.captureContext")
        let scansBefore = harness.targets.scanPlans.count

        harness.controller.activate()
        let cancelled = await yieldUntil(isIdle, harness: harness)
        XCTAssertTrue(cancelled, "a repeated activation cancels the live session through Core")
        // NO new AX capture: the repeated hotkey routes through Core with the dedicated
        // `.cancel(.repeatedActivation)` reason — no context snapshot, no replacement
        // capture, no drain.
        XCTAssertEqual(harness.trace.count("targets.captureContext"), capturesBefore)
        XCTAssertEqual(harness.trace.count("targets.scan"), scansBefore)
        XCTAssertEqual(harness.allTargets.count, 1, "no runtime was drained for the cancelling replacement")
        XCTAssertEqual(harness.allTargets[0].discardedCaptures.count, 0, "no pending capture existed to discard")
        XCTAssertEqual(harness.targets.releasedSessions.count, 1)
        let lines = harness.trace.lines
        let hideAt = lines.firstIndex(of: "presentation.hide")!
        let relinquishAt = lines.firstIndex(of: "input.relinquish")
        XCTAssertNotNil(relinquishAt, "the repeated-activation hide relinquishes the expected capture")
        if let relinquishAt {
            XCTAssertLessThan(relinquishAt, hideAt, "hidden via the standard order")
        }
    }

    // MARK: Capture slot (epoch-keyed reservation; no-yield back-to-back activation)

    /// Blocker 2 regression: two activations with NO yield in between. Because both
    /// `activate()` calls share ONE synchronous main-actor stretch, the first capture
    /// task cannot even start before the second activation drains that runtime — so
    /// `activate()` #2 sees the synchronously reserved slot (Core idle), drains the
    /// first runtime SYNCHRONOUSLY, and only the fresh runtime owns a pending capture.
    /// (The capture gate armed here is DELIBERATELY consumed-without-a-continuation:
    /// the cancelled-before-start task dies at its entry epoch guard.)
    func testBackToBackActivationDrainsFirstRuntimeSynchronouslyAndFreshSlotOwnsCapture() async {
        let harness = Harness()
        harness.scanAnswersTemplate = [SessionFixtures.scanResult(SessionFixtures.pressCandidate())]
        harness.allTargets[0].armCaptureGate() // documents the would-be in-flight capture

        // Back-to-back, NO yield between: the first reserves the slot + spawns the
        // capture task; the second sees the reservation and drains + reprovisions
        // synchronously, all before the asynchronous world can run.
        harness.controller.activate()
        harness.controller.activate()

        let replacement = await yieldUntil({
            harness.allTargets.count == 2 && !harness.allTargets[1].adoptPlans.isEmpty
        }, harness: harness)
        XCTAssertTrue(
            replacement,
            "the back-to-back replacement never adopted: \(harness.trace.joined())")

        // The FIRST runtime was drained SYNCHRONOUSLY (inside the second activate() call
        // chain), never resumed its gated capture into an adoption, and was closed for
        // reopening before any fresh lane existed.
        XCTAssertEqual(harness.allTargets.count, 2)
        XCTAssertEqual(harness.allTargets[0].stopAndWaitCount, 1, "the first runtime drains synchronously")
        XCTAssertTrue(harness.allTargets[0].isStopped, "the drained lane is closed for reopening")
        XCTAssertEqual(harness.allTargets.reduce(0) { $0 + $1.adoptPlans.count }, 1, "only the fresh runtime adopted")
        XCTAssertEqual(harness.allTargets[0].adoptPlans.count, 0, "the stale runtime never adopted")
        XCTAssertTrue(harness.trace.count("targets.captureContext") == 1, "the cancelled-before-start capture never reached the AX lane")
        XCTAssertEqual(harness.trace.count("targets.scan"), 1)
        XCTAssertFalse(harness.allTargets[1].isStopped, "the fresh lane is the only live one")

        // Only the FRESH runtime's capture continues to own the flow: the session
        // settles, and the fresh task's OWN defer is the only thing that releases the
        // capture slot (the stale task/defer is epoch-poisoned either way).
        let presented = await yieldUntil(isPresenting, harness: harness)
        XCTAssertTrue(presented, "the fresh runtime serves a full session")
        let slotReleased = await yieldUntil({ $0.controller.captureSlotEpoch == nil }, harness: harness)
        XCTAssertTrue(slotReleased, "the owning task releases the capture slot; no stale defer could")
        harness.input.deliver(.modifierBarrierReleased)
        let settled = await yieldUntil(isSettledPresenting, harness: harness)
        XCTAssertTrue(settled, "the fresh runtime is fully usable after the back-to-back activation")
    }

    // MARK: Stale keyed outcomes through the production entry point

    func testStaleKeyedOutcomeReleasesOnlyItsOwnPayload() async {
        let harness = Harness()
        await driveToPresenting(harness)
        let staleKey = HintSessionKey(id: 99, generation: 3)

        harness.controller.send(.scanCompleted(staleKey, SessionFixtures.scanResult(SessionFixtures.pressCandidate())))

        let released = await yieldUntil({ !$0.targets.releasedGenerations.isEmpty }, harness: harness)
        XCTAssertTrue(released, "the stale outcome never released its payload")
        XCTAssertEqual(harness.targets.releasedGenerations, [staleKey], "only the stale key's payload is released")
        XCTAssertTrue(harness.targets.releasedSessions.isEmpty, "the live session's roots stay alive")
        let untouched = await yieldUntil(isPresenting, harness: harness)
        XCTAssertTrue(untouched, "the live session is untouched")
        XCTAssertEqual(harness.presentation.snapshots.count, 1, "no refresh occurred")

        // The DUPLICATE live-key event releases nothing (core's idempotent no-op).
        let liveKey = harness.controller.reducer.state.key!
        harness.controller.send(.scanCompleted(liveKey, SessionFixtures.scanResult(SessionFixtures.pressCandidate())))
        try? await Task.sleep(nanoseconds: 2_000_000)
        XCTAssertEqual(harness.targets.releasedGenerations.count, 1, "a duplicate live-key event releases nothing")
        XCTAssertTrue(isPresenting(harness))
    }

    // MARK: Mailbox epoch tagging (rapid repeated callbacks cannot restart an idle reducer)

    /// Blocker 3 regression: mailbox entries are tagged with the lifecycle epoch at
    /// `send` time. An event queued BEFORE a terminal retirement is DISCARDED when the
    /// running drain pops it, so rapid repeated callbacks can never restart a reducer a
    /// retirement just settled to idle.
    func testQueuedOldLifecycleEventsAreDiscardedOnRetirement() async {
        let harness = Harness()
        await driveToPresenting(harness)

        // A terminal cancellation (escape) enters the mailbox FIRST. Both sends happen
        // back-to-back with NO yield, so the pump has not popped anything yet.
        harness.input.deliver(.escape)
        // A stale-context activation event queued behind it: from an idle reducer this
        // event would START A SESSION — the epoch tag is what dooms it here.
        harness.controller.send(.activateRequested(SessionFixtures.context()))

        let ended = await yieldUntil(isIdle, harness: harness)
        XCTAssertTrue(ended, "the escape ended the session terminally")

        // The drain pops the queued activation AFTER the retirement bumped the epoch:
        // the stale entry is discarded, so no session restarts.
        try? await Task.sleep(nanoseconds: 5_000_000)
        XCTAssertTrue(isIdle(harness), "a queued old-lifecycle activation cannot restart the idle reducer")
        XCTAssertFalse(harness.controller.provisioned, "retirement stands; nothing re-provisioned")
        XCTAssertEqual(harness.trace.count("targets.captureContext"), 1, "no replacement capture ran")
        XCTAssertEqual(harness.targets.releasedSessions.count, 1, "exactly one session release")
        XCTAssertEqual(harness.targets.releasedGenerations.count, 0)
    }

    // MARK: Stop racing gated in-flight calls (drained lanes resolve; fresh survives)

    /// Stop while the capture is gated, then reactivate BACK-TO-BACK with the stop
    /// (no yield). The drained lane resolves the gated capture synchronously
    /// (`stopAndWait` resumes gated continuations — production-faithful); the stale task
    /// must be unable to retire the fresh adapters, clear the fresh capture slot, or
    /// touch the fresh reducer.
    func testStopDuringGatedCaptureThenImmediateReactivationLeavesFreshRuntimeIntact() async {
        let harness = Harness()
        harness.scanAnswersTemplate = [SessionFixtures.scanResult(SessionFixtures.pressCandidate())]
        harness.allTargets[0].armCaptureGate()
        harness.controller.activate()
        let gated = await yieldUntil({ $0.trace.count("targets.captureContext") == 1 }, harness: harness)
        XCTAssertTrue(gated, "the capture never went mid-flight")

        // Stop, then IMMEDIATELY reactivate (no yield between): the drain resolves the
        // gated capture synchronously; the replacement reserves a FRESH capture slot.
        harness.controller.hardStop()
        harness.controller.activate()

        let reprovisioned = await yieldUntil({
            harness.allTargets.count == 2 && !harness.allTargets[1].adoptPlans.isEmpty
        }, harness: harness)
        XCTAssertTrue(reprovisioned, "the replacement never adopted: \(harness.trace.joined())")

        // The stale gated call resumed behind the drained lane and was REJECTED there:
        // the stopped recheck returned nil — the old outcome is observed, and the
        // epoch-scoped retirement made it powerless over the fresh runtime.
        let rejected = await yieldUntil(
            { harness.trace.count("targets.captureRejectedAfterStop") == 1 }, harness: harness)
        XCTAssertEqual(harness.trace.count("targets.captureRejectedAfterStop"), 1, "exactly one stale rejection")
        XCTAssertTrue(rejected)

        // The fresh runtime + fresh reducer survive the stale outcome end to end.
        let presented = await yieldUntil(isPresenting, harness: harness)
        XCTAssertTrue(presented, "the fresh runtime serves its session")
        XCTAssertEqual(harness.allTargets[0].stopAndWaitCount, 1, "the drained lane drained exactly once")
        XCTAssertEqual(harness.allTargets[1].stopAndWaitCount, 0, "NO fresh adapter was retired by stale work")
        XCTAssertEqual(harness.allTargets.reduce(0) { $0 + $1.adoptPlans.count }, 1, "only the fresh session adopted")
        harness.input.deliver(.modifierBarrierReleased)
        let settled = await yieldUntil(isSettledPresenting, harness: harness)
        XCTAssertTrue(settled, "the fresh runtime is fully usable after the stop race")
        let slotReleased = await yieldUntil({ $0.controller.captureSlotEpoch == nil }, harness: harness)
        XCTAssertTrue(slotReleased, "the fresh task's OWN defer released the fresh slot; no stale defer could")
    }

    /// Stop while an AX invocation is gated mid-flight, then reactivate BACK-TO-BACK
    /// with the stop. The invocation's adapter was bound BEFORE its await: the stale
    /// outcome completes inside the drained lane, is epoch-poisoned, and can neither
    /// feed the fresh reducer nor add any effect. No fresh adapter is retired, and no
    /// stale pump clears newer pump ownership.
    func testStopDuringGatedInvokeThenImmediateReactivationLeavesFreshRuntimeIntact() async {
        let harness = Harness()
        await driveToPresenting(harness)
        harness.allTargets[0].armInvokeGate()
        harness.targets.invocationAnswers = [.succeeded]
        deliver(harness, label: fullLabel(harness, of: 0))
        harness.input.deliver(.return)
        let gated = await yieldUntil({ $0.trace.count("targets.invoke") == 1 }, harness: harness)
        XCTAssertTrue(gated, "the invocation never went mid-flight")

        // Stop, then IMMEDIATELY reactivate (no yield between).
        harness.controller.hardStop()
        harness.controller.activate()

        let reprovisioned = await yieldUntil({
            harness.allTargets.count == 2 && !harness.allTargets[1].adoptPlans.isEmpty
        }, harness: harness)
        XCTAssertTrue(reprovisioned, "the replacement never adopted: \(harness.trace.joined())")

        let presented = await yieldUntil(isPresenting, harness: harness)
        XCTAssertTrue(presented, "the fresh runtime serves its session")
        XCTAssertEqual(harness.trace.count("targets.invoke"), 1, "no dispatch ever reached the fresh lane")
        XCTAssertEqual(harness.allTargets[1].stopAndWaitCount, 0, "NO fresh adapter was retired by stale work")
        XCTAssertEqual(harness.allTargets[0].stopAndWaitCount, 1, "the drained lane drained exactly once")
        XCTAssertEqual(harness.allTargets.reduce(0) { $0 + $1.releasedSessions.count }, 0,
                       "the hard stop owns payload teardown; no stale effect ran after it")
        // The fresh session settles normally.
        harness.input.deliver(.modifierBarrierReleased)
        let settled = await yieldUntil(isSettledPresenting, harness: harness)
        XCTAssertTrue(settled, "the fresh runtime is fully usable after the stop race")
    }

    /// A nil capture on the CURRENT lifecycle must still retire the runtime it belongs
    /// to, even when the counters have drifted: `hardStop` bumps both epochs once, then
    /// a later `activate` bumps ONLY the activation epoch, so on the replacement's
    /// capture `activationEpoch == lifecycleEpoch + 1`. A retirement keyed on the
    /// activation epoch would silently leave the runtime provisioned; the
    /// lifecycle-keyed retirement destroys it without poisoning the next activation.
    func testCurrentLifecycleNilCaptureRetiresItsRuntimeDespiteCounterDivergence() async {
        let harness = Harness()
        await driveToPresenting(harness)
        harness.controller.hardStop()
        XCTAssertEqual(harness.controller.provisioned, false, "hardStop cleared the first runtime")
        harness.factories.targetsContext = nil // the fresh instance's capture FAILS
        harness.controller.activate()
        let retired = await yieldUntil({
            harness.allTargets.count == 2
                && harness.allTargets[1].stopAndWaitCount == 1
                && !harness.controller.provisioned
        }, harness: harness)
        XCTAssertTrue(retired, "the nil capture path must retire the runtime it started: \(harness.trace.joined())")
        let current = harness.allTargets[1]
        XCTAssertTrue(current.isStopped, "the retired lane is closed")
        XCTAssertNil(harness.controller.captureSlotEpoch, "its own defer released the slot")
        // The retirement did not poison the following activation: the runtime is
        // recreated lazily and the session reaches presenting normally.
        harness.factories.targetsContext = SessionFixtures.context()
        harness.controller.activate()
        let rePresented = await yieldUntil(isPresenting, harness: harness)
        XCTAssertTrue(rePresented, "the next activation provisions a working runtime")
    }

    /// A stale gated capture resumed while the fresh runtime exists but is still
    /// DELIBERATELY GATED (idle reducer, provisioned adapters, fresh capture slot
    /// reserved) can retire nothing: the fresh lane is never stopped, the fresh slot
    /// reservation is never stolen by the stale defer, and the fresh session completes
    /// once its OWN gate releases. Harder than the post-adopt race: the fresh runtime
    /// has not reached any adoption state to lean on, only its own guards.
    func testStaleGatedCaptureResumedAgainstAnIdleFreshRuntimeCannotRetireIt() async {
        let harness = Harness()
        harness.scanAnswersTemplate = [SessionFixtures.scanResult(SessionFixtures.pressCandidate())]
        harness.allTargets[0].armCaptureGate()
        harness.controller.activate()
        let gated = await yieldUntil({ $0.trace.count("targets.captureContext") == 1 }, harness: harness)
        XCTAssertTrue(gated, "the first capture never went mid-flight")

        // The replacement: pre-register a fresh lane and gate it BEFORE the second
        // activation. The one-pending rule hard-stops the stale runtime synchronously
        // inside `activate` (which also resolves the stale gate), then reserves a fresh
        // slot whose capture now parks on the fresh gate.
        let fresh = harness.factories.nextTargets()
        fresh.armCaptureGate()
        harness.controller.activate()

        // The stale gated call resumed behind the drained lane and was rejected there.
        // While the FRESH capture is still gated, the fresh runtime must be intact.
        let rejected = await yieldUntil(
            { $0.trace.count("targets.captureRejectedAfterStop") == 1 }, harness: harness)
        XCTAssertTrue(rejected, "the stale gated capture completed as a drained-lane rejection")
        XCTAssertTrue(harness.controller.provisioned, "the fresh runtime stays provisioned while idle")
        XCTAssertTrue(isIdle(harness), "the fresh reducer is still idle (capture gated)")
        XCTAssertFalse(fresh.isStopped, "the fresh lane was never drained by stale work")
        XCTAssertEqual(fresh.stopAndWaitCount, 0, "stale work must not retire the fresh lane")
        XCTAssertNotNil(harness.controller.captureSlotEpoch, "the fresh reservation was not stolen")

        // The fresh capture completes on its own gate and serves the full session.
        fresh.releaseCapture()
        let presented = await yieldUntil(isPresenting, harness: harness)
        XCTAssertTrue(presented, "the fresh runtime serves its session completely")
        let slotReleased = await yieldUntil({ $0.controller.captureSlotEpoch == nil }, harness: harness)
        XCTAssertTrue(slotReleased, "the fresh task's OWN defer released the fresh slot")
    }

    /// A gated adoption on the stale runtime resumes only behind its lane's stop: its
    /// outcome must stay a strictly LOCAL cleanup — discard and (at most) a generation
    /// release on the ORIGINAL lane. It must never touch the fresh `pendingCaptureID`,
    /// the fresh runtime, or the fresh reducer, and must never enqueue a stale
    /// `scanFailed` — a wrongly routed one would bump `releasedGenerations` through the
    /// reducer's stale-key release effect, which is why the aggregate stays ZERO in both
    /// branches (a legitimate failed adoption releases the SESSION, not the generation).
    /// Parameterized over the FRESH adoption result because the stale lane post-resume
    /// is stopped (its post-gate recheck fails): a successful fresh instantiation must
    /// not be poisoned by the stale lane, and a failing one must fail on its OWN key.
    func testStaleGatedAdoptionCannotMutateFreshStateOrSendScanFailed() async {
        for freshAdoptSucceeds in [true, false] {
            let harness = Harness()
            await driveToPresenting(harness)
            // End lifecycle 0 fail-closed-free: escape cancels and terminally retires.
            harness.input.deliver(.escape)
            let ended = await yieldUntil(isIdle, harness: harness)
            XCTAssertTrue(ended, "escape cancelled the first session: \(harness.trace.joined())")

            // Fresh runtime for the next activation: adopt result templated, adopt gate
            // armed, BEFORE the controller's lazy factory call.
            harness.factories.targetsAdoptResult = freshAdoptSucceeds
            let stale = harness.factories.nextTargets()
            stale.armAdoptGate()
            harness.controller.activate()
            let gated = await yieldUntil({ $0.trace.count("targets.adoptCapture") == 2 }, harness: harness)
            XCTAssertTrue(gated, "the second adoption never went mid-flight: \(harness.trace.joined())")

            // Swap lifetimes back-to-back: hardStop resolves the stale adopt gate
            // synchronously (which resumes the gated adoption behind its epoch guards),
            // and the immediate reactivation provisions the fresh runtime.
            harness.controller.hardStop()
            harness.controller.activate()
            let fresh = harness.allTargets[2]
            let reprovisioned = await yieldUntil({
                harness.allTargets.count == 3 && !fresh.adoptPlans.isEmpty
            }, harness: harness)
            XCTAssertTrue(reprovisioned, "the replacement never adopted: \(harness.trace.joined())")

            // Stale adoption: failed at its own post-gate recheck, cleanup local-only.
            XCTAssertEqual(stale.discardedCaptures, [StubSessionTargets.fixedPendingID],
                           "stale adoption cleanup is local-only")
            XCTAssertEqual(stale.releasedGenerations.count, 0,
                           "stale adoption released nothing on its own lane")
            XCTAssertEqual(stale.stopAndWaitCount, 1, "the stale lane drained exactly once")
            // The aggregate discriminator: no stale `scanFailed` may EVER reach the
            // reducer in either branch.
            let totalGenerations = harness.allTargets.reduce(0) { $0 + $1.releasedGenerations.count }
            XCTAssertEqual(totalGenerations, 0, "no stale scanFailed ever reached the reducer")
            // Fresh state: only the fresh session adopted; fresh failure stays fresh.
            XCTAssertEqual(fresh.adoptPlans.count, 1, "only the fresh session adopted")
            XCTAssertTrue(fresh.discardedCaptures.isEmpty == freshAdoptSucceeds,
                          "a fresh failed adoption discards its OWN capture")
            XCTAssertEqual(fresh.scanPlans.count, freshAdoptSucceeds ? 1 : 0,
                           "the scan waits for adoption")
            XCTAssertEqual(fresh.stopAndWaitCount, freshAdoptSucceeds ? 0 : 1,
                           "the fresh lane only retires on its OWN failed adoption")
            let totalSessions = harness.allTargets.reduce(0) { $0 + $1.releasedSessions.count }
            XCTAssertEqual(totalSessions, freshAdoptSucceeds ? 1 : 2,
                           "session releases: the escaped one, plus a failed fresh adoption")
            if freshAdoptSucceeds {
                let presented = await yieldUntil(isPresenting, harness: harness)
                XCTAssertTrue(presented, "the fresh runtime reaches presenting unpoisoned")
            } else {
                let retired = await yieldUntil({ !harness.controller.provisioned }, harness: harness)
                XCTAssertTrue(retired, "the fresh failed adoption retires ITS runtime locally")
            }
        }
    }

    func testCancellationSourcesEndTheSessionExactlyOnce() async {

        struct SourceCase { let name: String; let trusted: Bool; let trigger: (Harness) -> Void; let cancels: Bool }
        let sourceCases: [SourceCase] = [
            SourceCase(name: "otherAppActivated", trusted: true, trigger: { $0.controller.workspaceAppActivated(pid: 99_999) }, cancels: true),
            SourceCase(name: "sameTargetActivated", trusted: true, trigger: { $0.controller.workspaceAppActivated(pid: SessionFixtures.targetPid) }, cancels: false),
            SourceCase(name: "targetTerminated", trusted: true, trigger: { $0.controller.workspaceAppTerminated(pid: SessionFixtures.targetPid) }, cancels: true),
            SourceCase(name: "unrelatedTerminated", trusted: true, trigger: { $0.controller.workspaceAppTerminated(pid: 99_999) }, cancels: false),
            SourceCase(name: "wake", trusted: true, trigger: { $0.controller.workspaceDidWake() }, cancels: true),
            SourceCase(name: "accessibilityRevoked", trusted: false, trigger: { $0.controller.appDidBecomeActive() }, cancels: true),
            SourceCase(name: "accessibilityStillGranted", trusted: true, trigger: { $0.controller.appDidBecomeActive() }, cancels: false),
            SourceCase(name: "displayTopologyChange", trusted: true, trigger: { $0.presentation.invalidateDisplayTopology() }, cancels: true),
            SourceCase(name: "overlayCaptureLost", trusted: true, trigger: { $0.presentation.captureLostHandler?() }, cancels: true),
            SourceCase(name: "inputSecureInput", trusted: true, trigger: { $0.input.deliverCancel(.secureInput) }, cancels: true),
            SourceCase(name: "escape", trusted: true, trigger: { $0.input.deliver(.escape) }, cancels: true),
        ]
        for entry in sourceCases {
            let harness = Harness(trusted: entry.trusted)
            await driveToPresenting(harness)
            entry.trigger(harness)

            if entry.cancels {
                let ended = await yieldUntil(isIdle, harness: harness)
                XCTAssertTrue(ended, "source \(entry.name) must cancel the session fail-closed")
                XCTAssertEqual(harness.presentation.hiddenKeys.count, 1, "source \(entry.name): exactly one hide")
                XCTAssertEqual(harness.targets.releasedSessions.count, 1, "source \(entry.name): exactly one session release")
                XCTAssertEqual(harness.targets.releasedGenerations.count, 0, "source \(entry.name): no partial generation release")
                let lines = harness.trace.lines
                let hideAt = lines.firstIndex(of: "presentation.hide")!
                let relinquishAt = lines.firstIndex(of: "input.relinquish")
                XCTAssertNotNil(relinquishAt, "source \(entry.name): expected capture relinquished")
                if let relinquishAt {
                    XCTAssertLessThan(relinquishAt, hideAt, "source \(entry.name): standard hide order")
                }
            } else {
                XCTAssertEqual(harness.presentation.hiddenKeys.count, 0, "source \(entry.name) must not cancel")
                let stillLive = await yieldUntil(isPresenting, harness: harness)
                XCTAssertTrue(stillLive, "source \(entry.name): session stays live")
            }
        }
    }

    // MARK: Terminal retirement (no poisoning of future activations)

    func testTerminalRetirementDestroysAdaptersWithoutTouchingTheIdleReducer() async {
        let harness = Harness()
        await driveToPresenting(harness)
        // Pre-retirement baselines: every retired counter is compared against the value
        // at retirement.
        let sessionsBefore = harness.targets.releasedSessions.count
        let scansBefore = harness.trace.count("targets.scan")

        harness.input.deliver(.escape) // terminal cancellation with full release
        let ended = await yieldUntil(isIdle, harness: harness)
        XCTAssertTrue(ended, "escape ends the session")
        // The terminal teardown ran to completion: adapters destroyed.
        XCTAssertEqual(harness.targets.releasedSessions.count, sessionsBefore + 1, "exactly one session release")
        XCTAssertEqual(harness.trace.count("targets.scan"), scansBefore, "retirement never rescans")
        XCTAssertEqual(harness.presentation.stopCount, 1)
        XCTAssertEqual(harness.input.stopCount, 1)
        XCTAssertEqual(harness.targets.stopAndWaitCount, 1)
        XCTAssertEqual(harness.presentation.installedResponderViews, 1, "one install total")
        XCTAssertNil(harness.presentation.onInvalidated, "overlay callbacks detached")
        XCTAssertNil(harness.input.delegate, "input delegate detached (BEFORE stop, per contract)")
        XCTAssertTrue(harness.allTargets[0].isStopped, "the AX lane is closed for reopening")

        // Order proof: the session release happened BEFORE the adapters stopped.
        let lines = harness.trace.lines
        XCTAssertLessThan(lines.firstIndex(of: "targets.releaseSession")!, lines.firstIndex(of: "input.stop")!)

        // Stopped input, judged by ABSENCE OF DELEGATE EFFECTS (not traces): reattach the
        // retired input and stop it again — the real adapter's stop() is idempotent
        // (notifies exactly once, already spent during retirement), so nothing reaches
        // the controller and no counter or state moves.
        let retiredInput = harness.allInputs[0]
        XCTAssertTrue(retiredInput.stopped, "the input stub models terminal-stop behavior")
        retiredInput.delegate = harness.controller
        retiredInput.stop() // idempotent: no second .toolDisabled notification
        try? await Task.sleep(nanoseconds: 2_000_000)
        XCTAssertTrue(isIdle(harness), "a stopped input cannot restart an idle reducer")
        XCTAssertEqual(harness.trace.count("targets.scan"), scansBefore, "no scan followed the stopped callback")

        // After a stop, deliveries — even a fresh cancel — are truly silent: no delegate
        // effect, no state change.
        retiredInput.deliver(.escape)
        retiredInput.deliverCancel(.secureInput)
        XCTAssertTrue(isIdle(harness))
        XCTAssertEqual(harness.targets.releasedSessions.count, sessionsBefore + 1, "still exactly one session release")
        XCTAssertEqual(harness.trace.count("targets.scan"), scansBefore, "a stopped input delivers nothing")
    }

    func testTerminalRetirementDoesNotPoisonTheNextActivation() async {
        let harness = Harness()
        await driveToPresenting(harness)
        harness.input.deliver(.escape)
        let ended = await yieldUntil(isIdle, harness: harness)
        XCTAssertTrue(ended)
        XCTAssertEqual(harness.allTargets.count, 1, "exactly one runtime existed so far")
        // Pre-reactivation baselines: the retired counters NEVER move again.
        let retiredBeginBaseline = harness.allInputs[0].beginInputCount
        let retiredInstallBaseline = harness.allPresentations[0].installedResponderViews
        let retiredSnapshotBaseline = harness.allPresentations[0].snapshots.count

        // The next activation provisions FRESH adapters and starts a session normally —
        // a terminal Secure Input / capture loss never poisons it.
        harness.controller.activate()
        let reprovisioned = await yieldUntil({ harness.allTargets.count == 2 }, harness: harness)
        XCTAssertTrue(reprovisioned, "the next activation lazily provisions a fresh runtime")
        let presented = await yieldUntil(isPresenting, harness: harness)
        XCTAssertTrue(presented, "the fresh runtime serves the next session: \(harness.trace.joined())")
        harness.input.deliver(.modifierBarrierReleased)
        let armed = await yieldUntil(isSettledPresenting, harness: harness)
        XCTAssertTrue(armed)

        // The fresh INPUT's counters reflect only ITS OWN session, and the retired
        // instances match their pre-reactivation baselines exactly.
        XCTAssertEqual(harness.input.beginInputCount, 1, "the fresh input armed once")
        XCTAssertEqual(harness.allInputs.count, 2, "one fresh input was created, not reused")
        XCTAssertEqual(harness.allInputs[0].beginInputCount, retiredBeginBaseline, "the retired input armed nothing more")

        // The fresh PRESENTATION received exactly one snapshot of its own; the aggregate
        // across both presentations is asserted explicitly so neither lane is implied.
        let freshPresentation = harness.allPresentations[1]
        XCTAssertEqual(freshPresentation.snapshots.count, 1, "the fresh presentation received exactly one snapshot")
        let aggregateSnapshots = harness.allPresentations.reduce(0) { $0 + $1.snapshots.count }
        XCTAssertEqual(aggregateSnapshots, retiredSnapshotBaseline + 1, "aggregate: retired baseline + one fresh snapshot")
        // Responder installs: fresh lane installed once; the retired lane never changed.
        XCTAssertEqual(freshPresentation.installedResponderViews, 1, "the fresh presentation installed once")
        XCTAssertEqual(harness.allPresentations[0].installedResponderViews, retiredInstallBaseline)
    }

    // MARK: Per-activation display snapshot (multi-display, primary-anchored)

    func testDisplaySnapshotConversionIsPrimaryAnchoredForADisplayAbovePrimary() {
        // AppKit global frames (bottom-left origin): a primary 2000×1250 display and a
        // second display physically ABOVE it, occupying AppKit y 1250...2500.
        let appKitFrames = [
            CGRect(x: 0, y: 0, width: 2_000, height: 1_250),
            CGRect(x: 0, y: 1_250, width: 2_500, height: 1_250),
        ]
        // PRIMARY anchor ONLY: the primary screen's own maxY, never the global maximum
        // (2500 — using it would silently clamp the above-display content on-screen).
        let converted = HintDisplaySnapshotGeometry.accessibilityFrames(from: appKitFrames, primaryMaxY: 1_250)

        XCTAssertEqual(converted.count, 2)
        // Primary display: identity (its AppKit maxY equals the anchor).
        XCTAssertEqual(converted[0], HintRect(x: 0, y: 0, width: 2_000, height: 1_250))
        // The display ABOVE the primary sits at NEGATIVE accessibility Y: its AppKit
        // bottom edge (1250) aligns with the primary's top, so its accessibility top is
        // 1250 - 2500 = -1250.
        XCTAssertEqual(converted[1], HintRect(x: 0, y: -1_250, width: 2_500, height: 1_250))

        // Determinism: the same anchor always yields the same frames, and a wrong anchor
        // (the maximum display maxY) produces a provably different result.
        let again = HintDisplaySnapshotGeometry.accessibilityFrames(from: appKitFrames, primaryMaxY: 1_250)
        XCTAssertEqual(again, converted)
        let wrongAnchor = HintDisplaySnapshotGeometry.accessibilityFrames(from: appKitFrames, primaryMaxY: 2_500)
        XCTAssertNotEqual(wrongAnchor, converted, "the maximum-display anchor must differ from the primary anchor")
    }

    func testDisplaySnapshotIsTakenOncePerActivationAndReusedThroughRescan() async {
        let harness = Harness()
        let press = SessionFixtures.pressCandidate()
        let region = SessionFixtures.scrollRegionCandidate(continuity: "$cont.region.1")
        await driveToPresenting(harness, result: SessionFixtures.scanResult(press, region))
        // ONE provider call per activation: the display snapshot was built exactly once,
        // even though the presentation lane already received show + update.
        XCTAssertEqual(harness.displaySnapshotCalls, 1)
        let screensSeenCount = harness.allPresentations.reduce(0) { $0 + $1.screensSeen.count }
        XCTAssertEqual(screensSeenCount, 2, "show + update each received the activation snapshot")
        let snapshotScreenCount = SessionFixtures.screens.count

        // Pre-seed the rescan answer BEFORE the scroll dispatch (same race as above).
        harness.targets.scanAnswers = [SessionFixtures.scanResult(press, region)]

        await dispatchScroll(harness, .left, mutation: .applied)
        let secondScan = await yieldUntil({ $0.targets.scanPlans.count == 2 }, harness: harness)
        XCTAssertTrue(secondScan, "the rescan ran")
        // The rescan REUSED the activation snapshot: no extra provider call, and every
        // screen array handed to the lane is the same snapshot shape.
        XCTAssertEqual(harness.displaySnapshotCalls, 1, "the rescan reused the activation snapshot")
        let screensSeenCountAfterRescan = harness.allPresentations.reduce(0) { $0 + $1.screensSeen.count }
        XCTAssertEqual(screensSeenCountAfterRescan, 4, "rescan show + rescan update reused the same snapshot")
        for screens in harness.allPresentations.flatMap({ $0.screensSeen }) {
            XCTAssertEqual(screens.count, snapshotScreenCount, "every presentation effect sees the activation snapshot")
        }
    }

    // MARK: Fail-closed adapter failures

    func testFailedAdoptionDiscardsCaptureAndFeedsScanFailedFailClosed() async {
        let harness = Harness()
        harness.targetsAdoptResult = false
        harness.controller.activate()
        let ended = await yieldUntil(isIdle, harness: harness)
        XCTAssertTrue(ended, "a failed adoption cannot start a session")
        XCTAssertEqual(harness.targets.discardedCaptures, [StubSessionTargets.fixedPendingID])
        XCTAssertEqual(harness.trace.count("targets.scan"), 0, "the scan waits for adoption")
        let lines = harness.trace.lines
        let discardAt = lines.firstIndex(of: "targets.discardPendingCapture")!
        XCTAssertLessThan(discardAt, lines.firstIndex(of: "presentation.hide")!, "dismissal runs before teardown effects")
        XCTAssertEqual(harness.targets.releasedSessions.count, 1)
        // Terminal: the runtime is destroyed after the failed adoption settles.
        let drained = await yieldUntil({ harness.targets.stopAndWaitCount == 1 }, harness: harness)
        XCTAssertTrue(drained, "the failed runtime is retired")
    }

    func testNilScanResultFailsClosedAsTimeoutWithoutRescan() async {
        let harness = Harness()
        harness.scanAnswersTemplate = [nil]
        harness.controller.activate()
        let ended = await yieldUntil(isIdle, harness: harness)
        XCTAssertTrue(ended)
        let lines = harness.trace.lines
        let scanAt = lines.firstIndex(of: "targets.scan")!
        XCTAssertLessThan(scanAt, lines.firstIndex(of: "presentation.hide")!, "the timeout path hides fail-closed")
        XCTAssertEqual(harness.targets.releasedSessions.count, 1)
        XCTAssertEqual(harness.targets.releasedGenerations.count, 0, "timeouts never rescan")
        XCTAssertEqual(harness.controller.phase, .idle)
        XCTAssertFalse(harness.controller.provisioned, "terminal retirement destroyed the runtime")
    }

    func testPresentationRejectionCancelsFailClosed() async {
        let harness = Harness()
        harness.presentationUpdateResult = false // the FIRST update is the showOverlays effect
        harness.controller.activate()
        let ended = await yieldUntil(isIdle, harness: harness)
        XCTAssertTrue(ended, "an unacceptable update cancels fail-closed")
        let lines = harness.trace.lines
        XCTAssertLessThan(lines.firstIndex(of: "presentation.update")!, lines.firstIndex(of: "presentation.hide")!)
        XCTAssertEqual(harness.targets.releasedSessions.count, 1)
        XCTAssertEqual(harness.presentation.snapshots.count, 1, "exactly one core snapshot reached the lane")
    }

    // MARK: Hard teardown

    func testHardStopDrainsEveryLaneSynchronouslyInContractOrder() async {
        let harness = Harness()
        await driveToPresenting(harness)

        harness.controller.hardStop() // synchronous: no await before these asserts
        XCTAssertTrue(isIdle(harness), "fresh idle reducer immediately")
        XCTAssertFalse(harness.controller.provisioned)
        XCTAssertEqual(harness.controller.phase, .idle)
        XCTAssertEqual(harness.controller.captureSlotEpoch, nil, "no capture reservation survives the stop")
        XCTAssertEqual(harness.targets.stopAndWaitCount, 1, "the AX lane drains exactly once")
        XCTAssertTrue(harness.targets.isStopped, "the AX lane is closed for reopening")
        XCTAssertEqual(harness.presentation.stopCount, 1)
        XCTAssertEqual(harness.input.stopCount, 1, "the real adapter notifies its delegate exactly once — the delegate was detached first")
        XCTAssertNil(harness.presentation.onInvalidated, "overlay callbacks detached")
        XCTAssertNil(harness.input.delegate, "input delegate detached")
        XCTAssertTrue(harness.targets.releasedSessions.isEmpty, "stopAndWait owns the payload teardown; no effect runs after")

        let lines = harness.trace.lines
        let stopAt = lines.firstIndex(of: "targets.stopAndWait")!
        let inputStopAt = lines.firstIndex(of: "input.stop")
        XCTAssertNotNil(inputStopAt, "input.stop must have run during the hard stop")
        let inputRelinquishAt = lines.firstIndex(of: "input.relinquish")
        XCTAssertNotNil(inputRelinquishAt, "the expected capture must have been relinquished")
        let presentationStopAt = lines.firstIndex(of: "presentation.stop")
        XCTAssertNotNil(presentationStopAt, "presentation.stop must have run during the hard stop")
        if let inputStopAt, let inputRelinquishAt, let presentationStopAt {
            XCTAssertLessThan(inputRelinquishAt, inputStopAt, "expected capture is relinquished first")
            XCTAssertLessThan(inputStopAt, stopAt, "input stops before the AX drain")
            XCTAssertLessThan(presentationStopAt, stopAt, "presentation stops before the AX drain")
        }
    }

    func testHardStopLeavesAFreshRuntimeThatReactivatesCleanly() async {
        let harness = Harness()
        await driveToPresenting(harness)
        let firstSnapshots = harness.presentation.snapshots.count
        let retiredBeginBaseline = harness.allInputs[0].beginInputCount
        harness.controller.hardStop()

        harness.scanAnswersTemplate = [SessionFixtures.scanResult(SessionFixtures.pressCandidate())]
        harness.controller.activate()
        let reprovisioned = await yieldUntil({ harness.allTargets.count == 2 }, harness: harness)
        XCTAssertTrue(reprovisioned, "hard stop tears down; the next activation provisions fresh")
        let presented = await yieldUntil(isPresenting, harness: harness)
        XCTAssertTrue(presented, "a stopped controller reactivates cleanly")
        harness.input.deliver(.modifierBarrierReleased)
        let armed = await yieldUntil({ $0.input.beginInputCount == 1 }, harness: harness)
        XCTAssertTrue(armed, "the fresh input armed once on its own session")
        XCTAssertEqual(harness.allInputs[0].beginInputCount, retiredBeginBaseline, "the retired input armed nothing more")
        XCTAssertEqual(harness.presentation.snapshots.count, firstSnapshots + 1, "a fresh snapshot arrived")
        XCTAssertEqual(harness.allTargets[0].stopAndWaitCount, 1, "still exactly one hard drain overall")
    }

    func testHardStopPoisonsLateScanOutcomeAndSavedCallbacks() async {
        let harness = Harness()
        harness.targets.armScanGate() // first targets instance (created by the factory below)
        harness.controller.activate() // capture → adopt → scan (gated mid-flight)
        let gated = await yieldUntil(
            { $0.trace.count("targets.scan") == 1 && !$0.allTargets[0].adoptPlans.isEmpty }, harness: harness)
        XCTAssertTrue(gated, "the scan never went mid-flight")

        let scansAtStop = harness.allTargets[0].scanPlans.count
        harness.controller.hardStop()
        XCTAssertTrue(isIdle(harness))
        // Snapshot AFTER the stop and BEFORE releasing the gate: the whole resurrection
        // window is measured from this baseline.
        let linesAtStop = harness.trace.lines.count

        // 1) The gated scan resolves AFTER the stop: the late result cannot resurrect.
        harness.allTargets[0].releaseScan()
        try? await Task.sleep(nanoseconds: 5_000_000)
        XCTAssertEqual(harness.allTargets.reduce(0) { $0 + $1.scanPlans.count }, scansAtStop, "no scan resurrected")
        XCTAssertEqual(harness.trace.lines.count, linesAtStop, "no traced lane call resurrected")
        XCTAssertTrue(isIdle(harness))

        // 2) Saved adapter callbacks after the stop are epoch-dead.
        harness.allPresentations[0].captureLostHandler?()
        harness.allPresentations[0].invalidateDisplayTopology()
        harness.allInputs[0].deliver(.escape)
        harness.allInputs[0].deliverCancel(.captureLost)
        // 3) No provisioning happened behind the test's back: no new adapters appeared.
        XCTAssertEqual(harness.allTargets.count, 1)
        XCTAssertEqual(harness.trace.lines.count, linesAtStop, "still nothing resurrected")
        XCTAssertEqual(harness.allTargets[0].stopAndWaitCount, 1, "no second drain without a new provisioning")
    }
}

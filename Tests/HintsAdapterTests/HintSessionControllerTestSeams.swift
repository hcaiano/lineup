import AppKit
import XCTest
@testable import lineup
import HintsCore

// ============================================================================
// Deterministic stub seams for `HintSessionController` lifecycle tests (Phase 3).
//
// HARD SAFETY RULES:
//   * No real Accessibility query, no window, no panel, no app launch, no input
//     synthesis, and no permission grant is required: the three lane protocols are
//     stubbed wholesale and every answer is canned.
//   * Nothing logged or asserted carries window/control/query content; tokens are
//     synthetic strings like "$token.1" and assertions are order/count-only.
//   * All stub state is touched from the main actor only (the controller and the tests
//     are @MainActor), so no lock is needed.
//
// Sequencing model: every stub records into a SHARED `SessionTrace`, and one-shot gates
// let a test hold an async adapter call open, do work on the main actor, then resume —
// so interleaving (repeated activation, late outcomes, stale results, hard-stop races) is
// deterministic without polling or sleeps beyond trivial yields.
//
// FRESHNESS: the harness factories return a FRESH stub instance per provisioning
// (production creates new adapters lazily per activation). Tests inspect either the
// CURRENT instance (`harness.targets` → last created) or every instance that ever lived
// (`harness.allTargets`), which is what makes terminal retirement observable: the OLD
// instances stay stopped and inert while the new ones serve the next session.
// ============================================================================

/// Append-only ordered trace shared by every stub in one test.
final class SessionTrace {
    private(set) var lines: [String] = []
    func append(_ line: String) { lines.append(line) }
    func joined() -> String { lines.joined(separator: ", ") }
    func count(_ needle: String) -> Int { lines.filter { $0 == needle }.count }
    func position(_ needle: String) -> Int? { lines.firstIndex(of: needle) }
}

final class StubSessionTargets: HintSessionAXTargets {
    let trace: SessionTrace
    /// The context `captureContext` returns (the test's target pid + screens).
    var capturedContext: HintTargetContext?
    var adoptResult = true
    /// FIFO of scan answers; `nil` means the lane failed/was cancelled (nil → timeout).
    var scanAnswers: [HintScanResult?] = []
    /// FIFO of invocation answers.
    var invocationAnswers: [HintInvocationOutcome] = []
    /// FIFO of scroll answers.
    var mutationAnswers: [HintMutationOutcome] = []

    // One-shot gates: `armXGate()` suspends EXACTLY the next call to that adapter, so two
    // overlapping calls cannot collide on a single continuation slot. `releaseX()` resumes.
    private var captureGateArmed = false
    private var scanGateArmed = false
    private var invokeGateArmed = false
    private var adoptGateArmed = false
    private var captureGate: CheckedContinuation<Void, Never>?
    private var scanGate: CheckedContinuation<Void, Never>?
    private var invokeGate: CheckedContinuation<Void, Never>?
    private var adoptGate: CheckedContinuation<Void, Never>?

    // Observation sinks.
    private(set) var grabbedTargets: HintActionKind = .press
    private(set) var invokedKey: HintSessionKey?
    private(set) var scannedKeys: [HintSessionKey] = []
    private(set) var scrolledOperations: [HintScrollCommand] = []
    private(set) var releasedGenerations: [HintSessionKey] = []
    private(set) var releasedSessions: [HintSessionKey] = []
    private(set) var discardedCaptures: [HintPendingCaptureID] = []
    private(set) var scanPlans: [HintScanPlan] = []
    private(set) var adoptPlans: [HintSessionKey] = []
    private(set) var stopAndWaitCount = 0

    // Production-modeled states:
    // `stopped` — after `stopAndWait()` the real service is closed for reopening: a new
    // capture attempt is rejected and an adoption can never succeed again.
    private(set) var isStopped = false
    // `one-pending` — the real service holds at most ONE pending capture: a second
    // concurrent capture attempt is rejected while the first is unresolved.
    private(set) var pendingCaptureLive = false

    init(trace: SessionTrace) {
        self.trace = trace
    }

    // MARK: Gates

    func armCaptureGate() { captureGateArmed = true }
    func armScanGate() { scanGateArmed = true }
    func armInvokeGate() { invokeGateArmed = true }
    func armAdoptGate() { adoptGateArmed = true }
    func releaseCapture() { captureGate?.resume(); captureGate = nil }
    func releaseScan() { scanGate?.resume(); scanGate = nil }
    func releaseInvoke() { invokeGate?.resume(); invokeGate = nil }
    func releaseAdopt() { adoptGate?.resume(); adoptGate = nil }

    // MARK: HintSessionAXTargets

    func captureContext(targetPid: Int32, screens: [HintRect]) async -> HintCapturedContext? {
        trace.append("targets.captureContext")
        if isStopped {
            trace.append("targets.captureRejectedAfterStop")
            return nil
        }
        if pendingCaptureLive {
            trace.append("targets.captureRejectedOnePending")
            return nil
        }
        // The capture is now IN FLIGHT (the pending slot is taken), even across the gate.
        pendingCaptureLive = true
        if captureGateArmed {
            captureGateArmed = false
            await withCheckedContinuation { captureGate = $0 }
        }
        // RECHECK after the gate resume: `stopAndWait()` resumes gated continuations
        // while draining (production services complete their calls, not resume them),
        // and a drained lane must reject, not hand back a capture.
        if isStopped {
            trace.append("targets.captureRejectedAfterStop")
            return nil
        }
        return capturedContext.map { HintCapturedContext(pendingID: fixedPendingID, context: $0) }
    }

    static let fixedPendingID = HintPendingCaptureID("$pending")

    func adoptCapture(id: HintPendingCaptureID, for key: HintSessionKey, matching context: HintTargetContext) async -> Bool {
        trace.append("targets.adoptCapture")
        if isStopped { return false }
        if adoptGateArmed {
            adoptGateArmed = false
            await withCheckedContinuation { adoptGate = $0 }
        }
        // RECHECK after the gate resume: `stopAndWait()` resumes gated continuations,
        // and a drained lane must reject, not report a fresh adoption.
        if isStopped { return false }
        // A successful adoption moves the pending capture into a session: the pending
        // slot frees (idempotent if nothing was pending).
        pendingCaptureLive = false
        adoptPlans.append(key)
        return adoptResult
    }

    func scan(plan: HintScanPlan) async -> HintScanResult? {
        trace.append("targets.scan")
        scanPlans.append(plan)
        scannedKeys.append(plan.key)
        if scanGateArmed {
            scanGateArmed = false
            await withCheckedContinuation { scanGate = $0 }
        }
        return scanAnswers.isEmpty ? nil : scanAnswers.removeFirst()
    }

    func invoke(token: HintTargetToken, action: HintActionKind, key: HintSessionKey) async -> HintInvocationOutcome {
        trace.append("targets.invoke")
        grabbedTargets = action
        invokedKey = key
        if invokeGateArmed {
            invokeGateArmed = false
            await withCheckedContinuation { invokeGate = $0 }
        }
        return invocationAnswers.isEmpty ? .failed : invocationAnswers.removeFirst()
    }

    func scroll(token: HintTargetToken, operation: HintScrollCommand, key: HintSessionKey) async -> HintMutationOutcome {
        trace.append("targets.scroll")
        scrolledOperations.append(operation)
        return mutationAnswers.isEmpty ? .failed : mutationAnswers.removeFirst()
    }

    func releaseGeneration(_ key: HintSessionKey) async {
        trace.append("targets.releaseGeneration")
        releasedGenerations.append(key)
    }

    func releaseSession(_ key: HintSessionKey) async {
        trace.append("targets.releaseSession")
        releasedSessions.append(key)
    }

    func discardPendingCapture(_ id: HintPendingCaptureID) async {
        trace.append("targets.discardPendingCapture")
        discardedCaptures.append(id)
        // A discarded capture vacates the pending slot it occupied.
        pendingCaptureLive = false
    }

    func stopAndWait() {
        trace.append("targets.stopAndWait")
        stopAndWaitCount += 1
        // Terminal: the real service is closed for reopening; a pending capture dies here.
        isStopped = true
        pendingCaptureLive = false
        // Synchronously RESUME every gated in-flight call so the old work can finish
        // behind its own epoch guards — matching a drained production service, whose
        // suspended calls complete (never stay suspended forever) during a drain. The
        // gates are consumed: later test-side `releaseX()` calls are no-ops.
        if let gate = captureGate { captureGate = nil; gate.resume() }
        if let gate = scanGate { scanGate = nil; gate.resume() }
        if let gate = invokeGate { invokeGate = nil; gate.resume() }
        if let gate = adoptGate { adoptGate = nil; gate.resume() }
    }
}

final class StubSessionPresentation: HintSessionPresentation {
    let trace: SessionTrace
    var showResult = true
    var updateResult = true
    var onInvalidated: ((HintOverlayInvalidation) -> Void)?
    private(set) var shownStatuses: [HintOverlayStatus] = []
    private(set) var snapshots: [HintPresentationSnapshot] = []
    private(set) var hiddenKeys: [HintSessionKey] = []
    /// Number of responder INSTALLS accepted by this lane instance. A second install
    /// while the responder is still attached is REJECTED (returns false): the production
    /// contract installs exactly once per presentation attach.
    private(set) var installedResponderViews = 0
    /// Every screen array handed to `show`/`update` — the per-activation snapshot proof.
    private(set) var screensSeen: [[NSScreen]] = []
    private(set) var stopCount = 0
    /// True while this lane holds the modal input responder (install accepted and not
    /// yet removed/stopped).
    private(set) var responderAttached = false
    /// Set by a successful `installInputResponder`; tests fire it to simulate loss.
    var captureLostHandler: (() -> Void)?

    init(trace: SessionTrace) {
        self.trace = trace
    }

    private func noteScreens(_ screens: [NSScreen]) { screensSeen.append(screens) }

    func show(generation: HintSessionKey, context: HintTargetContext, screens: [NSScreen], status: HintOverlayStatus) -> Bool {
        trace.append("presentation.show.\(status)")
        noteScreens(screens)
        shownStatuses.append(status)
        return showResult
    }

    func update(snapshot: HintPresentationSnapshot, context: HintTargetContext, screens: [NSScreen], status: HintOverlayStatus) -> Bool {
        trace.append("presentation.update")
        noteScreens(screens)
        snapshots.append(snapshot)
        return updateResult
    }

    func transition(to status: HintOverlayStatus, generation: HintSessionKey) -> Bool {
        trace.append("presentation.transition.\(status)")
        return true
    }

    func hide(generation: HintSessionKey) {
        trace.append("presentation.hide")
        hiddenKeys.append(generation)
        // Hidden overlays end the responder attachment: the next scan (a rescan after an
        // invocation's observational release) installs on its own canvas again. Same-
        // session scroll rescans never hide, so they retain the attachment.
        responderAttached = false
        captureLostHandler = nil
    }

    func stop() {
        trace.append("presentation.stop")
        stopCount += 1
        responderAttached = false
        captureLostHandler = nil
    }

    func installInputResponder(_ view: NSView, onCaptureLost: @escaping () -> Void) -> Bool {
        // REJECT a second install while attached: one responder per presentation attach.
        guard !responderAttached else {
            trace.append("presentation.installResponder.rejected")
            return false
        }
        trace.append("presentation.installResponder")
        installedResponderViews += 1
        responderAttached = true
        captureLostHandler = onCaptureLost
        return true
    }

    func removeInputResponder() {
        trace.append("presentation.removeResponder")
        responderAttached = false
        captureLostHandler = nil
    }

    /// Test-side delivery of the display-topology invalidation callback.
    func invalidateDisplayTopology() {
        onInvalidated?(.displayTopologyChanged)
    }
}

final class StubSessionInput: HintSessionInput {
    let trace: SessionTrace
    /// Real controller needed only to satisfy the delegate method signature; the
    /// controller under test ignores the sender identity.
    private let probe = HintInputController()
    weak var delegate: HintInputControllerDelegate?
    let responderView = HintInputResponderView()

    private(set) var awaitModifierMasks: [NSEvent.ModifierFlags] = []
    private(set) var beginInputCount = 0
    private(set) var relinquishCount = 0
    private(set) var stopCount = 0
    private(set) var cancelReasons: [HintCancellationReason] = []
    /// Terminal modeling: after `stop()` the real input controller stops observing and
    /// never delivers again; the stub matches, so post-stop deliveries are truly silent
    /// (recorded in a sink, not the trace, so trace baselines stay stable).
    private(set) var stopped = false
    private(set) var droppedAfterStop = 0

    init(trace: SessionTrace) {
        self.trace = trace
    }

    func captureConfirmed(window: NSWindow) {
        trace.append("input.captureConfirmed")
    }

    func captureLost() {
        trace.append("input.captureLost")
    }

    func awaitModifierRelease(modifierMask: NSEvent.ModifierFlags) {
        trace.append("input.awaitModifierRelease")
        awaitModifierMasks.append(modifierMask)
    }

    func beginInput() {
        trace.append("input.beginInput")
        beginInputCount += 1
    }

    func relinquishExpectedCapture() {
        trace.append("input.relinquish")
        relinquishCount += 1
    }

    func stop() {
        // TERMINAL, modeled exactly like `HintInputController.stop()`: first terminal
        // transition only (next stop is silent), torn down, and the delegate is notified
        // SYNCHRONOUSLY inside this call (`.toolDisabled`). The controller detaches the
        // delegate BEFORE calling stop() when it wants the notification to go nowhere.
        guard !stopped else { return }
        stopped = true
        trace.append("input.stop")
        stopCount += 1
        delegate?.hintInput(probe, didCancelWithReason: .toolDisabled)
    }

    func cancel(reason: HintCancellationReason) {
        trace.append("input.cancel.\(reason)")
        cancelReasons.append(reason)
    }

    // MARK: Test-side delivery

    func deliver(_ command: HintKeyCommand) {
        guard !stopped else { droppedAfterStop += 1; return }
        delegate?.hintInput(probe, didReceiveCommand: command)
    }

    /// Delivered cancellation is TERMINAL BEFORE notifying — modeled exactly like the
    /// real `HintInputController.cancel(reason:)` (`finished = true` first, then the
    /// synchronous delegate callback). After this, all deliveries are silent.
    func deliverCancel(_ reason: HintCancellationReason) {
        guard !stopped else { droppedAfterStop += 1; return }
        stopped = true
        delegate?.hintInput(probe, didCancelWithReason: reason)
    }
}

// MARK: - Shared fixtures

enum SessionFixtures {
    static let screens = NSScreen.screens // never consulted: the stubs ignore screen payloads
    static let captureScreens = [HintRect(x: 0, y: 0, width: 2_000, height: 1_200)]
    static let targetPid: Int32 = 42_42

    static func pressCandidate(pid: Int32 = targetPid, continuity: String? = nil) -> HintCandidate {
        HintCandidate(
            token: HintTargetToken("$token.1"),
            pid: pid,
            role: .button,
            advertisedActions: [.press],
            frame: HintRect(x: 10, y: 10, width: 100, height: 24),
            continuity: continuity.map(HintContinuityID.init)
        )
    }

    static func scrollRegionCandidate(pid: Int32 = targetPid, tokenRaw: String = "$token.2", continuity: String? = nil) -> HintCandidate {
        HintCandidate(
            token: HintTargetToken(tokenRaw),
            pid: pid,
            role: .scrollRegion,
            advertisedActions: [.scroll],
            frame: HintRect(x: 10, y: 10, width: 400, height: 300),
            continuity: continuity.map(HintContinuityID.init)
        )
    }

    static func context(pid: Int32 = targetPid) -> HintTargetContext {
        HintTargetContext(pid: pid, screens: captureScreens)
    }

    static func scanResult(_ candidates: HintCandidate...) -> HintScanResult {
        HintScanResult(candidates: candidates)
    }
}

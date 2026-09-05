import AppKit
import AppCore
import Carbon.HIToolbox
import HintsCore
import os

// ============================================================================
// Hints Phase 3 session controller: the one glue layer that feeds exactly ONE
// `HintSessionReducer` and executes its effects against the three Phase 2 lanes
// (AX, Input, Presentation).
//
// ORCHESTRATION CONTRACT (frozen Phase 3):
//   initial activation (strict order):
//     captureContext (async, AX lane) → reducer `.activateRequested` (pure) →
//     adoptCapture(generation 0) → scan. The `startScan` effect is DEFERRED until
//     adoption succeeds; an adoption failure feeds the reducer a keyed `scanFailed`
//     instead, so the core always owns the transition policy.
//   repeated activation:
//     while a session is ACTIVE the event is routed through Core cancellation
//     (`.activateRequested`) directly — NO new AX capture is taken. While Core is idle
//     but a pre-adoption capture is still in flight, the stale runtime is drained
//     SYNCHRONOUSLY (one-pending AX rule) and a fresh runtime is provisioned before the
//     replacement capture; the stale capture's epoch guard then drops it.
//   expected-hide/invoke order:
//     input.relinquishExpectedCapture() → presentation.hide(generation:) → AX invoke.
//     The reducer already orders the effects (`hideOverlays` before `invoke`) and the
//     `hideOverlays` handler performs the relinquish internally, so EVERY hide path —
//     invocation, rescan, cancel, replacement — has the same ordering. Scroll NEVER
//     routes through invoke: it dispatches through the dedicated scroll surface.
//   rescan: effects `[releaseGeneration(previousKey), startScan(plan)]` run in batch
//     order; the release is awaited BEFORE the next scan starts. A same-session rescan
//     reuses the modal input responder already attached to the SAME presentation lane
//     (install/confirm happen exactly once per attach; expected hide and terminal
//     teardown clear the attachment, so a brand-new runtime reinstalls).
//   terminal retirement:
//     when a drain settles the reducer at `.idle` (session end, cancellation, failed
//     scan/adoption), the adapters and active-session observers are DESTROYED without
//     touching the already-idle reducer: the lifecycle epoch is poisoned so stale
//     callbacks die at their guards, capture tasks are cancelled/cleared (the executing
//     drain is a pump task and is never cancelled), the input delegate is detached
//     BEFORE `stop()` (the real adapter notifies its delegate synchronously inside
//     stop), and queued mailbox entries are discarded by their lifecycle epoch. The
//     reducer — already idle — is never reset here, and the next activation lazily
//     provisions a completely fresh runtime, so a terminal input cancellation can never
//     poison future activations.
//   display snapshot:
//     ONE provider call per activation returns a single `HintDisplaySnapshot` — capture-
//     ready accessibility frames, the participating AppKit screens, and the primary
//     anchor — built from exactly ONE `NSScreen.screens` read, invoked only AFTER any
//     stale-runtime drain. Retained for the whole session; no presentation path re-reads
//     screens. The AppKit→accessibility conversion is anchored to the PRIMARY screen
//     (`NSScreen.screens.first`) — never the maximum display maxY — so a display
//     physically above the primary converts deterministically.
//   stop/disable (synchronous, exact order):
//     `stopping` marked and epochs invalidated FIRST → observers removed → tracked
//     tasks cancelled → input detached/relinquished/stopped → overlay callbacks
//     cleared and stopped → AX drained SYNCHRONOUSLY with `HintAXService.stopAndWait()`
//     → tracked state cleared → a fresh idle reducer left behind. No timers, no
//     polling, no stale callback resurrection: every closure and continuation carries
//     an epoch that is checked on entry, and the adapters themselves are destroyed.
//
// REENTRANCY: Input barrier callbacks can fire SYNCHRONOUSLY while the controller is
// inside effect execution (e.g. `captureConfirmed` checking Secure Input). Every event
// enters a mailbox through `send(_:)` and is reduced strictly one event at a time inside
// the drain loop; a synchronous delegate callback during an `await` window merely
// appends. `reducer.send` is touched ONLY inside the drain loop (or consistent effect
// runners that the drain awaits).
//
// SAFETY: the controller never activates Lineup, never synthesizes input, logs NOTHING
// about windows/controls/labels (count-only diagnostics only), never cancels fail-open,
// and always leaves the frontmost app frontmost.
// ============================================================================

// MARK: - Injectable capability protocols (real types conform; tests stub these)

/// The AX lane as the controller sees it. The production `HintAXService` keeps its own
/// `HintInvocationAction`/`HintScrollOperation` vocabulary, so the real adapter maps the
/// frozen core enumerations at this boundary; the controller only ever speaks core types.
protocol HintSessionAXTargets: AnyObject {
    func captureContext(targetPid: Int32, screens: [HintRect]) async -> HintCapturedContext?
    func adoptCapture(id: HintPendingCaptureID, for key: HintSessionKey, matching context: HintTargetContext) async -> Bool
    func scan(plan: HintScanPlan) async -> HintScanResult?
    /// `action` is `.press`/`.showMenu`/`.focus` only by reducer construction (`scroll`
    /// never routes through invoke). An unmapped action fails closed without dispatch.
    func invoke(token: HintTargetToken, action: HintActionKind, key: HintSessionKey) async -> HintInvocationOutcome
    func scroll(token: HintTargetToken, operation: HintScrollCommand, key: HintSessionKey) async -> HintMutationOutcome
    func releaseGeneration(_ key: HintSessionKey) async
    func releaseSession(_ key: HintSessionKey) async
    func discardPendingCapture(_ id: HintPendingCaptureID) async
    /// Synchronous hard teardown, closed for reopening exactly like
    /// `HintAXService.stopAndWait()`. Idempotent after the first call.
    func stopAndWait()
}

extension HintActionKind {
    /// The single mapping from the CORE action vocabulary to the AX lane's dispatch enum.
    /// `.scroll` is unreachable through the reducer's invoke path and maps to `nil` —
    /// the adapter FAILS CLOSED (no dispatch) rather than synthesizing anything.
    var mapped: HintInvocationAction? {
        switch self {
        case .press: return .press
        case .showMenu: return .showMenu
        case .focus: return .focus
        case .scroll: return nil
        }
    }
}

extension HintScrollCommand {
    /// One-to-one translation to the semantic AX scroll operation vocabulary.
    var mapped: HintScrollOperation {
        switch self {
        case .up: return .up
        case .down: return .down
        case .left: return .left
        case .right: return .right
        case .pageUp: return .pageUp
        case .pageDown: return .pageDown
        case .home: return .home
        case .end: return .end
        }
    }
}

extension HintScrollOperation {
    /// Inverse of `HintScrollCommand.mapped`, mirroring the translation in both directions.
    var mapped: HintScrollCommand {
        switch self {
        case .up: return .up
        case .down: return .down
        case .left: return .left
        case .right: return .right
        case .pageUp: return .pageUp
        case .pageDown: return .pageDown
        case .home: return .home
        case .end: return .end
        }
    }
}

/// The `HintInputController` surface the controller drives. The real controller
/// conforms 1:1.
protocol HintSessionInput: AnyObject {
    var delegate: HintInputControllerDelegate? { get set }
    var responderView: HintInputResponderView { get }
    func captureConfirmed(window: NSWindow)
    func captureLost()
    func awaitModifierRelease(modifierMask: NSEvent.ModifierFlags)
    func beginInput()
    func relinquishExpectedCapture()
    func stop()
    func cancel(reason: HintCancellationReason)
}

extension HintInputController: HintSessionInput {}

/// The Presentation lane as the controller drives it (a direct projection of
/// `HintOverlayController`, which conforms 1:1).
protocol HintSessionPresentation: AnyObject {
    var onInvalidated: ((HintOverlayInvalidation) -> Void)? { get set }
    func show(generation: HintSessionKey, context: HintTargetContext, screens: [NSScreen], status: HintOverlayStatus) -> Bool
    func update(snapshot: HintPresentationSnapshot, context: HintTargetContext, screens: [NSScreen], status: HintOverlayStatus) -> Bool
    func transition(to status: HintOverlayStatus, generation: HintSessionKey) -> Bool
    func hide(generation: HintSessionKey)
    func stop()
    func installInputResponder(_ view: NSView, onCaptureLost: @escaping () -> Void) -> Bool
    func removeInputResponder()
}

extension HintOverlayController: HintSessionPresentation {}

/// Real `HintAXService` adapter. Created lazily at activation time; `hardStop()` drains
/// it synchronously, so every adapter instance serves exactly one provisioning.
final class HintAXSessionTargets: HintSessionAXTargets {
    private let service: HintAXService

    init(limits: HintScanLimits) {
        self.service = HintAXService(limits: limits)
    }

    func captureContext(targetPid: Int32, screens: [HintRect]) async -> HintCapturedContext? {
        await service.captureContext(targetPid: targetPid, screens: screens)
    }

    func adoptCapture(id: HintPendingCaptureID, for key: HintSessionKey, matching context: HintTargetContext) async -> Bool {
        await service.adoptCapture(id: id, for: key, matching: context)
    }

    func scan(plan: HintScanPlan) async -> HintScanResult? {
        await service.scan(plan: plan)
    }

    func invoke(token: HintTargetToken, action: HintActionKind, key: HintSessionKey) async -> HintInvocationOutcome {
        // The unreachable action dispatches nothing: at-most-once preserved.
        guard let mapped = action.mapped else { return .failed }
        return await service.invoke(token: token, action: mapped, key: key)
    }

    func scroll(token: HintTargetToken, operation: HintScrollCommand, key: HintSessionKey) async -> HintMutationOutcome {
        await service.scroll(token: token, operation: operation.mapped, key: key)
    }

    func releaseGeneration(_ key: HintSessionKey) async {
        await service.releaseGeneration(key)
    }

    func releaseSession(_ key: HintSessionKey) async {
        await service.releaseSession(key)
    }

    func discardPendingCapture(_ id: HintPendingCaptureID) async {
        await service.discardPendingCapture(id)
    }

    func stopAndWait() {
        service.stopAndWait()
    }
}

// MARK: - Dependencies

/// Injected capabilities. A deterministic test harness replaces the adapter factories and
/// providers wholesale; the live defaults wire the three Phase 2 lanes.
@MainActor
struct HintSessionDependencies {
    var limits: HintScanLimits
    var alphabet: String
    /// Carbon modifier mask of the live activation shortcut, used (converted) as the
    /// input barrier mask. A modifierless/unassigned shortcut never provisions a session,
    /// so a session only ever starts with a nonzero mask.
    var activationModifierMask: UInt32
    var makeTargets: () -> HintSessionAXTargets
    var makeInput: () -> HintSessionInput
    var makePresentation: () -> HintSessionPresentation
    var frontmostPID: () -> Int32?
    /// ONE call per activation returns the complete display snapshot — capture-ready
    /// accessibility frames, the participating AppKit screens, and the primary anchor —
    /// built from exactly ONE `NSScreen.screens` read. The controller invokes it once
    /// (after any stale-runtime drain) and reuses it for every presentation effect; no
    /// presentation path ever consults a screen provider again.
    var displaySnapshot: () -> HintDisplaySnapshot
    var isAccessibilityTrusted: () -> Bool

    /// Real defaults. `accessibility` is the live trust source so a session is bound to
    /// actual permission state without this file reaching into `PermissionCenter`.
    static func live(
        limits: HintScanLimits,
        alphabet: String,
        activationModifierMask: UInt32,
        accessibility: @escaping () -> Bool
    ) -> HintSessionDependencies {
        HintSessionDependencies(
            limits: limits,
            alphabet: alphabet,
            activationModifierMask: activationModifierMask,
            makeTargets: { HintAXSessionTargets(limits: limits) },
            makeInput: { HintInputController() },
            makePresentation: { HintOverlayController() },
            frontmostPID: { NSWorkspace.shared.frontmostApplication?.processIdentifier },
            displaySnapshot: {
                // Exactly ONE `NSScreen.screens` read per snapshot, and the snapshot is
                // taken once per activation: both coordinate spaces and the primary
                // anchor come from the same screen list, so a mid-session display change
                // cannot split them apart.
                let screens = NSScreen.screens
                let primaryMaxY = screens.first?.frame.maxY ?? 0
                return HintDisplaySnapshot(
                    primaryMaxY: primaryMaxY,
                    accessibilityFrames: HintDisplaySnapshotGeometry.accessibilityFrames(
                        from: screens.map(\.frame), primaryMaxY: primaryMaxY),
                    screens: screens
                )
            },
            isAccessibilityTrusted: accessibility
        )
    }
}

/// The ONE per-activation display snapshot. `accessibilityScreens`/`overlayScreens`
/// providers were merged into this single value: the capture coordinates, the overlay
/// screens, and the primary anchor (`primaryMaxY`) were captured together from exactly
/// one screen read, so they can never disagree mid-session.
struct HintDisplaySnapshot {
    /// The primary screen's AppKit maxY the accessibility conversion was anchored to.
    /// `CGFloat` throughout: this family feeds `HintPresentationGeometry`
    /// directly, with no numeric conversion at any boundary.
    let primaryMaxY: CGFloat
    /// Participating screens in capture-ready accessibility (primary top-left) coordinates.
    let accessibilityFrames: [HintRect]
    /// AppKit screens for the overlay lane's panel placement.
    let screens: [NSScreen]
}

/// Deterministic, window-free AppKit→accessibility geometry conversion for the
/// per-activation display snapshot. Pure, so the multi-display contract is testable
/// without windows, permissions, or NSScreen state.
enum HintDisplaySnapshotGeometry {
    /// Converts AppKit global (bottom-left origin) frames to accessibility global
    /// (PRIMARY top-left origin) frames, anchored to `primaryMaxY` — the AppKit maxY of
    /// `NSScreen.screens.first` ONLY. A display physically above the primary never had
    /// its maxY subtracted (which would silently clamp it); it converts to a negative
    /// accessibility Y, exactly where the AX tree reports it.
    static func accessibilityFrames(from appKitFrames: [CGRect], primaryMaxY: CGFloat) -> [HintRect] {
        appKitFrames.map { frame in
            HintPresentationGeometry.accessibilityScreenFrame(from: frame, primaryMaxY: primaryMaxY)
        }
    }
}

/// Carbon mask → `NSEvent.ModifierFlags`. Pure, and relied on by tests: the barrier mask
/// comes from the SAME persisted shortcut primitives the tool registered.
enum HintActivationModifiers {
    static func eventFlags(fromCarbonMask mask: UInt32) -> NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if mask & UInt32(cmdKey) != 0 { flags.insert(.command) }
        if mask & UInt32(optionKey) != 0 { flags.insert(.option) }
        if mask & UInt32(controlKey) != 0 { flags.insert(.control) }
        if mask & UInt32(shiftKey) != 0 { flags.insert(.shift) }
        return flags
    }
}

// MARK: - Controller

@MainActor
final class HintSessionController: HintInputControllerDelegate {

    /// Count-only phase for the minimal menu/setup status.
    enum Phase: Equatable {
        case idle
        case scanning
        case presenting
        case invoking
        case scrolling

        var isSessionActive: Bool { self != .idle }
    }

    /// Fires on phase transitions; the tool refreshes menu rows only (no timers).
    var onPhaseChange: (() -> Void)?
    private(set) var phase: Phase = .idle {
        didSet {
            guard oldValue != phase else { return }
            onPhaseChange?()
        }
    }

    var deps: HintSessionDependencies

    private let log = Logger(subsystem: Product.logSubsystem, category: "hints.session")

    // Runtime, provisioned lazily on the FIRST activation (no eager singletons).
    private(set) var provisioned = false
    private var targets: HintSessionAXTargets?
    private var input: HintSessionInput?
    private var presentation: HintSessionPresentation?
    /// The presentation lane instance currently holding the modal input responder. A
    /// same-session rescan reuses it (one install per attach); the expected-hide path and
    /// every teardown clear it, so a fresh runtime always reinstalls.
    private var presentationWithResponder: HintSessionPresentation?
    private(set) var reducer = HintSessionReducer(
        limits: HintScanLimits.standard,
        alphabet: HintsSettings.defaultAlphabet
    )

    // Event mailbox (reentrancy-safe event dispatch; see the file header). Every entry
    // carries the lifecycle epoch it was tagged with at `send` time: after a terminal
    // retirement (which bumps the epoch) the drain DISCARDS queued old-lifecycle events
    // instead of replaying them into a fresh or idle reducer.
    private struct MailboxEntry {
        let epoch: UInt64
        let event: HintEvent
    }
    private var mailbox: [MailboxEntry] = []
    /// Epoch-keyed pump ownership. There are no shared `pumpRunning`/`draining` flags to
    /// get out of sync: EXACTLY one pump slot exists while a mailbox drain task runs,
    /// carrying a monotonically increasing pump identity and the lifecycle epoch the pump
    /// was created under. The drain verifies id + epoch at loop entry and after EVERY
    /// awaited effect; it clears the slot only while it still owns it (a stale
    /// continuation/defer can never clear or operate on a newer pump). Retirement CLEARS
    /// the slot (the executing drain is never cancelled); hardStop cancels and clears it.
    private struct PumpSlot {
        let id: UInt64
        let epoch: UInt64
    }
    private var pumpID: UInt64 = 0
    private var pumpSlot: PumpSlot?
    /// The ONLY tracked pump task (the running drain); tracked so `hardStop` can cancel it.
    private var pumpTask: Task<Void, Never>?

    // Lifecycle poisoning. Every captured closure and every in-flight continuation carries
    // these counters and compares on entry; a mismatched epoch guarantees no-op.
    private var activationEpoch: UInt64 = 0
    private var lifecycleEpoch: UInt64 = 0
    private var stopping = false
    /// Synchronously reserved, EPOCH-KEYED slot for the ONE pre-adoption capture: an
    /// activation reserves the slot before its capture task exists, and the slot is
    /// cleared only by the task whose reservation still stands (stored epoch == task
    /// epoch). This is what makes a repeated activation drain the stale runtime before
    /// the replacement capture (one-pending rule) — and what prevents a stale task or
    /// `defer` behind a hardStop + reprovision from clearing a newer slot.
    private(set) var captureSlotEpoch: UInt64?
    /// Capture tasks (the pre-adoption capture runners) and pump tasks (mailbox drains)
    /// are tracked SEPARATELY: a terminal retirement cancels/clears nonexecuting capture
    /// work while leaving the currently executing drain untouched (it is a pump task).
    /// `hardStop` cancels both.
    private var captureTasks: [Task<Void, Never>] = []

    // Active-session state (one snapshot per activation; never re-read mid-session).
    private var pendingCaptureID: HintPendingCaptureID?
    private var activeTargetPid: Int32?
    /// The single display snapshot captured in THIS activation (one provider call, taken
    /// after any stale-runtime drain): accessibility frames, AppKit screens, and the
    /// primary anchor. Every presentation effect of this session/generation reuses it —
    /// there is no live fallback re-read anywhere.
    private var sessionDisplay: HintDisplaySnapshot?
    private var observers: [(center: NotificationCenter, token: NSObjectProtocol)] = []

    init(deps: HintSessionDependencies) {
        self.deps = deps
        self.reducer = HintSessionReducer(limits: deps.limits, alphabet: deps.alphabet)
    }

    /// Whether a session is live in the reducer (idle → false). Pure state; the tool
    /// reads this for menu status instead of keeping its own mirror.
    var isSessionActive: Bool { reducer.state.isActive }

    /// Fresh settings applied. Cancels/rebuilds the runtime when provisioned; the lazy
    /// provisioning recreates every adapter on the next activation.
    func reconfigure(alphabet: String, activationModifierMask: UInt32) {
        deps.alphabet = alphabet
        deps.activationModifierMask = activationModifierMask
        hardStop()
    }

    // MARK: Activation (hotkey entry — returns quickly)

    /// The Carbon callback entry. Contract: SYNCHRONOUSLY this only snapshots the target
    /// identity (frontmost PID + both screen snapshots) and schedules the capture. No AX
    /// message, no overlay, and no blocking work runs on the calling run-loop thread.
    func activate() {
        guard !stopping else { return }

        // A repeated hotkey on a LIVE session cancels through Core with the dedicated
        // REPEATED-ACTIVATION reason: no context snapshot is taken (a stale-context
        // `.activateRequested` would mislead Core), no new AX capture, no provisioning.
        if reducer.state.isActive {
            send(.cancel(.repeatedActivation))
            return
        }

        // No target to hint at: show nothing, start nothing, keep no state.
        guard let targetPid = deps.frontmostPID() else {
            log.info("activation ignored: no frontmost target (count-only)")
            return
        }
        // One-pending rule: a capture slot is still reserved while Core is idle. Drain
        // that stale runtime SYNCHRONOUSLY (dropping its pending capture and poisoning
        // its continuations) and provision a fresh runtime before the replacement capture.
        if captureSlotEpoch != nil {
            hardStop()
        }
        // Lazy adapter creation happens here, on the first activation only.
        guard ensureRuntime() else { return }

        // ONE display snapshot per activation, invoked only AFTER any stale-runtime
        // drain: two coordinate spaces plus the primary anchor from one provider call.
        let display = deps.displaySnapshot()
        sessionDisplay = display

        activationEpoch &+= 1
        // Blocker 1 (epoch separation): capture work carries TWO SEPARATE captured
        // values — the activation epoch (capture-slot ownership, activation-supersession
        // guards) and the lifecycle epoch (retirement scoping, shared-state guards). No
        // activation counter may ever be compared to the lifecycle epoch.
        let activationEpochAtStart = activationEpoch
        let lifecycleEpochAtStart = lifecycleEpoch
        // Reserve the capture slot SYNCHRONOUSLY, BEFORE the task exists; the slot is
        // owned and cleared by ACTIVATION epoch only. The task clears it only while its
        // own reservation stands, so a stale task/defer after a hardStop + reprovision
        // can never clear a newer slot.
        captureSlotEpoch = activationEpochAtStart
        captureTasks.append(Task { [weak self] in
            await self?.runCapture(
                targetPid: targetPid,
                display: display,
                activationEpoch: activationEpochAtStart,
                lifecycleEpoch: lifecycleEpochAtStart)
        })
    }

    /// Strict initial order: captureContext → reducer `.activateRequested` →
    /// adoptCapture(generation 0) → scan. The captured context (target PID + participating
    /// screens from the activation's display snapshot) is taken BEFORE any overlay exists.
    private func runCapture(
        targetPid: Int32, display: HintDisplaySnapshot,
        activationEpoch: UInt64, lifecycleEpoch: UInt64
    ) async {
        defer {
            // Capture-slot ownership uses the ACTIVATION epoch ONLY: the reservation is
            // released while it is still this activation's, never by a stale task/defer
            // behind a hardStop + reprovision.
            if captureSlotEpoch == activationEpoch { captureSlotEpoch = nil }
        }
        // BOTH captured epochs must still own this work: the activation determines
        // capture/slot ownership and current-runtime use; the lifecycle determines
        // shared-state mutation and retirement.
        guard !stopping, activationEpoch == self.activationEpoch, lifecycleEpoch == self.lifecycleEpoch,
              let targets = self.targets else { return }

        guard let captured = await targets.captureContext(targetPid: targetPid, screens: display.accessibilityFrames) else {
            log.info("capture rejected or cancelled (count-only)")
            // Retirement is scoped to the captured LIFECYCLE epoch only: a stale task
            // after a hardStop + reprovision is UNABLE to retire the current adapters.
            retireIfIdle(epoch: lifecycleEpoch)
            return
        }
        // A superseded capture (activation replaced, or a stop/settings change) since it
        // began: clean ONLY the original local lane — every shared and current surface
        // stays untouched.
        guard !stopping, activationEpoch == self.activationEpoch, lifecycleEpoch == self.lifecycleEpoch else {
            await targets.discardPendingCapture(captured.pendingID)
            return
        }
        pendingCaptureID = captured.pendingID
        activeTargetPid = captured.context.pid

        // PURE: the reducer owns the transition policy. From idle this yields one
        // deferred `startScan`; the reducer reply is processed SYNCHRONOUSLY (no await
        // between the ownership check above and this send).
        var deferredScan: HintScanPlan?
        for effect in reducer.send(.activateRequested(captured.context)) {
            if case .startScan(let plan) = effect {
                deferredScan = plan
            } else {
                await run(effect)
            }
        }
        syncPhase()
        // BOTH ownership guards again: a superseded capture cleans ONLY local state —
        // never `pendingCaptureID`, the fresh reducer, or the current runtime.
        guard !stopping, activationEpoch == self.activationEpoch, lifecycleEpoch == self.lifecycleEpoch else {
            if let plan = deferredScan {
                // The never-adopted plan payload and the pending capture both go home to
                // the ORIGINAL lane only.
                await targets.releaseGeneration(plan.key)
            }
            await targets.discardPendingCapture(captured.pendingID)
            return
        }
        guard let plan = deferredScan else {
            // Current ownership, but Core started no session: the pending capture must
            // not linger owned-by-nobody — discard fail-closed, then retire (scoped).
            pendingCaptureID = nil
            await targets.discardPendingCapture(captured.pendingID)
            retireIfIdle(epoch: lifecycleEpoch)
            return
        }

        // Adopt generation 0 BEFORE the scan starts. The adapter reference is the
        // ORIGINAL local one, so a stale adoption continuation can only clean THAT lane.
        let adopted = await targets.adoptCapture(id: captured.pendingID, for: plan.key, matching: captured.context)
        // BOTH ownership guards IMMEDIATELY after adoption (blocker 2): a stale failed or
        // successful adoption must never touch `pendingCaptureID`, the fresh reducer, or
        // the current runtime — and must never enqueue a stale `scanFailed`. Cleanup
        // targets ONLY the original local lane.
        guard !stopping, activationEpoch == self.activationEpoch, lifecycleEpoch == self.lifecycleEpoch else {
            if adopted {
                await targets.releaseGeneration(plan.key)
            } else {
                await targets.discardPendingCapture(captured.pendingID)
            }
            return
        }
        if !adopted {
            pendingCaptureID = nil
            await targets.discardPendingCapture(captured.pendingID)
            // AFTER the cleanup await: recheck BOTH epochs before any send, retirement,
            // or shared-state mutation.
            guard !stopping, activationEpoch == self.activationEpoch, lifecycleEpoch == self.lifecycleEpoch else { return }
            send(.scanFailed(plan.key, .captureLost))
            retireIfIdle(epoch: lifecycleEpoch)
            return
        }
        // A drained event (e.g. a safety cancel) could have ended the just-started
        // session while this capture was mid-adopt: then Core no longer owns the key and
        // the adopted payload is orphaned — release it, fail-closed, and never scan.
        guard case .scanning(let live, _) = reducer.state, live.key == plan.key else {
            await targets.releaseGeneration(plan.key)
            return
        }
        // The capture is now fully owned by the session; its reservation was released.
        pendingCaptureID = nil
        await run([.startScan(plan)])
        retireIfIdle(epoch: lifecycleEpoch)
    }

    // MARK: Effect execution (exhaustive, in batch order)

    /// Executes effects in the order the reducer emitted them; every async boundary is
    /// awaited before the next effect runs, so a `[releaseGeneration, startScan]` batch
    /// cannot begin the new scan until the old generation is actually released. Keyed
    /// outcomes RETURN through the reducer (`send`) rather than touching state, so stale
    /// keys take core's own idempotent release path.
    private func run(_ effects: [HintEffect]) async {
        for effect in effects {
            guard !stopping else { return }
            await run(effect)
        }
    }

    private func run(_ effect: HintEffect) async {
        guard !stopping else { return }
        switch effect {
        case .startScan(let plan):
            await runScan(plan)

        case .showOverlays(let key, let snapshot):
            present(snapshot: snapshot, key: key)

        case .refreshOverlays(let key, let snapshot):
            present(snapshot: snapshot, key: key)

        case .awaitModifierRelease(let key):
            // Activation candidates are modifierless (the frozen modifier rule), so the
            // barrier is armed with the conversion of the PERSISTED shortcut mask and
            // releases as soon as those physical modifiers leave the keys.
            _ = key
            input?.awaitModifierRelease(modifierMask: HintActivationModifiers.eventFlags(fromCarbonMask: deps.activationModifierMask))

        case .beginInput(let key):
            _ = key
            input?.beginInput()

        case .invoke(let key, let token, let action):
            // PRECONDITION: the batch already ran `.hideOverlays`, i.e. input relinquished
            // its expected capture and the overlays hid, BEFORE this dispatch begins.
            // The adapter is bound BEFORE the await: the effect belongs to the runtime
            // that emitted it — a resumed await dispatches into the (possibly already
            // drained) ORIGINAL lane, never into the fresh runtime a reprovision made.
            guard let targets = targets else { return }
            let epoch = lifecycleEpoch
            let outcome = await targets.invoke(token: token, action: action, key: key)
            // A resumed await after `hardStop()` or terminal retirement (both reset
            // `stopping`/leave idle) must not feed a FRESH runtime: the old payloads were
            // destroyed synchronously and the reducer is already idle.
            guard !stopping, epoch == lifecycleEpoch else { return }
            send(.invocationFinished(key, outcome))

        case .scrollRegion(let key, let token, let command):
            // Scroll NEVER routes through invoke: it dispatches through the dedicated
            // semantic scroll surface and lands as `scrollFinished`. Adapter bound BEFORE
            // the await, exactly like `invoke`.
            guard let targets = targets else { return }
            let epoch = lifecycleEpoch
            let outcome = await targets.scroll(token: token, operation: command, key: key)
            guard !stopping, epoch == lifecycleEpoch else { return }
            send(.scrollFinished(key, outcome))

        case .hideOverlays(let key):
            // EXPECTED-HIDE ORDER: relinquish input's expected capture FIRST (straggling
            // input drops silently and capture loss cannot misfire), THEN hide. The
            // responder attachment ends with the overlays: a replacement session or a
            // fresh runtime reinstalls on its next scan.
            input?.relinquishExpectedCapture()
            presentation?.hide(generation: key)
            presentationWithResponder = nil

        case .releaseGeneration(let key):
            await targets?.releaseGeneration(key)

        case .releaseSession(let key):
            await targets?.releaseSession(key)
        }
    }

    // MARK: Scan

    private func runScan(_ plan: HintScanPlan) async {
        guard !stopping, let display = sessionDisplay, let targets = targets, let input = self.input,
              let presentation = self.presentation,
              case .scanning(let live, _) = reducer.state, live.key == plan.key else { return }
        // The activation's display snapshot is the ONLY screen source here: no live
        // fallback re-read exists.
        let overlayScreens = display.screens

        // The scanning canvas exists so the panel can install input BEFORE results land;
        // a failure is `targetContextMismatch` (frontmost/topology proof failed).
        guard presentation.show(
            generation: plan.key,
            context: plan.context,
            screens: overlayScreens,
            status: .scanning
        ) else {
            send(.scanFailed(plan.key, .targetContextMismatch))
            return
        }
        let epoch = lifecycleEpoch
        // One install per presentation attach: the initial scan installs and confirms;
        // a same-session rescan whose overlay retained the responder (same instance)
        // reuses it instead of reinstalling.
        if presentationWithResponder !== presentation {
            let installed = presentation.installInputResponder(input.responderView, onCaptureLost: { [weak self] in
                MainActor.assumeIsolated { self?.safetyCancel(.captureLost, epoch: epoch) }
            })
            guard installed else {
                send(.scanFailed(plan.key, .captureLost))
                return
            }
            presentationWithResponder = presentation
            // Input verifies Secure Input / key window / first responder SYNCHRONOUSLY and
            // cancels through the delegate on any failure; that event only appends.
            if let window = input.responderView.window {
                input.captureConfirmed(window: window)
            }
        }
        guard !stopping, case .scanning(let still, _) = reducer.state, still.key == plan.key else { return }

        let result = await targets.scan(plan: plan)
        // A scan resumed after `hardStop()` or terminal retirement cannot feed the current
        // runtime: the epoch it carries is stale by definition.
        guard !stopping, epoch == lifecycleEpoch else { return }
        if let result {
            send(.scanCompleted(plan.key, result))
        } else {
            // A nil scan result carries no reason of its own; fail closed.
            log.info("scan returned nothing (count-only): timeout or cancellation")
            send(.scanFailed(plan.key, .timeout))
        }
    }

    // MARK: Presentation effects

    private func present(snapshot: HintPresentationSnapshot, key: HintSessionKey) {
        guard snapshot.key == key, !stopping, let presentation, let display = sessionDisplay,
              let context = reducerContext(for: key) else { return }
        // Presentation renders `.noMatches` itself for an empty pool; anything Presentation
        // cannot accept (frontmost/topology proof failed) is an uncertainty — cancel closed.
        guard presentation.update(
            snapshot: snapshot,
            context: context,
            screens: display.screens,
            status: .active
        ) else {
            send(.cancel(.targetContextMismatch))
            return
        }
    }

    /// The context the LIVE session state carries for `key`; a mismatch (stale effect)
    /// drops the presentation quietly — core already handled that outcome.
    private func reducerContext(for key: HintSessionKey) -> HintTargetContext? {
        switch reducer.state {
        case .idle: return nil
        case .scanning(let plan, _): return plan.key == key ? plan.context : nil
        case .presenting(let presenting): return presenting.key == key ? presenting.context : nil
        case .invoking(let invoking): return invoking.key == key ? invoking.context : nil
        case .scrolling(let scrolling): return scrolling.key == key ? scrolling.context : nil
        }
    }

    // MARK: Mailbox (reentrancy-safe event dispatch)

    /// The only way events reach the reducer. Reentrant callers (synchronous Input
    /// callbacks inside an `await` window) just append; the running drain accepts them.
    /// Internal (not private) so deterministic test harnesses can inject any `HintEvent`
    /// — including stale keyed outcomes — through the exact production entry point.
    func send(_ event: HintEvent) {
        guard !stopping else { return }
        mailbox.append(MailboxEntry(epoch: lifecycleEpoch, event: event))
        pump()
    }

    private func pump() {
        guard !stopping, pumpSlot == nil else { return }
        pumpID &+= 1
        let slot = PumpSlot(id: pumpID, epoch: lifecycleEpoch)
        pumpSlot = slot
        pumpTask = Task { [weak self, slot] in
            await self?.drainMailbox(id: slot.id)
        }
    }

    private func drainMailbox(id: UInt64) async {
        while true {
            // Ownership check at the head of EVERY iteration — BEFORE reading
            // `mailbox.isEmpty` or touching the reducer: the `while true` shape
            // forces every exit through this guard, so a continuation that lost
            // its slot can never even observe mailbox state, let alone drain it.
            guard !stopping, let slot = pumpSlot, slot.id == id, slot.epoch == lifecycleEpoch else { break }
            guard !mailbox.isEmpty else { break }
            let entry = mailbox.removeFirst()
            // Epoch-tagged entries from a lifecycle that already ended (terminal
            // retirement, hardStop + reprovision) are DISCARDED: rapid repeated callbacks
            // queued before a retirement can never restart an idle or fresh reducer.
            guard entry.epoch == lifecycleEpoch else { continue }
            // The SINGLE reducer touch point: one event at a time, whole batch awaited
            // before the next event (which is what makes Input's synchronous callbacks
            // safe — they can only append to the mailbox while this loop is suspended).
            let effects = reducer.send(entry.event)
            await run(effects)
            // Re-verify ownership AFTER the awaited effect run: a stale continuation must
            // not sync the phase of, retire, or otherwise operate on a newer pump.
            guard let after = pumpSlot, after.id == id, after.epoch == lifecycleEpoch else { break }
            syncPhase()
            // Terminal retirement is EPOCH-SCOPED to this pump's captured epoch: a stale
            // or superseded drain can never retire the CURRENT adapters.
            retireIfIdle(epoch: slot.epoch)
        }
        // Clear the slot ONLY when this pump still owns it — a stale continuation/defer
        // must not clear a newer pump's slot. (When retirement already cleared ownership,
        // the mismatched id check is what keeps this from nil-ing the new slot.)
        if pumpSlot?.id == id {
            pumpSlot = nil
            pumpTask = nil
        }
    }

    private func syncPhase() {
        switch reducer.state {
        case .idle: phase = .idle
        case .scanning: phase = .scanning
        case .presenting: phase = .presenting
        case .invoking: phase = .invoking
        case .scrolling: phase = .scrolling
        }
    }

    // MARK: Terminal retirement

    /// Destroys the runtime after a session reached its terminal state. Captures/PUMP
    /// tasks are tracked separately: nonexecuting capture work is cancelled and cleared,
    /// while the executing drain (a pump task) is NEVER cancelled — the retirement itself
    /// may be running inside it. Poisoning via the lifecycle epoch makes every stale
    /// closure dead at its own guard, and epoch-tagged mailbox entries from the ended
    /// lifecycle are discarded by the still-running drain. Also deliberately does NOT
    /// touch the reducer (already idle).
    private func retireRuntime() {
        // Poison via the epoch FIRST: every stale closure/continuation dies at its guard.
        lifecycleEpoch &+= 1

        // Nonexecuting capture work is cancelled and cleared; the currently EXECUTING
        // drain is never a cancelled task here — retirement CLEARS the pump slot instead,
        // so the suspended drain exits at its next ownership check. `hardStop` cancels
        // both task classes.
        for task in captureTasks { task.cancel() }
        captureTasks.removeAll()
        pumpSlot = nil
        pumpTask = nil

        // Observers first: no further workspace events can touch the mailbox of a tool
        // whose runtime just died.
        for entry in observers { entry.center.removeObserver(entry.token) }
        observers.removeAll()

        // Input: the real input adapter notifies its delegate SYNCHRONOUSLY inside
        // `stop()` (`.toolDisabled`), so the delegate is detached BEFORE `stop()` — the
        // notification cannot enqueue anything into the retired runtime.
        if let input {
            input.delegate = nil
            input.relinquishExpectedCapture()
            input.stop()
        }

        // Presentation: callbacks cleared BEFORE stopping, so no invalidation or
        // capture-loss path can fire during or after teardown.
        if let presentation {
            presentation.onInvalidated = nil
            presentation.stop()
        }

        // AX: synchronous drain — every pending capture, session, snapshot, and token is
        // dropped before this call returns. The adapter instance is closed for reopening.
        targets?.stopAndWait()

        pendingCaptureID = nil
        activeTargetPid = nil
        sessionDisplay = nil
        presentationWithResponder = nil
        targets = nil
        input = nil
        presentation = nil
        provisioned = false

        // Queued mailbox entries were tagged with the OLD lifecycle epoch: the running
        // drain discards them one by one; no queued callback can restart the idle reducer.
    }

    /// Terminal retirement whenever the calling flow settles with the reducer idle.
    /// REQUIREMENT: the caller passes the lifecycle epoch it was captured with — a stale
    /// continuation (behind a hardStop + reprovision, or a finished retirement) must be
    /// UNABLE to retire the current adapters, so an epoch mismatch makes this a no-op.
    /// Unscoped retirement from stale async work is forbidden by construction: there is
    /// no parameterless overload.
    private func retireIfIdle(epoch: UInt64) {
        guard !stopping, provisioned, reducer.state == .idle else { return }
        guard epoch == lifecycleEpoch else { return }
        retireRuntime()
    }

    // MARK: Input delegate

    func hintInput(_ controller: HintInputController, didReceiveCommand command: HintKeyCommand) {
        send(.key(command))
    }

    func hintInput(_ controller: HintInputController, didCancelWithReason reason: HintCancellationReason) {
        send(.cancel(reason))
    }

    // MARK: Runtime provisioning + safety observers

    @discardableResult
    private func ensureRuntime() -> Bool {
        guard !stopping, targets == nil else { return targets != nil }
        let targets = deps.makeTargets()
        let input = deps.makeInput()
        let presentation = deps.makePresentation()
        input.delegate = self
        let epoch = lifecycleEpoch
        presentation.onInvalidated = { [weak self] invalidation in
            MainActor.assumeIsolated {
                // Only one invalidation exists today; the switch keeps the handling
                // explicit and exhaustive if the vocabulary grows.
                switch invalidation {
                case .displayTopologyChanged:
                    // Presentation already hid its panels; this is the fail-closed event.
                    self?.safetyCancel(.displayTopologyChange, epoch: epoch)
                }
            }
        }
        self.targets = targets
        self.input = input
        self.presentation = presentation
        self.provisioned = true
        installSessionObservers(epoch: epoch)
        return true
    }

    /// Active-session safety observers. Handlers no-op unless a session is live for the
    /// recorded target; every reason maps to the exact frozen core cancellation vocabulary.
    /// The handler BODIES are internal (test-driven deterministically without real
    /// `NSRunningApplication`s); the observer wrappers only filter by notification.
    private func installSessionObservers(epoch: UInt64) {
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        record(workspaceCenter, workspaceCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self, !self.stopping, epoch == self.lifecycleEpoch else { return }
                self.workspaceAppActivated(
                    pid: (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier)
            }
        })
        record(workspaceCenter, workspaceCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self, !self.stopping, epoch == self.lifecycleEpoch else { return }
                self.workspaceAppTerminated(
                    pid: (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier)
            }
        })
        record(workspaceCenter, workspaceCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.stopping, epoch == self.lifecycleEpoch else { return }
                self.workspaceDidWake()
            }
        })
        // Coming back from System Settings (or any app switch back to ourselves) is when a
        // grant or a revocation becomes visible; the menu refresh happens elsewhere, and
        // this keeps a LIVE session honest about a mid-session revocation.
        record(NotificationCenter.default, NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.stopping, epoch == self.lifecycleEpoch else { return }
                self.appDidBecomeActive()
            }
        })
    }

    private func record(_ center: NotificationCenter, _ token: NSObjectProtocol) {
        observers.append((center, token))
    }

    /// A different app becoming frontmost invalidates the captured context.
    func workspaceAppActivated(pid: Int32?) {
        guard !stopping, reducer.state.isActive, let target = activeTargetPid else { return }
        guard let pid, pid != target else { return }
        send(.cancel(.targetContextMismatch))
    }

    func workspaceAppTerminated(pid: Int32?) {
        guard !stopping, reducer.state.isActive else { return }
        guard let pid, pid == activeTargetPid else { return }
        send(.cancel(.appTerminated))
    }

    /// Sleep invalidates every captured assumption at once; trust is re-checked here too,
    /// because the accessibility watch lives above this layer.
    func workspaceDidWake() {
        guard !stopping else { return }
        recheckAccessibility()
        guard reducer.state.isActive else { return }
        send(.cancel(.wake))
    }

    func appDidBecomeActive() {
        guard !stopping else { return }
        recheckAccessibility()
    }

    private func recheckAccessibility() {
        guard !stopping, reducer.state.isActive, !deps.isAccessibilityTrusted() else { return }
        send(.cancel(.accessibilityRevoked))
    }

    /// Epoch-checked cancellation entry for every adapter-reported safety signal.
    private func safetyCancel(_ reason: HintCancellationReason, epoch: UInt64) {
        guard epoch == lifecycleEpoch, !stopping, reducer.state.isActive else { return }
        send(.cancel(reason))
    }

    // MARK: Hard teardown (synchronous; the ONLY teardown)

    /// Marks stopping + epoch invalid first, then detaches and drains every lane in the
    /// contract order, and leaves a fresh idle reducer. Idempotent AND safe when nothing
    /// was ever provisioned. Used by disable/termination, by a settings reconfigure, and
    /// by the one-pending repeated-activation path in `activate()`.
    ///
    /// Contract guarantee: this method is only ever called from synchronous call sites
    /// OUTSIDE tracked tasks, so cancelling the tracked tasks here can never cancel the
    /// task currently performing cleanup. Every in-flight continuation is epoch-poisoned
    /// (checked at its own guard after resumption), never resurrected.
    func hardStop() {
        stopping = true
        activationEpoch &+= 1
        lifecycleEpoch &+= 1

        // Observers first: no further workspace events can touch the mailbox.
        for entry in observers { entry.center.removeObserver(entry.token) }
        observers.removeAll()

        // Tracked tasks die here, synchronously — the capture tasks AND the pump task;
        // their continuations are also epoch/ownership-checked. This method is only ever
        // called from synchronous call sites OUTSIDE tracked tasks, so the executing
        // cleanup can never be a cancelled task here.
        for task in captureTasks { task.cancel() }
        pumpTask?.cancel()
        captureTasks.removeAll()
        pumpTask = nil
        pumpSlot = nil

        // Input: the adapter notifies its delegate SYNCHRONOUSLY inside `stop()`
        // (`.toolDisabled`), so the delegate is detached FIRST — nothing re-sends into
        // the fresh reducer that replaces this runtime below.
        if let input {
            input.delegate = nil
            input.relinquishExpectedCapture()
            input.stop()
        }

        // Presentation: callbacks cleared BEFORE stopping, so no invalidation or capture-
        // loss path can fire during or after teardown.
        if let presentation {
            presentation.onInvalidated = nil
            presentation.stop()
        }

        // AX: synchronous drain — every pending capture, session, snapshot, and token is
        // dropped before this call returns. A stopped instance never reopens, so the
        // adapter itself is discarded here and recreated lazily on a future activation.
        targets?.stopAndWait()

        // Clear every piece of tracked runtime state. The capture slot included: the
        // stale capture is dead by definition (one-pending rule; its task is cancelled
        // and epoch-poisoned), so a later activation never drains a live replacement.
        mailbox.removeAll()
        pumpSlot = nil
        pumpTask = nil
        captureSlotEpoch = nil
        pendingCaptureID = nil
        activeTargetPid = nil
        sessionDisplay = nil
        presentationWithResponder = nil
        targets = nil
        input = nil
        presentation = nil
        provisioned = false

        // Fresh idle reducer on the current settings; phases settle back to idle.
        reducer = HintSessionReducer(limits: deps.limits, alphabet: deps.alphabet)
        phase = .idle
        stopping = false
    }
}

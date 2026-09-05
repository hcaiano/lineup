import AppKit
import ApplicationServices
import AppCore
import Foundation
import HintsCore
import os

// ============================================================================
// HintAXService — the sole Hints owner of `AXUIElement` values.
// ============================================================================
//
// THREE-STORE OWNERSHIP:
//   1. Pending capture (opaque `HintPendingCaptureID`): exists from `captureContext`
//      until adoption or discard. At most one; a second capture fails.
//   2. Session roots: keyed by the adopted owner id, owning the application element, the
//      exact pure context, the AUTHORITATIVE `activeKey` binding, and immutable deduped
//      baseline roots with stable opaque `HintAXRootID`s AND explicit provenance kind
//      (original window / sheet captured from the public kAXWindowsAttribute enumeration
//      via public `kAXSheetRole` / menu bar). Roots survive generation rollover only;
//      continuity is NEVER minted.
//   3. Per-generation state: the `HintAXTokenRepository` (keyed by FULL `HintSessionKey`
//      with proven root ID + ancestor chain) plus the generation's OWN window-identity
//      snapshot (`HintAXGenerationSnapshot`), both released with their generation.
//
// EXACT ACTIVE-FULL-KEY OWNERSHIP (Oracle Gate 3):
//   * Adoption RESERVES its generation-0 key in the lock-protected registry BEFORE any
//     cancellable AX validation, and rechecks that exact binding immediately before
//     publication — a cancelled/stale adoption never publishes.
//   * `scan(plan:)` requires `plan.key == session.activeKey` AND `plan.limits ==
//     service.limits`; it rejects duplicate scans of an already-live exact generation
//     WITHOUT touching the live state (no poisoning).
//   * `releaseGeneration(_:)` is authorized ONLY on an exact active-key match: it
//     synchronously cancels that generation and ADVANCES the binding to
//     `key.nextGeneration`; serialized cleanup releases ONLY that exact generation.
//     A stale/foreign/future key merely prunes repository records owned by that exact
//     key — no cancellation, no advancement, no poisoning, untouched roots/generations.
//   * `releaseSession(_:)` removes the session, roots, snapshots, and owner binding ONLY
//     on an exact active full-key match; otherwise it prunes exact-key repository
//     records only.
//
// ORCHESTRATION ORDER (Phase 3 contract):
//   initial:  captureContext → (reducer activates) → adoptCapture → scan
//   rescan:   releaseGeneration(current full key) → scan(next-generation plan)
//   abort:    discardPendingCapture / releaseGeneration / releaseSession / stop
//   A later HintsCore change will split release effects across the reducer; the AX-side
//   half is implemented here exactly as ordered and not pre-empted.
//
// CANCELLATION/DEADLINE SAFETY:
//   * Capture, adoption, scan preflight, invocation, and scroll carry a bounded
//     service-limit wall clock with a boundary closure AROUND EVERY AX message,
//     including every ancestry read and every composite backend helper
//     (`scrollCapabilities`, `pageStepper`, `frame`, `scrollbars`, `numericRange`).
//   * ONE bounded validator AND classifier (`validateGeneration`) runs the fresh
//     session/generation check: required public windows enumeration, unknown/foreign-PID
//     entry rejection, baseline identity/kind/liveness/admission, retained menu identity,
//     and the COMPLETE nonbaseline participation classification (identity,
//     admitted-vs-skipped, exact sponsor root). Used by scan preflight AND immediately
//     before invoke/scroll mutations, where the fresh snapshot must EQUAL the generation-
//     stored one — window-set, admission, or sponsor changes after a scan fail closed.
//   * Cancelled or deadline-crossed scans publish NOTHING: the final preparatory recheck
//     (immediately before repository pruning and state publication) closes the exact
//     generation. All mutations dispatch AT MOST ONCE after an immediate cancellation
//     recheck; `kAXErrorCannotComplete` ⇒ `.unknownOutcome`, never retried.
//
// SCROLL MATRIX (public APIs only, macOS 13; no raw action strings, no scrollToVisible,
//   no event/pointer synthesis, no private APIs, no fallback guesses):
//     up/down     → kAXDecrementAction / kAXIncrementAction on the VERTICAL scrollbar,
//                   dispatched only when that exact name is freshly returned by
//                   `AXUIElementCopyActionNames` on the resolved scrollbar.
//     left/right  → the same two actions on the HORIZONTAL scrollbar.
//     pageUp/pageDown → a descendant of the scroll area exposing public
//                   kAXDecrementPageSubrole / kAXIncrementPageSubrole whose kAXPressAction
//                   is freshly advertised; pressed once. Unavailable ⇒ fail closed.
//     home/end    → the vertical scrollbar's public kAXValueAttribute set to its
//                   kAXMinValueAttribute / kAXMaxValueAttribute value, only when the value
//                   attribute is freshly settable and min/max decode as compatible public
//                   CFNumber scalars. Unsupported/type-invalid ⇒ fail closed.
//
// HONEST READS AND PUBLIC CONSTANTS (no raw AXVisible/AXIsOnScreen/AXSheets/AXLabel):
//   * Visibility/on-screen admission for roots AND candidates is proven from PUBLIC
//     non-minimized state plus finite positive frame geometry intersecting the captured
//     screens (`HintAXGeometry.admitsOnScreen`); candidate booleans are true ONLY after
//     that proof. Unknown or stale answers fail closed.
//   * `.unknown` role/subrole transport/decoding REJECTS candidate admission AND every
//     mutation; `.value(nil)` is a KNOWN absence and admits normally. Unknown is never
//     collapsed to nil. Sheets prove the public `kAXSheetRole`; secure surfaces prove
//     `kAXSecureTextFieldSubrole` (also explicitly rejected on scroll lanes).
//   * Sheets/popovers/menus participate only through public windows roles plus
//     child/parent/kAXWindow (owningWindow)/kAXTopLevelUIElement ancestry to EXACTLY ONE
//     retained root. No first-window sponsorship guess exists anywhere.
//   * Traverse/retain only elements of the captured target PID; Lineup is never a target.
//
// PRIVACY: logs are count/error-only via `Product.logSubsystem` (no titles, values,
//   labels, queries, raw tokens). Secure field values are never read. Idle cost: no
//   polling, timers, or observers; a stopped instance never reopens.
// ============================================================================

/// Capture output for Phase 3: ONLY a pending capture ID and the pure captured context.
public struct HintCapturedContext: Sendable, Equatable {
    public let pendingID: HintPendingCaptureID
    public let context: HintTargetContext

    public init(pendingID: HintPendingCaptureID, context: HintTargetContext) {
        self.pendingID = pendingID
        self.context = context
    }
}

/// Operation the invocation lane dispatches for one candidate. No pointer/synthesis kinds
/// exist by frozen decision.
public enum HintInvocationAction: Hashable, Sendable {
    case press
    case showMenu
    case focus
}

/// One NONBASELINE window/transient surface's COMPLETE participation classification in a
/// generation: its public AX identity, whether it was ADMITTED as a participating surface
/// (explicitly non-minimized, on-screen, and proven attached) versus SKIPPED (explicitly
/// minimized or proven off captured screens), and its exact sponsoring retained root ID
/// when admitted. Recorded at scan preflight and compared for FULL equality immediately
/// before each mutation, so admission or sponsor changes fail closed even when AX
/// identity is unchanged.
struct HintAXTransientParticipation: Hashable {
    let identity: HintAXElementKey
    let admitted: Bool
    let sponsor: HintAXRootID?
}

/// Per-generation generation-owned COMPLETE participation snapshot: the FRESH public
/// window identity set, the retained menu identity, and the full participation
/// classification of every nonbaseline transient surface (see
/// `HintAXTransientParticipation`). Captured at preflight by the shared
/// validator/classifier and re-proven (equality) immediately before each mutation.
/// Owned by the FULL key; released with its generation.
struct HintAXGenerationSnapshot: Equatable {
    let key: HintSessionKey
    let windowIdentity: Set<HintAXElementKey>
    let menuIdentity: HintAXElementKey?
    let transientParticipations: Set<HintAXTransientParticipation>
}

/// One adopted session's owned state; lives only on the serial executor.
struct HintAXSessionRecord {
    /// The adopted owner binding (exact session key at generation 0).
    let ownerKey: HintSessionKey
    /// The AUTHORITATIVE active full key (generation 0 at adoption; advanced exactly by
    /// authorized `releaseGeneration` calls). Scan/release authorization compares THIS.
    var activeKey: HintSessionKey
    /// Exact pure context captured and re-verified before every scan.
    let context: HintTargetContext
    let targetPid: Int32
    /// The owning application element (stamped).
    let application: AXUIElement
    /// Immutable deduped baseline roots with stable opaque IDs and explicit provenance
    /// kind, in capture order.
    let baselineRoots: [(element: AXUIElement, rootID: HintAXRootID, kind: HintAXRootKind)]
    /// Live target generations owned by this session (at most one at a time; the N+1 scan
    /// fails until N's release completed).
    var liveGenerations: Set<HintSessionKey> = []

    var rootElements: [AXUIElement] { baselineRoots.map(\.element) }
    var rootIDs: Set<HintAXRootID> { Set(baselineRoots.map(\.rootID)) }
}

public final class HintAXService {
    // MARK: Dependencies and ownership state

    private let backend: HintAXBackend
    private let frontmost: HintFrontmostProvider
    private let tokenFactory: HintTokenFactory
    private let clock: HintScanClock

    /// The one private serial executor for all AX work and all mutable state below.
    private let axQueue: DispatchQueue

    /// Dispatch-specific marker installed on `axQueue` at init; read by `stopAndWait()`
    /// to prove the caller is not already running ON the AX executor (deadlock guard).
    private static let axQueueMarkerKey = DispatchSpecificKey<UInt8>()

    private let lineupPid: Int32

    /// Per-generation target repository, keyed by FULL `HintSessionKey`.
    private let repository = HintAXTokenRepository()

    /// Generation-owned window-identity snapshots, keyed by FULL `HintSessionKey`;
    /// released with their generation.
    private var generationSnapshots: [HintSessionKey: HintAXGenerationSnapshot] = [:]

    /// Lock-protected cancellation registry (no AX values; synchronous marking and the
    /// authoritative active full-key bindings).
    private let registry = HintAXCancellationRegistry()

    /// At most one pending capture (store 1).
    private var pendingCapture: HintPendingCapture?

    /// Adopted sessions (store 2), keyed by owner id with the authoritative active key.
    private var sessions: [UInt64: HintAXSessionRecord] = [:]

    private let logger = Logger(
        subsystem: Product.logSubsystem, category: "hints.ax"
    )

    /// Frozen Phase 0 budgets; `HintScanLimits` clamping makes loosening impossible.
    public let limits: HintScanLimits

    public init(
        limits: HintScanLimits = .standard,
        backend: HintAXBackend = SystemHintAXBackend(),
        frontmost: HintFrontmostProvider = HintNSWorkspaceFrontmostProvider(),
        tokenFactory: HintTokenFactory = HintRandomTokenFactory(),
        clock: HintScanClock = HintSystemClock()
    ) {
        self.limits = limits
        self.backend = backend
        self.frontmost = frontmost
        self.tokenFactory = tokenFactory
        self.clock = clock
        self.axQueue = DispatchQueue(label: "\(Product.logSubsystem).hints.ax", qos: .userInitiated)
        // Queue-identity marker: lets `stopAndWait()` prove it is NOT running on the AX
        // executor before it `sync`s, so a queue-confined caller can never deadlock on
        // its own serial queue.
        self.axQueue.setSpecific(key: Self.axQueueMarkerKey, value: 1)
        self.lineupPid = ProcessInfo.processInfo.processIdentifier
    }

    deinit {
        // Deliberately empty: the lifecycle owner's `stop()` (or the adopted release
        // paths) is the ONLY serial teardown. A deinit body here runs on whichever thread
        // dropped the last reference and cannot prove serial ownership, so it must never
        // mutate the repository, pending store, sessions, or snapshots.
    }

    // MARK: Executor plumbing

    /// Awaitably runs `operation` on the serial AX executor. Completions happen exactly
    /// once per await, never under a lock; the only lock is the registry's micro-lock.
    private func perform<T: Sendable>(_ operation: @escaping () -> T) async -> T {
        await withCheckedContinuation { continuation in
            axQueue.async { continuation.resume(returning: operation()) }
        }
    }

    // MARK: Checked AX messaging helpers (no bypass, fail closed)

    // ONE boundary-checked AX message: the boundary is verified BEFORE the backend call
    // so a failed check issues NO next AX message at all. The "after" side of the
    // between-messages contract belongs to the NEXT message's "before" check — every
    // fixed mutation/classification sequence routes each backend call through these
    // helpers, so a consecutive pair can never bypass the between-message boundary.
    // A failed pre-check is fail-closed: reads surface transport `.unknown`, mutations
    // return `.cannotComplete` WITHOUT dispatching (at-most-once preserved — the
    // mutation pre-check also doubles as the final cancel/deadline check).

    private func checkedMessage<T>(
        _ boundary: HintAXBoundary, label: String, _ message: () -> HintAXRead<T>
    ) -> HintAXRead<T> {
        guard boundary() else {
            logger.error("\(label, privacy: .public): cancelled or deadline, no AX message issued")
            return .unknown
        }
        return message()
    }

    private func checkedMessage(
        _ boundary: HintAXBoundary, label: String, _ message: () -> Int32?
    ) -> Int32? {
        guard boundary() else {
            logger.error("\(label, privacy: .public): cancelled or deadline, no AX message issued")
            return nil
        }
        return message()
    }

    private func checkedMessage(
        _ boundary: HintAXBoundary, label: String, _ message: () -> AXError
    ) -> AXError {
        guard boundary() else {
            logger.error("\(label, privacy: .public): cancelled or deadline, no dispatch issued")
            return .cannotComplete
        }
        return message()
    }

    // MARK: Shared bounded validators (serial executor only)

    /// THE ONE bounded fresh session/generation validator AND classifier: a REQUIRED
    /// public window enumeration, a hygiene sweep rejecting unknown/foreign-PID entries,
    /// baseline roots proven by IDENTITY inside the fresh enumeration (public
    /// `kAXSheetRole` kind consistency, explicitly non-minimized, and
    /// `HintAXGeometry.admitsOnScreen` admission against the captured screens), the
    /// retained menu root re-proven by identity against a FRESH `kAXMenuBarAttribute`
    /// lookup, and the COMPLETE participation classification of every NONBASELINE
    /// transient surface: public identity, explicitly minimized state, public frame
    /// admission against the captured screens, and attachment proven by public
    /// child/parent/kAXWindow/kAXTopLevelUIElement ancestry to EXACTLY ONE retained
    /// root (admitted=false recorded for explicitly minimized/off-screen surfaces,
    /// whose sponsor stays nil). Used by the scan preflight AND immediately before
    /// each invocation/scroll mutation; the classification rides the returned snapshot
    /// so admission or sponsor changes fail closed by snapshot equality even when AX
    /// identity is unchanged. Returns the fresh snapshot, the fresh window enumeration,
    /// and the ADMITTED transient surfaces with their sponsors (only the preflight
    /// consumes the latter two); nil on ANY failure (cancel, deadline, or context
    /// mismatch). Boundary checks surround EVERY AX message.
    private func validateGeneration(
        session: HintAXSessionRecord,
        key: HintSessionKey,
        deadlineMs: Int64
    ) -> (
        snapshot: HintAXGenerationSnapshot,
        freshWindows: [AXUIElement],
        admittedTransients: [(element: AXUIElement, sponsor: HintAXRootID)]
    )? {
        let boundary: HintAXBoundary = {
            !self.registry.isStopped && !self.registry.isCancelled(key) && self.clock.nowMs() < deadlineMs
        }
        guard boundary() else {
            logger.error("generation validation aborted: cancelled or deadline (gen \(key.generation, privacy: .public))")
            return nil
        }
        // Required public enumeration: unknown → nil.
        guard case .value(let windowElements) = backend.windows(of: session.application) else {
            logger.error("generation validation failed: unknown window enumeration (context mismatch)")
            return nil
        }
        guard boundary() else {
            logger.error("generation validation aborted: cancelled or deadline")
            return nil
        }
        // Hygiene: unknown/foreign PID entries in the required enumeration REJECT the
        // generation ("skip" would let stale/hostile windows in).
        for window in windowElements {
            let pid = backend.pid(of: window)
            guard boundary() else {
                logger.error("generation validation aborted: cancelled or deadline")
                return nil
            }
            guard pid == session.targetPid, pid != lineupPid else {
                logger.error("generation validation failed: unknown/foreign-PID window entry in the fresh set")
                return nil
            }
        }
        let windowIdentity = Set(windowElements.map { HintAXElementKey(element: $0) })

        // Baseline roots: identity presence + kind consistency with ONE cached role read
        // each + explicitly non-minimized + geometry admission. Menu identity is fetched
        // at most one fresh lookup when a menu root is retained.
        var menuLookup: HintAXRead<AXUIElement?>?
        if session.baselineRoots.contains(where: { $0.kind == .menuBar }) {
            menuLookup = backend.menuBar(of: session.application)
            guard boundary() else {
                logger.error("generation validation aborted: cancelled or deadline")
                return nil
            }
        }
        for (element, _, kind) in session.baselineRoots {
            guard boundary() else {
                logger.error("generation validation aborted: cancelled or deadline")
                return nil
            }
            let pid = backend.pid(of: element)
            guard boundary() else {
                logger.error("generation validation aborted: cancelled or deadline")
                return nil
            }
            guard pid == session.targetPid, pid != lineupPid else {
                logger.error("generation validation failed: baseline root pid unknown/foreign")
                return nil
            }
            switch kind {
            case .window, .sheet:
                // Identity proof inside the FRESH public enumeration.
                guard windowIdentity.contains(HintAXElementKey(element: element)) else {
                    logger.error("generation validation failed: stale window/sheet root absent from the fresh enumeration")
                    return nil
                }
                guard boundary() else {
                    logger.error("generation validation aborted: cancelled or deadline")
                    return nil
                }
                let roleRead = backend.role(of: element) // ONE cached read below
                guard boundary() else {
                    logger.error("generation validation aborted: cancelled or deadline")
                    return nil
                }
                guard roleRead != HintAXRead<String>.unknown else {
                    logger.error("generation validation failed: root role transport failure")
                    return nil
                }
                // KIND consistency with the SAME cached read: a retained `.sheet` root
                // must freshly re-prove the public sheet ROLE; `.window` roots must not
                // have become one. Provenance is never re-minted upward from a guess.
                let freshKind: HintAXRootKind = roleRead
                    == HintAXRead<String>.value(kAXSheetRole as String) ? .sheet : .window
                guard freshKind == kind else {
                    logger.error("generation validation failed: root kind changed (context mismatch)")
                    return nil
                }
                guard boundary() else {
                    logger.error("generation validation aborted: cancelled or deadline")
                    return nil
                }
                let minimized = backend.minimized(element)
                guard boundary() else {
                    logger.error("generation validation aborted: cancelled or deadline")
                    return nil
                }
                guard minimized == HintAXRead<Bool>.value(false) else {
                    logger.error("generation validation failed: window/sheet root not explicitly non-minimized")
                    return nil
                }
                guard boundary() else {
                    logger.error("generation validation aborted: cancelled or deadline")
                    return nil
                }
                let rootFrame = backend.frame(of: element, boundary: boundary)
                guard boundary() else {
                    logger.error("generation validation aborted: cancelled or deadline")
                    return nil
                }
                guard case .value(let frameValue) = rootFrame,
                      HintAXGeometry.admitsOnScreen(frame: frameValue, screens: session.context.screens) else {
                    logger.error("generation validation failed: window/sheet root geometry unreadable or not admitted")
                    return nil
                }
            case .menuBar:
                // Identity proof against the FRESH public menu-bar lookup.
                guard case .value(.some(let freshMenuBar)) = menuLookup ?? HintAXRead<AXUIElement?>.value(nil),
                      HintAXElementKey(element: freshMenuBar) == HintAXElementKey(element: element) else {
                    logger.error("generation validation failed: stale menu root absent from the fresh menu-bar lookup")
                    return nil
                }
                guard boundary() else {
                    logger.error("generation validation aborted: cancelled or deadline")
                    return nil
                }
                let roleRead = backend.role(of: element)
                guard boundary() else {
                    logger.error("generation validation aborted: cancelled or deadline")
                    return nil
                }
                guard roleRead != HintAXRead<String>.unknown else {
                    logger.error("generation validation failed: menu root role transport failure")
                    return nil
                }
            }
        }
        // COMPLETE participation classification of every FRESH NONBASELINE surface
        // (transients): public identity, explicitly minimized state, public frame
        // admission against the captured screens, and attachment proven by public
        // ancestry to EXACTLY ONE retained root. Baseline roots were fully validated
        // above; every other enumerated surface is classified HERE so preflight and
        // mutation share one classification — admission (minimized/on-screen) or sponsor
        // changes are caught by snapshot equality even when AX identity is unchanged.
        let rootIDByElement = Dictionary(
            uniqueKeysWithValues: session.baselineRoots.map {
                (HintAXElementKey(element: $0.element), $0.rootID)
            }
        )
        let baselineKeySet = Set(rootIDByElement.keys)
        var participations = Set<HintAXTransientParticipation>()
        var admittedTransients: [(element: AXUIElement, sponsor: HintAXRootID)] = []
        for window in windowElements {
            let identity = HintAXElementKey(element: window)
            guard !baselineKeySet.contains(identity) else { continue } // validated above
            guard boundary() else {
                logger.error("generation validation aborted: cancelled or deadline")
                return nil
            }
            let minimized = backend.minimized(window)
            guard boundary() else {
                logger.error("generation validation aborted: cancelled or deadline")
                return nil
            }
            switch minimized {
            case .unknown:
                logger.error("generation validation failed: unknown minimized state on a fresh nonbaseline surface")
                return nil
            case .value(true):
                // Explicitly minimized: SKIPPED participation (sponsor stays nil).
                participations.insert(HintAXTransientParticipation(identity: identity, admitted: false, sponsor: nil))
                continue
            case .value(false):
                break
            }
            guard boundary() else {
                logger.error("generation validation aborted: cancelled or deadline")
                return nil
            }
            let frameRead = backend.frame(of: window, boundary: boundary)
            guard boundary() else {
                logger.error("generation validation aborted: cancelled or deadline")
                return nil
            }
            switch frameRead {
            case .unknown:
                logger.error("generation validation failed: unreadable frame on a fresh nonbaseline surface")
                return nil
            case .value(let frameValue):
                guard HintAXGeometry.admitsOnScreen(frame: frameValue, screens: session.context.screens) else {
                    // Proven off captured screens: SKIPPED participation (sponsor stays nil).
                    participations.insert(HintAXTransientParticipation(identity: identity, admitted: false, sponsor: nil))
                    continue
                }
            }
            guard boundary() else {
                logger.error("generation validation aborted: cancelled or deadline")
                return nil
            }
            // Attachment: EXACTLY ONE retained root or the whole generation fails; the
            // boundary abort honestly classifies as failure (caller-closed, never a guess).
            guard let sponsor = uniqueRetainedRoot(
                of: window, rootIDsByElement: rootIDByElement,
                maxDepth: limits.maxDepth, boundary: boundary
            ) else {
                logger.error("generation validation failed: unproven or ambiguous attachment of a fresh nonbaseline surface")
                return nil
            }
            participations.insert(HintAXTransientParticipation(identity: identity, admitted: true, sponsor: sponsor))
            admittedTransients.append((element: window, sponsor: sponsor))
        }
        let snapshot = HintAXGenerationSnapshot(
            key: key,
            windowIdentity: windowIdentity,
            menuIdentity: menuLookup.flatMap { read -> HintAXElementKey? in
                guard case .value(.some(let menu)) = read else { return nil }
                return HintAXElementKey(element: menu)
            },
            transientParticipations: participations
        )
        return (snapshot, windowElements, admittedTransients)
    }

    // MARK: Store 1 — capture

    /// Captures the participating context for `targetPid` under the frozen service-limit
    /// wall clock. Participating roots come from the public `kAXWindowsAttribute`
    /// enumeration: original windows (`.window`) or sheet surfaces (`.sheet`, proven by
    /// public `kAXSheetRole`), plus the app's public menu-bar surface (`.menuBar`).
    /// Unknown/foreign-PID entries in the required window enumeration REJECT the capture
    /// (never silently skipped). Admission per window/sheet root: explicitly NOT
    /// minimized and geometry admitted against the captured screens; unknown required
    /// state rejects. Returned value carries ONLY the pending ID and the pure context;
    /// stop/cancellation is rechecked immediately before publishing.
    public func captureContext(
        targetPid: Int32,
        screens: [HintRect]
    ) async -> HintCapturedContext? {
        await perform { [weak self] in
            guard let self else { return nil }
            return self.captureLocked(targetPid: targetPid, screens: screens)
        }
    }

    /// Runs on the serial executor.
    private func captureLocked(targetPid: Int32, screens: [HintRect]) -> HintCapturedContext? {
        if registry.isStopped {
            logger.error("capture rejected: service stopped")
            return nil
        }
        if pendingCapture != nil {
            logger.error("capture rejected: another pending capture exists (adopt or discard first)")
            return nil
        }
        guard targetPid != lineupPid, targetPid != 0 else {
            logger.error("capture rejected: target pid is Lineup or zero")
            return nil
        }
        guard let frontmostPid = frontmost.currentFrontmostPID(), frontmostPid == targetPid else {
            logger.error("capture rejected: target not frontmost or frontmost unknown")
            return nil
        }
        let application = backend.applicationElement(pid: targetPid)
        // The service-limit wall clock and boundary begin BEFORE the first
        // application-element AX message (the pid read below) and are checked around it.
        let deadlineMs = clock.nowMs() + limits.wallClockMs
        let boundary: HintAXBoundary = { !self.registry.isStopped && self.clock.nowMs() < deadlineMs }
        guard boundary() else {
            logger.error("capture aborted: cancelled or deadline before the application pid read")
            return nil
        }
        guard backend.pid(of: application) == targetPid else {
            logger.error("capture failed: application element pid mismatch")
            return nil
        }
        guard boundary() else {
            logger.error("capture aborted: cancelled or deadline after the application pid read")
            return nil
        }

        // REQUIRED public window enumeration: any error rejects the capture.
        guard boundary() else { return nil }
        guard case .value(let windowElements) = backend.windows(of: application) else {
            logger.error("capture rejected: unknown window enumeration")
            return nil
        }
        guard boundary() else { return nil }

        var participating: [(element: AXUIElement, rootID: HintAXRootID, kind: HintAXRootKind)] = []
        var windowsSeen = Set<HintAXElementKey>()

        // Kind-appropriate admission. Returns true to continue; false rejects the capture.
        // `roleRead` is cached: classification (sheet role) and the liveness gate share
        // ONE fresh read instead of duplicating the AX message.
        func evaluate(_ element: AXUIElement, kind: HintAXRootKind, roleRead: HintAXRead<String>) -> Bool {
            let pid = backend.pid(of: element)
            guard boundary() else { logger.error("capture aborted: cancelled or deadline"); return false }
            // Unknown/foreign PID in the required enumeration REJECTS the capture.
            guard pid == targetPid, pid != lineupPid else {
                logger.error("capture rejected: unknown/foreign-PID entry in the window enumeration")
                return false
            }
            guard roleRead != HintAXRead<String>.unknown else {
                logger.error("capture rejected: root liveness unreadable")
                return false
            }
            switch kind {
            case .window, .sheet:
                // Explicit non-minimized is a REQUIRED public admission proof; unknown
                // REJECTS (fail closed), explicitly minimized windows are skipped.
                guard boundary() else { logger.error("capture aborted: cancelled or deadline"); return false }
                let minimized = backend.minimized(element)
                guard boundary() else { logger.error("capture aborted: cancelled or deadline"); return false }
                if minimized.isUnknown {
                    logger.error("capture rejected: minimized state unknown")
                    return false
                }
                guard minimized != HintAXRead<Bool>.value(true) else {
                    windowsSeen.insert(HintAXElementKey(element: element)) // minimized; skip
                    return true
                }
                // Public geometry admission (the non-public AXVisible/AXIsOnScreen reads
                // do not exist): unreadable frame rejects; proven off-captured-screens skips.
                guard boundary() else { logger.error("capture aborted: cancelled or deadline"); return false }
                let frameRead = backend.frame(of: element, boundary: boundary)
                guard boundary() else { logger.error("capture aborted: cancelled or deadline"); return false }
                guard case .value(let frame) = frameRead else {
                    logger.error("capture rejected: root frame unreadable")
                    return false
                }
                guard HintAXGeometry.admitsOnScreen(frame: frame, screens: screens) else {
                    windowsSeen.insert(HintAXElementKey(element: element)) // off captured screens
                    return true
                }
            case .menuBar:
                break // presence + pid + live role suffice for the menu-bar kind
            }
            windowsSeen.insert(HintAXElementKey(element: element))
            let rootID = HintAXRootID(tokenFactory.mint())
            participating.append((element, rootID, kind))
            return true
        }

        for window in windowElements {
            guard boundary() else { return nil }
            guard !windowsSeen.contains(HintAXElementKey(element: window)) else { continue }
            // Public ROLE discovery with one cached read: sheet surfaces prove the public
            // sheet ROLE (`kAXSheetRole`; there is no public sheet subrole). Unknown role
            // conservatively takes the STRONGEST (window) admission checks.
            let roleRead = backend.role(of: window)
            guard boundary() else { logger.error("capture aborted: cancelled or deadline"); return nil }
            let kind: HintAXRootKind = roleRead == HintAXRead<String>.value(kAXSheetRole as String)
                ? .sheet
                : .window
            guard evaluate(window, kind: kind, roleRead: roleRead) else { return nil }
        }
        guard boundary() else { logger.error("capture aborted: cancelled or deadline"); return nil }
        switch backend.menuBar(of: application) {
        case .unknown:
            logger.error("capture rejected: menu-bar liveness transport failure")
            return nil
        case .value(.some(let menuBar)):
            // Cache the menu-bar pid ONCE with boundary checks before/after the message.
            guard boundary() else {
                logger.error("capture aborted: cancelled or deadline before the menu-bar pid read")
                return nil
            }
            let menuPid = backend.pid(of: menuBar)
            guard boundary() else {
                logger.error("capture aborted: cancelled or deadline after the menu-bar pid read")
                return nil
            }
            guard menuPid == targetPid, menuPid != lineupPid else { break }
            if !windowsSeen.contains(HintAXElementKey(element: menuBar)) {
                let rootID = HintAXRootID(tokenFactory.mint())
                participating.append((menuBar, rootID, .menuBar))
            }
        case .value(.none):
            break // known absence of a menu bar is acceptable
        }

        guard !participating.isEmpty else {
            logger.error("capture rejected: no participating roots")
            return nil
        }

        // Recheck the SAME capture boundary (stop AND deadline) immediately before
        // publishing the PENDING state: a budget-expired capture publishes nothing.
        guard boundary() else {
            logger.error("capture rejected: captured boundary crossed before publication")
            return nil
        }
        let windowTokens = Set(participating.map { $0.rootID.raw })
        let context = HintTargetContext(pid: targetPid, windowTokens: windowTokens, screens: screens)
        let pending = HintPendingCapture(
            id: HintPendingCaptureID(tokenFactory.mint()),
            targetPid: targetPid,
            context: context,
            application: application,
            roots: participating
        )
        logger.info("captured pending: roots \(participating.count, privacy: .public)")
        pendingCapture = pending
        return HintCapturedContext(pendingID: pending.id, context: context)
    }

    // MARK: Store 2 — adoption

    /// Promotes the pending capture into a session owned by the FULL key. The generation-0
    /// key is RESERVED (registry active-key binding) BEFORE cancellable AX validation and
    /// re-checked immediately before publication: cancelled/stale adoptions NEVER publish.
    /// A failed NON-cancelled validation consistently retains the pending capture for a
    /// retry/discard. Atomic: pending/session stores swap in one executor step.
    public func adoptCapture(
        id: HintPendingCaptureID,
        for key: HintSessionKey,
        matching context: HintTargetContext
    ) async -> Bool {
        await perform { [weak self] in
            guard let self else { return false }
            return self.adoptLocked(id: id, key: key, context: context)
        }
    }

    /// Runs on the serial executor.
    private func adoptLocked(id: HintPendingCaptureID, key: HintSessionKey, context: HintTargetContext) -> Bool {
        if registry.isStopped || registry.isPendingDiscarded(id) || registry.isSessionCancelled(id: key.id) {
            logger.error("adopt rejected: cancelled, discarded, or stopped")
            return false
        }
        guard key.generation == 0 else {
            logger.error("adopt rejected: owner binding requires generation 0")
            return false
        }
        guard sessions[key.id] == nil else {
            logger.error("adopt rejected: session owner id already adopted")
            return false
        }
        guard let pending = pendingCapture, pending.id == id, !pending.roots.isEmpty else {
            logger.error("adopt rejected: unknown or superseded pending capture")
            return false
        }
        guard pending.context == context else {
            logger.error("adopt rejected: context drift between capture and adoption")
            return false
        }

        // RESERVE the exact generation-0 binding BEFORE cancellable validation so every
        // concurrent release/scan observes authoritative ownership. A rejected binding
        // (stopped, cancelled, or conflicting) aborts adoption before any AX message.
        guard registry.bindActiveKey(key) else {
            logger.error("adopt rejected: active-key binding refused (stopped, cancelled, or conflicting)")
            return false
        }

        // Bounded validation: frozen service-limit wall clock + cancellation boundaries
        // around every AX message.
        let deadlineMs = clock.nowMs() + limits.wallClockMs
        let boundary: HintAXBoundary = {
            !self.registry.isStopped
                && !self.registry.isPendingDiscarded(id)
                && !self.registry.isSessionCancelled(id: key.id)
                && self.clock.nowMs() < deadlineMs
        }
        guard let frontmostPid = frontmost.currentFrontmostPID(), frontmostPid == pending.targetPid else {
            logger.error("adopt rejected: target no longer frontmost or frontmost unknown")
            return false
        }
        for (element, _, kind) in pending.roots {
            guard boundary() else { return false }
            switch kind {
            case .window, .sheet:
                guard backend.pid(of: element) == pending.targetPid else {
                    logger.error("adopt rejected: root pid no longer the captured target")
                    return false
                }
                guard boundary() else { return false }
                let roleRead = backend.role(of: element)
                guard boundary() else { return false }
                guard roleRead != HintAXRead<String>.unknown else {
                    logger.error("adopt rejected: root role transport failure")
                    return false
                }
                guard boundary() else { return false }
                let minimized = backend.minimized(element)
                guard boundary() else { return false }
                guard minimized == HintAXRead<Bool>.value(false) else {
                    logger.error("adopt rejected: root no longer explicitly non-minimized")
                    return false
                }
                guard boundary() else { return false }
                let frameRead = backend.frame(of: element, boundary: boundary)
                guard boundary() else { return false }
                guard case .value(let frame) = frameRead,
                      HintAXGeometry.admitsOnScreen(frame: frame, screens: context.screens) else {
                    logger.error("adopt rejected: root no longer admitted by geometry")
                    return false
                }
            case .menuBar:
                guard backend.pid(of: element) == pending.targetPid else {
                    logger.error("adopt rejected: menu root pid no longer the captured target")
                    return false
                }
                guard boundary() else { return false }
                let roleRead = backend.role(of: element)
                guard boundary() else { return false }
                guard roleRead != HintAXRead<String>.unknown else {
                    logger.error("adopt rejected: menu root role transport failure")
                    return false
                }
            }
        }

        // Recheck the EXACT binding (and all cancel state) IMMEDIATELY before publication;
        // generation-0 must still be the authoritative active key and the adoption's own
        // wall-clock budget must still hold — a deadline-expired adoption never publishes.
        guard clock.nowMs() < deadlineMs,
              !registry.isStopped,
              !registry.isPendingDiscarded(id),
              !registry.isSessionCancelled(id: key.id),
              registry.activeKey(for: key.id) == key else {
            logger.error("adopt aborted: deadline crossed or session binding drifted/cancelled before publication")
            return false
        }
        // Atomic promotion: references move out of the pending store into the session.
        sessions[key.id] = HintAXSessionRecord(
            ownerKey: key,
            activeKey: key,
            context: context,
            targetPid: pending.targetPid,
            application: pending.application,
            baselineRoots: pending.roots
        )
        pendingCapture = nil
        logger.info("adopted session \(key.id, privacy: .public): roots \(pending.roots.count, privacy: .public)")
        return true
    }

    // MARK: Store 3 — scanning (per full key)

    /// Scans the retained session roots for the plan's FULL key under the exact
    /// authoritative gates (active key + service limits + no duplicate live generation).
    /// The ABSOLUTE scan wall clock starts HERE, before the first preflight AX message.
    /// Publication runs HintsCore's `HintEligibility.prepare` (eligibility → ancestry
    /// dedupe → rank → cap with the EXACT captured context) and returns only the ranked,
    /// deduped, capped candidates; pre-cap discovered/accepted counts stay in the
    /// summary; the repository prunes down to the final retained token set afterwards.
    public func scan(plan: HintScanPlan) async -> HintScanResult? {
        await perform { [weak self] in
            guard let self else { return nil }
            return self.runScan(plan: plan)
        }
    }

    /// Runs on the serial executor.
    private func runScan(plan: HintScanPlan) -> HintScanResult? {
        let key = plan.key
        if registry.isStopped || registry.isCancelled(key) {
            logger.error("scan rejected: stopped or cancelled for gen \(key.generation, privacy: .public)")
            return nil
        }
        guard let session = sessions[key.id] else {
            logger.error("scan rejected: no adopted session for owner id \(key.id, privacy: .public)")
            return nil
        }

        // Exact authoritative gates — judged WITHOUT closing state (stale/foreign keys
        // must never poison live state):
        guard plan.limits == limits else {
            logger.error("scan rejected: plan limits differ from the service limits")
            return nil
        }
        guard plan.key == session.activeKey else {
            logger.error("scan rejected: plan key is not the session's authoritative active key")
            return nil
        }
        guard !session.liveGenerations.contains(key) else {
            logger.error("scan rejected: duplicate scan/publication for an already-live exact generation")
            return nil
        }

        // 1) Exact pure context equality with the adopted session record.
        guard plan.context == session.context else {
            logger.error("scan rejected: plan context differs from the adopted context")
            closeGenerationLocked(key: key)
            return nil
        }

        // 2) Frontmost PID must still match the captured target.
        guard let frontmostPid = frontmost.currentFrontmostPID(), frontmostPid == session.targetPid else {
            logger.error("scan rejected: target no longer frontmost (context mismatch)")
            closeGenerationLocked(key: key)
            return nil
        }

        // ABSOLUTE scan wall clock: begins BEFORE any preflight AX message below and is
        // shared with the traversal (never reset after preflight).
        let wallDeadlineMs = clock.nowMs() + limits.wallClockMs
        func crossed() -> Bool { clock.nowMs() >= wallDeadlineMs }

        // 3) THE bounded fresh generation validation/classification (shared with
        //    mutation-time checks): fresh required windows enumeration + unknown/
        //    foreign-PID entry hygiene + baseline identity/kind/liveness/admission +
        //    retained menu identity + the COMPLETE nonbaseline participation
        //    classification (identity, admitted-vs-skipped, exact sponsor). Deadline
        //    checks bracket EVERY internal AX message.
        guard let validated = validateGeneration(
            session: session, key: key, deadlineMs: wallDeadlineMs
        ) else {
            logger.error("scan rejected: generation validation failed (context mismatch, cancelled, or deadline)")
            closeGenerationLocked(key: key)
            return nil
        }
        let snapshot = validated.snapshot

        // 4) Bounded traversal over baseline roots plus ADMITTED transient surfaces
        //    (transients borrow the sponsor root ID; retained ONLY in this generation's
        //    repository). The wall clock started at the top and passes UNTOUCHED. The
        //    admitted set and sponsors come from the shared classification above.
        let roots: [(element: AXUIElement, rootID: HintAXRootID)]
            = session.baselineRoots.map { ($0.element, $0.rootID) }
                + validated.admittedTransients.map { ($0.element, $0.sponsor) }
        guard let outcome = HintAXTraversal.run(
            roots: roots,
            repository: repository,
            key: key,
            limits: limits,
            clock: clock,
            wallDeadlineMs: wallDeadlineMs,
            screens: session.context.screens,
            backend: backend,
            tokenFactory: tokenFactory,
            targetPid: session.targetPid,
            lineupPid: lineupPid,
            shouldAbort: { [weak self] in
                guard let self else { return true }
                return self.registry.isCancelled(key)
            }
        ) else {
            closeGenerationLocked(key: key)
            return nil
        }

        // 5) FINAL cancel/deadline recheck IMMEDIATELY before repository pruning and
        //    state publication: a failed final check publishes NOTHING and
        //    deterministically cleans the exact generation's state — no truncated
        //    partial ever escapes a crossed budget or a cancel.
        guard !registry.isStopped, !registry.isCancelled(key), !crossed() else {
            logger.error("scan aborted: cancelled or deadline crossed before publication")
            closeGenerationLocked(key: key)
            return nil
        }
        // 6) Publication: the shared Core preparation (eligibility → ancestry dedupe →
        //    rank → cap) owns the exact pre-cap counts and the final retained candidate
        //    list.
        let preparation = HintEligibility.prepare(
            outcome.candidates,
            context: plan.context,
            limits: plan.limits
        )
        var summary = outcome.summary
        // Pre-cap accepted count from the shared Core pipeline: NEVER overwritten by
        // anything smaller (anything the adapter discovered above the cap stays counted).
        summary.acceptedCandidates = preparation.acceptedCandidates
        summary.discoveredCandidates = max(summary.discoveredCandidates, outcome.candidates.count)
        if preparation.candidateCapReached {
            summary.truncationReasons.insert(.candidateCapReached)
        }
        summary.retainedCandidates = preparation.ranked.count
        // Repository pruning: ONLY final retained actionable candidate tokens stay in the
        // generation; container/overflow/noncandidate entries drop here.
        let retainedTokens = Set(preparation.ranked.map { $0.candidate.token.raw })
        repository.retain(tokens: retainedTokens, fullKey: key)
        // Generation-owned context snapshot: live for the published generation and
        // re-proven before mutations; released with the generation.
        sessions[key.id]?.liveGenerations.insert(key)
        generationSnapshots[key] = snapshot
        logger.info(
            "scan gen \(key.generation, privacy: .public): nodes \(outcome.visitedNodes, privacy: .public), discovered \(summary.discoveredCandidates, privacy: .public), accepted \(summary.acceptedCandidates, privacy: .public), retained \(summary.retainedCandidates, privacy: .public)"
        )
        return HintScanResult(candidates: preparation.ranked.map(\.candidate), summary: summary)
    }

    /// Runs on the serial executor: marks the exact full key cancelled and removes that
    /// generation's entities (targets, snapshots); unblocks the session's next scan.
    private func closeGenerationLocked(key: HintSessionKey) {
        registry.markGenerationCancelled(key)
        let released = repository.release(fullKey: key)
        generationSnapshots[key] = nil
        sessions[key.id]?.liveGenerations.remove(key)
        logger.info("closed generation \(key.generation, privacy: .public): elements \(released, privacy: .public)")
    }

    // MARK: Invocation

    /// Full bounded revalidation (exact-key ownership, generation snapshot freshness,
    /// pid/frontmost/ancestry/role/enabled/geometry/capability) then an immediate
    /// cancellation recheck, then an AT-MOST-ONCE dispatch.
    public func invoke(
        token: HintTargetToken,
        action: HintInvocationAction,
        key: HintSessionKey
    ) async -> HintInvocationOutcome {
        await perform { [weak self] in
            guard let self else { return .failed }
            return self.runInvoke(token: token, action: action, key: key)
        }
    }

    /// Runs on the serial executor with its own bounded wall clock.
    private func runInvoke(
        token: HintTargetToken,
        action: HintInvocationAction,
        key: HintSessionKey
    ) -> HintInvocationOutcome {
        let invocationDeadlineMs = clock.nowMs() + limits.wallClockMs
        let mutationBoundary: HintAXBoundary = {
            !self.registry.isCancelled(key) && self.clock.nowMs() < invocationDeadlineMs
        }
        if registry.isStopped || registry.isCancelled(key) {
            logger.error("invoke rejected: stopped or cancelled generation/session")
            return .failed
        }
        guard let session = sessions[key.id] else { return .failed }
        // Exact full-key token ownership AND provenance whose stored root is retained.
        guard let element = repository.element(for: token, in: key),
              let provenance = repository.provenance(for: token, in: key),
              session.rootIDs.contains(provenance.rootID) else {
            logger.error("invoke rejected: token unknown for the exact full key, or unproven root")
            return .failed
        }
        let rootIDsByElement = Dictionary(
            uniqueKeysWithValues: session.baselineRoots.map {
                (HintAXElementKey(element: $0.element), $0.rootID)
            }
        )
        // Every backend message below is a checked message: checked BEFORE it runs, so a
        // failed boundary issues NO further AX message anywhere on the mutation path.
        guard let elementPid = checkedMessage(mutationBoundary, label: "invoke element pid") {
            backend.pid(of: element)
        }, elementPid == session.targetPid, elementPid != lineupPid else {
            logger.error("invoke rejected: element pid differs from the captured target or is Lineup-owned")
            return failInvocationLocked(key: key)
        }
        guard let current = frontmost.currentFrontmostPID(), current == elementPid else {
            logger.error("invoke rejected: target pid no longer frontmost")
            return failInvocationLocked(key: key)
        }
        // THE bounded fresh generation revalidation, compared against the generation-
        // stored snapshot: ANY window-set or participating-surface change after the scan
        // (identity, admitted-vs-skipped participation, or exact sponsor) fails closed.
        guard let stored = generationSnapshots[key] else {
            logger.error("invoke rejected: no generation snapshot for the exact full key")
            return failInvocationLocked(key: key)
        }
        guard let fresh = validateGeneration(
            session: session, key: key, deadlineMs: invocationDeadlineMs
        ), fresh.snapshot == stored else {
            logger.error("invoke rejected: generation context changed (or aborted) since the scan")
            return failInvocationLocked(key: key)
        }
        guard mutationBoundary() else {
            logger.error("invoke aborted: cancelled or deadline after generation validation")
            return failInvocationLocked(key: key)
        }
        // Live ancestry proof with boundary checks around EVERY owningWindow/parent/
        // top-level message: the walk must reach EXACTLY ONE retained root and it must
        // be the candidate's EXACT provenance root — ambiguity or mismatch fails closed.
        guard let reachedRoot = uniqueRetainedRoot(
            of: element, rootIDsByElement: rootIDsByElement,
            maxDepth: limits.maxDepth, boundary: mutationBoundary
        ), reachedRoot == provenance.rootID, registry.isCancelled(key) == false,
            clock.nowMs() < invocationDeadlineMs else {
            logger.error("invoke rejected: ancestry does not reach the candidate's exact provenance root (or the walk aborted/ambiguous)")
            return failInvocationLocked(key: key)
        }
        guard mutationBoundary() else {
            logger.error("invoke aborted: cancelled or deadline after the ancestry proof")
            return failInvocationLocked(key: key)
        }
        // Honest optionals: unknown role/subrole transport REJECTS the mutation; known
        // absences (nil) admit via the frozen matrix (public constants only). The two
        // reads are SEPARATE checked messages — the subrole message is issued only when
        // the boundary still holds after the role message.
        let roleRead = checkedMessage(mutationBoundary, label: "invoke role read") {
            backend.role(of: element)
        }
        guard case .value(let roleString) = roleRead else {
            logger.error("invoke rejected: role transport failure/unknown (or boundary)")
            return failInvocationLocked(key: key)
        }
        let subroleOptional = checkedMessage(mutationBoundary, label: "invoke subrole read") {
            backend.subrole(of: element)
        }
        guard case .value(let subroleValue) = subroleOptional else {
            logger.error("invoke rejected: subrole transport failure/unknown (or boundary)")
            return failInvocationLocked(key: key)
        }
        let role: String? = roleString
        let subrole: String? = subroleValue
        if HintAXCandidateFactory.isSecure(role: role, subrole: subrole) {
            logger.error("invoke rejected: secure element")
            return failInvocationLocked(key: key)
        }
        let roleClass = HintAXCandidateFactory.classify(role: role, subrole: subrole, parentRole: nil)
        func actionAllowed(_ requested: HintInvocationAction, _ klass: HintRoleClass) -> Bool {
            switch (requested, klass) {
            case (.press, .button), (.press, .link), (.press, .checkbox), (.press, .radio),
                 (.press, .tab), (.press, .menuItem),
                 (.showMenu, .popup), (.showMenu, .menuTrigger),
                 (.focus, .editable):
                return true
            default:
                return false
            }
        }
        guard actionAllowed(action, roleClass) else {
            logger.error("invoke rejected: role/subrole not allowed for the requested action")
            return .failed
        }
        // Explicit enabled, then the ONE geometry admission proof (public finite positive
        // frame intersecting captured screens). No visibility attributes are read.
        let enabledRead = checkedMessage(mutationBoundary, label: "invoke enabled read") {
            backend.enabled(element)
        }
        guard enabledRead == HintAXRead<Bool>.value(true) else {
            logger.error("invoke rejected: element not explicitly enabled (or boundary)")
            return failInvocationLocked(key: key)
        }
        let frameRead = checkedMessage(mutationBoundary, label: "invoke frame read") {
            backend.frame(of: element, boundary: mutationBoundary)
        }
        guard case .value(let frame) = frameRead,
              HintAXGeometry.admitsOnScreen(frame: frame, screens: session.context.screens) else {
            logger.error("invoke rejected: frame unreadable or not admitted by the geometry proof")
            return failInvocationLocked(key: key)
        }
        // Freshly advertised action, or explicitly settable focus for the focus row ONLY.
        let dispatch: (name: String?, target: AXUIElement)
        switch action {
        case .press:
            let pressName = kAXPressAction as String
            let names = checkedMessage(mutationBoundary, label: "invoke press action read") {
                backend.actionNames(of: element)
            }
            guard case .value(let actionNames) = names, actionNames.contains(pressName) else {
                logger.error("invoke rejected: AXPress not currently advertised (or boundary)")
                return failInvocationLocked(key: key)
            }
            dispatch = (pressName, element)
        case .showMenu:
            let showMenuName = kAXShowMenuAction as String
            let names = checkedMessage(mutationBoundary, label: "invoke show-menu action read") {
                backend.actionNames(of: element)
            }
            guard case .value(let actionNames) = names, actionNames.contains(showMenuName) else {
                logger.error("invoke rejected: AXShowMenu not currently advertised (or boundary)")
                return failInvocationLocked(key: key)
            }
            dispatch = (showMenuName, element)
        case .focus:
            let settableRead = checkedMessage(mutationBoundary, label: "invoke focus settable read") {
                backend.isFocusedSettable(element)
            }
            guard settableRead == HintAXRead<Bool>.value(true) else {
                logger.error("invoke rejected: kAXFocusedAttribute not explicitly settable now (or boundary)")
                return failInvocationLocked(key: key)
            }
            dispatch = (nil, element)
        }
        // Dispatch exactly once (checked message: the boundary is verified immediately
        // before the single mutation and a failed check returns `.cannotComplete`
        // WITHOUT dispatching). No retry on any path.
        let error: AXError = checkedMessage(mutationBoundary, label: "invoke dispatch") {
            if let name = dispatch.name {
                return backend.performAction(name, on: dispatch.target)
            }
            return backend.setFocused(true, on: dispatch.target)
        }
        switch error {
        case .success:
            logger.info("invoke dispatched once")
            return action == .showMenu ? .succeededNeedsRescan : .succeeded
        case .cannotComplete:
            logger.error("invoke dispatch returned cannotComplete (at-most-once honored)")
            return .unknownOutcome
        case .failure, .invalidUIElement:
            logger.error("invoke dispatch failed: element stale or invalid")
            return failInvocationLocked(key: key)
        default:
            logger.error("invoke dispatch failed with AX error \(Int(error.rawValue), privacy: .public)")
            return .failed
        }
    }

    /// Runs on the serial executor: hard failure closes the generation's targets.
    private func failInvocationLocked(key: HintSessionKey) -> HintInvocationOutcome {
        closeGenerationLocked(key: key)
        return .failed
    }

    // MARK: Scroll (public semantic matrix; see the header for the exact mapping)

    /// Revalidates fully (including token provenance, generation snapshot freshness, the
    /// geometry proof, and an explicit secure-subrole rejection), then an immediate
    /// cancellation recheck, then dispatches the requested provable scroll operation at
    /// most once. Unsupported commands are never attempted.
    public func scroll(
        token: HintTargetToken,
        operation: HintScrollOperation,
        key: HintSessionKey
    ) async -> HintMutationOutcome {
        await perform { [weak self] in
            guard let self else { return .failed }
            return self.runScroll(token: token, operation: operation, key: key)
        }
    }

    /// Runs on the serial executor with its own bounded wall clock.
    private func runScroll(
        token: HintTargetToken,
        operation: HintScrollOperation,
        key: HintSessionKey
    ) -> HintMutationOutcome {
        let scrollDeadlineMs = clock.nowMs() + limits.wallClockMs
        let mutationBoundary: HintAXBoundary = {
            !self.registry.isCancelled(key) && self.clock.nowMs() < scrollDeadlineMs
        }
        if registry.isStopped || registry.isCancelled(key) {
            logger.error("scroll rejected: stopped or cancelled generation/session")
            return .failed
        }
        guard let session = sessions[key.id],
              let element = repository.element(for: token, in: key),
              let provenance = repository.provenance(for: token, in: key),
              session.rootIDs.contains(provenance.rootID) else {
            logger.error("scroll rejected: token/provenance unknown for the exact full key, or root not retained")
            return .failed
        }
        let rootIDsByElement = Dictionary(
            uniqueKeysWithValues: session.baselineRoots.map {
                (HintAXElementKey(element: $0.element), $0.rootID)
            }
        )
        // Every backend message below is a checked message: checked BEFORE it runs, so a
        // failed boundary issues NO further AX message anywhere on the mutation path.
        guard let elementPid = checkedMessage(mutationBoundary, label: "scroll element pid") {
            backend.pid(of: element)
        }, elementPid == session.targetPid, elementPid != lineupPid else {
            logger.error("scroll rejected: element pid mismatch or Lineup-owned")
            return .failed
        }
        guard let current = frontmost.currentFrontmostPID(), current == elementPid else {
            logger.error("scroll rejected: target pid no longer frontmost")
            return .failed
        }
        // THE bounded fresh generation revalidation compared against the generation-
        // stored snapshot; ANY window-set or participating-surface change after the scan
        // (identity, admitted-vs-skipped participation, or exact sponsor) fails closed.
        guard let stored = generationSnapshots[key] else {
            logger.error("scroll rejected: no generation snapshot for the exact full key")
            return .failed
        }
        guard let fresh = validateGeneration(
            session: session, key: key, deadlineMs: scrollDeadlineMs
        ), fresh.snapshot == stored else {
            logger.error("scroll rejected: generation context changed (or aborted) since the scan")
            return .failed
        }
        guard mutationBoundary() else {
            logger.error("scroll aborted: cancelled or deadline after generation validation")
            return .failed
        }
        // Live ancestry proof with boundary checks around EVERY ancestry message: the
        // walk must reach EXACTLY ONE retained root and it must be the candidate's
        // EXACT provenance root — ambiguity or mismatch fails closed.
        guard let reachedRoot = uniqueRetainedRoot(
            of: element, rootIDsByElement: rootIDsByElement,
            maxDepth: limits.maxDepth, boundary: mutationBoundary
        ), reachedRoot == provenance.rootID, registry.isCancelled(key) == false,
            clock.nowMs() < scrollDeadlineMs else {
            logger.error("scroll rejected: ancestry does not reach the candidate's exact provenance root (or the walk aborted/ambiguous)")
            return .failed
        }
        guard mutationBoundary() else {
            logger.error("scroll aborted: cancelled or deadline after the ancestry proof")
            return .failed
        }
        // Honest optionals: unknown role/subrole transport rejects; secure subrole is
        // EXPLICITLY rejected on the scroll lane. The two reads are SEPARATE checked
        // messages — the subrole message is issued only when the boundary still holds
        // after the role message.
        let roleRead = checkedMessage(mutationBoundary, label: "scroll role read") {
            backend.role(of: element)
        }
        guard case .value(let roleString) = roleRead else {
            logger.error("scroll rejected: role transport failure/unknown (or boundary)")
            return .failed
        }
        let subroleOptional = checkedMessage(mutationBoundary, label: "scroll subrole read") {
            backend.subrole(of: element)
        }
        guard case .value(let subroleValue) = subroleOptional else {
            logger.error("scroll rejected: subrole transport failure/unknown (or boundary)")
            return .failed
        }
        if HintAXCandidateFactory.isSecure(role: roleString, subrole: subroleValue) {
            logger.error("scroll rejected: secure element")
            return .failed
        }
        // Role: only a scroll region may be scrolled.
        guard roleString == (kAXScrollAreaRole as String) else {
            logger.error("scroll rejected: element is not a scroll region")
            return .failed
        }
        // Explicitly enabled plus the ONE geometry admission proof.
        let enabledRead = checkedMessage(mutationBoundary, label: "scroll enabled read") {
            backend.enabled(element)
        }
        guard enabledRead == HintAXRead<Bool>.value(true) else {
            logger.error("scroll rejected: region not explicitly enabled (or boundary)")
            return .failed
        }
        let frameRead = checkedMessage(mutationBoundary, label: "scroll frame read") {
            backend.frame(of: element, boundary: mutationBoundary)
        }
        guard case .value(let frame) = frameRead,
              HintAXGeometry.admitsOnScreen(frame: frame, screens: session.context.screens) else {
            logger.error("scroll rejected: frame unreadable or not admitted by the geometry proof")
            return .failed
        }
        // Fresh public capability inspection (every internal AX message boundary-driven);
        // unsupported commands are never attempted.
        let capabilityRead = checkedMessage(mutationBoundary, label: "scroll capability inspection") {
            backend.scrollCapabilities(of: element, boundary: mutationBoundary)
        }
        guard case .value(let capabilities) = capabilityRead, capabilities.contains(operation) else {
            logger.error("scroll fails closed: requested operation is not provably supported now")
            return .failed
        }

        // Resolve the scroll relationship (which element carries the command), then
        // dispatch AT MOST ONCE. EVERY backend message below is a checked message; the
        // mutation itself is the final checked message whose pre-check is the immediate
        // cancellation recheck.
        let dispatchError: AXError
        switch operation {
        case .up, .down, .left, .right:
            let barsRead = checkedMessage(mutationBoundary, label: "scroll scrollbar lookup") {
                backend.scrollbars(of: element, boundary: mutationBoundary)
            }
            guard case .value(let bars) = barsRead else {
                logger.error("scroll fails closed: scrollbar relationship unreadable")
                return .failed
            }
            let vertical = operation.isVertical
            guard let bar = vertical ? bars.vertical : bars.horizontal,
                  (checkedMessage(mutationBoundary, label: "scroll scrollbar pid") {
                    backend.pid(of: bar)
                }) == elementPid else {
                logger.error("scroll fails closed: scrollbar unresolved or foreign")
                return .failed
            }
            let actionName = scrollAxisAction(operation, vertical: vertical)
            let namesRead = checkedMessage(mutationBoundary, label: "scroll scrollbar action read") {
                backend.actionNames(of: bar)
            }
            guard case .value(let names) = namesRead, names.contains(actionName) else {
                logger.error("scroll fails closed: scroll action not freshly advertised")
                return .failed
            }
            dispatchError = checkedMessage(mutationBoundary, label: "scroll dispatch") {
                backend.performAction(actionName, on: bar)
            }
        case .pageUp, .pageDown:
            let stepperRead = checkedMessage(mutationBoundary, label: "scroll page stepper lookup") {
                backend.pageStepper(of: element, increment: operation == .pageDown, boundary: mutationBoundary)
            }
            guard case .value(.some(let stepper)) = stepperRead,
                  (checkedMessage(mutationBoundary, label: "scroll page stepper pid") {
                    backend.pid(of: stepper)
                }) == elementPid else {
                logger.error("scroll fails closed: page stepper unavailable or foreign")
                return .failed
            }
            let namesRead = checkedMessage(mutationBoundary, label: "scroll stepper action read") {
                backend.actionNames(of: stepper)
            }
            guard case .value(let names) = namesRead, names.contains(kAXPressAction as String) else {
                logger.error("scroll fails closed: page stepper press not freshly advertised")
                return .failed
            }
            dispatchError = checkedMessage(mutationBoundary, label: "scroll dispatch") {
                backend.performAction(kAXPressAction as String, on: stepper)
            }
        case .home, .end:
            let barsRead = checkedMessage(mutationBoundary, label: "scroll vertical scrollbar lookup") {
                backend.scrollbars(of: element, boundary: mutationBoundary)
            }
            guard case .value(let bars) = barsRead, let bar = bars.vertical,
                  (checkedMessage(mutationBoundary, label: "scroll vertical scrollbar pid") {
                    backend.pid(of: bar)
                }) == elementPid else {
                logger.error("scroll fails closed: vertical scrollbar unavailable or foreign")
                return .failed
            }
            let settableRead = checkedMessage(mutationBoundary, label: "scroll value settable read") {
                backend.isValueSettable(bar)
            }
            guard settableRead == HintAXRead<Bool>.value(true) else {
                logger.error("scroll fails closed: scrollbar value not freshly settable")
                return .failed
            }
            let rangeRead = checkedMessage(mutationBoundary, label: "scroll numeric range read") {
                backend.numericRange(of: bar, boundary: mutationBoundary)
            }
            guard case .value(let range) = rangeRead,
                  range.minimum.isFinite, range.maximum.isFinite,
                  range.minimum < range.maximum else {
                logger.error("scroll fails closed: scrollbar range invalid or unreadable")
                return .failed
            }
            let targetValue = operation == .home ? range.minimum : range.maximum
            dispatchError = checkedMessage(mutationBoundary, label: "scroll dispatch") {
                backend.setNumericValue(targetValue, on: bar)
            }
        }

        switch dispatchError {
        case .success:
            logger.info("scroll dispatched once")
            return .applied
        case .cannotComplete:
            logger.error("scroll dispatch returned cannotComplete (at-most-once honored)")
            return .unknownOutcome
        case .failure, .invalidUIElement:
            logger.error("scroll dispatch failed: element stale or invalid")
            return .failed
        case .actionUnsupported:
            logger.error("scroll dispatch failed: action unsupported")
            return .failed
        default:
            logger.error("scroll dispatch failed with AX error \(Int(dispatchError.rawValue), privacy: .public)")
            return .failed
        }
    }

    /// The public decrement/increment action for one scroll operation on its axis.
    private func scrollAxisAction(_ operation: HintScrollOperation, vertical: Bool) -> String {
        switch (operation, vertical) {
        case (.up, true), (.left, false): return kAXDecrementAction as String
        default: return kAXIncrementAction as String
        }
    }

    // MARK: Release surface (synchronous authorization; awaited serialized cleanup)

    /// Authorized ONLY on an exact active full-key match: synchronously cancels that
    /// generation and ADVANCES the authorization to `key.nextGeneration`; the serialized
    /// cleanup then releases ONLY that exact generation's targets/snapshots and updates
    /// the session's authoritative active key. A stale/foreign/future key prunes ONLY
    /// the exact key's repository records and its exact-key generation snapshot — it
    /// NEVER marks cancellation, advances state, poisons a future key, or touches
    /// roots/live generations.
    public func releaseGeneration(_ key: HintSessionKey) async {
        if let next = registry.authorizeGenerationRelease(key) {
            await perform { [weak self] in
                guard let self else { return }
                self.repository.release(fullKey: key)
                self.generationSnapshots[key] = nil
                if var record = self.sessions[key.id] {
                    record.activeKey = next
                    record.liveGenerations.remove(key)
                    self.sessions[key.id] = record
                }
                self.logger.info("released gen \(key.generation, privacy: .public): active advanced")
            }
        } else {
            // Stale/foreign/future: prune ONLY that exact key's repository records and its
            // exact-key generation snapshot; NO cancellation, advancement, roots, active
            // key, or live-generation state is touched.
            let released = await perform { [weak self] in
                guard let self else { return 0 }
                self.generationSnapshots[key] = nil
                return self.repository.release(fullKey: key)
            }
            logger.info("ignored stale generation release: pruned \(released, privacy: .public) exact-key records")
        }
    }

    /// Removes the whole session/roots/snapshots/binding ONLY on an exact active
    /// full-key match; otherwise prunes the exact key's repository records and the
    /// exact-key generation snapshot and NEVER cancels the owner id or the roots.
    /// Idempotent.
    public func releaseSession(_ key: HintSessionKey) async {
        let authorized = registry.authorizeSessionRelease(key)
        await perform { [weak self] in
            guard let self else { return }
            if authorized {
                self.sessions.removeValue(forKey: key.id)
                self.repository.release(sessionId: key.id)
                for snapshotKey in self.generationSnapshots.keys where snapshotKey.id == key.id {
                    self.generationSnapshots[snapshotKey] = nil
                }
                self.logger.info("released session \(key.id, privacy: .public): roots+generations dropped")
            } else {
                // Stale/foreign/future: prune ONLY that exact key's repository records and
                // its exact-key generation snapshot; the owner id, roots, active key, and
                // live-generation state stay untouched.
                self.generationSnapshots[key] = nil
                let released = self.repository.release(fullKey: key)
                self.logger.info("ignored stale session release: pruned \(released, privacy: .public) exact-key records")
            }
        }
    }

    /// Marks the pending capture discarded synchronously, then awaits serialized cleanup.
    /// For repeated activation/capture abort.
    public func discardPendingCapture(_ id: HintPendingCaptureID) async {
        registry.discardPending(id)
        await perform { [weak self] in
            guard let self else { return }
            if self.pendingCapture?.id == id { self.pendingCapture = nil }
        }
    }

    /// Permanent stop: marks stopped SYNCHRONOUSLY BEFORE waiting (the active-key
    /// bindings go too), so in-flight bounded work observes the mark at its next
    /// cancellation boundary; then awaits serialized cleanup draining pending captures,
    /// adoption state, every session, snapshot, and AX reference via the ONE shared
    /// queue-confined routine. A stopped instance NEVER reopens.
    public func stop() async {
        registry.markStopped()
        await perform { [weak self] in
            self?.performStopCleanup()
        }
    }

    /// SYNCHRONOUS hard-lifecycle-teardown bridge for the frozen `Tool.stop()` /
    /// `TerminationCoordinator` cleanup APIs. Identical semantics to `stop()` with no
    /// `Task`, returning only after cleanup is COMPLETE:
    ///   1. Marks stopped intent SYNCHRONOUSLY FIRST (active-key bindings discarded),
    ///      so every bounded in-flight path observes the mark at its next cancellation
    ///      boundary and issues NO further AX messages.
    ///   2. Drains the private serial AX executor with the ONE shared queue-confined
    ///      cleanup routine (pending capture, sessions, generation snapshots, token
    ///      repository, full-key references — exactly as async `stop()`), so no AX value
    ///      or per-generation token survives the call.
    /// Idempotent: repeat calls re-mark and re-clean empty state with no effect beyond
    /// the journal entry. Deadlock prevention: a queue-specific marker proves whether
    /// the caller is ALREADY on the AX executor — in that case the shared routine runs
    /// INLINE on the same (still-serial) queue instead of `sync`ing onto itself, which
    /// would deadlock.
    /// Callers NOT on the AX queue stay serialized behind any in-flight operation, so
    /// the return moment is a deterministic post-cleanup point.
    public func stopAndWait() {
        registry.markStopped()
        if DispatchQueue.getSpecific(key: Self.axQueueMarkerKey) != nil {
            // Already ON the AX executor: inline cleanup, no self-`sync` deadlock.
            performStopCleanup()
            return
        }
        axQueue.sync { [weak self] in
            self?.performStopCleanup()
        }
    }

    /// The ONE queue-confined teardown routine shared by `stop()` and `stopAndWait()`:
    /// drains store 1/2/3 (pending capture, sessions, generation snapshots, token
    /// repository) exactly once per stop. Runs ONLY on the AX executor.
    private func performStopCleanup() {
        pendingCapture = nil
        sessions.removeAll()
        generationSnapshots.removeAll()
        repository.reset()
        logger.info("stopped: all AX references dropped (idle: no polling, no reopen)")
    }

    // MARK: Shared helpers (serial executor only)

    /// Bounded graph ancestry proof: from the candidate, explore ALL live PUBLIC upward
    /// links — every `kAXWindowAttribute` owning-window, `kAXParentAttribute`, and
    /// `kAXTopLevelUIElementAttribute` edge of every reached node (a lower-priority link
    /// fallback is IMPOSSIBLE: all live links are always examined). The proof FAILS
    /// (returns nil) on any unknown link read, on a cycle (a link back into the current
    /// path), when two different retained roots are reached (conflict), and whenever the
    /// frontier beyond the frozen 40-deep budget leaves ANY non-root strand unresolved —
    /// only a fully resolved graph whose upward closure touches EXACTLY ONE retained
    /// root succeeds. Boundary checks sit between EVERY AX read; a boundary abort fails
    /// closed. The walk itself stores no AX state anywhere; callers compare the returned
    /// root with the requirement (the scan classifier's unique sponsor root; the invoke/
    /// scroll candidate's EXACT provenance root).
    private func uniqueRetainedRoot(
        of element: AXUIElement,
        rootIDsByElement: [HintAXElementKey: HintAXRootID],
        maxDepth: Int,
        boundary: HintAXBoundary
    ) -> HintAXRootID? {
        var reached = Set<HintAXRootID>()
        var failed = false
        // Cycle detection: `onPath` marks the DFS path (a back edge ⇒ cycle);
        // `complete` memoizes fully explored subtrees (cross edges contribute nothing).
        var onPath = Set<HintAXElementKey>()
        var complete = Set<HintAXElementKey>()
        var inspected = 0

        func walk(_ node: AXUIElement, _ depth: Int) {
            guard !failed else { return }
            let key = HintAXElementKey(element: node)
            if complete.contains(key) { return } // cross edge into a fully proven subtree
            if onPath.contains(key) { failed = true; return } // cycle ⇒ unresolved proof
            // A retained root is terminal on every path (nothing lives above it); two
            // different retained roots reached by the SAME proof are a conflict.
            if let rootID = rootIDsByElement[key] {
                reached.insert(rootID)
                if reached.count > 1 { failed = true }
                return
            }
            // A non-root strand that would need to be expanded beyond the frozen depth
            // budget leaves ancestry unresolved: fail, never guess.
            guard depth < maxDepth else { failed = true; return }
            inspected += 1
            guard inspected <= limits.maxVisitedNodes else { failed = true; return } // node budget
            onPath.insert(key)
            defer { onPath.remove(key); complete.insert(key) }

            // ALL live upward links are read, each delimited by boundary checks: after
            // every read the boundary is re-verified before the next AX message.
            guard boundary() else { failed = true; return }
            let ownerRead = backend.owningWindow(of: node)
            guard boundary() else { failed = true; return }
            guard case .value(let ownerOptional) = ownerRead else { failed = true; return }
            let parentRead = backend.parent(of: node)
            guard boundary() else { failed = true; return }
            guard case .value(let parentOptional) = parentRead else { failed = true; return }
            let topLevelRead = backend.topLevelUIElement(of: node)
            guard boundary() else { failed = true; return }
            guard case .value(let topLevelOptional) = topLevelRead else { failed = true; return }

            var edges: [AXUIElement] = []
            if let owner = ownerOptional { edges.append(owner) }
            if let parent = parentOptional { edges.append(parent) }
            if let topLevel = topLevelOptional { edges.append(topLevel) }
            // An empty edge set is a fully resolved strand end (no ancestor ANYWHERE
            // above this node): no unresolved frontier, the path simply proves this
            // node roots outside every retained root.
            for edge in edges where !failed {
                walk(edge, depth + 1)
            }
        }

        walk(element, 0)
        guard !failed, reached.count == 1 else { return nil }
        return reached.first
    }
}

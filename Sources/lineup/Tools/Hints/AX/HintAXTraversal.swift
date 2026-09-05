import ApplicationServices
import HintsCore

// Bounded breadth-first AX traversal with cycle protection, exact frozen budgets
// (element-stamped 50 ms per-call timeout in the backend, depth 40, 4,000 nodes,
// 750 ms wall clock), rank-before-cap candidate retention, and hard cancellation around
// every AX message.
//
// Phase 2A official-header rules (public macOS 10.13 AXAttributeConstants.h): NO
//   AXVisible/AXIsOnScreen (they do not exist as public attributes). Visibility and
//   on-screen admission for candidate booleans comes from the pure geometry proof
//   (`HintAXGeometry.admitsOnScreen`) against the captured NSScreen-derived rectangles;
//   the single frame read feeds both the proof and the candidate shape.
//
// Phase 2A remediation 2 (B):
//   * Cancellation AND the wall-clock boundary are checked BEFORE and AFTER every single
//     AX call, so a node with many attributes cannot run past the scan budget.
//   * The ABSOLUTE scan wall-clock deadline is computed by `HintAXService.runScan` BEFORE
//     the preflight reads and passed here untouched — the preflight and the traversal
//     share one 750 ms budget.
//   * Composite backend helpers (`scrollCapabilities`, `pageStepper`, `frame`) run with
//     a `boundary` closure so they abort between every internal AX message too.
//   * Candidates are NOT truncated at discovery by the 1,500 candidate cap alone: HintsCore
//     performs rank-before-cap retention, so this scanner keeps discovering while the node
//     budget and wall clock allow, and `HintsCore.prepare` owns the cap/label cut. When
//     discovery exceeded the cap, `.candidateCapReached` is recorded as a count-only
//     truncation reason at the END so the scanner-side hard limit stays auditable — the
//     candidate LIST handed back may exceed `maxCandidates` and Core truncates it.
//   * The 4,000-node cap remains the traversal hard stop.
//
// Phase 2A remediation 2 (A): only the captured target PID's elements are traversed/
//   retained; an unknown or foreign PID node is rejected (skipped) — the guard happens
//   before any further probing of that node.
//
// Phase 2A remediation 2 (C): scroll-region advertisement comes exclusively from the
//   backend's fresh public capability inspection; failed inspections never advertise.

/// Hashable identity wrapper over an `AXUIElement` value using `CFHash`/`CFEqual`.
struct HintAXElementKey: Hashable {
    let element: AXUIElement

    static func == (lhs: HintAXElementKey, rhs: HintAXElementKey) -> Bool {
        CFEqual(lhs.element, rhs.element)
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(CFHash(element))
    }
}

/// One BFS frontier item. `rootID` is the proven sponsoring session root; candidates under
/// it always record exactly that root.
struct HintAXFrontierItem {
    let element: AXUIElement
    let depth: Int
    let rootID: HintAXRootID
    let parentRole: String?
    let ancestorTokens: [HintTargetToken]
}

/// Count-only per-scan counters feeding count-only `HintScanSummary` inputs.
struct HintAXTraversalOutcome {
    var visitedNodes = 0
    var deepestDepth = 0
    var discoveredCandidates = 0
    var candidates: [HintCandidate] = []
    var truncationReasons: Set<HintTruncationReason> = []

    var summary: HintScanSummary {
        HintScanSummary(
            visitedNodes: visitedNodes,
            deepestDepth: deepestDepth,
            discoveredCandidates: discoveredCandidates,
            acceptedCandidates: candidates.count,
            retainedCandidates: candidates.count,
            truncationReasons: truncationReasons
        )
    }
}

/// Deterministic bounded scanner over an injected `HintAXBackend`.
enum HintAXTraversal {

    /// Runs one full scan of `roots`. Synchronous with respect to the caller (the serial
    /// executor; never the main actor). Returns nil when CANCELLED — nothing publishes.
    /// `wallDeadlineMs` is the ABSOLUTE monotonic-millisecond scan deadline computed by
    /// the service BEFORE its preflight (shared budget; never reset here).
    static func run(
        roots: [(element: AXUIElement, rootID: HintAXRootID)],
        repository: HintAXTokenRepository,
        key: HintSessionKey,
        limits: HintScanLimits,
        clock: HintScanClock,
        wallDeadlineMs: Int64,
        screens: [HintRect],
        backend: HintAXBackend,
        tokenFactory: HintTokenFactory,
        targetPid: Int32,
        lineupPid: Int32,
        shouldAbort: () -> Bool
    ) -> HintAXTraversalOutcome? {
        var outcome = HintAXTraversalOutcome()
        var seen = Set<HintAXElementKey>()
        // Enqueued identity set: duplicate graph edges never inflate frontier CPU — a
        // child already queued is skipped at ENQUEUE time. `seen` still guards revisit
        // safety at dequeue time.
        var queued = Set<HintAXElementKey>(roots.map { HintAXElementKey(element: $0.element) })
        var frontier = roots.map { root in
            HintAXFrontierItem(
                element: root.element, depth: 0, rootID: root.rootID,
                parentRole: nil, ancestorTokens: []
            )
        }

        func deadlineMissed() -> Bool {
            clock.nowMs() >= wallDeadlineMs
        }
        /// Per-message boundary for composite backend helpers: aborts them between every
        /// internal AX message on cancellation or deadline.
        func boundary() -> Bool {
            !shouldAbort() && !deadlineMissed()
        }

        while !frontier.isEmpty {
            // Cancellation AND deadline at the very top, BEFORE dequeue.
            if shouldAbort() { return nil }
            if deadlineMissed() {
                outcome.truncationReasons.insert(.wallClockExceeded)
                break
            }

            let item = frontier.removeFirst()
            if item.depth > limits.maxDepth {
                outcome.truncationReasons.insert(.maxDepthReached)
                continue
            }
            outcome.deepestDepth = Swift.max(outcome.deepestDepth, item.depth)

            // Cycle protection BEFORE any read.
            let keyValue = HintAXElementKey(element: item.element)
            guard !seen.contains(keyValue) else { continue }
            seen.insert(keyValue)

            // Node budget: a visited node counts regardless of its fate; 4,000 hard cap.
            if outcome.visitedNodes >= limits.maxVisitedNodes {
                outcome.truncationReasons.insert(.nodeBudgetExhausted)
                break
            }
            outcome.visitedNodes += 1

            // --- Provenance gate: target PID only; unknown/foreign rejected. ---
            if !boundary() {
                if deadlineMissed() { outcome.truncationReasons.insert(.wallClockExceeded) }
                break
            }
            let pid = backend.pid(of: item.element)
            // Post-message cancellation and wall-clock boundary.
            if shouldAbort() { return nil }
            if deadlineMissed() {
                outcome.truncationReasons.insert(.wallClockExceeded)
                break
            }
            guard pid == targetPid, pid != lineupPid else { continue }

            // EVERY retained node mints its token here (before classification pruning)
            // so proven ancestor chains stay complete for both candidates and containers.
            // The mint is local, not an AX message.
            let token = repository.insert(
                element: item.element, key: key, rootID: item.rootID,
                ancestorTokens: item.ancestorTokens, factory: tokenFactory
            )

            // --- Classification reads (role/subrole) with per-call boundaries. ---
            if !boundary() {
                if deadlineMissed() { outcome.truncationReasons.insert(.wallClockExceeded) }
                break
            }
            let roleRead = backend.role(of: item.element)
            if shouldAbort() { return nil }
            if deadlineMissed() {
                outcome.truncationReasons.insert(.wallClockExceeded)
                break
            }
            let subroleRead = backend.subrole(of: item.element)
            if shouldAbort() { return nil }
            if deadlineMissed() {
                outcome.truncationReasons.insert(.wallClockExceeded)
                break
            }
            let parentRole: String? = item.parentRole
            // Honest optionals ONLY: transport/decoding `.unknown` role/subrole REJECTS
            // candidate admission (fail closed) while keeping chain traversal; `.value(nil)`
            // is a KNOWN absence and admits normally. Unknown is never collapsed to nil.
            guard case .value(let roleOptional) = roleRead,
                  case .value(let subroleOptional) = subroleRead else {
                guard let expanded = expandChildren(
                    item: item, role: nil, maxDepth: limits.maxDepth,
                    ancestorToken: token, outcome: &outcome,
                    frontier: &frontier, seen: &seen, queued: &queued, backend: backend,
                    shouldAbort: shouldAbort, deadlineCrossed: deadlineMissed
                ) else { return nil }
                if expanded == .deadline {
                    outcome.truncationReasons.insert(.wallClockExceeded)
                    break
                }
                continue
            }
            let role: String? = roleOptional
            let subrole: String? = subroleOptional

            let roleClass = HintAXCandidateFactory.classify(
                role: role, subrole: subrole, parentRole: parentRole
            )
            let secure = HintAXCandidateFactory.isSecure(role: role, subrole: subrole)

            // Matrix pruning: `other` can never advertise anything; keep traversing
            // children but probe nothing further for this node.
            if roleClass == .other {
                guard let expanded = expandChildren(
                    item: item, role: role, maxDepth: limits.maxDepth,
                    ancestorToken: token, outcome: &outcome,
                    frontier: &frontier, seen: &seen, queued: &queued, backend: backend,
                    shouldAbort: shouldAbort, deadlineCrossed: deadlineMissed
                ) else { return nil }
                if expanded == .deadline {
                    outcome.truncationReasons.insert(.wallClockExceeded)
                    break
                }
                continue
            }
            // Secure fields are rejected candidates; their values are never read. Keep
            // traversing children (a secure container's interior may hold readables) but
            // do not probe this node further than the action-surface read below.
            if !boundary() {
                if deadlineMissed() { outcome.truncationReasons.insert(.wallClockExceeded) }
                break
            }
            let actionNames = backend.actionNames(of: item.element)
            if shouldAbort() { return nil }
            if deadlineMissed() {
                outcome.truncationReasons.insert(.wallClockExceeded)
                break
            }

            let focusedSettable: HintAXRead<Bool>
            if roleClass == .editable {
                // Settability consulted ONLY for the editable focus row.
                if !boundary() {
                    if deadlineMissed() { outcome.truncationReasons.insert(.wallClockExceeded) }
                    break
                }
                focusedSettable = backend.isFocusedSettable(item.element)
                if shouldAbort() { return nil }
                if deadlineMissed() {
                    outcome.truncationReasons.insert(.wallClockExceeded)
                    break
                }
            } else {
                focusedSettable = HintAXRead<Bool>.value(false)
            }

            let scrollCapabilities: HintAXRead<Set<HintScrollOperation>>
            if roleClass == .scrollRegion {
                // Fresh public capability inspection for the scroll advertisement; the
                // composite helper aborts between every internal AX message.
                if !boundary() {
                    if deadlineMissed() { outcome.truncationReasons.insert(.wallClockExceeded) }
                    break
                }
                scrollCapabilities = backend.scrollCapabilities(of: item.element, boundary: boundary)
                if shouldAbort() { return nil }
                if deadlineMissed() {
                    outcome.truncationReasons.insert(.wallClockExceeded)
                    break
                }
            } else {
                scrollCapabilities = HintAXRead<Set<HintScrollOperation>>.value([])
            }

            // --- Geometry read with per-message boundary; ONE review feeds the pure
            // --- visibility/on-screen proof and the candidate shape.
            if !boundary() {
                if deadlineMissed() { outcome.truncationReasons.insert(.wallClockExceeded) }
                break
            }
            let frame = backend.frame(of: item.element, boundary: boundary)
            if shouldAbort() { return nil }
            if deadlineMissed() {
                outcome.truncationReasons.insert(.wallClockExceeded)
                break
            }
            let enabled = backend.enabled(item.element)
            if shouldAbort() { return nil }
            if deadlineMissed() {
                outcome.truncationReasons.insert(.wallClockExceeded)
                break
            }

            let advertised = HintAXCandidateFactory.advertisedActions(
                roleClass: roleClass,
                actionNames: actionNames,
                isSecure: secure,
                focusedSettable: focusedSettable,
                scrollCapabilities: scrollCapabilities
            )

            var searchMetadata: (title: String?, description: String?)?
            if !advertised.isEmpty {
                // Metadata reads are additional AX messages with the same boundaries;
                // never read for secure fields. No public label attribute is read.
                if !boundary() {
                    if deadlineMissed() { outcome.truncationReasons.insert(.wallClockExceeded) }
                    break
                }
                let titleRead = secure ? HintAXRead<String?>.value(nil) : backend.title(of: item.element)
                if shouldAbort() { return nil }
                if deadlineMissed() {
                    outcome.truncationReasons.insert(.wallClockExceeded)
                    break
                }
                let descriptionRead = secure
                    ? HintAXRead<String?>.value(nil)
                    : backend.accessibleDescription(of: item.element)
                if shouldAbort() { return nil }
                if deadlineMissed() {
                    outcome.truncationReasons.insert(.wallClockExceeded)
                    break
                }
                searchMetadata = (title: titleRead.value ?? nil, description: descriptionRead.value ?? nil)
            }

            if !advertised.isEmpty {
                outcome.discoveredCandidates += 1
                if let candidate = HintAXCandidateFactory.candidate(
                    from: HintAXCandidateFactory.Probe(
                        role: role,
                        subrole: subrole,
                        parentRole: parentRole,
                        frame: frame,
                        enabled: enabled,
                        actionNames: actionNames,
                        focusedSettable: focusedSettable,
                        scrollCapabilities: scrollCapabilities,
                        pid: pid ?? 0,
                        rootID: item.rootID,
                        ancestorTokens: item.ancestorTokens,
                        screens: screens
                    ),
                    searchMetadata: searchMetadata,
                    token: token
                ) {
                    outcome.candidates.append(candidate)
                }
            }

            // --- Child expansion with per-boundary cancellation and deadline handling ---
            guard let expanded = expandChildren(
                item: item, role: role, maxDepth: limits.maxDepth,
                ancestorToken: token, outcome: &outcome,
                frontier: &frontier, seen: &seen, queued: &queued, backend: backend,
                shouldAbort: shouldAbort, deadlineCrossed: deadlineMissed
            ) else { return nil }
            if expanded == .deadline {
                outcome.truncationReasons.insert(.wallClockExceeded)
                break
            }
        }

        // Rank-before-cap: discovery was NOT cut at the candidate cap; record the
        // count-only reason when the hard scanner cap was exceeded so auditing sees it.
        if outcome.candidates.count > limits.maxCandidates {
            outcome.truncationReasons.insert(.candidateCapReached)
        }

        // Cancellation checked before publishing: a cancelled pass publishes nothing.
        if shouldAbort() { return nil }
        return outcome
    }

    /// Child-expansion helper: reads (stamped) children only AFTER cancellation AND
    /// deadline checks, then re-checks BOTH after the enumeration message and appends the
    /// readable ones breadth-first in AX order. Cycle-safe via the shared identity set at
    /// enqueue time. Returns nil when CANCELLED; `.deadline` when the shared scan budget
    /// was crossed by or after the enumeration call (partial result then stands — the
    /// caller records `.wallClockExceeded` and breaks).
    private enum ExpansionContinuation { case done, deadline }

    private static func expandChildren(
        item: HintAXFrontierItem,
        role: String?,
        maxDepth: Int,
        ancestorToken: HintTargetToken,
        outcome: inout HintAXTraversalOutcome,
        frontier: inout [HintAXFrontierItem],
        seen: inout Set<HintAXElementKey>,
        queued: inout Set<HintAXElementKey>,
        backend: HintAXBackend,
        shouldAbort: () -> Bool,
        deadlineCrossed: () -> Bool
    ) -> ExpansionContinuation? {
        let childDepth = item.depth + 1
        if childDepth > maxDepth {
            outcome.truncationReasons.insert(.maxDepthReached)
            return .done
        }
        if shouldAbort() { return nil }
        if deadlineCrossed() { return .deadline }
        let childElements = backend.children(of: item.element)
        // Cancellation AND deadline AFTER the enumeration message, before expansion.
        if shouldAbort() { return nil }
        if deadlineCrossed() { return .deadline }
        switch childElements {
        case .value(let kids):
            for child in kids {
                let childKey = HintAXElementKey(element: child)
                // Enqueued-set guard first: duplicate graph edges never enter the queue.
                if queued.contains(childKey) { continue }
                queued.insert(childKey)
                guard !seen.contains(childKey) else { continue }
                frontier.append(
                    HintAXFrontierItem(
                        element: child, depth: childDepth, rootID: item.rootID,
                        parentRole: role,
                        ancestorTokens: [ancestorToken] + item.ancestorTokens
                    )
                )
            }
            return .done
        case .unknown:
            // Unknown subtree: stop expanding; fail closed for this branch without
            // aborting the rest of the scan.
            return .done
        }
    }
}

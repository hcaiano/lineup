import Foundation

/// Keyboard mode inside a presenting session.
public enum HintKeyboardMode: String, Codable, Hashable, Sendable, CaseIterable {
    /// Typing filters labels.
    case labels
    /// `/` entered accessible-name search over title/label/description.
    case search
    /// Space entered scroll-region selection; arrows/PageUp/PageDown/Home/End scroll.
    case scroll
}

/// Snapshot HintsCore hands to the overlay lane. Contains only derived display data so the
/// overlay never re-derives filtering decisions.
public struct HintPresentationSnapshot: Hashable, Sendable {
    public let key: HintSessionKey
    public let mode: HintKeyboardMode
    public let query: String
    /// Visible candidates in deterministic order (already filtered or search-ordered). The
    /// single authoritative visible pool for the current mode.
    public let visible: [HintLabelledCandidate]
    /// The candidate Return would invoke. Always equals the mode's actual Return target:
    /// the full-label selection in label/scroll modes, the first search result in search
    /// mode, and `nil` when Return is inert (empty query, no pool).
    public let selectedToken: HintTargetToken?
    public let selectedLabel: String?
    /// Count-only truncation status for status surfaces (reasons carry no candidate names).
    public let truncated: Bool
    public let truncationReasons: Set<HintTruncationReason>
    public let totalCandidates: Int
}

/// Session lifecycle: `idle -> scanning -> presenting -> invoking/scrolling -> idle | rescan`.
/// Every active state carries its `HintSessionKey` and the captured `HintTargetContext`
/// (there is no separately retained "current context"): async outcomes carry keys too, and
/// any mismatch is a stale result handled by the idempotent release rule.
public enum HintSessionState: Equatable, Sendable {
    case idle
    case scanning(HintScanPlan, resume: HintResume?)
    case presenting(HintPresentingState)
    case invoking(HintInvocationState)
    /// A semantic scroll is in flight; further scroll commands are ignored until it lands.
    case scrolling(HintScrollingState)

    /// The key of an active state; `nil` in idle.
    public var key: HintSessionKey? {
        switch self {
        case .idle: return nil
        case .scanning(let plan, _): return plan.key
        case .presenting(let presenting): return presenting.key
        case .invoking(let invoking): return invoking.key
        case .scrolling(let scrolling): return scrolling.key
        }
    }

    public var isActive: Bool { key != nil }
}

/// What a rescan should restore in the new generation: the mode to re-enter, the label
/// query to carry over, and the selected candidate's adapter-proven continuity identity.
/// Continuity (never a generation-bound target token) is the ONLY restoration key; a
/// missing, mismatched, or re-badged identity yields no selection.
public struct HintResume: Equatable, Sendable {
    public var mode: HintKeyboardMode
    public var query: String
    public var selectedContinuity: HintContinuityID?

    public init(mode: HintKeyboardMode, query: String, selectedContinuity: HintContinuityID?) {
        self.mode = mode
        self.query = query
        self.selectedContinuity = selectedContinuity
    }
}

public struct HintPresentingState: Equatable, Sendable {
    public var key: HintSessionKey
    public var context: HintTargetContext
    /// Labelled candidates in canonical rank order, allocated for this generation. Every
    /// mode slices its authoritative visible pool out of this single list.
    public var candidates: [HintLabelledCandidate]
    public var mode: HintKeyboardMode
    public var query: String
    /// Index into `candidates` of the Return-bound candidate, when one exists.
    public var selectedIndex: Int?
    /// Modifier-release barrier: key input is dropped until activation modifiers release.
    public var awaitingModifierRelease: Bool
    /// Count-only scan diagnostics for status surfaces (never control names or content).
    public var summary: HintScanSummary
}

public struct HintInvocationState: Equatable, Sendable {
    public var key: HintSessionKey
    public var context: HintTargetContext
    public var token: HintTargetToken
    public var action: HintActionKind
}

/// Scroll mode while a semantic scroll command is in flight.
public struct HintScrollingState: Equatable, Sendable {
    public var key: HintSessionKey
    public var context: HintTargetContext
    public var candidates: [HintLabelledCandidate]
    public var query: String
    public var selectedIndex: Int?
    /// Count-only diagnostics carried from the presenting state.
    public var summary: HintScanSummary
}

/// Result reported by the scroll adapter for one semantic scroll of the selected region.
/// Dispatch happens at most once per selection; `unknownOutcome` is never retried.
public enum HintMutationOutcome: String, Codable, Hashable, Sendable {
    case applied
    /// The adapter could not learn whether the scroll took effect
    /// (for example `kAXErrorCannotComplete`); treated like `applied`, with a fresh
    /// observational rescan — the tree may or may not have changed.
    case unknownOutcome
    case failed
}

/// Result reported by the invocation adapter. Dispatch happens at most once outside
/// HintsCore. `unknownOutcome` (for example `kAXErrorCannotComplete`) is never retried; only
/// a fresh observational rescan under a new generation may follow it.
public enum HintInvocationOutcome: String, Codable, Hashable, Sendable {
    case succeeded
    /// Succeeded, but the revealed change (menu/popover/reveal) requires a fresh scan.
    case succeededNeedsRescan
    case unknownOutcome
    case failed
}

/// Every reason a session can end without invocation. Cancellation always fails closed.
public enum HintCancellationReason: String, Codable, CaseIterable, Hashable, Sendable {
    case escape
    case repeatedActivation
    case toolDisabled
    case appTerminated
    case accessibilityRevoked
    case secureInput
    case targetContextMismatch
    case displayTopologyChange
    case captureLost
    case timeout
    case wake
    case staleInvocation
    case scrollFailed
}

/// The event vocabulary. All async outcomes carry the `HintSessionKey` they belong to.
public enum HintEvent: Equatable, Sendable {
    /// Global activation. From idle: starts a session; from any active state: cancels it
    /// (the repeated-activation shortcut).
    case activateRequested(HintTargetContext)
    case scanCompleted(HintSessionKey, HintScanResult)
    case scanFailed(HintSessionKey, HintCancellationReason)
    case key(HintKeyCommand)
    case invocationFinished(HintSessionKey, HintInvocationOutcome)
    /// Landing of one semantic scroll dispatched in scroll mode.
    case scrollFinished(HintSessionKey, HintMutationOutcome)
    /// Unconditional cancellation from any active state, for every
    /// `HintCancellationReason`: disable/stop, termination, permission loss, Secure Input,
    /// target mismatch, display changes, capture loss, timeout, wake, stale invocation,
    /// failed scroll.
    case cancel(HintCancellationReason)
}

/// Pure effects. The session controller executes them; the reducer performs no OS work.
public enum HintEffect: Equatable, Sendable {
    /// Begin a bounded scan under this key/generation.
    case startScan(HintScanPlan)
    case showOverlays(HintSessionKey, HintPresentationSnapshot)
    case refreshOverlays(HintSessionKey, HintPresentationSnapshot)
    /// Begin the modifier-release barrier; modal input is not accepted until `beginInput`.
    case awaitModifierRelease(HintSessionKey)
    case beginInput(HintSessionKey)
    /// Dispatch the advertised AX action at most once (revalidation is the adapter's job).
    case invoke(HintSessionKey, HintTargetToken, HintActionKind)
    /// Semantic scroll of the selected region (scroll mode only, never while in flight).
    case scrollRegion(HintSessionKey, HintTargetToken, HintScrollCommand)
    case hideOverlays(HintSessionKey)
    /// Release the AX target records bound to one generation; the session's immutable roots
    /// (the captured participating roots backing the context) stay alive. Used for stale
    /// generation-bound payload cleanup and generation rollover. Idempotent.
    case releaseGeneration(HintSessionKey)
    /// Terminal teardown: release both the session's generation payload AND the session
    /// roots themselves. Used only when the whole session ends or is replaced; never during
    /// a rollover, since the new generation reuses the same roots. Idempotent.
    case releaseSession(HintSessionKey)
}

/// The session reducer: a pure value type with no timers, observers, retained context, or
/// OS side effects. One instance per tool lifecycle; feed events with `send(_:)`, which
/// returns the ordered effects to execute and updates `state`.
public struct HintSessionReducer: Sendable {

    public private(set) var state: HintSessionState = .idle
    public private(set) var lastSessionID: UInt64 = 0
    public let limits: HintScanLimits
    public let labelMaker: HintLabelMaker

    public init(limits: HintScanLimits = .standard, alphabet: String = HintLabelMaker.defaultAlphabet) {
        // HintScanLimits clamps every field on construction; nothing to re-sanitize here.
        self.limits = limits
        self.labelMaker = HintLabelMaker.lenient(alphabet: alphabet)
    }

    /// Feed one event; returns ordered effects. Stale keys (a different generation than the
    /// active state) produce the idempotent release-teardown for the stale payload and no
    /// other effects; a duplicate event for the live key releases nothing.
    public mutating func send(_ event: HintEvent) -> [HintEffect] {
        switch event {
        case .activateRequested(let context):
            return sendActivate(context)
        case .scanCompleted(let key, let result):
            return sendScanCompleted(key, result)
        case .scanFailed(let key, let reason):
            return sendScanFailed(key, reason)
        case .key(let command):
            return sendKey(command)
        case .invocationFinished(let key, let outcome):
            return sendInvocationFinished(key, outcome)
        case .scrollFinished(let key, let outcome):
            return sendScrollFinished(key, outcome)
        case .cancel(let reason):
            return sendCancel(reason)
        }
    }

    // MARK: Activation

    private mutating func sendActivate(_ context: HintTargetContext) -> [HintEffect] {
        if state.isActive {
            let key = state.key!
            state = .idle
            return [.hideOverlays(key), .releaseSession(key)]
        }
        return startNewSession(context: context)
    }

    private mutating func startNewSession(context: HintTargetContext) -> [HintEffect] {
        lastSessionID += 1
        let key = HintSessionKey(id: lastSessionID, generation: 0)
        let plan = HintScanPlan(key: key, context: context, limits: limits)
        state = .scanning(plan, resume: nil)
        return [.startScan(plan)]
    }

    /// Fresh observational rescan under the next generation of the same session. Never
    /// carries an invocation: unknown outcomes are not retried, ever. Releases the old
    /// generation's targets BEFORE the new scan starts, so target payloads never overlap.
    /// `resume` re-enters the given mode/query after the scan completes.
    private mutating func rescan(resume: HintResume?) -> [HintEffect] {
        let previousKey = state.key!
        let context = self.context(ofState: state)
        let plan = HintScanPlan(
            key: previousKey.nextGeneration,
            context: context,
            limits: limits
        )
        state = .scanning(plan, resume: resume)
        return [.releaseGeneration(previousKey), .startScan(plan)]
    }

    private func context(ofState state: HintSessionState) -> HintTargetContext {
        switch state {
        case .idle: return HintTargetContext(pid: 0, screens: [])
        case .scanning(let plan, _): return plan.context
        case .presenting(let presenting): return presenting.context
        case .invoking(let invoking): return invoking.context
        case .scrolling(let scrolling): return scrolling.context
        }
    }

    // MARK: Scan results

    private mutating func sendScanCompleted(_ key: HintSessionKey, _ result: HintScanResult) -> [HintEffect] {
        guard case .scanning(let plan, let resume) = state else {
            return staleKeyEffects(key)
        }
        guard plan.key == key else {
            return staleKeyEffects(key)
        }
        let context = plan.context
        let prepared = prepareLabelled(result: result, context: context)
        if prepared.labelled.isEmpty {
            state = .idle
            return [.hideOverlays(key), .releaseSession(key)]
        }
        var mode = HintKeyboardMode.labels
        var query = ""
        var selectedContinuity: HintContinuityID?
        if let resume = resume {
            mode = resume.mode
            query = resume.query
            selectedContinuity = resume.selectedContinuity
        }
        var presenting = HintPresentingState(
            key: key,
            context: context,
            candidates: prepared.labelled,
            mode: mode,
            query: query,
            selectedIndex: nil,
            awaitingModifierRelease: resume == nil,
            summary: prepared.summary
        )
        if mode == .scroll {
            presentingRestoreSelection(&presenting, selectedContinuity: selectedContinuity)
        }
        state = .presenting(presenting)
        var effects: [HintEffect] = [.showOverlays(key, snapshot(presenting))]
        if resume == nil {
            effects.append(.awaitModifierRelease(key))
        }
        return effects
    }

    /// Re-resolve a resumed selection by its adapter-proven continuity identity only, and
    /// only when the continuity candidate is ALSO the current exact full-label selection
    /// for the resumed query in the new generation. There is no fallback: absent identity,
    /// a mismatch, a changed label, or a re-badged target token with different continuity
    /// all leave the selection empty.
    private mutating func presentingRestoreSelection(_ presenting: inout HintPresentingState, selectedContinuity: HintContinuityID?) {
        guard let continuity = selectedContinuity else { return }
        // The selection pool matches the restored mode: scroll pool in scroll mode, the
        // normal-control pool otherwise.
        let pool = presenting.mode == .scroll
            ? presenting.candidates.filter { $0.candidate.role == .scrollRegion }
            : presenting.candidates.filter { $0.candidate.role != .scrollRegion }
        guard let matchLabelIndex = pool.firstIndex(where: { $0.candidate.continuity == continuity }),
              let matchIndex = presenting.candidates.firstIndex(
                  where: { $0.index == pool[matchLabelIndex].index })
        else { return }
        // The label must STILL be the exact full-label match of the resumed query in this
        // generation's pool; if labels changed (or the match is ambiguous) nothing binds.
        let labels = pool.map(\.label)
        guard HintFilter.fullLabelSelection(labels: labels, query: presenting.query) == matchLabelIndex else {
            presenting.selectedIndex = nil
            return
        }
        presenting.selectedIndex = matchIndex
    }

    private mutating func sendScanFailed(_ key: HintSessionKey, _ reason: HintCancellationReason) -> [HintEffect] {
        guard case .scanning(let plan, _) = state, plan.key == key else {
            return staleKeyEffects(key)
        }
        return sendCancel(reason)
    }

    struct PreparedLabelled: Equatable {
        var labelled: [HintLabelledCandidate]
        var summary: HintScanSummary
    }

    /// Frozen preparation order: eligibility → ancestry dedupe → rank → candidate cap →
    /// label allocation. All accepted candidates (both ordinary controls and scroll regions)
    /// share this one labelled list; keyboard mode decides which slice is presented.
    /// Count-only truncation is folded into the summary; session content never leaks into
    /// `HintScanSummary`.
    private func prepareLabelled(
        result: HintScanResult,
        context: HintTargetContext
    ) -> PreparedLabelled {
        let preparation = HintEligibility.prepare(
            result.candidates,
            context: context,
            limits: limits
        )
        var summary = result.summary
        // acceptedCandidates = after eligibility AND ancestry dedupe, before any cap. The
        // AX adapter already counted its own PRE-CAP accepted set before the shared Core
        // preparation re-ran; the merge is a MAX, never an overwrite, so an adapter count
        // above the re-prepared value survives (and vice versa).
        summary.acceptedCandidates = max(summary.acceptedCandidates, preparation.acceptedCandidates)
        // The count contract guarantees discovered count is never under-reported: the
        // received payload is the floor even when the scanner summary omitted it.
        summary.discoveredCandidates = max(summary.discoveredCandidates, result.candidates.count)
        if preparation.candidateCapReached {
            summary.truncationReasons.insert(.candidateCapReached)
        }
        let allocation = (try? labelMaker.allocate(candidateCount: preparation.ranked.count))
            ?? HintLabelMaker.Allocation(labels: [], overflowed: preparation.ranked.count)
        if allocation.overflowed > 0 {
            summary.truncationReasons.insert(.labelCapacityReached)
        }
        var labelled: [HintLabelledCandidate] = []
        labelled.reserveCapacity(allocation.labels.count)
        for (index, rankedCandidate) in preparation.ranked.enumerated() where index < allocation.labels.count {
            labelled.append(HintLabelledCandidate(
                index: index,
                candidate: rankedCandidate.candidate,
                label: allocation.labels[index],
                action: rankedCandidate.action
            ))
        }
        summary.retainedCandidates = labelled.count
        return PreparedLabelled(labelled: labelled, summary: summary)
    }

    // MARK: Key input

    private mutating func sendKey(_ command: HintKeyCommand) -> [HintEffect] {
        guard case .presenting(let presenting) = state else {
            if case .scrolling = state {
                // In-flight scroll: further key input is dropped; Escape still cancels.
                if command == .escape { return sendCancel(.escape) }
            }
            return []
        }
        if command == .modifierBarrierReleased {
            guard presenting.awaitingModifierRelease else { return [] }
            var updated = presenting
            updated.awaitingModifierRelease = false
            state = .presenting(updated)
            return [.beginInput(updated.key)]
        }
        // While the modifier barrier holds, everything except Escape is dropped.
        if presenting.awaitingModifierRelease {
            return command == .escape ? sendCancel(.escape) : []
        }
        var updated = presenting
        switch presenting.mode {
        case .labels: return reduceLabelsMode(&updated, command)
        case .search: return reduceSearchMode(&updated, command)
        case .scroll: return reduceScrollMode(&updated, command)
        }
    }

    // MARK: Labels mode

    private mutating func reduceLabelsMode(_ presenting: inout HintPresentingState, _ command: HintKeyCommand) -> [HintEffect] {
        switch command {
        case .character(let character):
            guard labelMaker.normalizedAlphabet.contains(Character(character.lowercased())) else {
                return []
            }
            presenting.query.append(Character(character.lowercased()))
            return applyLabelQuery(&presenting)
        case .backspace:
            guard !presenting.query.isEmpty else { return [] }
            presenting.query.removeLast()
            return applyLabelQuery(&presenting)
        case .return:
            guard let selected = presenting.selectedIndex,
                  presenting.candidates.indices.contains(selected),
                  presenting.candidates[selected].candidate.role != .scrollRegion else {
                return [] // Nothing bound (empty query, no match) or a scroll region: inert.
            }
            return beginInvocation(presenting, index: selected)
        case .slash:
            presenting.mode = .search
            presenting.query = ""
            presenting.selectedIndex = nil
            state = .presenting(presenting)
            return [.refreshOverlays(presenting.key, snapshot(presenting))]
        case .space:
            presenting.mode = .scroll
            presenting.query = ""
            presenting.selectedIndex = nil
            state = .presenting(presenting)
            return [.refreshOverlays(presenting.key, snapshot(presenting))]
        case .escape:
            return sendCancel(.escape)
        case .scroll, .modifierBarrierReleased:
            return []
        }
    }

    private mutating func applyLabelQuery(_ presenting: inout HintPresentingState) -> [HintEffect] {
        // Selection is resolved over the label-mode pool (scroll regions excluded) so the
        // selection is always exactly the Return target.
        let normalIndices = presenting.candidates.enumerated().compactMap {
            $0.element.candidate.role == .scrollRegion ? nil : $0.offset
        }
        let normalLabels = normalIndices.map { presenting.candidates[$0].label }
        if let selected = HintFilter.fullLabelSelection(labels: normalLabels, query: presenting.query) {
            presenting.selectedIndex = normalIndices[selected]
        } else {
            presenting.selectedIndex = nil
        }
        state = .presenting(presenting)
        return [.refreshOverlays(presenting.key, snapshot(presenting))]
    }

    // MARK: Search mode

    private mutating func reduceSearchMode(_ presenting: inout HintPresentingState, _ command: HintKeyCommand) -> [HintEffect] {
        switch command {
        case .character(let character):
            presenting.query.append(character)
            return refreshSearch(&presenting)
        case .slash:
            // Inside search the slash is literal committed text.
            presenting.query.append("/")
            return refreshSearch(&presenting)
        case .space:
            presenting.query.append(" ")
            return refreshSearch(&presenting)
        case .backspace:
            if presenting.query.isEmpty {
                // Backspace on an empty search query: no trimming (removeLast would trap),
                // deterministic exit to label mode with an empty query and no selection.
                presenting.mode = .labels
                presenting.selectedIndex = nil
                state = .presenting(presenting)
                return [.refreshOverlays(presenting.key, snapshot(presenting))]
            }
            presenting.query.removeLast()
            if presenting.query.isEmpty {
                // Removing the final character exits to label mode without running search
                // selection logic against the empty query.
                presenting.mode = .labels
                presenting.selectedIndex = nil
                state = .presenting(presenting)
                return [.refreshOverlays(presenting.key, snapshot(presenting))]
            }
            return refreshSearch(&presenting)
        case .return:
            guard let selected = presenting.selectedIndex,
                  presenting.candidates.indices.contains(selected) else {
                return [] // Empty query or no result: Return is inert; no sole-result invoke.
            }
            guard presenting.candidates[selected].candidate.role != .scrollRegion else { return [] }
            return beginInvocation(presenting, index: selected)
        case .escape:
            return sendCancel(.escape)
        case .scroll, .modifierBarrierReleased:
            return []
        }
    }

    /// Deterministic search ordering over the labelled candidate list, excluding scroll
    /// regions from the search pool. The first visible result becomes the selection, so the
    /// snapshot's selection always equals the Return target.
    private mutating func refreshSearch(_ presenting: inout HintPresentingState) -> [HintEffect] {
        let searchPool = presenting.candidates.filter { $0.candidate.role != .scrollRegion }
        let indices = HintSearch.orderedIndices(candidates: searchPool.map(\.candidate), query: presenting.query)
        let visible = indices.map { searchPool[$0] }
        presenting.selectedIndex = visible.first?.index
        state = .presenting(presenting)
        return [.refreshOverlays(presenting.key, snapshot(presenting))]
    }

    // MARK: Scroll mode

    private mutating func reduceScrollMode(_ presenting: inout HintPresentingState, _ command: HintKeyCommand) -> [HintEffect] {
        // The label query selects among scroll regions inside scroll mode.
        switch command {
        case .character(let character):
            guard labelMaker.normalizedAlphabet.contains(Character(character.lowercased())) else {
                return []
            }
            presenting.query.append(Character(character.lowercased()))
            return applyScrollQuery(&presenting)
        case .backspace:
            guard !presenting.query.isEmpty else {
                presenting.mode = .labels
                presenting.selectedIndex = nil
                state = .presenting(presenting)
                return [.refreshOverlays(presenting.key, snapshot(presenting))]
            }
            presenting.query.removeLast()
            return applyScrollQuery(&presenting)
        case .scroll(let scrollCommand):
            guard let selected = presenting.selectedIndex,
                  presenting.candidates.indices.contains(selected),
                  presenting.candidates[selected].candidate.role == .scrollRegion else {
                return []
            }
            // An additional command while one scroll is in flight is ignored: `.scrolling`
            // serializes region mutations, and in-flight commands are dropped (never queued).
            let token = presenting.candidates[selected].candidate.token
            let scrolling = HintScrollingState(
                key: presenting.key,
                context: presenting.context,
                candidates: presenting.candidates,
                query: presenting.query,
                selectedIndex: presenting.selectedIndex,
                summary: presenting.summary
            )
            state = .scrolling(scrolling)
            return [.scrollRegion(presenting.key, token, scrollCommand)]
        case .space:
            // Space exits scroll mode to labels: clear the scroll-pool query and selection
            // so the label pool is presented unfiltered with nothing bound.
            presenting.mode = .labels
            presenting.query = ""
            presenting.selectedIndex = nil
            state = .presenting(presenting)
            return [.refreshOverlays(presenting.key, snapshot(presenting))]
        case .escape:
            return sendCancel(.escape)
        case .return, .slash, .modifierBarrierReleased:
            return []
        }
    }

    private mutating func applyScrollQuery(_ presenting: inout HintPresentingState) -> [HintEffect] {
        let regionIndices = presenting.candidates.enumerated().compactMap {
            $0.element.candidate.role == .scrollRegion ? $0.offset : nil
        }
        let regionLabels = regionIndices.map { presenting.candidates[$0].label }
        presenting.selectedIndex = HintFilter.fullLabelSelection(labels: regionLabels, query: presenting.query)
            .map { regionIndices[$0] }
        state = .presenting(presenting)
        return [.refreshOverlays(presenting.key, snapshot(presenting))]
    }

    // MARK: Scroll completion

    private mutating func sendScrollFinished(_ key: HintSessionKey, _ outcome: HintMutationOutcome) -> [HintEffect] {
        guard case .scrolling(let scrolling) = state, scrolling.key == key else {
            return staleKeyEffects(key)
        }
        switch outcome {
        case .failed:
            // A failed scroll cancels the session: hide and release in one fail-closed path.
            return sendCancel(.scrollFailed)
        case .applied, .unknownOutcome:
            // Visibility may have changed: release the old generation's targets BEFORE the
            // observational rescan, then re-enter scroll mode. The selection is restored in
            // the new generation ONLY by its adapter-proven continuity identity (target
            // tokens are generation-bound and never a restoration key).
            let resumeContinuity = scrolling.selectedIndex.flatMap {
                scrolling.candidates.indices.contains($0)
                    ? scrolling.candidates[$0].candidate.continuity
                    : nil
            }
            let resume = HintResume(mode: .scroll, query: scrolling.query, selectedContinuity: resumeContinuity)
            state = .presenting(HintPresentingState(
                key: scrolling.key,
                context: scrolling.context,
                candidates: scrolling.candidates,
                mode: .scroll,
                query: scrolling.query,
                selectedIndex: scrolling.selectedIndex,
                awaitingModifierRelease: false,
                summary: scrolling.summary
            ))
            return rescan(resume: resume)
        }
    }

    // MARK: Invocation

    private mutating func beginInvocation(_ presenting: HintPresentingState, index: Int) -> [HintEffect] {
        let candidate = presenting.candidates[index]
        let key = presenting.key
        let invocation = HintInvocationState(
            key: key,
            context: presenting.context,
            token: candidate.candidate.token,
            action: candidate.action
        )
        state = .invoking(invocation)
        return [.hideOverlays(key), .invoke(key, candidate.candidate.token, candidate.action)]
    }

    private mutating func sendInvocationFinished(_ key: HintSessionKey, _ outcome: HintInvocationOutcome) -> [HintEffect] {
        guard case .invoking(let invocation) = state, invocation.key == key else {
            return staleKeyEffects(key)
        }
        switch outcome {
        case .succeeded:
            state = .idle
            return [.releaseSession(key)]
        case .succeededNeedsRescan, .unknownOutcome:
            // Unknown outcomes are NEVER retried; only a fresh observational rescan follows.
            // Overlays were already hidden by beginInvocation.
            return rescan(resume: nil)
        case .failed:
            state = .idle
            return [.releaseSession(key)]
        }
    }

    // MARK: Cancellation

    private mutating func sendCancel(_ reason: HintCancellationReason) -> [HintEffect] {
        guard let key = state.key else { return [] }
        _ = reason
        state = .idle
        return [.hideOverlays(key), .releaseSession(key)]
    }

    /// A keyed event that references a payload the live session does not own (a different,
    /// stale generation, or any key after session end): clean up that payload idempotently
    /// without touching the live session. A duplicate event carrying the LIVE key produces
    /// no effects here — callers already returned `[]` for well-formed duplicates.
    private func staleKeyEffects(_ staleKey: HintSessionKey) -> [HintEffect] {
        if let live = state.key, staleKey == live {
            // A duplicate event for the live key handled later in a specific phase falls
            // back to a no-op rather than releasing the live payload.
            return []
        }
        return [.releaseGeneration(staleKey)]
    }

    // MARK: Snapshot

    /// Deterministic presentation snapshot for a presenting state (public for adapters and
    /// for tests that need to inspect the overlay payloads the reducer produced).
    public func snapshot(_ presenting: HintPresentingState) -> HintPresentationSnapshot {
        let visible: [HintLabelledCandidate]
        var selectedToken: HintTargetToken?
        var selectedLabel: String?
        let liveSelection: Int? = presenting.selectedIndex.flatMap {
            presenting.candidates.indices.contains($0) ? $0 : nil
        }
        switch presenting.mode {
        case .labels:
            // Label mode shows only non-scroll candidates, in query-filtered order.
            let normal = presenting.candidates.filter { $0.candidate.role != .scrollRegion }
            let visibleIndices = HintFilter.visibleIndices(labels: normal.map(\.label), query: presenting.query)
            visible = visibleIndices.map { normal[$0] }
        case .search:
            // The search pool excludes scroll regions even when the query is empty (no
            // selection; Return is inert).
            let searchPool = presenting.candidates.filter { $0.candidate.role != .scrollRegion }
            let indices = HintSearch.orderedIndices(candidates: searchPool.map(\.candidate), query: presenting.query)
            visible = indices.map { searchPool[$0] }
        case .scroll:
            // Scroll mode narrows to its region pool and prefix-filters by the current
            // label query — exactly the treatment labels mode gives its own pool.
            let regions = presenting.candidates.filter { $0.candidate.role == .scrollRegion }
            let visibleIndices = HintFilter.visibleIndices(labels: regions.map(\.label), query: presenting.query)
            visible = visibleIndices.map { regions[$0] }
        }
        if let selected = liveSelection {
            selectedToken = presenting.candidates[selected].candidate.token
            selectedLabel = presenting.candidates[selected].label
        }
        return HintPresentationSnapshot(
            key: presenting.key,
            mode: presenting.mode,
            query: presenting.query,
            visible: visible,
            selectedToken: selectedToken,
            selectedLabel: selectedLabel,
            truncated: presenting.summary.isTruncated,
            truncationReasons: presenting.summary.truncationReasons,
            totalCandidates: presenting.candidates.count
        )
    }
}

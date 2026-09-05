import AppKit
import Carbon.HIToolbox
import HintsCore

/// Callbacks from the Input adapter. Presentation (or a capture-matrix recorder in Phase 5)
/// implements this to receive semantic commands and fail-closed cancellation outcomes.
///
/// Typed text and queries are never included in any callback payload and are never logged.
@MainActor
protocol HintInputControllerDelegate: AnyObject {
    /// A translated semantic event, only delivered while capture is active and the modifier
    /// barrier has been released.
    func hintInput(_ controller: HintInputController, didReceiveCommand command: HintKeyCommand)
    /// One fail-closed cancellation per adapter lifetime. Every reason that ends capture
    /// originates here; the receiver disposes panel/input state for the session.
    func hintInput(_ controller: HintInputController, didCancelWithReason reason: HintCancellationReason)
}

/// Frozen panel-only modal input adapter (Phase 2C). Translates responder callbacks and
/// committed text from an `NSTextView`-based responder view into `HintKeyCommand` events for
/// the HintsCore session reducer.
///
/// Ownership boundaries:
/// - Presentation owns the `NSPanel`, ordering, key-window status, and display placement. This
///   controller exposes the invisible responder view (`responderView`), and Presentation
///   reports capture confirmation or loss back via `captureConfirmed(window:)` /
///   `captureLost()`.
/// - Input owns the activation-modifier release barrier, Secure Input checks, translation, and
///   fail-closed cancellation.
///
/// Prohibited paths this lane must never take (verified by source scan): modal Carbon
/// registration (`RegisterEventHotKey`, `BeginModalEventSession`), `CGEventTap` creation,
/// Input Monitoring permission requests, global/local `NSEvent` monitors, event posting
/// (`CGEvent.post`), and timers/polling. Carbon is imported only for Secure Input checking;
/// modifier state goes through `NSEvent.ModifierFlags`.
@MainActor
final class HintInputController {

    // MARK: Phase 5 injection seams

    /// Secure Event Input state provider, injectable for capture-matrix checks.
    let secureInputProvider: () -> Bool
    /// Current physical modifier flags provider, injectable for capture-matrix checks.
    let modifierFlagsProvider: () -> NSEvent.ModifierFlags

    weak var delegate: HintInputControllerDelegate?

    // MARK: State

    /// Modifier-release barrier progression. While `waiting`, modal characters/special keys are
    /// dropped; the transition to `released` emits `.modifierBarrierReleased` exactly once.
    private enum BarrierState { case inactive, waiting, released }

    private var barrierState: BarrierState = .inactive
    private var barrierModifierMask: NSEvent.ModifierFlags = []
    private var inputBegun = false
    private var captureActive = false
    /// Set by `relinquishExpectedCapture()` and reset on the next `captureConfirmed(window:)`.
    /// While set, all input callbacks are dropped silently — the expected-hide path must never
    /// be mistaken for capture loss and must never emit a cancellation.
    private var captureRelinquished = false
    private var finished = false
    private weak var window: NSWindow?

    /// Presentation seam: install this responder view into the key-capable panel, then confirm
    /// capture with `captureConfirmed(window:)`. Input never creates, orders, or keys the
    /// panel itself.
    let responderView: HintInputResponderView

    // MARK: Initialization

    init(
        secureInputProvider: @escaping () -> Bool = { IsSecureEventInputEnabled() },
        modifierFlagsProvider: @escaping () -> NSEvent.ModifierFlags = { NSEvent.modifierFlags }
    ) {
        self.secureInputProvider = secureInputProvider
        self.modifierFlagsProvider = modifierFlagsProvider
        let view = HintInputResponderView()
        view.eventSink = self
        view.delegate = self
        self.responderView = view
    }

    // MARK: Capture seam (Presentation → Input)
    //
    // Ownership: Presentation is the SOLE owner/observer of the NSPanel key-window lifecycle
    // (HintOverlayController observes didResignKey). This controller installs no NSWindow
    // notification observers; unexpected loss arrives as `captureLost()` from the Phase 3
    // session controller via Presentation's `onCaptureLost` seam.

    /// Presentation reports that its panel is key and our responder view is first responder.
    /// Required conditions, fail-closed otherwise: Secure Input off, the responder installed in
    /// this exact window, panel visible and actually key, and first-responder status. This
    /// method only VERIFIES those conditions — it never observes the window afterwards.
    func captureConfirmed(window: NSWindow) {
        guard !finished else { return }
        if secureInputProvider() {
            cancel(reason: .secureInput)
            return
        }
        // Capture is only confirmed for the exact window the Presentation lane installed our
        // responder into; a mismatch is panel/capture uncertainty and fails closed.
        guard responderView.window === window else {
            cancel(reason: .captureLost)
            return
        }
        guard window.windowNumber != -1 else {
            cancel(reason: .captureLost)
            return
        }
        // Key status is checked explicitly: a present but non-key panel cannot receive
        // keyboard input, so confirming capture would leave a silent dead window.
        guard window.isVisible, window.isKeyWindow else {
            cancel(reason: .captureLost)
            return
        }
        self.window = window
        // First-responder status is verified BEFORE capture becomes active, so an inability to
        // become first responder never coexists with an active capture.
        ensureFirstResponderOrCancel()
        guard !finished else { return }
        captureActive = true
        captureRelinquished = false
        // An already-released physical chord need not wait for a keystroke: evaluate the
        // pending barrier now that capture exists.
        if barrierState == .waiting {
            evaluateBarrier()
        }
    }

    /// Presentation reports capture loss (panel demoted from key, closed, or display removal).
    /// This is only called by Presentation's verified-loss seam, once per capture; Input itself
    /// performs no NSWindow observation, so it cannot double-report.
    func captureLost() {
        cancel(reason: .captureLost)
    }

    // MARK: Expected capture relinquishment (silent, idempotent)

    /// Effect ordering contract (Phase 3): Input relinquishes expected capture FIRST, then
    /// Presentation hides (`hide(generation:)` → `removeInputResponder()`), then AX invokes.
    ///
    /// Synchronously stops accepting semantic input for the current capture and clears
    /// capture/window/barrier/input state WITHOUT any delegate cancellation callback: the
    /// caller is not an uncertainty path, so nothing fails closed here. The responder view and
    /// the event sink/delegate stay attached — only terminal `stop()`/`cancel(reason:)` own
    /// that teardown — so any input AppKit still delivers before Presentation's
    /// `removeInputResponder()` lands is dropped silently by the acceptance gate.
    ///
    /// Lifecycle/reusability contract: the controller is REUSED across captures of the rescan
    /// flow; each new capture re-runs `awaitModifierRelease`/`beginInput`/`captureConfirmed`
    /// on a fully reset capture/barrier/input state. No per-capture cleanup beyond this.
    func relinquishExpectedCapture() {
        guard !finished else { return }
        captureActive = false
        captureRelinquished = true
        inputBegun = false
        barrierState = .inactive
        barrierModifierMask = []
        window = nil
    }

    // MARK: Phase 3 seam (reducer-effect landing)

    /// Reducer `awaitModifierRelease` landed: install the assigned activation modifier mask.
    /// Must precede `beginInput()`; semantic input is not accepted while these modifiers are
    /// down.
    func awaitModifierRelease(modifierMask: NSEvent.ModifierFlags) {
        guard !finished else { return }
        barrierModifierMask = modifierMask
        barrierState = .waiting
        // If capture is already confirmed and the physical modifiers are already up, the
        // barrier is trivially satisfied and is emitted exactly once right now — no polling,
        // only the current flag snapshot. Otherwise `captureConfirmed(window:)` evaluates it.
        evaluateBarrier()
    }

    /// Reducer `beginInput` landed: semantic commands may now be accepted, still gated on the
    /// modifier barrier, capture, and Secure Input.
    func beginInput() {
        guard !finished else { return }
        inputBegun = true
        evaluateBarrier()
    }

    // MARK: Stop / cancellation (idempotent)

    /// Explicit tool stop. Supersedes any other cancellation trigger: at most one delegate
    /// callback is ever delivered per adapter lifetime, and later `stop()`/`cancel` calls are
    /// no-ops.
    func stop() {
        guard !finished else { return }
        finished = true
        teardown()
        delegate?.hintInput(self, didCancelWithReason: .toolDisabled)
    }

    /// Fail-closed cancellation from any trigger: capture failure or loss, Secure Input,
    /// unexpected resign/key-window loss. Idempotent by construction.
    func cancel(reason: HintCancellationReason) {
        guard !finished else { return }
        finished = true
        teardown()
        delegate?.hintInput(self, didCancelWithReason: reason)
    }

    private func teardown() {
        window = nil
        responderView.eventSink = nil
        responderView.delegate = nil
    }

    /// Our responder must be first responder inside the key window; inability to become it
    /// fails closed. Runs on capture confirmation only — re-keying is Presentation's
    /// observation domain.
    private func ensureFirstResponderOrCancel() {
        guard !finished else { return }
        guard let window else {
            cancel(reason: .captureLost)
            return
        }
        if responderView === window.firstResponder { return }
        let became = window.makeFirstResponder(responderView)
        guard became, responderView === window.firstResponder else {
            cancel(reason: .captureLost)
            return
        }
    }

    // MARK: Modifier-release barrier

    private func activationModifiersStillDown() -> Bool {
        !modifierFlagsProvider().intersection(barrierModifierMask).isEmpty
    }

    /// Advances the waiting barrier to released when the physical activation modifiers are all
    /// up. Invariants: nothing is emitted before capture is confirmed, Secure Input is checked
    /// just before emitting, and `.modifierBarrierReleased` is emitted exactly once.
    private func evaluateBarrier() {
        guard !finished else { return }
        // The barrier event is only meaningful for a live capture; emitting earlier would let
        // the reducer accept input before any panel exists.
        guard captureActive else { return }
        guard barrierState == .waiting else { return }
        // Fail closed: a Secure Input flip between capture confirmation and barrier release
        // must cancel, never hand the modal session input while system interception is on.
        if secureInputProvider() {
            cancel(reason: .secureInput)
            return
        }
        guard !activationModifiersStillDown() else { return }
        barrierState = .released
        delegate?.hintInput(self, didReceiveCommand: .modifierBarrierReleased)
    }

    // MARK: Input gate

    /// Single acceptance gate for every translated event: capture, Secure Input, then the
    /// modifier-release barrier. Fails closed on the first two; drops silently while the
    /// activation modifiers remain down.
    private func accept(_ command: HintKeyCommand) {
        if finished { return }
        if !captureActive {
            if captureRelinquished {
                // Expected silent relinquishment (pre-hide): drop input without any
                // cancellation — this is a planned transition, not capture loss.
                return
            }
            cancel(reason: .captureLost)
            return
        }
        if secureInputProvider() {
            cancel(reason: .secureInput)
            return
        }
        if barrierState == .waiting {
            if activationModifiersStillDown() {
                // Modal characters/special keys are dropped while activation modifiers remain
                // held: no command leaves for a chord.
                return
            }
            // Release observed: run the shared barrier transition so this same committed
            // input can become the first post-barrier keystroke (exactly-once emit inside).
            evaluateBarrier()
        }
        // Semantic input is accepted ONLY with a released barrier. An inactive barrier means
        // the lifecycle is misordered (no awaitModifierRelease landed/began first): drop the
        // event instead of accepting after beginInput().
        guard finished == false, barrierState == .released else { return }
        guard inputBegun else { return }
        delegate?.hintInput(self, didReceiveCommand: command)
    }
}

// MARK: - HintInputEventSink (responder view → controller)

extension HintInputController: HintInputEventSink {

    func responderViewDidReceiveCommittedText(_ text: String) {
        guard !text.isEmpty else { return }
        // Committed text is translated one character at a time; it is never stored, echoed,
        // or logged anywhere. Unsupported control characters are dropped, never guessed.
        for character in text {
            guard let command = Self.command(for: character) else { continue }
            accept(command)
            if finished { return }
        }
    }

    func responderViewDidObserveModifierChange(currentFlags: NSEvent.ModifierFlags) {
        // `flagsChanged` arrives through responder-chain routing while our view is first
        // responder — not a global/local event monitor, no polling behind it.
        guard !finished, captureActive else { return }
        guard barrierState == .waiting else { return }
        let eventFlagsSayDown = !currentFlags.intersection(barrierModifierMask).isEmpty
        guard eventFlagsSayDown else {
            evaluateBarrier()
            return
        }
        // The event snapshot says modifiers are still down. If the live provider disagrees
        // (stale event), wait for the next callback rather than racing a release emit.
        if !activationModifiersStillDown() {
            evaluateBarrier()
        }
    }
}

// MARK: - NSTextViewDelegate (doCommandBy translation)

extension HintInputController: NSTextViewDelegate {

    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        // Every selector is swallowed: the modal session must not leak editor behavior, and
        // unmapped keys are dropped instead of falling through to anything else.
        guard let command = Self.command(for: commandSelector) else { return true }
        accept(command)
        return true
    }
}

// MARK: - Translation tables

extension HintInputController {

    /// Committed-character translation per the frozen keyboard map: `/` and Space are
    /// semantic keys; other printable characters are label/search inputs.
    static func command(for character: Character) -> HintKeyCommand? {
        switch character {
        case "/": return .slash
        case " ": return .space
        case "\n", "\r", "\u{2028}": return .return
        case "\u{7F}", "\u{08}": return .backspace
        default:
            if character.isNewline { return nil }
            if let scalar = character.unicodeScalars.first, scalar.value < 0x20 { return nil }
            return .character(character)
        }
    }

    /// Editor-command translation for responder-callback special keys: Escape, Backspace,
    /// Return, arrows, Page Up/Down, Home, and End, including the alternate selector variants
    /// macOS can emit for those keys.
    static func command(for selector: Selector) -> HintKeyCommand? {
        let scroll: (HintScrollCommand) -> HintKeyCommand = { .scroll($0) }
        let table: [String: HintKeyCommand] = [
            "cancelOperation:": .escape,
            "cancelOperation:reply:": .escape,
            "deleteBackward:": .backspace,
            "deleteBackwardByDecimatingCharacter:": .backspace,
            "insertNewline:": .return,
            "insertNewlineIgnoringFieldEditor:": .return,
            "moveUp:": scroll(.up),
            "moveDown:": scroll(.down),
            "moveLeft:": scroll(.left),
            "moveRight:": scroll(.right),
            "moveUpAlternative:": scroll(.up),
            "moveDownAlternative:": scroll(.down),
            "moveLeftAlternative:": scroll(.left),
            "moveRightAlternative:": scroll(.right),
            "pageUp:": scroll(.pageUp),
            "pageDown:": scroll(.pageDown),
            "movePageUp:": scroll(.pageUp),
            "movePageDown:": scroll(.pageDown),
            "moveToBeginningOfDocument:": scroll(.home),
            "moveToEndOfDocument:": scroll(.end),
            "moveToBeginningOfLine:": scroll(.home),
            "moveToEndOfLine:": scroll(.end),
        ]
        return table[NSStringFromSelector(selector)]
    }
}


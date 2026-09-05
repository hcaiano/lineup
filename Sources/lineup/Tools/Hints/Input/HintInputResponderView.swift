import AppKit
import HintsCore

/// Panel-installable invisible text responder. An `NSTextView` subclass so native text input
/// (key events, IME composition, marked text) behaves exactly as macOS intends. The view draws
/// nothing, never retains typed text, and contains no session logic: every callback forwards to
/// `HintInputEventSink` (the controller), which owns Secure Input checks, the modifier-release
/// barrier, and fail-closed cancellation.
///
/// Lifecycle rules:
/// - Input does NOT create, order, or key any `NSPanel`. Presentation installs this view into
///   its key-capable panel and hands the window back via
///   `HintInputController.captureConfirmed(window:)`.
/// - No event tap, no Carbon modal registration, no event monitor, no key-event posting, and no
///   timers live in or behind this view. Editing hooks (`didChangeText`,
///   `textView(_:doCommandBy:)`) are AppKit responder-callback plumbing only.
@MainActor
final class HintInputResponderView: NSTextView {

    /// Forwarding target (the controller). Weak to avoid a view/controller reference cycle.
    weak var eventSink: HintInputEventSink?

    init() {
        // Plain, invisible, non-scrolling text carrier. Presentation decides the panel's
        // position, size, ordering, and hit-test behavior; this view only owns text input.
        super.init(frame: .zero, textContainer: nil)
        setup()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("HintInputResponderView is created in code only")
    }

    private func setup() {
        drawsBackground = false
        backgroundColor = .clear
        textColor = .clear
        isRichText = false
        usesFontPanel = false
        usesRuler = false
        allowsUndo = false
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticTextReplacementEnabled = false
        isAutomaticSpellingCorrectionEnabled = false
        // Long-standing NSTextView properties available on the macOS 13 baseline.
        isGrammarCheckingEnabled = false
        isContinuousSpellCheckingEnabled = false
        smartInsertDeleteEnabled = false
        insertionPointColor = .clear
        isHorizontallyResizable = false
        isVerticallyResizable = false
    }

    // MARK: Responder identity

    override var acceptsFirstResponder: Bool { true }

    // MARK: Modifier routing

    /// Delivered via responder-chain routing while this view is first responder in the key
    /// window. This is not a global or local event monitor: AppKit dispatches `flagsChanged`
    /// to the responder chain of the key window.
    override func flagsChanged(with event: NSEvent) {
        super.flagsChanged(with: event)
        eventSink?.responderViewDidObserveModifierChange(currentFlags: event.modifierFlags)
    }

    // MARK: Committed-text translation

    /// AppKit calls `didChangeText()` after every edit, including IME composition updates and
    /// commits. Nothing is translated while marked (in-composition) text exists; on commit the
    /// full composed string is drained in one pass.
    override func didChangeText() {
        super.didChangeText()
        guard !hasMarkedText() else { return }
        let committed = string
        guard !committed.isEmpty else { return }
        // Drain immediately: typed text never accumulates in the view, the process, or logs.
        replaceCharacters(in: NSRange(location: 0, length: (committed as NSString).length), with: "")
        // The drain edit can re-enter `didChangeText`; the empty-string guard above stops it there.
        eventSink?.responderViewDidReceiveCommittedText(committed)
    }
}

/// Forwarding seam from the responder view to `HintInputController`. A protocol so Phase 5
/// capture-matrix checks can inject a recorder without another input owner.
@MainActor
protocol HintInputEventSink: AnyObject {
    /// Committed (post-IME) text arrived and was already removed from the view's storage.
    func responderViewDidReceiveCommittedText(_ text: String)
    /// A `flagsChanged` responder event arrived; `currentFlags` is that event's modifier state.
    func responderViewDidObserveModifierChange(currentFlags: NSEvent.ModifierFlags)
}

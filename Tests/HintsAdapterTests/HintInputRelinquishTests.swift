import AppKit
import XCTest
@testable import lineup
import HintsCore

// ============================================================================
// Input relinquishment contract, driven through the responder event-sink seam
// (no NSPanel, no key-window live state — the panel/full-window legs of the
// capture matrix require a real computed key window and belong to the signed
// Phase 5 capture-matrix work):
//
//   * `relinquishExpectedCapture()` (the expected-hide transition, ordered
//     BEFORE Presentation's hide) must make any input AppKit still delivers
//     drop SILENTLY: no semantic command, and crucially NO cancellation —
//     this is a planned transition, not capture loss.
//   * By contrast, without relinquishment an event with no active capture is
//     an uncertainty path and MUST cancel fail-closed with `.captureLost`.
//   * Relinquishment is not terminal: a subsequent `stop()` still delivers
//     exactly one `.toolDisabled` cancellation, and the barrier state resets.
// ============================================================================

@MainActor
final class HintInputRelinquishTests: XCTestCase {

    private final class DelegateRecorder: HintInputControllerDelegate {
        var commands: [HintKeyCommand] = []
        var cancellations: [HintCancellationReason] = []
        func hintInput(_ controller: HintInputController, didReceiveCommand command: HintKeyCommand) {
            commands.append(command)
        }
        func hintInput(_ controller: HintInputController, didCancelWithReason reason: HintCancellationReason) {
            cancellations.append(reason)
        }
    }

    private func makeController(
        secureInput: Bool = false,
        modifiersDown: Bool = false
    ) -> (HintInputController, DelegateRecorder) {
        let controller = HintInputController(
            secureInputProvider: { secureInput },
            modifierFlagsProvider: { modifiersDown ? [.command] : [] }
        )
        let recorder = DelegateRecorder()
        controller.delegate = recorder
        return (controller, recorder)
    }

    // MARK: Expected-hide relinquishment is silent and non-terminal

    func testRelinquishedCaptureDropsInputSilentlyWithoutCancellation() {
        let (controller, recorder) = makeController()
        controller.awaitModifierRelease(modifierMask: [])
        controller.beginInput()
        // The expected-hide order fires FIRST, before Presentation hides.
        controller.relinquishExpectedCapture()

        // Any input the AppKit modal machinery still delivers drops silently: committed
        // text, semantic selector events, and modifier observations.
        controller.responderViewDidReceiveCommittedText("a ")
        let swallow = controller.textView(controller.responderView, doCommandBy: NSSelectorFromString("moveUp:"))
        XCTAssertTrue(swallow, "selectors stay swallowed after relinquishment")
        controller.responderViewDidObserveModifierChange(currentFlags: [.command])
        XCTAssertTrue(recorder.commands.isEmpty, "no semantic command leaves after relinquishment")
        XCTAssertTrue(recorder.cancellations.isEmpty, "expected relinquishment must never emit a cancellation")

        // Relinquishment is not terminal: the adapter stays reusable for the rescan flow
        // (barrier reset, exactly-once cancellation budget preserved).
        controller.awaitModifierRelease(modifierMask: [])
        controller.beginInput()
        XCTAssertTrue(recorder.commands.isEmpty, "the barrier does NOT re-emit without a live capture")
        controller.stop()
        XCTAssertEqual(recorder.cancellations, [.toolDisabled], "exactly the terminal stop cancels")
        controller.stop()
        XCTAssertEqual(recorder.cancellations.count, 1, "stop() stays idempotent after relinquishment")
    }

    /// Contrast leg: WITHOUT relinquishment, input with no active capture is an
    /// uncertainty path and must cancel fail-closed (this is what the silent-drop gate
    /// diverges from).
    func testUnrelinquishedInputWithNoCaptureCancelsFailClosed() {
        let (controller, recorder) = makeController()
        controller.awaitModifierRelease(modifierMask: [])
        controller.beginInput()
        controller.responderViewDidReceiveCommittedText("a")
        XCTAssertTrue(recorder.commands.isEmpty, "an event before capture confirmed is never a command")
        XCTAssertEqual(recorder.cancellations, [.captureLost], "unexpected input without capture fails closed")
        controller.stop()
        XCTAssertEqual(recorder.cancellations.count, 1, "at most one cancellation per adapter lifetime")
    }
}

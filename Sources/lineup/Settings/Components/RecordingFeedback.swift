import SwiftUI

/// A short horizontal wobble, used when a recorder refuses a keystroke.
///
/// Both recorder controls used to answer a rejected key with `NSSound.beep()` and nothing else,
/// which says nothing at all to a user on a muted Mac — and nothing to a user watching the field
/// rather than listening. The beep stays; this pairs it with something visible.
private struct ShakeEffect: GeometryEffect {
    var travel: CGFloat = 5
    var shakes: CGFloat = 3
    var animatableData: CGFloat

    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(CGAffineTransform(
            translationX: travel * sin(animatableData * .pi * shakes), y: 0))
    }
}

extension View {
    /// Wobble whenever `count` changes. `count` is `ShortcutRecorder.rejectionCount`, which only
    /// ever moves for the field that is capturing, so exactly one control reacts.
    ///
    /// Skipped under Reduce Motion — the control still tints, and the beep still plays.
    func recordingRejectionShake(_ count: Int) -> some View {
        modifier(RecordingRejectionShake(count: count))
    }
}

private struct RecordingRejectionShake: ViewModifier {
    let count: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .modifier(ShakeEffect(animatableData: phase))
            .onChange(of: count) { _ in
                guard !reduceMotion else { return }
                phase = 0
                withAnimation(.linear(duration: 0.28)) { phase = 1 }
            }
    }
}

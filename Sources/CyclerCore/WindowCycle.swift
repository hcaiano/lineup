import Foundation

/// Pure cycle-order math: "press the key, get the app; press again, walk its windows."
///
/// The AppKit layer (Sources/cycler) owns the live AX window list and focus; this type owns the
/// *decision* of which window index to advance to, so the round-robin behaviour is unit-testable
/// without a running app. Keep it free of AppKit so it builds under `swift run cycler-tests`.
public enum WindowCycle {
    /// Given how many windows the target app currently has, the index that was focused last time
    /// (or `nil` if we weren't cycling this app yet / it just came to front), and the direction,
    /// return the next index to focus.
    ///
    /// Rules:
    /// - 0 windows -> `nil` (nothing to focus).
    /// - First engagement (`current == nil`): focus the FIRST window (index 0). The first press of
    ///   a per-app hotkey is "go to this app"; only a repeat press should advance past window 0.
    /// - Repeat engagement: step forward/back with wraparound.
    public static func next(count: Int, current: Int?, direction: Direction = .forward) -> Int? {
        guard count > 0 else { return nil }
        // First engagement, or only one window: focus the first window (i.e. "go to this app").
        guard let current, count > 1 else { return 0 }
        let clamped = ((current % count) + count) % count   // tolerate a stale out-of-range index
        switch direction {
        case .forward:  return (clamped + 1) % count
        case .backward: return (clamped - 1 + count) % count
        }
    }

    public enum Direction: Sendable { case forward, backward }
}

import AppKit
import AppCore

/// Two live instances fight over the same Carbon hotkeys (one hides an app, the other instantly
/// re-activates it — the toggle "never closes"). Standalone Cycler had this election; Lineup 1.x
/// had none, so this is a genuine improvement, now correctly scoped to `com.caiano.lineup`.
///
/// The election is deterministic — the older launch wins, lower pid breaks ties — so a same-wave
/// double launch (duplicate login items, say) can never make BOTH copies exit.
enum SingleInstance {
    /// The already-running Lineup that should keep the hotkeys, or `nil` when we are it.
    @MainActor
    static func incumbent() -> NSRunningApplication? {
        guard let bundleID = Bundle.main.bundleIdentifier else { return nil }
        let myPID = ProcessInfo.processInfo.processIdentifier
        let myLaunch = NSRunningApplication.current.launchDate ?? .distantPast
        return NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            // A process that has already exited is not an incumbent. The list can still carry a
            // just-quit copy (an update relaunch, a crash), and deferring to a dead one would make
            // the NEW instance exit and leave the user with no Lineup at all.
            .filter { $0.processIdentifier != myPID && !$0.isTerminated }
            .first { other in
                let otherLaunch = other.launchDate ?? .distantPast
                return otherLaunch < myLaunch
                    || (otherLaunch == myLaunch && other.processIdentifier < myPID)
            }
    }

    /// The standalone Cycler.app, if the user still has it running. It owns the same Carbon
    /// combos and can hold its own Caps Lock -> F18 `hidutil` mapping, so Hyperkey refuses to
    /// engage while it is alive (see `CapsLockHandoff`).
    @MainActor
    static func standaloneCyclerIsRunning() -> NSRunningApplication? {
        // Same `isTerminated` rule as the election: a Cycler that has already quit must not keep
        // Hyperkey blocked, nor stop us adopting the mapping it left behind.
        NSRunningApplication.runningApplications(withBundleIdentifier: legacyCyclerBundleID)
            .first { !$0.isTerminated }
    }

    static let legacyCyclerBundleID = "com.caiano.cycler"
}

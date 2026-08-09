import AppCore
import Foundation
import os

private let log = Logger(subsystem: Product.logSubsystem, category: "capslock-handoff")

/// Takes over the Caps Lock -> F18 `hidutil` mapping from a previous standalone Cycler install,
/// and recovers a mapping nobody owns any more.
///
/// The problem this exists for (plan §5.2, the highest-severity *silent* risk in the merge):
/// standalone Cycler recorded its ownership under its own flag (`legacyKey` below) in the
/// `com.caiano.cycler` defaults domain, while `HyperKeyController.isMappingOurs()` matches the
/// applied mapping on **shape**, not on ownership. So Lineup would look at a mapping Cycler
/// created, decide it is "ours", use it — and then never clear it on quit, because Lineup's own
/// ownership flag was never set. The user's Caps Lock stays remapped after quitting Lineup, with
/// nothing on screen to explain it.
///
/// Both sides of the handoff matter: Lineup has to *take* ownership (so its teardown clears the
/// mapping) and Cycler has to *lose* it (so a later Cycler run cannot clear a mapping Lineup is
/// actively using, or double-claim one). Lineup is not sandboxed, so the other app's defaults
/// domain is both readable and writable.
enum CapsLockHandoff {
    /// Lineup's ownership flag, in the `com.caiano.lineup` domain, matching the existing
    /// `lineup.*` key convention (`lineup.didOnboard`, `lineup.seenEdgeHint`).
    /// `HyperKeyController` reads this constant rather than a literal of its own.
    static let newKey = "lineup.ownsCapsLockToF18Mapping"
    /// Standalone Cycler's flag. This literal must appear exactly ONCE in `Sources/` — it is a
    /// superseded key, and a second mention would mean somebody re-implemented the handoff.
    /// Pinned by a source scan in `HyperkeySuite`.
    static let legacyKey = "CyclerOwnsCapsLockToF18Mapping"
    /// Same bundle ID the standalone-Cycler process check uses; shared so the two can never drift.
    static let legacySuite = SingleInstance.legacyCyclerBundleID

    // MARK: - Adoption

    /// One-time, called from `HyperkeyTool.start()` BEFORE the first `apply()`.
    ///
    /// If standalone Cycler recorded ownership of a Caps Lock -> F18 mapping **and is not
    /// running**:
    ///  * the legacy flag is cleared in the `com.caiano.cycler` domain, so a later Cycler run can
    ///    never also claim the mapping;
    ///  * and, only when that mapping is **still applied**, Lineup adopts it (sets `newKey` and
    ///    arms the exit hook), so Lineup's teardown is what finally clears it.
    ///
    /// A set flag with no mapping applied is stale (Cycler cleared the mapping but the flag
    /// survived, or the user cleared it by hand): the flag is dropped and nothing is adopted.
    ///
    /// The liveness guard is the whole reason this is not unconditional: a RUNNING standalone
    /// Cycler is still *using* that mapping. Adopting it would hand its Caps Lock to our teardown
    /// (`HyperkeyTool.apply()` blocks on the same liveness check and immediately clears every
    /// mapping we own), breaking a live app; clearing its flag alone would strand the mapping when
    /// Cycler later quits and finds no claim of its own. Same test `orphanedMappingDetected()`
    /// uses, and it recovers on the next launch once Cycler is gone.
    ///
    /// Probes `hidutil` on its queue, so nothing here blocks the main thread; adoption lands
    /// before the `apply()` that follows because both use that one serial queue.
    @MainActor
    static func adoptLegacyOwnershipIfNeeded() {
        guard let legacy = UserDefaults(suiteName: legacySuite), legacy.bool(forKey: legacyKey) else {
            return
        }
        guard SingleInstance.standaloneCyclerIsRunning() == nil else {
            log.info("standalone Cycler is running; leaving its Caps Lock ownership claim alone")
            return
        }
        // Cycler is gone, so its claim is ours to retire: whatever the probe finds, it must not
        // keep a claim on a mapping this process is about to manage.
        legacy.removeObject(forKey: legacyKey)

        HyperKeyController.adoptAppliedMappingIfPresentAsync { adopted in
            if adopted {
                log.info("adopted the CapsLock->F18 mapping left by standalone Cycler")
            } else {
                log.info("legacy Cycler ownership flag was stale (no CapsLock->F18 mapping applied); dropped")
            }
        }
    }

    // MARK: - Orphan detection + recovery

    /// True when a Caps Lock -> F18 mapping is applied that **no live process claims**: Lineup does
    /// not own it, and standalone Cycler — the only other program that creates this exact mapping —
    /// is not running. That is what a crashed, force-quit or deleted Cycler leaves behind.
    ///
    /// Deliberately NOT keyed on `legacyKey`. Cycler clears that flag only on a clean teardown, so a
    /// crash leaves it set — which is precisely the case this has to report. Liveness is the honest
    /// test: while Cycler runs, the mapping has an owner (and `HyperkeyTool`'s standalone-Cycler
    /// guard already says so, with a more specific message); once it is gone, nothing will ever
    /// clear the mapping but us.
    ///
    /// Raycast's Hyper Key installs the identical mapping, so it is excluded too — otherwise Lineup
    /// would offer to "restore" Caps Lock out from under a healthy Raycast.
    ///
    /// Residual false positive by construction: a Caps Lock -> F18 mapping the user installed
    /// themselves (a login item, a Karabiner-free `hidutil` one-liner) has the same shape and reads
    /// as orphaned. That is why recovery is a button the user presses, never automatic.
    ///
    /// Spawns `hidutil`, so the answer arrives on a completion (on the main thread) rather than
    /// blocking the caller, and callers cache it rather than asking per menu build or per SwiftUI
    /// body evaluation.
    @MainActor
    static func orphanedMappingDetected(completion: @escaping (Bool) -> Void) {
        guard !HyperKeyController.ownsCapsLockMapping,
              SingleInstance.standaloneCyclerIsRunning() == nil,
              !HyperKeyController.raycastCapsHyperEnabled()
        else {
            completion(false)
            return
        }
        HyperKeyController.currentMappingAsync { mapping in
            completion(HyperKeyController.isMappingOurs(mapping))
        }
    }

    /// User-triggered recovery, from the "Restore Caps Lock" button in the Hyperkey pane.
    /// Clears the mapping only after re-confirming it matches our shape, so a mapping some other
    /// app installed for its own purposes is never wiped, and forgets any ownership either side
    /// recorded.
    ///
    /// `hidutil` runs on its own queue; `completion` reports on the main thread whether a mapping
    /// was actually cleared.
    @MainActor
    static func restoreCapsLock(completion: @escaping (Bool) -> Void) {
        HyperKeyController.clearIfMappingIsOursAsync { cleared in
            HyperKeyController.releaseOwnedMapping()
            UserDefaults(suiteName: legacySuite)?.removeObject(forKey: legacyKey)
            log.info("restore Caps Lock requested; cleared=\(cleared, privacy: .public)")
            completion(cleared)
        }
    }
}

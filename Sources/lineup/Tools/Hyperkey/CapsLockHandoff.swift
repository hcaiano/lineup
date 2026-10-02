import AppCore
import Foundation

/// The two pre-service ownership flags remain migration inputs. A pair's shape alone never
/// authorizes adoption or recovery; all table changes go through KeyboardMappingService.
enum CapsLockHandoff {
    static let newKey = "lineup.ownsCapsLockToF18Mapping"
    static let legacyKey = "CyclerOwnsCapsLockToF18Mapping"
    static let legacySuite = SingleInstance.legacyCyclerBundleID

    @MainActor
    static func adoptLegacyOwnershipIfNeeded(using service: KeyboardMappingService) {
        // start() probes and journals an explicit claim before retiring either old flag.
        service.start()
    }

    @MainActor
    static func orphanedMappingDetected(using service: KeyboardMappingService,
                                       completion: @escaping (Bool) -> Void) {
        guard SingleInstance.standaloneCyclerIsRunning() == nil,
              !HyperKeyController.raycastCapsHyperEnabled() else {
            completion(false)
            return
        }
        let legacyClaim = UserDefaults.standard.bool(forKey: newKey)
            || (UserDefaults(suiteName: legacySuite)?.bool(forKey: legacyKey) ?? false)
        completion(service.capsLockRecoveryPending || (!service.hyperkeyRequested && legacyClaim))
    }

    @MainActor
    static func restoreCapsLock(using service: KeyboardMappingService,
                                completion: @escaping (Bool) -> Void) {
        service.restoreOwnedCapsLock(completion: completion)
    }
}

import HyperkeyCore

@MainActor
final class HyperkeyBlockedAttemptObserver {
    struct Snapshot {
        var isRunning: Bool
        var isBlocked: Bool
        var trigger: TriggerKey
        var keyCode: Int
        var capsMappingReady: Bool

        var eligibleKey: EligibleKey? {
            guard isRunning, isBlocked,
                  trigger.isFunctionKey || (trigger.needsCapsLockRemap && capsMappingReady) else { return nil }
            return EligibleKey(trigger: trigger, keyCode: keyCode)
        }
    }

    struct EligibleKey: Equatable {
        let trigger: TriggerKey
        let keyCode: Int
    }

    private struct Registration {
        let key: EligibleKey
        let identity: Int
        let token: HotkeyManager.Token
    }

    private let hotkeys: HotkeyScope
    private let snapshot: () -> Snapshot
    private let onAttempt: () -> Void
    private let onFailure: (HotkeyFailure) -> Void
    private var registration: Registration?
    private var nextIdentity = 0

    init(hotkeys: HotkeyScope, snapshot: @escaping () -> Snapshot,
         onAttempt: @escaping () -> Void, onFailure: @escaping (HotkeyFailure) -> Void) {
        self.hotkeys = hotkeys
        self.snapshot = snapshot
        self.onAttempt = onAttempt
        self.onFailure = onFailure
    }

    func reconcile() {
        guard let key = snapshot().eligibleKey else { stop(); return }
        guard registration?.key != key else { return }
        stop()
        nextIdentity += 1
        let identity = nextIdentity
        let result = hotkeys.register(keyCode: key.keyCode, modifiers: 0) { [weak self] in
            guard let self, !self.hotkeys.isSuspended,
                  self.registration?.identity == identity,
                  self.snapshot().eligibleKey == key else { return }
            self.onAttempt()
        }
        switch result {
        case .success(let token):
            registration = Registration(key: key, identity: identity, token: token)
        case .failure(let failure):
            onFailure(failure)
        }
    }

    func hotkeysFailedToRestore(_ failures: [HotkeyRestoreFailure]) {
        guard let registration,
              let failure = failures.first(where: { $0.keyCode == registration.key.keyCode && $0.modifiers == 0 }) else { return }
        stop()
        onFailure(.carbon(failure.status))
    }

    func stop() {
        guard let registration else { return }
        self.registration = nil
        hotkeys.unregister(registration.token)
    }
}

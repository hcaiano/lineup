import AppKit
import AppCore
import ApplicationServices
import Carbon.HIToolbox
import CoreGraphics
import DisplayControlCore

typealias MediaKeyAction = DisplayMediaKey

enum MediaKeyFailure: Error, Equatable, LocalizedError {
    case accessibilityDenied
    case unavailable
    case ownedByTool(ToolID)

    var errorDescription: String? {
        switch self {
        case .accessibilityDenied:
            return "Allow Accessibility to use brightness and volume keys. Display sliders remain available."
        case .unavailable:
            return "macOS could not start brightness and volume key control. Use the display sliders or retry."
        case .ownedByTool(let owner):
            return "\(owner.displayName) already uses these media keys. Display sliders remain available."
        }
    }
}

/// Tools receive an owner scope, just as they do for Carbon shortcuts. A handler claims a
/// press after accepting a command or handling a refusal that must not change another display.
@MainActor
struct MediaKeyScope {
    let owner: ToolID

    @discardableResult
    func register(actions: Set<MediaKeyAction>,
                  handler: @escaping (MediaKeyAction, Bool, Double) -> Bool,
                  onFailureChange: ((MediaKeyFailure?) -> Void)? = nil)
        -> Result<Void, MediaKeyFailure> {
        MediaKeyManager.shared.register(owner: owner, actions: actions,
                                        handler: handler, onFailureChange: onFailureChange)
    }

    var failure: MediaKeyFailure? { MediaKeyManager.shared.failure(for: owner) }

    func unregisterAll() {
        MediaKeyManager.shared.unregisterAll(owner: owner)
    }
}

/// Owns only system media-key events. Hyperkey's keyboard/flags tap and the Carbon shortcut
/// registry keep their existing event paths. No event is synthesized or reposted here.
@MainActor
final class MediaKeyManager {
    static let shared = MediaKeyManager()
    private static let systemDefinedType = UInt32(NSEvent.EventType.systemDefined.rawValue)

    private struct Registration {
        let owner: ToolID
        let actions: Set<MediaKeyAction>
        let handler: (MediaKeyAction, Bool, Double) -> Bool
        let onFailureChange: ((MediaKeyFailure?) -> Void)?
    }

    // An array makes both dispatch and conflict attribution follow registration order.
    private var registrations: [Registration] = []
    private var failures: [ToolID: MediaKeyFailure] = [:]
    private var claimedPresses: [MediaKeyAction: ToolID] = [:]
    private var pressState = DisplayMediaKeyPressState()
    private var registrationRevision = 0
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var observers: [(center: NotificationCenter, token: NSObjectProtocol)] = []
    private var permissionTimer: Timer?
    private var isSleeping = false

    @discardableResult
    func register(owner: ToolID, actions: Set<MediaKeyAction>,
                  handler: @escaping (MediaKeyAction, Bool, Double) -> Bool,
                  onFailureChange: ((MediaKeyFailure?) -> Void)?)
        -> Result<Void, MediaKeyFailure> {
        guard !actions.isEmpty else {
            unregisterAll(owner: owner)
            return .success(())
        }
        if let foreign = registrations.first(where: {
            $0.owner != owner && !$0.actions.isDisjoint(with: actions)
        }) {
            let failure = MediaKeyFailure.ownedByTool(foreign.owner)
            unregisterAll(owner: owner)
            failures[owner] = failure
            onFailureChange?(failure)
            return .failure(failure)
        }

        let registration = Registration(owner: owner, actions: actions, handler: handler,
                                        onFailureChange: onFailureChange)
        registrationRevision &+= 1
        if let index = registrations.firstIndex(where: { $0.owner == owner }) {
            registrations[index] = registration
        } else {
            registrations.append(registration)
        }
        startWatching()
        reconcile()
        if let failure = failures[owner] { return .failure(failure) }
        return .success(())
    }

    func failure(for owner: ToolID) -> MediaKeyFailure? { failures[owner] }

    func unregisterAll(owner: ToolID) {
        registrationRevision &+= 1
        registrations.removeAll { $0.owner == owner }
        failures.removeValue(forKey: owner)
        pressState.release(Set(claimedPresses.filter { $0.value == owner }.map(\.key)))
        claimedPresses = claimedPresses.filter { $0.value != owner }
        guard registrations.isEmpty else { return }
        stopTap()
        permissionTimer?.invalidate()
        permissionTimer = nil
        for observer in observers { observer.center.removeObserver(observer.token) }
        observers.removeAll()
        isSleeping = false
    }

    private func startWatching() {
        guard permissionTimer == nil else { return }
        observe(NotificationCenter.default, NSApplication.didBecomeActiveNotification) { $0.reconcile() }
        observe(DistributedNotificationCenter.default(),
                NSNotification.Name("com.apple.accessibility.api")) { $0.reconcile() }
        observe(NSWorkspace.shared.notificationCenter, NSWorkspace.willSleepNotification) {
            $0.isSleeping = true
            $0.stopTap()
        }
        observe(NSWorkspace.shared.notificationCenter, NSWorkspace.didWakeNotification) {
            $0.isSleeping = false
            $0.reconcile()
        }

        // A revoked grant may disable the tap before another event arrives. Watch only while
        // a tool has explicitly opted in to media keys, including while a menu tracks input.
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.reconcile() }
        }
        timer.tolerance = 1
        RunLoop.main.add(timer, forMode: .common)
        permissionTimer = timer
    }

    private func observe(_ center: NotificationCenter, _ name: NSNotification.Name,
                         action: @escaping (MediaKeyManager) -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                action(self)
            }
        }
        observers.append((center, token))
    }

    private func reconcile() {
        guard !registrations.isEmpty, !isSleeping else { return }
        // Permission requests belong to the invoking tool's user action and PermissionCenter.
        guard AXIsProcessTrusted() else {
            stopTap()
            setFailure(.accessibilityDenied)
            return
        }
        if let tap, CGEvent.tapIsEnabled(tap: tap) {
            setFailure(nil)
            return
        }
        stopTap()
        guard let created = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: CGEventMask(1) << Self.systemDefinedType,
            callback: mediaKeyManagerTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            setFailure(.unavailable)
            return
        }
        guard let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, created, 0) else {
            CFMachPortInvalidate(created)
            setFailure(.unavailable)
            return
        }
        tap = created
        source = runLoopSource
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: created, enable: true)
        setFailure(nil)
    }

    private func setFailure(_ failure: MediaKeyFailure?) {
        // Notify from a snapshot: the callback can refresh a pane or unregister its tool.
        let current = registrations
        for registration in current {
            guard failures[registration.owner] != failure else { continue }
            failures[registration.owner] = failure
            registration.onFailureChange?(failure)
        }
    }

    private func stopTap() {
        registrationRevision &+= 1
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let source {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            CFRunLoopSourceInvalidate(source)
        }
        tap = nil
        source = nil
        claimedPresses.removeAll()
        pressState.releaseAll()
    }

    fileprivate func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            claimedPresses.removeAll()
            pressState.releaseAll()
            if AXIsProcessTrusted(), !isSleeping, !registrations.isEmpty, let tap {
                CGEvent.tapEnable(tap: tap, enable: true)
            } else {
                reconcile()
            }
            return Unmanaged.passUnretained(event)
        }
        guard AXIsProcessTrusted() else {
            reconcile()
            return Unmanaged.passUnretained(event)
        }
        guard !isSleeping, !registrations.isEmpty, tap != nil else {
            return Unmanaged.passUnretained(event)
        }
        guard type.rawValue == Self.systemDefinedType, let native = NSEvent(cgEvent: event),
              native.subtype.rawValue == 8,
              let keyEvent = DisplayMediaKeyEvent(data1: native.data1) else {
            return Unmanaged.passUnretained(event)
        }

        if !keyEvent.isDown {
            let consumed = pressState.handle(keyEvent) { _ in false }
            claimedPresses.removeValue(forKey: keyEvent.key)
            return consumed ? nil : Unmanaged.passUnretained(event)
        }

        // Option + Shift uses macOS's fine-adjustment convention. Other modifier chords,
        // Hyperkey, and raw Settings recording retain their existing actions.
        guard let scopeOwner = registrations.first?.owner,
              !HotkeyScope(owner: scopeOwner).isSuspended,
              let adjustment = DisplayMediaKeyAdjustment(modifierFlags: event.flags.rawValue),
              !IsSecureEventInputEnabled() else {
            // Pause commands for a held claimed key without native fallback changing another
            // display. A fresh press or an unclaimed repeat still reaches macOS.
            let consumed = pressState.handle(keyEvent) { _ in false }
            if !keyEvent.isRepeat { claimedPresses.removeValue(forKey: keyEvent.key) }
            return consumed ? nil : Unmanaged.passUnretained(event)
        }

        let revision = registrationRevision
        let accepted: Bool
        if keyEvent.isRepeat {
            // The tool pins its display connection for the initial press. A failed repeat
            // stays consumed so native fallback cannot change another display midway through.
            if keyEvent.key != .mute, let owner = claimedPresses[keyEvent.key],
               let registration = registrations.first(where: {
                   $0.owner == owner && $0.actions.contains(keyEvent.key)
               }) {
                accepted = registration.handler(keyEvent.key, true, adjustment.step)
            } else {
                accepted = false
            }
        } else {
            claimedPresses.removeValue(forKey: keyEvent.key)
            if let registration = registrations.first(where: { $0.actions.contains(keyEvent.key) }) {
                accepted = registration.handler(keyEvent.key, false, adjustment.step)
                if accepted, registrationRevision == revision {
                    claimedPresses[keyEvent.key] = registration.owner
                }
            } else {
                accepted = false
            }
        }
        // A handler may stop its tool. Do not recreate press state after its scope was released.
        guard registrationRevision == revision else {
            return accepted ? nil : Unmanaged.passUnretained(event)
        }
        let consumed = pressState.handle(keyEvent) { _ in accepted }
        return consumed ? nil : Unmanaged.passUnretained(event)
    }
}

private func mediaKeyManagerTapCallback(proxy: CGEventTapProxy, type: CGEventType,
                                       event: CGEvent, userInfo: UnsafeMutableRawPointer?)
    -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let manager = Unmanaged<MediaKeyManager>.fromOpaque(userInfo).takeUnretainedValue()
    return MainActor.assumeIsolated { manager.handle(type: type, event: event) }
}

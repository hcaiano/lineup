import AppKit
import ApplicationServices
import CryptoKit
import Foundation
import TilesCore
import ZonesCore

enum SnapshotScope: Sendable {
    case all
    case pid(pid_t)
}

enum WindowSystemEvent: Sendable {
    case applicationChanged(pid_t)
    case applicationActivated(pid_t)
    case externalActivation(WindowToken)
    case windowCreated(pid_t)
    case windowChanged(WindowToken, pid_t)
    case windowDestroyed(WindowToken)
    case topologyChanged
}

struct TilesRecoveryResult: Sendable {
    let restoredIdentityKeys: Set<String>
}

protocol TilesWindowSystem: AnyObject {
    func updateScreens(_ screens: [LiveScreen])
    func start(_ receive: @escaping @Sendable (WindowSystemEvent) -> Void) throws
    func snapshot(_ scope: SnapshotScope) -> WindowSnapshot
    func apply(_ effects: [WindowEffect]) -> [WindowEffectResult]
    func stackPreview(tokens: [WindowToken], selected: WindowToken) -> TilesStackPreview?
    func cancelPending()
    func token(for element: AXUIElement) -> WindowToken?
    func recoveryRecord(for token: WindowToken, managed: ManagedWindow, stageIntent: Bool) -> RecoveryRecord?
    func recover(_ journal: RecoveryJournal, deadline: DispatchTime) -> TilesRecoveryResult
    func restore(_ session: TilesSession, journal: RecoveryJournal, deadline: DispatchTime) -> TilesRecoveryResult
    func stop()
}

private final class TilesAXObserverBridge {
    weak var owner: AXWindowSystem?
    let pid: pid_t

    init(owner: AXWindowSystem, pid: pid_t) {
        self.owner = owner
        self.pid = pid
    }
}

private func tilesAXObserverCallback(
    _ observer: AXObserver,
    _ element: AXUIElement,
    _ notification: CFString,
    _ refcon: UnsafeMutableRawPointer?
) {
    guard let refcon else { return }
    let bridge = Unmanaged<TilesAXObserverBridge>.fromOpaque(refcon).takeUnretainedValue()
    bridge.owner?.receivedAXNotification(pid: bridge.pid, element: element,
                                         notification: notification as String)
}

final class AXWindowSystem: TilesWindowSystem {
    private struct ApplicationDescriptor {
        let pid: pid_t
        let bundleIdentifier: String
    }

    private struct EligibilityObservation {
        let eligible: Bool
        let complete: Bool
        let initiallyMinimized: Bool
    }

    private final class Entry {
        let token: WindowToken
        let element: AXUIElement
        let pid: pid_t
        var bundleIdentifier: String
        var role: String
        var subrole: String
        var titleDigest: String
        var ordinalAmongExactPeers: Int
        var eligibleAtDiscovery: Bool
        var eligibilityResolved: Bool
        var initiallyMinimized: Bool

        init(token: WindowToken = WindowToken(), element: AXUIElement, pid: pid_t,
             bundleIdentifier: String, role: String, subrole: String,
             titleDigest: String, ordinalAmongExactPeers: Int,
             eligibleAtDiscovery: Bool, eligibilityResolved: Bool,
             initiallyMinimized: Bool) {
            self.token = token
            self.element = element
            self.pid = pid
            self.bundleIdentifier = bundleIdentifier
            self.role = role
            self.subrole = subrole
            self.titleDigest = titleDigest
            self.ordinalAmongExactPeers = ordinalAmongExactPeers
            self.eligibleAtDiscovery = eligibleAtDiscovery
            self.eligibilityResolved = eligibilityResolved
            self.initiallyMinimized = initiallyMinimized
        }
    }

    private struct ObserverEntry {
        let observer: AXObserver
        let bridge: TilesAXObserverBridge
    }

    /// `AXUIElement` is a CF type with no Swift `Hashable` conformance, so an
    /// element-keyed index needs an explicit `CFHash`/`CFEqual` wrapper.  Every
    /// AX lookup by element goes through this instead of a linear scan; the
    /// notification stream during a drag hits those lookups continuously.
    private struct ElementKey: Hashable {
        let element: AXUIElement

        init(_ element: AXUIElement) { self.element = element }

        static func == (lhs: ElementKey, rhs: ElementKey) -> Bool {
            CFEqual(lhs.element, rhs.element)
        }

        func hash(into hasher: inout Hasher) { hasher.combine(CFHash(element)) }
    }

    /// One live AX read of the two values every correlation and snapshot pass
    /// needs, so a window costs one frame read and one minimized read per pass.
    private struct EntryObservation {
        let entry: Entry
        let frame: CGRect?
        let minimized: Bool
    }

    private let queue = DispatchQueue(label: "com.caiano.lineup.tiles.ax", qos: .userInitiated)
    private let ownPID = ProcessInfo.processInfo.processIdentifier
    private var entries: [WindowToken: Entry] = [:]
    /// Element-keyed index over `entries`.  Mutate both only through
    /// `insertEntry` and `removeEntry` so they cannot drift apart.
    private var entriesByElement: [ElementKey: Entry] = [:]
    /// Windows whose per-window AX notifications are already registered.  A
    /// repeat `AXObserverAddNotification` returns `notificationAlreadyRegistered`
    /// but still costs a cross-process round trip on every discover pass.
    private var registeredElements: Set<ElementKey> = []
    private var pendingGoneTokens: [WindowToken: pid_t] = [:]
    private var observers: [pid_t: ObserverEntry] = [:]
    private var workspaceObservers: [NSObjectProtocol] = []
    private var screens: [LiveScreen] = []
    private var receive: (@Sendable (WindowSystemEvent) -> Void)?
    private var acceptingEvents = false
    private let cancellationLock = NSLock()
    private var cancellationGeneration: UInt64 = 0

    func updateScreens(_ screens: [LiveScreen]) {
        queue.async { self.screens = screens }
    }

    func start(_ receive: @escaping @Sendable (WindowSystemEvent) -> Void) throws {
        guard AXIsProcessTrusted() else { throw AXWindowSystemError.accessibilityDenied }
        guard !acceptingEvents else { return }
        self.receive = receive
        acceptingEvents = true

        let workspace = NSWorkspace.shared
        let center = workspace.notificationCenter
        workspaceObservers.append(center.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            self?.applicationLaunched(app)
        })
        workspaceObservers.append(center.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            self?.applicationTerminated(app.processIdentifier)
        })
        for name in [NSWorkspace.didHideApplicationNotification, NSWorkspace.didUnhideApplicationNotification] {
            workspaceObservers.append(center.addObserver(forName: name, object: nil, queue: .main) {
                [weak self] note in
                guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
                self?.emit(.applicationChanged(app.processIdentifier))
            })
        }
        workspaceObservers.append(center.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            self?.emit(.applicationActivated(app.processIdentifier))
        })
        workspaceObservers.append(center.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.emit(.topologyChanged) })
        workspaceObservers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.emit(.topologyChanged) })

        let applications = Self.regularApplications(workspace.runningApplications, excluding: ownPID)
        let generation = currentCancellationGeneration()
        // Queue discovery before returning to MainActor. The coordinator's first recovery call
        // enters this same serial queue, so it waits for discovery without freezing Settings.
        queue.async { [weak self] in
            guard let self, self.acceptingEvents else { return }
            self.discover(applications: applications, cancellationGeneration: generation)
        }
    }

    func snapshot(_ scope: SnapshotScope) -> WindowSnapshot {
        let generation = currentCancellationGeneration()
        return queue.sync {
            let applications = Self.regularApplications(NSWorkspace.shared.runningApplications,
                                                        excluding: ownPID)
            let selected: [Entry]
            let gone: Set<WindowToken>
            let consumesGone: Bool
            switch scope {
            case .all:
                discover(applications: applications, cancellationGeneration: generation)
                selected = Array(entries.values)
                gone = Set(pendingGoneTokens.keys)
                consumesGone = true
            case .pid(let pid):
                // A scoped snapshot only reports one application's windows, so
                // only that application needs the AX window sweep.  The full
                // application list still drives the dead-process pruning.
                discover(applications: applications, cancellationGeneration: generation,
                         scanning: [pid])
                selected = entries.values.filter { $0.pid == pid }
                gone = Set(pendingGoneTokens.compactMap { $0.value == pid ? $0.key : nil })
                consumesGone = false
            }
            if consumesGone {
                for token in gone { pendingGoneTokens[token] = nil }
            }
            // Correlate against every retained AX entry, not only the requested
            // snapshot scope.  A scoped snapshot must not make two windows
            // sharing a frame look uniquely correlated simply because one peer
            // was omitted from the output.
            let observations = liveObservations()
            let correlated = correlatedTokens(observations)
            var observationsByToken: [WindowToken: EntryObservation] = [:]
            observationsByToken.reserveCapacity(observations.count)
            for observation in observations { observationsByToken[observation.entry.token] = observation }
            let screenFrames = screens.map(\.frame)
            var output: [WindowToken: WindowSnapshotEntry] = [:]
            for entry in selected {
                guard let observation = observationsByToken[entry.token],
                      let frame = observation.frame else { continue }
                let minimized = observation.minimized
                let screenKey = ScreenPicker.bestScreenIndex(forWindow: frame, screens: screenFrames)
                    .map { screens[$0].key } ?? ""
                // A retained minimized AX window is still a valid mutation target even
                // though `optionOnScreenOnly` cannot correlate it. Keep current-Space
                // correlation as the reachability gate only for non-minimized windows.
                let reachable = minimized || correlated.contains(entry.token)
                output[entry.token] = WindowSnapshotEntry(
                    token: entry.token, frame: frame, screenKey: screenKey,
                    isVisible: !minimized && reachable, isMinimized: minimized,
                    isEligible: entry.eligibleAtDiscovery, isReachable: reachable)
            }
            return WindowSnapshot(windows: output, focused: focusedToken(), goneTokens: gone)
        }
    }

    func apply(_ effects: [WindowEffect]) -> [WindowEffectResult] {
        let generation = currentCancellationGeneration()
        return queue.sync {
            var correlated = correlatedTokens(liveObservations())
            return effects.map { effect in
                guard !isCancelled(generation) else { return .failure(effect, .cancelled) }
                guard let entry = entries[effect.token] else {
                    return .failure(effect, .goneWindow)
                }
                switch effect {
                case .setMinimized(_, false, _):
                    let error = setBool(false, on: entry.element,
                                        attribute: kAXMinimizedAttribute, verify: true)
                    if error == .success {
                        // Deminimizing a staged window is the one permitted effect while it is
                        // absent from the current on-screen CG snapshot. Wait for bounded public
                        // CG correlation before any following frame/raise/focus effect.
                        for attempt in 0..<3 {
                            correlated = correlatedTokens(liveObservations())
                            if correlated.contains(entry.token) { break }
                            if attempt < 2 { usleep(40_000) }
                        }
                    }
                    return result(effect, from: error)
                default:
                    guard correlated.contains(entry.token) else {
                        // The AX element is still retained, but it is not in
                        // the current native Space's public CG snapshot.  It
                        // is unreachable, not gone; keep its Tiles
                        // assignment and let reconciliation retry it later.
                        return .failure(effect, .cannotComplete)
                    }
                }

                switch effect {
                case .setFrame(_, let frame, _):
                    guard isSafeOnScreen(frame) else { return .failure(effect, .rejectedFrame) }
                    return result(effect, from: setFrame(frame, on: entry.element))
                case .setMinimized(_, let minimized, _):
                    return result(effect, from: setBool(minimized, on: entry.element,
                                                        attribute: kAXMinimizedAttribute,
                                                        verify: true))
                case .raise:
                    return result(effect, from: AXUIElementPerformAction(
                        entry.element, kAXRaiseAction as CFString))
                case .focus:
                    NSRunningApplication(processIdentifier: entry.pid)?.activate(options: [.activateIgnoringOtherApps])
                    let app = tame(AXUIElementCreateApplication(entry.pid))
                    _ = AXUIElementSetAttributeValue(entry.element, kAXMainAttribute as CFString,
                                                     kCFBooleanTrue)
                    _ = AXUIElementSetAttributeValue(entry.element, kAXFocusedAttribute as CFString,
                                                     kCFBooleanTrue)
                    _ = AXUIElementSetAttributeValue(app, kAXFocusedWindowAttribute as CFString,
                                                     entry.element)
                    var focusedRaw: CFTypeRef?
                    let focused = AXUIElementCopyAttributeValue(
                        app, kAXFocusedWindowAttribute as CFString, &focusedRaw) == .success
                        && focusedRaw.map { CFEqual($0, entry.element) } == true
                    return focused ? .success(effect) : .failure(effect, .cannotComplete)
                }
            }
        }
    }

    func token(for element: AXUIElement) -> WindowToken? {
        queue.sync { entriesByElement[ElementKey(element)]?.token }
    }

    func stackPreview(tokens: [WindowToken], selected: WindowToken) -> TilesStackPreview? {
        queue.sync {
            guard let selectedIndex = tokens.firstIndex(of: selected), !tokens.isEmpty else { return nil }
            let titles = tokens.compactMap { token -> String? in
                guard let entry = entries[token] else { return nil }
                let title = string(entry.element, kAXTitleAttribute) ?? ""
                if !title.isEmpty { return title }
                return NSRunningApplication(processIdentifier: entry.pid)?.localizedName ?? "Window"
            }
            guard titles.count == tokens.count else { return nil }
            let icon = entries[selected]
                .flatMap { NSRunningApplication(processIdentifier: $0.pid) }?.icon
            return TilesStackPreview(appIcon: icon, titles: titles, selectedIndex: selectedIndex)
        }
    }

    func cancelPending() {
        cancellationLock.lock()
        cancellationGeneration &+= 1
        cancellationLock.unlock()
    }

    func recoveryRecord(for token: WindowToken, managed: ManagedWindow,
                        stageIntent: Bool) -> RecoveryRecord? {
        queue.sync {
            recoveryRecordUnlocked(for: token, managed: managed, stageIntent: stageIntent)
        }
    }

    func recover(_ journal: RecoveryJournal, deadline: DispatchTime) -> TilesRecoveryResult {
        queue.sync { restoreRecords(journal.records, deadline: deadline) }
    }

    func restore(_ session: TilesSession, journal: RecoveryJournal,
                 deadline: DispatchTime) -> TilesRecoveryResult {
        queue.sync {
            var recordsByIdentity: [String: RecoveryRecord] = [:]
            for managed in session.windows.values {
                if let record = recoveryRecordUnlocked(for: managed.token, managed: managed,
                                                        stageIntent: managed.visibility == .stagedByTiles) {
                    recordsByIdentity[record.identityKey] = record
                }
            }
            for record in journal.records {
                if var current = recordsByIdentity[record.identityKey] {
                    // The journal is the crash boundary.  If a deminimize was
                    // journaled but its verification was not observed, keep
                    // the ownership bit even when the in-memory session says
                    // the window is visible.
                    current.stageIntent = current.stageIntent || record.stageIntent
                    recordsByIdentity[record.identityKey] = current
                } else {
                    recordsByIdentity[record.identityKey] = record
                }
            }
            return restoreRecords(Array(recordsByIdentity.values), deadline: deadline)
        }
    }

    func stop() {
        acceptingEvents = false
        let center = NSWorkspace.shared.notificationCenter
        for token in workspaceObservers {
            center.removeObserver(token)
            NotificationCenter.default.removeObserver(token)
        }
        workspaceObservers.removeAll()
        queue.sync {
            for item in observers.values {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(item.observer), .defaultMode)
            }
            observers.removeAll()
            entries.removeAll()
            entriesByElement.removeAll()
            registeredElements.removeAll()
            pendingGoneTokens.removeAll()
            receive = nil
        }
    }

    fileprivate func receivedAXNotification(pid: pid_t, element: AXUIElement, notification: String) {
        queue.async { [weak self] in
            guard let self, self.acceptingEvents else { return }
            let token = self.entriesByElement[ElementKey(element)]?.token
            switch notification {
            case kAXWindowCreatedNotification:
                self.emit(.windowCreated(pid))
            case kAXUIElementDestroyedNotification:
                if let token {
                    self.removeEntry(token)
                    self.emit(.windowDestroyed(token))
                } else {
                    self.emit(.applicationChanged(pid))
                }
            case kAXFocusedWindowChangedNotification:
                // This callback is registered on the application AX element,
                // so its element is not itself a window.  Resolve the newly
                // focused window while still on the AX queue and carry the
                // token to the coordinator.  This also covers focus changes
                // between windows of an already-frontmost application, for
                // which NSWorkspace sends no activation notification.
                if let focused = self.focusedToken(in: element, pid: pid) {
                    self.emit(.externalActivation(focused))
                } else {
                    self.emit(.applicationChanged(pid))
                }
            default:
                if let token { self.emit(.windowChanged(token, pid)) }
                else { self.emit(.applicationChanged(pid)) }
            }
        }
    }

    private func applicationLaunched(_ application: NSRunningApplication) {
        guard let descriptor = Self.regularDescriptor(application, excluding: ownPID) else { return }
        queue.async { [weak self] in
            self?.installObserver(for: descriptor)
            self?.emit(.applicationChanged(descriptor.pid))
        }
    }

    private func applicationTerminated(_ pid: pid_t) {
        queue.async { [weak self] in
            guard let self else { return }
            if let item = self.observers.removeValue(forKey: pid) {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(item.observer), .defaultMode)
            }
            let removed = self.entries.values.filter { $0.pid == pid }.map(\.token)
            for token in removed {
                self.removeEntry(token)
                self.emit(.windowDestroyed(token))
            }
        }
    }

    private func emit(_ event: WindowSystemEvent) {
        guard acceptingEvents else { return }
        receive?(event)
    }

    private static func regularApplications(_ applications: [NSRunningApplication],
                                            excluding ownPID: pid_t) -> [ApplicationDescriptor] {
        applications.compactMap { regularDescriptor($0, excluding: ownPID) }
    }

    private static func regularDescriptor(_ application: NSRunningApplication,
                                          excluding ownPID: pid_t) -> ApplicationDescriptor? {
        guard application.processIdentifier != ownPID,
              !application.isTerminated,
              application.activationPolicy == .regular,
              let bundle = application.bundleIdentifier else { return nil }
        return ApplicationDescriptor(pid: application.processIdentifier, bundleIdentifier: bundle)
    }

    private func installObserver(for application: ApplicationDescriptor) {
        guard observers[application.pid] == nil else { return }
        var observer: AXObserver?
        guard AXObserverCreate(application.pid, tilesAXObserverCallback, &observer) == .success,
              let observer else { return }
        let bridge = TilesAXObserverBridge(owner: self, pid: application.pid)
        let pointer = Unmanaged.passUnretained(bridge).toOpaque()
        let app = tame(AXUIElementCreateApplication(application.pid))
        let notifications = [kAXWindowCreatedNotification, kAXFocusedWindowChangedNotification]
        for notification in notifications {
            _ = AXObserverAddNotification(observer, app, notification as CFString, pointer)
        }
        observers[application.pid] = ObserverEntry(observer: observer, bridge: bridge)
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
    }

    /// Sweeps the AX window list of every application in `scanning`, or of all
    /// `applications` when `scanning` is nil.  The full `applications` list
    /// always defines which retained entries belong to a live process, so a
    /// scoped sweep never prunes another application's windows.
    private func discover(applications: [ApplicationDescriptor],
                          cancellationGeneration: UInt64? = nil,
                          scanning: Set<pid_t>? = nil) {
        let validPIDs = Set(applications.map(\.pid))
        for application in applications {
            if let cancellationGeneration, isCancelled(cancellationGeneration) { return }
            installObserver(for: application)
            if let scanning, !scanning.contains(application.pid) { continue }
            let app = tame(AXUIElementCreateApplication(application.pid))
            var raw: CFTypeRef?
            guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &raw) == .success,
                  let windows = raw as? [AXUIElement] else { continue }
            let peers = windows.compactMap { window -> (AXUIElement, String?, String?, String, CGRect?)? in
                let window = tame(window)
                // Keep an AX element even while role/subrole are transiently
                // unavailable. That lets the first minimized observation stay
                // authoritative while the rest of eligibility settles.
                let role = string(window, kAXRoleAttribute)
                let subrole = string(window, kAXSubroleAttribute)
                let digest = Self.titleDigest(string(window, kAXTitleAttribute) ?? "")
                return (window, role, subrole, digest, cocoaFrame(of: window))
            }.sorted { lhs, rhs in
                let a = lhs.4 ?? .zero, b = rhs.4 ?? .zero
                if a.minX != b.minX { return a.minX < b.minX }
                if a.minY != b.minY { return a.minY < b.minY }
                return a.width * a.height < b.width * b.height
            }
            let peerKeys = Set(peers.map { ElementKey($0.0) })
            let disappeared = entries.values.filter { entry in
                entry.pid == application.pid && !peerKeys.contains(ElementKey(entry.element))
            }.map(\.token)
            for token in disappeared {
                pendingGoneTokens[token] = application.pid
                removeEntry(token)
            }
            var ordinalByFingerprint: [String: Int] = [:]
            for peer in peers {
                registerWindowNotifications(peer.0, pid: application.pid)
                let key = [peer.1 ?? "", peer.2 ?? "", peer.3].joined(separator: "\u{1f}")
                let ordinal = ordinalByFingerprint[key, default: 0]
                ordinalByFingerprint[key] = ordinal + 1
                if let existing = entriesByElement[ElementKey(peer.0)] {
                    existing.bundleIdentifier = application.bundleIdentifier
                    if let role = peer.1 { existing.role = role }
                    if let subrole = peer.2 { existing.subrole = subrole }
                    existing.titleDigest = peer.3
                    existing.ordinalAmongExactPeers = ordinal
                    if !existing.eligibilityResolved {
                        let observation = eligibilityObservation(of: peer.0,
                                                                 role: peer.1,
                                                                 subrole: peer.2,
                                                                 frame: peer.4)
                        // A minimized first observation is an ownership rule,
                        // not a transient readiness failure. Remember it even
                        // when role/frame/settable data is still incomplete.
                        existing.initiallyMinimized = existing.initiallyMinimized ||
                            observation.initiallyMinimized
                        if observation.complete {
                            existing.eligibilityResolved = true
                            existing.eligibleAtDiscovery = observation.eligible &&
                                !existing.initiallyMinimized
                        }
                    }
                    continue
                }
                let observation = eligibilityObservation(of: peer.0,
                                                         role: peer.1,
                                                         subrole: peer.2,
                                                         frame: peer.4)
                let entry = Entry(element: peer.0, pid: application.pid,
                                  bundleIdentifier: application.bundleIdentifier,
                                  role: peer.1 ?? "", subrole: peer.2 ?? "", titleDigest: peer.3,
                                  ordinalAmongExactPeers: ordinal,
                                  eligibleAtDiscovery: observation.eligible,
                                  eligibilityResolved: observation.complete,
                                  initiallyMinimized: observation.initiallyMinimized)
                insertEntry(entry)
            }
        }
        let dead = entries.values.filter { !validPIDs.contains($0.pid) }
        for entry in dead {
            pendingGoneTokens[entry.token] = entry.pid
            removeEntry(entry.token)
        }
    }

    private func insertEntry(_ entry: Entry) {
        entries[entry.token] = entry
        entriesByElement[ElementKey(entry.element)] = entry
    }

    @discardableResult
    private func removeEntry(_ token: WindowToken) -> Entry? {
        guard let entry = entries.removeValue(forKey: token) else { return nil }
        let key = ElementKey(entry.element)
        entriesByElement[key] = nil
        registeredElements.remove(key)
        return entry
    }

    private func registerWindowNotifications(_ window: AXUIElement, pid: pid_t) {
        let key = ElementKey(window)
        guard !registeredElements.contains(key), let item = observers[pid] else { return }
        let pointer = Unmanaged.passUnretained(item.bridge).toOpaque()
        var complete = true
        for notification in [kAXUIElementDestroyedNotification, kAXMovedNotification,
                             kAXResizedNotification, kAXWindowMiniaturizedNotification,
                             kAXWindowDeminiaturizedNotification, kAXTitleChangedNotification] {
            let error = AXObserverAddNotification(
                item.observer, window, notification as CFString, pointer)
            if error != .success && error != .notificationAlreadyRegistered {
                complete = false
            }
        }
        // A transient AX failure must remain retryable on the next discovery.
        // Calls that already succeeded return `notificationAlreadyRegistered`
        // and therefore do not block a later complete registration pass.
        if complete { registeredElements.insert(key) }
    }

    private func eligibilityObservation(of window: AXUIElement, role: String?, subrole: String?,
                                        frame: CGRect?) -> EligibilityObservation {
        let minimized = bool(window, kAXMinimizedAttribute)
        let positionSettable = settableObservation(window, kAXPositionAttribute)
        let sizeSettable = settableObservation(window, kAXSizeAttribute)
        let minimizedSettable = settableObservation(window, kAXMinimizedAttribute)
        let hasUsableFrame = frame.map { $0.width > 0 && $0.height > 0 } == true
        let fullScreen = fullScreenObservation(of: window)
        let complete = role != nil && subrole != nil && hasUsableFrame && minimized != nil &&
            fullScreen != nil && positionSettable != nil && sizeSettable != nil &&
            minimizedSettable != nil
        let eligible = role == kAXWindowRole as String &&
            subrole == kAXStandardWindowSubrole as String &&
            frame.map { candidateFrame in
                hasUsableFrame &&
                    screens.contains(where: { screen in screen.frame.intersects(candidateFrame) })
            } == true &&
            minimized == false && fullScreen == false &&
            positionSettable == true && sizeSettable == true && minimizedSettable == true
        return EligibilityObservation(eligible: eligible, complete: complete,
                                       initiallyMinimized: minimized == true)
    }

    private func settableObservation(_ element: AXUIElement, _ attribute: String) -> Bool? {
        var result = DarwinBoolean(false)
        let error = AXUIElementIsAttributeSettable(element, attribute as CFString, &result)
        guard error == .success else { return nil }
        return result.boolValue
    }

    /// Reads the frame and minimized flag of every retained entry once.  Both
    /// correlation and the snapshot output need them, so they must not be read
    /// twice per window per pass.
    private func liveObservations() -> [EntryObservation] {
        entries.values.map { entry in
            EntryObservation(entry: entry, frame: cocoaFrame(of: entry.element),
                             minimized: bool(entry.element, kAXMinimizedAttribute) == true)
        }
    }

    private func correlatedTokens(_ observations: [EntryObservation]) -> Set<WindowToken> {
        guard let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                    kCGNullWindowID) as? [[String: Any]] else { return [] }
        let candidates: [(pid: pid_t, frame: CGRect, title: String)] = info.compactMap { row in
            guard let pid = row[kCGWindowOwnerPID as String] as? NSNumber,
                  let bounds = row[kCGWindowBounds as String] as? [String: Any],
                  let cgFrame = CGRect(dictionaryRepresentation: bounds as CFDictionary)
            else { return nil }
            return (pid.int32Value, Coord.cocoaRect(fromAX: cgFrame, primaryMaxY: primaryMaxY),
                    row[kCGWindowName as String] as? String ?? "")
        }

        // Build a bipartite graph. A balanced component with a perfect
        // matching proves that all its AX entries are on the current Space,
        // even when same-frame CG titles make the individual pairing
        // ambiguous. Unbalanced components stay unreachable.
        let usable: [(entry: Entry, frame: CGRect)] = observations.compactMap { observation in
            guard let frame = observation.frame, !observation.minimized else { return nil }
            return (observation.entry, frame)
        }
        guard !usable.isEmpty, !candidates.isEmpty else { return [] }

        let edges: [[Int]] = usable.map { item in
            candidates.indices.filter { index in
                let candidate = candidates[index]
                guard candidate.pid == item.entry.pid,
                      approximately(candidate.frame, item.frame) else { return false }
                return candidate.title.isEmpty ||
                    Self.titleDigest(candidate.title) == item.entry.titleDigest
            }
        }
        guard edges.contains(where: { !$0.isEmpty }) else { return [] }

        let reachableIndices = WindowCorrelation.reachableEntryIndices(
            edges: edges, candidateCount: candidates.count)
        return Set(reachableIndices.map { usable[$0].entry.token })
    }

    private func focusedToken() -> WindowToken? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let appElement = tame(AXUIElementCreateApplication(app.processIdentifier))
        return focusedToken(in: appElement, pid: app.processIdentifier)
    }

    private func focusedToken(in applicationElement: AXUIElement, pid: pid_t) -> WindowToken? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(applicationElement,
                                             kAXFocusedWindowAttribute as CFString,
                                             &raw) == .success,
              let focused = AXExtract.element(raw) else { return nil }
        guard let entry = entriesByElement[ElementKey(focused)], entry.pid == pid else { return nil }
        return entry.token
    }

    private func restoreRecords(_ records: [RecoveryRecord], deadline: DispatchTime) -> TilesRecoveryResult {
        let generation = currentCancellationGeneration()
        let candidateEntries: [(candidate: RecoveryCandidate, entry: Entry)] = entries.values.compactMap { entry in
            guard let frame = cocoaFrame(of: entry.element) else { return nil }
            let candidate = RecoveryCandidate(bundleIdentifier: entry.bundleIdentifier,
                                              pid: entry.pid,
                                              role: entry.role,
                                              subrole: entry.subrole,
                                              titleDigest: entry.titleDigest,
                                              ordinalAmongExactPeers: entry.ordinalAmongExactPeers,
                                              frame: frame)
            return (candidate, entry)
        }
        let candidates = candidateEntries.map(\.candidate)
        var restored = Set<String>()
        for record in records {
            guard !isCancelled(generation), DispatchTime.now() < deadline,
                  case .unique(let index) = RecoveryModel.match(record: record, candidates: candidates),
                  candidateEntries.indices.contains(index) else { continue }
            // Keep the exact candidate-to-entry relationship selected by the
            // matcher.  Repeating a weaker dictionary lookup can select a
            // different window when peers share all fingerprint fields.
            let entry = candidateEntries[index].entry
            if record.stageIntent {
                guard setBool(false, on: entry.element, attribute: kAXMinimizedAttribute,
                              verify: true) == .success else { continue }
            }
            if let applied = record.lastAppliedFrame,
               let current = cocoaFrame(of: entry.element),
               RecoveryModel.compatibleFrame(current, with: applied),
               setFrame(record.adoptionFrame, on: entry.element) != .success {
                continue
            }
            restored.insert(record.identityKey)
        }
        return TilesRecoveryResult(restoredIdentityKeys: restored)
    }

    private func recoveryRecordUnlocked(for token: WindowToken, managed: ManagedWindow,
                                        stageIntent: Bool) -> RecoveryRecord? {
        guard let entry = entries[token] else { return nil }
        return RecoveryRecord(bundleIdentifier: entry.bundleIdentifier, pid: entry.pid,
                              role: entry.role, subrole: entry.subrole,
                              titleDigest: entry.titleDigest,
                              ordinalAmongExactPeers: entry.ordinalAmongExactPeers,
                              adoptionFrame: managed.adoptionFrame,
                              lastAppliedFrame: managed.lastAppliedFrame,
                              stageIntent: stageIntent)
    }

    private func setFrame(_ cocoa: CGRect, on window: AXUIElement) -> AXError {
        let ax = Coord.axRect(fromCocoa: cocoa, primaryMaxY: primaryMaxY)
        var size = ax.size
        var position = ax.origin
        guard let sizeValue = AXValueCreate(.cgSize, &size),
              let positionValue = AXValueCreate(.cgPoint, &position) else { return .failure }
        for (attribute, value) in [(kAXSizeAttribute, sizeValue),
                                   (kAXPositionAttribute, positionValue),
                                   (kAXSizeAttribute, sizeValue)] {
            let error = AXUIElementSetAttributeValue(window, attribute as CFString, value)
            guard error == .success else { return error }
        }
        guard let actual = cocoaFrame(of: window), approximately(actual, cocoa) else { return .failure }
        return .success
    }

    private func setBool(_ value: Bool, on element: AXUIElement, attribute: String,
                         verify: Bool) -> AXError {
        let error = AXUIElementSetAttributeValue(element, attribute as CFString,
                                                 value ? kCFBooleanTrue : kCFBooleanFalse)
        guard error == .success, !verify || bool(element, attribute) == value else {
            return error == .success ? .failure : error
        }
        return .success
    }

    private func result(_ effect: WindowEffect, from error: AXError) -> WindowEffectResult {
        switch error {
        case .success: return .success(effect)
        case .cannotComplete: return .failure(effect, .cannotComplete)
        case .invalidUIElement, .invalidUIElementObserver: return .failure(effect, .invalidElement)
        case .attributeUnsupported, .actionUnsupported, .notImplemented:
            return .failure(effect, .unsupportedAttribute)
        default: return .failure(effect, .rejectedFrame)
        }
    }

    private func tame(_ element: AXUIElement) -> AXUIElement {
        AXUIElementSetMessagingTimeout(element, 0.25)
        return element
    }

    private func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &raw) == .success else { return nil }
        return raw as? String
    }

    private func bool(_ element: AXUIElement, _ attribute: String) -> Bool? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &raw) == .success else { return nil }
        return raw as? Bool
    }

    /// Some standard windows do not expose `AXFullScreen`. That is an
    /// unsupported optional attribute, not evidence that the window is full
    /// screen. Other AX failures remain incomplete so discovery can retry.
    private func fullScreenObservation(of element: AXUIElement) -> Bool? {
        var raw: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, "AXFullScreen" as CFString, &raw)
        if error == .attributeUnsupported { return false }
        guard error == .success else { return nil }
        return raw as? Bool
    }

    private func cocoaFrame(of element: AXUIElement) -> CGRect? {
        var positionRaw: CFTypeRef?, sizeRaw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionRaw) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRaw) == .success,
              let position = AXExtract.point(positionRaw), let size = AXExtract.size(sizeRaw) else { return nil }
        return Coord.cocoaRect(fromAX: CGRect(origin: position, size: size),
                               primaryMaxY: primaryMaxY)
    }

    /// The primary display's top edge in Cocoa space, the pivot for every
    /// AX/Cocoa flip.  Zero without a known screen list keeps reads inert.
    private var primaryMaxY: CGFloat { screens.first?.frame.maxY ?? 0 }

    private func isSafeOnScreen(_ frame: CGRect) -> Bool {
        frame.origin.x.isFinite && frame.origin.y.isFinite &&
            frame.width.isFinite && frame.height.isFinite &&
            frame.width > 0 && frame.height > 0 &&
            screens.contains { $0.frame.intersects(frame) }
    }

    private func approximately(_ lhs: CGRect, _ rhs: CGRect, tolerance: CGFloat = 4) -> Bool {
        RecoveryModel.compatibleFrame(lhs, with: rhs, tolerance: tolerance)
    }

    private static func titleDigest(_ title: String) -> String {
        SHA256.hash(data: Data(title.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func currentCancellationGeneration() -> UInt64 {
        cancellationLock.lock()
        defer { cancellationLock.unlock() }
        return cancellationGeneration
    }

    private func isCancelled(_ generation: UInt64) -> Bool {
        currentCancellationGeneration() != generation
    }
}

enum AXWindowSystemError: LocalizedError {
    case accessibilityDenied

    var errorDescription: String? {
        "Accessibility access is required before Tiles can start."
    }
}

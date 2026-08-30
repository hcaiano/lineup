import AppKit
import ApplicationServices
import CryptoKit
import Foundation
import TilesCore
import ZonesCore

enum SnapshotScope: Sendable {
    case all
    case pid(pid_t)
    case tokens(Set<WindowToken>)
}

enum WindowSystemEvent: Sendable {
    case applicationChanged(pid_t)
    case applicationActivated(pid_t)
    case externalActivation(WindowToken)
    case windowCreated(pid_t)
    case windowChanged(WindowToken)
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

    private let queue = DispatchQueue(label: "com.caiano.lineup.tiles.ax", qos: .userInitiated)
    private let ownPID = ProcessInfo.processInfo.processIdentifier
    private var entries: [WindowToken: Entry] = [:]
    private var pendingGoneTokens: [WindowToken: pid_t] = [:]
    private var observers: [pid_t: ObserverEntry] = [:]
    private var workspaceObservers: [NSObjectProtocol] = []
    private var screens: [LiveScreen] = []
    private var receive: (@Sendable (WindowSystemEvent) -> Void)?
    private var acceptingEvents = false
    private let cancellationLock = NSLock()
    private var cancellationGeneration: UInt64 = 0

    func updateScreens(_ screens: [LiveScreen]) {
        queue.sync { self.screens = screens }
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
        return queue.sync {
            for application in applications { self.installObserver(for: application) }
            self.discover(applications: applications)
        }
    }

    func snapshot(_ scope: SnapshotScope) -> WindowSnapshot {
        let generation = currentCancellationGeneration()
        return queue.sync {
            let applications = Self.regularApplications(NSWorkspace.shared.runningApplications,
                                                        excluding: ownPID)
            discover(applications: applications, cancellationGeneration: generation)
            let selected: [Entry]
            let gone: Set<WindowToken>
            let consumesGone: Bool
            switch scope {
            case .all:
                selected = Array(entries.values)
                gone = Set(pendingGoneTokens.keys)
                consumesGone = true
            case .pid(let pid):
                selected = entries.values.filter { $0.pid == pid }
                gone = Set(pendingGoneTokens.compactMap { $0.value == pid ? $0.key : nil })
                consumesGone = false
            case .tokens(let tokens):
                selected = tokens.compactMap { entries[$0] }
                gone = Set(pendingGoneTokens.keys).intersection(tokens)
                consumesGone = false
            }
            if consumesGone {
                for token in gone { pendingGoneTokens[token] = nil }
            }
            // Correlate against every retained AX entry, not only the requested
            // snapshot scope.  A scoped snapshot must not make two windows
            // sharing a frame look uniquely correlated simply because one peer
            // was omitted from the output.
            let correlated = correlatedTokens(entries: Array(entries.values))
            var output: [WindowToken: WindowSnapshotEntry] = [:]
            for entry in selected {
                guard let frame = cocoaFrame(of: entry.element) else { continue }
                let minimized = bool(entry.element, kAXMinimizedAttribute) ?? false
                let screenKey = bestScreen(for: frame)?.key ?? ""
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
            var correlated = correlatedTokens(entries: Array(entries.values))
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
                            correlated = correlatedTokens(entries: Array(entries.values))
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
        queue.sync { entries.values.first(where: { CFEqual($0.element, element) })?.token }
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
            guard let entry = entries[token] else { return nil }
            return RecoveryRecord(bundleIdentifier: entry.bundleIdentifier, pid: entry.pid,
                                  role: entry.role, subrole: entry.subrole,
                                  titleDigest: entry.titleDigest,
                                  ordinalAmongExactPeers: entry.ordinalAmongExactPeers,
                                  adoptionFrame: managed.adoptionFrame,
                                  lastAppliedFrame: managed.lastAppliedFrame,
                                  stageIntent: stageIntent)
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
            pendingGoneTokens.removeAll()
            receive = nil
        }
    }

    fileprivate func receivedAXNotification(pid: pid_t, element: AXUIElement, notification: String) {
        queue.async { [weak self] in
            guard let self, self.acceptingEvents else { return }
            let token = self.entries.values.first(where: { CFEqual($0.element, element) })?.token
            switch notification {
            case kAXWindowCreatedNotification:
                self.emit(.windowCreated(pid))
            case kAXUIElementDestroyedNotification:
                if let token {
                    self.entries[token] = nil
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
                if let token { self.emit(.windowChanged(token)) }
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
                self.entries[token] = nil
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

    private func discover(applications: [ApplicationDescriptor]) {
        discover(applications: applications, cancellationGeneration: nil)
    }

    private func discover(applications: [ApplicationDescriptor],
                          cancellationGeneration: UInt64?) {
        let validPIDs = Set(applications.map(\.pid))
        for application in applications {
            if let cancellationGeneration, isCancelled(cancellationGeneration) { return }
            installObserver(for: application)
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
            let disappeared = entries.values.filter { entry in
                entry.pid == application.pid && !peers.contains(where: { CFEqual($0.0, entry.element) })
            }.map(\.token)
            for token in disappeared {
                pendingGoneTokens[token] = application.pid
                entries[token] = nil
            }
            var ordinalByFingerprint: [String: Int] = [:]
            for peer in peers {
                registerWindowNotifications(peer.0, pid: application.pid)
                let key = [peer.1 ?? "", peer.2 ?? "", peer.3].joined(separator: "\u{1f}")
                let ordinal = ordinalByFingerprint[key, default: 0]
                ordinalByFingerprint[key] = ordinal + 1
                if let existing = entries.values.first(where: { CFEqual($0.element, peer.0) }) {
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
                entries[entry.token] = entry
            }
        }
        let dead = entries.values.filter { !validPIDs.contains($0.pid) }.map(\.token)
        for token in dead { entries[token] = nil }
    }

    private func registerWindowNotifications(_ window: AXUIElement, pid: pid_t) {
        guard let item = observers[pid] else { return }
        let pointer = Unmanaged.passUnretained(item.bridge).toOpaque()
        for notification in [kAXUIElementDestroyedNotification, kAXMovedNotification,
                             kAXResizedNotification, kAXWindowMiniaturizedNotification,
                             kAXWindowDeminiaturizedNotification, kAXTitleChangedNotification] {
            _ = AXObserverAddNotification(item.observer, window, notification as CFString, pointer)
        }
    }

    private func eligibilityObservation(of window: AXUIElement, role: String?, subrole: String?,
                                        frame: CGRect?) -> EligibilityObservation {
        let minimized = bool(window, kAXMinimizedAttribute)
        let positionSettable = settableObservation(window, kAXPositionAttribute)
        let sizeSettable = settableObservation(window, kAXSizeAttribute)
        let minimizedSettable = settableObservation(window, kAXMinimizedAttribute)
        let hasUsableFrame = frame.map { $0.width > 0 && $0.height > 0 } == true
        let complete = role != nil && subrole != nil && hasUsableFrame && minimized != nil &&
            positionSettable != nil && sizeSettable != nil && minimizedSettable != nil
        let eligible = role == kAXWindowRole as String &&
            subrole == kAXStandardWindowSubrole as String &&
            frame.map { candidateFrame in
                hasUsableFrame &&
                    screens.contains(where: { screen in screen.frame.intersects(candidateFrame) })
            } == true &&
            minimized == false && bool(window, "AXFullScreen") != true &&
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

    private func eligibility(of window: AXUIElement, role: String, subrole: String,
                             frame: CGRect?) -> Bool {
        eligibilityObservation(of: window, role: role, subrole: subrole, frame: frame).eligible
    }

    private func correlatedTokens(entries selected: [Entry]) -> Set<WindowToken> {
        guard let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                    kCGNullWindowID) as? [[String: Any]] else { return [] }
        let candidates: [(pid: pid_t, frame: CGRect, title: String, windowID: UInt32)] = info.compactMap { row in
            guard let pid = row[kCGWindowOwnerPID as String] as? NSNumber,
                  let bounds = row[kCGWindowBounds as String] as? [String: Any],
                  let cgFrame = CGRect(dictionaryRepresentation: bounds as CFDictionary)
            else { return nil }
            return (pid.int32Value, cocoaRect(fromTopLeft: cgFrame),
                    row[kCGWindowName as String] as? String ?? "",
                    (row[kCGWindowNumber as String] as? NSNumber)?.uint32Value ?? 0)
        }

        // Build a bipartite graph and assign candidates collectively.  The
        // old per-entry `matches.count == 1` rule rejected every AX window
        // when macOS returned several same-frame windows with empty CG titles.
        // A candidate can still be consumed only once, so two AX entries are
        // never correlated to one CG window.
        let usable: [(entry: Entry, frame: CGRect)] = selected.compactMap { entry in
            guard let frame = cocoaFrame(of: entry.element),
                  bool(entry.element, kAXMinimizedAttribute) != true else { return nil }
            return (entry, frame)
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

        // Stable ordering makes the fallback deterministic when all titles are
        // empty.  The candidate order is the public CG order with window ID as
        // a tie-breaker; an AX token is runtime-only, so UUID order is the
        // stable tie-breaker for the retained entries.
        let entryOrder = usable.indices.sorted { lhs, rhs in
            if edges[lhs].count != edges[rhs].count {
                return edges[lhs].count < edges[rhs].count
            }
            return usable[lhs].entry.token.rawValue.uuidString <
                usable[rhs].entry.token.rawValue.uuidString
        }
        let candidateOrder = candidates.indices.sorted { lhs, rhs in
            let left = candidates[lhs], right = candidates[rhs]
            if left.pid != right.pid { return left.pid < right.pid }
            if left.frame.minX != right.frame.minX { return left.frame.minX < right.frame.minX }
            if left.frame.minY != right.frame.minY { return left.frame.minY < right.frame.minY }
            if left.frame.width != right.frame.width { return left.frame.width < right.frame.width }
            if left.frame.height != right.frame.height { return left.frame.height < right.frame.height }
            if left.title != right.title { return left.title < right.title }
            return left.windowID < right.windowID
        }

        var candidateToEntry = Array(repeating: -1, count: candidates.count)
        func assign(_ entryIndex: Int, _ visited: inout Set<Int>) -> Bool {
            let orderedEdges = edges[entryIndex].sorted {
                candidateOrder.firstIndex(of: $0)! < candidateOrder.firstIndex(of: $1)!
            }
            for candidateIndex in orderedEdges where visited.insert(candidateIndex).inserted {
                if candidateToEntry[candidateIndex] == -1 ||
                    assign(candidateToEntry[candidateIndex], &visited) {
                    candidateToEntry[candidateIndex] = entryIndex
                    return true
                }
            }
            return false
        }
        for entryIndex in entryOrder {
            var visited = Set<Int>()
            _ = assign(entryIndex, &visited)
        }

        var result = Set<WindowToken>()
        for (candidateIndex, entryIndex) in candidateToEntry.enumerated()
            where entryIndex >= 0 {
            _ = candidateIndex
            result.insert(usable[entryIndex].entry.token)
        }
        return result
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
        return entries.values.first(where: {
            $0.pid == pid && CFEqual($0.element, focused)
        })?.token
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
        let ax = axRect(fromCocoa: cocoa)
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

    private func isSettable(_ element: AXUIElement, _ attribute: String) -> Bool {
        var result = DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(element, attribute as CFString, &result) == .success
            && result.boolValue
    }

    private func cocoaFrame(of element: AXUIElement) -> CGRect? {
        var positionRaw: CFTypeRef?, sizeRaw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionRaw) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRaw) == .success,
              let position = AXExtract.point(positionRaw), let size = AXExtract.size(sizeRaw) else { return nil }
        return cocoaRect(fromTopLeft: CGRect(origin: position, size: size))
    }

    private func cocoaRect(fromTopLeft rect: CGRect) -> CGRect {
        let primaryMaxY = screens.first?.frame.maxY ?? 0
        return CGRect(x: rect.minX, y: primaryMaxY - rect.maxY,
                      width: rect.width, height: rect.height)
    }

    private func axRect(fromCocoa rect: CGRect) -> CGRect {
        let primaryMaxY = screens.first?.frame.maxY ?? 0
        return CGRect(x: rect.minX, y: primaryMaxY - rect.maxY,
                      width: rect.width, height: rect.height)
    }

    private func bestScreen(for frame: CGRect) -> LiveScreen? {
        screens.max { lhs, rhs in
            intersectionArea(lhs.frame, frame) < intersectionArea(rhs.frame, frame)
        }
    }

    private func isSafeOnScreen(_ frame: CGRect) -> Bool {
        frame.origin.x.isFinite && frame.origin.y.isFinite &&
            frame.width.isFinite && frame.height.isFinite &&
            frame.width > 0 && frame.height > 0 &&
            screens.contains { $0.frame.intersects(frame) }
    }

    private func intersectionArea(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        let intersection = lhs.intersection(rhs)
        return intersection.isNull ? 0 : intersection.width * intersection.height
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

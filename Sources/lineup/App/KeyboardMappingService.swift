import AppCore
import AppKit
import Darwin
import Foundation
import IOKit
import IOKit.hid
import IOKit.hidsystem
import KeyboardRemapCore
import os

/// The sole writer of UserKeyMapping. A tool contributes rules; it never replaces a keyboard's
/// table itself. IOKit work and the recovery journal share one serial queue.
@MainActor
final class KeyboardMappingService {
    static let shared = KeyboardMappingService()

    private(set) var devices: [KeyboardDevice] = []
    private(set) var remapStatus: String?
    private(set) var hyperkeyStatus: String?
    private(set) var recoveryStatus: String?
    private(set) var remapDeviceStatuses: [UInt64: String] = [:]
    private(set) var appliedRemapDeviceIDs: Set<UInt64> = []
    private(set) var hyperkeyReady = false
    private(set) var hyperkeyRequested = false

    private let backend = KeyboardMappingBackend()
    private let readOnly: Bool
    private var legacyClaimRequested = false
    private(set) var capsLockRecoveryPending = false

    init(readOnly: Bool = false) { self.readOnly = readOnly }
    private var rules: [KeyboardRuleSet] = []
    private var remapEnabled = false
    private var observers: [UUID: () -> Void] = [:]
    private var wakeObserver: NSObjectProtocol?
    private var pollTimer: Timer?
    private var started = false
    private var generation = 0
    private var refreshQueue = KeyboardMappingRefreshQueue()
    private var reconciliationPending = false

    func observe(_ callback: @escaping () -> Void) -> UUID {
        let id = UUID()
        observers[id] = callback
        return id
    }

    func removeObserver(_ id: UUID) { observers.removeValue(forKey: id) }

    func start() {
        guard !started else { return }
        started = true
        refreshLegacyClaimRequest()
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.started else { return }
                self.refresh()
            }
        }
        updatePolling()
        refresh()
    }

    func setKeyboardRemap(_ rules: [KeyboardRuleSet], enabled: Bool) {
        start()
        self.rules = rules
        remapEnabled = enabled
        generation += 1
        enqueue()
    }

    func setHyperkeyEnabled(_ enabled: Bool, completion: @escaping (String?) -> Void) {
        start()
        hyperkeyRequested = enabled
        hyperkeyReady = false
        generation += 1
        enqueue { snapshot in completion(snapshot.hyperkeyStatus) }
    }

    func refresh() {
        guard started else { start(); return }
        guard let requestID = refreshQueue.request() else { return }
        enqueueRefresh(requestID)
    }

    private func enqueueRefresh(_ requestID: UInt64) {
        enqueue { [weak self] _ in
            guard let self else { return }
            if let next = self.refreshQueue.complete(requestID, started: self.started) {
                self.enqueueRefresh(next)
            }
        }
    }

    func retry() { refresh() }

    func shutdown() {
        // A duplicate app exits before start(). It must not reconcile the active app's journal.
        guard started else { return }
        pollTimer?.invalidate()
        pollTimer = nil
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        wakeObserver = nil
        started = false
        refreshQueue.stop()
        remapEnabled = false
        hyperkeyRequested = false
        hyperkeyReady = false
        generation += 1
        enqueue()
    }

    /// Recovery is limited to journaled pairs. It cannot clear a same-shaped user-owned remap.
    func restoreOwnedCapsLock(completion: @escaping (Bool) -> Void) {
        start()
        // A legacy provider may have exited since startup. Recheck its explicit claim before
        // migrating ownership into the journal and releasing the owned pair.
        refreshLegacyClaimRequest()
        reconciliationPending = !readOnly
        updatePolling()
        let request = KeyboardMappingRequest(rules: remapEnabled ? rules : [], hyperkey: false, legacyClaim: legacyClaimRequested)
        let token = generation
        if !readOnly { backend.armExitCleanup() }
        let onlyInventory = readOnly
        backend.queue.async { [backend, weak self] in
            let snapshot = onlyInventory ? backend.inventorySnapshot() : backend.reconcile(request)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if token == self.generation { self.accept(snapshot) }
                completion(!snapshot.capsLockRecoveryPending && snapshot.remapStatus == nil)
            }
        }
    }

    private func refreshLegacyClaimRequest() {
        // A matching pair without an ownership flag stays external. Live providers retain it.
        legacyClaimRequested = !readOnly && SingleInstance.standaloneCyclerIsRunning() == nil
            && !HyperKeyController.raycastCapsHyperEnabled()
            && (UserDefaults.standard.bool(forKey: CapsLockHandoff.newKey)
                || (UserDefaults(suiteName: CapsLockHandoff.legacySuite)?.bool(forKey: CapsLockHandoff.legacyKey) ?? false))
    }

    private func updatePolling() {
        let needed = KeyboardMappingMaintenance.requiresPolling(started: started, readOnly: readOnly,
            rules: rules, remapEnabled: remapEnabled, hyperkeyRequested: hyperkeyRequested,
            legacyClaimRequested: legacyClaimRequested, reconciliationPending: reconciliationPending,
            recoveryPending: recoveryStatus != nil || capsLockRecoveryPending)
        guard needed else {
            pollTimer?.invalidate()
            pollTimer = nil
            return
        }
        guard pollTimer == nil else { return }
        // Reconnects can create a new RegistryID. Work stays on the backend's serial queue.
        let timer = Timer(timeInterval: 3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.started else { return }
                self.refresh()
            }
        }
        timer.tolerance = 0.5
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    private func enqueue(completion: ((KeyboardMappingSnapshot) -> Void)? = nil) {
        reconciliationPending = !readOnly
        updatePolling()
        let request = KeyboardMappingRequest(rules: remapEnabled ? rules : [], hyperkey: hyperkeyRequested, legacyClaim: legacyClaimRequested)
        let token = generation
        if !readOnly { backend.armExitCleanup() }
        let onlyInventory = readOnly
        backend.queue.async { [backend, weak self] in
            let snapshot = onlyInventory ? backend.inventorySnapshot() : backend.reconcile(request)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if token == self.generation { self.accept(snapshot) }
                completion?(snapshot)
            }
        }
    }

    private func accept(_ snapshot: KeyboardMappingSnapshot) {
        reconciliationPending = false
        let changed = devices != snapshot.devices || remapStatus != snapshot.remapStatus
            || hyperkeyStatus != snapshot.hyperkeyStatus || hyperkeyReady != snapshot.hyperkeyReady
            || remapDeviceStatuses != snapshot.deviceStatuses || appliedRemapDeviceIDs != snapshot.applied
            || capsLockRecoveryPending != snapshot.capsLockRecoveryPending || recoveryStatus != snapshot.recoveryStatus
        devices = snapshot.devices
        remapStatus = snapshot.remapStatus
        hyperkeyStatus = snapshot.hyperkeyStatus
        recoveryStatus = snapshot.recoveryStatus
        hyperkeyReady = snapshot.hyperkeyReady
        remapDeviceStatuses = snapshot.deviceStatuses
        appliedRemapDeviceIDs = snapshot.applied
        capsLockRecoveryPending = snapshot.capsLockRecoveryPending
        if snapshot.legacyTransferred && legacyClaimRequested {
            legacyClaimRequested = false
            UserDefaults.standard.removeObject(forKey: CapsLockHandoff.newKey)
            UserDefaults(suiteName: CapsLockHandoff.legacySuite)?.removeObject(forKey: CapsLockHandoff.legacyKey)
        }
        updatePolling()
        if changed { for callback in Array(observers.values) { callback() } }
    }
}

private struct KeyboardMappingRequest {
    var rules: [KeyboardRuleSet]
    var hyperkey: Bool
    var legacyClaim = false
}

private struct KeyboardMappingSnapshot {
    var devices: [KeyboardDevice] = []
    var remapStatus: String?
    var hyperkeyStatus: String?
    var recoveryStatus: String?
    var hyperkeyReady = false
    var deviceStatuses: [UInt64: String] = [:]
    var applied: Set<UInt64> = []
    var legacyTransferred = false
    var capsLockRecoveryPending = false
}

private final class KeyboardMappingBackend: @unchecked Sendable {
    let queue = DispatchQueue(label: Product.bundleID + ".keyboard-mappings", qos: .utility)
    private let journalURL = Product.configDirectory.appendingPathComponent("keyboard-mappings-recovery.json")
    private let bootSession = KeyboardMappingBackend.currentBootSession()
    private let log = Logger(subsystem: Product.logSubsystem, category: "keyboard-mappings")
    private var client: IOHIDEventSystemClient?
    private var journal: KeyboardMappingJournal?
    private let legacyClaimTransfer = KeyboardLegacyClaimTransfer()
    private static let exitLock = NSLock()
    private static var exitBackend: KeyboardMappingBackend?

    func armExitCleanup() {
        Self.exitLock.lock()
        let install = Self.exitBackend == nil
        Self.exitBackend = self
        Self.exitLock.unlock()
        if install {
            atexit {
                KeyboardMappingBackend.exitLock.lock()
                let backend = KeyboardMappingBackend.exitBackend
                KeyboardMappingBackend.exitLock.unlock()
                guard let backend else { return }
                let drained = DispatchSemaphore(value: 0)
                backend.queue.async {
                    _ = backend.reconcile(KeyboardMappingRequest(rules: [], hyperkey: false))
                    drained.signal()
                }
                // A HID or filesystem failure must never prevent the process from exiting.
                _ = drained.wait(timeout: .now() + .seconds(3))
            }
        }
    }

    func reconcile(_ request: KeyboardMappingRequest) -> KeyboardMappingSnapshot {
        var result = KeyboardMappingSnapshot()
        do {
            let services = try inventory()
            result.devices = services.map(\.device).sorted {
                if $0.isBuiltIn != $1.isBuiltIn { return $0.isBuiltIn }
                if $0.product != $1.product { return $0.product.localizedStandardCompare($1.product) == .orderedAscending }
                return $0.registryID < $1.registryID
            }
            try loadJournal()
            let servicesByID = Dictionary(uniqueKeysWithValues: services.map { ($0.device.registryID, $0.client) })
            result.legacyTransferred = try legacyClaimTransfer.transfer(requested: request.legacyClaim,
                mapping: Self.capsLockPair, registryIDs: services.map { $0.device.registryID },
                journal: journal!, read: { id in try self.read(servicesByID[id]!) }, record: save)

            let selection = KeyboardRuleSelection(rules: request.rules, devices: result.devices)
            let deviceRules = selection.mappings
            result.deviceStatuses = selection.deviceErrors
            result.remapStatus = selection.status

            let selectionStatus = result.remapStatus
            var tables: [UInt64: [KeyMapping]] = [:]
            var plans: [UInt64: KeyboardMappingPlan] = [:]
            var hyperkeyBlocked = false
            for service in services {
                let id = service.device.registryID
                do {
                    let current = try read(service.client)
                    tables[id] = current
                    let resolution = try KeyboardMappingPlanner.resolve(
                        current: current, owned: journal!.mappings(for: id),
                        hyperkey: request.hyperkey ? Self.capsLockPair : nil,
                        remappings: deviceRules[id] ?? [])
                    plans[id] = resolution.plan
                    if let error = resolution.hyperkeyError {
                        result.hyperkeyStatus = "\(service.device.product): \(error.localizedDescription)"
                        hyperkeyBlocked = true
                    }
                    if let error = resolution.remapError, deviceRules[id] != nil {
                        result.deviceStatuses[id] = "\(service.device.product): \(error.localizedDescription)"
                    }
                } catch {
                    let message = "\(service.device.product): \(error.localizedDescription)"
                    if request.hyperkey { result.hyperkeyStatus = message; hyperkeyBlocked = true }
                    if deviceRules[id] != nil || !journal!.mappings(for: id).isEmpty {
                        result.deviceStatuses[id] = message
                    }
                }
            }
            if hyperkeyBlocked {
                // Hyperkey's event tap is global. Keep its remap off every keyboard while any
                // keyboard blocks it, preserving every independently applicable remap rule.
                for service in services {
                    let id = service.device.registryID
                    guard let current = tables[id] else { continue }
                    let resolution = try KeyboardMappingPlanner.resolve(current: current,
                        owned: journal!.mappings(for: id), hyperkey: nil,
                        remappings: deviceRules[id] ?? [])
                    plans[id] = resolution.plan
                    if let error = resolution.remapError, deviceRules[id] != nil {
                        result.deviceStatuses[id] = "\(service.device.product): \(error.localizedDescription)"
                    } else if deviceRules[id] != nil {
                        result.deviceStatuses.removeValue(forKey: id)
                    }
                }
            }
            var rollbackNeeded = false

            for service in services {
                let id = service.device.registryID
                guard let plan = plans[id], let current = tables[id] else { continue }
                do {
                    try apply(plan, current: current, service: service.client, registryID: id)
                    if deviceRules[id] != nil, result.deviceStatuses[id] == nil {
                        result.applied.insert(id)
                        result.deviceStatuses[id] = "Applied"
                    }
                } catch {
                    let message = "\(service.device.product): \(error.localizedDescription)"
                    result.deviceStatuses[id] = message
                    result.remapStatus = message
                    if request.hyperkey {
                        result.hyperkeyStatus = message
                        hyperkeyBlocked = true
                        rollbackNeeded = true
                    }
                    log.error("keyboard mapping failed: \(message, privacy: .public)")
                }
            }
            if rollbackNeeded {
                // A later keyboard can fail after an earlier one applied successfully. Roll the
                // Hyperkey contribution back immediately, keeping each keyboard's remap rules.
                // An unreadable or failing service retains its journal claim for the next retry.
                for service in services {
                    let id = service.device.registryID
                    do {
                        let current = try read(service.client)
                        let resolution = try KeyboardMappingPlanner.resolve(current: current,
                            owned: journal!.mappings(for: id), hyperkey: nil,
                            remappings: deviceRules[id] ?? [])
                        try apply(resolution.plan, current: current, service: service.client, registryID: id)
                        if let error = resolution.remapError, deviceRules[id] != nil {
                            result.deviceStatuses[id] = "\(service.device.product): \(error.localizedDescription)"
                            result.applied.remove(id)
                        } else if deviceRules[id] != nil {
                            result.deviceStatuses[id] = "Applied"
                            result.applied.insert(id)
                        }
                    } catch {
                        let message = "\(service.device.product): \(error.localizedDescription)"
                        result.deviceStatuses[id] = message
                        result.remapStatus = message
                        result.applied.remove(id)
                    }
                }
            }
            result.remapStatus = result.deviceStatuses.keys.sorted().compactMap { id in
                let status = result.deviceStatuses[id]
                return status == "Applied" ? nil : status
            }.first ?? selectionStatus
            // Removed HID services cannot retain a mapping. RegistryIDs are scoped to one boot;
            // reconnecting creates a new service, which gets composed from the saved selector.
            let connected = Set(services.map { $0.device.registryID })
            var trimmed = journal!
            trimmed.entries.removeAll { !connected.contains($0.registryID) }
            if trimmed != journal! { try save(trimmed) }
            let staleOwnership = journal!.entries.contains { entry in
                let desired = (deviceRules[entry.registryID] ?? [])
                    + (request.hyperkey ? [Self.capsLockPair] : [])
                return entry.mappings.contains { !desired.contains($0) }
            }
            if staleOwnership {
                result.recoveryStatus = result.remapStatus ?? result.hyperkeyStatus
                    ?? "Lineup could not release previous keyboard mappings. Retry to recover them."
            }
            if request.hyperkey, services.isEmpty {
                result.hyperkeyStatus = "No keyboard is connected. Hyperkey will retry when a keyboard appears."
            }
            result.hyperkeyReady = request.hyperkey && !hyperkeyBlocked && !services.isEmpty
        } catch {
            let message = "Keyboard maps could not be recovered: \(error.localizedDescription). Retry after resolving the error."
            result.remapStatus = message
            result.recoveryStatus = message
            if request.hyperkey { result.hyperkeyStatus = message }
            log.error("keyboard mapping recovery failed: \(message, privacy: .public)")
        }
        let pendingLegacyClaim = request.legacyClaim && !result.legacyTransferred
        let pendingOwnedCapsLock = !request.rules.flatMap(\.mappings).contains(Self.capsLockPair)
            && (journal?.entries.contains { $0.mappings.contains(Self.capsLockPair) } ?? false)
        result.capsLockRecoveryPending = !request.hyperkey && (pendingLegacyClaim || pendingOwnedCapsLock)
        return result
    }

    func inventorySnapshot() -> KeyboardMappingSnapshot {
        var snapshot = KeyboardMappingSnapshot()
        do { snapshot.devices = try inventory().map(\.device) }
        catch { snapshot.remapStatus = error.localizedDescription }
        return snapshot
    }

    private struct Service {
        let client: IOHIDServiceClient
        let device: KeyboardDevice
    }

    private func inventory() throws -> [Service] {
        if client == nil { client = IOHIDEventSystemClientCreateSimpleClient(kCFAllocatorDefault) }
        guard let client, let raw = IOHIDEventSystemClientCopyServices(client) else {
            throw MappingFailure("The HID keyboard inventory could not be read")
        }
        guard let all = raw as? [IOHIDServiceClient] else { throw MappingFailure("The HID keyboard inventory is unreadable") }
        return try all.filter {
            IOHIDServiceClientConformsTo($0, UInt32(kHIDPage_GenericDesktop), UInt32(kHIDUsage_GD_Keyboard)) != 0
        }.map { service in
            guard let number = IOHIDServiceClientGetRegistryID(service) as? NSNumber else {
                throw MappingFailure("A keyboard has no registry identity")
            }
            let id = number.uint64Value
            let registry = IOServiceGetMatchingService(kIOMainPortDefault, IORegistryEntryIDMatching(id))
            defer { if registry != 0 { IOObjectRelease(registry) } }
            func property(_ key: String) -> Any? {
                if let value = IOHIDServiceClientCopyProperty(service, key as CFString) { return value }
                guard registry != 0 else { return nil }
                return IORegistryEntrySearchCFProperty(registry, kIOServicePlane, key as CFString,
                    kCFAllocatorDefault, IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents))
            }
            let device = KeyboardDevice(registryID: id,
                product: property(kIOHIDProductKey) as? String ?? "Keyboard",
                vendorID: (property(kIOHIDVendorIDKey) as? NSNumber)?.intValue,
                productID: (property(kIOHIDProductIDKey) as? NSNumber)?.intValue,
                locationID: (property(kIOHIDLocationIDKey) as? NSNumber)?.intValue,
                serialNumber: property(kIOHIDSerialNumberKey) as? String,
                transport: property(kIOHIDTransportKey) as? String,
                isBuiltIn: (property(kIOHIDBuiltInKey) as? NSNumber)?.boolValue ?? false)
            return Service(client: service, device: device)
        }
    }

    private func read(_ service: IOHIDServiceClient) throws -> [KeyMapping] {
        try HIDMappingTable.parse(IOHIDServiceClientCopyProperty(service, "UserKeyMapping" as CFString))
    }

    private func apply(_ plan: KeyboardMappingPlan, current: [KeyMapping], service: IOHIDServiceClient, registryID: UInt64) throws {
        try KeyboardMappingTransaction.apply(current: current,
            owned: journal!.mappings(for: registryID), plan: plan,
            read: { try self.read(service) },
            write: { mappings in
                let property = HIDMappingTable.propertyList(mappings) as CFArray
                guard IOHIDServiceClientSetProperty(service, "UserKeyMapping" as CFString, property) else {
                    throw MappingFailure("macOS refused to apply the keyboard map")
                }
            },
            record: { owned in
                guard Set(self.journal!.mappings(for: registryID)) != Set(owned) else { return }
                var pending = self.journal!
                pending.setMappings(owned, for: registryID)
                if pending != self.journal! { try self.save(pending) }
            })
    }

    private func loadJournal() throws {
        guard let bootSession else { throw MappingFailure("The system boot identity could not be read") }
        guard journal == nil else { return }
        if !FileManager.default.fileExists(atPath: journalURL.path) {
            journal = KeyboardMappingJournal(bootSession: bootSession)
            return
        }
        let decoded = try JSONDecoder().decode(KeyboardMappingJournal.self, from: Data(contentsOf: journalURL))
        guard decoded.version == 1 else { throw MappingFailure("The keyboard recovery file was created by a newer version of Lineup") }
        if decoded.bootSession == bootSession {
            journal = decoded
        } else {
            // The kernel drops HID maps on reboot. An old RegistryID must never authorize a write
            // in a new boot, even if its number happens to be reused.
            let empty = KeyboardMappingJournal(bootSession: bootSession)
            try save(empty)
        }
    }

    private func save(_ value: KeyboardMappingJournal) throws {
        try FileManager.default.createDirectory(at: journalURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(value).write(to: journalURL, options: .atomic)
        journal = value
    }

    private static let capsLockPair = KeyMapping(source: 0x700000039, destination: 0x70000006D)
    private static func currentBootSession() -> String? {
        var size = 0
        guard sysctlbyname("kern.bootsessionuuid", nil, &size, nil, 0) == 0, size > 1 else { return nil }
        var bytes = [CChar](repeating: 0, count: size)
        guard sysctlbyname("kern.bootsessionuuid", &bytes, &size, nil, 0) == 0 else { return nil }
        return String(cString: bytes)
    }
}

private struct MappingFailure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

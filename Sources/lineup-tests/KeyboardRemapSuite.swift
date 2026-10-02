import Foundation
import KeyboardRemapCore

func runKeyboardRemapTests() throws {
    try runKeyboardSelectionTests()
    try runKeyboardCompositionTests()
    try runKeyboardConflictResolutionTests()
    try runKeyboardTableTests()
    try runKeyboardJournalTests()
    try runKeyboardTransactionTests()
    runKeyboardMaintenanceTests()
    runKeyboardRefreshQueueTests()
    runKeyboardRuleSelectionTests()
    try runLegacyClaimTransferTests()
}

private let isoToGrave = KeyMapping(source: 0x700000064, destination: 0x700000035)
private let graveToISO = KeyMapping(source: 0x700000035, destination: 0x700000064)
private let capsToF18 = KeyMapping(source: 0x700000039, destination: 0x70000006D)
private let externalMapping = KeyMapping(source: 0xC000000E9, destination: 0xC000000EA)

private func runKeyboardMaintenanceTests() {
    let saved = [KeyboardRuleSet(selector: .builtIn, mappings: [isoToGrave])]
    let empty = [KeyboardRuleSet(selector: .builtIn, mappings: [])]
    let cases: [(String, Bool, Bool, [KeyboardRuleSet], Bool, Bool, Bool, Bool, Bool, Bool)] = [
        ("idle tools suspend periodic keyboard reads after initial reconciliation", true, false, saved, false, false, false, false, false, false),
        ("an enabled tool with no mappings leaves periodic keyboard reads suspended", true, false, empty, true, false, false, false, false, false),
        ("saved active mappings keep reconnect detection running even without a connected keyboard", true, false, saved, true, false, false, false, false, true),
        ("requested Hyperkey keeps keyboard inventory active", true, false, [], false, true, false, false, false, true),
        ("an unacknowledged legacy claim keeps recovery active", true, false, [], false, false, true, false, false, true),
        ("disabling the last contributor waits for its queued cleanup before suspending", true, false, [], false, false, false, true, false, true),
        ("failed cleanup continues recovery retries after both tools are disabled", true, false, [], false, false, false, false, true, true),
        ("a shutdown snapshot cannot restart the periodic timer", false, false, saved, true, true, true, true, true, false),
        ("read-only previews do not start periodic work for active-looking settings", true, true, saved, true, true, true, true, true, false),
    ]
    for (name, started, readOnly, rules, remap, hyperkey, legacy, pending, recovery, expected) in cases {
        check(KeyboardMappingMaintenance.requiresPolling(started: started, readOnly: readOnly,
            rules: rules, remapEnabled: remap, hyperkeyRequested: hyperkey,
            legacyClaimRequested: legacy, reconciliationPending: pending,
            recoveryPending: recovery) == expected, name)
    }
}

private func runKeyboardRuleSelectionTests() {
    let builtIn = KeyboardDevice(registryID: 1, product: "Built-in", isBuiltIn: true)
    let external = KeyboardDevice(registryID: 2, product: "USB keyboard",
        vendorID: 10, productID: 20, locationID: 30, transport: "USB", isBuiltIn: false)
    let rules = [KeyboardRuleSet(selector: .builtIn, mappings: [isoToGrave]),
                 KeyboardRuleSet(selector: KeyboardSelector(device: external), mappings: [graveToISO])]
    let disconnected = KeyboardRuleSelection(rules: rules, devices: [builtIn])
    check(disconnected.status == nil && disconnected.deviceErrors.isEmpty
            && disconnected.mappings == [builtIn.registryID: [isoToGrave]],
          "a disconnected saved keyboard does not block or report an error for connected keyboard mappings")
    let reconnected = KeyboardRuleSelection(rules: rules, devices: [builtIn, external])
    check(reconnected.status == nil && reconnected.deviceErrors.isEmpty
            && reconnected.mappings[external.registryID] == [graveToISO],
          "a reconnected saved keyboard receives its own mappings without editing the saved rules")
    let duplicate = KeyboardDevice(registryID: 3, product: "Other built-in service", isBuiltIn: true)
    let ambiguous = KeyboardRuleSelection(rules: rules, devices: [builtIn, duplicate, external])
    check(ambiguous.status != nil && Set(ambiguous.deviceErrors.keys) == Set([1, 3])
            && ambiguous.mappings == [external.registryID: [graveToISO]],
          "ambiguous selectors still block only the affected devices and preserve independent keyboard rules")
}

private func runKeyboardRefreshQueueTests() {
    var queue = KeyboardMappingRefreshQueue()
    let first = queue.request()!
    let repeated = (0..<5).map { _ in queue.request() }
    let followUp = queue.complete(first, started: true)
    check(repeated.allSatisfy { $0 == nil } && followUp != nil,
          "refresh requests during an in-flight snapshot coalesce into one follow-up snapshot")
    if let followUp {
        check(queue.complete(followUp, started: true) == nil && queue.request() != nil,
              "the follow-up finishes without repeating indefinitely and later manual refresh remains available")
    }

    var stopped = KeyboardMappingRefreshQueue()
    let stoppedRequest = stopped.request()!
    _ = stopped.request()
    stopped.stop()
    check(stopped.complete(stoppedRequest, started: false) == nil,
          "shutdown discards a queued refresh instead of starting work from a late completion")
    let restarted = stopped.request()!
    _ = stopped.request()
    let stale = stopped.complete(stoppedRequest, started: true)
    check(stale == nil && stopped.complete(restarted, started: true) != nil,
          "a completion from before shutdown cannot consume a newer lifetime's queued refresh")
}

private func runLegacyClaimTransferTests() throws {
    enum ProbeFailure: Error { case unreadable }
    let transfer = KeyboardLegacyClaimTransfer()
    var inventoryJournal = KeyboardMappingJournal(bootSession: "same-boot")
    let originalJournal = inventoryJournal
    var inventoryReads = 0
    var inventoryRecords = 0
    let absentAcknowledged = try transfer.transfer(requested: true, mapping: capsToF18,
        registryIDs: [], journal: inventoryJournal,
        read: { _ in inventoryReads += 1; return [capsToF18, externalMapping] },
        record: { inventoryJournal = $0; inventoryRecords += 1 })
    check(!absentAcknowledged && inventoryReads == 0 && inventoryRecords == 0
            && inventoryJournal == originalJournal,
          "an empty keyboard inventory retains the explicit legacy claim without reading, recording or acknowledging it")
    let appearedAcknowledged = try transfer.transfer(requested: true, mapping: capsToF18,
        registryIDs: [5], journal: inventoryJournal,
        read: { _ in inventoryReads += 1; return [capsToF18, externalMapping] },
        record: { inventoryJournal = $0; inventoryRecords += 1 })
    let appearedCleanup = try KeyboardMappingPlanner.plan(current: [capsToF18, externalMapping],
        owned: inventoryJournal.mappings(for: 5), hyperkey: nil, remappings: [])
    check(appearedAcknowledged && inventoryReads == 1 && inventoryRecords == 1
            && appearedCleanup.table == [externalMapping] && appearedCleanup.owned.isEmpty,
          "a keyboard appearing after an empty inventory supplies the evidence needed to journal and restore the pending legacy claim")

    var journal = KeyboardMappingJournal(bootSession: "same-boot")
    var records = 0
    _ = try transfer.transfer(requested: true, mapping: capsToF18, registryIDs: [1],
        journal: journal, read: { _ in [capsToF18, externalMapping] }, record: { journal = $0; records += 1 })
    let firstCleanup = try KeyboardMappingPlanner.plan(current: [capsToF18, externalMapping],
        owned: journal.mappings(for: 1), hyperkey: nil, remappings: [])
    journal.setMappings(firstCleanup.owned, for: 1)

    // The same owner can later receive a fresh explicit claim from an old provider.
    let acknowledged = try transfer.transfer(requested: true, mapping: capsToF18, registryIDs: [2],
        journal: journal, read: { _ in [capsToF18, externalMapping] }, record: { journal = $0; records += 1 })
    let secondCleanup = try KeyboardMappingPlanner.plan(current: [capsToF18, externalMapping],
        owned: journal.mappings(for: 2), hyperkey: nil, remappings: [])
    check(acknowledged && records == 2 && secondCleanup.table == [externalMapping]
            && secondCleanup.owned.isEmpty,
          "a second explicit legacy claim in the same owner is journaled and restored instead of borrowing its Caps Lock pair")
    journal.setMappings(secondCleanup.owned, for: 2)

    let priorJournal = journal
    var failed = false
    var failedAcknowledged = false
    do {
        failedAcknowledged = try transfer.transfer(requested: true, mapping: capsToF18,
            registryIDs: [3, 4], journal: journal,
            read: { id in if id == 4 { throw ProbeFailure.unreadable }; return [capsToF18] },
            record: { journal = $0; records += 1 })
    } catch { failed = error is ProbeFailure }
    check(failed && !failedAcknowledged && journal == priorJournal && records == 2,
          "a failed later legacy probe never reuses an old acknowledgement or retires the new ownership flag")
}

private func keyboardError(_ expected: KeyboardMappingError, _ name: String,
                           _ operation: () throws -> Void) {
    do {
        try operation()
        check(false, name)
    } catch {
        check(error as? KeyboardMappingError == expected, name)
    }
}

private func runKeyboardSelectionTests() throws {
    let internalDevice = KeyboardDevice(registryID: 10, product: "Internal input",
        vendorID: 1452, productID: 123, locationID: 0, transport: "SPI", isBuiltIn: true)
    let externalDevice = KeyboardDevice(registryID: 20, product: "Keychron", vendorID: 3434,
        productID: 567, locationID: 100, transport: "USB", isBuiltIn: false)
    check(KeyboardSelector(device: internalDevice).matches(device: internalDevice)
            && !KeyboardSelector.builtIn.matches(device: externalDevice),
          "built-in selection uses the hardware flag and excludes external keyboards")

    let renamed = KeyboardDevice(registryID: 25, product: "Different product label", vendorID: 3434,
        productID: 567, locationID: 100, transport: "USB", isBuiltIn: false)
    let otherPort = KeyboardDevice(registryID: 30, product: "Keychron", vendorID: 3434,
        productID: 567, locationID: 200, transport: "USB", isBuiltIn: false)
    let selector = KeyboardSelector(device: externalDevice)
    check(selector.matches(device: renamed) && selector == KeyboardSelector(device: renamed),
          "external rules survive reconnection and product-label changes without duplicating identity")
    check(!selector.matches(device: otherPort),
          "external keyboards without a serial number remain scoped to the selected USB location")

    let serialDevice = KeyboardDevice(registryID: 40, product: "Keychron", vendorID: 3434,
        productID: 567, locationID: 100, serialNumber: "unique-serial", transport: "USB", isBuiltIn: false)
    let movedSerialDevice = KeyboardDevice(registryID: 50, product: "Keychron", vendorID: 3434,
        productID: 567, locationID: 200, serialNumber: "unique-serial", transport: "USB", isBuiltIn: false)
    let serialSelector = KeyboardSelector(device: serialDevice)
    check(serialSelector.matches(device: movedSerialDevice)
            && !serialSelector.matches(device: externalDevice),
          "a saved serial number follows its keyboard between ports and excludes another model-identical keyboard")
    let unidentifiable = KeyboardDevice(registryID: 60, product: "Keychron", isBuiltIn: false)
    check(!KeyboardSelector(device: unidentifiable).isValid
            && !KeyboardSelector(device: unidentifiable).matches(device: unidentifiable),
          "a product label alone never authorizes a per-keyboard write")
    let decoded = try JSONDecoder().decode(KeyboardSelector.self, from: JSONEncoder().encode(serialSelector))
    check(decoded.matches(device: movedSerialDevice),
          "saved hardware selectors keep the same reconnect behavior after decoding")
    for invalid in [
        #"{"product":"Same name"}"#,
        #"{"product":"Same name","serialNumber":""}"#,
        #"{"product":"Same name","vendorID":-1,"productID":2}"#,
        #"{"product":"Same name","vendorID":1,"productID":2,"transport":" "}"#,
    ] {
        var rejected = false
        do { _ = try JSONDecoder().decode(KeyboardFingerprint.self, from: Data(invalid.utf8)) }
        catch { rejected = true }
        check(rejected, "malformed hardware selectors are rejected rather than matching a broader keyboard group")
    }
}

private func runKeyboardCompositionTests() throws {
    let desired = [isoToGrave, graveToISO]
    let installed = try KeyboardMappingPlanner.plan(current: [externalMapping], owned: [],
        hyperkey: capsToF18, remappings: desired)
    check(Set(installed.table) == Set([externalMapping, capsToF18] + desired)
            && Set(installed.owned) == Set([capsToF18] + desired),
          "Hyperkey and an ISO swap compose into one table while preserving unrelated HID pages")

    let withoutRemap = try KeyboardMappingPlanner.plan(current: installed.table, owned: installed.owned,
        hyperkey: capsToF18, remappings: [])
    let withoutHyperkey = try KeyboardMappingPlanner.plan(current: installed.table, owned: installed.owned,
        hyperkey: nil, remappings: desired)
    let stopped = try KeyboardMappingPlanner.plan(current: installed.table, owned: installed.owned,
        hyperkey: nil, remappings: [])
    check(Set(withoutRemap.table) == Set([externalMapping, capsToF18])
            && Set(withoutHyperkey.table) == Set([externalMapping] + desired),
          "disabling either tool removes only its contribution and preserves the other tool")
    check(stopped.table == [externalMapping] && stopped.owned.isEmpty,
          "stopping the shared owner removes its exact pairs and leaves the external table intact")

    let borrowed = try KeyboardMappingPlanner.plan(current: [capsToF18, isoToGrave, externalMapping], owned: [],
        hyperkey: capsToF18, remappings: desired)
    let borrowedStopped = try KeyboardMappingPlanner.plan(current: borrowed.table, owned: borrowed.owned,
        hyperkey: nil, remappings: [])
    check(borrowed.owned == [graveToISO]
            && Set(borrowedStopped.table) == Set([capsToF18, isoToGrave, externalMapping]),
          "identical external mappings are borrowed and survive shutdown instead of being claimed by shape")

    let laterEdit = KeyMapping(source: isoToGrave.source, destination: 0x700000029)
    let changed = installed.table.map { $0 == isoToGrave ? laterEdit : $0 }
    let changedCleanup = try KeyboardMappingPlanner.plan(current: changed, owned: installed.owned,
        hyperkey: nil, remappings: [])
    check(Set(changedCleanup.table) == Set([externalMapping, laterEdit]),
          "shutdown preserves a later external replacement of an owned source")
    keyboardError(.sourceConflict(source: isoToGrave.source,
        existingDestination: laterEdit.destination, requestedDestination: isoToGrave.destination),
        "retry refuses to overwrite an external replacement of a desired source") {
        _ = try KeyboardMappingPlanner.plan(current: changed, owned: installed.owned,
            hyperkey: capsToF18, remappings: desired)
    }

    let capsToEscape = KeyMapping(source: capsToF18.source, destination: 0x700000029)
    keyboardError(.hyperkeyConflict(capsToF18.source),
        "a Remap rule for Caps Lock is blocked while Caps Lock Hyperkey owns that source") {
        _ = try KeyboardMappingPlanner.plan(current: [], owned: [],
            hyperkey: capsToF18, remappings: [capsToEscape])
    }
    for conflict in [KeyMapping(source: 0x700000004, destination: capsToF18.destination),
                     KeyMapping(source: capsToF18.destination, destination: 0x700000004)] {
        keyboardError(.hyperkeyConflict(conflict.source),
            "external rules cannot intercept or synthesize the active Hyperkey F18 route") {
            _ = try KeyboardMappingPlanner.plan(current: [conflict], owned: [],
                hyperkey: capsToF18, remappings: [])
        }
        keyboardError(.hyperkeyConflict(conflict.source),
            "configured rules cannot intercept or synthesize the active Hyperkey F18 route") {
            _ = try KeyboardMappingPlanner.plan(current: [], owned: [],
                hyperkey: capsToF18, remappings: [conflict])
        }
    }
    keyboardError(.duplicateSource(isoToGrave.source),
        "multiple requested destinations for one physical key are rejected before planning") {
        _ = try KeyboardMappingPlanner.plan(current: [], owned: [], hyperkey: nil,
            remappings: [isoToGrave, laterEdit])
    }
    let interruptedCleanup = try KeyboardMappingPlanner.plan(current: [laterEdit, externalMapping],
        owned: [isoToGrave, laterEdit], hyperkey: nil, remappings: [])
    check(interruptedCleanup.table == [externalMapping],
          "a pending replacement journal can clean either exact destination for the same source")
}

private func runKeyboardTableTests() throws {
    let property: [[String: UInt64]] = [
        ["HIDKeyboardModifierMappingSrc": 0x700000064, "HIDKeyboardModifierMappingDst": 0x700000035],
        ["HIDKeyboardModifierMappingSrc": 0xC000000E9, "HIDKeyboardModifierMappingDst": 0xC000000EA],
    ]
    let decoded = try HIDMappingTable.parse(property)
    check(decoded == [isoToGrave, externalMapping],
          "typed HID property parsing retains complete mappings, including unrelated usage pages")
    check(HIDMappingTable.propertyList([isoToGrave, externalMapping]) == property,
          "the native HID write payload uses Apple's source and destination property keys")
    check(try HIDMappingTable.parse(nil).isEmpty && HIDMappingTable.parse([] as [Any]).isEmpty,
          "an absent property and an explicit empty table both permit a fresh mapping")

    let source = HIDMappingTable.sourceKey
    let destination = HIDMappingTable.destinationKey
    let malformed: [Any] = [
        NSNull(), "()", [source: isoToGrave.source, destination: isoToGrave.destination],
        [[source: isoToGrave.source]],
        [[source: isoToGrave.source, destination: isoToGrave.destination, "UnknownKey": UInt64(1)]],
        [[source: "30064771172", destination: isoToGrave.destination]],
        [[source: true, destination: isoToGrave.destination]],
        [[source: NSNumber(value: -1), destination: NSNumber(value: isoToGrave.destination)]],
        [[source: NSNumber(value: Double(isoToGrave.source)), destination: isoToGrave.destination]],
        [HIDMappingTable.propertyList([isoToGrave])[0], "unreadable second pair"],
    ]
    for raw in malformed {
        keyboardError(.malformedTable,
            "unrecognized, partial, non-integral or extended HID tables block writes in their entirety") {
            _ = try HIDMappingTable.parse(raw)
        }
    }
    keyboardError(.duplicateSource(isoToGrave.source),
        "duplicate physical sources in an existing HID table block writes") {
        _ = try HIDMappingTable.parse(HIDMappingTable.propertyList([isoToGrave, isoToGrave]))
    }
}

private func runKeyboardConflictResolutionTests() throws {
    let isoToEscape = KeyMapping(source: isoToGrave.source, destination: 0x700000029)
    let capsToEscape = KeyMapping(source: capsToF18.source, destination: 0x700000029)
    let isoError = KeyboardMappingError.sourceConflict(source: isoToGrave.source,
        existingDestination: isoToEscape.destination, requestedDestination: isoToGrave.destination)
    let capsError = KeyboardMappingError.sourceConflict(source: capsToF18.source,
        existingDestination: capsToEscape.destination, requestedDestination: capsToF18.destination)

    let remapBlocked = try KeyboardMappingPlanner.resolve(
        current: [externalMapping, isoToEscape, capsToF18, graveToISO], owned: [capsToF18, graveToISO],
        hyperkey: capsToF18, remappings: [isoToGrave, graveToISO])
    check(Set(remapBlocked.plan.table) == Set([externalMapping, isoToEscape, capsToF18])
            && remapBlocked.plan.owned == [capsToF18]
            && remapBlocked.hyperkeyError == nil && remapBlocked.remapError == isoError,
          "an unrelated Remap conflict keeps Hyperkey active, releases stale Remap pairs and reports only Remap blocked")

    let hyperkeyBlocked = try KeyboardMappingPlanner.resolve(current: [externalMapping, capsToEscape], owned: [],
        hyperkey: capsToF18, remappings: [isoToGrave, graveToISO])
    check(Set(hyperkeyBlocked.plan.table) == Set([externalMapping, capsToEscape, isoToGrave, graveToISO])
            && Set(hyperkeyBlocked.plan.owned) == Set([isoToGrave, graveToISO])
            && hyperkeyBlocked.hyperkeyError == capsError && hyperkeyBlocked.remapError == nil,
          "a blocked Caps Lock route still applies independent Remap rules and reports only Hyperkey blocked")

    let contradictory = try KeyboardMappingPlanner.resolve(current: [externalMapping], owned: [],
        hyperkey: capsToF18, remappings: [capsToEscape])
    check(Set(contradictory.plan.table) == Set([externalMapping, capsToF18])
            && contradictory.hyperkeyError == nil
            && contradictory.remapError == .hyperkeyConflict(capsToF18.source),
          "a configured Caps Lock contradiction preserves Hyperkey's single route owner and blocks the Remap rule")

    let bothBlocked = try KeyboardMappingPlanner.resolve(
        current: [externalMapping, capsToEscape, isoToEscape, graveToISO], owned: [graveToISO],
        hyperkey: capsToF18, remappings: [isoToGrave, graveToISO])
    check(Set(bothBlocked.plan.table) == Set([externalMapping, capsToEscape, isoToEscape])
            && bothBlocked.plan.owned.isEmpty
            && bothBlocked.hyperkeyError == capsError && bothBlocked.remapError == isoError,
          "independent conflicts preserve every external pair, release owned stale pairs and report each tool's own error")

    let remapOnlyBlocked = try KeyboardMappingPlanner.resolve(current: [isoToEscape, graveToISO],
        owned: [graveToISO], hyperkey: nil, remappings: [isoToGrave, graveToISO])
    check(remapOnlyBlocked.plan.table == [isoToEscape] && remapOnlyBlocked.plan.owned.isEmpty
            && remapOnlyBlocked.hyperkeyError == nil && remapOnlyBlocked.remapError == isoError,
          "a Remap-only conflict never reports an inactive Hyperkey as blocked")

    keyboardError(.duplicateSource(isoToGrave.source),
        "conflict fallback never turns an unreadable current table into a writable cleanup plan") {
        _ = try KeyboardMappingPlanner.resolve(current: [isoToGrave, isoToEscape], owned: [],
            hyperkey: capsToF18, remappings: [graveToISO])
    }
}

private func runKeyboardJournalTests() throws {
    var journal = KeyboardMappingJournal(bootSession: "boot-A")
    let replacement = KeyMapping(source: isoToGrave.source, destination: 0x700000029)
    journal.setMappings([isoToGrave, replacement], for: 100)
    journal.setMappings([capsToF18], for: 200)
    let saved = try JSONDecoder().decode(KeyboardMappingJournal.self, from: JSONEncoder().encode(journal))
    check(saved.bootSession == "boot-A" && saved.mappings(for: 100) == [isoToGrave, replacement]
            && saved.mappings(for: 200) == [capsToF18],
          "the recovery journal retains per-service intent, including both sides of an interrupted replacement")
    journal.setMappings([], for: 100)
    check(journal.mappings(for: 100).isEmpty && journal.mappings(for: 200) == [capsToF18],
          "confirmed cleanup retires only the selected service's ownership")

    keyboardError(.unsupportedJournalVersion(99),
        "a future ownership journal cannot authorize cleanup") {
        _ = try JSONDecoder().decode(KeyboardMappingJournal.self,
            from: Data(#"{"version":99,"bootSession":"boot-A","entries":[]}"#.utf8))
    }
    for invalid in [
        #"{"version":1,"bootSession":"","entries":[]}"#,
        #"{"version":1,"bootSession":"boot-A","entries":[{"registryID":0,"mappings":[]}]}"#,
        #"{"version":1,"bootSession":"boot-A","entries":[{"registryID":1,"mappings":[]},{"registryID":1,"mappings":[]}]}"#,
    ] {
        keyboardError(.malformedJournal, "ambiguous ownership journals block recovery instead of broad cleanup") {
            _ = try JSONDecoder().decode(KeyboardMappingJournal.self, from: Data(invalid.utf8))
        }
    }
}

private final class MappingTransactionFixture {
    enum Failure: Error { case record, write }
    var table: [KeyMapping]
    var recorded: [KeyMapping] = []
    var events: [String] = []
    var failRecord = false
    var failWrite = false
    var discardWrite = false
    var externalChangeOnIntent: [KeyMapping]?

    init(table: [KeyMapping]) { self.table = table }
    func read() -> [KeyMapping] { events.append("read"); return table }
    func write(_ next: [KeyMapping]) throws {
        events.append("write")
        if failWrite { throw Failure.write }
        if !discardWrite { table = next }
    }
    func record(_ pairs: [KeyMapping]) throws {
        events.append("record")
        if failRecord { throw Failure.record }
        recorded = pairs
        if let changed = externalChangeOnIntent {
            table = changed
            externalChangeOnIntent = nil
        }
    }
    func apply(current: [KeyMapping], owned: [KeyMapping], plan: KeyboardMappingPlan) throws {
        try KeyboardMappingTransaction.apply(current: current, owned: owned, plan: plan,
            read: read, write: write, record: record)
    }
}

private func runKeyboardTransactionTests() throws {
    let current = [externalMapping]
    let initialPlan = try KeyboardMappingPlanner.plan(current: current, owned: [],
        hyperkey: capsToF18, remappings: [isoToGrave, graveToISO])
    let fixture = MappingTransactionFixture(table: current)
    try fixture.apply(current: current, owned: [], plan: initialPlan)
    check(Set(fixture.table) == Set(initialPlan.table) && fixture.recorded == initialPlan.owned
            && fixture.events == ["read", "record", "read", "write", "read", "record"],
          "a transaction journals intent before its write and records confirmed ownership only after readback")

    let cleanup = try KeyboardMappingPlanner.plan(current: fixture.table, owned: fixture.recorded,
        hyperkey: nil, remappings: [])
    try fixture.apply(current: fixture.table, owned: fixture.recorded, plan: cleanup)
    check(fixture.table == [externalMapping] && fixture.recorded.isEmpty,
          "transaction cleanup verifies the external table before retiring ownership")

    let journalFailure = MappingTransactionFixture(table: current)
    journalFailure.failRecord = true
    var journalFailed = false
    do { try journalFailure.apply(current: current, owned: [], plan: initialPlan) }
    catch { journalFailed = error is MappingTransactionFixture.Failure }
    check(journalFailed && journalFailure.events == ["read", "record"] && journalFailure.table == current,
          "a failed intent save prevents every HID write")

    let drift = MappingTransactionFixture(table: current + [isoToGrave])
    keyboardError(.tableChanged, "external changes between planning and writing cancel the transaction") {
        try drift.apply(current: current, owned: [], plan: initialPlan)
    }
    check(drift.table == current + [isoToGrave] && !drift.events.contains("write"),
          "a cancelled transaction leaves the external writer's changed table intact")

    let driftDuringJournal = MappingTransactionFixture(table: current)
    driftDuringJournal.externalChangeOnIntent = current + [isoToGrave]
    keyboardError(.tableChanged, "an external change while saving intent cancels the pending HID write") {
        try driftDuringJournal.apply(current: current, owned: [], plan: initialPlan)
    }
    check(driftDuringJournal.table == current + [isoToGrave] && driftDuringJournal.recorded.isEmpty
            && driftDuringJournal.events == ["read", "record", "read", "record"],
          "a cancelled pre-write intent never claims an identical pair introduced by the external writer")

    let writeFailure = MappingTransactionFixture(table: current)
    writeFailure.failWrite = true
    var writeFailed = false
    do { try writeFailure.apply(current: current, owned: [], plan: initialPlan) }
    catch { writeFailed = error is MappingTransactionFixture.Failure }
    check(writeFailed && writeFailure.recorded == initialPlan.owned
            && writeFailure.events == ["read", "record", "read", "write"],
          "a failed OS write retains recovery intent without falsely confirming success")

    let discarded = MappingTransactionFixture(table: current)
    discarded.discardWrite = true
    keyboardError(.verificationFailed, "a successful API return with incorrect readback still fails the transaction") {
        try discarded.apply(current: current, owned: [], plan: initialPlan)
    }
    check(discarded.recorded == initialPlan.owned && discarded.events.last == "read",
          "failed readback retains recovery intent and never advances confirmed ownership")

    let reordered = MappingTransactionFixture(table: [isoToGrave, externalMapping])
    let borrowed = try KeyboardMappingPlanner.plan(current: [externalMapping, isoToGrave], owned: [],
        hyperkey: nil, remappings: [isoToGrave])
    try reordered.apply(current: [externalMapping, isoToGrave], owned: [], plan: borrowed)
    check(reordered.events == ["read", "record", "read", "record"] && reordered.recorded.isEmpty,
          "table ordering does not cause a redundant write or claim a borrowed mapping")

    let next = KeyMapping(source: isoToGrave.source, destination: 0x700000029)
    let replacing = MappingTransactionFixture(table: [externalMapping, isoToGrave])
    replacing.discardWrite = true
    let replacePlan = try KeyboardMappingPlanner.plan(current: replacing.table, owned: [isoToGrave],
        hyperkey: nil, remappings: [next])
    keyboardError(.verificationFailed, "an interrupted replacement retains old and new ownership alternatives") {
        try replacing.apply(current: replacing.table, owned: [isoToGrave], plan: replacePlan)
    }
    check(Set(replacing.recorded) == Set([isoToGrave, next]),
          "recovery intent preserves the removed pair until the replacement has been verified")
}

import AppCore
import Foundation
import IOKit
import IOKit.hid
import IOKit.hidsystem

// Compile with the shipping KeyboardMappingService. These module-local IOKit shims
// replay a frozen client inventory using real, read-only service handles. No HID map,
// recovery journal, user configuration, or physical connection is changed.
private final class InventoryFixture: @unchecked Sendable {
    static let shared = InventoryFixture()
    private let lock = NSLock()
    private var sourceClient: IOHIDEventSystemClient?
    private var nextServices: [IOHIDServiceClient] = []
    private var removed: Set<UInt64> = []
    private var inventories: [ObjectIdentifier: [IOHIDServiceClient]] = [:]

    func prepare() -> [(IOHIDServiceClient, UInt64)]? {
        let created: IOHIDEventSystemClient? = IOKit.IOHIDEventSystemClientCreateSimpleClient(kCFAllocatorDefault)
        guard let client = created,
              let raw = IOKit.IOHIDEventSystemClientCopyServices(client),
              let services = raw as? [IOHIDServiceClient] else { return nil }
        sourceClient = client
        var found: [(IOHIDServiceClient, UInt64)] = []
        for service in services {
            guard IOHIDServiceClientConformsTo(service, UInt32(kHIDPage_GenericDesktop),
                    UInt32(kHIDUsage_GD_Keyboard)) != 0,
                  let id = IOHIDServiceClientGetRegistryID(service) as? NSNumber else { continue }
            let entry = IOKit.IOServiceGetMatchingService(kIOMainPortDefault,
                IORegistryEntryIDMatching(id.uint64Value))
            guard entry != 0 else { continue }
            IOObjectRelease(entry)
            found.append((service, id.uint64Value))
        }
        return found.count >= 2 ? Array(found.prefix(2)) : nil
    }

    func set(services: [IOHIDServiceClient], removed: Set<UInt64> = []) {
        lock.withLock {
            nextServices = services
            self.removed = removed
        }
    }

    func makeClient(_ allocator: CFAllocator?) -> IOHIDEventSystemClient? {
        let created: IOHIDEventSystemClient? = IOKit.IOHIDEventSystemClientCreateSimpleClient(allocator)
        guard let client = created else { return nil }
        lock.withLock { inventories[ObjectIdentifier(client)] = nextServices }
        return client
    }

    func services(_ client: IOHIDEventSystemClient) -> CFArray? {
        lock.withLock { inventories[ObjectIdentifier(client)].map { $0 as CFArray } }
    }

    func isRemoved(_ id: UInt64) -> Bool { lock.withLock { removed.contains(id) } }
}

func IOHIDEventSystemClientCreateSimpleClient(_ allocator: CFAllocator?) -> IOHIDEventSystemClient? {
    InventoryFixture.shared.makeClient(allocator)
}

func IOHIDEventSystemClientCopyServices(_ client: IOHIDEventSystemClient) -> CFArray? {
    InventoryFixture.shared.services(client)
}

// A callable binding shadows the imported C function. A Swift overload can lose overload
// resolution to IOKit's consumed-argument signature and silently query the live registry.
let IOServiceGetMatchingService: @Sendable (mach_port_t, CFDictionary?) -> io_service_t = { mainPort, matching in
    let entry = IOKit.IOServiceGetMatchingService(mainPort, matching)
    guard entry != 0 else { return 0 }
    var id: UInt64 = 0
    if IORegistryEntryGetRegistryEntryID(entry, &id) == KERN_SUCCESS,
       InventoryFixture.shared.isRemoved(id) {
        IOObjectRelease(entry)
        return 0
    }
    return entry
}

@main
private struct KeyboardMappingInventoryProbe {
    @MainActor
    static func main() async {
        let fixture = InventoryFixture.shared
        guard let keyboards = fixture.prepare() else {
            print("UNAVAILABLE: inventory regression requires two live keyboard HID services; no maps were changed.")
            exit(77)
        }
        let (oldService, oldID) = keyboards[0]
        let (replacementService, replacementID) = keyboards[1]
        let service = KeyboardMappingService(readOnly: true)
        defer { service.shutdown() }

        fixture.set(services: [oldService])
        service.start()
        guard await expect(service, ids: [oldID], stage: "initial keyboard") else { exit(1) }

        // The client still enumerates an entry after its IORegistry removal.
        fixture.set(services: [oldService], removed: [oldID])
        service.refresh()
        guard await expect(service, ids: [], stage: "removed service is excluded") else { exit(1) }

        // A reconnected keyboard has a new identity. Existing clients retain their old list.
        fixture.set(services: [replacementService], removed: [oldID])
        service.refresh()
        guard await expect(service, ids: [replacementID], stage: "replacement keyboard is discovered") else { exit(1) }
        print("PASS: the shipping inventory drops removed services and discovers replacements without restarting.")
    }

    @MainActor
    private static func expect(_ service: KeyboardMappingService, ids: Set<UInt64>, stage: String) async -> Bool {
        for _ in 0..<100 {
            if Set(service.devices.map(\.registryID)) == ids && service.remapStatus == nil { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        print("FAIL: \(stage); expected \(ids.sorted()), observed \(service.devices.map(\.registryID).sorted()), status \(service.remapStatus ?? "none")")
        return false
    }
}

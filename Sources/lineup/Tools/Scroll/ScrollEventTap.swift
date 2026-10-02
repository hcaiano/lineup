import CoreGraphics
import Foundation
import IOKit
import ScrollCore

/// Reverses scroll events in place. It never posts an event, so nothing is duplicated, and
/// gestures such as zoom, rotation and swipes are not observed at all.
///
/// The callback runs on its own thread. Every scroll on the Mac waits for an active tap, so a busy
/// main thread would otherwise stall scrolling until macOS timed the tap out. If the tap stops,
/// crashes or is disabled, macOS delivers scroll events unchanged.
final class ScrollEventTap {
    enum StartFailure: Error {
        /// The private HID event interface is missing, so devices cannot be identified.
        case unsupported
        /// macOS refused the tap, normally because Accessibility is not granted.
        case refused
    }

    private let reversal = ReversalBox()
    // Main thread only.
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var runLoop: CFRunLoop?

    /// Read on the tap thread for every event, so a change applies to the next scroll.
    func setReversal(_ value: ScrollReversal) { reversal.value = value }

    func start() throws {
        // macOS can invalidate a tap, for example across an Accessibility revocation and grant.
        if let tap, !CFMachPortIsValid(tap) { stop() }
        guard tap == nil else {
            if let tap, !CGEvent.tapIsEnabled(tap: tap) { CGEvent.tapEnable(tap: tap, enable: true) }
            return
        }
        guard HIDEvent.isAvailable else { throw StartFailure.unsupported }
        let session = TapSession(reversal: reversal)
        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .tailAppendEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(1) << CGEventType.scrollWheel.rawValue,
            callback: scrollTapCallback,
            userInfo: Unmanaged.passUnretained(session).toOpaque()) else {
            throw StartFailure.refused
        }
        // An enabled tap that nobody services would hold every scroll until macOS times it out.
        CGEvent.tapEnable(tap: port, enable: false)
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0) else {
            CFMachPortInvalidate(port)
            throw StartFailure.refused
        }
        session.port = port
        let handoff = Handoff()
        // The thread keeps the session alive until its run loop ends.
        let thread = Thread {
            let loop = CFRunLoopGetCurrent()
            CFRunLoopAddSource(loop, source, .commonModes)
            handoff.loop = loop
            handoff.ready.signal()
            CFRunLoopRun()
            withExtendedLifetime(session) {}
        }
        thread.name = "Lineup Scroll"
        thread.qualityOfService = .userInteractive
        thread.start()
        handoff.ready.wait()
        tap = port
        self.source = source
        runLoop = handoff.loop
        CGEvent.tapEnable(tap: port, enable: true)
    }

    /// Ends interception immediately. Idempotent.
    func stop() {
        guard let tap else { return }
        CGEvent.tapEnable(tap: tap, enable: false)
        CFMachPortInvalidate(tap)
        if let source { CFRunLoopSourceInvalidate(source) }
        if let runLoop { CFRunLoopStop(runLoop) }
        self.tap = nil
        source = nil
        runLoop = nil
    }
}

/// Passes the tap thread's run loop back to `start()`; the semaphore orders the write and read.
private final class Handoff: @unchecked Sendable {
    let ready = DispatchSemaphore(value: 0)
    var loop: CFRunLoop?
}

private final class ReversalBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = ScrollReversal()

    var value: ScrollReversal {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

/// One installation's state. Touched only on the tap thread after `start()` hands it over.
private final class TapSession {
    let reversal: ReversalBox
    var port: CFMachPort?
    private var filter = ScrollFilter()
    private var devices: [UInt64: ScrollDevice?] = [:]

    init(reversal: ReversalBox) { self.reversal = reversal }

    func handle(_ type: CGEventType, _ event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            filter = ScrollFilter()
            if let port { CGEvent.tapEnable(tap: port, enable: true) }
            return
        }
        guard type == .scrollWheel else { return }
        let reversal = reversal.value
        guard !reversal.isEmpty else { return }
        let hid = HIDEvent(event)
        let phase = ScrollPhase(scroll: event.getIntegerValueField(.scrollWheelEventScrollPhase),
                                momentum: event.getIntegerValueField(.scrollWheelEventMomentumPhase))
        let axes = filter.axes(source: hid.map { source(for: $0.senderID) } ?? .software,
                               phase: phase, reversal: reversal)
        guard !axes.isEmpty else { return }
        let deltas = ScrollDeltas(
            line: (event.getIntegerValueField(.scrollWheelEventDeltaAxis1),
                   event.getIntegerValueField(.scrollWheelEventDeltaAxis2)),
            point: (event.getDoubleValueField(.scrollWheelEventPointDeltaAxis1),
                    event.getDoubleValueField(.scrollWheelEventPointDeltaAxis2)),
            fixed: (event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1),
                    event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2)),
            hid: hid.map { ($0.value(HIDEvent.scrollY), $0.value(HIDEvent.scrollX)) })
            .reversed(axes)
        // Setting a line delta makes Core Graphics recompute the other deltas from it, so the
        // precise values must be written after it or smooth scrolling becomes line steps.
        if axes.contains(.vertical) {
            event.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: deltas.line.y)
            event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: deltas.fixed.y)
            event.setDoubleValueField(.scrollWheelEventPointDeltaAxis1, value: deltas.point.y)
            if let y = deltas.hid?.y { hid?.setValue(y, HIDEvent.scrollY) }
        }
        if axes.contains(.horizontal) {
            event.setIntegerValueField(.scrollWheelEventDeltaAxis2, value: deltas.line.x)
            event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: deltas.fixed.x)
            event.setDoubleValueField(.scrollWheelEventPointDeltaAxis2, value: deltas.point.x)
            if let x = deltas.hid?.x { hid?.setValue(x, HIDEvent.scrollX) }
        }
    }

    /// Registry IDs are never reused while the Mac is running, so a cached answer stays valid
    /// across sleep and reconnection. A service that cannot be found yet is retried next event.
    private func source(for senderID: UInt64) -> ScrollSource {
        guard senderID != 0 else { return .unresolved }
        if let known = devices[senderID] { return .device(known) }
        guard let descriptor = Self.descriptor(registryID: senderID) else { return .unresolved }
        if devices.count >= 64 { devices.removeAll() }
        devices.updateValue(descriptor.device, forKey: senderID) // also caches "not a mouse or trackpad"
        return .device(descriptor.device)
    }

    private static func descriptor(registryID: UInt64) -> ScrollDeviceDescriptor? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IORegistryEntryIDMatching(registryID))
        guard service != IO_OBJECT_NULL else { return nil }
        defer { IOObjectRelease(service) }
        func number(_ value: Any?) -> Int? { (value as? NSNumber)?.intValue }
        func property(_ key: String) -> Any? {
            IORegistryEntrySearchCFProperty(service, kIOServicePlane, key as CFString, kCFAllocatorDefault,
                                            IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents))
        }
        let pairs = property("DeviceUsagePairs") as? [[String: Any]] ?? []
        return ScrollDeviceDescriptor(
            classes: Set(ScrollDeviceDescriptor.knownClasses.filter { IOObjectConformsTo(service, $0) != 0 }),
            usages: Set(pairs.compactMap { pair in
                guard let page = number(pair["DeviceUsagePage"]), let usage = number(pair["DeviceUsage"]) else {
                    return nil
                }
                return ScrollDeviceUsage(page: page, usage: usage)
            }),
            vendorID: number(property("VendorID")),
            productID: number(property("ProductID")))
    }
}

private func scrollTapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent,
                               userInfo: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    if let userInfo {
        Unmanaged<TapSession>.fromOpaque(userInfo).takeUnretainedValue().handle(type, event)
    }
    return Unmanaged.passUnretained(event)
}

/// The IOHIDEvent attached to a hardware scroll event. Its sender is the registry ID of the HID
/// service that produced the event, which identifies the device regardless of pointer position.
/// This is private macOS API, resolved at runtime; without it the tool refuses to start.
private struct HIDEvent {
    private typealias Copy = @convention(c) (CGEvent) -> Unmanaged<AnyObject>?
    private typealias SenderID = @convention(c) (AnyObject) -> UInt64
    private typealias GetFloat = @convention(c) (AnyObject, UInt32) -> Double
    private typealias SetFloat = @convention(c) (AnyObject, UInt32, Double) -> Void

    private static let copy = symbol("CGEventCopyIOHIDEvent", Copy.self)
    private static let getSenderID = symbol("IOHIDEventGetSenderID", SenderID.self)
    private static let getFloat = symbol("IOHIDEventGetFloatValue", GetFloat.self)
    private static let setFloat = symbol("IOHIDEventSetFloatValue", SetFloat.self)

    // kIOHIDEventFieldScrollX and Y: the scroll event type (6) in the upper 16 bits.
    static let scrollX: UInt32 = 6 << 16
    static let scrollY: UInt32 = 6 << 16 | 1

    static var isAvailable: Bool { copy != nil && getSenderID != nil && getFloat != nil && setFloat != nil }

    private let ref: AnyObject

    /// `nil` for an event without HID data, such as one posted by another app.
    init?(_ event: CGEvent) {
        guard let copy = Self.copy, let ref = copy(event)?.takeRetainedValue() else { return nil }
        self.ref = ref
    }

    var senderID: UInt64 { Self.getSenderID?(ref) ?? 0 }
    func value(_ field: UInt32) -> Double { Self.getFloat?(ref, field) ?? 0 }
    func setValue(_ value: Double, _ field: UInt32) { Self.setFloat?(ref, field, value) }

    private static func symbol<T>(_ name: String, _ type: T.Type) -> T? {
        dlsym(UnsafeMutableRawPointer(bitPattern: -2), name).map { unsafeBitCast($0, to: type) }
    }
}

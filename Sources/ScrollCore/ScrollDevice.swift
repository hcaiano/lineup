import Foundation

/// The two kinds of pointing device whose scroll direction can be reversed separately.
public enum ScrollDevice: String, CaseIterable, Sendable {
    case mouse
    case trackpad
}

/// One `DeviceUsagePairs` entry of a HID service.
public struct ScrollDeviceUsage: Hashable, Sendable {
    public let page: Int
    public let usage: Int

    public init(page: Int, usage: Int) {
        self.page = page
        self.usage = usage
    }

    static let pointer = ScrollDeviceUsage(page: 0x01, usage: 0x01)
    static let mouse = ScrollDeviceUsage(page: 0x01, usage: 0x02)
    static let touchpad = ScrollDeviceUsage(page: 0x0D, usage: 0x05)
}

/// What the IORegistry reports for the HID service that sent a scroll event.
public struct ScrollDeviceDescriptor: Equatable, Sendable {
    /// The IOKit classes from `ScrollDeviceDescriptor.knownClasses` that the service conforms to.
    public var classes: Set<String>
    public var usages: Set<ScrollDeviceUsage>
    public var vendorID: Int?
    public var productID: Int?

    public init(classes: Set<String> = [], usages: Set<ScrollDeviceUsage> = [],
                vendorID: Int? = nil, productID: Int? = nil) {
        self.classes = classes
        self.usages = usages
        self.vendorID = vendorID
        self.productID = productID
    }

    public static let trackpadDriver = "AppleMultitouchTrackpadHIDEventDriver"
    public static let magicMouseDriver = "AppleMultitouchMouseHIDEventDriver"
    public static let knownClasses = [trackpadDriver, magicMouseDriver]

    // Bluetooth and USB vendor IDs, with the Magic Mouse and Magic Trackpad product IDs. These
    // back up the driver classes in case a macOS release renames them.
    private static let appleVendors: Set<Int> = [0x004C, 0x05AC]
    private static let magicMice: Set<Int> = [0x030D, 0x0269, 0x0323]
    private static let magicTrackpads: Set<Int> = [0x030E, 0x0265, 0x0324]

    /// `nil` when the service cannot be identified safely; its events keep the system direction.
    ///
    /// Magic Mouse is checked first because its multitouch surface can also report touch
    /// usages. A trackpad reports a mouse usage for pointer compatibility, so the touchpad
    /// usage wins over it.
    public var device: ScrollDevice? {
        let apple = vendorID.map(Self.appleVendors.contains) ?? false
        if classes.contains(Self.magicMouseDriver) || (apple && productID.map(Self.magicMice.contains) == true) {
            return .mouse
        }
        if classes.contains(Self.trackpadDriver) || (apple && productID.map(Self.magicTrackpads.contains) == true)
            || usages.contains(.touchpad) {
            return .trackpad
        }
        if usages.contains(.mouse) || usages.contains(.pointer) { return .mouse }
        return nil
    }
}

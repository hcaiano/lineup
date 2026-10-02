import Foundation

/// USB keyboard usages identify positions. The app translates virtualKeyCode through the
/// selected input source to present the symbols produced by that physical position.
public struct PhysicalKey: Equatable, Hashable, Sendable, Identifiable {
    public let hidUsage: UInt64
    public let name: String
    public let virtualKeyCode: UInt16?
    public var id: UInt64 { hidUsage }

    public init(hidUsage: UInt64, name: String, virtualKeyCode: UInt16? = nil) {
        self.hidUsage = hidUsage
        self.name = name
        self.virtualKeyCode = virtualKeyCode
    }

    public static let grave = key(0x35, "Grave / tilde position", 0x32)
    public static let isoSection = key(0x64, "ISO section position", 0x0A)
    public static let capsLock = key(0x39, "Caps Lock", 0x39)
    public static let f18 = key(0x6D, "F18", 0x4F)

    public static let catalog: [PhysicalKey] = [
        isoSection, grave,
        key(0x04, "A", 0x00), key(0x05, "B", 0x0B), key(0x06, "C", 0x08),
        key(0x07, "D", 0x02), key(0x08, "E", 0x0E), key(0x09, "F", 0x03),
        key(0x0A, "G", 0x05), key(0x0B, "H", 0x04), key(0x0C, "I", 0x22),
        key(0x0D, "J", 0x26), key(0x0E, "K", 0x28), key(0x0F, "L", 0x25),
        key(0x10, "M", 0x2E), key(0x11, "N", 0x2D), key(0x12, "O", 0x1F),
        key(0x13, "P", 0x23), key(0x14, "Q", 0x0C), key(0x15, "R", 0x0F),
        key(0x16, "S", 0x01), key(0x17, "T", 0x11), key(0x18, "U", 0x20),
        key(0x19, "V", 0x09), key(0x1A, "W", 0x0D), key(0x1B, "X", 0x07),
        key(0x1C, "Y", 0x10), key(0x1D, "Z", 0x06),
        key(0x1E, "1", 0x12), key(0x1F, "2", 0x13), key(0x20, "3", 0x14),
        key(0x21, "4", 0x15), key(0x22, "5", 0x17), key(0x23, "6", 0x16),
        key(0x24, "7", 0x1A), key(0x25, "8", 0x1C), key(0x26, "9", 0x19),
        key(0x27, "0", 0x1D),
        key(0x28, "Return", 0x24), key(0x29, "Escape", 0x35),
        key(0x2A, "Delete backward", 0x33), key(0x2B, "Tab", 0x30),
        key(0x2C, "Space", 0x31), key(0x2D, "Minus position", 0x1B),
        key(0x2E, "Equal position", 0x18), key(0x2F, "Left bracket position", 0x21),
        key(0x30, "Right bracket position", 0x1E), key(0x31, "Backslash position", 0x2A),
        key(0x32, "ISO hash position", 0x2A), key(0x33, "Semicolon position", 0x29),
        key(0x34, "Quote position", 0x27), key(0x36, "Comma position", 0x2B),
        key(0x37, "Period position", 0x2F), key(0x38, "Slash position", 0x2C), capsLock,
        key(0x3A, "F1", 0x7A), key(0x3B, "F2", 0x78), key(0x3C, "F3", 0x63),
        key(0x3D, "F4", 0x76), key(0x3E, "F5", 0x60), key(0x3F, "F6", 0x61),
        key(0x40, "F7", 0x62), key(0x41, "F8", 0x64), key(0x42, "F9", 0x65),
        key(0x43, "F10", 0x6D), key(0x44, "F11", 0x67), key(0x45, "F12", 0x6F),
        key(0x49, "Insert", 0x72), key(0x4A, "Home", 0x73),
        key(0x4B, "Page Up", 0x74), key(0x4C, "Delete forward", 0x75),
        key(0x4D, "End", 0x77), key(0x4E, "Page Down", 0x79),
        key(0x4F, "Right arrow", 0x7C), key(0x50, "Left arrow", 0x7B),
        key(0x51, "Down arrow", 0x7D), key(0x52, "Up arrow", 0x7E),
        key(0x53, "Keypad Clear", 0x47), key(0x54, "Keypad /", 0x4B),
        key(0x55, "Keypad *", 0x43), key(0x56, "Keypad -", 0x4E),
        key(0x57, "Keypad +", 0x45), key(0x58, "Keypad Enter", 0x4C),
        key(0x59, "Keypad 1", 0x53), key(0x5A, "Keypad 2", 0x54),
        key(0x5B, "Keypad 3", 0x55), key(0x5C, "Keypad 4", 0x56),
        key(0x5D, "Keypad 5", 0x57), key(0x5E, "Keypad 6", 0x58),
        key(0x5F, "Keypad 7", 0x59), key(0x60, "Keypad 8", 0x5B),
        key(0x61, "Keypad 9", 0x5C), key(0x62, "Keypad 0", 0x52),
        key(0x63, "Keypad .", 0x41), key(0x67, "Keypad =", 0x51),
        key(0x68, "F13", 0x69), key(0x69, "F14", 0x6B), key(0x6A, "F15", 0x71),
        key(0x6B, "F16", 0x6A), key(0x6C, "F17", 0x40), f18,
        key(0x6E, "F19", 0x50), key(0x6F, "F20", 0x5A),
        key(0xE0, "Left Control", 0x3B), key(0xE1, "Left Shift", 0x38),
        key(0xE2, "Left Option", 0x3A), key(0xE3, "Left Command", 0x37),
        key(0xE4, "Right Control", 0x3E), key(0xE5, "Right Shift", 0x3C),
        key(0xE6, "Right Option", 0x3D), key(0xE7, "Right Command", 0x36),
    ]

    public static func key(for hidUsage: UInt64) -> PhysicalKey? {
        catalog.first { $0.hidUsage == hidUsage }
    }

    public static func isValidUsage(_ hidUsage: UInt64) -> Bool {
        key(for: hidUsage) != nil
    }

    private static func key(_ usage: UInt64, _ name: String, _ code: UInt16) -> PhysicalKey {
        PhysicalKey(hidUsage: 0x700000000 | usage, name: name, virtualKeyCode: code)
    }
}

extension KeyMapping {
    public var isValid: Bool {
        source != destination && PhysicalKey.isValidUsage(source) && PhysicalKey.isValidUsage(destination)
    }
}

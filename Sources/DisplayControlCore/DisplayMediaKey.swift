/// IOKit NX_KEYTYPE values for display brightness and sound. Keyboard illumination is separate.
public enum DisplayMediaKey: Int, CaseIterable, Hashable, Sendable {
    case volumeUp = 0
    case volumeDown = 1
    case brightnessUp = 2
    case brightnessDown = 3
    case mute = 7

    public var control: DisplayControl {
        switch self {
        case .brightnessUp, .brightnessDown: return .brightness
        case .volumeUp, .volumeDown, .mute: return .volume
        }
    }
}

/// Quartz's device-independent modifier bits. Caps Lock, Fn and device-side bits do not
/// change display adjustment; other macOS chords remain native except Option + Shift.
public enum DisplayMediaKeyAdjustment: Equatable, Sendable {
    case standard
    case fine

    public init?(modifierFlags: UInt64) {
        let shift: UInt64 = 1 << 17
        let control: UInt64 = 1 << 18
        let option: UInt64 = 1 << 19
        let command: UInt64 = 1 << 20
        switch modifierFlags & (shift | control | option | command) {
        case 0: self = .standard
        case shift | option: self = .fine
        default: return nil
        }
    }

    public var step: Double { self == .fine ? 1 / 64 : 1 / 16 }
}

/// Decodes data1 from a systemDefined media-key event. Subtype and modifier policy belong to
/// the shared input service, which also pairs swallowed key-down and key-up events.
public struct DisplayMediaKeyEvent: Equatable, Sendable {
    public let key: DisplayMediaKey
    public let isDown: Bool
    public let isRepeat: Bool

    public init?(data1: Int) {
        guard let key = DisplayMediaKey(rawValue: (data1 >> 16) & 0xffff) else { return nil }
        let state = (data1 >> 8) & 0xff
        guard state == 0x0a || state == 0x0b else { return nil }
        self.key = key
        self.isDown = state == 0x0a
        self.isRepeat = data1 & 1 != 0
    }
}

/// A repeat or release belongs to Lineup only when Lineup accepted its initial press.
public struct DisplayMediaKeyPressState {
    private var claimed: Set<DisplayMediaKey> = []

    public init() {}

    @discardableResult
    public mutating func handle(_ event: DisplayMediaKeyEvent,
                                claim: (DisplayMediaKey) -> Bool) -> Bool {
        if !event.isDown { return claimed.remove(event.key) != nil }
        if event.isRepeat {
            guard claimed.contains(event.key) else { return false }
            if event.key != .mute { _ = claim(event.key) }
            return true
        }
        claimed.remove(event.key)
        guard claim(event.key) else { return false }
        claimed.insert(event.key)
        return true
    }

    public mutating func release(_ keys: Set<DisplayMediaKey>) {
        claimed.subtract(keys)
    }

    public mutating func releaseAll() { claimed = [] }
}

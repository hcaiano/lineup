import Foundation

/// Which physical key, when held, Cycler turns into Hyper.
///
/// Caps Lock needs an OS-level remap (Cycler maps it to F18 via `hidutil`) because macOS otherwise
/// swallows it as a lock toggle. The physical function keys are already ordinary keys, so Cycler
/// can grab them straight from its event tap with no remap. F18-F20 remain decode-only legacy cases
/// so old config files load safely; they are never presented as choices.
public enum TriggerKey: String, Codable, Equatable, Hashable, Sendable, CaseIterable {
    case capsLock
    case leftControl
    case leftShift
    case leftOption
    case leftCommand
    case rightControl
    case rightShift
    case rightOption
    case rightCommand
    case f1
    case f2
    case f3
    case f4
    case f5
    case f6
    case f7
    case f8
    case f9
    case f10
    case f11
    case f12
    case f18
    case f19
    case f20

    /// Keys that exist on a standard Mac keyboard and are valid user-facing choices.
    public static let pickerCases: [TriggerKey] = [
        .capsLock,
        .leftControl, .leftShift, .leftOption, .leftCommand,
        .rightControl, .rightShift, .rightOption, .rightCommand,
        .f1, .f2, .f3, .f4, .f5, .f6,
        .f7, .f8, .f9, .f10, .f11, .f12,
    ]

    /// Human label for the trigger picker. Pure text (no AppKit), so it stays in CyclerCore.
    public var displayName: String {
        switch self {
        case .capsLock: return "Caps Lock"
        case .leftControl: return "Left Control (⌃)"
        case .leftShift: return "Left Shift (⇧)"
        case .leftOption: return "Left Option (⌥)"
        case .leftCommand: return "Left Command (⌘)"
        case .rightControl: return "Right Control (⌃)"
        case .rightShift: return "Right Shift (⇧)"
        case .rightOption: return "Right Option (⌥)"
        case .rightCommand: return "Right Command (⌘)"
        case .f1: return "F1"
        case .f2: return "F2"
        case .f3: return "F3"
        case .f4: return "F4"
        case .f5: return "F5"
        case .f6: return "F6"
        case .f7: return "F7"
        case .f8: return "F8"
        case .f9: return "F9"
        case .f10: return "F10"
        case .f11: return "F11"
        case .f12: return "F12"
        case .f18: return "F18"
        case .f19: return "F19"
        case .f20: return "F20"
        }
    }

    /// Whether engaging this trigger requires Cycler's `hidutil` remap. Only Caps Lock does; the
    /// function keys are caught directly by the event tap.
    public var needsCapsLockRemap: Bool { self == .capsLock }

    /// Modifier triggers arrive as `flagsChanged` events rather than key-down/key-up events.
    public var isModifier: Bool {
        switch self {
        case .leftControl, .leftShift, .leftOption, .leftCommand,
             .rightControl, .rightShift, .rightOption, .rightCommand:
            return true
        default:
            return false
        }
    }

    /// Side-specific device bit carried by a macOS flags-changed event for this modifier.
    public var deviceModifierRawBit: UInt64? {
        switch self {
        case .leftControl: return 0x0000_0001
        case .leftShift: return 0x0000_0002
        case .rightShift: return 0x0000_0004
        case .leftCommand: return 0x0000_0008
        case .rightCommand: return 0x0000_0010
        case .leftOption: return 0x0000_0020
        case .rightOption: return 0x0000_0040
        case .rightControl: return 0x0000_2000
        default: return nil
        }
    }
}

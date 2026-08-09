import AppKit
import Carbon.HIToolbox
import ZonesCore

/// App-side glue for the pure `Shortcuts` model: default bindings (Carbon key constants),
/// Cocoa↔Carbon modifier conversion, and human-readable combo strings.
enum ShortcutKit {
    /// Hyperkey = ⌃⌥⇧⌘ as a Carbon modifier mask.
    static let hyper = Int(controlKey) | Int(optionKey) | Int(shiftKey) | Int(cmdKey)
    static let defaultDragSnapModifiers = DragSnapModifierMask.default
    static let dragSnapModifierChoices: [(modifiers: Int, label: String)] = [
        (DragSnapModifierMask.shift, "Shift"),
        (DragSnapModifierMask.option, "Option"),
        (DragSnapModifierMask.control, "Control"),
        (DragSnapModifierMask.command, "Command"),
        (DragSnapModifierMask.control | DragSnapModifierMask.option, "Control-Option"),
        (DragSnapModifierMask.control | DragSnapModifierMask.shift, "Control-Shift"),
        (DragSnapModifierMask.option | DragSnapModifierMask.shift, "Option-Shift"),
        (DragSnapModifierMask.command | DragSnapModifierMask.shift, "Command-Shift"),
        (DragSnapModifierMask.control | DragSnapModifierMask.command, "Control-Command"),
        (DragSnapModifierMask.option | DragSnapModifierMask.command, "Option-Command"),
        (DragSnapModifierMask.control | DragSnapModifierMask.option | DragSnapModifierMask.shift, "Control-Option-Shift"),
        (DragSnapModifierMask.control | DragSnapModifierMask.option | DragSnapModifierMask.command, "Control-Option-Command"),
        (DragSnapModifierMask.control | DragSnapModifierMask.shift | DragSnapModifierMask.command, "Control-Shift-Command"),
        (DragSnapModifierMask.option | DragSnapModifierMask.shift | DragSnapModifierMask.command, "Option-Shift-Command"),
        (DragSnapModifierMask.hyper, "Hyper"),
    ]

    /// Actions shown in the Shortcuts tab, in order, with display names.
    static let quickActions: [(id: String, label: String)] = [
        ("full", "Full screen"),
        ("center", "Center"),
        ("left", "Left"),
        ("right", "Right"),
        ("leftHalf", "Left half"),
        ("rightHalf", "Right half"),
        ("restore", "Restore previous size"),
    ]
    /// How many positional Zone-N rows to offer (out-of-range ones disable themselves).
    static let zoneRows = 9

    /// Default bindings: ONLY the quick actions (the Magnet replacement). Zone shortcuts
    /// default to UNASSIGNED so they don't collide with combos users already use (e.g.
    /// Hyper+1…9). Users opt zones in via the recorder.
    static var defaults: Shortcuts {
        var s = Shortcuts()
        s = s.setting(action: "full", keyCode: kVK_UpArrow, modifiers: hyper)
        s = s.setting(action: "center", keyCode: kVK_DownArrow, modifiers: hyper)
        s = s.setting(action: "left", keyCode: kVK_LeftArrow, modifiers: hyper)
        s = s.setting(action: "right", keyCode: kVK_RightArrow, modifiers: hyper)
        s = s.setting(action: "leftHalf", keyCode: kVK_ANSI_LeftBracket, modifiers: hyper)
        s = s.setting(action: "rightHalf", keyCode: kVK_ANSI_RightBracket, modifiers: hyper)
        s = s.setting(action: "restore", keyCode: kVK_Delete, modifiers: hyper) // "delete the snap"
        return s
    }

    static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> Int {
        var m = 0
        if flags.contains(.command) { m |= Int(cmdKey) }
        if flags.contains(.option) { m |= Int(optionKey) }
        if flags.contains(.control) { m |= Int(controlKey) }
        if flags.contains(.shift) { m |= Int(shiftKey) }
        return m
    }

    static func hasModifier(_ flags: NSEvent.ModifierFlags) -> Bool {
        !flags.intersection([.command, .option, .control, .shift]).isEmpty
    }

    static func normalizedDragSnapModifiers(_ modifiers: Int?) -> Int {
        DragSnapModifierMask.normalized(modifiers)
    }

    static func dragSnapDisplay(keyCode: Int?, modifiers: Int) -> String {
        if let keyCode { return display(keyCode: keyCode, modifiers: modifiers) }
        return modifierDisplay(modifiers)
    }

    static func modifierDisplay(_ modifiers: Int) -> String {
        if let choice = dragSnapModifierChoices.first(where: { $0.modifiers == modifiers }) {
            return choice.label
        }
        var parts: [String] = []
        if modifiers & DragSnapModifierMask.control != 0 { parts.append("Control") }
        if modifiers & DragSnapModifierMask.option != 0 { parts.append("Option") }
        if modifiers & DragSnapModifierMask.shift != 0 { parts.append("Shift") }
        if modifiers & DragSnapModifierMask.command != 0 { parts.append("Command") }
        return parts.isEmpty ? "Shift" : parts.joined(separator: "-")
    }

    static func display(keyCode: Int, modifiers: Int) -> String {
        var s = ""
        if modifiers & Int(controlKey) != 0 { s += "⌃" }
        if modifiers & Int(optionKey) != 0 { s += "⌥" }
        if modifiers & Int(shiftKey) != 0 { s += "⇧" }
        if modifiers & Int(cmdKey) != 0 { s += "⌘" }
        return s + keyName(keyCode)
    }

    static func keyName(_ kc: Int) -> String {
        switch kc {
        case kVK_UpArrow: return "↑"
        case kVK_DownArrow: return "↓"
        case kVK_LeftArrow: return "←"
        case kVK_RightArrow: return "→"
        case kVK_ANSI_LeftBracket: return "["
        case kVK_ANSI_RightBracket: return "]"
        case kVK_Space: return "Space"
        case kVK_Return: return "↩"
        case kVK_Tab: return "⇥"
        case kVK_Delete: return "⌫"
        default:
            if let name = ShortcutKit.ansiNames[kc] { return name }
            return "key \(kc)"
        }
    }

    private static let ansiNames: [Int: String] = [
        kVK_ANSI_0: "0", kVK_ANSI_1: "1", kVK_ANSI_2: "2", kVK_ANSI_3: "3", kVK_ANSI_4: "4",
        kVK_ANSI_5: "5", kVK_ANSI_6: "6", kVK_ANSI_7: "7", kVK_ANSI_8: "8", kVK_ANSI_9: "9",
        kVK_ANSI_A: "A", kVK_ANSI_B: "B", kVK_ANSI_C: "C", kVK_ANSI_D: "D", kVK_ANSI_E: "E",
        kVK_ANSI_F: "F", kVK_ANSI_G: "G", kVK_ANSI_H: "H", kVK_ANSI_I: "I", kVK_ANSI_J: "J",
        kVK_ANSI_K: "K", kVK_ANSI_L: "L", kVK_ANSI_M: "M", kVK_ANSI_N: "N", kVK_ANSI_O: "O",
        kVK_ANSI_P: "P", kVK_ANSI_Q: "Q", kVK_ANSI_R: "R", kVK_ANSI_S: "S", kVK_ANSI_T: "T",
        kVK_ANSI_U: "U", kVK_ANSI_V: "V", kVK_ANSI_W: "W", kVK_ANSI_X: "X", kVK_ANSI_Y: "Y",
        kVK_ANSI_Z: "Z", kVK_ANSI_Minus: "-", kVK_ANSI_Equal: "=", kVK_ANSI_Semicolon: ";",
        kVK_ANSI_Quote: "'", kVK_ANSI_Comma: ",", kVK_ANSI_Period: ".", kVK_ANSI_Slash: "/",
        kVK_ANSI_Backslash: "\\", kVK_ANSI_Grave: "`",
    ]
}

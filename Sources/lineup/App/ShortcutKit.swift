import AppKit
import Carbon.HIToolbox
import TilesCore
import ZonesCore

/// App-side glue for the pure `Shortcuts` model: default bindings (Carbon key constants),
/// Cocoa↔Carbon modifier conversion, and human-readable combo strings.
///
/// Merged from Lineup's and Cycler's versions. `UInt32` is canonical — it is what Carbon's
/// `RegisterEventHotKey` and `AppBinding.modifiers` use. `ZonesCore.ShortcutBinding.modifiers`
/// stays `Int`, so the `Int` variants below are the boundary bridges, exactly as the 1.x code
/// already converted at the call site.
enum ShortcutKit {
    /// Hyperkey = ⌃⌥⇧⌘ as a Carbon modifier mask (`6912`). Canonical form.
    static let hyper: UInt32 =
        UInt32(controlKey) | UInt32(optionKey) | UInt32(shiftKey) | UInt32(cmdKey)
    /// The real Hyperkey mask when its optional physical Shift output is disabled (`6400`).
    /// Keep this separate from `hyper`: the two masks are both valid user choices.
    static let hyperWithoutShift: UInt32 =
        UInt32(controlKey) | UInt32(optionKey) | UInt32(cmdKey)
    /// The same mask for the `Int`-typed Zones shortcut model.
    static let hyperInt = Int(hyper)
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
    /// Hyper+1…9). Users opt zones in via the recorder. The quick-action arrows follow the
    /// current Hyperkey mode; with Include Shift off, a physical Shift is still required by
    /// the established full-Hyper (`6912`) defaults, so the compact preset uses the no-Shift
    /// mask (`6400`) for the same physical Caps+arrow gesture.
    /// The historical stored-section fallback. A legacy `LineupConfig` can contain a real
    /// section with `shortcuts == nil`; keep its established full-Hyper quick actions unchanged.
    static var defaults: Shortcuts { zonesDefaults(includeShift: true) }

    static func zonesDefaults(includeShift: Bool) -> Shortcuts {
        let mask = includeShift ? hyperInt : Int(hyperWithoutShift)
        var s = Shortcuts()
        s = s.setting(action: "full", keyCode: kVK_UpArrow, modifiers: mask)
        s = s.setting(action: "center", keyCode: kVK_DownArrow, modifiers: mask)
        s = s.setting(action: "left", keyCode: kVK_LeftArrow, modifiers: mask)
        s = s.setting(action: "right", keyCode: kVK_RightArrow, modifiers: mask)
        s = s.setting(action: "leftHalf", keyCode: kVK_ANSI_LeftBracket, modifiers: mask)
        s = s.setting(action: "rightHalf", keyCode: kVK_ANSI_RightBracket, modifiers: mask)
        s = s.setting(action: "restore", keyCode: kVK_Delete, modifiers: mask) // "delete the snap"
        return s
    }

    /// The first-use Tiles preset follows the user's Hyperkey mode. It is deliberately created
    /// here, at the AppKit/Carbon boundary, so the pure Tiles settings model stays independent of
    /// platform key constants. A caller must only materialize this when Tiles has no stored
    /// settings; an existing section, including one with explicit null bindings, wins unchanged.
    static func tilesDefaults(includeShift: Bool) -> TilesSettings {
        let base = includeShift ? hyper : hyperWithoutShift
        let focusKeys = [kVK_ANSI_H, kVK_ANSI_J, kVK_ANSI_K, kVK_ANSI_L]
        let moveKeys = includeShift
            ? [kVK_ANSI_U, kVK_ANSI_I, kVK_ANSI_O, kVK_ANSI_P]
            : focusKeys

        func binding(_ action: String, _ keyCode: Int, _ modifiers: UInt32) -> ShortcutBinding {
            ShortcutBinding(action: action, keyCode: keyCode,
                            modifiers: Int(truncatingIfNeeded: modifiers))
        }

        return TilesSettings(
            // The base remains useful in both modes. When Hyperkey includes
            // Shift, its physical Shift counterpart is the same combo and is
            // therefore intentionally not generated by the shell.
            workspace1: binding("workspace1", kVK_ANSI_1, base),
            workspace2: binding("workspace2", kVK_ANSI_2, base),
            workspace3: binding("workspace3", kVK_ANSI_3, base),
            workspace4: binding("workspace4", kVK_ANSI_4, base),
            nextWindow: binding("nextWindow", kVK_Tab, base),
            focusTileLeft: binding("focusTileLeft", focusKeys[0], base),
            focusTileRight: binding("focusTileRight", focusKeys[3], base),
            focusTileUp: binding("focusTileUp", focusKeys[2], base),
            focusTileDown: binding("focusTileDown", focusKeys[1], base),
            moveWindowLeft: binding("moveWindowLeft", moveKeys[0], hyper),
            moveWindowRight: binding("moveWindowRight", moveKeys[3], hyper),
            moveWindowUp: binding("moveWindowUp", moveKeys[2], hyper),
            moveWindowDown: binding("moveWindowDown", moveKeys[1], hyper),
            toggleSplitOrientation: binding("toggleSplitOrientation", kVK_Return, base),
            toggleTiled: binding("toggleTiled", kVK_Space, base))
    }

    /// Rebase an untouched Tiles preset when Hyperkey changes its emitted modifier mask. Spacing
    /// is independent user state and stays unchanged. One customized or cleared shortcut makes
    /// the whole set user-owned, so this returns nil and leaves every row alone.
    static func adaptingTilesDefaults(_ source: TilesSettings,
                                      from oldIncludeShift: Bool,
                                      to newIncludeShift: Bool) -> TilesSettings? {
        let old = tilesDefaults(includeShift: oldIncludeShift)
        guard tilesShortcutKeyPaths.allSatisfy({ source[keyPath: $0] == old[keyPath: $0] }) else {
            return nil
        }
        let fresh = tilesDefaults(includeShift: newIncludeShift)
        var adapted = source
        for keyPath in tilesShortcutKeyPaths {
            adapted[keyPath: keyPath] = fresh[keyPath: keyPath]
        }
        return adapted
    }

    private static let tilesShortcutKeyPaths: [WritableKeyPath<TilesSettings, ShortcutBinding?>] = [
        \.workspace1, \.workspace2, \.workspace3, \.workspace4,
        \.nextWorkspace, \.nextWindow, \.moveWindowToNextWorkspace,
        \.focusTileLeft, \.focusTileRight, \.focusTileUp, \.focusTileDown,
        \.moveWindowLeft, \.moveWindowRight, \.moveWindowUp, \.moveWindowDown,
        \.toggleSplitOrientation, \.toggleTiled,
    ]

    /// `Int` form, for the Zones shortcut model and the drag-snap masks.
    static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> Int {
        Int(carbonModifierMask(from: flags))
    }

    /// Canonical form, for Carbon registration and `AppBinding.modifiers`.
    static func carbonModifierMask(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var m: UInt32 = 0
        if flags.contains(.command) { m |= UInt32(cmdKey) }
        if flags.contains(.option) { m |= UInt32(optionKey) }
        if flags.contains(.control) { m |= UInt32(controlKey) }
        if flags.contains(.shift) { m |= UInt32(shiftKey) }
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

    /// Modifiers held on their own, as GLYPHS — the same `⌃⌥⇧⌘` order `display` uses.
    ///
    /// It used to answer in words ("Control-Option"), which is why the Zones pane showed a worded
    /// drag bind sitting directly above rows full of glyph caps. One vocabulary: the words survive
    /// as `modifierWords` for help text and VoiceOver, where a glyph reads as nothing.
    static func modifierDisplay(_ modifiers: Int) -> String {
        var s = ""
        if modifiers & DragSnapModifierMask.control != 0 { s += "⌃" }
        if modifiers & DragSnapModifierMask.option != 0 { s += "⌥" }
        if modifiers & DragSnapModifierMask.shift != 0 { s += "⇧" }
        if modifiers & DragSnapModifierMask.command != 0 { s += "⌘" }
        return s.isEmpty ? "⇧" : s
    }

    /// The spoken form of the same mask, for `help(_:)` and accessibility labels.
    static func modifierWords(_ modifiers: Int) -> String {
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
        display(keyCode: keyCode, modifiers: UInt32(bitPattern: Int32(truncatingIfNeeded: modifiers)))
    }

    /// The modifier glyphs `display(keyCode:modifiers:)` emits, in the order it emits them.
    static let modifierGlyphs: [Character] = ["⌃", "⌥", "⇧", "⌘"]

    /// Splits a display string into one token per key cap, for `KeyCapRow`.
    ///
    /// Works on the STRING rather than on a `(keyCode, modifiers)` pair on purpose: both recorder
    /// controls already receive a rendered display string (from three different producers —
    /// `display`, `modifierDisplay` and `dragSnapDisplay`), and one splitter keeps every one of
    /// them rendering identically. `⌃⌥⇧⌘←` → `["⌃","⌥","⇧","⌘","←"]`; the drag bind's worded form
    /// `Control-Option` → `["Control","Option"]`.
    static func keyCaps(_ display: String) -> [String] {
        guard !display.isEmpty else { return [] }
        var caps: [String] = []
        var rest = Substring(display)
        while let first = rest.first, modifierGlyphs.contains(first) {
            caps.append(String(first))
            rest = rest.dropFirst()
        }
        guard !rest.isEmpty else { return caps }
        if caps.isEmpty, rest.contains("-") {
            return rest.split(separator: "-").map(String.init)
        }
        caps.append(String(rest))
        return caps
    }

    /// Canonical form — what Cycler's bindings and the Carbon registry use.
    static func display(keyCode: Int, modifiers: UInt32) -> String {
        var s = ""
        if modifiers & UInt32(controlKey) != 0 { s += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { s += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { s += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { s += "⌘" }
        return s + keyName(keyCode)
    }

    /// Union of both apps' key tables. Cycler contributed `Esc`; the `[`/`]` entries were in
    /// both and are kept here only (not duplicated into `ansiNames`).
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
        case kVK_Escape: return "Esc"
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

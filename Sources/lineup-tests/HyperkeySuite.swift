import Foundation
import CyclerCore
import HyperkeyCore

// Hyperkey checks — moved out of cycler-tests/main.swift when TriggerKey and
// HyperKeySettings moved to their own module. CyclerCore is still imported because these
// checks also pin the LEGACY ~/.config/cycler/bindings.json decode path (CyclerConfig
// .hyperKey), which must keep working as the 2.0 migration source.

func runHyperkeyTests() throws {
    let hyperMask: UInt32 = 0x100 | 0x800 | 0x200 | 0x1000 // shift | cmd | option | control
    _ = hyperMask

    // ---- HyperKeySettings: off-by-default, backward-compatible decode, round-trip ----
    do {
        // Config JSON written before HyperKey existed must still decode, as the disabled defaults.
        let legacy = try CyclerConfig.decode(Data("{\"bindings\":[]}".utf8))
        check(legacy.hyperKey == .disabled, "missing hyperKey decodes to .disabled")
        check(legacy.hyperKey.enabled == false, "default hyperKey is off")
        check(legacy.hyperKey.triggerKey == .capsLock, "default trigger is Caps Lock")
        check(legacy.hyperKey.includeShift == true, "default includeShift is true")
    }
    do {
        // A real binding file from before this change (only the legacy singular key) still decodes,
        // and HyperKey is absent -> disabled.
        let legacy = try CyclerConfig.decode(Data(
            "{\"bindings\":[{\"keyCode\":18,\"modifiers\":6912,\"bundleIdentifier\":\"com.google.Chrome\"}]}".utf8))
        check(legacy.hyperKey == .disabled, "legacy binding file decodes with hyperKey disabled")
    }
    do {
        // An enabled Caps Lock / includeShift-true setting round-trips through JSON.
        let cfg = CyclerConfig(
            bindings: [AppBinding(keyCode: 18, modifiers: hyperMask, bundleIdentifier: "com.apple.Safari")],
            hyperKey: HyperKeySettings(enabled: true, triggerKey: .capsLock, includeShift: true))
        let back = try CyclerConfig.decode(try cfg.encoded())
        check(back == cfg, "config with enabled hyperKey round-trips")
        check(back.hyperKey.enabled, "enabled survives the round-trip")
        check(back.hyperKey.triggerKey == .capsLock, "trigger survives the round-trip")
        check(back.hyperKey.includeShift, "includeShift survives the round-trip")
        let json = String(decoding: try cfg.encoded(), as: UTF8.self)
        check(json.contains("\"hyperKey\""), "encode emits hyperKey")
    }
    do {
        // includeShift = false also round-trips, so the flag is genuinely persisted.
        let cfg = CyclerConfig(hyperKey: HyperKeySettings(enabled: true, triggerKey: .capsLock, includeShift: false))
        let back = try CyclerConfig.decode(try cfg.encoded())
        check(back.hyperKey == cfg.hyperKey, "includeShift=false round-trips")
        check(back.hyperKey.includeShift == false, "includeShift false survives the round-trip")
    }
    do {
        // The picker only exposes keys that exist on a standard Mac keyboard.
        check(TriggerKey.pickerCases == [
            .capsLock,
            .leftControl, .leftShift, .leftOption, .leftCommand,
            .rightControl, .rightShift, .rightOption, .rightCommand,
            .f1, .f2, .f3, .f4, .f5, .f6,
            .f7, .f8, .f9, .f10, .f11, .f12,
        ], "trigger picker only exposes physical keys in order")
        check(TriggerKey.capsLock.displayName == "Caps Lock", "Caps Lock trigger has a display name")
        check(TriggerKey.f1.displayName == "F1", "F1 trigger has a display name")
        check(TriggerKey.f12.displayName == "F12", "F12 trigger has a display name")
        check(TriggerKey.rightControl.displayName == "Right Control (⌃)", "modifier trigger has a display name")
        check(TriggerKey.capsLock.needsCapsLockRemap, "Caps Lock trigger needs the hidutil remap")
        check(!TriggerKey.f1.needsCapsLockRemap, "F1 trigger does not need the hidutil remap")
        check(!TriggerKey.f12.needsCapsLockRemap, "F12 trigger does not need the hidutil remap")
        check(TriggerKey.leftCommand.isModifier, "left Command is a modifier trigger")
        check(TriggerKey.rightControl.isModifier, "right Control is a modifier trigger")
        check(!TriggerKey.capsLock.isModifier, "Caps Lock is not handled as a modifier trigger")
        check(!TriggerKey.f12.isModifier, "F12 is not a modifier trigger")
        check(TriggerKey.leftControl.deviceModifierRawBit == 0x1, "left Control has its device flag")
        check(TriggerKey.rightControl.deviceModifierRawBit == 0x2000, "right Control has its device flag")
        check(TriggerKey.rightShift.deviceModifierRawBit == 0x4, "right Shift has its device flag")
        check(TriggerKey.rightOption.deviceModifierRawBit == 0x40, "right Option has its device flag")
        check(TriggerKey.rightCommand.deviceModifierRawBit == 0x10, "right Command has its device flag")
        check(TriggerKey.capsLock.deviceModifierRawBit == nil, "Caps Lock has no modifier device flag")

        let cfg = CyclerConfig(hyperKey: HyperKeySettings(enabled: true, triggerKey: .f12, includeShift: true))
        let back = try CyclerConfig.decode(try cfg.encoded())
        check(back.hyperKey.triggerKey == .f12, "F12 trigger round-trips")
        let json = String(decoding: try cfg.encoded(), as: UTF8.self)
        check(json.contains("\"triggerKey\" : \"f12\""), "encode emits the selected function trigger")

        let legacy = try CyclerConfig.decode(Data(
            "{\"bindings\":[],\"hyperKey\":{\"enabled\":true,\"triggerKey\":\"f19\",\"includeShift\":false}}".utf8))
        check(legacy.hyperKey.triggerKey == .capsLock, "legacy virtual trigger migrates to Caps Lock")
    }
    do {
        // Coalescing duplicate shortcuts must not drop the hyperKey setting.
        let cfg = CyclerConfig(
            bindings: [
                AppBinding(keyCode: 18, modifiers: hyperMask, bundleIdentifier: "com.openai.codex"),
                AppBinding(keyCode: 18, modifiers: hyperMask, bundleIdentifier: "com.google.Gemini"),
            ],
            hyperKey: HyperKeySettings(enabled: true, triggerKey: .capsLock, includeShift: false))
        let merged = cfg.coalescingDuplicateShortcuts()
        check(merged.bindings.count == 1, "duplicate shortcuts still coalesce with hyperKey present")
        check(merged.hyperKey == cfg.hyperKey, "coalescing preserves hyperKey")
    }
}

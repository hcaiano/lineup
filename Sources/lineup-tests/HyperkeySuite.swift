import Foundation
import AppCore
import CyclerCore
import HyperkeyCore

// Hyperkey checks — moved out of cycler-tests/main.swift when TriggerKey and
// HyperKeySettings moved to their own module. CyclerCore is still imported because these
// checks also pin the LEGACY ~/.config/cycler/bindings.json decode path (CyclerConfig
// .hyperKey), which must keep working as the 2.0 migration source.
//
// Phase 6 adds two groups below: the tool section's enabled-flag semantics, and the source-scan
// invariants that keep the Caps Lock `hidutil` handoff honest (plan §5.2(d)). The CGEventTap and
// hidutil paths themselves need Input Monitoring and a signed bundle, so they are manual QA.

func runHyperkeyTests() throws {
    try runHyperkeyModelTests()
    try runCapsLockMappingTests()
    try runHyperkeyToolSectionTests()
    try runHyperkeySourceScanTests()
    try runHyperkeyLifecycleScanTests()
}

// MARK: - The hidutil mapping dump (pure parsing)

/// `hidutil property --get UserKeyMapping` prints a CoreFoundation description (one per HID
/// service on macOS 27). The parsing lives
/// in `HyperkeyCore` precisely so it can be checked here: the app target is an AppKit executable
/// this runner cannot import, and getting "is this mapping ours?" wrong either strands the user's
/// Caps Lock or wipes a mapping that belongs to somebody else.
private func runCapsLockMappingTests() throws {
    /// What macOS actually prints for one Caps Lock -> F18 remap.
    func dump(_ pairs: [(src: UInt64, dst: UInt64)]) -> String {
        let entries = pairs.map {
            "    {\n        HIDKeyboardModifierMappingDst = \($0.dst);\n"
                + "        HIDKeyboardModifierMappingSrc = \($0.src);\n    }"
        }
        return "(\n" + entries.joined(separator: ",\n") + "\n)\n"
    }
    let caps = CapsLockMapping.capsLockHID
    let f18 = CapsLockMapping.f18HID

    check(caps == 0x700000039, "Caps Lock keeps its HID usage value")
    check(f18 == 0x70000006D, "F18 keeps its HID usage value")

    // ---- Empty ----
    for empty in ["()", "(null)", "null", " ( ) \n"] {
        check(CapsLockMapping.isEmpty(empty), "\"\(empty)\" reads as an empty mapping")
        check(!CapsLockMapping.isLineupMapping(empty), "\"\(empty)\" is not our mapping")
    }
    // A hidutil that failed to run produces nothing at all; treating that as "nothing is mapped"
    // would let us stomp on a mapping we never actually read.
    check(!CapsLockMapping.isEmpty(""), "no output at all is NOT an empty mapping")

    // ---- Ours ----
    check(CapsLockMapping.isLineupMapping(dump([(caps, f18)])),
          "the CapsLock->F18 mapping reads as ours")
    check(CapsLockMapping.pairs(in: dump([(caps, f18)]))
          == [CapsLockMapping.Pair(src: caps, dst: f18)],
          "one printed dictionary parses to one Src->Dst pair")
    check(CapsLockMapping.isLineupMapping(
        "({HIDKeyboardModifierMappingSrc = 0x700000039; HIDKeyboardModifierMappingDst = 0x70000006D;})"),
          "a hexadecimal dump of the same mapping still reads as ours")
    check(CapsLockMapping.isLineupMapping(
        "({\"HIDKeyboardModifierMappingSrc\"=30064771129;\"HIDKeyboardModifierMappingDst\"=30064771181;})"),
          "quoting and missing spaces do not change the answer")

    // ---- Not ours ----
    // THE regression this parser exists for: a REVERSED mapping contains exactly the same two
    // numbers, and counting occurrences claimed it as ours — so Lineup would have cleared an
    // F18 -> Caps Lock remap somebody else installed.
    check(!CapsLockMapping.isLineupMapping(dump([(f18, caps)])),
          "a reversed F18->CapsLock mapping is NOT ours")
    check(!CapsLockMapping.isLineupMapping(dump([(caps, 0x700000029)])),
          "CapsLock remapped to something else is not ours")
    check(!CapsLockMapping.isLineupMapping(dump([(0x700000029, f18)])),
          "another key remapped to F18 is not ours")
    // Ours plus somebody else's: clearing that would take their remap with it.
    let two = dump([(caps, f18), (0x700000029, 0x700000039)])
    check(CapsLockMapping.pairs(in: two).count == 2, "two printed dictionaries parse to two pairs")
    check(!CapsLockMapping.isLineupMapping(two),
          "our mapping alongside another user mapping is not claimed as ours")
    check(CapsLockMapping.pairs(in: "(\n)\n").isEmpty, "an empty dump has no pairs")
    check(CapsLockMapping.pairs(in: "({HIDKeyboardModifierMappingSrc = 30064771129;})").isEmpty,
          "a Src with no Dst is not a pair")

    // ---- macOS 27 per-service table ----
    // macOS 27 prints one row per HID service. Before this was parsed, every table read as
    // "somebody else's mapping" and Hyper Key stayed blocked on every launch.
    func table(_ values: [String]) -> String {
        let rows = values.enumerated().map { index, value in
            "10000\(String(0xb49 + index, radix: 16))   UserKeyMapping   \(value)"
        }
        return (["RegistryID  Key                   Value"] + rows).joined(separator: "\n") + "\n"
    }
    let ours = dump([(caps, f18)])
    let freshBoot = table(["(null)", "(\n)", "(null)"])
    check(CapsLockMapping.isEmpty(freshBoot), "a table of (null) and () services reads as empty")
    check(!CapsLockMapping.isLineupMapping(freshBoot), "an empty table is not our mapping")

    // What Lineup's own `--set` leaves behind: our pair everywhere, `(null)` where a service does
    // not hold the property.
    let applied = table([ours, "(null)", ours])
    check(CapsLockMapping.state(of: applied) == .lineup,
          "our mapping on every service that holds one reads as fully installed")
    check(CapsLockMapping.isLineupMapping(applied), "a fully installed table is ours")
    check(!CapsLockMapping.isEmpty(applied), "a table with our mapping is not empty")

    // Our pair on some keyboards, an explicit `()` on another: same shape, not installed there.
    // Cleanup may still clear it (that only empties services); installing re-applies only a
    // mapping Lineup owns.
    let partial = table([ours, "(\n)", "(null)"])
    check(CapsLockMapping.state(of: partial) == .partialLineup,
          "our mapping next to an explicitly empty service reads as partial")
    check(CapsLockMapping.isLineupMapping(partial) && !CapsLockMapping.isEmpty(partial),
          "a partial table keeps our shape for cleanup and is not empty")

    check(!CapsLockMapping.isLineupMapping(table([ours, dump([(f18, caps)])])),
          "one service with a reversed mapping makes the table not ours")
    check(!CapsLockMapping.isLineupMapping(table([ours, dump([(caps, f18), (0x700000029, caps)])])),
          "one service with an extra remap makes the table not ours")
    check(!CapsLockMapping.isEmpty(table([])) && !CapsLockMapping.isLineupMapping(table([])),
          "a header with no service rows is neither empty nor ours")
    check(!CapsLockMapping.isEmpty(table(["(null)", ""])),
          "a service row with no value is not read as empty")

    // ---- Unreadable or incomplete dumps are never empty and never ours ----
    // Each of these once let a malformed or cut-off dump pass for "nothing mapped" or "only ours",
    // which would authorize a global write or a clear over somebody else's remap.
    let header = "RegistryID  Key                   Value\n"
    let badRowFirst = header + "BAD-ID   UserKeyMapping   " + dump([(f18, caps)])
        + "100000b49   UserKeyMapping   ()\n"
    check(CapsLockMapping.state(of: badRowFirst) == .foreign,
          "a row whose registry ID is not hexadecimal makes the table unreadable")
    let strayLine = header + "    {\n100000b49   UserKeyMapping   ()\n"
    check(CapsLockMapping.state(of: strayLine) == .foreign,
          "a line before the first row makes the table unreadable")
    let afterClose = header + "100000b49   UserKeyMapping   " + ours + "unexpected ()\n"
    check(CapsLockMapping.state(of: afterClose) == .foreign,
          "a line after a row's value has closed makes the table unreadable")
    let truncatedExtra = "(\n    {\n        HIDKeyboardModifierMappingDst = \(f18);\n"
        + "        HIDKeyboardModifierMappingSrc = \(caps);\n    },\n    {\n"
        + "        HIDKeyboardModifierMappingSrc = 30064771113;\n"
    check(!CapsLockMapping.isLineupMapping(table([ours, truncatedExtra])),
          "a service whose extra dictionary was cut off is not ours")
    check(!CapsLockMapping.isLineupMapping(truncatedExtra),
          "a single-value dump cut off inside an extra dictionary is not ours")
    check(!CapsLockMapping.isLineupMapping(
        "({HIDKeyboardModifierMappingSrc = 30064771129; HIDKeyboardModifierMappingDst = 30064771181;},"
            + "{HIDKeyboardModifierMappingSrc = 30064771113;})"),
          "our pair next to a dictionary with no Dst is not ours")
}

private func runHyperkeyModelTests() throws {
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

// MARK: - The tool section (config.json → tools.hyperkey)

/// Two "enabled" flags describe Hyperkey and they are NOT peers: `ToolSection.enabled` is
/// authoritative (it is what `ToolRegistry` starts and stops the tool from), while
/// `HyperKeySettings.enabled` inside the blob only exists because the blob IS the legacy Cycler
/// `hyperKey` shape. `HyperkeyTool` writes the blob's flag to match the tool flag on every save.
private func runHyperkeyToolSectionTests() throws {
    // ---- HyperKeySettings round-trips through an opaque tool section ----
    do {
        var cfg = LineupAppConfig()
        let settings = HyperKeySettings(enabled: true, triggerKey: .f12, includeShift: false)
        try cfg.setSettings(settings, for: .hyperkey)
        cfg.setEnabled(true, for: .hyperkey)
        let back = try JSONDecoder().decode(LineupAppConfig.self, from: try cfg.encoded())
        check(try back.settings(HyperKeySettings.self, for: .hyperkey) == settings,
              "HyperKeySettings round-trips through the hyperkey tool section")
        check(back.isEnabled(.hyperkey) == true, "the hyperkey section's enabled flag round-trips")
        let json = String(decoding: try back.encoded(), as: UTF8.self)
        check(json.contains("\"triggerKey\" : \"f12\""),
              "the hyperkey section stores the trigger key by name")
    }

    // ---- The TOOL flag is authoritative in both directions ----
    do {
        // A blob that says enabled:true inside a section that is off must NOT make the tool run:
        // ToolRegistry only ever reads the section flag.
        var cfg = LineupAppConfig()
        try cfg.setSettings(HyperKeySettings(enabled: true, triggerKey: .capsLock, includeShift: true),
                            for: .hyperkey)
        cfg.setEnabled(false, for: .hyperkey)
        check(cfg.isEnabled(.hyperkey) == false,
              "a stale enabled:true blob does not enable the tool")
        check(try cfg.settings(HyperKeySettings.self, for: .hyperkey)?.triggerKey == .capsLock,
              "the blob's other fields survive a disabled section")

        // And the mirror image: an off blob inside an enabled section still runs.
        cfg.setEnabled(true, for: .hyperkey)
        check(cfg.isEnabled(.hyperkey) == true, "the section flag alone decides that the tool runs")
    }

    // ---- No section yet: the tool's own default (off) applies ----
    do {
        let cfg = LineupAppConfig()
        check(cfg.isEnabled(.hyperkey) == nil,
              "a fresh config has no hyperkey section, so the tool's defaultEnabled applies")
        check(try cfg.settings(HyperKeySettings.self, for: .hyperkey) == nil,
              "a fresh config has no hyperkey settings")
        check(HyperKeySettings.disabled.enabled == false,
              "the fallback settings are off — an auto-update never grabs Caps Lock by itself")
    }

    // ---- Saving hyperkey never disturbs a sibling tool ----
    do {
        var cfg = LineupAppConfig()
        try cfg.setSettings(CyclerToolSettings(bindings: [
            AppBinding(keyCode: 18, modifiers: 0x1F00, bundleIdentifier: "com.apple.Safari"),
        ]), for: .cycler)
        let cyclerBefore = cfg.section(for: .cycler)
        try cfg.setSettings(HyperKeySettings(enabled: true, triggerKey: .f12, includeShift: true),
                            for: .hyperkey)
        check(cfg.section(for: .cycler) == cyclerBefore,
              "saving the hyperkey section leaves the cycler section byte-identical")
    }
}

// MARK: - Source scans (plan §5.2(d) and the Phase 6 lifecycle contract)

private func hyperkeySourceFiles() -> [(path: String, text: String)] {
    let root = "Sources"
    guard let en = FileManager.default.enumerator(atPath: root) else { return [] }
    var out: [(String, String)] = []
    for case let rel as String in en where rel.hasSuffix(".swift") {
        // The test target is excluded: these invariants are about the SHIPPING sources, and the
        // scans themselves necessarily contain the strings they look for.
        if rel.hasPrefix("lineup-tests/") { continue }
        let path = "\(root)/\(rel)"
        if let text = try? String(contentsOfFile: path, encoding: .utf8) { out.append((path, text)) }
    }
    return out.sorted { $0.0 < $1.0 }
}

private func runHyperkeySourceScanTests() throws {
    let files = hyperkeySourceFiles()
    func source(_ path: String) -> String { files.first { $0.path == path }?.text ?? "" }
    let handoff = source("Sources/lineup/Tools/Hyperkey/CapsLockHandoff.swift")
    let mappingService = source("Sources/lineup/App/KeyboardMappingService.swift")

    // These literals are migration contracts with previously shipped applications.
    for (key, owner) in [
        ("lineup.ownsCapsLockToF18Mapping", "Sources/lineup/Tools/Hyperkey/CapsLockHandoff.swift"),
        ("CyclerOwnsCapsLockToF18Mapping", "Sources/lineup/Tools/Hyperkey/CapsLockHandoff.swift"),
    ] {
        let matchingFiles = files.filter { $0.text.contains("\"\(key)\"") }.map(\.path)
        let occurrences = files.reduce(0) { $0 + $1.text.components(separatedBy: "\"\(key)\"").count - 1 }
        check(matchingFiles == [owner] && occurrences == 1,
              "the shipped ownership key \(key) has one migration owner")
    }
    check(handoff.contains("SingleInstance.legacyCyclerBundleID"),
          "legacy ownership migration uses the standalone Cycler identity")

    // The runner cannot import the macOS executable. Keep the OS write boundary here;
    // composition, ownership and failed transactions have behavior checks in KeyboardRemapSuite.
    let mappingWriters = files.filter { $0.text.contains("IOHIDServiceClientSetProperty(") }.map(\.path)
    check(mappingWriters == ["Sources/lineup/App/KeyboardMappingService.swift"],
          "per-keyboard HID writes have one owner shared by both tools")
    check(!files.contains { $0.text.contains("/usr/bin/hidutil") && $0.text.contains("--set") },
          "shipping code never replaces every keyboard table through a global hidutil write")
    let signalOwners = files.filter { $0.text.contains("DispatchSource.makeSignalSource") }.map(\.path)
    check(signalOwners == ["Sources/lineup/App/TerminationCoordinator.swift"],
          "signals run the shell's shared termination cleanup")
    check(mappingService.contains("atexit {") && mappingService.contains("wait(timeout:"),
          "keyboard mapping exit cleanup is bounded")

    let requestOwners = files.filter { $0.text.contains("CGRequestListenEventAccess") }.map(\.path)
    check(requestOwners == ["Sources/lineup/App/PermissionCenter.swift",
                            "Sources/lineup/Tools/Hyperkey/HyperKeyController.swift"],
          "only permission setup and the Hyperkey tap request Input Monitoring")
    let shell = source("Sources/lineup/App/AppShell.swift")
    check(!shell.contains("CGRequestListenEventAccess") && !shell.contains("requestInputMonitoring"),
          "launch never asks for Input Monitoring")
}

private func runHyperkeyLifecycleScanTests() throws {
    let files = hyperkeySourceFiles()
    func source(_ path: String) -> String { files.first { $0.path == path }?.text ?? "" }
    let controller = source("Sources/lineup/Tools/Hyperkey/HyperKeyController.swift")
    let tool = source("Sources/lineup/Tools/Hyperkey/HyperkeyTool.swift")

    // Native tap health and teardown need a real Input Monitoring grant. These guards name
    // platform operations, rather than the private mapping implementation moved into the core.
    check(controller.contains("CFMachPortInvalidate(tap)")
          && controller.contains("CFRunLoopSourceInvalidate(source)"),
          "Hyperkey invalidates both its event tap and run-loop source at teardown")
    check(controller.contains("CGEvent.tapIsEnabled(tap: tap)")
          && controller.contains("CGEvent.tapEnable(tap: tap, enable: true)"),
          "Hyperkey can rearm an event tap disabled by macOS")
    check(tool.contains("NSWorkspace.didWakeNotification")
          && tool.contains("NSApplication.didBecomeActiveNotification"),
          "Hyperkey reconciles after wake and permission changes")
    let wake = tool.components(separatedBy: "if didWake {").last?
        .components(separatedBy: "} else {").first ?? ""
    check(wake.contains("controller.resetTriggerState()"),
          "wake releases synthetic modifiers held before suspension")
}

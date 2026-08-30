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

/// `hidutil property --get UserKeyMapping` prints a CoreFoundation description. The parsing lives
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
        check(legacy.hyperKey.includeShift == false, "default includeShift is false")
        let fresh = HyperKeySettings()
        check(fresh.includeShift == false, "new Hyperkey settings leave Shift available by default")
    }
    do {
        // The legacy object predates includeShift. Keep its established full-Hyper behavior when
        // that field is absent; explicit true and false values remain covered below.
        let legacy = try CyclerConfig.decode(Data(
            #"{"bindings":[],"hyperKey":{"enabled":true,"triggerKey":"capsLock"}}"#.utf8))
        check(legacy.hyperKey.includeShift == true,
              "legacy Hyperkey without includeShift keeps the full-Hyper behavior")
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
    check(!files.isEmpty, "hyperkey source scan finds Swift files")
    let paths = Set(files.map(\.path))
    for file in ["HyperkeyTool", "HyperkeySettingsPane", "HyperKeyController",
                 "HyperKeyBlockedPill", "CapsLockHandoff"] {
        check(paths.contains("Sources/lineup/Tools/Hyperkey/\(file).swift"),
              "Tools/Hyperkey/\(file).swift exists")
    }

    func text(_ path: String) -> String {
        files.first { $0.path == path }?.text ?? ""
    }
    let handoff = text("Sources/lineup/Tools/Hyperkey/CapsLockHandoff.swift")
    let controller = text("Sources/lineup/Tools/Hyperkey/HyperKeyController.swift")
    let tool = text("Sources/lineup/Tools/Hyperkey/HyperkeyTool.swift")
    let pane = text("Sources/lineup/Tools/Hyperkey/HyperkeySettingsPane.swift")

    // ---- §5.2(d): the ownership keys ----
    // The mapping flag moved into Lineup's own defaults domain, matching the lineup.* convention.
    check(handoff.contains(#"static let newKey = "lineup.ownsCapsLockToF18Mapping""#),
          "CapsLockHandoff declares the Lineup ownership key exactly as specified")
    let newKeyOccurrences = files.reduce(0) {
        $0 + $1.text.components(separatedBy: "\"lineup.ownsCapsLockToF18Mapping\"").count - 1
    }
    check(newKeyOccurrences == 1,
          "the Lineup ownership key literal appears exactly once in Sources/ (got \(newKeyOccurrences))")
    // Standalone Cycler's key is SUPERSEDED: it may only be named by the handoff that retires it.
    // A second mention would mean somebody re-implemented the adoption elsewhere.
    let legacyKeyFiles = files.filter { $0.text.contains("CyclerOwnsCapsLockToF18Mapping") }.map(\.path)
    check(legacyKeyFiles == ["Sources/lineup/Tools/Hyperkey/CapsLockHandoff.swift"],
          "the legacy Cycler ownership key is named only by CapsLockHandoff (got \(legacyKeyFiles))")
    let legacyKeyOccurrences = files.reduce(0) {
        $0 + $1.text.components(separatedBy: "CyclerOwnsCapsLockToF18Mapping").count - 1
    }
    check(legacyKeyOccurrences == 1,
          "the legacy Cycler ownership key literal appears exactly once in Sources/ (got \(legacyKeyOccurrences))")
    check(controller.contains("CapsLockHandoff.newKey"),
          "HyperKeyController reads the ownership key from CapsLockHandoff, not a literal of its own")

    // The handoff has to do BOTH halves, or a later Cycler run double-claims the mapping.
    check(handoff.contains("legacy.removeObject(forKey: legacyKey)"),
          "adoption clears the legacy flag in the cycler domain")
    check(handoff.contains("UserDefaults(suiteName: legacySuite)"),
          "the handoff reads and writes the com.caiano.cycler domain directly")
    check(handoff.contains("static let legacySuite = SingleInstance.legacyCyclerBundleID"),
          "the legacy defaults suite and the standalone-Cycler process check share one bundle ID")
    for member in ["adoptLegacyOwnershipIfNeeded", "orphanedMappingDetected", "restoreCapsLock"] {
        check(handoff.contains("func \(member)"), "CapsLockHandoff exposes \(member)()")
    }
    check(tool.contains("CapsLockHandoff.adoptLegacyOwnershipIfNeeded()"),
          "HyperkeyTool.start() adopts a legacy Caps Lock mapping before the first apply()")

    // Orphan detection must key on LIVENESS, not on the legacy flag: Cycler clears that flag only
    // on a clean teardown, so the crash it is meant to catch leaves the flag set. Keying on the
    // flag would make the recovery button invisible in exactly the case it exists for.
    let orphanBody = handoff.components(separatedBy: "func orphanedMappingDetected").last ?? ""
    let orphanScope = orphanBody.components(separatedBy: "func restoreCapsLock").first ?? ""
    check(orphanScope.contains("SingleInstance.standaloneCyclerIsRunning() == nil"),
          "an orphaned mapping means standalone Cycler is NOT running")
    check(!orphanScope.contains("legacyKey"),
          "orphan detection does not consult the legacy ownership flag (a crash leaves it set)")
    check(orphanScope.contains("!HyperKeyController.ownsCapsLockMapping"),
          "a mapping Lineup owns is never reported as orphaned")
    // Raycast's Hyper Key installs the identical CapsLock->F18 mapping.
    check(orphanScope.contains("!HyperKeyController.raycastCapsHyperEnabled()"),
          "a mapping a live Raycast Hyper Key owns is never reported as orphaned")
    // Recovery must forget BOTH claims, or the next launch adopts a mapping that no longer exists.
    let restoreScope = handoff.components(separatedBy: "func restoreCapsLock").last ?? ""
    check(restoreScope.contains("HyperKeyController.clearIfMappingIsOursAsync"),
          "restore clears the mapping only after re-confirming its shape")
    check(restoreScope.contains("releaseOwnedMapping()")
          && restoreScope.contains("removeObject(forKey: legacyKey)"),
          "restore drops both Lineup's and Cycler's ownership claims")

    // ---- Retargeting: nothing in the tool may still point at Cycler's identity ----
    let cyclerSubsystem = files.filter { $0.text.contains("Logger(subsystem: \"") }.map(\.path)
    check(cyclerSubsystem.isEmpty,
          "every Logger uses Product.logSubsystem, never a hardcoded subsystem (got \(cyclerSubsystem))")
    check(controller.contains("DispatchQueue(label: Product.bundleID + \".hidutil\")"),
          "the hidutil queue label is derived from Product.bundleID, not hardcoded")
    let hidutilFiles = files.filter { $0.text.contains("/usr/bin/hidutil") }.map(\.path)
    check(hidutilFiles == ["Sources/lineup/Tools/Hyperkey/HyperKeyController.swift"],
          "hidutil is only ever run from HyperKeyController (got \(hidutilFiles))")

    // ---- Lifecycle: signals are the shell's, the atexit drain is the controller's ----
    // Cycler's own SIGINT/SIGTERM/SIGHUP sources are deliberately NOT ported: they exit(128+sig)
    // after only the hyper-key cleanup, which would skip Zones' and Cycler's teardown.
    let signalFiles = files.filter { $0.text.contains("DispatchSource.makeSignalSource") }.map(\.path)
    check(signalFiles == ["Sources/lineup/App/TerminationCoordinator.swift"],
          "signal handling stays in TerminationCoordinator (got \(signalFiles))")
    check(controller.contains("atexit {") && controller.contains("HyperKeyController.hidutilQueue.async"),
          "HyperKeyController keeps the static atexit drain for an in-flight remap")
    // ...but the drain is BOUNDED. `hidutilQueue.sync {}` behind a wedged hidutil hangs quit
    // forever, and an agent with no window and no menu bar icon can only be force-quit.
    check(!controller.contains("hidutilQueue.sync"),
          "the atexit drain never blocks on the whole hidutil queue")
    check(controller.contains("drained.wait(timeout: deadline)")
          && controller.contains("atexitDrainTimeout"),
          "the atexit drain waits with a timeout and gives up rather than hanging quit")
    check(tool.contains("services.termination.addCleanup(.hyperkey)")
          && tool.contains("services?.termination.removeCleanup(.hyperkey)"),
          "HyperkeyTool registers its termination cleanup in start() and removes it in stop()")
    check(tool.contains("controller.stop()") && tool.contains("HyperKeyBlockedPill.shared.hide()"),
          "stop() tears the controller down and hides the blocked pill")
    check(tool.contains("NSWorkspace.didWakeNotification")
          && tool.contains("NSApplication.didBecomeActiveNotification"),
          "HyperkeyTool re-applies on wake and on becoming active")
    check(tool.contains("for entry in observers { entry.center.removeObserver(entry.token) }"),
          "stop() removes every observer start() added")

    // ---- The two "enabled" flags, on the implementation side ----
    // The section flag decides everything; the blob's flag is written to match and never read.
    check(tool.contains("settings.enabled = isRunning"),
          "every save mirrors the authoritative tool flag into the HyperKeySettings blob")
    check(tool.contains("effective.enabled = true"),
          "apply() takes enabled from the tool's running state, never from the blob")

    // ---- The standalone-Cycler guard (plan §5.2(b)) ----
    check(controller.contains(#"static let standaloneCyclerBlockedMessage = "Cycler is running. Quit it to use Hyperkey here""#),
          "the standalone-Cycler block carries the specified message")
    check(tool.contains("SingleInstance.standaloneCyclerIsRunning() != nil"),
          "HyperkeyTool checks for a running standalone Cycler before each apply()")
    check(controller.contains("if settings.triggerKey.needsCapsLockRemap, blockedByStandaloneCycler"),
          "the Cycler block only applies to triggers that need the Caps Lock remap")

    // ---- Input Monitoring is requested ONLY on first enable, never at launch ----
    let requestFiles = files.filter { $0.text.contains("CGRequestListenEventAccess") }.map(\.path)
    check(requestFiles == ["Sources/lineup/App/PermissionCenter.swift",
                           "Sources/lineup/Tools/Hyperkey/HyperKeyController.swift"],
          "Input Monitoring is requested only by PermissionCenter and the hyper-key tap (got \(requestFiles))")
    let shell = text("Sources/lineup/App/AppShell.swift")
    check(!shell.contains("requestInputMonitoring") && !shell.contains("CGRequestListenEventAccess"),
          "the shell never asks for Input Monitoring at launch")
    // Loose on the argument list: phases 4/5 and the integration agent edit the same lines, and
    // this only has to prove the tool reaches the registry.
    check(shell.contains("registry.register(HyperkeyTool("),
          "HyperkeyTool is registered by the shell")
    check(tool.contains("persistIncludeShiftChange")
            && tool.contains("guard persistIncludeShift(rollingBackTo: previous) else { return }")
            && tool.contains("try persistIncludeShiftChange(previous, settings)")
            && tool.contains("settings = previous")
            && tool.contains("apply()"),
          "Include Shift delegates the atomic sibling update and rolls the visible setting back on failure")
    check(tool.contains("system-wide ⌃⌥⌘ modifier; Shift is optional")
            && !tool.contains("system-wide ⌃⌥⇧⌘ modifier"),
          "Hyperkey's user-facing summary matches the compact default")

    // ---- The pane (plan §6.4 + the recovery affordance) ----
    check(pane.contains("Lineup leaves ⇧ available for move/reverse shortcuts."),
          "the Hyperkey pane explains that Shift remains available for move and reverse shortcuts")
    check(pane.contains("TriggerKey.pickerCases"), "the pane offers the trigger picker")
    check(pane.contains("model.includeShift"), "the pane offers the includeShift toggle")
    check(pane.contains("Restore Caps Lock"), "the pane offers the Caps Lock recovery button")
    check(pane.contains("model.orphanedMapping"),
          "the recovery button is shown only when an orphaned mapping is detected")
    check(pane.contains("SettingsSectionView") && pane.contains("SettingsRow"),
          "the pane is built on the shared Settings components")
    check(!pane.contains("RecorderButton") && !pane.contains("ShortcutField"),
          "the pane needs no shortcut recorder")
}

// MARK: - Review fixes: teardown, tap health, adoption liveness, apply churn

/// Four failure modes that all end with the user's Caps Lock (or their whole keyboard) in a state
/// only a reboot or a reinstall fixes. None of them can be exercised here — they need Input
/// Monitoring, a signed bundle and a real `hidutil` — so what is pinned is the code shape that
/// makes each one impossible.
private func runHyperkeyLifecycleScanTests() throws {
    let files = hyperkeySourceFiles()
    func text(_ path: String) -> String { files.first { $0.path == path }?.text ?? "" }
    let controller = text("Sources/lineup/Tools/Hyperkey/HyperKeyController.swift")
    let handoff = text("Sources/lineup/Tools/Hyperkey/CapsLockHandoff.swift")
    let tool = text("Sources/lineup/Tools/Hyperkey/HyperkeyTool.swift")

    // ---- (1) A fast toggle-off must not strand the Caps Lock remap ----
    // `didApplyMapping` is set in the hidutil COMPLETION, which a real stop() has just cancelled
    // (`invalidatingPending`) — while the background ensureCapsLockMapping may already have
    // applied the mapping and recorded ownership. Gating the cleanup on that flag left Caps Lock
    // remapped for the rest of the session for anyone who switched Hyperkey on and straight back
    // off. The clear self-gates on the persisted ownership flag, so it is asked unconditionally.
    let stopScope = controller
        .components(separatedBy: "private func stop(invalidatingPending:").last?
        .components(separatedBy: "fileprivate func handle(").first ?? ""
    check(!stopScope.isEmpty, "HyperKeyController.stop(invalidatingPending:) is scannable")
    check(stopScope.contains("if hadMapping || invalidatingPending {")
          && stopScope.contains("Self.clearKnownOwnedMappingAsync()"),
          "a cancelling stop() always asks for the owned mapping back, flag or no flag")
    check(controller.contains("guard ownsCapsLockMapping else { return false }"),
          "clearKnownOwnedMapping self-gates on the persisted ownership flag")
    // The tap and its run-loop source are invalidated, not just detached.
    check(stopScope.contains("CFMachPortInvalidate(tap)")
          && stopScope.contains("CFRunLoopSourceInvalidate(source)"),
          "stop() invalidates the mach port and the run-loop source before dropping them")
    // One state transition per gate, so the menu never flashes "disabled" on the way to "blocked".
    check(controller.contains("private func stop(invalidatingPending: Bool, settingState newState: State = .disabled)"),
          "stop() takes the state it should settle on, so a blocked apply() fires onStateChange once")
    check(controller.contains("private func stopAndClearMapping(settingState newState: State)"),
          "every blocked gate goes through one stop-and-clear helper")

    // ---- (2) The tap is health-checked, and wake resets the state machine ----
    // `if tap != nil { return .started }` made the wake re-apply a no-op: the system disables a
    // tap on timeout, on a user-input storm and across sleep, and the object stays non-nil.
    check(controller.contains("CGEvent.tapIsEnabled(tap: tap)"),
          "startTap re-arms a tap the system disabled instead of assuming it is live")
    check(controller.contains("func resetTriggerState()")
          && controller.contains("triggerDown = false"),
          "the controller can drop a latched trigger without a full teardown")
    let wakeScope = tool.components(separatedBy: "if didWake {").last?
        .components(separatedBy: "} else {").first ?? ""
    check(wakeScope.contains("controller.resetTriggerState()") && wakeScope.contains("apply(force: true)"),
          "wake releases the synthetic modifiers and re-applies in full")

    // ---- (3) Adoption must not wipe a RUNNING standalone Cycler's mapping ----
    // Adopting on shape alone took over the mapping a live Cycler was using — and HyperkeyTool's
    // own standalone-Cycler block then cleared it out from under it. Liveness gates BOTH halves,
    // the adoption and the retiring of Cycler's flag.
    let adoptScope = handoff.components(separatedBy: "static func adoptLegacyOwnershipIfNeeded").last?
        .components(separatedBy: "// MARK: - Orphan detection").first ?? ""
    check(!adoptScope.isEmpty, "CapsLockHandoff.adoptLegacyOwnershipIfNeeded is scannable")
    check(adoptScope.contains("SingleInstance.standaloneCyclerIsRunning() == nil"),
          "adoption only happens when standalone Cycler is NOT running")
    let livenessIndex = adoptScope.range(of: "standaloneCyclerIsRunning() == nil")?.lowerBound
    let clearIndex = adoptScope.range(of: "legacy.removeObject(forKey: legacyKey)")?.lowerBound
    check(livenessIndex != nil && clearIndex != nil && livenessIndex! < clearIndex!,
          "the legacy flag is only retired after the liveness check, never out from under a live Cycler")

    // ---- (9) Activation churn: no hidutil subprocess per app switch ----
    check(controller.contains("func isSettled(for settings: HyperKeySettings) -> Bool"),
          "the controller can say when a re-apply would change nothing")
    let settledScope = controller.components(separatedBy: "func isSettled(for settings").last?
        .components(separatedBy: "func apply(").first ?? ""
    check(settledScope.contains("state == .active") && settledScope.contains("tap != nil"),
          "settled means the tap is live and the state is active")
    check(settledScope.contains("activeTrigger == settings.triggerKey")
          && settledScope.contains("didApplyMapping"),
          "settled means the same trigger, with its mapping already applied")
    check(settledScope.contains("!blockedByStandaloneCycler"),
          "a standalone Cycler that just launched still un-settles the tool")
    check(tool.contains("guard force || !controller.isSettled(for: effective) else { return }"),
          "HyperkeyTool skips the full apply() when nothing changed")
    check(tool.contains("private func apply(force: Bool = false)"),
          "apply() can be forced past the settled check")

    // ---- (8) hidutil never runs on the main thread ----
    // Every probe is a subprocess; the callers are launch, the menu and a button.
    check(handoff.contains("HyperKeyController.currentMappingAsync")
          && !handoff.contains("HyperKeyController.currentMapping()"),
          "CapsLockHandoff probes hidutil off the main thread")
    check(tool.contains("CapsLockHandoff.orphanedMappingDetected {"),
          "the orphan probe reports back on a completion")
    check(tool.contains("guard !isTerminating else { return }"),
          "the orphan probe is skipped while the app is quitting")
}

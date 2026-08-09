import Foundation
import AppCore
import CyclerCore
import HyperkeyCore
import ZonesCore

// Shell-level checks: the config envelope, its write discipline, the legacy import/split, and
// source-scan invariants that keep the three tools from stepping on each other.

// A scratch directory that is removed when the closure returns. Named per-case so a failure
// leaves a readable trail in /tmp.
private func withTempDir(_ name: String, _ body: (URL) throws -> Void) rethrows {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("lineup-tests-\(name)-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    try body(dir)
}

private func canonical(_ config: LineupAppConfig) -> String {
    (try? String(decoding: config.encoded(), as: UTF8.self)) ?? "<encode failed>"
}

private let sampleHyperMask: UInt32 = 0x100 | 0x800 | 0x200 | 0x1000

func runAppTests() throws {
    try runEnvelopeTests()
    try runStoreTests()
    try runLegacyImportTests()
    try runIdentityTests()
    try runShellSourceScanTests()
    try runSettingsWindowTests()
    try runIntegrationTests()
    try runOnboardingTests()
    try runParityFixTests()
}

// MARK: - Envelope

private func runEnvelopeTests() throws {
    // ---- Round-trip, including a tool section this build knows nothing about ----
    do {
        var cfg = LineupAppConfig()
        cfg.general.didShowWhatsNew2 = true
        try cfg.setSettings(CyclerToolSettings(bindings: [
            AppBinding(keyCode: 18, modifiers: sampleHyperMask, bundleIdentifier: "com.apple.Safari"),
        ]), for: .cycler)
        cfg.setEnabled(true, for: .cycler)
        // A section written by a FUTURE Lineup with a tool this build has never heard of.
        cfg.tools["quicknote"] = ToolSection(enabled: true, settings: .object([
            "note": .string("hi"),
            "count": .number(3),
            "nested": .object(["deep": .array([.bool(true), .null, .string("x")])]),
        ]))

        let data = try cfg.encoded()
        let back = try JSONDecoder().decode(LineupAppConfig.self, from: data)
        check(back == cfg, "LineupAppConfig round-trips")
        check(back.schemaVersion == 1, "envelope declares schema 1")
        check(String(decoding: try back.encoded(), as: UTF8.self) == String(decoding: data, as: UTF8.self),
              "unknown tool section survives decode->encode byte-identically")
        check(back.tools["quicknote"]?.settings["note"] == .string("hi"),
              "unknown section keeps its scalar values")
        check(back.tools["quicknote"]?.settings["nested"]?["deep"] == .array([.bool(true), .null, .string("x")]),
              "unknown section keeps its nested array")
        check(back.tools["quicknote"]?.enabled == true, "unknown section keeps its enabled flag")
    }

    // ---- Defaults ----
    do {
        let fresh = LineupAppConfig()
        check(fresh.schemaVersion == LineupAppConfig.currentSchema, "fresh envelope uses the current schema")
        check(fresh.tools.isEmpty, "fresh envelope has no tool sections")
        check(fresh.general.showMenuBarIcon, "menu-bar icon shows by default")
        check(!fresh.general.didImportLegacyZones, "fresh envelope has not imported zones")
        check(!fresh.general.didImportLegacyCycler, "fresh envelope has not imported cycler")
        check(!fresh.general.didShowWhatsNew2, "fresh envelope has not shown What's New")
        check(fresh.isEnabled(.zones) == nil, "no section -> nil enabled (caller uses Tool.defaultEnabled)")
    }

    // ---- Lenient decode: a file from a build that predates a general key ----
    do {
        let old = try JSONDecoder().decode(
            LineupAppConfig.self,
            from: Data(#"{"schemaVersion":1,"general":{},"tools":{}}"#.utf8))
        check(old.general.showMenuBarIcon, "missing general keys fall back to defaults")
        let bare = try JSONDecoder().decode(LineupAppConfig.self, from: Data("{}".utf8))
        check(bare == LineupAppConfig(), "an empty object decodes to the fresh envelope")
    }

    // ---- Each tool model round-trips through an opaque section ----
    do {
        var cfg = LineupAppConfig()

        var zones = LineupConfig()
        zones.dragSnapEnabled = true
        zones.screens["uuid-wide"] = ScreenLayout(
            label: "Wide", pixelsWide: 5120, pixelsHigh: 1440, keyIsStable: true,
            lastSeenAt: "2026-01-01T00:00:00Z", layout: .columns([Boundary(0.5, .fraction)]))
        try cfg.setSettings(zones, for: .zones)
        check(try cfg.settings(LineupConfig.self, for: .zones) == zones,
              "LineupConfig round-trips through a tool section")
        check(cfg.section(for: .zones)?.settings["schemaVersion"] == .number(3),
              "the zones section carries LineupConfig's own schema 3 (two-level versioning)")

        let cycler = CyclerToolSettings(bindings: [
            AppBinding(keyCode: 18, modifiers: sampleHyperMask, bundleIdentifiers: ["a", "b"]),
        ])
        try cfg.setSettings(cycler, for: .cycler)
        check(try cfg.settings(CyclerToolSettings.self, for: .cycler) == cycler,
              "CyclerToolSettings round-trips through a tool section")

        let hyper = HyperKeySettings(enabled: true, triggerKey: .f12, includeShift: false)
        try cfg.setSettings(hyper, for: .hyperkey)
        check(try cfg.settings(HyperKeySettings.self, for: .hyperkey) == hyper,
              "HyperKeySettings round-trips through a tool section")

        check(try cfg.settings(LineupConfig.self, for: .zones) == zones,
              "writing two siblings leaves the zones section intact")
    }

    // ---- setSettings preserves enabled; setEnabled preserves settings ----
    do {
        var cfg = LineupAppConfig()
        cfg.setEnabled(true, for: .cycler)
        try cfg.setSettings(CyclerToolSettings(bindings: []), for: .cycler)
        check(cfg.isEnabled(.cycler) == true, "setSettings preserves the enabled flag")
        cfg.setEnabled(false, for: .cycler)
        check(try cfg.settings(CyclerToolSettings.self, for: .cycler) != nil,
              "setEnabled preserves the settings blob")
    }

    // ---- CyclerToolSettings delegates coalescing to CyclerConfig ----
    do {
        let s = CyclerToolSettings(bindings: [
            AppBinding(keyCode: 18, modifiers: sampleHyperMask, bundleIdentifier: "com.openai.codex"),
            AppBinding(keyCode: 18, modifiers: sampleHyperMask, bundleIdentifier: "com.google.Gemini"),
            AppBinding(keyCode: 19, modifiers: sampleHyperMask, bundleIdentifier: "com.apple.Safari"),
        ]).coalescingDuplicateShortcuts()
        check(s.bindings.count == 2, "CyclerToolSettings coalesces duplicate combos")
        check(s.bindings[0].bundleIdentifiers == ["com.openai.codex", "com.google.Gemini"],
              "coalescing produces the app group in order")
        let json = String(decoding: try JSONEncoder().encode(s), as: UTF8.self)
        check(!json.contains("hyperKey"), "the cycler section never carries hyper-key state")
        check(!json.contains("showMenuBarIcon"), "the cycler section never carries the menu-bar flag")
    }

    // ---- JSONValue ----
    do {
        let raw = Data(#"{"a":1,"b":[true,null,"s"],"c":{"d":1.5},"e":false}"#.utf8)
        let v = try JSONDecoder().decode(JSONValue.self, from: raw)
        check(v["a"] == .number(1), "JSONValue decodes an integer as a number")
        check(v["b"] == .array([.bool(true), .null, .string("s")]), "JSONValue decodes a mixed array")
        check(v["c"]?["d"] == .number(1.5), "JSONValue decodes a nested object")
        check(v["e"] == .bool(false), "JSONValue decodes false as a bool, not a number")
        let again = try JSONDecoder().decode(JSONValue.self, from: try JSONEncoder().encode(v))
        check(again == v, "JSONValue round-trips")
        check(JSONValue.object([:]).isEmptyObject, "empty object is detected")
    }
}

// MARK: - Store

private func runStoreTests() throws {
    // ---- fresh ----
    try withTempDir("store-fresh") { dir in
        let store = LineupAppConfigStore(url: dir.appendingPathComponent("config.json"))
        check(store.load() == .fresh, "a missing config.json loads as .fresh")
        check(store.canWrite, "a fresh store is writable")
        check(store.blockedMessage == nil, "a fresh store has no blocked message")
        try store.setEnabled(true, for: .zones)
        check(FileManager.default.fileExists(atPath: store.url.path), "the first save creates config.json")

        let reread = LineupAppConfigStore(url: store.url)
        check(reread.load() == .loaded, "an existing config.json loads as .loaded")
        check(reread.config.isEnabled(.zones) == true, "the saved enabled flag survives a reload")
    }

    // ---- newer schema: blocked, file untouched ----
    try withTempDir("store-newer") { dir in
        let url = dir.appendingPathComponent("config.json")
        let raw = Data(#"{"schemaVersion":999,"general":{},"tools":{"zones":{"enabled":true,"settings":{}}}}"#.utf8)
        try raw.write(to: url)
        let store = LineupAppConfigStore(url: url)
        check(store.load() == .failed(.unsupportedSchema(999)), "schemaVersion 999 is rejected")
        check(!store.canWrite, "a newer-schema file blocks writes")
        check(store.blockedMessage != nil, "a newer-schema file has a blocked message")
        var threw = false
        do { try store.setEnabled(false, for: .zones) } catch { threw = true }
        check(threw, "saving while blocked throws")
        check(try Data(contentsOf: url) == raw, "a newer-schema file is left byte-identical")
    }

    // ---- corrupt: blocked, bytes preserved, reset recovers ----
    try withTempDir("store-corrupt") { dir in
        let url = dir.appendingPathComponent("config.json")
        let raw = Data("{ this is not json".utf8)
        try raw.write(to: url)
        let store = LineupAppConfigStore(url: url)
        check(store.load() == .failed(.unreadable), "corrupt JSON loads as .unreadable")
        check(!store.canWrite, "a corrupt file blocks writes")
        check(store.config == LineupAppConfig(), "a corrupt file runs on in-memory defaults")
        check(try Data(contentsOf: url) == raw, "a corrupt file is NOT overwritten by the failed load")

        try store.reset(now: 1234)
        let rejected = dir.appendingPathComponent("config.rejected-1234.json")
        check(try Data(contentsOf: rejected) == raw, "reset preserves the rejected bytes first")
        check(store.canWrite, "reset unblocks writes")
        check(store.state == .ok, "reset clears the error state")
        check(try JSONDecoder().decode(LineupAppConfig.self, from: Data(contentsOf: url)) == LineupAppConfig(),
              "reset writes a fresh envelope")
    }

    // ---- saving one section preserves the siblings, in both directions ----
    try withTempDir("store-siblings") { dir in
        let url = dir.appendingPathComponent("config.json")
        let store = LineupAppConfigStore(url: url)
        store.load()

        var zones = LineupConfig()
        zones.dragSnapEnabled = false
        try store.setSettings(zones, for: .zones)
        try store.setSettings(CyclerToolSettings(bindings: [
            AppBinding(keyCode: 18, modifiers: sampleHyperMask, bundleIdentifier: "com.apple.Safari"),
        ]), for: .cycler)
        try store.setSettings(HyperKeySettings(enabled: true, triggerKey: .f12, includeShift: false),
                              for: .hyperkey)
        try store.update { $0.tools["future"] = ToolSection(enabled: true, settings: .object(["k": .string("v")])) }

        let zonesBefore = store.config.section(for: .zones)
        let hyperBefore = store.config.section(for: .hyperkey)
        let futureBefore = store.config.tools["future"]

        // Write cycler again; nothing else may move.
        try store.setSettings(CyclerToolSettings(bindings: []), for: .cycler)
        check(store.config.section(for: .zones) == zonesBefore, "saving cycler preserves the zones section")
        check(store.config.section(for: .hyperkey) == hyperBefore, "saving cycler preserves the hyperkey section")
        check(store.config.tools["future"] == futureBefore, "saving cycler preserves an unknown section")

        // And the other direction.
        let cyclerBefore = store.config.section(for: .cycler)
        var zones2 = zones
        zones2.dragSnapEnabled = true
        try store.setSettings(zones2, for: .zones)
        check(store.config.section(for: .cycler) == cyclerBefore, "saving zones preserves the cycler section")
        check(store.config.section(for: .hyperkey) == hyperBefore, "saving zones preserves the hyperkey section")

        let ondisk = try JSONDecoder().decode(LineupAppConfig.self, from: Data(contentsOf: url))
        check(ondisk == store.config, "the file on disk matches the in-memory envelope exactly")
        check(ondisk.tools["future"] == futureBefore, "the unknown section survives a real write cycle")
    }

    // ---- a failing mutation leaves the in-memory envelope untouched ----
    try withTempDir("store-atomic") { dir in
        let store = LineupAppConfigStore(url: dir.appendingPathComponent("config.json"))
        store.load()
        try store.setEnabled(true, for: .zones)
        let before = store.config
        struct Boom: Error {}
        var threw = false
        do { try store.update { _ in throw Boom() } } catch { threw = true }
        check(threw, "update propagates the body's error")
        check(store.config == before, "a failed update leaves the in-memory envelope unchanged")
    }
}

// MARK: - Legacy import

private func writeZonesFile(_ dir: URL, _ body: String) throws -> URL {
    let url = dir.appendingPathComponent("zones.json")
    try Data(body.utf8).write(to: url)
    return url
}

private func writeCyclerFile(_ dir: URL, _ body: String) throws -> URL {
    let url = dir.appendingPathComponent("bindings.json")
    try Data(body.utf8).write(to: url)
    return url
}

/// A real schema-3 `zones.json`, produced by the same encoder Lineup 1.x writes with, so the
/// import is exercised against the actual on-disk shape rather than a hand-written guess.
private let schema3Zones: String = {
    var cfg = LineupConfig()
    cfg.dragSnapEnabled = true
    let enc = JSONEncoder()
    enc.outputFormatting = [.prettyPrinted, .sortedKeys]
    return String(decoding: (try? enc.encode(cfg)) ?? Data(), as: UTF8.self)
}()

private let legacyColumns = """
{"dividers":[{"unit":"pixels","value":1706}],"halfDivider":{"unit":"pixels","value":2560}}
"""

private func neverResolve(_ old: ColumnConfig) -> ScreenInfo? { nil }
private let wideScreen = ScreenInfo(key: "uuid-wide", label: "Wide", pixelsWide: 5120,
                                    pixelsHigh: 1440, keyIsStable: true)

private func runLegacyImportTests() throws {
    let missing = URL(fileURLWithPath: "/nonexistent/lineup-tests/nothing.json")

    // ---- neither source present: Zones on, Cycler off, Hyperkey off ----
    do {
        var cfg = LineupAppConfig()
        let r = LegacyImport.run(into: &cfg, zonesURL: missing, cyclerBindingsURL: missing,
                                 now: "T", resolveLegacyScreen: neverResolve)
        check(!r.importedZones && !r.importedCycler, "fresh install imports nothing")
        check(cfg.isEnabled(.zones) == true, "fresh install: Zones is on")
        check(cfg.isEnabled(.cycler) == nil, "fresh install: no cycler section is invented")
        check(cfg.isEnabled(.hyperkey) == nil, "fresh install: no hyperkey section is invented")
        check(cfg.general.didImportLegacyZones && cfg.general.didImportLegacyCycler,
              "fresh install marks both imports done so they never run again")
        check(try cfg.settings(LineupConfig.self, for: .zones) == LineupConfig(),
              "fresh install seeds the default zones layout")
    }

    // ---- zones only (schema 3) ----
    try withTempDir("import-zones") { dir in
        let url = try writeZonesFile(dir, schema3Zones)
        let before = try Data(contentsOf: url)
        let beforeMtime = try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date

        var cfg = LineupAppConfig()
        let r = LegacyImport.run(into: &cfg, zonesURL: url, cyclerBindingsURL: missing,
                                 now: "T", resolveLegacyScreen: neverResolve)
        check(r.importedZones, "a schema-3 zones.json imports")
        check(r.zonesError == nil, "a schema-3 zones.json imports without error")
        check(cfg.isEnabled(.zones) == true, "imported Zones is enabled")
        let imported = try cfg.settings(LineupConfig.self, for: .zones)
        check(imported?.dragSnapEnabled == true, "the zones section keeps dragSnapEnabled")
        check(imported?.schemaVersion == 3, "the zones section keeps LineupConfig schema 3")
        check(cfg.general.didImportLegacyZones, "didImportLegacyZones is set")
        check(cfg.isEnabled(.cycler) == nil, "a zones-only import creates no cycler section")

        check(try Data(contentsOf: url) == before, "zones.json is byte-identical after import")
        let afterMtime = try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
        check(beforeMtime == afterMtime, "zones.json mtime is unchanged after import")
        check(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["zones.json"],
              "the import writes no backup next to zones.json")

        // Idempotent: a second run must not touch anything.
        var again = cfg
        let r2 = LegacyImport.run(into: &again, zonesURL: url, cyclerBindingsURL: missing,
                                  now: "T2", resolveLegacyScreen: neverResolve)
        check(!r2.importedZones, "a second import run is a no-op")
        check(canonical(again) == canonical(cfg), "a second import run leaves the envelope unchanged")
    }

    // ---- pre-schema-3 zones migrates through loadOrMigrate ----
    try withTempDir("import-legacy-columns") { dir in
        let url = try writeZonesFile(dir, legacyColumns)
        let before = try Data(contentsOf: url)
        var cfg = LineupAppConfig()
        let r = LegacyImport.run(into: &cfg, zonesURL: url, cyclerBindingsURL: missing,
                                 now: "2026-01-01T00:00:00Z", resolveLegacyScreen: { _ in wideScreen })
        check(r.importedZones, "a pre-schema-3 zones.json migrates and imports")
        let imported = try cfg.settings(LineupConfig.self, for: .zones)
        check(imported?.screens["uuid-wide"] != nil, "migration lands the seams on the resolved display")
        check(imported?.schemaVersion == 3, "migration produces schema 3")
        check(try Data(contentsOf: url) == before, "the legacy zones.json is left byte-identical")
        check(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["zones.json"],
              "migration writes no backup file (the untouched original IS the backup)")
    }

    // ---- deferred: display absent -> nothing written, retried next launch ----
    try withTempDir("import-deferred") { dir in
        let url = try writeZonesFile(dir, legacyColumns)
        var cfg = LineupAppConfig()
        let r = LegacyImport.run(into: &cfg, zonesURL: url, cyclerBindingsURL: missing,
                                 now: "T", resolveLegacyScreen: neverResolve)
        check(r.zonesDeferred, "an unresolvable legacy display defers the import")
        check(!r.importedZones, "a deferred import imports nothing")
        check(cfg.section(for: .zones) == nil, "a deferred import writes no zones section")
        check(!cfg.general.didImportLegacyZones, "a deferred import leaves didImportLegacyZones false")
    }

    // ---- corrupt zones.json: error reported, nothing written, file untouched ----
    try withTempDir("import-zones-corrupt") { dir in
        let url = try writeZonesFile(dir, "{ nope")
        let before = try Data(contentsOf: url)
        var cfg = LineupAppConfig()
        let r = LegacyImport.run(into: &cfg, zonesURL: url, cyclerBindingsURL: missing,
                                 now: "T", resolveLegacyScreen: neverResolve)
        check(r.zonesError != nil, "a corrupt zones.json reports an error")
        check(cfg.section(for: .zones) == nil, "a corrupt zones.json writes no zones section")
        check(!cfg.general.didImportLegacyZones, "a corrupt zones.json leaves the flag false")
        check(try Data(contentsOf: url) == before, "a corrupt zones.json is left byte-identical")
    }

    // ---- cycler only: THE SPLIT ----
    try withTempDir("import-split") { dir in
        let url = try writeCyclerFile(dir, """
        {"bindings":[
          {"keyCode":18,"modifiers":6912,"bundleIdentifier":"com.google.Chrome"},
          {"keyCode":19,"modifiers":6912,"bundleIdentifiers":["com.apple.Safari"]},
          {"keyCode":20,"modifiers":6912,"bundleIdentifier":"com.openai.codex"}
        ],"hyperKey":{"enabled":true,"triggerKey":"f12","includeShift":false},
        "showMenuBarIcon":false}
        """)
        let before = try Data(contentsOf: url)
        let beforeMtime = try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date

        var cfg = LineupAppConfig()
        let r = LegacyImport.run(into: &cfg, zonesURL: missing, cyclerBindingsURL: url,
                                 now: "T", resolveLegacyScreen: neverResolve)
        check(r.importedCycler, "a legacy bindings.json imports")
        check(r.importedBindingCount == 3, "the report counts the imported bindings")
        check(r.importedHyperkey && r.hyperkeyWasEnabled, "the report notes the hyper-key import")

        check(cfg.isEnabled(.cycler) == true, "split: cycler is enabled when it has bindings")
        let cycler = try cfg.settings(CyclerToolSettings.self, for: .cycler)
        check(cycler?.bindings.count == 3, "split: all three bindings land in the cycler section")
        check(cfg.section(for: .cycler)?.settings["hyperKey"] == nil,
              "split: NO hyperKey key inside the cycler section")

        check(cfg.isEnabled(.hyperkey) == true, "split: hyperkey is enabled from the legacy flag")
        let hyper = try cfg.settings(HyperKeySettings.self, for: .hyperkey)
        check(hyper?.triggerKey == .f12, "split: the legacy trigger key lands in the hyperkey section")
        check(hyper?.includeShift == false, "split: includeShift survives the split")
        check(hyper?.enabled == true, "split: HyperKeySettings.enabled matches the tool flag at import")

        check(!cfg.general.showMenuBarIcon,
              "split: a Cycler-ONLY migrant's hidden-icon preference becomes the app-wide setting")
        check(cfg.general.didImportLegacyCycler, "didImportLegacyCycler is set")
        check(cfg.isEnabled(.zones) == true, "a cycler-only import still turns Zones on")

        check(try Data(contentsOf: url) == before, "bindings.json is byte-identical after import")
        let afterMtime = try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
        check(beforeMtime == afterMtime, "bindings.json mtime is unchanged after import")

        var again = cfg
        let r2 = LegacyImport.run(into: &again, zonesURL: missing, cyclerBindingsURL: url,
                                  now: "T", resolveLegacyScreen: neverResolve)
        check(!r2.importedCycler, "a second cycler import run is a no-op")
        check(canonical(again) == canonical(cfg), "a second cycler import leaves the envelope unchanged")
    }

    // ---- showMenuBarIcon: adopted from a Cycler-only migrant, IGNORED for a 1.x upgrade ----
    //
    // In standalone Cycler the flag hid Cycler's own second menu-bar icon. In 2.0 there is one
    // icon for the whole suite, so adopting a `false` on a machine that also ran Lineup 1.x would
    // silently remove the only way into the app, mid-auto-update, for a user who never asked.
    try withTempDir("import-menubar-icon") { dir in
        let hiddenIcon = #"{"bindings":[{"keyCode":18,"modifiers":6400,"bundleIdentifier":"com.apple.Safari"}],"showMenuBarIcon":false}"#

        var migrant = LineupAppConfig()
        _ = LegacyImport.run(into: &migrant, zonesURL: missing,
                             cyclerBindingsURL: try writeCyclerFile(dir, hiddenIcon),
                             now: "T", hasLineupHistory: false, resolveLegacyScreen: neverResolve)
        check(!migrant.general.showMenuBarIcon,
              "a Cycler-only migrant who hid the icon keeps it hidden")

        var upgrade = LineupAppConfig()
        _ = LegacyImport.run(into: &upgrade, zonesURL: missing,
                             cyclerBindingsURL: try writeCyclerFile(dir, hiddenIcon),
                             now: "T", hasLineupHistory: true, resolveLegacyScreen: neverResolve)
        check(upgrade.general.showMenuBarIcon,
              "a Lineup 1.x user keeps the suite's menu-bar icon, whatever Cycler's own flag said")
        check(upgrade.isEnabled(.cycler) == true,
              "ignoring the icon flag does not affect the rest of the Cycler import")

        // The other direction is never surprising: a visible icon stays visible either way.
        let shownIcon = #"{"bindings":[],"showMenuBarIcon":true}"#
        var shown = LineupAppConfig()
        _ = LegacyImport.run(into: &shown, zonesURL: missing,
                             cyclerBindingsURL: try writeCyclerFile(dir, shownIcon),
                             now: "T", hasLineupHistory: true, resolveLegacyScreen: neverResolve)
        check(shown.general.showMenuBarIcon, "a visible icon stays visible for a 1.x upgrade too")
    }

    // ---- cycler with empty bindings: section written, tool OFF ----
    try withTempDir("import-cycler-empty") { dir in
        let url = try writeCyclerFile(dir, #"{"bindings":[]}"#)
        var cfg = LineupAppConfig()
        let r = LegacyImport.run(into: &cfg, zonesURL: missing, cyclerBindingsURL: url,
                                 now: "T", resolveLegacyScreen: neverResolve)
        check(r.importedCycler && r.importedBindingCount == 0, "an empty bindings.json still imports")
        check(cfg.isEnabled(.cycler) == false, "cycler stays off when it has no bindings")
        check(cfg.isEnabled(.hyperkey) == false, "hyperkey stays off when the legacy file never enabled it")
        check(cfg.general.showMenuBarIcon, "a legacy file without showMenuBarIcon keeps the icon on")
    }

    // ---- cycler with hyperkey disabled ----
    try withTempDir("import-cycler-hyper-off") { dir in
        let url = try writeCyclerFile(dir, """
        {"bindings":[{"keyCode":18,"modifiers":6912,"bundleIdentifier":"com.apple.Safari"}],
         "hyperKey":{"enabled":false,"triggerKey":"capsLock","includeShift":true}}
        """)
        var cfg = LineupAppConfig()
        LegacyImport.run(into: &cfg, zonesURL: missing, cyclerBindingsURL: url,
                         now: "T", resolveLegacyScreen: neverResolve)
        check(cfg.isEnabled(.cycler) == true, "cycler is on when the legacy file has bindings")
        check(cfg.isEnabled(.hyperkey) == false, "hyperkey stays off when the legacy file had it off")
        check(try cfg.settings(HyperKeySettings.self, for: .hyperkey)?.triggerKey == .capsLock,
              "a disabled legacy hyper-key still carries its trigger across")
    }

    // ---- a legacy VIRTUAL trigger migrates to Caps Lock through the split ----
    try withTempDir("import-virtual-trigger") { dir in
        let url = try writeCyclerFile(dir, """
        {"bindings":[],"hyperKey":{"enabled":true,"triggerKey":"f19","includeShift":false}}
        """)
        var cfg = LineupAppConfig()
        LegacyImport.run(into: &cfg, zonesURL: missing, cyclerBindingsURL: url,
                         now: "T", resolveLegacyScreen: neverResolve)
        let hyper = try cfg.settings(HyperKeySettings.self, for: .hyperkey)
        check(hyper?.triggerKey == .capsLock, "the legacy f19 virtual trigger migrates to Caps Lock")
        check(cfg.isEnabled(.hyperkey) == true, "hyperkey is enabled even though its trigger migrated")
    }

    // ---- duplicate combos coalesce during import ----
    try withTempDir("import-coalesce") { dir in
        let url = try writeCyclerFile(dir, """
        {"bindings":[
          {"keyCode":18,"modifiers":6912,"bundleIdentifier":"com.openai.codex"},
          {"keyCode":18,"modifiers":6912,"bundleIdentifier":"com.google.Gemini"}
        ]}
        """)
        var cfg = LineupAppConfig()
        let r = LegacyImport.run(into: &cfg, zonesURL: missing, cyclerBindingsURL: url,
                                 now: "T", resolveLegacyScreen: neverResolve)
        check(r.importedBindingCount == 1, "duplicate combos coalesce before import")
        let cycler = try cfg.settings(CyclerToolSettings.self, for: .cycler)
        check(cycler?.bindings.first?.bundleIdentifiers == ["com.openai.codex", "com.google.Gemini"],
              "the coalesced app group keeps its order")
    }

    // ---- corrupt bindings.json: reported, retried later, zones import unaffected ----
    try withTempDir("import-cycler-corrupt") { dir in
        let cyclerURL = try writeCyclerFile(dir, "{ nope")
        let zonesURL = try writeZonesFile(dir, schema3Zones)
        var cfg = LineupAppConfig()
        let r = LegacyImport.run(into: &cfg, zonesURL: zonesURL, cyclerBindingsURL: cyclerURL,
                                 now: "T", resolveLegacyScreen: neverResolve)
        check(r.cyclerError != nil, "a corrupt bindings.json reports an error")
        check(r.importedZones, "a failed cycler import does not block the zones import")
        check(cfg.general.didImportLegacyZones, "the zones flag is set independently")
        check(!cfg.general.didImportLegacyCycler, "the cycler flag stays false so it retries")
        check(cfg.section(for: .cycler) == nil, "a corrupt bindings.json writes no cycler section")
    }

    // ---- both sources ----
    try withTempDir("import-both") { dir in
        let zonesURL = try writeZonesFile(dir, schema3Zones)
        let cyclerURL = try writeCyclerFile(dir, """
        {"bindings":[{"keyCode":18,"modifiers":6912,"bundleIdentifier":"com.apple.Safari"}],
         "hyperKey":{"enabled":true,"triggerKey":"capsLock","includeShift":true}}
        """)
        var cfg = LineupAppConfig()
        let r = LegacyImport.run(into: &cfg, zonesURL: zonesURL, cyclerBindingsURL: cyclerURL,
                                 now: "T", resolveLegacyScreen: neverResolve)
        check(r.importedZones && r.importedCycler, "both sources import in one run")
        check(cfg.isEnabled(.zones) == true, "both: Zones on")
        check(cfg.isEnabled(.cycler) == true, "both: Cycler on")
        check(cfg.isEnabled(.hyperkey) == true, "both: Hyperkey on")
        check(cfg.tools.count == 3, "both: exactly three sections are created")
    }
}

// MARK: - Identity + source scans
//
// The app target is not linked into this runner (it is an executable), so shell invariants are
// asserted by scanning the source tree. That is deliberate: these are single-owner rules whose
// whole point is "this string/call appears in exactly one place", which is a text property.

private func sourceFiles() -> [(path: String, text: String)] {
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

private func shellScript(_ path: String, key: String) -> String? {
    guard let s = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
    for raw in s.split(separator: "\n") {
        let line = raw.trimmingCharacters(in: .whitespaces)
        guard line.hasPrefix("\(key)=") else { continue }
        return String(line.dropFirst(key.count + 1))
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
    }
    return nil
}

private func plistString(_ key: String) -> String? {
    guard let s = try? String(contentsOfFile: "Resources/Info.plist", encoding: .utf8) else { return nil }
    guard let keyRange = s.range(of: "<key>\(key)</key>") else { return nil }
    let rest = s[keyRange.upperBound...]
    guard let open = rest.range(of: "<string>"), let close = rest.range(of: "</string>") else { return nil }
    return String(rest[open.upperBound..<close.lowerBound])
}

private func runIdentityTests() throws {
    // Product is the single Swift-side home for identity. The bundle ID is the TCC and Sparkle
    // anchor: if it (or the signing identity) ever moves, every existing user silently loses
    // their Accessibility grant on the next auto-update.
    check(Product.bundleID == "com.caiano.lineup", "Product.bundleID is unchanged from Lineup 1.x")
    check(Product.name == "Lineup", "Product.name is Lineup")
    check(Product.executableName == "lineup", "Product.executableName is lineup")
    check(Product.logSubsystem == Product.bundleID, "the log subsystem is the bundle id")
    check(Product.feedURLString == "https://lineup.caiano.com/appcast.xml", "the Sparkle feed is unchanged")
    check(Product.hotkeySignatureString == "LNUP", "the Carbon hotkey signature is unchanged")
    check(Product.selfSignedIdentity == "Lineup Self-Signed", "the self-signed identity name is unchanged")

    check(plistString("CFBundleIdentifier") == Product.bundleID,
          "identity: Info.plist CFBundleIdentifier matches Product.bundleID")
    check(plistString("SUFeedURL") == Product.feedURLString,
          "identity: Info.plist SUFeedURL matches Product.feedURLString")
    check(shellScript("Scripts/build-app.sh", key: "BUNDLE_ID") == Product.bundleID,
          "identity: build-app.sh BUNDLE_ID matches Product.bundleID")
    check(shellScript("Scripts/setup-signing.sh", key: "BUNDLE_ID") == Product.bundleID,
          "identity: setup-signing.sh BUNDLE_ID matches Product.bundleID (stable designated requirement)")
    check(shellScript("Scripts/build-app.sh", key: "APP_NAME") == Product.name,
          "identity: build-app.sh APP_NAME matches Product.name")
    check(shellScript("Scripts/build-app.sh", key: "EXEC_NAME") == Product.executableName,
          "identity: build-app.sh EXEC_NAME matches Product.executableName")
    check(shellScript("Scripts/build-app.sh", key: "SIGN_IDENTITY") == Product.selfSignedIdentity,
          "identity: build-app.sh SIGN_IDENTITY matches Product.selfSignedIdentity")
    check(shellScript("Scripts/setup-signing.sh", key: "IDENTITY") == Product.selfSignedIdentity,
          "identity: setup-signing.sh IDENTITY matches Product.selfSignedIdentity")

    // The Carbon namespace, derived the way HotkeyManager derives it.
    let derived = Product.hotkeySignatureString.utf8.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    let literal = (UInt32(UInt8(ascii: "L")) << 24) | (UInt32(UInt8(ascii: "N")) << 16)
        | (UInt32(UInt8(ascii: "U")) << 8) | UInt32(UInt8(ascii: "P"))
    check(derived == literal, "the FourCharCode derived from Product.hotkeySignatureString is 'LNUP'")
    check(derived == 0x4C4E_5550, "'LNUP' is 0x4C4E5550, byte-identical to the 1.x registry")

    check(plistString("CFBundleShortVersionString") == "2.0.0", "Info.plist ships 2.0.0")
    check(plistString("CFBundleVersion") == "17", "Info.plist ships build 17")
}

private func runShellSourceScanTests() throws {
    let files = sourceFiles()
    check(!files.isEmpty, "source scan finds Swift files")

    // Two SPUStandardUpdaterControllers in one process is unsupported by Sparkle. Cycler's
    // Updater.swift is deliberately never copied.
    let updaterOccurrences = files.reduce(0) { $0 + $1.text.components(separatedBy: "SPUStandardUpdaterController(").count - 1 }
    check(updaterOccurrences == 1,
          "exactly one SPUStandardUpdaterController( in Sources/ (got \(updaterOccurrences))")

    // ActivationCoordinator is the SOLE owner of the activation policy: otherwise closing
    // Settings drops the app to .accessory mid layout-edit.
    let policyFiles = files.filter { $0.text.contains("setActivationPolicy") }.map(\.path)
    check(policyFiles == ["Sources/lineup/App/ActivationCoordinator.swift"],
          "setActivationPolicy appears only in ActivationCoordinator.swift (got \(policyFiles))")

    // The Carbon signature has exactly one home.
    let signatureFiles = files.filter { $0.text.contains("hotkeySignatureString") }.map(\.path)
    check(signatureFiles == ["Sources/AppCore/Product.swift", "Sources/lineup/App/HotkeyManager.swift"],
          "the hotkey signature is defined in Product and used only by HotkeyManager (got \(signatureFiles))")

    // The merged ShortcutKit must be the UNION of both apps' key tables. There were no
    // ShortcutKit assertions in either original runner (it lives in the app target, which this
    // runner does not link), so these are scans of the merged file rather than ported checks.
    guard let shortcutKit = files.first(where: { $0.path.hasSuffix("App/ShortcutKit.swift") })?.text else {
        check(false, "App/ShortcutKit.swift exists")
        return
    }
    check(shortcutKit.contains("case kVK_Escape: return \"Esc\""),
          "merged ShortcutKit keeps Cycler's Esc key name")
    check(shortcutKit.contains("case kVK_ANSI_LeftBracket: return \"[\""),
          "merged ShortcutKit keeps Lineup's [ key name")
    check(shortcutKit.contains("case kVK_ANSI_RightBracket: return \"]\""),
          "merged ShortcutKit keeps Lineup's ] key name")
    check(!shortcutKit.contains("kVK_ANSI_LeftBracket: \"[\""),
          "merged ShortcutKit does not duplicate [ into the ANSI table")
    check(shortcutKit.contains("static let hyper: UInt32"),
          "merged ShortcutKit makes UInt32 the canonical modifier mask")
    check(shortcutKit.contains("static let hyperInt = Int(hyper)"),
          "merged ShortcutKit bridges the mask to the Int-typed Zones model")
    check(shortcutKit.contains("static func display(keyCode: Int, modifiers: UInt32)")
          && shortcutKit.contains("static func display(keyCode: Int, modifiers: Int)"),
          "merged ShortcutKit exposes both display overloads")
    check(shortcutKit.contains("static let quickActions") && shortcutKit.contains("static let zoneRows")
          && shortcutKit.contains("dragSnapModifierChoices"),
          "merged ShortcutKit keeps Lineup's quick actions, zone rows and drag-snap helpers")

    // The 2.0 config file is new; zones.json is the rollback safety net and must never be
    // written, renamed or deleted. Nothing outside Product may name it.
    let zonesPathFiles = files.filter { $0.text.contains("\"zones.json\"") }.map(\.path)
    check(zonesPathFiles == ["Sources/AppCore/Product.swift"],
          "the legacy zones.json path is named only by Product (got \(zonesPathFiles))")

    // SettingsStore is the SOLE route to the global recording suspension. A pane that reached for
    // HotkeyManager itself would bypass the ref count and the cancel-on-blur/close path, and
    // could strand all three tools' hotkeys unregistered.
    let suspendFiles = files.filter {
        $0.text.contains("HotkeyManager.shared.suspendAll") || $0.text.contains("HotkeyManager.shared.resumeAll")
    }.map(\.path)
    check(suspendFiles == ["Sources/lineup/Settings/SettingsStore.swift"],
          "the global hotkey suspension is driven only by SettingsStore (got \(suspendFiles))")

    // The two recorder styles coexist by design through the merge: Zones keeps 1.x's
    // RecorderButton, Cycler keeps its ShortcutField. Do not unify them here.
    let paths = Set(files.map(\.path))
    for component in ["SettingsSection", "RecorderButton", "ShortcutField", "ShortcutRecorder"] {
        check(paths.contains("Sources/lineup/Settings/Components/\(component).swift"),
              "shared Settings component \(component).swift exists")
    }
}

// MARK: - Settings window (Phase 7b)

/// The Settings window lives in the app target, which this runner does not link, so its
/// invariants are asserted the same way the other shell rules are: by scanning the sources.
/// These are the rules three parallel tool agents could each break by accident — the fixed
/// sidebar order, the single owner of the enable switch, the private-build About, and the
/// resource plumbing that makes the per-tool icons survive `Scripts/build-app.sh`.
private func runSettingsWindowTests() throws {
    let files = sourceFiles()
    func source(_ path: String) -> String {
        guard let text = files.first(where: { $0.path == path })?.text else {
            check(false, "\(path) exists")
            return ""
        }
        return text
    }

    // ---- Sidebar: shape and fixed order ----
    let root = source("Sources/lineup/Settings/SettingsRootView.swift")
    check(root.contains("NavigationSplitView"), "Settings is a NavigationSplitView")
    check(root.contains(".listStyle(.sidebar)"), "the navigator uses the sidebar list style")
    check(root.contains("navigationSplitViewColumnWidth(min: 190, ideal: 200, max: 240)"),
          "the sidebar column is pinned to min 190 / ideal 200 / max 240")
    check(root.contains("frame(minWidth: 760, minHeight: 520)"),
          "the window cannot be resized below 760x520")
    if let general = root.range(of: "SettingsSection.general"),
       let tools = root.range(of: "Section(\"Tools\")"),
       let about = root.range(of: "SettingsSection.about") {
        check(general.lowerBound < tools.lowerBound && tools.lowerBound < about.lowerBound,
              "sidebar order is fixed: General, then the Tools section, then About")
    } else {
        check(false, "the sidebar declares General, a Tools section and About")
    }
    check(root.contains("ToolSidebarRow(row: row)"), "tool rows are ToolSidebarRow")
    check(root.contains("ToolIcon(id: row.id"), "a sidebar tool row shows the tool's app icon")
    check(!root.contains("Toggle(\"\""),
          "the sidebar carries NO switch — the enable switch belongs to the pane header")

    // ---- The shell, not the tools, owns the pane header and the enable switch ----
    let store = source("Sources/lineup/Settings/SettingsStore.swift")
    check(store.contains("ToolPane(") && store.contains("tool.makeSettingsPane()"),
          "a tool's pane is wrapped by the shell's ToolPane header")
    let paneOwners = files.filter { $0.text.contains("binding(forTool:") }.map(\.path)
    check(paneOwners == ["Sources/lineup/Settings/SettingsStore.swift"],
          "the per-tool enable binding has exactly one owner (got \(paneOwners))")

    let pane = source("Sources/lineup/Settings/ToolPane.swift")
    check(pane.contains("ToolIcon(id: id, size: 72)"), "the pane header shows a 72pt tool icon")
    // The switch is an overlay on the ICON row, not on the header block: pinned to the block's
    // corner it floats over the scroll area instead of reading as part of the header.
    check(pane.contains("toggleStyle(.switch)") && pane.contains("alignment: .trailing")
            && !pane.contains("alignment: .topTrailing"),
          "the enable switch is aligned with the pane header's icon row")
    check(pane.contains("Text(summary)"), "the pane header shows the tool's one-line summary")
    // A fixed header above a scrolling pane otherwise reports an ideal height of header + the
    // WHOLE scroll content, and a tall pane pushes the entire split view up out of the window.
    check(pane.contains("GeometryReader"),
          "ToolPane does not propagate its content's ideal height to the window")

    // ---- Per-tool icons, and the resource plumbing they depend on ----
    let icon = source("Sources/lineup/Settings/Components/ToolIcon.swift")
    check(icon.contains("struct AppStyleIcon"),
          "AppStyleIcon is the drawn-tile template for a tool with no artwork")
    check(icon.contains("applicationIconImage"), "Zones uses the running app's own icon")
    check(icon.contains("Bundle.module") && icon.contains("\"cycler-icon\""),
          "Cycler's icon is loaded from the package resource bundle")
    let paths = Set(files.map(\.path))
    check(!paths.contains("Sources/lineup/App/ZZPreviewTools.swift"),
          "the temporary preview-tool scaffold is not committed")
    check(!files.contains { $0.text.contains("LINEUP_PREVIEW_TOOLS") },
          "no source reads the preview-tool escape hatch")
    check(FileManager.default.fileExists(atPath: "Sources/lineup/Resources/ToolIcons/cycler-icon.png"),
          "the Cycler icon ships inside the lineup target")
    let manifest = (try? String(contentsOfFile: "Package.swift", encoding: .utf8)) ?? ""
    check(manifest.contains(".copy(\"Resources/ToolIcons\")"),
          "Package.swift declares the tool icons as a target resource")
    // build-app.sh assembles the .app by hand: without this copy, Bundle.module finds nothing in
    // the shipped app and every tool icon silently falls back to a drawn tile.
    let buildScript = (try? String(contentsOfFile: "Scripts/build-app.sh", encoding: .utf8)) ?? ""
    check(buildScript.contains("${EXEC_NAME}_${EXEC_NAME}.bundle")
          && buildScript.contains("${APP}/Contents/Resources/$(basename \"${RES_BUNDLE}\")"),
          "build-app.sh copies the SwiftPM resource bundle into Contents/Resources")

    // ---- Window controller ----
    let controller = source("Sources/lineup/Settings/SettingsWindowController.swift")
    check(controller.contains("isReleasedWhenClosed = false"),
          "the Settings window is not freed by AppKit on close")
    check(controller.contains("Product.name) Settings"),
          "the window title is \"\(Product.name) Settings\"")
    check(controller.contains("private func placeWindowIfNeeded"),
          "the off-screen window recovery is kept")
    check(controller.contains("ActivationCoordinator.shared.retain(Self.activationReason)")
          && controller.contains("ActivationCoordinator.shared.release(Self.activationReason)"),
          "Settings retains and releases activation under one reason")
    for hook in ["func windowDidResignKey", "func windowWillClose"] {
        guard let start = controller.range(of: hook) else {
            check(false, "SettingsWindowController implements \(hook)")
            continue
        }
        let body = controller[start.lowerBound...].prefix(260)
        check(body.contains("store.stopAllRecording()"),
              "\(hook) stops every live recorder")
    }
    check(controller.contains("store.onRecordingRestoreFailures"),
          "combos another app stole during recording are surfaced to the user")

    // ---- General pane ----
    let general = source("Sources/lineup/Settings/GeneralPane.swift")
    for section in ["Startup", "Menu bar", "Permissions", "Updates"] {
        check(general.contains("SettingsSectionView(\"\(section)\")"),
              "General has a \(section) section, in the shared section style")
    }
    check(general.contains("$store.launchAtLogin") && general.contains("$store.showMenuBarIcon"),
          "General drives launch-at-login and the menu-bar icon")
    check(general.contains("AppUpdater.shared.checkForUpdates"),
          "General's Check for Updates goes through the one Sparkle controller")
    check(general.contains("permissions.openSettings(for: permission)"),
          "a permission row opens the right System Settings pane")
    check(general.contains("Required by ") && general.contains("requirements"),
          "a permission row names the tools that need it, from requiredPermissions")
    check(!general.contains("RoundedRectangle"),
          "General uses the shared section style, not a pane-local card")

    // ---- About: private build ----
    let about = source("Sources/lineup/Settings/AboutPane.swift")
    check(about.contains("lineup.caiano.com"), "About links the product site")
    check(about.contains("AppUpdater.shared.checkForUpdates"), "About offers Check for Updates")
    check(!about.lowercased().contains("github"),
          "About has no source-repository link (Lineup 2.0 is a private build)")
    check(!about.contains("MIT"), "About has no open-source licence line")

    // ---- Reopen path: with no menu-bar icon, Settings is the only way back in ----
    let shell = source("Sources/lineup/App/AppShell.swift")
    check(shell.contains("func applicationShouldHandleReopen"),
          "the shell handles reopen (Dock / Spotlight)")
    if let start = shell.range(of: "func applicationShouldHandleReopen") {
        let body = shell[start.lowerBound...].prefix(300)
        check(body.contains("showMenuBarIcon") && body.contains("openSettings()"),
              "reopen shows Settings when the menu-bar icon is hidden")
    }
    // didBecomeActive fires on EVERY activation — including the ones Settings itself and a
    // dismissed alert cause — so reopening unconditionally de-minimized the window the user had
    // just minimized and fought whatever sheet was on it. The reopen handler above is the route
    // back in; this one only has to cover "there is no window at all".
    if let start = shell.range(of: "@objc private func applicationBecameActive") {
        let body = shell[start.lowerBound...].prefix(700)
        check(body.contains("settings == nil"),
              "becoming active only opens Settings when no Settings window exists")
    } else {
        check(false, "AppShell owns applicationBecameActive")
    }

    // A store that can no longer be written to makes the deferred Zones import a guaranteed
    // no-op, so the display observer that retries it has to come off rather than re-run forever.
    if let start = shell.range(of: "private func retryDeferredImport") {
        let body = shell[start.lowerBound...].prefix(900)
        check(body.contains("guard store.canWrite else {") && body.contains("removeDeferredImportObserver()"),
              "the deferred-import observer is removed when the store cannot be written to")
    } else {
        check(false, "AppShell owns retryDeferredImport")
    }

    if let start = shell.range(of: "private func setShowMenuBarIcon") {
        let body = shell[start.lowerBound...].prefix(300)
        check(body.contains("statusItem.refresh()"),
              "flipping the menu-bar icon updates the status item live")
    } else {
        check(false, "AppShell owns setShowMenuBarIcon")
    }
}

// MARK: - Integration (merge of phases 4-7b)

/// The cross-cutting rules that only became assertable once the four tool branches were merged.
/// Two of them are behavioural (the config-flag seeding hazard); the rest are source scans, for
/// the same reason as the shell scans above — these types live in the app target.
private func runIntegrationTests() throws {
    // ---- The self-disable hazard: setSettings can only CREATE a section as disabled ----
    //
    // `setSettings` deliberately never invents an enabled state, so a tool whose section does not
    // exist yet (a fresh install running on `defaultEnabled`) would be written to disk as
    // `enabled: false` by its first settings edit — and Zones, which defaults to ON, would come
    // back OFF at the next launch. `ToolRegistry.startEnabledTools()` seeds the flag first.
    do {
        var cfg = LineupAppConfig()
        check(cfg.isEnabled(.zones) == nil, "a fresh envelope has no zones section")
        try cfg.setSettings(LineupConfig(), for: .zones)
        check(cfg.isEnabled(.zones) == false,
              "setSettings creates a MISSING section as disabled — this is the hazard the registry seeds around")
    }
    do {
        // Seeded first (what startEnabledTools does), a settings write preserves the flag.
        var cfg = LineupAppConfig()
        cfg.setEnabled(true, for: .zones) // Zones' defaultEnabled
        try cfg.setSettings(LineupConfig(), for: .zones)
        check(cfg.isEnabled(.zones) == true,
              "a seeded enabled flag survives the first settings write")
    }
    // ---- A seeded-but-empty section reads as "no settings yet", never as a corrupt blob ----
    //
    // Seeding creates `{"enabled": true, "settings": {}}`. If `{}` were handed to the tool's
    // decoder it would throw, and a brand-new install would open with "Zones settings couldn't be
    // read" and editing disabled.
    do {
        var cfg = LineupAppConfig()
        cfg.setEnabled(true, for: .zones)
        check(cfg.section(for: .zones)?.settings == .object([:]),
              "seeding a missing section leaves an empty settings blob")
        check(try cfg.settings(LineupConfig.self, for: .zones) == nil,
              "an empty blob decodes as nil (defaults), not as an error")
        check(try cfg.settings(CyclerToolSettings.self, for: .cycler) == nil,
              "a missing section is still nil")
        cfg.setEnabled(false, for: .cycler)
        check(try cfg.settings(CyclerToolSettings.self, for: .cycler) == nil,
              "a seeded cycler section reads as no-settings-yet")
        cfg.setEnabled(false, for: .hyperkey)
        check(try cfg.settings(HyperKeySettings.self, for: .hyperkey) == nil,
              "a seeded hyperkey section reads as no-settings-yet")
        // A real blob still decodes, and a genuinely broken one still throws.
        try cfg.setSettings(CyclerToolSettings(bindings: []), for: .cycler)
        check(try cfg.settings(CyclerToolSettings.self, for: .cycler) == CyclerToolSettings(bindings: []),
              "a real empty-bindings blob is distinct from an empty section")
        cfg.tools["zones"] = ToolSection(enabled: true, settings: .string("nonsense"))
        var threw = false
        do { _ = try cfg.settings(LineupConfig.self, for: .zones) } catch { threw = true }
        check(threw, "a genuinely undecodable blob still throws")
    }

    try withTempDir("registry-seed") { dir in
        // The same sequence through the store, which is what actually runs at launch.
        let store = LineupAppConfigStore(url: dir.appendingPathComponent("config.json"))
        check(store.load() == .fresh, "fresh install has no config.json")
        check(store.config.isEnabled(.zones) == nil, "no zones section on a fresh install")
        check(store.canWrite, "a fresh store accepts writes")
        try store.setEnabled(true, for: .zones)      // the seeding step
        try store.setSettings(LineupConfig(), for: .zones)  // the first shortcut edit
        let reread = LineupAppConfigStore(url: dir.appendingPathComponent("config.json"))
        _ = reread.load()
        check(reread.config.isEnabled(.zones) == true,
              "after seeding, editing a Zones shortcut leaves Zones enabled at the next launch")
    }

    let files = sourceFiles()
    func source(_ path: String) -> String {
        files.first { $0.path == path }?.text ?? ""
    }

    // ---- Services at registration, not at start ----
    let registry = source("Sources/lineup/App/ToolRegistry.swift")
    check(registry.contains("tool.attach(services)"),
          "the registry hands a tool its services at register()")
    if let start = registry.range(of: "func startEnabledTools()") {
        let body = registry[start.lowerBound...].prefix(700)
        check(body.contains("isEnabled(tool.id) == nil") && body.contains("setEnabled(tool.defaultEnabled"),
              "startEnabledTools seeds a missing section with the tool's defaultEnabled")
        check(body.contains("store.canWrite"),
              "seeding respects a write-blocked store")
    } else {
        check(false, "ToolRegistry owns startEnabledTools()")
    }
    let tool = source("Sources/lineup/App/Tool.swift")
    check(tool.contains("func attach(_ services: ToolServices)"),
          "the Tool contract has an attach step")
    for path in ["Sources/lineup/Tools/Zones/ZonesTool.swift",
                 "Sources/lineup/Tools/Cycler/CyclerTool.swift",
                 "Sources/lineup/Tools/Hyperkey/HyperkeyTool.swift"] {
        check(source(path).contains("func attach(_ services: ToolServices)"),
              "\(path) takes its services at registration, so its pane works while the tool is off")
    }
    // The workaround attach() replaces.
    check(!source("Sources/lineup/Tools/Hyperkey/HyperkeyTool.swift").contains("pendingSettings"),
          "HyperkeyTool no longer defers edits made while it has never started")

    // ---- SettingsStore injection: no pane may hunt for the window ----
    let settingsStore = source("Sources/lineup/Settings/SettingsStore.swift")
    check(settingsStore.contains(".environmentObject(self)"),
          "SettingsStore.pane(for:) injects itself into a tool pane's environment")
    let windowHunters = files.filter {
        $0.text.contains("window.delegate as? SettingsWindowController")
    }.map(\.path)
    check(windowHunters.isEmpty,
          "no pane reaches through NSApp.windows for the Settings store (got \(windowHunters))")
    for path in ["Sources/lineup/Tools/Zones/ZonesSettingsPane.swift",
                 "Sources/lineup/Tools/Cycler/CyclerSettingsPane.swift"] {
        check(source(path).contains("@EnvironmentObject private var settings: SettingsStore"),
              "\(path) takes the store from the environment")
    }

    // ---- A row that failed to come back after a recording reaches its OWNER ----
    // `HotkeyManager.resumeAll()` keeps a row it could not re-register with a nil Carbon ref:
    // recorded, but dead. The alert told the user; nothing told the TOOL, so no retry loop ever
    // saw those rows and the shortcut stayed broken until the next relaunch.
    check(tool.contains("struct HotkeyRestoreFailure"),
          "the Tool contract names the rows that failed to come back")
    check(tool.contains("func hotkeysFailedToRestore(_ failures: [HotkeyRestoreFailure])"),
          "the Tool contract has a hook for them")
    check(tool.contains("func hotkeysFailedToRestore(_ failures: [HotkeyRestoreFailure]) {}"),
          "the hook is defaulted, so a tool with no shortcuts implements nothing")
    check(settingsStore.contains("Dictionary(grouping: failures, by: \\.owner)")
          && settingsStore.contains("registry.tool(owner)?.hotkeysFailedToRestore("),
          "resumeOneLevel hands each owner its own failed rows")
    check(settingsStore.contains("onRecordingRestoreFailures?(failures)"),
          "the user-facing alert survives alongside the tool hook")
    for path in ["Sources/lineup/Tools/Zones/ZonesTool.swift",
                 "Sources/lineup/Tools/Cycler/CyclerTool.swift"] {
        let text = source(path)
        check(text.contains("func hotkeysFailedToRestore(_ failures: [HotkeyRestoreFailure])"),
              "\(path) takes its failed rows back")
        check(text.contains("failedHotkeys.append("),
              "\(path) records them in the blocked list its warning reads")
    }
    // Cycler's list is what arms its retry timer, so it has to be re-armed here too.
    check(source("Sources/lineup/Tools/Cycler/CyclerTool.swift")
        .components(separatedBy: "func hotkeysFailedToRestore").last?
        .contains("updateFailedHotkeyRetryTimer()") == true,
          "CyclerTool re-arms its retry timer for rows that failed to restore")

    // ---- isSuspended belongs to the scope, not to the singleton ----
    check(tool.contains("var isSuspended: Bool { HotkeyManager.shared.isSuspended }"),
          "HotkeyScope exposes isSuspended")
    let suspendReaders = files.filter { $0.text.contains("HotkeyManager.shared.isSuspended") }.map(\.path)
    check(suspendReaders == ["Sources/lineup/App/Tool.swift"],
          "only HotkeyScope reads HotkeyManager.shared.isSuspended (got \(suspendReaders))")

    // ---- No doubled headers: the shell's ToolPane is the only tool title + enable switch ----
    for path in ["Sources/lineup/Tools/Zones/ZonesSettingsPane.swift",
                 "Sources/lineup/Tools/Cycler/CyclerSettingsPane.swift",
                 "Sources/lineup/Tools/Hyperkey/HyperkeySettingsPane.swift"] {
        let text = source(path)
        check(!text.contains("size: 22, weight: .bold"),
              "\(path) draws no hero-sized title of its own")
        check(!text.contains("Toggle(\"\", isOn: $isOn)"),
              "\(path) draws no enable switch of its own")
    }

    // ---- Key caps: ONE renderer, used by both recorder styles ----
    let shortcutKit = source("Sources/lineup/App/ShortcutKit.swift")
    check(shortcutKit.contains("static func keyCaps("),
          "ShortcutKit splits a display string into key caps")
    check(ShortcutKitCaps.split("⌃⌥⇧⌘←") == ["⌃", "⌥", "⇧", "⌘", "←"],
          "a hyper combo splits into four modifier caps and the key")
    check(ShortcutKitCaps.split("⌘Space") == ["⌘", "Space"],
          "a multi-character key name stays one cap")
    check(ShortcutKitCaps.split("Control-Option") == ["Control", "Option"],
          "the drag bind's worded modifier form splits on the separator")
    check(ShortcutKitCaps.split("") == [], "an unassigned shortcut renders no caps")
    check(source("Sources/lineup/Settings/Components/KeyCapRow.swift").contains("ShortcutKit.keyCaps"),
          "KeyCapRow renders the caps ShortcutKit produced")
    for path in ["Sources/lineup/Settings/Components/RecorderButton.swift",
                 "Sources/lineup/Settings/Components/ShortcutField.swift"] {
        check(source(path).contains("KeyCapRow("),
              "\(path) shows an assigned shortcut as key caps")
    }

    // ---- Shortcut rows are denser than the default row ----
    let metrics = source("Sources/lineup/Settings/Components/SettingsSection.swift")
    check(metrics.contains("static let shortcutRowHeight"),
          "SettingsMetrics defines a shortcut-row height")
    check(source("Sources/lineup/Tools/Zones/ZonesSettingsPane.swift")
            .contains("SettingsMetrics.shortcutRowHeight"),
          "the Zones shortcut rows use it")
    check(SettingsMetricsMirror.shortcutRowHeight < SettingsMetricsMirror.rowHeight,
          "a shortcut row is denser than a stock settings row")
}

// MARK: - Onboarding, upgrade UX and import wiring (Phase 8)

/// The three audiences the plan separates, the windows they do and do not get, and the launch
/// wiring that must not regress: no permission is requested at launch, the import runs before the
/// tools start, and an existing user is never re-onboarded.
private func runOnboardingTests() throws {
    // ---- Audience detection ----
    check(Onboarding.audience(hasConfig: false, hasLegacyZones: false, didOnboard: false) == .brandNew,
          "no config, no zones.json, never onboarded -> brand new")
    check(Onboarding.audience(hasConfig: false, hasLegacyZones: true, didOnboard: false) == .upgradingFrom1x,
          "a 1.x zones.json with no config.json -> upgrading from 1.x")
    check(Onboarding.audience(hasConfig: false, hasLegacyZones: false, didOnboard: true) == .upgradingFrom1x,
          "lineup.didOnboard alone (a 1.x user who never saved a layout) -> upgrading from 1.x")
    check(Onboarding.audience(hasConfig: true, hasLegacyZones: true, didOnboard: true) == .returning,
          "config.json present -> returning, whatever the legacy state")
    check(Onboarding.audience(hasConfig: true, hasLegacyZones: false, didOnboard: false) == .returning,
          "config.json present is sufficient for returning")

    // ---- Welcome: brand-new users only, and only once ----
    check(Onboarding.shouldShowWelcome(audience: .brandNew, didOnboard: false),
          "a brand-new user sees Welcome")
    check(!Onboarding.shouldShowWelcome(audience: .brandNew, didOnboard: true),
          "an onboarded user never sees Welcome again")
    check(!Onboarding.shouldShowWelcome(audience: .upgradingFrom1x, didOnboard: false),
          "a 1.x upgrade never sees Welcome, even with didOnboard unset")
    check(!Onboarding.shouldShowWelcome(audience: .returning, didOnboard: false),
          "a returning 2.0 user never sees Welcome")

    // ---- What's New: existing users only, once, and never alongside Welcome ----
    check(Onboarding.shouldShowWhatsNew(audience: .upgradingFrom1x, didShowWhatsNew2: false,
                                        showingWelcome: false),
          "a 1.x upgrade sees What's New")
    check(!Onboarding.shouldShowWhatsNew(audience: .upgradingFrom1x, didShowWhatsNew2: true,
                                         showingWelcome: false),
          "What's New is shown once — didShowWhatsNew2 retires it")
    check(!Onboarding.shouldShowWhatsNew(audience: .brandNew, didShowWhatsNew2: false,
                                         showingWelcome: true),
          "a brand-new user gets Welcome INSTEAD of What's New, never both")
    check(!Onboarding.shouldShowWhatsNew(audience: .brandNew, didShowWhatsNew2: false,
                                         showingWelcome: false),
          "a brand-new user never gets What's New even if Welcome was suppressed")
    check(Onboarding.shouldShowWhatsNew(audience: .returning, didShowWhatsNew2: false,
                                        showingWelcome: false),
          "a 2.0 user who has not seen the note yet still gets it")

    // ---- The Cycler import confirmation line ----
    func summary(_ bindings: Int, hyperEnabled: Bool, imported: Bool = true) -> String? {
        var r = LegacyImport.Report()
        r.importedCycler = imported
        r.importedBindingCount = bindings
        r.importedHyperkey = imported
        r.hyperkeyWasEnabled = hyperEnabled
        return Onboarding.cyclerImportSummary(r)
    }
    check(summary(6, hyperEnabled: true) == "Imported 6 Cycler shortcuts and your Hyper Key setup.",
          "the confirmation names both the shortcut count and the hyper key")
    check(summary(6, hyperEnabled: false) == "Imported 6 Cycler shortcuts.",
          "a disabled legacy hyper key is not claimed")
    check(summary(1, hyperEnabled: false) == "Imported 1 Cycler shortcut.",
          "one shortcut is singular")
    check(summary(0, hyperEnabled: true) == "Imported your Hyper Key setup from Cycler.",
          "a hyper-key-only Cycler config still gets a confirmation")
    check(summary(0, hyperEnabled: false) == nil,
          "an empty bindings.json produces no confirmation line")
    check(summary(3, hyperEnabled: true, imported: false) == nil,
          "no confirmation when the Cycler import did not run")
    check(Onboarding.cyclerImportSummary(LegacyImport.Report()) == nil,
          "an empty report produces no confirmation line")

    // ---- The shell's own import guard: both flags set means never look again ----
    try withTempDir("import-wiring") { dir in
        let configURL = dir.appendingPathComponent("config.json")
        let zonesURL = try writeZonesFile(dir, schema3Zones)
        let store = LineupAppConfigStore(url: configURL)
        check(store.load() == .fresh, "no config.json before the first 2.0 launch")

        var report = LegacyImport.Report()
        try store.update { config in
            report = LegacyImport.run(into: &config, zonesURL: zonesURL,
                                      cyclerBindingsURL: dir.appendingPathComponent("none.json"),
                                      now: "T", resolveLegacyScreen: neverResolve)
        }
        check(report.importedZones, "the wired import reads the 1.x zones.json")
        check(store.config.general.didImportLegacyZones && store.config.general.didImportLegacyCycler,
              "both import flags are persisted after the first launch")
        check(store.config.isEnabled(.zones) == true, "the imported Zones section is enabled")
        check(FileManager.default.fileExists(atPath: configURL.path),
              "the import creates config.json")

        // The shell's guard: with both flags set it does not call LegacyImport at all.
        let general = store.config.general
        check(general.didImportLegacyZones && general.didImportLegacyCycler,
              "the second launch's guard condition is satisfied, so no import runs")

        // ...and even if it did, the run is a no-op.
        let before = canonical(store.config)
        var again = store.config
        _ = LegacyImport.run(into: &again, zonesURL: zonesURL,
                             cyclerBindingsURL: dir.appendingPathComponent("none.json"),
                             now: "T2", resolveLegacyScreen: neverResolve)
        check(canonical(again) == before, "a second import run leaves the envelope byte-identical")
    }

    // ---- A deferred Zones import leaves the retry armed ----
    try withTempDir("import-wiring-deferred") { dir in
        let zonesURL = try writeZonesFile(dir, legacyColumns)
        let store = LineupAppConfigStore(url: dir.appendingPathComponent("config.json"))
        _ = store.load()
        var report = LegacyImport.Report()
        try store.update { config in
            report = LegacyImport.run(into: &config, zonesURL: zonesURL,
                                      cyclerBindingsURL: dir.appendingPathComponent("none.json"),
                                      now: "T", resolveLegacyScreen: neverResolve)
        }
        check(report.zonesDeferred, "an absent display defers the wired import")
        check(!store.config.general.didImportLegacyZones,
              "the deferred import stays pending, so the screen-change retry can complete it")
        check(store.config.general.didImportLegacyCycler,
              "the Cycler flag is independent and still settles")

        // The retry, once the display is back.
        try store.update { config in
            report = LegacyImport.run(into: &config, zonesURL: zonesURL,
                                      cyclerBindingsURL: dir.appendingPathComponent("none.json"),
                                      now: "T2", resolveLegacyScreen: { _ in wideScreen })
        }
        check(report.importedZones && !report.zonesDeferred,
              "the retry lands the layout once its display reconnects")
        check(store.config.general.didImportLegacyZones, "the retry sets the flag")
        check(try store.config.settings(LineupConfig.self, for: .zones)?.screens["uuid-wide"] != nil,
              "the retry writes the migrated layout onto the reconnected display")
    }

    // ---- Source scans: the launch path ----
    let files = sourceFiles()
    func source(_ path: String) -> String {
        guard let text = files.first(where: { $0.path == path })?.text else {
            check(false, "\(path) exists")
            return ""
        }
        return text
    }
    let shell = source("Sources/lineup/App/AppShell.swift")

    // NO permission request may sit on a launch path. Input Monitoring in particular is the one
    // genuinely new permission for an existing Lineup user, and it must stay opt-in: it is only
    // requested when Hyperkey is actually switched on.
    let listenAccessFiles = files.filter { $0.text.contains("CGRequestListenEventAccess") }.map(\.path)
    check(listenAccessFiles == ["Sources/lineup/App/PermissionCenter.swift",
                                "Sources/lineup/Tools/Hyperkey/HyperKeyController.swift"],
          "Input Monitoring is requested only by PermissionCenter and HyperKeyController (got \(listenAccessFiles))")
    for path in ["Sources/lineup/App/AppShell.swift",
                 "Sources/lineup/App/WelcomeWindow.swift",
                 "Sources/lineup/App/WhatsNewWindow.swift",
                 "Sources/lineup/App/OnboardingKit.swift"] {
        let text = source(path)
        check(!text.contains("CGRequestListenEventAccess") && !text.contains("requestInputMonitoring"),
              "\(path) never requests Input Monitoring")
        check(!text.contains("CGPreflightListenEventAccess"),
              "\(path) does not even preflight Input Monitoring")
    }
    // Accessibility is requested from exactly one place: the Welcome window's Grant button.
    let axRequestFiles = files.filter { $0.text.contains("PermissionCenter.shared.requestAccessibility()") }
        .map(\.path)
    check(axRequestFiles == ["Sources/lineup/App/AppShell.swift"],
          "Accessibility is requested only from the shell's Welcome path (got \(axRequestFiles))")
    if let grant = shell.range(of: "PermissionCenter.shared.requestAccessibility()"),
       let welcome = shell.range(of: "private func showWelcome()") {
        check(welcome.lowerBound < grant.lowerBound,
              "the only Accessibility request is inside showWelcome()")
    } else {
        check(false, "the shell requests Accessibility from showWelcome()")
    }
    check(!source("Sources/lineup/App/WhatsNewWindow.swift").contains("PermissionCenter"),
          "the What's New window asks an existing user for nothing")

    // The import must run BEFORE any tool starts, or a tool reads an empty section, runs on
    // defaults, and has to be told to reload.
    if let importCall = shell.range(of: "runLegacyImport()"),
       let register = shell.range(of: "registry.register(ZonesTool())"),
       let start = shell.range(of: "registry.startEnabledTools()") {
        check(importCall.lowerBound < register.lowerBound && register.lowerBound < start.lowerBound,
              "the legacy import runs before the tools are registered and started")
    } else {
        check(false, "the shell runs the legacy import and then starts the tools")
    }
    let importCallers = files.filter { $0.text.contains("LegacyImport.run(") }.map(\.path)
    check(importCallers == ["Sources/lineup/App/AppShell.swift"],
          "the app has exactly one LegacyImport caller (got \(importCallers))")
    check(shell.contains("hasLineupHistory: hasLineupHistory"),
          "the import is told whether this machine also ran Lineup 1.x")
    check(shell.contains("hasLineupHistory = hasLegacyZones"),
          "1.x history is decided from zones.json and the didOnboard default, not from the audience")

    // Gating goes through the tested pure logic, not through an inline condition.
    for call in ["Onboarding.audience(", "Onboarding.shouldShowWelcome(", "Onboarding.shouldShowWhatsNew("] {
        check(shell.contains(call), "the shell gates onboarding through \(call)")
    }
    check(shell.contains("$0.general.didShowWhatsNew2 = true"),
          "dismissing What's New persists didShowWhatsNew2")

    // The 1.x UserDefaults keys are untouched — an existing user must not be re-onboarded or
    // re-taught the drag-snap edge hint.
    check(shell.contains("\"lineup.didOnboard\""), "the shell keeps the 1.x didOnboard key")
    check(source("Sources/lineup/Tools/Zones/DragSnap.swift").contains("\"lineup.seenEdgeHint\""),
          "the 1.x seenEdgeHint key is unchanged")

    // The deferred-display retry, and the standalone-Cycler warnings.
    check(shell.contains("didChangeScreenParametersNotification"),
          "the shell retries a deferred import on a screen change")
    check(shell.contains("Saved layout waiting for its display"),
          "a deferred import surfaces 1.x's 'waiting for its display' wording as a shell warning")
    check(shell.contains("SingleInstance.standaloneCyclerIsRunning()"),
          "a running standalone Cycler is a persistent shell warning")
    check(shell.contains("Onboarding.cyclerUninstallBanner"),
          "the shell warning reuses the one uninstall wording")
    check(shell.contains("urlForApplication(withBundleIdentifier: SingleInstance.legacyCyclerBundleID)")
          && shell.contains("activateFileViewerSelecting"),
          "Reveal in Finder is offered only when Cycler.app actually resolves")
    check(Onboarding.cyclerUninstallBanner.contains("Quit and remove Cycler.app")
          && Onboarding.cyclerUninstallBanner.contains("win the race"),
          "the uninstall banner keeps the plan's wording")

    // The onboarding windows sell the suite with the shared tool tiles.
    for path in ["Sources/lineup/App/WelcomeWindow.swift",
                 "Sources/lineup/App/WhatsNewWindow.swift"] {
        check(source(path).contains("ToolTileRow()"),
              "\(path) shows the three tool tiles")
    }
    check(source("Sources/lineup/App/OnboardingKit.swift").contains("ToolIcon(id: tool.id"),
          "the tiles reuse the Settings ToolIcon rather than inventing a second icon set")
    let whatsNew = source("Sources/lineup/App/WhatsNewWindow.swift")
    check(whatsNew.contains("Your window snapping is now the Zones tool"),
          "What's New leads with the rename")
    check(whatsNew.contains("Open Settings") && whatsNew.contains("Not now"),
          "What's New offers Open Settings / Not now")
    let welcome = source("Sources/lineup/App/WelcomeWindow.swift")
    check(welcome.contains("OnboardingCopy.accessibilityBody")
          && welcome.contains("OnboardingCopy.inputMonitoringNote"),
          "Welcome explains Accessibility and names Input Monitoring as later-only")
    check(OnboardingCopyMirror.inputMonitoringNote.contains("only when you turn Hyperkey on"),
          "the Input Monitoring note says it is only asked for on Hyperkey enable")
    check(source("Sources/lineup/App/OnboardingKit.swift")
            .contains("\"\(OnboardingCopyMirror.inputMonitoringNote)\""),
          "the mirrored Input Monitoring note is the one the app actually shows")

    // ---- Settings panes: the design-review polish ----
    let cyclerPane = source("Sources/lineup/Tools/Cycler/CyclerSettingsPane.swift")
    let addButtons = cyclerPane.components(separatedBy: "\"Add Shortcut\"").count - 1
    check(addButtons == 2,
          "the Cycler pane declares the Add control twice — empty state and list footer — and shows exactly one at a time (got \(addButtons))")
    if let empty = cyclerPane.range(of: "if model.rows.isEmpty {"),
       let footer = cyclerPane.range(of: "Add ⇧ to a shortcut to cycle backwards.") {
        check(empty.lowerBound < footer.lowerBound,
              "the list footer is on the non-empty branch, below the empty state")
    } else {
        check(false, "the Cycler pane branches on an empty binding list")
    }
    check(!cyclerPane.contains("private var header: some View"),
          "the Cycler pane's loose instruction paragraph is gone — the hero summary carries it")
    check(!cyclerPane.contains("Use one app to cycle its windows, or add several apps to cycle between them. Add"),
          "the tripled guidance sentence is not repeated in the pane body")

    let zonesPane = source("Sources/lineup/Tools/Zones/ZonesSettingsPane.swift")
    check(zonesPane.contains("caption: \"Click a shortcut, then press a key combo."),
          "the recorder instructions are a caption on the shortcut section, not a floating line")
    if let caption = zonesPane.range(of: "caption: \"Click a shortcut"),
       let dragSection = zonesPane.range(of: "SettingsSectionView(\"Drag to snap\")") {
        check(dragSection.lowerBound < caption.lowerBound,
              "the recorder caption sits below the drag-snap section, where the recorders are")
    } else {
        check(false, "the Zones pane keeps its drag-snap section")
    }
    check(source("Sources/lineup/Settings/Components/SettingsSection.swift")
            .contains("init(_ title: String, caption: String? = nil"),
          "SettingsSectionView supports a header caption")
}

// MARK: - Parity fixes (audit A28/B21/H8/B22-23-A30/A34/B3 + cross-tool conflicts)

/// The six confirmed 1.x parity regressions and the cross-tool conflict gap.
///
/// Two of them are pure logic that was deliberately lifted into AppCore so it could be asserted
/// directly (`ShortcutCaptureRules`, `ToolCombo`); the rest live in the app target, which this
/// runner does not link, so they are scanned the way every other shell rule here is.
private func runParityFixTests() throws {
    let files = sourceFiles()
    func source(_ path: String) -> String {
        guard let text = files.first(where: { $0.path == path })?.text else {
            check(false, "\(path) exists")
            return ""
        }
        return text
    }

    // ---- A28: a bare key is capturable ONLY where the field opts in ----
    do {
        let intent = ShortcutCaptureRules.intent

        // A shortcut row (allowsBareKey: false) — 1.x's rules, unchanged.
        check(intent(false, false, false, false) == .reject,
              "a bare key is refused by a shortcut row")
        check(intent(false, false, true, false) == .record,
              "a key with a modifier is recorded by a shortcut row")
        check(intent(true, false, false, false) == .cancel, "bare Esc cancels a shortcut row")
        check(intent(false, true, false, false) == .clear, "bare Delete clears a shortcut row")

        // The drag bind (allowsBareKey: true) — 1.x accepted F5-drag.
        check(intent(false, false, false, true) == .record,
              "a bare key IS recorded where the field allows one (Zones' drag bind)")
        check(intent(false, false, true, true) == .record,
              "a bare-key field still records key + modifiers")

        // The ordering that makes the bare-key field usable at all.
        check(intent(true, false, false, true) == .cancel,
              "Esc still cancels a bare-key field rather than being captured as its value")
        check(intent(false, true, false, true) == .clear,
              "Delete still resets a bare-key field rather than being captured as its value")

        // With a modifier held, both are ordinary keys — ⌘⌫ has to stay bindable.
        check(intent(true, false, true, false) == .record, "⌘-Esc is a combo, not a cancel")
        check(intent(false, true, true, false) == .record, "⌘⌫ is a combo, not a clear")
        check(intent(true, false, true, true) == .record,
              "⌘-Esc is a combo in a bare-key field too")
    }

    // ---- Cross-tool conflicts: a DISABLED tool still owns its combos ----
    do {
        let zonesLeft = ToolCombo(owner: .zones, keyCode: 123, modifiers: sampleHyperMask)
        let cyclerT = ToolCombo(owner: .cycler, keyCode: 17, modifiers: sampleHyperMask)
        // Exactly the shape `ToolRegistry.boundCombos()` produces with Cycler switched OFF: its
        // combos come from the persisted section, so they are here even though nothing is live.
        let combos = [zonesLeft, cyclerT]

        check(combos.conflictOwner(keyCode: 17, modifiers: sampleHyperMask, excluding: .zones) == .cycler,
              "Zones' recorder is told a combo belongs to Cycler even with Cycler not running")
        check(combos.conflictOwner(keyCode: 123, modifiers: sampleHyperMask, excluding: .cycler) == .zones,
              "Cycler's recorder is told a combo belongs to Zones")
        check(combos.conflictOwner(keyCode: 123, modifiers: sampleHyperMask, excluding: .zones) == nil,
              "a tool re-recording its OWN combo is not a cross-tool conflict")
        check(combos.conflictOwner(keyCode: 17, modifiers: 0, excluding: .zones) == nil,
              "the same key with different modifiers is a different combo")
        check(combos.conflictOwner(keyCode: 99, modifiers: sampleHyperMask, excluding: .zones) == nil,
              "an unclaimed combo has no owner")
        check([ToolCombo]().conflictOwner(keyCode: 17, modifiers: sampleHyperMask, excluding: .zones) == nil,
              "no bound combos means no conflict")
        // Deterministic naming: the registry puts persisted combos first, in registration order.
        check([cyclerT, ToolCombo(owner: .hyperkey, keyCode: 17, modifiers: sampleHyperMask)]
                .conflictOwner(keyCode: 17, modifiers: sampleHyperMask, excluding: .zones) == .cycler,
              "the first owner in the list is the one named")
    }

    // The live Carbon registry must not be anyone's conflict source any more: it only knows
    // about tools that are RUNNING, which is exactly the gap being closed.
    let comboSources = files.filter { $0.text.contains("registeredCombos()") }.map(\.path)
    check(comboSources == ["Sources/lineup/App/HotkeyManager.swift",
                           "Sources/lineup/App/ToolRegistry.swift"],
          "the live registry is read only by HotkeyManager and ToolRegistry.boundCombos() (got \(comboSources))")
    let registry = source("Sources/lineup/App/ToolRegistry.swift")
    check(registry.contains("func boundCombos() -> [ToolCombo]") && registry.contains("tool.persistedCombos()"),
          "boundCombos() unions every registered tool's persisted combos with the live ones")
    check(source("Sources/lineup/App/Tool.swift").contains("boundCombos: () -> [ToolCombo]"),
          "a tool reaches the conflict source through its ToolServices")
    check(!source("Sources/lineup/App/Tool.swift").contains("func foreignCombos()"),
          "HotkeyScope no longer offers a running-tools-only conflict list")

    // ---- B21 + B22: a live capture is cancelled before it can swallow keystrokes ----
    let cyclerPane = source("Sources/lineup/Tools/Cycler/CyclerSettingsPane.swift")
    for fn in ["func showAddShortcutPicker()", "func showAddAppPicker(for row: Row)",
               "func remove(_ row: Row)", "func reload()"] {
        guard let start = cyclerPane.range(of: fn) else {
            check(false, "CyclerSettingsModel implements \(fn)")
            continue
        }
        check(cyclerPane[start.lowerBound...].prefix(400).contains("cancelRecording?()"),
              "\(fn) cancels any live capture")
    }
    check(cyclerPane.contains("model.cancelRecording = { [weak recorder] in recorder?.cancel() }")
            && cyclerPane.contains("model.cancelRecording = nil"),
          "the Cycler pane lends the model its recorder's cancel, and takes it back on disappear")
    check(cyclerPane.contains("boundCombos.conflictOwner(keyCode: keyCode, modifiers: modifiers,"),
          "the Cycler pane now does a cross-tool conflict check of its own")
    check(cyclerPane.contains("model.prepareForRecording()"),
          "the Cycler pane snapshots the conflict list when a capture starts")
    let cyclerTool = source("Sources/lineup/Tools/Cycler/CyclerTool.swift")
    check(cyclerTool.contains("func persistedCombos()") && cyclerTool.contains("b.modifiers | UInt32(shiftKey)"),
          "Cycler reports its persisted combos INCLUDING the ⇧ reverses it would generate")

    // ---- H8: the Hyperkey pane behaves like the other two when writes are blocked ----
    let hyperPane = source("Sources/lineup/Tools/Hyperkey/HyperkeySettingsPane.swift")
    check(hyperPane.contains("model.blockedMessage") && hyperPane.contains("systemImage: \"lock.fill\""),
          "the Hyperkey pane shows the write-blocked banner the Zones pane shows")
    let disabledControls = hyperPane.components(separatedBy: ".disabled(!model.canEdit)").count - 1
    check(disabledControls == 2,
          "both the trigger picker and includeShift are disabled while writes are blocked (got \(disabledControls))")
    check(hyperPane.contains(".alert(item: $model.alert)"),
          "the Hyperkey pane surfaces a failed save, the way standalone Cycler did")
    let hyperTool = source("Sources/lineup/Tools/Hyperkey/HyperkeyTool.swift")
    check(hyperTool.contains("private func save() throws"),
          "a refused Hyperkey write is thrown, not only logged")
    check(hyperTool.contains("throw HyperkeyToolError.writesBlocked"),
          "a write-blocked store produces an error the pane can name")
    check(hyperTool.contains("func persist(rollingBackTo previous: HyperKeySettings)")
            && hyperTool.contains("settings = previous"),
          "a failed save puts the settings back, so the pane never shows a trigger that isn't saved")
    check(hyperTool.contains("var canPersist: Bool") && hyperTool.contains("var configBlockedMessage: String?"),
          "the Hyperkey tool exposes the same canPersist/blockedMessage pair Cycler does")

    // ---- A34: the two Abouts tell ONE story ----
    let aboutWindow = source("Sources/lineup/App/AboutWindow.swift")
    let aboutPane = source("Sources/lineup/Settings/AboutPane.swift")
    check(!aboutWindow.contains("MIT"), "the About window has no open-source licence line")
    check(!aboutWindow.lowercased().contains("github"),
          "the About window has no source-repository link (this branch is private)")
    check(aboutWindow.contains("lineup.caiano.com") && aboutPane.contains("lineup.caiano.com"),
          "both Abouts keep the product site")
    check(aboutWindow.contains("AboutFacts.copyright") && aboutPane.contains("AboutFacts.copyright"),
          "both Abouts render the SAME copyright string, so they cannot drift apart again")
    check(AboutFactsMirror.copyright == "© 2026 Henrique Caiano. All rights reserved."
            && aboutWindow.contains("\"\(AboutFactsMirror.copyright)\""),
          "the copyright line reserves all rights and names no licence")
    check(aboutWindow.contains("AboutFacts.buildDateLine()") && aboutPane.contains("AboutFacts.buildDateLine()"),
          "the build date the window always had is now on the Settings pane too")
    check(aboutWindow.contains("func versionLine()") && aboutPane.contains("CFBundleVersion"),
          "both Abouts show version and build")

    // ---- The About WINDOW takes the same ref-counted activation every other window does ----
    // Without it, an agent-only app shows About behind whatever is frontmost, and the window has
    // no Dock icon to get back to.
    check(aboutWindow.contains("ActivationCoordinator.shared.retain(Self.activationReason)")
          && aboutWindow.contains("ActivationCoordinator.shared.release(Self.activationReason)"),
          "the About window retains and releases the activation policy like Settings and Welcome")
    check(aboutWindow.components(separatedBy: "func windowWillClose").last?
        .contains("release(Self.activationReason)") == true,
          "About releases its activation claim when the window closes")
    // Layer colours resolved once at creation froze the card in whatever appearance was current;
    // an About window open across a Dark Mode switch kept a light card on a dark window.
    check(aboutWindow.contains("override func updateLayer()")
          && aboutWindow.contains("effectiveAppearance.performAsCurrentDrawingAppearance"),
          "About resolves its layer colours under the view's own effective appearance")
    check(aboutWindow.contains("override func viewDidChangeEffectiveAppearance()"),
          "About redraws those colours when the appearance changes")
    check(!aboutWindow.contains("layer?.backgroundColor = NSColor")
          && !aboutWindow.contains("layer?.borderColor = NSColor"),
          "no About layer colour is assigned from a one-shot NSColor.cgColor")

    // ---- B3: Settings opens on the Space the user is on ----
    check(source("Sources/lineup/Settings/SettingsWindowController.swift")
            .contains("collectionBehavior = [.moveToActiveSpace]"),
          "the Settings window follows the active Space (it is reused across openings)")
}

/// `AboutFacts` lives in the app target, which this runner does not link. Mirrored the same way
/// `ShortcutKitCaps` is, with the scan above pinning the real definition.
private enum AboutFactsMirror {
    static let copyright = "© 2026 Henrique Caiano. All rights reserved."
}

/// The onboarding copy lives in the app target, which this runner does not link. Mirrored the
/// same way `ShortcutKitCaps` is, with the scan above pinning the real definition.
private enum OnboardingCopyMirror {
    static let inputMonitoringNote = "Input Monitoring is asked for only when you turn Hyperkey on."
}

/// `ShortcutKit` and `SettingsMetrics` live in the app target, which this runner does not link.
/// These mirror the two pieces of pure logic worth asserting on directly; the source scans above
/// pin them to the real definitions so the mirror cannot drift silently.
private enum ShortcutKitCaps {
    static let modifierGlyphs: [Character] = ["⌃", "⌥", "⇧", "⌘"]

    static func split(_ display: String) -> [String] {
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
}

private enum SettingsMetricsMirror {
    static let rowHeight: Double = 44
    static let shortcutRowHeight: Double = 28
}

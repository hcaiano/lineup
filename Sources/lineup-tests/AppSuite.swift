import Foundation
import AppCore
import CyclerCore
import HyperkeyCore
import ZonesCore

// Shell-level checks: the config envelope, its write discipline, the legacy import/split, and
// source-scan invariants that keep the tools from stepping on each other.

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
    try runReleaseToolingTests()
    try runShellSourceScanTests()
    try runSettingsWindowTests()
    try runIntegrationTests()
    try runOnboardingTests()
    try runParityFixTests()
    try runConfigCorrectnessTests()
    try runToolWriteDisciplineTests()
    try runUIStateContractTests()
    try runVisualDesignTests()
    try runTilesShellContractTests()
}

// MARK: - Envelope

private func runEnvelopeTests() throws {
    // ---- Round-trip, including a tool section this build knows nothing about ----
    do {
        var cfg = LineupAppConfig()
        cfg.general.didShowWhatsNew2 = true
        cfg.general.didShowWhatsNewTiles = true
        try cfg.setSettings(CyclerToolSettings(bindings: [
            AppBinding(keyCode: 18, modifiers: sampleHyperMask, bundleIdentifier: "com.apple.Safari"),
        ]), for: .cycler)
        cfg.setEnabled(true, for: .cycler)
        // A section written by a FUTURE Lineup with a tool this build has never heard of.
        cfg.tools["quicknote"] = ToolSection(enabled: true, settings: .object([
            "note": .string("hi"),
            "count": .int(3),
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
        check(!fresh.general.didShowWhatsNewTiles,
              "fresh envelope has not shown the Tiles introduction")
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
        check(cfg.section(for: .zones)?.settings["schemaVersion"] == .int(3),
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
        check(v["a"] == .int(1), "JSONValue decodes a whole number as an int, not a lossy double")
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

    check(plistString("CFBundleShortVersionString") == "2.0.1", "Info.plist ships 2.0.1")
    // Sparkle offers an update only when the appcast's sparkle:version (CFBundleVersion) sorts
    // ABOVE the running app's. 2.0.0 shipped as build 18, so a 2.0.1 that reused 18 would be
    // invisible to every existing user. The build number must stay strictly monotonic.
    check(plistString("CFBundleVersion") == "19", "Info.plist ships build 19")
    check(Int(plistString("CFBundleVersion") ?? "0") ?? 0 > 18, "build number is above 2.0.0's build 18")
}

private func runReleaseToolingTests() throws {
    let publisher = try String(contentsOfFile: "Scripts/publish-appcast.sh", encoding: .utf8)
    check(publisher.contains("HOSTED_DMG=\"web/downloads/Lineup-${VERSION}.dmg\""),
          "publish-appcast names the self-hosted DMG")
    check(publisher.contains("git add -- web/appcast.xml \"$HOSTED_DMG\""),
          "publish-appcast commits the feed and its self-hosted DMG together")
    check(publisher.contains("Merge the PR, then deploy web/"),
          "publish-appcast does not claim that a merge deploys a dormant workflow")

    let deploy = try String(contentsOfFile: ".github/workflows/deploy-web.yml", encoding: .utf8)
    let release = try String(contentsOfFile: ".github/workflows/release.yml", encoding: .utf8)
    let ci = try String(contentsOfFile: ".github/workflows/ci.yml", encoding: .utf8)
    check(deploy.contains("vars.ENABLE_WEB_DEPLOY == 'true'")
            && release.contains("vars.ENABLE_RELEASE_WORKFLOW == 'true'"),
          "dormant release workflows use explicit repository-variable gates")
    check(ci.contains("runs-on: macos-26") && release.contains("runs-on: macos-26"),
          "CI and release builds use an SDK that provides macOS 26 symbols")
    if let appNotarize = release.range(of: "./Scripts/notarize.sh \"dist/Lineup.app\" lineup-notary"),
       let makeDMG = release.range(of: "./Scripts/make-dmg.sh") {
        check(appNotarize.lowerBound < makeDMG.lowerBound,
              "release notarizes and staples the app before packaging the DMG")
    } else {
        check(false, "release notarizes and staples the app before packaging the DMG")
    }
    check(deploy.contains("permissions:\n  contents: read")
            && deploy.contains("cloudflare/wrangler-action@9acf94ace14e7dc412b076f2c5c20b8ce93c79cd")
            && deploy.contains("wranglerVersion: '4.127.1'")
            && deploy.contains("persist-credentials: false"),
          "web deploy uses least privilege and pinned action and CLI versions")
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
    // could strand all tools' hotkeys unregistered.
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
    check(!icon.contains("Bundle.module."),
          "a missing tool resource bundle cannot trigger SwiftPM's fatal Bundle.module accessor")
    check(icon.contains("Bundle.main.resourceURL")
          && icon.contains("\"lineup_lineup.bundle\"")
          && icon.contains("\"cycler-icon\""),
          "Cycler's icon is loaded safely from the app's packaged resource bundle")
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
    // build-app.sh assembles the .app by hand. The bundle belongs in Contents/Resources; the
    // loader must still tolerate a missing copy and fall back to a drawn tile.
    let buildScript = (try? String(contentsOfFile: "Scripts/build-app.sh", encoding: .utf8)) ?? ""
    check(buildScript.contains("${EXEC_NAME}_${EXEC_NAME}.bundle")
          && buildScript.contains("${APP}/Contents/Resources/$(basename \"${RES_BUNDLE}\")"),
          "build-app.sh copies the SwiftPM resource bundle into Contents/Resources")
    check(buildScript.contains("Lineup-LICENSE.txt")
          && buildScript.contains("Sparkle-LICENSE.txt"),
          "build-app.sh includes Lineup and Sparkle licence notices")

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

    // ---- About ----
    let about = source("Sources/lineup/Settings/AboutPane.swift")
    check(about.contains("lineup.caiano.com"), "About links the product site")
    check(about.contains("AppUpdater.shared.checkForUpdates"), "About offers Check for Updates")
    check(about.contains("AboutFacts.copyright"), "About uses the shared attribution line")

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
    check(Onboarding.shouldShowWhatsNew(audience: .upgradingFrom1x, didShowCurrentWhatsNew: false,
                                        showingWelcome: false, canPersist: true),
          "a 1.x upgrade sees What's New")
    check(!Onboarding.shouldShowWhatsNew(audience: .upgradingFrom1x, didShowCurrentWhatsNew: true,
                                         showingWelcome: false, canPersist: true),
          "What's New is shown once — didShowWhatsNew2 retires it")
    check(!Onboarding.shouldShowWhatsNew(audience: .brandNew, didShowCurrentWhatsNew: false,
                                         showingWelcome: true, canPersist: true),
          "a brand-new user gets Welcome INSTEAD of What's New, never both")
    check(!Onboarding.shouldShowWhatsNew(audience: .brandNew, didShowCurrentWhatsNew: false,
                                         showingWelcome: false, canPersist: true),
          "a brand-new user never gets What's New even if Welcome was suppressed")
    check(Onboarding.shouldShowWhatsNew(audience: .returning, didShowCurrentWhatsNew: false,
                                        showingWelcome: false, canPersist: true),
          "a 2.0 user who has not seen the note yet still gets it")
    // An unreadable config.json reads as `.returning` with the flag false and cannot be written,
    // so without this gate the window came back at every single launch.
    check(!Onboarding.shouldShowWhatsNew(audience: .returning, didShowCurrentWhatsNew: false,
                                         showingWelcome: false, canPersist: false),
          "a write-blocked store suppresses What's New instead of showing it every launch")
    check(!Onboarding.shouldShowWhatsNew(audience: .upgradingFrom1x, didShowCurrentWhatsNew: false,
                                         showingWelcome: false, canPersist: false),
          "a 1.x upgrade with a rejected config.json is not shown a note that cannot be retired")

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
       let register = shell.range(of: "registry.register(ZonesTool("),
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
    check(shell.contains("$0.general.didShowWhatsNewTiles = true"),
          "dismissing What's New persists the Tiles introduction flag")

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
              "\(path) shows the shared tool tiles")
    }
    let onboardingKit = source("Sources/lineup/App/OnboardingKit.swift")
    check(onboardingKit.contains("ToolIcon(id: tool.id"),
          "the tiles reuse the Settings ToolIcon rather than inventing a second icon set")
    check(onboardingKit.contains("OnboardingTool(id: .tiles")
            && onboardingKit.contains("state: \"Off by default\", isOn: false"),
          "onboarding introduces Tiles without enabling it")
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
    // The section is titled "Behavior" since batch 3: it holds drag-to-snap, the drag bind AND the
    // layout-editor row, so "Drag to snap" named only a third of it (and repeated the row below it).
    if let caption = zonesPane.range(of: "caption: \"Click a shortcut"),
       let dragSection = zonesPane.range(of: "SettingsSectionView(\"Behavior\")") {
        check(dragSection.lowerBound < caption.lowerBound,
              "the recorder caption sits below the behaviour section, where the recorders are")
    } else {
        check(false, "the Zones pane keeps its behaviour section")
    }
    check(!zonesPane.contains("SettingsSectionView(\"Drag to snap\")")
            && !zonesPane.contains("SettingsSectionView(\"Zones\")"),
          "no section repeats its own row's title, and no section is named after the pane")
    check(zonesPane.contains("\"Zone shortcuts\","),
          "the zone rows sit under a \"Zone shortcuts\" header")
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
    // Since batch 3 the "lock.fill" glyph is `BlockedBanner`'s own default, so the pane no longer
    // names it — what it must still do is show that ONE shared banner for `blockedMessage`.
    check(hyperPane.contains("model.blockedMessage") && hyperPane.contains("BlockedBanner(message: message"),
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
    check(aboutWindow.contains("lineup.caiano.com") && aboutPane.contains("lineup.caiano.com"),
          "both Abouts keep the product site")
    check(aboutWindow.contains("AboutFacts.copyright") && aboutPane.contains("AboutFacts.copyright"),
          "both Abouts render the SAME copyright string, so they cannot drift apart again")
    check(AboutFactsMirror.copyright == "© 2026 Henrique Caiano. All rights reserved."
            && aboutWindow.contains("\"\(AboutFactsMirror.copyright)\""),
          "both Abouts keep the same copyright attribution")
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

// MARK: - Config + persistence correctness (review batch 2)

/// The write-discipline holes the second review pass found: a late legacy import replacing 2.0
/// settings, a reset that could not tell "unreadable" from "absent", a rewrite on every no-op
/// update, and two lossy spots in the envelope's own encoding.
private func runConfigCorrectnessTests() throws {
    let missing = URL(fileURLWithPath: "/nonexistent/lineup-tests/nothing.json")

    // ---- 1. A DEFERRED zones import that lands later must not replace 2.0 settings ----
    try withTempDir("import-late-zones") { dir in
        let url = try writeZonesFile(dir, legacyColumns)
        var cfg = LineupAppConfig()
        var r = LegacyImport.run(into: &cfg, zonesURL: url, cyclerBindingsURL: missing,
                                 now: "T", resolveLegacyScreen: neverResolve)
        check(r.zonesDeferred && cfg.section(for: .zones) == nil,
              "late-zones: the first pass defers and writes nothing")

        // The user configures Zones in 2.0 — and switches it off — while the display is away.
        var mine = LineupConfig()
        mine.dragSnapEnabled = false
        try cfg.setSettings(mine, for: .zones)
        cfg.setEnabled(false, for: .zones)

        // The display comes back and the import finally resolves.
        r = LegacyImport.run(into: &cfg, zonesURL: url, cyclerBindingsURL: missing,
                             now: "T2", resolveLegacyScreen: { _ in wideScreen })
        check(!r.importedZones, "late-zones: a skipped import does not claim to have imported")
        check(try cfg.settings(LineupConfig.self, for: .zones) == mine,
              "late-zones: the user's own 2.0 layout survives the retry")
        check(cfg.isEnabled(.zones) == false,
              "late-zones: the retry does not re-enable a tool the user switched off")
        check(cfg.general.didImportLegacyZones,
              "late-zones: the flag is set anyway, so the retry stops instead of looping")
    }

    // A section that only carries the seeded `enabled` flag is NOT the user's settings, so the
    // deferred import must still land — otherwise `startEnabledTools` seeding would block it.
    try withTempDir("import-late-zones-seeded") { dir in
        let url = try writeZonesFile(dir, legacyColumns)
        var cfg = LineupAppConfig()
        _ = LegacyImport.run(into: &cfg, zonesURL: url, cyclerBindingsURL: missing,
                             now: "T", resolveLegacyScreen: neverResolve)
        cfg.setEnabled(true, for: .zones) // the registry's first-launch seeding
        let r = LegacyImport.run(into: &cfg, zonesURL: url, cyclerBindingsURL: missing,
                                 now: "T2", resolveLegacyScreen: { _ in wideScreen })
        check(r.importedZones, "late-zones: a seeded-but-empty section does not block the import")
        check(try cfg.settings(LineupConfig.self, for: .zones)?.screens["uuid-wide"] != nil,
              "late-zones: the migrated layout lands on the reconnected display")
    }

    // ---- 1b. A corrupt bindings.json that becomes valid later ----
    try withTempDir("import-late-cycler") { dir in
        let url = try writeCyclerFile(dir, "{ nope")
        var cfg = LineupAppConfig()
        var r = LegacyImport.run(into: &cfg, zonesURL: missing, cyclerBindingsURL: url,
                                 now: "T", resolveLegacyScreen: neverResolve)
        check(r.cyclerError != nil && !cfg.general.didImportLegacyCycler,
              "late-cycler: a corrupt file reports and stays pending")

        // The user sets both tools up in 2.0 and keeps the menu-bar icon.
        let mine = CyclerToolSettings(bindings: [
            AppBinding(keyCode: 18, modifiers: sampleHyperMask, bundleIdentifier: "com.apple.Safari"),
        ])
        try cfg.setSettings(mine, for: .cycler)
        cfg.setEnabled(true, for: .cycler)
        let myHyper = HyperKeySettings(enabled: true, triggerKey: .f12, includeShift: true)
        try cfg.setSettings(myHyper, for: .hyperkey)
        cfg.setEnabled(true, for: .hyperkey)

        // …and then the legacy file becomes readable (fixed by hand, or Cycler rewrote it).
        try Data("""
        {"bindings":[{"keyCode":20,"modifiers":6912,"bundleIdentifier":"com.google.Chrome"}],
         "hyperKey":{"enabled":false,"triggerKey":"capsLock","includeShift":false},
         "showMenuBarIcon":false}
        """.utf8).write(to: url)
        r = LegacyImport.run(into: &cfg, zonesURL: missing, cyclerBindingsURL: url,
                             now: "T2", hasLineupHistory: false, resolveLegacyScreen: neverResolve)

        check(!r.importedCycler,
              "late-cycler: nothing is claimed when both sections are already the user's")
        check(try cfg.settings(CyclerToolSettings.self, for: .cycler) == mine,
              "late-cycler: the user's 2.0 bindings survive")
        check(try cfg.settings(HyperKeySettings.self, for: .hyperkey) == myHyper,
              "late-cycler: the user's 2.0 hyper-key trigger survives")
        check(cfg.general.showMenuBarIcon,
              "late-cycler: a late import cannot hide the menu-bar icon the user has been using")
        check(cfg.general.didImportLegacyCycler,
              "late-cycler: the flag settles so this stops retrying")
    }

    // Half and half: an untouched hyperkey section still imports even when cycler's is the user's.
    try withTempDir("import-late-cycler-half") { dir in
        let url = try writeCyclerFile(dir, """
        {"bindings":[{"keyCode":20,"modifiers":6912,"bundleIdentifier":"com.google.Chrome"}],
         "hyperKey":{"enabled":true,"triggerKey":"f12","includeShift":false},
         "showMenuBarIcon":false}
        """)
        var cfg = LineupAppConfig()
        let mine = CyclerToolSettings(bindings: [
            AppBinding(keyCode: 18, modifiers: sampleHyperMask, bundleIdentifier: "com.apple.Safari"),
        ])
        try cfg.setSettings(mine, for: .cycler)
        let r = LegacyImport.run(into: &cfg, zonesURL: missing, cyclerBindingsURL: url,
                                 now: "T", resolveLegacyScreen: neverResolve)
        check(try cfg.settings(CyclerToolSettings.self, for: .cycler) == mine,
              "late-cycler: the cycler section is judged on its own")
        check(try cfg.settings(HyperKeySettings.self, for: .hyperkey)?.triggerKey == .f12,
              "late-cycler: an untouched hyperkey section still imports")
        check(r.importedCycler && r.importedHyperkey && r.importedBindingCount == 0,
              "late-cycler: the report counts only what was actually written")
        check(cfg.general.showMenuBarIcon,
              "late-cycler: the icon flag is not adopted once any 2.0 section exists")
    }

    // ---- 2. reset(): an UNREADABLE file is preserved or the reset aborts ----
    try withTempDir("store-reset-unreadable") { dir in
        // A directory where the config should be: it exists, and reading it fails — exactly the
        // shape `try?` used to swallow, turning "cannot read" into "nothing to preserve".
        let url = dir.appendingPathComponent("config.json")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let store = LineupAppConfigStore(url: url)
        check(store.load() == .failed(.unreadable), "an unreadable config.json is rejected")
        var threw = false
        do { try store.reset(now: 4242) } catch { threw = true }
        check(threw, "reset throws rather than writing over bytes it could not preserve")
        check(!store.canWrite, "an aborted reset leaves writes blocked")
        var isDir: ObjCBool = false
        check(FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue,
              "an aborted reset leaves the unreadable file exactly as it was")
        check(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("config.rejected-4242.json").path),
              "an aborted reset writes no rejected copy either")
    }

    // …and with no file at all, reset is still the plain "start fresh" path.
    try withTempDir("store-reset-absent") { dir in
        let store = LineupAppConfigStore(url: dir.appendingPathComponent("config.json"))
        _ = store.load()
        try store.reset(now: 7)
        check(store.canWrite && store.state == .ok, "resetting with no file on disk succeeds")
        check(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["config.json"],
              "a reset with nothing to preserve writes no rejected copy")
    }

    // ---- 11. update() writes only when something actually changed ----
    try withTempDir("store-noop-update") { dir in
        let url = dir.appendingPathComponent("config.json")
        let store = LineupAppConfigStore(url: url)
        _ = store.load()
        try store.setEnabled(true, for: .zones)

        // A marker only a real write would replace.
        let marker = Data("MARKER".utf8)
        try marker.write(to: url)
        try store.update { $0.general.showMenuBarIcon = true }   // already true
        try store.setEnabled(true, for: .zones)                  // already true
        try store.setSettings(CyclerToolSettings(bindings: []), for: .cycler)
        try store.setSettings(CyclerToolSettings(bindings: []), for: .cycler) // second time: no-op
        check(try Data(contentsOf: url) != marker,
              "a real change still writes (the cycler section was new)")

        try marker.write(to: url)
        try store.update { $0.general.showMenuBarIcon = true }
        check(try Data(contentsOf: url) == marker,
              "an update that changes nothing does not rewrite the file all tools share")
        try store.update { $0.general.showMenuBarIcon = false }
        check(try Data(contentsOf: url) != marker, "a change that IS a change still writes")
    }

    // ---- 10. JSONValue keeps whole numbers whole ----
    do {
        let raw = Data(#"{"big":9007199254740993,"small":3,"neg":-42,"real":1.5,"exp":1e3}"#.utf8)
        let v = try JSONDecoder().decode(JSONValue.self, from: raw)
        check(v["big"] == .int(9007199254740993),
              "a 64-bit integer survives decoding (a Double would round it to ...92)")
        check(v["small"] == .int(3) && v["neg"] == .int(-42), "ordinary integers decode as ints")
        check(v["real"] == .number(1.5), "a fractional number is still a double")
        check(v["exp"] == .int(1000),
              "an exponent form with a whole value normalises to an int (1000 either way on encode)")

        let out = String(decoding: try JSONEncoder().encode(v), as: UTF8.self)
        check(out.contains("9007199254740993"), "the 64-bit integer is re-emitted exactly")
        check(!out.contains("9007199254740992"), "it is NOT re-emitted through a Double")
        check(String(decoding: try JSONEncoder().encode(JSONValue.int(3)), as: UTF8.self) == "3",
              "an int encodes the way the old Double did, so existing files are byte-identical")
        check(try JSONDecoder().decode(JSONValue.self, from: try JSONEncoder().encode(v)) == v,
              "the whole tree round-trips")
    }

    // ---- 9. Unknown keys survive a rewrite at every level of the envelope ----
    do {
        let raw = """
        {"schemaVersion":1,
         "futureTopLevel":{"a":[1,2]},
         "general":{"showMenuBarIcon":false,"futureGeneral":"keep me"},
         "tools":{"zones":{"enabled":true,"settings":{"schemaVersion":3},"futureSectionKey":7}}}
        """
        let cfg = try JSONDecoder().decode(LineupAppConfig.self, from: Data(raw.utf8))
        check(cfg.extra["futureTopLevel"] != nil, "an unknown top-level key is captured")
        check(cfg.general.extra["futureGeneral"] == .string("keep me"),
              "an unknown general key is captured")
        check(cfg.tools["zones"]?.extra["futureSectionKey"] == .int(7),
              "an unknown tool-section key is captured")
        check(cfg.extra["tools"] == nil && cfg.extra["general"] == nil,
              "known keys are not duplicated into the catch-all")

        let back = try JSONDecoder().decode(LineupAppConfig.self, from: try cfg.encoded())
        check(back == cfg, "an envelope with unknown keys round-trips")
        check(back.extra["futureTopLevel"]?["a"] == .array([.int(1), .int(2)]),
              "the unknown top-level value keeps its shape")
        check(back.general.extra["futureGeneral"] == .string("keep me"),
              "the unknown general key survives a rewrite")
        check(back.tools["zones"]?.extra["futureSectionKey"] == .int(7),
              "the unknown section key survives a rewrite")
        check(!back.general.showMenuBarIcon && back.general.didShowWhatsNew2 == false
              && back.general.didShowWhatsNewTiles == false,
              "the known general keys are unchanged by the catch-all")
        check(String(decoding: try back.encoded(), as: UTF8.self)
              == String(decoding: try cfg.encoded(), as: UTF8.self),
              "a second rewrite is byte-identical")

        // A rewrite through the real store, which is where the loss actually happened.
        try withTempDir("store-unknown-keys") { dir in
            let url = dir.appendingPathComponent("config.json")
            try Data(raw.utf8).write(to: url)
            let store = LineupAppConfigStore(url: url)
            check(store.load() == .loaded, "a file with unknown keys still loads")
            try store.setEnabled(false, for: .cycler)
            let reread = LineupAppConfigStore(url: url)
            _ = reread.load()
            check(reread.config.extra["futureTopLevel"] != nil,
                  "an unrelated write preserves the unknown top-level key")
            check(reread.config.general.extra["futureGeneral"] == .string("keep me"),
                  "an unrelated write preserves the unknown general key")
            check(reread.config.tools["zones"]?.extra["futureSectionKey"] == .int(7),
                  "an unrelated write preserves the unknown section key")
        }
    }

    // A fresh envelope carries no catch-all, so nothing new appears in a first-launch file.
    do {
        let fresh = String(decoding: try LineupAppConfig().encoded(), as: UTF8.self)
        check(!fresh.contains("extra"), "the catch-all is never written as a key of its own")
    }
}

// MARK: - Tool write discipline (review batch 2)

/// The tools and the registry live in the app target, which this runner does not link, so these
/// are source scans — the same way every other shell rule here is asserted. All of them are one
/// rule: nothing may write over settings it could not read, and no switch may claim a state that
/// did not reach disk.
private func runToolWriteDisciplineTests() throws {
    let files = sourceFiles()
    func source(_ path: String) -> String {
        guard let text = files.first(where: { $0.path == path })?.text else {
            check(false, "\(path) exists")
            return ""
        }
        return text
    }

    // ---- 3. Hyperkey treats an unreadable section the way Cycler and Zones do ----
    let hyperTool = source("Sources/lineup/Tools/Hyperkey/HyperkeyTool.swift")
    check(hyperTool.contains("private(set) var sectionLoadError: String?"),
          "HyperkeyTool records an unreadable section instead of silently using defaults")
    check(!hyperTool.contains("(try? services.config.load(HyperKeySettings.self))"),
          "attach no longer swallows a decode failure with try?")
    if let start = hyperTool.range(of: "private func mirrorEnabledFlag()") {
        check(hyperTool[start.lowerBound...].prefix(260).contains("sectionLoadError == nil"),
              "mirrorEnabledFlag refuses to write over an unreadable hyperkey section")
    } else {
        check(false, "HyperkeyTool owns mirrorEnabledFlag()")
    }
    check(hyperTool.contains("guard sectionLoadError == nil else { throw HyperkeyToolError.sectionUnreadable }"),
          "every hyperkey save is blocked while the section is unreadable")
    check(hyperTool.contains("var canPersist: Bool { sectionLoadError == nil"),
          "the Hyperkey pane is read-only while its section is unreadable")
    check(hyperTool.contains("func resetSection()") && hyperTool.contains("config.hyperkey-rejected-"),
          "Hyperkey's reset preserves the rejected blob first, under its own name")
    check(hyperTool.contains("id: \"hyperkey.config\"") && hyperTool.contains("Reset Hyperkey settings…"),
          "an unreadable hyperkey section becomes a warning with a recovery action")

    // ---- 4. Cycler: a load error blocks editing, and the pane says so instead of showing empty
    let cyclerTool = source("Sources/lineup/Tools/Cycler/CyclerTool.swift")
    check(cyclerTool.contains("var canEdit: Bool { canPersist && sectionLoadError == nil }"),
          "Cycler's pane cannot overwrite bindings it failed to read")
    check(cyclerTool.contains("guard sectionLoadError == nil else { throw CyclerToolError.sectionUnreadable }"),
          "a save is refused outright while the section is unreadable")
    check(cyclerTool.contains("func resetSection()") && cyclerTool.contains("config.cycler-rejected-"),
          "Cycler's reset preserves the rejected blob first")
    check(cyclerTool.contains("Reset Cycler shortcuts…"),
          "the unreadable-section warning offers the reset")
    let cyclerPane = source("Sources/lineup/Tools/Cycler/CyclerSettingsPane.swift")
    check(cyclerPane.contains("var canEdit: Bool { tool.canEdit }"),
          "the pane model reads the tool's combined edit gate")
    check(cyclerPane.contains("struct CyclerLoadErrorState") && cyclerPane.contains("Your shortcuts couldn’t be read"),
          "the pane has an explicit load-error state")
    if let error = cyclerPane.range(of: "if let message = model.loadErrorMessage {"),
       let empty = cyclerPane.range(of: "} else if model.rows.isEmpty {") {
        check(error.lowerBound < empty.lowerBound,
              "the load-error state replaces the empty state, never the other way round")
    } else {
        check(false, "the Cycler pane branches on the load error before the empty list")
    }
    // The two banners were an if/else: a blocked store plus an unreadable section showed only one.
    check(!cyclerPane.contains("} else if let message = model.blockedMessage {"),
          "the load-error and write-blocked banners are independent conditions")

    // ---- 5. restart() re-reads a STOPPED tool's section too ----
    let registry = source("Sources/lineup/App/ToolRegistry.swift")
    if let start = registry.range(of: "func restart(_ id: ToolID)") {
        let body = registry[start.lowerBound...].prefix(600)
        check(!body.contains("tool.isRunning else { return }"),
              "restart no longer no-ops for a stopped tool")
        check(body.contains("tool.attach("),
              "a stopped tool is re-attached so it re-reads its section")
        check(body.contains("if isEnabled(id)") && body.contains("start(tool)"),
              "restart re-asserts the persisted enable flag, so the switch and the tool agree")
    } else {
        check(false, "ToolRegistry owns restart(_:)")
    }

    // ---- 6. A refused enable write reverts the switch and is surfaced ----
    if let start = registry.range(of: "func setEnabled(_ enabled: Bool, for id: ToolID)") {
        let body = registry[start.lowerBound...].prefix(900)
        guard let persist = body.range(of: "try store.setEnabled(enabled, for: id)"),
              let act = body.range(of: "if !tool.isRunning { start(tool) }") else {
            check(false, "setEnabled both persists and starts the tool")
            return
        }
        check(persist.lowerBound < act.lowerBound,
              "setEnabled persists BEFORE it starts or stops, so a refused write changes nothing")
        check(body.contains("lastEnableError"),
              "a refused enable write is kept for the UI rather than only logged")
    } else {
        check(false, "ToolRegistry owns setEnabled(_:for:)")
    }
    let settingsStore = source("Sources/lineup/Settings/SettingsStore.swift")
    check(settingsStore.contains("@Published private(set) var toolEnableError: String?")
          && settingsStore.contains("toolEnableError = registry.lastEnableError"),
          "the Settings store republishes the failed toggle for the pane")
    check(source("Sources/lineup/Settings/SettingsStore.swift").contains("enableError: toolEnableError")
          && source("Sources/lineup/Settings/ToolPane.swift").contains("if let message = enableError {"),
          "the tool pane shows why a switch sprang back")
    // showMenuBarIcon self-corrects the way launchAtLogin does.
    check(settingsStore.contains("private let onMenuBarIconChange: (Bool) -> Bool"),
          "the menu-bar callback reports what is actually in force")
    if let start = settingsStore.range(of: "@Published var showMenuBarIcon: Bool {") {
        check(settingsStore[start.lowerBound...].prefix(320).contains("if actual != showMenuBarIcon"),
              "a refused menu-bar write puts the switch back instead of lying")
    } else {
        check(false, "SettingsStore owns the showMenuBarIcon toggle")
    }
    let shell = source("Sources/lineup/App/AppShell.swift")
    check(shell.contains("return store.config.general.showMenuBarIcon"),
          "the shell answers with the value that survived the write")

    // ---- 7. Zones validates a layout at WRITE time ----
    let zonesTool = source("Sources/lineup/Tools/Zones/ZonesTool.swift")
    if let start = zonesTool.range(of: "private func applyLayouts(") {
        let body = zonesTool[start.lowerBound...].prefix(900)
        guard let validate = body.range(of: "try updated.validate()"),
              let save = body.range(of: "try services.config.save(updated)") else {
            check(false, "applyLayouts validates and then saves")
            return
        }
        check(validate.lowerBound < save.lowerBound,
              "an invalid layout is refused at write time, not discovered at the next launch")
    } else {
        check(false, "ZonesTool owns applyLayouts")
    }
    check(zonesTool.contains("if let rejected = try services.config.load(JSONValue.self)"),
          "Zones' reset aborts when the rejected blob cannot be read back")

    // ---- 8. What's New is gated on a persistable store ----
    check(shell.contains("canPersist: store.canWrite"),
          "the shell will not show a note it cannot record as seen")

}

// MARK: - Settings UI state contracts (review batch 2)

/// The Settings window, the recorder and the panes, scanned for the same reason.
private func runUIStateContractTests() throws {
    let files = sourceFiles()
    func source(_ path: String) -> String {
        guard let text = files.first(where: { $0.path == path })?.text else {
            check(false, "\(path) exists")
            return ""
        }
        return text
    }
    let cyclerPane = source("Sources/lineup/Tools/Cycler/CyclerSettingsPane.swift")
    let zonesTool = source("Sources/lineup/Tools/Zones/ZonesTool.swift")
    let settingsStore = source("Sources/lineup/Settings/SettingsStore.swift")
    let recorder = source("Sources/lineup/Settings/Components/ShortcutRecorder.swift")

    // ---- 12. The window has a real minimum size ----
    let controller = source("Sources/lineup/Settings/SettingsWindowController.swift")
    check(controller.contains("window.contentMinSize = NSSize(width: 760, height: 520)"),
          "sizingOptions = [] disables AppKit's minimum, so the window sets its own")

    // ---- 13. The recorder does not hold the store unowned ----
    check(recorder.contains("private weak var store: SettingsStore?"),
          "the recorder holds its store weakly")
    check(!recorder.contains("private unowned let store"), "no unowned store reference is left")
    check(recorder.components(separatedBy: "store?.").count - 1 >= 3,
          "every store call is optional-chained")

    // ---- 14. Drag-to-snap cannot flip when it cannot be saved ----
    let zonesPane = source("Sources/lineup/Tools/Zones/ZonesSettingsPane.swift")
    if let start = zonesPane.range(of: "SettingsRow(title: \"Drag to snap\"") {
        check(zonesPane[start.lowerBound...].prefix(900).contains(".disabled(!model.canWrite)"),
              "the drag-snap toggle is disabled with the rest of the pane")
    } else {
        check(false, "the Zones pane has a Drag to snap row")
    }
    if let start = zonesTool.range(of: "private func setDragSnapEnabled(") {
        check(zonesTool[start.lowerBound...].prefix(300).contains("guard canWrite else { return }"),
              "the tool refuses the drag-snap edit too, so the menu row cannot lie either")
    } else {
        check(false, "ZonesTool owns setDragSnapEnabled")
    }
    check(zonesTool.contains("drag.isEnabled = canWrite"),
          "the menu's drag-snap row is disabled while writes are blocked")

    // ---- 15. A failed save is reported even when a sheet is dismissing ----
    if let start = cyclerPane.range(of: "func apply() -> Bool"),
       let fail = cyclerPane[start.lowerBound...].range(of: "catch {") {
        check(cyclerPane[fail.lowerBound...].prefix(700).contains("DispatchQueue.main.async"),
              "the save-failure alert is published on the next runloop turn, not inside the sheet's transaction")
    } else {
        check(false, "the Cycler model reports a failed apply()")
    }

    // ---- 16. The restore-failure alert waits out an app-modal prompt ----
    check(controller.contains("guard NSApp.modalWindow == nil else {"),
          "the restore-failure alert is re-queued while another modal owns the app")
    check(controller.contains("private func showRestoreAlert("),
          "the deferred presentation is its own step, so it can re-queue itself")

    // ---- 17. Re-targeting a recorder keeps the suspension ----
    if let start = recorder.range(of: "func begin(_ id: some Hashable"),
       let body = Optional(recorder[start.lowerBound...].prefix(700)) {
        check(body.contains("teardown()") && !body.contains("cancel()"),
              "begin re-targets without a Carbon resume+suspend round-trip")
    } else {
        check(false, "ShortcutRecorder owns begin(_:options:onCapture:)")
    }

    // ---- 18. A stale pane cannot clear the live pane's cancel hook ----
    for path in ["Sources/lineup/Tools/Cycler/CyclerSettingsPane.swift",
                 "Sources/lineup/Tools/Zones/ZonesSettingsPane.swift"] {
        let text = source(path)
        check(text.contains("weak var recorder: ShortcutRecorder?"),
              "\(path)'s model remembers whose cancel hook it holds")
        check(text.contains("guard model.recorder === recorder else { return }"),
              "\(path) only clears the hook when it is still its own")
    }

    // ---- 19. One refresh per sidebar toggle ----
    if let start = settingsStore.range(of: "func binding(forTool id: ToolID)") {
        let body = settingsStore[start.lowerBound...].prefix(600)
        check(body.contains("registry.setEnabled(newValue, for: id)") && !body.contains("self?.refresh()"),
              "the toggle relies on the registry's own change callback instead of refreshing twice")
    } else {
        check(false, "SettingsStore owns binding(forTool:)")
    }

    // ---- 20. Accessibility labels and honest tool names ----
    check(source("Sources/lineup/Settings/SettingsRootView.swift")
            .contains("accessibilityValue(row.isEnabled ? \"On\" : \"Off\")"),
          "a sidebar row states whether its tool is on")
    let hyperPane = source("Sources/lineup/Tools/Hyperkey/HyperkeySettingsPane.swift")
    check(hyperPane.contains(".accessibilityLabel(\"Trigger key\")")
          && hyperPane.contains(".accessibilityLabel(\"Include Shift\")"),
          "the Hyperkey controls are named for VoiceOver, which labelsHidden() strips")
    check(zonesPane.contains(".accessibilityLabel(\"Drag to snap\")"),
          "the Zones drag-snap toggle is named too")
    let rawNamers = files.filter { $0.text.contains("owner.rawValue.capitalized") }.map(\.path)
    check(rawNamers.isEmpty,
          "a conflict alert names the tool the way the sidebar does (got \(rawNamers))")
    for path in ["Sources/lineup/Tools/Cycler/CyclerSettingsPane.swift",
                 "Sources/lineup/Tools/Zones/ZonesSettingsPane.swift"] {
        check(source(path).contains("settings?.displayName(for: id)"),
              "\(path) takes its tool names from SettingsStore.displayName(for:)")
    }

    // ---- 21. Resetting the drag bind ends the capture first ----
    if let start = zonesPane.range(of: "func resetDragBind()") {
        check(zonesPane[start.lowerBound...].prefix(420).contains("cancelRecording?()"),
              "resetDragBind cancels a live capture, like clearShortcut does")
    } else {
        check(false, "ZonesSettingsModel owns resetDragBind()")
    }
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

// MARK: - Visual design system (review batch 3)

/// The 2.0 design review's findings, locked in as source rules.
///
/// Every one of these is a "this is done in exactly one place, the same way everywhere" property,
/// which is why they are scans: the panes are SwiftUI view bodies the runner cannot instantiate,
/// but the shared component being used at all (rather than a fourth hand-rolled variant appearing
/// in the next tool) is a text property of the tree.
private func runVisualDesignTests() throws {
    let files = sourceFiles()
    func source(_ path: String) -> String {
        guard let text = files.first(where: { $0.path == path })?.text else {
            check(false, "\(path) exists")
            return ""
        }
        return text
    }

    // ---- 1. ONE blocked banner, used by every pane ----
    let banner = source("Sources/lineup/Settings/Components/BlockedBanner.swift")
    check(banner.contains("struct BlockedBanner: View"), "the shared blocked banner exists")
    check(banner.contains("var actionTitle: String?") && banner.contains("var action: (() -> Void)?"),
          "the banner carries the tool's own recovery action, so it is never a dead end")
    check(banner.contains("var actionEnabled: Bool"),
          "the banner can show a recovery it cannot currently run, rather than hiding it")
    check(banner.contains("struct PinnedBannerStrip"),
          "the banner has one placement helper, so every pane pins it the same way")
    check(banner.contains("SettingsMetrics.contentWidth"),
          "the pinned banner sits on the shared content column, not on the pane edge")

    let bannerUsers = [
        "Sources/lineup/Tools/Zones/ZonesSettingsPane.swift",
        "Sources/lineup/Tools/Cycler/CyclerSettingsPane.swift",
        "Sources/lineup/Tools/Hyperkey/HyperkeySettingsPane.swift",
        "Sources/lineup/Settings/ToolPane.swift",
    ]
    for path in bannerUsers {
        let text = source(path)
        check(text.contains("PinnedBannerStrip {") && text.contains("BlockedBanner("),
              "\(path) shows the blocked state through the shared pinned banner")
    }
    for path in bannerUsers.dropLast() { // ToolPane's banner explains a switch, not a section
        check(source(path).contains("actionTitle: \"Reset"),
              "\(path)'s banner offers its tool's reset")
    }
    // The three hand-rolled variants the banner replaced. Each was an orange Label at a different
    // place in a different pane, which gave one condition three severities.
    for path in bannerUsers {
        let text = source(path)
        check(!text.contains("Label(message, systemImage:")
                && !text.contains("Label(model.blockedMessage"),
              "\(path) has no hand-rolled blocked label left")
    }

    // ---- 2. Contrast: a sentence is never drawn in orange ----
    //
    // `Color.orange` on the light window background measures 2.34:1, well under the 4.5:1 body
    // floor. SF Symbols keep it — a glyph only has to be noticed — so the rule is about `Text`.
    check(banner.contains("Text(message)"), "the banner draws its message as a Text")
    if let msg = banner.range(of: "Text(message)") {
        let chain = banner[msg.lowerBound...].prefix(220)
        check(chain.contains(".foregroundStyle(.primary)"),
              "the banner's message is .primary, never the orange the old variants used")
        check(!chain.contains("orange"), "no orange reaches the banner's message text")
    }
    var orangeText: [String] = []
    for file in files where file.path.hasPrefix("Sources/lineup/") {
        let lines = file.text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        for (i, line) in lines.enumerated() where line.contains("Text(") {
            // Walk the modifier chain hanging off this Text and stop at the next statement.
            var j = i + 1
            while j < lines.count, j <= i + 5 {
                let next = lines[j].trimmingCharacters(in: .whitespaces)
                guard next.hasPrefix(".") else { break }
                if next.contains("foregroundStyle(.orange)") || next.contains("foregroundStyle(Color.orange)") {
                    orangeText.append("\(file.path):\(j + 1)")
                }
                j += 1
            }
            let inline = line
            if inline.contains(".foregroundStyle(.orange)") || inline.contains(".foregroundStyle(Color.orange)") {
                orangeText.append("\(file.path):\(i + 1)")
            }
        }
    }
    check(orangeText.isEmpty,
          "no body text is drawn in orange, which cannot reach 4.5:1 on the light window (got \(orangeText))")

    // ---- 3. Shared HUD motion, and glass that does not follow a light desktop ----
    let motion = source("Sources/lineup/App/HUDMotion.swift")
    check(motion.contains("static let fadeIn: TimeInterval = 0.12")
            && motion.contains("static let fadeOut: TimeInterval = 0.14"),
          "the two overlays share one fade pair (0.12 in, 0.14 out)")
    check(motion.contains("accessibilityDisplayShouldReduceMotion") && motion.contains("? 0 : base"),
          "Reduce Motion snaps the overlays instead of crossfading, and still runs the completion")
    for path in ["Sources/lineup/Tools/Cycler/CycleHUD.swift",
                 "Sources/lineup/Tools/Hyperkey/HyperKeyBlockedPill.swift"] {
        let text = source(path)
        check(text.contains("HUDMotion.duration(HUDMotion.fadeIn)")
                && text.contains("HUDMotion.duration(HUDMotion.fadeOut)"),
              "\(path) takes both fades from HUDMotion")
        check(text.contains("glass.appearance = NSAppearance(named: .darkAqua)"),
              "\(path) pins its glass dark, because its labels are hard white")
        check(text.contains("NSAppearance(named: .vibrantDark)"),
              "\(path)'s pre-26 fallback keeps forcing a dark vibrancy, for the same reason")
    }

    // ---- 4. One rhythm for every pane ----
    let metrics = source("Sources/lineup/Settings/Components/SettingsSection.swift")
    check(metrics.contains("static let contentWidth: CGFloat = 540")
            && metrics.contains("static let sectionSpacing: CGFloat = 26")
            && metrics.contains("static let panePaddingVertical: CGFloat = 24"),
          "SettingsMetrics owns the column width and both outer gaps")
    let panes = ["Sources/lineup/Settings/GeneralPane.swift",
                 "Sources/lineup/Tools/Zones/ZonesSettingsPane.swift",
                 "Sources/lineup/Tools/Cycler/CyclerSettingsPane.swift",
                 "Sources/lineup/Tools/Hyperkey/HyperkeySettingsPane.swift"]
    for path in panes {
        let text = source(path)
        check(text.contains(".frame(width: SettingsMetrics.contentWidth"),
              "\(path) sets the column WIDTH, so every pane centres on the same gutter")
        check(!text.contains("maxWidth: SettingsMetrics.contentWidth"),
              "\(path) does not merely cap its width (Hyperkey did, and drifted)")
        check(text.contains("spacing: SettingsMetrics.sectionSpacing")
                && text.contains(".padding(.vertical, SettingsMetrics.panePaddingVertical)"),
              "\(path) takes its section spacing and pane padding from SettingsMetrics")
    }
    check(source("Sources/lineup/Settings/ToolPane.swift")
            .contains("ToolIcon(id: id, size: 72)\n                .padding(.bottom, 2)\n                .frame(width: SettingsMetrics.contentWidth)"),
          "the hero enable switch hangs off the 540pt content gutter, not the pane edge")

    // ---- 5. Type hierarchy and section endings ----
    check(metrics.contains(".font(.system(size: 15, weight: .semibold))"),
          "a section header is a real step above the 13pt row title under it")
    check(metrics.contains(".padding(.bottom, -SettingsMetrics.dividerThickness)")
            && metrics.contains(".clipped()"),
          "a section drops the hairline under its LAST row, which separated nothing")
    check(metrics.contains("struct SettingsCaption"),
          "a standing explanation has a caption shape, instead of a row promising a control")
    let hyperPane = source("Sources/lineup/Tools/Hyperkey/HyperkeySettingsPane.swift")
    check(!hyperPane.contains("EmptyView()\n                        }\n                    }\n                } else if"),
          "the Hyperkey status line is no longer a SettingsRow with an empty control")
    check(hyperPane.contains("SettingsCaption(text: status"),
          "the running status is a caption")
    check(hyperPane.contains("SettingsCaption(\n            text: \"Zones and Cycler shortcuts use"),
          "the cross-tool hint is a caption, not the window's only card")
    check(!hyperPane.contains("Color(nsColor: .textBackgroundColor).opacity(0.5)"),
          "the hint card's 1.000-contrast fill is gone")

    // ---- 6. One key cap size, one modifier vocabulary ----
    let caps = source("Sources/lineup/Settings/Components/KeyCapRow.swift")
    check(!caps.contains("enum Size") && !caps.contains("var size: Size"),
          "key caps render at ONE size, in both recorder controls")
    check(caps.contains("@Environment(\\.isEnabled)")
            && caps.contains("isEnabled ? Color.primary : Color.secondary"),
          "key caps dim with their control: an explicit colour is not dimmed by .disabled(), and a "
            + "write-blocked pane showed live-looking shortcuts under a banner saying otherwise")
    check(source("Sources/lineup/Settings/Components/ShortcutField.swift").contains("KeyCapRow(display: text)"),
          "Cycler's field uses the same caps Zones' button does")
    let zonesPaneSource = source("Sources/lineup/Tools/Zones/ZonesSettingsPane.swift")
    let kit = source("Sources/lineup/App/ShortcutKit.swift")
    check(kit.contains("static func modifierDisplay") && kit.contains("s += \"⇧\""),
          "a modifier-only bind renders as glyphs, like every other shortcut in the window")
    check(kit.contains("static func modifierWords"),
          "the worded form survives for help text and VoiceOver, where a glyph reads as nothing")
    check(zonesPaneSource.contains("var dragTriggerSpokenValue: String")
            && zonesPaneSource.contains("ShortcutKit.modifierWords(dragTrigger.modifiers)")
            && zonesPaneSource.contains("accessibilityValue: model.dragTriggerSpokenValue"),
          "the drag bind SHOWS glyphs and SPEAKS words, so the swap costs no accessibility")
    let recorderButton = source("Sources/lineup/Settings/Components/RecorderButton.swift")
    check(recorderButton.contains(".frame(minWidth: Self.minWidth)") && !recorderButton.contains(".frame(width: 164)"),
          "the recorder button sizes to its content above a minimum, instead of clipping at 164pt")
    for path in [recorderButton, source("Sources/lineup/Settings/Components/ShortcutField.swift")] {
        check(path.contains("Press keys…") && !path.contains("Press keys..."),
              "the recorder placeholder uses a real ellipsis")
    }

    // ---- 7. A refused keystroke is seen as well as heard ----
    let feedback = source("Sources/lineup/Settings/Components/RecordingFeedback.swift")
    check(feedback.contains("func recordingRejectionShake") && feedback.contains("accessibilityReduceMotion"),
          "the rejection shake exists and is skipped under Reduce Motion")
    let recorder = source("Sources/lineup/Settings/Components/ShortcutRecorder.swift")
    if let beep = recorder.range(of: "NSSound.beep()") {
        check(recorder[beep.lowerBound...].prefix(120).contains("rejectionCount &+= 1"),
              "every beep is paired with the counter the capturing control watches")
    } else {
        check(false, "the recorder beeps on a refused keystroke")
    }
    for path in ["Sources/lineup/Settings/Components/RecorderButton.swift",
                 "Sources/lineup/Settings/Components/ShortcutField.swift"] {
        let text = source(path)
        check(text.contains("var rejectionCount: Int") && text.contains(".recordingRejectionShake(rejectionCount)"),
              "\(path) shakes on a refused keystroke")
        check(text.contains("strokeBorder"),
              "\(path) shows a visible recording border, not only a tint")
    }

    // ---- 8. The accent belongs to the selection ----
    let root = source("Sources/lineup/Settings/SettingsRootView.swift")
    if let tint = root.range(of: ".tint(Color(nsColor: Brand.blue))"),
       let style = root.range(of: ".navigationSplitViewStyle(") {
        check(tint.lowerBound < style.lowerBound,
              "the brand tint is on the SIDEBAR column; on the split view every pane button went blue")
    } else {
        check(false, "the Settings root tints its sidebar")
    }
    check(root.components(separatedBy: ".tint(").count - 1 == 1,
          "the window tints exactly one thing")

    // ---- 9. Cycler: an orphaned binding says so, and says which app ----
    let cyclerPane = source("Sources/lineup/Tools/Cycler/CyclerSettingsPane.swift")
    check(source("Sources/lineup/Tools/Cycler/AppPicker.swift").contains("static func displayName(forBundleIdentifier"),
          "an uninstalled app has a friendly name to fall back on")
    check(cyclerPane.contains("AppInfo.displayName(forBundleIdentifier: bundleIdentifier)"),
          "the pane uses it, so a row is never titled with a raw bundle identifier")
    check(cyclerPane.contains("var isOrphaned: Bool") && cyclerPane.contains("row.isOrphaned ? 0.55 : 1"),
          "a binding whose apps are ALL gone is dimmed, single-app rows included")
    if let warn = cyclerPane.range(of: "if row.missingCount > 0 {") {
        let body = cyclerPane[warn.lowerBound...].prefix(700)
        check(body.contains("exclamationmark.triangle.fill") && body.contains(".foregroundStyle(.orange)"),
              "the missing-app warning is visible rather than a tertiary grey glyph")
        check(body.contains(".accessibilityLabel(row.missingHelp)"),
              "the warning glyph is named for VoiceOver")
    } else {
        check(false, "the Cycler row warns about missing apps")
    }
    check(cyclerPane.contains(".accessibilityLabel(\"\\(app.name) is not installed\")"),
          "a missing GROUP member is named too")

    // ---- 10. Merging two Cycler rows is a decision, not a side effect ----
    if let merge = cyclerPane.range(of: "if let other = rows.firstIndex(where: {") {
        check(cyclerPane[merge.lowerBound...].prefix(500).contains("guard confirmMerge("),
              "recording a duplicate combo asks before folding one row into the other")
    } else {
        check(false, "the Cycler model still merges on a duplicate combo")
    }
    check(cyclerPane.contains("alert.addButton(withTitle: \"Merge\")")
            && cyclerPane.contains("alert.addButton(withTitle: \"Cancel\")")
            && cyclerPane.contains("target.title") && cyclerPane.contains("source.title"),
          "the merge alert names BOTH rows and offers Merge/Cancel, like Zones' reassign")

    // ---- 11. Cycler's pane is the same window as the other two ----
    check(!cyclerPane.contains(".listStyle(.inset)") && !cyclerPane.contains("scrollContentBackground"),
          "the List inset background that made Cycler look like another app is gone")
    check(cyclerPane.contains("SettingsSectionView(\n                            \"Shortcuts\","),
          "Cycler's rows live in a SettingsSectionView like every other pane's")
    check(cyclerPane.contains("CyclerEmptyState") && cyclerPane.contains("CyclerLoadErrorState"),
          "the good empty state and the batch-2 load-error state both survive the unification")

    // ---- 12. Zones: the layout editor is reachable from the pane that owns zones ----
    let zonesPane = source("Sources/lineup/Tools/Zones/ZonesSettingsPane.swift")
    check(zonesPane.contains("Button(\"Open Layout Editor…\") { model.openLayoutEditor() }")
            && zonesPane.contains(".disabled(!model.canOpenLayoutEditor)"),
          "the pane opens the layout editor, and only when the tool can actually show it")
    check(zonesPane.contains("var canOpenLayoutEditor: Bool { isRunning && canWrite }"),
          "the editor needs a running tool AND a writable config")
    check(source("Sources/lineup/Tools/Zones/ZonesTool.swift").contains("openLayoutEditor: { [weak self] in self?.openEditor() }"),
          "the pane's button and the menu item run the SAME action")
    check(zonesPane.contains("if row.isBeyondLayout") && zonesPane.contains("(not in current layout)"),
          "a zone row past the saved layout says so instead of silently doing nothing")

    // ---- 13. Hyperkey: the F-key caveat, where it applies ----
    check(source("Sources/HyperkeyCore/TriggerKey.swift").contains("public var isFunctionKey: Bool"),
          "the trigger model knows which keys are function keys")
    check(hyperPane.contains("settings.triggerKey.isFunctionKey")
            && hyperPane.contains("Use F1, F2, etc. keys as standard function keys"),
          "the pane names the System Settings switch a function-key trigger needs")
    check(hyperPane.contains("caption: model.triggerCaption"),
          "the caveat is the section's caption, so it appears only for the key it applies to")

    // ---- 14. About: one story, one icon ----
    let aboutPane = source("Sources/lineup/Settings/AboutPane.swift")
    check(aboutPane.contains("Image(nsImage: AppIconImage.shared)") && !aboutPane.contains("Brand.menuBarLogo()"),
          "the About pane shows the real app icon, like the About window does")
    check(aboutPane.contains("Spacer(minLength: 0)")
            && aboutPane.components(separatedBy: "Spacer(minLength: 0)").count - 1 == 2,
          "the About content is centred between equal spacers, not stranded at the two edges")

    // ---- 15. Onboarding: good news reads as good news ----
    let onboardingKit = source("Sources/lineup/App/OnboardingKit.swift")
    check(onboardingKit.contains("static let successTint"),
          "the import confirmation has a success tint of its own")
    for path in ["Sources/lineup/App/WelcomeWindow.swift", "Sources/lineup/App/WhatsNewWindow.swift"] {
        let text = source(path)
        check(text.contains("tint: OnboardingBanner.successTint"),
              "\(path)'s import confirmation is not drawn in the warning's colour")
        check(text.contains(".buttonStyle(.borderedProminent)"),
              "\(path) has exactly one recommended action, and it looks like one")
    }

    // ---- 16. Em dashes are not user-facing copy ----
    var dashes: [String] = []
    for file in files {
        for (i, raw) in file.text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let line = String(raw)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("//") || trimmed.hasPrefix("*") { continue }
            guard line.contains("—") else { continue }
            // A trailing comment on a code line is prose too, not copy.
            if let commentStart = line.range(of: "//"),
               line.range(of: "—")!.lowerBound > commentStart.lowerBound { continue }
            dashes.append("\(file.path):\(i + 1)")
        }
    }
    check(dashes.isEmpty, "no user-facing string carries an em dash (got \(dashes))")

    // ---- 17. The app picker opens ready to type ----
    let picker = source("Sources/lineup/Tools/Cycler/AppPicker.swift")
    check(picker.contains("@FocusState private var searchFocused") && picker.contains("searchFocused = true"),
          "the app picker focuses its search field on open")
    check(picker.contains(".onSubmit { pickFirstMatch() }") && picker.contains("private func pickFirstMatch()"),
          "Return picks the first match, and does nothing when there is none")
}

// MARK: - Tiles shell and Settings (Phase 2)

/// Tiles' shell lives in the AppKit executable, so these contracts are source scans. The scans
/// keep the Phase 2 seam narrow: config and hotkeys belong to TilesTool, window work belongs to an
/// injected coordinator, and Settings remains usable while the tool is off.
private func runTilesShellContractTests() throws {
    let files = sourceFiles()
    func source(_ path: String) -> String {
        guard let text = files.first(where: { $0.path == path })?.text else {
            check(false, "\(path) exists")
            return ""
        }
        return text
    }

    check(ToolID.all == [.zones, .tiles, .cycler, .hyperkey],
          "ToolID order is Zones, Tiles, Cycler, Hyperkey")

    let shell = source("Sources/lineup/App/AppShell.swift")
    guard let zones = shell.range(of: "registry.register(ZonesTool("),
          let tiles = shell.range(of: "registry.register(TilesTool("),
          let cycler = shell.range(of: "registry.register(CyclerTool())") else {
        check(false, "AppShell registers Zones, Tiles and Cycler")
        return
    }
    check(zones.lowerBound < tiles.lowerBound && tiles.lowerBound < cycler.lowerBound,
          "Tiles is registered after Zones and before Cycler")

    let mutationCenter = source("Sources/lineup/App/ZoneLayoutMutationCenter.swift")
    check(mutationCenter.contains("@MainActor\nfinal class ZoneLayoutMutationCenter")
            && mutationCenter.contains("screenKey: String")
            && mutationCenter.contains("leafIndex: Int"),
          "Zones and Tiles share a narrow main-actor layout mutation center")
    check(shell.contains("layoutMutationCenter: layoutMutationCenter"),
          "AppShell injects the same layout mutation center into both tools")
    let tilesCoordinator = source("Sources/lineup/Tools/Tiles/TilesCoordinator.swift")
    check(!tilesCoordinator.contains("LayoutEdit.") && !tilesCoordinator.contains("config.save"),
          "Tiles does not write Zones geometry directly")

    let tool = source("Sources/lineup/Tools/Tiles/TilesTool.swift")
    check(tool.contains("final class TilesTool: Tool"), "TilesTool conforms to Tool")
    check(tool.contains("let id = ToolID.tiles") && tool.contains("let displayName = \"Tiles\""),
          "Tiles has the stable id and user-facing name")
    check(tool.contains("let defaultEnabled = false"), "Tiles is disabled by default")
    check(tool.contains("let requiredPermissions: Set<Permission> = [.accessibility]"),
          "Tiles requests Accessibility only")
    check(tool.contains("func attach(_ services: ToolServices)")
            && tool.contains("func start(_ services: ToolServices)")
            && tool.contains("func stop()"),
          "Tiles implements the complete lifecycle")
    check(tool.contains("protocol TilesCoordinatorProtocol")
            && tool.contains("private let coordinator: TilesCoordinatorProtocol"),
          "Tiles injects its runtime through the coordinator protocol")
    check(tool.contains("func start(settings: TilesSettings) throws")
            && tool.contains("func perform(_ action: TilesRuntimeAction)")
            && tool.contains("var onPresentation: ((TilesPresentation) -> Void)?"),
          "the coordinator boundary has runtime actions and confirmed presentation feedback")
    check(tool.contains("services.hotkeys.unregisterAll()")
            && tool.contains("TilesHUD.shared.dismiss()"),
          "stop releases hotkeys and HUD resources")
    check(tool.contains("private(set) var sectionLoadError: String?")
            && tool.contains("func resetSection()")
            && tool.contains("config.tiles-rejected-"),
          "an invalid Tiles section is blocked and reset preserves a rejected copy")
    check(tool.contains("guard services.config.canWrite")
            && tool.contains("runtimeBlockedMessage"),
          "a blocked config or preflight leaves Tiles paused without runtime resources")
    check(tool.contains("func persistedCombos()")
            && tool.contains("UInt32(shiftKey)")
            && tool.contains("conflictOwner(keyCode:"),
          "persistedCombos includes generated reverse bindings and sibling conflicts")
    check(tool.contains("func hotkeysFailedToRestore(_ failures: [HotkeyRestoreFailure])"),
          "Tiles receives shortcut restore failures for retry")

    let pane = source("Sources/lineup/Tools/Tiles/TilesSettingsPane.swift")
    check(pane.contains("SettingsSectionView(\"Workspace\")")
            && pane.contains("SettingsSectionView(\"Behavior\")")
            && pane.contains("SettingsSectionView(\"Shortcuts\""),
          "Tiles Settings has Workspace, Behavior and Shortcuts sections")
    check(pane.contains("ForEach(1...4")
            && pane.contains(".pickerStyle(.segmented)")
            && pane.contains("Uses your Zones layouts. Workspaces are separate from macOS Spaces."),
          "the pane exposes four segmented workspaces and explains native Spaces")
    // The pane renders one row per `TilesTool.Action`, so the labels live on the
    // action and the pane only has to iterate every case.
    check(pane.contains("TilesTool.Action.allCases"),
          "Tiles Settings renders a shortcut row for every action")
    for label in ["Next Workspace", "Next Window in Tile", "Move Window to Next Workspace",
                  "Focus Tile Left", "Focus Tile Right", "Focus Tile Up", "Focus Tile Down",
                  "Move Window Left", "Move Window Right", "Move Window Up", "Move Window Down",
                  "Switch Split Direction"] {
        check(tool.contains(label), "Tiles Settings includes the \(label) shortcut row")
    }
    check(pane.contains("Space between tiles")
            && pane.contains("tileSpacingEnabled")
            && pane.contains("tileSpacingPoints"),
          "Tiles Settings exposes one switch for 8 pt tile spacing")
    check(tool.contains("let focus = NSMenuItem(title: \"Focus Tile\"")
            && tool.contains("let moveTile = NSMenuItem(title: \"Move Focused Window\"")
            && tool.contains("Switch Split Direction"),
          "Tiles menu exposes directional focus, move and split controls")
    check(pane.contains("ShortcutRecorder")
            && pane.contains("RecorderButton(")
            && pane.contains("Set shortcut")
            && pane.contains("For workspace and stack shortcuts without Shift, hold Shift for previous"),
          "Tiles shortcuts start unassigned and use the shared recorder")
    check(pane.contains("BlockedBanner(message: message")
            && pane.contains("model.canEdit")
            && pane.contains("model.canUseRuntime"),
          "Tiles Settings has blocked states and disables the correct controls")
    check(pane.contains("accessibilityLabel(model.canUseRuntime")
            && pane.contains("\"Active workspace\"")
            && pane.contains("\"Starting workspace\""),
          "workspace picker explains its active and disabled states")

    let icon = source("Sources/lineup/Settings/Components/ToolIcon.swift")
    check(icon.contains("case .tiles: return \"square.grid.3x3.fill\""),
          "Tiles uses the generated AppStyleIcon fallback")
    let brand = source("Sources/lineup/App/Brand.swift")
    check(brand.contains("case .tiles: return blue"), "Tiles uses Brand.blue")

    let hud = source("Sources/lineup/Tools/Tiles/TilesHUD.swift")
    check(hud.contains("styleMask: [.borderless, .nonactivatingPanel]")
            && hud.contains("canJoinAllSpaces")
            && hud.contains("fullScreenAuxiliary")
            && hud.contains("ignoresCycle")
            && hud.contains("ignoresMouseEvents = true"),
          "Tiles HUD is non-activating and click-through")
    check(hud.contains("func showWorkspace") && hud.contains("func showStack")
            && hud.contains("func showConfirmation")
            && hud.contains("func showFailure")
            && hud.contains("HUDMotion.duration(HUDMotion.fadeIn)")
            && hud.contains("HUDMotion.duration(HUDMotion.fadeOut)")
            && hud.contains("Brand.blue"),
          "Tiles HUD covers workspace, stack and failure states with shared motion")
    check(tool.contains("private func handle(_ presentation: TilesPresentation)")
            && !tool.contains("coordinator.perform(.switchWorkspace(workspace))\n        hudWasUsed"),
          "Tiles shows the HUD from confirmed coordinator feedback, not stale action state")

    let tilesFiles = files.filter { $0.path.contains("/Tiles/") }
    let forbidden = ["CGSMainConnectionID", "CGSSetWorkspace", "SkyLight", "offscreen"]
    check(!tilesFiles.contains { file in forbidden.contains { file.text.contains($0) } },
          "Tiles shell contains no private Space API or off-screen staging")
}

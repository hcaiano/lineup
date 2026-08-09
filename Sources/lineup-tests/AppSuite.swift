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

        check(!cfg.general.showMenuBarIcon, "split: showMenuBarIcon becomes an app-wide general setting")
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

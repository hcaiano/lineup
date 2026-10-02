import AppCore
import Foundation
import KeyboardRemapCore

func runKeyboardRemapPersistenceTests() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("lineup-remap-persistence-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("config.json")
    let store = LineupAppConfigStore(url: url)
    _ = store.load()

    try store.setEnabled(true, for: .hyperkey)
    try store.setSettings(["futureSibling": "keep"], for: ToolID(rawValue: "futureTool"))
    let sibling = store.config.section(for: ToolID(rawValue: "futureTool"))
    let settings = try JSONDecoder().decode(KeyboardRemapSettings.self, from: Data("""
    {
      "version": 1,
      "futureSetting": {"value": "keep settings"},
      "rules": [{
        "id": "internal",
        "selector": {"builtIn": {"futureSelector": "keep selector"}},
        "futureRule": "keep rule",
        "mappings": [{
          "id": "iso-to-grave",
          "source": 30064771172,
          "destination": 30064771125,
          "futurePair": "keep pair"
        }]
      }]
    }
    """.utf8))
    try store.setSettings(settings, for: .keyboardRemap)
    try store.setEnabled(true, for: .keyboardRemap)

    let reloaded = LineupAppConfigStore(url: url)
    _ = reloaded.load()
    var edited = try reloaded.config.settings(KeyboardRemapSettings.self, for: .keyboardRemap)!
    edited.rules[0].mappings[0].destination = PhysicalKey.f18.hidUsage
    try reloaded.setSettings(edited, for: .keyboardRemap)
    let saved = reloaded.config.section(for: .keyboardRemap)!.settings
    let rule = saved["rules"]!.arrayValueForRemapTests![0]
    let pair = rule["mappings"]!.arrayValueForRemapTests![0]
    check(saved["futureSetting"]?["value"] == .string("keep settings")
          && rule["futureRule"] == .string("keep rule")
          && rule["selector"]?["builtIn"]?["futureSelector"] == .string("keep selector")
          && pair["futurePair"] == .string("keep pair"),
          "editing a persisted remap preserves unknown settings, rule, selector and pair fields")
    check(pair["destination"] == .int(Int64(PhysicalKey.f18.hidUsage))
          && reloaded.config.isEnabled(.keyboardRemap) == true
          && reloaded.config.isEnabled(.hyperkey) == true
          && reloaded.config.section(for: ToolID(rawValue: "futureTool")) == sibling,
          "saving remap edits persists the new physical destination and preserves all tool flags and siblings")

    for rejected in [
        #"{"version":2,"rules":[]}"#,
        #"{"version":1,"rules":[{"id":"r","selector":{"builtIn":{}},"mappings":[{"id":"p","source":"invalid","destination":30064771125}]}]}"#,
        #"{"version":1,"rules":[{"id":"r","selector":{"builtIn":{}},"mappings":[{"id":"a","source":30064771172,"destination":30064771125},{"id":"b","source":30064771172,"destination":30064771181}]}]}"#,
    ] {
        var envelope = reloaded.config
        let raw = try JSONDecoder().decode(JSONValue.self, from: Data(rejected.utf8))
        envelope.tools[ToolID.keyboardRemap.rawValue] = ToolSection(enabled: true, settings: raw)
        try envelope.encoded().write(to: url, options: .atomic)
        let rejectedStore = LineupAppConfigStore(url: url)
        _ = rejectedStore.load()
        var didReject = false
        do { _ = try rejectedStore.config.settings(KeyboardRemapSettings.self, for: .keyboardRemap) }
        catch { didReject = true }
        try rejectedStore.setEnabled(false, for: .hyperkey)
        check(didReject && rejectedStore.config.section(for: .keyboardRemap)?.settings == raw,
              "future, malformed and contradictory remap sections stay recoverable during a sibling edit")
    }
}

private extension JSONValue {
    var arrayValueForRemapTests: [JSONValue]? {
        if case .array(let values) = self { return values }
        return nil
    }
}

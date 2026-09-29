import AppCore
import Foundation

func runMenuBarTests() throws {
    try runMenuBarPreferenceTests()
    let previous = ["music", "clock", "stats", "target"]
    check(!MenuBarOrder.verifiesMove("music", before: "target", previous: previous, observed: previous),
          "a missed rightward drag is rejected even when the source remains left of the target")
    check(MenuBarOrder.verifiesMove("music", before: "target", previous: previous,
            observed: ["clock", "stats", "music", "target"]), "the requested rightward permutation is accepted")
    check(MenuBarOrder.verifiesMove("target", before: "clock", previous: previous,
            observed: ["music", "target", "clock", "stats"]), "the requested leftward permutation is accepted")
    check(!MenuBarOrder.verifiesMove("target", before: "clock", previous: previous,
            observed: ["target", "music", "clock", "stats"]), "a move to the wrong slot is rejected")
    check(!MenuBarOrder.verifiesMove("target", before: "clock", previous: previous,
            observed: ["target", "clock", "stats"]), "an app disappearing during a drag requires a new observation")
    var settings = MenuBarSettings()
    settings.setHidden(true, owner: "stats")
    settings.setHidden(true, owner: "music")
    settings.setHidden(false, owner: "stats")
    settings.preferencesBookmark = Data("opaque file authorization".utf8)
    settings.extra["futureOption"] = .object(["enabled": .bool(true)])
    let encoded = try JSONEncoder().encode(settings)
    let restored = try JSONDecoder().decode(MenuBarSettings.self, from: encoded)
    check(restored.hiddenOwners == ["music"] && restored.extra == settings.extra && restored.preferencesBookmark == settings.preferencesBookmark,
          "Menu Bar edits preserve other groups and unknown options on disk")
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("lineup-menubar-\(UUID())")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("config.json")
    let store = LineupAppConfigStore(url: url)
    _ = store.load()
    try store.setSettings(["preserve": true], for: .zones)
    try store.setEnabled(true, for: .menuBar)
    try store.setSettings(settings, for: .menuBar)
    let loaded = LineupAppConfigStore(url: url)
    _ = loaded.load()
    check(try loaded.config.settings(MenuBarSettings.self, for: .menuBar) == settings,
          "Menu Bar groups, bookmark and unknown fields survive the actual shared store")
    check(loaded.config.isEnabled(.menuBar) == true
            && loaded.config.section(for: .zones)?.settings["preserve"] == .bool(true),
          "Menu Bar edits retain enablement and sibling tool settings")
    for rejectedData in [Data("broken".utf8), Data(#"{"schemaVersion":999}"#.utf8)] {
        try rejectedData.write(to: url)
        _ = loaded.load()
        var refused = false
        do { try loaded.setSettings(settings, for: .menuBar) } catch { refused = true }
        let preserved = try Data(contentsOf: url)
        check(refused && preserved == rejectedData,
              "Menu Bar edits cannot overwrite rejected shared configuration bytes")
    }

    for input in [#"{"version":2}"#, #"{"hiddenOwners":false}"#] {
        do {
            _ = try JSONDecoder().decode(MenuBarSettings.self, from: Data(input.utf8))
            check(false, "unreadable or future Menu Bar settings must block editing")
        } catch {
            check(true, "unreadable or future Menu Bar settings reject decoding")
        }
    }
}

private func runMenuBarPreferenceTests() throws {
    let selectedKey: [String: Any] = ["bundle": ["_0": "example.selected"]]
    let keeperKey: [String: Any] = ["bundle": ["_0": "example.keeper"]]
    let developmentLocation: [String: Any] = ["adhocBinary": ["_0": ["relative": "file:///tmp/Development.app/Contents/MacOS/App"]]]
    let selected: [String: Any] = ["location": selectedKey, "isAllowed": true,
                                  "menuItemLocations": [selectedKey], "futureValue": "retain"]
    let keeper: [String: Any] = ["location": keeperKey, "isAllowed": false,
                                "menuItemLocations": [developmentLocation]]
    let systemKey: [String: Any] = ["bundle": ["_0": "com.apple.system"]]
    let selfKey: [String: Any] = ["bundle": ["_0": "example.lineup"]]
    let original: [Any] = [selectedKey, selected, keeperKey, keeper,
        systemKey, ["location": systemKey, "isAllowed": true],
        selfKey, ["location": selfKey, "isAllowed": true]]
    let data = try PropertyListSerialization.data(fromPropertyList: original, format: .binary, options: 0)
    var document = try MenuBarPreferences(data: data)
    check(document.originalsToHide(selected: ["example.selected", "example.keeper", "com.apple.system", "example.lineup", "missing"],
            excluding: ["example.lineup"]) == ["example.selected": true],
          "hiding excludes system/self, absent apps and apps already disabled by the user")
    try document.setAllowed(["example.selected": false])
    let changed = try PropertyListSerialization.propertyList(from: document.encoded(), format: nil) as! [Any]
    check((changed[3] as! NSDictionary).isEqual(to: keeper),
          "selective hiding preserves another app's visibility and development location")
    let selectedAfter = changed[1] as! [String: Any]
    check(selectedAfter["isAllowed"] as? Bool == false && selectedAfter["futureValue"] as? String == "retain",
          "selective hiding changes the selected flag and preserves unknown record fields")
    check(document.changesToRestore(original: ["example.selected": true, "example.keeper": false,
            "missing": true, "com.apple.system": true]) == ["example.selected": true],
          "recovery only reveals apps this session hid and still present, preserving disabled apps")
    try document.setAllowed(["example.selected": true])
    let restored = try PropertyListSerialization.propertyList(from: document.encoded(), format: nil) as! NSArray
    check(restored.isEqual(to: original), "restoring selected visibility preserves the complete original preference")

    do {
        try document.setAllowed(["example.selected": false, "missing": false])
        check(false, "a disappeared app rejects the whole visibility update")
    } catch {
        check(document.allowed["example.selected"] == true, "a disappeared app cannot cause a partial visibility update")
    }
    let invalid: [[Any]] = [
        [selectedKey],
        [selectedKey, ["location": selectedKey, "isAllowed": "true"]],
        [selectedKey, ["location": keeperKey, "isAllowed": true]],
        [selectedKey, selected, selectedKey, selected]
    ]
    for value in invalid {
        let invalidData = try PropertyListSerialization.data(fromPropertyList: value, format: .binary, options: 0)
        do {
            _ = try MenuBarPreferences(data: invalidData)
            check(false, "ambiguous or changed OS preference formats must block writes")
        } catch { check(true, "unsupported OS preference format rejected") }
    }
}

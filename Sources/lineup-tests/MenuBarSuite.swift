import AppCore
import Foundation

func runMenuBarTests() throws {
    try runMenuBarPreferenceTests()
    // Dragging an observed item must not duplicate it or discard a temporarily
    // absent app. Unknown items can appear while the layout editor is open.
    var settings = MenuBarSettings(itemOrder: ["clock", "missing", "music", "clock"])
    settings.move("music", before: "clock", observed: ["clock", "new", "music"])
    check(settings.orderedIDs(observed: ["clock", "new", "music"]) == ["music", "clock", "new"],
          "Menu Bar drag reorders observed items without duplicates")
    check(settings.orderedIDs(observed: ["clock", "missing", "music", "new"])
            == ["music", "clock", "new", "missing"],
          "Menu Bar drag retains an absent app's saved identity")
    let before = settings
    settings.move("new", before: "gone", observed: ["clock", "new", "music"])
    check(settings == before, "a stale drop target cannot reorder unrelated items")

    settings.setHidden(true, owner: "stats")
    settings.setHidden(true, owner: "music")
    settings.setHidden(false, owner: "stats")
    settings.extra["futureOption"] = .object(["enabled": .bool(true)])
    let encoded = try JSONEncoder().encode(settings)
    let restored = try JSONDecoder().decode(MenuBarSettings.self, from: encoded)
    check(restored.hiddenOwners == ["music"] && restored.extra == settings.extra,
          "Menu Bar edits preserve other groups and unknown options on disk")
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
    let original: [Any] = [selectedKey, selected, keeperKey, keeper]
    let data = try PropertyListSerialization.data(fromPropertyList: original, format: .binary, options: 0)
    var document = try MenuBarPreferences(data: data)
    try document.setAllowed(["example.selected": false])
    let changed = try PropertyListSerialization.propertyList(from: document.encoded(), format: nil) as! [Any]
    check((changed[3] as! NSDictionary).isEqual(to: keeper),
          "selective hiding preserves another app's visibility and development location")
    let selectedAfter = changed[1] as! [String: Any]
    check(selectedAfter["isAllowed"] as? Bool == false && selectedAfter["futureValue"] as? String == "retain",
          "selective hiding changes the selected flag and preserves unknown record fields")
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

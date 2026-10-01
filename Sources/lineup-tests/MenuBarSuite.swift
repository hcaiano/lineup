import AppCore
import Foundation

func runMenuBarTests() throws {
    try runMenuBarPreferenceTests()
    runMenuBarLayoutTests()
    runMenuBarAutoHideTests()
    var settings = MenuBarSettings(hiddenOwners: ["music"])
    settings.preferencesBookmark = Data("opaque file authorization".utf8)
    settings.extra["futureOption"] = .object(["enabled": .bool(true)])
    let encoded = try JSONEncoder().encode(settings)
    let restored = try JSONDecoder().decode(MenuBarSettings.self, from: encoded)
    check(restored.hiddenOwners == ["music"] && restored.extra == settings.extra && restored.preferencesBookmark == settings.preferencesBookmark,
          "the remembered hidden group, legacy bookmark and unknown options survive encoding")
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

private func runMenuBarLayoutTests() {
    let display = CGRect(x: 0, y: 0, width: 1920, height: 1080)
    let arrow = CGRect(x: 1000, y: 0, width: 24, height: 30)
    func icon(_ owner: String, _ x: CGFloat, y: CGFloat = 3) -> (owner: String, frame: CGRect) {
        (owner, CGRect(x: x, y: y, width: 24, height: 24))
    }
    func hidden(_ items: [(owner: String, frame: CGRect)], previous: Set<String> = [],
                leftToRight: Bool = true, displays: [CGRect]? = nil) -> Set<String> {
        MenuBarLayout.hiddenOwners(items: items, arrow: arrow, displayBounds: displays ?? [display],
                                   leftToRight: leftToRight, previous: previous)
    }
    check(hidden([icon("drive", 900), icon("clock", 1100)]) == ["drive"],
          "icons left of the arrow are hidden and icons to its right stay visible")
    check(hidden([icon("codex", 900), icon("codex", 1100)]).isEmpty,
          "an app with an icon on each side of the arrow stays visible")
    check(hidden([icon("com.apple.controlcenter", 900), icon("com.apple.MenuBarAgent", 800, y: 0),
                  icon("com.apple.campo", 750)], previous: ["com.apple.campo"]).isEmpty,
          "macOS's own controls never join the hidden group by bundle")
    check(hidden([icon("drive", 900), icon("clock", 1100)], leftToRight: false) == ["clock"],
          "right-to-left menu bars hide the icons to the right of the arrow")
    check(hidden([icon("drive", 1100)], previous: ["drive", "stopped"]) == ["stopped"],
          "an app moved right of the arrow leaves the group while an app that is not running keeps its group")
    check(hidden([icon("far", 2100), icon("near", 900)], previous: ["far"],
                 displays: [display, CGRect(x: 1920, y: 0, width: 1600, height: 900)]) == ["far", "near"],
          "icons on another display keep their previous group")
    check(hidden([icon("drive", 900)], previous: ["old"], displays: []) == ["old"],
          "missing display geometry changes no group")
    check(hidden([icon("parked", 7, y: 1050), icon("drive", 900)], previous: ["stopped"])
            == ["drive", "stopped"],
          "AX items parked at the bottom of a display cannot join the hidden group")
    let shiftedDisplay = CGRect(x: -1920, y: -1080, width: 1920, height: 1080)
    let shiftedArrow = arrow.offsetBy(dx: -1920, dy: -1080)
    check(MenuBarLayout.hiddenOwners(items: [("drive", icon("drive", 900).frame.offsetBy(dx: -1920, dy: -1080)),
                                              ("visible", icon("visible", 1100).frame.offsetBy(dx: -1920, dy: -1080))],
                                    arrow: shiftedArrow, displayBounds: [shiftedDisplay], leftToRight: true,
                                    previous: []) == ["drive"],
          "an arrow on a display above and left of the primary display keeps the same groups")

}

private func runMenuBarAutoHideTests() {
    let bars = [CGRect(x: 0, y: 0, width: 1920, height: 30)]
    let outside = CGPoint(x: 900, y: 500)
    func waits(_ window: MenuBarAutoHide.Window, pointer: CGPoint = outside) -> Bool {
        MenuBarAutoHide.shouldWait(pointer: pointer, menuBars: bars, windows: [window], hiddenPIDs: [42])
    }
    let statusItem = MenuBarAutoHide.Window(pid: 42, layer: 25, bounds: CGRect(x: 800, y: 3, width: 24, height: 24))
    check(waits(statusItem, pointer: CGPoint(x: 1500, y: 10)), "auto-hide waits while the pointer is on the menu bar")
    check(!waits(statusItem), "a hidden app's own menu bar item does not postpone auto-hide")
    check(waits(.init(pid: 42, layer: 101, bounds: CGRect(x: 790, y: 30, width: 240, height: 300))),
          "auto-hide waits while a hidden app's menu is open")
    check(waits(.init(pid: 42, layer: 3, bounds: CGRect(x: 700, y: 34, width: 360, height: 420))),
          "auto-hide waits while a hidden app's popover is open")
    check(!waits(.init(pid: 42, layer: 0, bounds: CGRect(x: 700, y: 34, width: 360, height: 420))),
          "an ordinary window from a hidden app does not postpone auto-hide")
    check(!waits(.init(pid: 42, layer: 2000, bounds: CGRect(x: 0, y: 0, width: 1920, height: 1080))),
          "a full-screen overlay from a hidden app does not postpone auto-hide")
    check(!waits(.init(pid: 7, layer: 101, bounds: CGRect(x: 790, y: 30, width: 240, height: 300))),
          "a visible app's menu does not postpone auto-hide")
}

/// Native visibility and recovery change selected flags without altering other records.
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
    let trayURL = "file:///Applications/Synergy.app/Contents/MacOS/synergy-tray"
    let trayKey: [String: Any] = ["adhocBinary": ["_0": ["relative": trayURL]]]
    let trayRecord: [String: Any] = ["location": trayKey, "isAllowed": true,
                                   "menuItemLocations": [trayKey], "futureValue": "retain"]
    let opaqueKey: [String: Any] = ["futureLocation": ["_0": "opaque"]]
    let opaqueRecord: [String: Any] = ["location": opaqueKey, "isAllowed": false]
    let withTray: [Any] = original + [trayKey, trayRecord, opaqueKey, opaqueRecord]
    let trayData = try PropertyListSerialization.data(fromPropertyList: withTray, format: .binary, options: 0)
    do {
        var trayDocument = try MenuBarPreferences(data: trayData)
        let bundle = URL(fileURLWithPath: "/Applications/Synergy.app", isDirectory: true)
        let helper = URL(fileURLWithPath: "/Applications/Synergy.app/Contents/MacOS", isDirectory: true)
        check(trayDocument.originalFlags(for: ["synergy"], bundles: ["synergy": [bundle]]) == [trayURL: true],
              "a selected parent app includes its executable-tracked tray in the recovery transaction")
        check(trayDocument.originalFlags(for: ["synergy"], bundles: ["synergy": [bundle], "visible-helper": [helper]]).isEmpty,
              "an executable owned by a more specific visible helper cannot hide with its parent app")
        check(trayDocument.originalFlags(for: ["synergy"], bundles: ["synergy": [bundle], "visible-copy": [bundle]]).isEmpty,
              "ambiguous executable ownership stays visible when one matching owner is visible")
        let nestedURL = "file:///Applications/Synergy.app/Contents/Helpers/Visible.app/Contents/MacOS/tray"
        let nestedKey: [String: Any] = ["adhocBinary": ["_0": ["relative": nestedURL]]]
        let nestedData = try PropertyListSerialization.data(fromPropertyList:
            [nestedKey, ["location": nestedKey, "isAllowed": true]], format: .binary, options: 0)
        let nestedDocument = try MenuBarPreferences(data: nestedData)
        check(nestedDocument.originalFlags(for: ["synergy"], bundles: ["synergy": [bundle]]).isEmpty,
              "an unresolved nested app stays visible even when it is stopped and only tracked by executable")
        let nestedBundle = URL(fileURLWithPath: "/Applications/Synergy.app/Contents/Helpers/Visible.app", isDirectory: true)
        check(nestedDocument.originalFlags(for: ["helper"], bundles: ["synergy": [bundle], "helper": [nestedBundle]]) == [nestedURL: true],
              "a selected nested app still hides once its own bundle is identified")
        try trayDocument.setAllowed([trayURL: false])
        let edited = try PropertyListSerialization.propertyList(from: trayDocument.encoded(), format: nil) as! [Any]
        check((edited[original.count + 1] as! [String: Any])["isAllowed"] as? Bool == false
                && (edited[original.count + 3] as! NSDictionary).isEqual(to: opaqueRecord),
              "executable-tracked trays hide without changing unrecognized locations")
        try trayDocument.setAllowed(trayDocument.changesToRestore(original: [trayURL: true]))
        let restoredTray = try PropertyListSerialization.propertyList(from: trayDocument.encoded(), format: nil) as! NSArray
        check(restoredTray.isEqual(to: withTray), "tray recovery preserves executable locations and all unrelated records")
    } catch {
        check(false, "executable-tracked trays must be editable and recoverable: \(error)")
    }

    do {
        try document.setAllowed(["example.selected": false, "com.apple.system": false])
        check(false, "system controls must reject the whole native visibility update")
    } catch {
        check(document.allowed["example.selected"] == true && document.allowed["com.apple.system"] == true,
              "a request to hide system controls cannot change any native flag")
    }

    let invalid: [[Any]] = [
        [selectedKey],
        [selectedKey, ["location": selectedKey, "isAllowed": "true"]],
        [selectedKey, ["location": keeperKey, "isAllowed": true]],
        [selectedKey, selected, selectedKey, selected],
        [trayKey, ["location": keeperKey, "isAllowed": true]]
    ]
    for value in invalid {
        let invalidData = try PropertyListSerialization.data(fromPropertyList: value, format: .binary, options: 0)
        do {
            _ = try MenuBarPreferences(data: invalidData)
            check(false, "ambiguous or changed OS preference formats must block writes")
        } catch { check(true, "unsupported OS preference format rejected") }
    }
}

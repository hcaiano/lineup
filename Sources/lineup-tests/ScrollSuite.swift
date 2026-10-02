import AppCore
import Foundation
import ScrollCore

func runScrollTests() throws {
    // Classification uses the HID service that sent the event.
    let builtInTrackpad = ScrollDeviceDescriptor(
        classes: [ScrollDeviceDescriptor.trackpadDriver],
        usages: [.init(page: 1, usage: 2), .init(page: 1, usage: 1), .init(page: 13, usage: 5)],
        vendorID: 0, productID: 0)
    let magicMouse = ScrollDeviceDescriptor(
        classes: [ScrollDeviceDescriptor.magicMouseDriver],
        usages: [.init(page: 1, usage: 2), .init(page: 13, usage: 5)], vendorID: 0x004C, productID: 0x0269)
    check(builtInTrackpad.device == .trackpad,
          "a trackpad that also reports a mouse usage is classified as a trackpad")
    check(magicMouse.device == .mouse, "Magic Mouse is a mouse even though its surface reports touch usages")
    check(ScrollDeviceDescriptor(vendorID: 0x004C, productID: 0x030D).device == .mouse
            && ScrollDeviceDescriptor(vendorID: 0x05AC, productID: 0x0265).device == .trackpad,
          "Magic devices are recognized by product ID if their driver class is renamed")
    check(ScrollDeviceDescriptor(usages: [.init(page: 1, usage: 2)], vendorID: 0x046D, productID: 0xC52B).device == .mouse
            && ScrollDeviceDescriptor(usages: [.init(page: 1, usage: 1)]).device == .mouse,
          "a wheel mouse or generic pointer is a mouse")
    check(ScrollDeviceDescriptor(usages: [.init(page: 1, usage: 6), .init(page: 12, usage: 1)]).device == nil
            && ScrollDeviceDescriptor(vendorID: 0x004C, productID: 0x1234).device == nil,
          "a service that is neither a mouse nor a trackpad cannot be classified")

    // Settings select the axes for each device.
    let defaults = ScrollSettings()
    check(defaults.reversal == ScrollReversal(mouse: [.vertical], trackpad: []),
          "defaults reverse the mouse wheel and keep the trackpad and horizontal navigation unchanged")
    var custom = ScrollSettings()
    custom.reverseHorizontal = true
    check(custom.reversal == ScrollReversal(mouse: [.vertical, .horizontal], trackpad: []),
          "horizontal reversal applies to each reversed device")
    custom.reverseMouse = false
    custom.reverseTrackpad = true
    custom.reverseHorizontal = false
    check(custom.reversal == ScrollReversal(mouse: [], trackpad: [.vertical]),
          "the inverse combination reverses only the trackpad's selected direction")
    custom.reverseVertical = false
    check(custom.reversal.isEmpty, "no selected direction means nothing is reversed")

    // The filter decides per event and keeps a gesture's inertia on the device that began it.
    let both = ScrollReversal(mouse: [.vertical, .horizontal], trackpad: [.vertical])
    let began = ScrollPhase(scroll: 1), changed = ScrollPhase(scroll: 2), ended = ScrollPhase(scroll: 4)
    let momentum = ScrollPhase(momentum: 2), momentumEnd = ScrollPhase(momentum: 3)
    let mouse = ScrollSource.device(.mouse), trackpad = ScrollSource.device(.trackpad)
    var filter = ScrollFilter()
    check(filter.axes(source: .unresolved, phase: ScrollPhase(), reversal: both).isEmpty
            && filter.axes(source: .device(nil), phase: ScrollPhase(), reversal: both).isEmpty,
          "an unidentified wheel event keeps the system direction")
    check(filter.axes(source: mouse, phase: ScrollPhase(), reversal: both) == [.vertical, .horizontal]
            && filter.axes(source: trackpad, phase: began, reversal: both) == [.vertical],
          "mouse and trackpad events use their own settings")
    check(filter.axes(source: mouse, phase: ScrollPhase(), reversal: both) == [.vertical, .horizontal]
            && filter.axes(source: .unresolved, phase: changed, reversal: both) == [.vertical],
          "a mouse wheel between trackpad events does not change the trackpad gesture")
    check(filter.axes(source: .software, phase: changed, reversal: both).isEmpty
            && filter.axes(source: .software, phase: momentum, reversal: both).isEmpty
            && filter.axes(source: .device(nil), phase: changed, reversal: both).isEmpty
            && filter.axes(source: .unresolved, phase: changed, reversal: both) == [.vertical],
          "app-posted and other-device events during a gesture are unchanged and leave the gesture intact")
    check(filter.axes(source: trackpad, phase: ended, reversal: both) == [.vertical]
            && filter.axes(source: .unresolved, phase: momentum, reversal: both) == [.vertical]
            && filter.axes(source: .unresolved, phase: momentumEnd, reversal: both) == [.vertical],
          "inertia with an unresolved sender keeps the gesture's direction")
    check(filter.axes(source: .unresolved, phase: momentum, reversal: both).isEmpty,
          "the gesture's device is forgotten when its inertia ends")
    _ = filter.axes(source: trackpad, phase: began, reversal: both)
    check(filter.axes(source: .unresolved, phase: began, reversal: both).isEmpty
            && filter.axes(source: .unresolved, phase: changed, reversal: both).isEmpty,
          "a gesture that begins without a recognizable sender is left unchanged")
    _ = filter.axes(source: trackpad, phase: began, reversal: both)
    check(filter.axes(source: .unresolved, phase: changed, reversal: ScrollReversal()).isEmpty
            && filter.axes(source: .unresolved, phase: changed, reversal: both) == [.vertical],
          "a settings change applies to the next event")
    check(filter.axes(source: .unresolved, phase: ScrollPhase(scroll: 8), reversal: both) == [.vertical]
            && filter.axes(source: .unresolved, phase: momentum, reversal: both).isEmpty,
          "a cancelled gesture also ends the remembered device")

    // Reversal changes only the sign of the selected axis.
    let deltas = ScrollDeltas(line: (y: 3, x: -1), point: (y: 30.5, x: -10), fixed: (y: 3.25, x: -1),
                              hid: (y: 12, x: -4))
    let vertical = deltas.reversed(.vertical)
    check(vertical == ScrollDeltas(line: (y: -3, x: -1), point: (y: -30.5, x: -10), fixed: (y: -3.25, x: -1),
                                   hid: (y: -12, x: -4)),
          "vertical reversal negates every vertical delta, preserves magnitude, and leaves horizontal alone")
    check(deltas.reversed(.horizontal).line == (y: 3, x: 1) && deltas.reversed(.horizontal).hid?.y == 12,
          "horizontal reversal leaves vertical scrolling alone")
    check(deltas.reversed([]) == deltas && vertical.reversed(.vertical) == deltas,
          "an unselected event is unchanged and reversal is never applied twice by the same rule")
    let noHID = ScrollDeltas(line: (y: 1, x: 0), point: (y: 10, x: 0), fixed: (y: 1, x: 0))
    check(noHID.reversed(.vertical).hid == nil, "an event without HID data gains none")

    // Persistence uses the shared store and preserves unknown fields.
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("lineup-scroll-\(UUID())")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("config.json")
    let store = LineupAppConfigStore(url: url)
    _ = store.load()
    try store.setEnabled(true, for: .scroll)
    var saved = try JSONDecoder().decode(ScrollSettings.self,
        from: Data(#"{"reverseTrackpad":true,"futureOption":"preserve"}"#.utf8))
    check(saved.reverseMouse && saved.reverseTrackpad && saved.reverseVertical && !saved.reverseHorizontal,
          "missing Scroll fields use their defaults")
    saved.reverseHorizontal = true
    try store.setSettings(saved, for: .scroll)
    let reloaded = LineupAppConfigStore(url: url)
    _ = reloaded.load()
    check(try reloaded.config.settings(ScrollSettings.self, for: .scroll) == saved
            && reloaded.config.isEnabled(.scroll) == true
            && reloaded.config.section(for: .scroll)?.settings["futureOption"] == .string("preserve"),
          "Scroll settings survive a reload with enablement and unknown fields intact")
    var rejected = false
    do { _ = try JSONDecoder().decode(ScrollSettings.self, from: Data(#"{"reverseMouse":"yes"}"#.utf8)) }
    catch { rejected = true }
    check(rejected, "malformed Scroll settings are rejected instead of replaced by defaults")
}

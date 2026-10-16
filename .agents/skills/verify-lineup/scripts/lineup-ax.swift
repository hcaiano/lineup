// lineup-ax: Accessibility driver that runs inside the verification VM.
// It finds elements by role and accessible name, then acts like a user: real clicks,
// key presses and drags posted into the VM's own session. `verify-lineup` copies it into
// the guest. On the host it posts input only under a host-desktop claim
// (`verify-lineup host-ax`) and stops at the first sign of human input.
import AppKit
import ApplicationServices
import IOKit

let usage = """
usage: lineup-ax <command> [selector...] [options]

commands:
  trusted                       print whether this process may use Accessibility
  tree [--depth N]              print the target app's elements
  find SELECTOR...              print matching elements
  click SELECTOR... [--right] [--press] [--index N]
  raise SELECTOR...             bring the matching element's window and app to the front
  wait SELECTOR... [--gone] [--timeout S]
  read SELECTOR... [--attr NAME]
  key COMBO                     e.g. escape, cmd+comma, ctrl+tab, cmd+1, hyper+z
  type TEXT
  drag --from X,Y --to X,Y [--mods shift] [--steps N]
  move X,Y

selectors (all must match; `~` means substring, case-insensitive):
  role=AXButton  subrole=AXCloseButton  title=Settings  desc~clock  id=x  value=On
  name=TEXT      matches title, description or identifier

options:
  --app BUNDLE_ID   target app (default com.caiano.lineup); `--app system` for every app
  --scope menubar|windows|all   (default all)
  --json            print matches as JSON lines
"""

struct Failure: Error { let message: String }

func fail(_ message: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
    // Any failure on the host still reports human input seen during the command, so
    // `host-ax` releases the claim.
    if code != 7 { finishHostInput() }
    exit(code)
}

// MARK: - Arguments

struct Matcher {
    let key: String
    let expected: String
    let substring: Bool

    func matches(_ node: Node) -> Bool {
        let candidates: [String?]
        switch key {
        case "role": candidates = [node.role]
        case "subrole": candidates = [node.subrole]
        case "title": candidates = [node.title]
        case "desc": candidates = [node.desc]
        case "id": candidates = [node.identifier]
        case "value": candidates = [node.value]
        case "name": candidates = [node.title, node.desc, node.identifier]
        default: fail("unknown selector key: \(key)", code: 2)
        }
        return candidates.contains { candidate in
            guard let candidate else { return false }
            return substring
                ? candidate.localizedCaseInsensitiveContains(expected)
                : candidate == expected
        }
    }
}

struct Options {
    var command = ""
    var matchers: [Matcher] = []
    var positional: [String] = []
    var app = "com.caiano.lineup"
    var scope = "all"
    var json = false
    var depth = 40
    var index: Int?
    var right = false
    var press = false
    var gone = false
    var timeout: Double = 10
    var attr = "AXValue"
    var from: CGPoint?
    var to: CGPoint?
    var mods: CGEventFlags = []
    var steps = 30
}

func parsePoint(_ text: String) -> CGPoint {
    let parts = text.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
    guard parts.count == 2 else { fail("expected X,Y but got \(text)", code: 2) }
    return CGPoint(x: parts[0], y: parts[1])
}

func parseOptions() -> Options {
    var options = Options()
    var args = Array(CommandLine.arguments.dropFirst())
    guard !args.isEmpty, args[0] != "-h", args[0] != "--help", args[0] != "help" else {
        print(usage)
        exit(args.isEmpty ? 2 : 0)
    }
    options.command = args.removeFirst()
    func value(_ flag: String) -> String {
        guard !args.isEmpty else { fail("\(flag) needs a value", code: 2) }
        return args.removeFirst()
    }
    while !args.isEmpty {
        let arg = args.removeFirst()
        switch arg {
        case "--app": options.app = value(arg)
        case "--scope": options.scope = value(arg)
        case "--json": options.json = true
        case "--depth": options.depth = Int(value(arg)) ?? options.depth
        case "--index": options.index = Int(value(arg))
        case "--right": options.right = true
        case "--press": options.press = true
        case "--gone": options.gone = true
        case "--timeout": options.timeout = Double(value(arg)) ?? options.timeout
        case "--attr": options.attr = value(arg)
        case "--from": options.from = parsePoint(value(arg))
        case "--to": options.to = parsePoint(value(arg))
        case "--mods": options.mods = modifierFlags(value(arg).split(separator: "+").map(String.init))
        case "--steps": options.steps = max(1, Int(value(arg)) ?? options.steps)
        default:
            // Split at the first `~` or `=`, so a value may contain either character.
            if let split = arg.firstIndex(where: { $0 == "~" || $0 == "=" }),
               ["role", "subrole", "title", "desc", "id", "value", "name"].contains(String(arg[..<split])) {
                let key = String(arg[..<split])
                let substring = arg[split] == "~"
                var valueStart = arg.index(after: split)
                if substring, valueStart < arg.endIndex, arg[valueStart] == "=" { valueStart = arg.index(after: valueStart) }
                options.matchers.append(Matcher(key: key, expected: String(arg[valueStart...]), substring: substring))
            } else {
                options.positional.append(arg)
            }
        }
    }
    return options
}

// MARK: - Accessibility tree

struct Node {
    let element: AXUIElement
    let path: String
    let depth: Int
    let role: String?
    let subrole: String?
    let title: String?
    let desc: String?
    let identifier: String?
    let value: String?
    let enabled: Bool?
    let frame: CGRect?
    let pid: pid_t

    var center: CGPoint? { frame.map { CGPoint(x: $0.midX, y: $0.midY) } }

    var line: String {
        var parts = ["\(role ?? "?")" + (subrole.map { "(\($0))" } ?? "")]
        if let title, !title.isEmpty { parts.append("title=\"\(title)\"") }
        if let desc, !desc.isEmpty { parts.append("desc=\"\(desc)\"") }
        if let identifier, !identifier.isEmpty { parts.append("id=\"\(identifier)\"") }
        if let value, !value.isEmpty { parts.append("value=\"\(value.prefix(80))\"") }
        if enabled == false { parts.append("disabled") }
        if let frame { parts.append("frame=\(Int(frame.minX)),\(Int(frame.minY)),\(Int(frame.width)),\(Int(frame.height))") }
        return parts.joined(separator: " ")
    }

    var json: String {
        var object: [String: Any] = ["path": path, "pid": pid]
        if let role { object["role"] = role }
        if let subrole { object["subrole"] = subrole }
        if let title { object["title"] = title }
        if let desc { object["desc"] = desc }
        if let identifier { object["id"] = identifier }
        if let value { object["value"] = value }
        if let enabled { object["enabled"] = enabled }
        if let frame { object["frame"] = [frame.minX, frame.minY, frame.width, frame.height] }
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(data: data, encoding: .utf8)!
    }
}

func attribute(_ element: AXUIElement, _ name: String) -> AnyObject? {
    var value: AnyObject?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
    return value
}

func stringValue(_ object: AnyObject?) -> String? {
    switch object {
    case let string as String: return string
    case let number as NSNumber: return number.stringValue
    case let url as URL: return url.absoluteString
    default: return nil
    }
}

func frame(_ element: AXUIElement) -> CGRect? {
    guard let positionValue = attribute(element, kAXPositionAttribute),
          let sizeValue = attribute(element, kAXSizeAttribute) else { return nil }
    var position = CGPoint.zero
    var size = CGSize.zero
    guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &position),
          AXValueGetValue(sizeValue as! AXValue, .cgSize, &size) else { return nil }
    return CGRect(origin: position, size: size)
}

func makeNode(_ element: AXUIElement, path: String, depth: Int) -> Node {
    var pid: pid_t = 0
    AXUIElementGetPid(element, &pid)
    return Node(
        element: element,
        path: path,
        depth: depth,
        role: attribute(element, kAXRoleAttribute) as? String,
        subrole: attribute(element, kAXSubroleAttribute) as? String,
        title: attribute(element, kAXTitleAttribute) as? String,
        desc: attribute(element, kAXDescriptionAttribute) as? String,
        identifier: attribute(element, kAXIdentifierAttribute) as? String,
        value: stringValue(attribute(element, kAXValueAttribute)),
        enabled: (attribute(element, kAXEnabledAttribute) as? NSNumber)?.boolValue,
        frame: frame(element),
        pid: pid
    )
}

func children(_ element: AXUIElement) -> [AXUIElement] {
    (attribute(element, kAXChildrenAttribute) as? [AXUIElement]) ?? []
}

func walk(_ element: AXUIElement, path: String, depth: Int, maxDepth: Int, into nodes: inout [Node]) {
    let node = makeNode(element, path: path, depth: depth)
    nodes.append(node)
    guard depth < maxDepth else { return }
    for (index, child) in children(element).enumerated() {
        walk(child, path: "\(path)/\(index)", depth: depth + 1, maxDepth: maxDepth, into: &nodes)
    }
}

func roots(_ options: Options) -> [(String, AXUIElement)] {
    let apps: [NSRunningApplication]
    if options.app == "system" {
        apps = NSWorkspace.shared.runningApplications
    } else {
        apps = NSRunningApplication.runningApplications(withBundleIdentifier: options.app).filter { !$0.isTerminated }
        guard !apps.isEmpty else { fail("not running: \(options.app)", code: 3) }
    }
    var result: [(String, AXUIElement)] = []
    for app in apps {
        let element = AXUIElementCreateApplication(app.processIdentifier)
        let label = app.bundleIdentifier ?? "\(app.processIdentifier)"
        if options.scope != "windows", let extras = attribute(element, "AXExtrasMenuBar") {
            result.append(("\(label):menubar", extras as! AXUIElement))
        }
        if options.scope != "menubar" {
            for (index, window) in ((attribute(element, kAXWindowsAttribute) as? [AXUIElement]) ?? []).enumerated() {
                result.append(("\(label):window\(index)", window))
            }
        }
    }
    return result
}

func snapshot(_ options: Options) -> [Node] {
    var nodes: [Node] = []
    for (label, root) in roots(options) {
        walk(root, path: label, depth: 0, maxDepth: options.depth, into: &nodes)
    }
    return nodes
}

func matches(_ options: Options) -> [Node] {
    let found = snapshot(options).filter { node in options.matchers.allSatisfy { $0.matches(node) } }
    if let index = options.index {
        return found.indices.contains(index) ? [found[index]] : []
    }
    return found
}

func requireSelector(_ options: Options) {
    if options.matchers.isEmpty { fail("this command needs a selector such as role=AXButton name=Settings", code: 2) }
}

func single(_ options: Options) -> Node {
    requireSelector(options)
    let deadline = Date().addingTimeInterval(options.timeout)
    while true {
        let found = matches(options)
        if found.count == 1 { return found[0] }
        if found.count > 1 {
            fail("ambiguous selector, \(found.count) matches (add --index N or a narrower selector):\n"
                + found.enumerated().map { "  [\($0.offset)] \($0.element.line)" }.joined(separator: "\n"))
        }
        if Date() > deadline { fail("no element matches \(CommandLine.arguments.dropFirst().joined(separator: " "))", code: 4) }
        Thread.sleep(forTimeInterval: 0.2)
    }
}

// MARK: - Input inside the VM session

let keyCodes: [String: CGKeyCode] = [
    "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12,
    "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23,
    "equal": 24, "9": 25, "7": 26, "minus": 27, "8": 28, "0": 29, "]": 30, "o": 31, "u": 32, "[": 33,
    "i": 34, "p": 35, "return": 36, "enter": 36, "l": 37, "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42,
    "comma": 43, ",": 43, "/": 44, "n": 45, "m": 46, "period": 47, ".": 47, "tab": 48, "space": 49,
    "`": 50, "grave": 50, "delete": 51, "backspace": 51, "escape": 53, "esc": 53, "capslock": 57,
    "f17": 64, "f18": 79, "f19": 80, "f20": 90, "f5": 96, "f6": 97, "f7": 98, "f3": 99, "f8": 100,
    "f9": 101, "f11": 103, "f13": 105, "f16": 106, "f14": 107, "f10": 109, "f12": 111, "f15": 113,
    "home": 115, "pageup": 116, "forwarddelete": 117, "f4": 118, "end": 119, "f2": 120,
    "pagedown": 121, "f1": 122, "left": 123, "right": 124, "down": 125, "up": 126, "section": 10,
]

func modifierFlags(_ names: [String]) -> CGEventFlags {
    var flags: CGEventFlags = []
    for name in names {
        switch name.lowercased() {
        case "cmd", "command": flags.insert(.maskCommand)
        case "shift": flags.insert(.maskShift)
        case "opt", "option", "alt": flags.insert(.maskAlternate)
        case "ctrl", "control": flags.insert(.maskControl)
        case "fn": flags.insert(.maskSecondaryFn)
        case "hyper": flags.formUnion([.maskCommand, .maskShift, .maskAlternate, .maskControl])
        default: fail("unknown modifier: \(name)", code: 2)
        }
    }
    return flags
}

// Input goes to a virtual machine's session. On the host it needs the claim stamp that
// `verify-lineup host-ax` passes, and any human input since our last action ends the run.
let insideVirtualMachine: Bool = {
    var value: Int32 = 0
    var size = MemoryLayout<Int32>.size
    return sysctlbyname("kern.hv_vmm_present", &value, &size, nil, 0) == 0 && value == 1
}()
let hostStamp = ProcessInfo.processInfo.environment["LINEUP_AX_HOST_STAMP"]
var lastOwnInput: Date?

func secondsSinceLastHIDEvent() -> Double? {
    let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOHIDSystem"))
    guard service != 0 else { return nil }
    defer { IOObjectRelease(service) }
    let property = IORegistryEntryCreateCFProperty(service, "HIDIdleTime" as CFString, kCFAllocatorDefault, 0)
    guard let nanoseconds = property?.takeRetainedValue() as? NSNumber else { return nil }
    return nanoseconds.doubleValue / 1_000_000_000
}

// Synthetic events reset the idle time like real ones, so the idle time alone cannot tell them
// apart. On the host every event we post carries this marker, and a listen-only tap latches any
// other event while a command runs. The idle time covers the gaps between commands.
let ownEventMarker: Int64 = 0x4C4E_5550
let foreignInputLock = NSLock()
var foreignInputSeen = false
var hostTapCreated = false

func watchHostInput() {
    guard CGPreflightListenEventAccess() || AXIsProcessTrusted() else {
        fail("cannot watch the host for human input; give this terminal Input Monitoring in System Settings", code: 6)
    }
    let ready = DispatchSemaphore(value: 0)
    Thread {
        let tap = CGEvent.tapCreate(tap: .cghidEventTap, place: .headInsertEventTap, options: .listenOnly,
                                    eventsOfInterest: CGEventMask.max, callback: { _, type, event, _ in
            // A disabled tap (timeout or secure input) no longer sees the human, so it counts as human
            // input. Null events carry no input, and posting can emit some from our own process.
            let ours = event.getIntegerValueField(.eventSourceUserData) == ownEventMarker
                || event.getIntegerValueField(.eventSourceUnixProcessID) == Int64(getpid())
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput || (type != .null && !ours) {
                foreignInputLock.lock()
                foreignInputSeen = true
                foreignInputLock.unlock()
            }
            return Unmanaged.passUnretained(event)
        }, userInfo: nil)
        if let tap {
            CFRunLoopAddSource(CFRunLoopGetCurrent(), CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            hostTapCreated = true
        }
        ready.signal()
        if hostTapCreated { CFRunLoopRun() }
    }.start()
    ready.wait()
    guard hostTapCreated else {
        fail("cannot watch the host for human input; give this terminal Input Monitoring in System Settings", code: 6)
    }
}

func stopForHumanInput() -> Never {
    releaseHeldInput()
    fail("human input detected since the last verification input; release the host desktop", code: 7)
}

// Runs before every event and every Accessibility action on the host.
func checkInputOwnership() {
    if insideVirtualMachine { return }
    guard let hostStamp else { fail("refusing to post input outside the verification VM without a host-desktop claim", code: 6) }
    if !hostTapCreated { watchHostInput() }
    if lastOwnInput == nil {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: hostStamp),
              let stamp = attributes[.modificationDate] as? Date else {
            fail("refusing to post input outside the verification VM without a host-desktop claim", code: 6)
        }
        lastOwnInput = stamp
    }
    foreignInputLock.lock()
    let seen = foreignInputSeen
    foreignInputLock.unlock()
    guard let idle = secondsSinceLastHIDEvent() else { fail("cannot read the input idle time", code: 6) }
    // Our own events reset the idle time just before we stamp them, so an idle time shorter
    // than the time since our stamp means someone else touched the keyboard, mouse or trackpad.
    if seen || idle + 0.02 < Date().timeIntervalSince(lastOwnInput!) { stopForHumanInput() }
}

// Keep watching briefly after a host command, so its tap overlaps the next command's idle check.
func finishHostInput() {
    guard hostTapCreated else { return }
    usleep(100_000)
    foreignInputLock.lock()
    let seen = foreignInputSeen
    foreignInputLock.unlock()
    if seen { stopForHumanInput() }
}

func markOwnInput() {
    lastOwnInput = Date()
    if let hostStamp { try? FileManager.default.setAttributes([.modificationDate: lastOwnInput!], ofItemAtPath: hostStamp) }
}

// Everything we pressed and have not released yet, so a stop never leaves a key or button down.
var heldKeys: Set<CGKeyCode> = []
var heldButtons: Set<UInt32> = []
var heldModifiers: CGEventFlags = []

func track(_ event: CGEvent) {
    let code = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
    switch event.type {
    case .keyDown: heldKeys.insert(code)
    case .keyUp: heldKeys.remove(code)
    case .flagsChanged: heldModifiers = event.flags.intersection([.maskCommand, .maskShift, .maskAlternate, .maskControl, .maskSecondaryFn])
    case .leftMouseDown: heldButtons.insert(CGMouseButton.left.rawValue)
    case .leftMouseUp: heldButtons.remove(CGMouseButton.left.rawValue)
    case .rightMouseDown: heldButtons.insert(CGMouseButton.right.rawValue)
    case .rightMouseUp: heldButtons.remove(CGMouseButton.right.rawValue)
    default: break
    }
}

func releaseHeldInput() {
    func send(_ event: CGEvent?) {
        event?.setIntegerValueField(.eventSourceUserData, value: ownEventMarker)
        event?.post(tap: .cghidEventTap)
    }
    for code in heldKeys {
        let up = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: false)
        up?.flags = heldModifiers
        send(up)
    }
    let point = CGEvent(source: nil)?.location ?? .zero
    if heldButtons.contains(CGMouseButton.left.rawValue) {
        send(CGEvent(mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left))
    }
    if heldButtons.contains(CGMouseButton.right.rawValue) {
        send(CGEvent(mouseEventSource: source, mouseType: .rightMouseUp, mouseCursorPosition: point, mouseButton: .right))
    }
    for key in modifierKeys.reversed() where heldModifiers.contains(key.flag) {
        heldModifiers.remove(key.flag)
        let event = CGEvent(keyboardEventSource: source, virtualKey: key.code, keyDown: false)
        event?.type = .flagsChanged
        event?.flags = heldModifiers
        send(event)
    }
    heldKeys = []
    heldButtons = []
}

func post(_ event: CGEvent?) {
    checkInputOwnership()
    guard let event else { fail("could not create input event") }
    if !insideVirtualMachine { event.setIntegerValueField(.eventSourceUserData, value: ownEventMarker) }
    event.post(tap: .cghidEventTap)
    track(event)
    markOwnInput()
    usleep(12_000)
}

let source = CGEventSource(stateID: .hidSystemState)

func mouse(_ type: CGEventType, _ point: CGPoint, button: CGMouseButton = .left, flags: CGEventFlags = []) {
    let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: button)
    event?.flags = flags
    post(event)
}

// The app whose element is on top at a screen point, so a click never lands on a covering window.
func ownerPID(at point: CGPoint) -> pid_t? {
    var hit: AXUIElement?
    guard AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(point.x), Float(point.y), &hit) == .success,
          let hit else { return nil }
    var pid: pid_t = 0
    AXUIElementGetPid(hit, &pid)
    return pid
}

func click(at point: CGPoint, right: Bool) {
    mouse(.mouseMoved, point)
    usleep(80_000)
    if right {
        mouse(.rightMouseDown, point, button: .right)
        mouse(.rightMouseUp, point, button: .right)
    } else {
        mouse(.leftMouseDown, point)
        mouse(.leftMouseUp, point)
    }
}

let modifierKeys: [(flag: CGEventFlags, code: CGKeyCode)] = [
    (.maskCommand, 55), (.maskShift, 56), (.maskAlternate, 58), (.maskControl, 59), (.maskSecondaryFn, 63),
]

// Press or release modifier keys one by one, like a keyboard does, so the system's modifier
// state ends where it started. Flags on the main event alone leave Command "held" for the
// next command's typing.
func pressModifiers(_ flags: CGEventFlags, down: Bool) {
    let keys = modifierKeys.filter { flags.contains($0.flag) }
    var current: CGEventFlags = down ? [] : flags
    for key in down ? keys : keys.reversed() {
        if down { current.insert(key.flag) } else { current.remove(key.flag) }
        let event = CGEvent(keyboardEventSource: source, virtualKey: key.code, keyDown: down)
        event?.type = .flagsChanged
        event?.flags = current
        post(event)
    }
}

func pressKey(_ combo: String) {
    let parts = combo.split(separator: "+").map(String.init)
    guard let keyName = parts.last?.lowercased(), let code = keyCodes[keyName] else {
        fail("unknown key in \(combo); known keys: \(keyCodes.keys.sorted().joined(separator: " "))", code: 2)
    }
    let flags = modifierFlags(Array(parts.dropLast()))
    pressModifiers(flags, down: true)
    let down = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: true)
    down?.flags = flags
    post(down)
    let up = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: false)
    up?.flags = flags
    post(up)
    pressModifiers(flags, down: false)
}

func typeText(_ text: String) {
    for scalar in text.utf16 {
        var unit = scalar
        for keyDown in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: keyDown)
            event?.flags = []
            event?.keyboardSetUnicodeString(stringLength: 1, unicodeString: &unit)
            post(event)
        }
        usleep(20_000)
    }
}

func drag(from: CGPoint, to: CGPoint, flags: CGEventFlags, steps: Int) {
    pressModifiers(flags, down: true)
    defer { pressModifiers(flags, down: false) }
    mouse(.mouseMoved, from, flags: flags)
    usleep(100_000)
    mouse(.leftMouseDown, from, flags: flags)
    usleep(150_000)
    for step in 1...steps {
        let t = Double(step) / Double(steps)
        let point = CGPoint(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t)
        mouse(.leftMouseDragged, point, flags: flags)
        usleep(16_000)
    }
    usleep(250_000)
    mouse(.leftMouseUp, to, flags: flags)
}

// MARK: - Commands

let options = parseOptions()

switch options.command {
case "trusted":
    print(AXIsProcessTrusted() ? "trusted" : "not trusted")
    exit(AXIsProcessTrusted() ? 0 : 1)
case "key", "type", "drag", "move":
    break
default:
    guard AXIsProcessTrusted() else { fail("lineup-ax is not trusted for Accessibility in this session", code: 5) }
}

switch options.command {
case "tree":
    for node in snapshot(options) {
        print(options.json ? node.json : String(repeating: "  ", count: node.depth) + node.line)
    }
case "find":
    requireSelector(options)
    let found = matches(options)
    for (index, node) in found.enumerated() {
        print(options.json ? node.json : "[\(index)] \(node.line)  path=\(node.path)")
    }
    exit(found.isEmpty ? 4 : 0)
case "click":
    let node = single(options)
    if options.press {
        checkInputOwnership()
        let result = AXUIElementPerformAction(node.element, kAXPressAction as CFString)
        markOwnInput()
        guard result == .success else { fail("AXPress failed (\(result.rawValue)) on \(node.line)") }
    } else {
        guard let center = node.center else { fail("element has no frame: \(node.line)") }
        if node.path.contains(":window"), let owner = ownerPID(at: center), owner != node.pid {
            let name = NSRunningApplication(processIdentifier: owner)?.localizedName ?? "pid \(owner)"
            fail("\(name) covers \(node.line); bring its window forward with `raise` first", code: 3)
        }
        click(at: center, right: options.right)
    }
    print("clicked \(node.line)")
case "wait":
    requireSelector(options)
    let deadline = Date().addingTimeInterval(options.timeout)
    while true {
        let found = matches(options)
        if options.gone ? found.isEmpty : !found.isEmpty {
            print(options.gone ? "gone" : found.map(\.line).joined(separator: "\n"))
            exit(0)
        }
        if Date() > deadline { fail(options.gone ? "still present after \(options.timeout)s" : "not found after \(options.timeout)s", code: 4) }
        Thread.sleep(forTimeInterval: 0.2)
    }
case "raise":
    let node = single(options)
    let window = node.role == kAXWindowRole ? node.element : (attribute(node.element, kAXWindowAttribute) as! AXUIElement?)
    guard let window else { fail("no window for \(node.line)") }
    checkInputOwnership()
    NSRunningApplication(processIdentifier: node.pid)?.activate()
    AXUIElementPerformAction(window, kAXRaiseAction as CFString)
    markOwnInput()
    print("raised \(node.line)")
case "read":
    let node = single(options)
    print(stringValue(attribute(node.element, options.attr)) ?? "")
case "key":
    guard let combo = options.positional.first else { fail("key needs a combo", code: 2) }
    pressKey(combo)
case "type":
    guard let text = options.positional.first else { fail("type needs text", code: 2) }
    typeText(text)
case "drag":
    guard let from = options.from, let to = options.to else { fail("drag needs --from X,Y and --to X,Y", code: 2) }
    drag(from: from, to: to, flags: options.mods, steps: options.steps)
case "move":
    guard let text = options.positional.first else { fail("move needs X,Y", code: 2) }
    mouse(.mouseMoved, parsePoint(text))
default:
    fail("unknown command: \(options.command)\n\n\(usage)", code: 2)
}
finishHostInput()

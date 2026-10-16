import AppKit
import ApplicationServices
import ScreenCaptureKit
import ZonesCore
import AppCore
@testable import lineup

@MainActor
final class ProbeInput {
    var pointer = CGPoint.zero
    var modifiers: NSEvent.ModifierFlags = .shift
    var keys: Set<CGKeyCode> = []
    var buttons = 0
    var trusted: Bool?
    var realTime = false
    var unreadable: Set<CGEventType> = []
    private var clock: TimeInterval = 1_000
    private var lastEvent: [UInt32: TimeInterval] = [:]
    private var monitors: [UUID: (NSEvent.EventTypeMask, (NSEvent) -> Void)] = [:]
    private var nextTimer = 0
    private(set) var timers: [(id: Int, due: TimeInterval, delay: TimeInterval, action: () -> Void)] = []

    var now: TimeInterval { realTime ? ProcessInfo.processInfo.systemUptime : clock }

    func source() -> DragSnapInput {
        DragSnapInput(
            addGlobalMonitor: { mask, handler in
                let id = UUID()
                self.monitors[id] = (mask, handler)
                return id
            },
            removeMonitor: { if let id = $0 as? UUID { self.monitors[id] = nil } },
            pointer: { self.pointer },
            modifiers: { self.modifiers },
            isKeyDown: { self.keys.contains($0) },
            isTrusted: { self.trusted ?? AXIsProcessTrusted() },
            now: { self.now },
            secondsSince: { self.unreadable.contains($0) ? .nan : self.now - (self.lastEvent[$0.rawValue] ?? -1_000_000) },
            pressedButtons: { self.buttons },
            schedule: { delay, action in
                if self.realTime { return DragSnapInput.system.schedule(delay, action) }
                self.nextTimer += 1
                let id = self.nextTimer
                self.timers.append((id, self.clock + delay, delay, action))
                return { self.timers.removeAll { $0.id == id } }
            })
    }

    var monitorCount: Int { monitors.count }

    func happen(_ type: CGEventType) { lastEvent[type.rawValue] = now }

    func elapse(_ seconds: TimeInterval) {
        clock += seconds
        for _ in 0..<16 {
            guard let next = timers.filter({ $0.due <= clock + 1e-9 }).min(by: { $0.due < $1.due }) else { return }
            timers.removeAll { $0.id == next.id }
            next.action()
        }
    }

    func deliver(_ type: NSEvent.EventType, at point: CGPoint? = nil, keyCode: UInt16 = 0) {
        if let point { pointer = point }
        let event = type == .keyDown
            ? NSEvent.keyEvent(with: .keyDown, location: pointer, modifierFlags: modifiers,
                               timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0, context: nil,
                               characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: keyCode)
            : NSEvent.mouseEvent(with: type, location: pointer, modifierFlags: modifiers,
                                 timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0, context: nil,
                                 eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)
        guard let event else { return }
        for (mask, handler) in Array(monitors.values) where mask.contains(NSEvent.EventTypeMask(type: type)) { handler(event) }
    }
}

@MainActor
final class ProbeOperation {
    private var waiter: CheckedContinuation<Void, Never>?
    private var observer: CheckedContinuation<Void, Never>?
    private var entered = false
    private var released = false

    func hold() async {
        entered = true
        observer?.resume(); observer = nil
        if released { return }
        await withCheckedContinuation { waiter = $0 }
    }

    func waitForEntry() async {
        if entered { return }
        await withCheckedContinuation { observer = $0 }
    }

    func release() { released = true; waiter?.resume(); waiter = nil }
}

@main
struct ZonesNativeProbe {
    struct Completion {
        let status: Int32
        let path: URL
        var receipt: [String: Any]
    }

    @MainActor
    static func main() {
        if CommandLine.arguments.contains("--offscreen") { exit(offscreen()) }
        if let index = CommandLine.arguments.firstIndex(of: "--fixture"), CommandLine.arguments.count > index + 2 {
            fixture(URL(fileURLWithPath: CommandLine.arguments[index + 1]), count: Int(CommandLine.arguments[index + 2]) ?? 1)
            return
        }
        setvbuf(stdout, nil, _IONBF, 0)
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        for name in [NSApplication.didFinishLaunchingNotification, NSApplication.didBecomeActiveNotification,
                     NSApplication.didResignActiveNotification] {
            _ = NotificationCenter.default.addObserver(forName: name, object: app, queue: .main) { notification in
                print("Probe application lifecycle. \(notification.name.rawValue)")
            }
        }
        Task { @MainActor in
            do {
                guard var completion = try await run() else { exit(1) }
                completion.receipt["cleanup"] = true
                try JSONSerialization.data(withJSONObject: completion.receipt, options: [.prettyPrinted, .sortedKeys])
                    .write(to: completion.path, options: .atomic)
                print("TERMINAL: \(completion.receipt["endpoint"]!) invocation \(completion.receipt["invocation"]!) after fixture cleanup")
                exit(completion.status)
            } catch { print("FAIL: \(error)"); exit(1) }
        }
        app.run()
        print("FAIL: probe event loop ended without its terminal endpoint")
        exit(1)
    }

    @MainActor
    static func fixture(_ directory: URL, count: Int) {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        app.finishLaunching()
        NSWindow.allowsAutomaticWindowTabbing = false
        let bounds = NSScreen.screens[0].visibleFrame
        var windows: [NSWindow] = []
        for index in 0..<count {
            let rect = CGRect(x: bounds.minX + 30 + CGFloat(index) * 520, y: bounds.minY + 100, width: 480, height: 360)
            let window = NSWindow(contentRect: rect, styleMask: [.titled, .closable, .resizable],
                                  backing: .buffered, defer: false)
            window.title = "Zones document-free fixture \(index)"
            window.isReleasedWhenClosed = false
            window.animationBehavior = .none
            let label = NSTextField(labelWithString: "Fixture \(index). This window contains no user documents.")
            label.frame = CGRect(x: 20, y: 40, width: 420, height: 40)
            window.contentView?.addSubview(label)
            window.orderFront(nil)
            windows.append(window)
        }
        let readiness = Timer(timeInterval: 0.03, repeats: true) { timer in
            MainActor.assumeIsolated {
                let onScreen = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? []
                let ids = Set(onScreen.compactMap { info -> Int? in
                    guard info[kCGWindowOwnerPID as String] as? Int32 == getpid() else { return nil }
                    return info[kCGWindowNumber as String] as? Int
                })
                guard windows.allSatisfy({ ids.contains($0.windowNumber) }) else { return }
                let data = try! JSONSerialization.data(withJSONObject: ["pid": getpid(), "ids": windows.map(\.windowNumber),
                                                                        "hasShadow": windows.map(\.hasShadow)])
                try! data.write(to: directory.appendingPathComponent("ready.json"), options: .atomic)
                timer.invalidate()
            }
        }
        RunLoop.main.add(readiness, forMode: .common)
        var handled: Set<String> = []
        let commands = Timer(timeInterval: 0.03, repeats: true) { _ in
            MainActor.assumeIsolated {
                let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
                for name in names.sorted() where name.hasSuffix(".request") && !handled.contains(name) {
                    handled.insert(name)
                    let words = ((try? String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8)) ?? "")
                        .split(separator: " ").map(String.init)
                    let index = words.count > 1 ? Int(words[1]) ?? 0 : 0
                    switch words.first {
                    case "minimum":
                        if words.count == 4, let width = Double(words[2]), let height = Double(words[3]) {
                            windows[index].minSize = CGSize(width: width, height: height)
                        } else { windows[index].minSize = windows[index].frame.size }
                    case "minimize":
                        windows[index].styleMask.insert(.miniaturizable)
                        windows[index].miniaturize(nil)
                    case "unminimize":
                        windows[index].deminiaturize(nil)
                        windows[index].styleMask.remove(.miniaturizable)
                    case "hide": windows[index].orderOut(nil)
                    case "show": windows[index].orderFrontRegardless()
                    case "move":
                        var origin = windows[index].frame.origin
                        origin.x += CGFloat(Double(words[2]) ?? 0)
                        windows[index].setFrameOrigin(origin)
                    case "frame" where words.count == 6:
                        if let x = Double(words[2]), let y = Double(words[3]),
                           let width = Double(words[4]), let height = Double(words[5]) {
                            windows[index].setFrame(CGRect(x: x, y: y, width: width, height: height), display: true)
                        }
                    case "fixed": windows[index].styleMask.remove(.resizable)
                    case "resizable": windows[index].styleMask.insert(.resizable)
                    case "front": windows.filter(\.isVisible).forEach { $0.orderFrontRegardless() }
                    case "report":
                        let frames = windows.map { [$0.frame.minX, $0.frame.minY, $0.frame.width, $0.frame.height] }
                        try? JSONSerialization.data(withJSONObject: frames).write(to: directory.appendingPathComponent("frames.json"))
                    default: break
                    }
                    try? Data("ready".utf8).write(to: directory.appendingPathComponent(
                        name.replacingOccurrences(of: ".request", with: ".ready")), options: .atomic)
                }
            }
        }
        RunLoop.main.add(commands, forMode: .common)
        app.run()
    }

    @MainActor
    static func run() async throws -> Completion? {
        let app = NSApplication.shared
        var failures = 0
        var passes = 0
        var completed: [String] = []
        var gates: [String: String] = [:]
        let passive = CommandLine.arguments.contains("--passive")
        var keyWindows: [String] = []
        gates["firstMouseDelivery"] = "a first click reaching a card in the inactive, non-key chooser needs a physical pointer; "
            + "constructed clicks through NSWindow.sendEvent bypass the window server's routing"
        if passive {
            gates["views"] = "passive run skips the pinned handle's focus, the window suggestions and the notice; run --permission-free on an unoccupied desktop"
            _ = NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { note in
                MainActor.assumeIsolated { keyWindows.append(String(describing: note.object.map { type(of: $0) })) }
            }
        }
        func terminal() throws -> Completion {
            guard let tokenIndex = CommandLine.arguments.firstIndex(of: "--invocation"),
                  let pathIndex = CommandLine.arguments.firstIndex(of: "--receipt"),
                  CommandLine.arguments.count > tokenIndex + 1, CommandLine.arguments.count > pathIndex + 1 else {
                throw SingleFrameCaptureError.failed
            }
            let receipt: [String: Any] = ["version": 1, "invocation": CommandLine.arguments[tokenIndex + 1],
                "mode": passive ? "passive" : CommandLine.arguments.contains("--permission-free") ? "permission-free" : "granted",
                "endpoint": gates.isEmpty ? "completed" : "gated", "passed": passes, "failed": failures,
                "completed": completed, "gates": gates]
            return Completion(status: failures == 0 ? 0 : 1,
                path: URL(fileURLWithPath: CommandLine.arguments[pathIndex + 1]), receipt: receipt)
        }
        func expect(_ condition: Bool, _ message: String, _ detail: @autoclosure () -> String = "") {
            print("\(condition ? "PASS" : "FAIL"): \(message)")
            if condition { passes += 1 }
            if !condition { failures += 1; if !detail().isEmpty { print("  observed: \(detail())") } }
        }
        let output = ProcessInfo.processInfo.environment["LINEUP_ZONES_CAPTURE_DIR"].map { URL(fileURLWithPath: $0) }
        if let output { try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true) }
        func capture(_ window: NSWindow, name: String) throws {
            guard let output, let view = window.contentView,
                  let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
            view.cacheDisplay(in: view.bounds, to: bitmap)
            guard let png = bitmap.representation(using: .png, properties: [:]) else { return }
            try png.write(to: output.appendingPathComponent(name + ".png"))
        }
        func bitmap(_ window: NSWindow) -> Data? {
            guard let view = window.contentView, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
            view.cacheDisplay(in: view.bounds, to: bitmap)
            return bitmap.representation(using: .png, properties: [:])
        }
        func composeOffscreen(_ windows: [NSWindow], around focus: CGRect, name: String) {
            guard let output else { return }
            let crop = focus.insetBy(dx: -48, dy: -72)
            let backdrop = ProbeBackdrop(frame: CGRect(origin: .zero, size: crop.size))
            backdrop.appearance = app.effectiveAppearance
            let layers = [(backdrop as NSView, crop, CGFloat(1))] + windows.compactMap { window in
                window.contentView.map { ($0, window.frame, window.alphaValue) }
            }
            let reps = layers.compactMap { view, frame, alpha -> (NSBitmapImageRep, CGRect, CGFloat)? in
                guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
                view.cacheDisplay(in: view.bounds, to: rep)
                return (rep, frame.offsetBy(dx: -crop.minX, dy: -crop.minY), alpha)
            }
            let image = NSImage(size: crop.size, flipped: false) { _ in
                for (rep, rect, alpha) in reps { rep.draw(in: rect, from: .zero, operation: .sourceOver, fraction: alpha, respectFlipped: true, hints: nil) }
                return true
            }
            guard let tiff = image.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
            else { return }
            try? png.write(to: output.appendingPathComponent(name + ".png"))
        }
        func composite(_ overlay: NSWindow, name: String, roundedCorner: Bool = false, shareCaption: Bool = false,
                       extra: [NSWindow] = []) async throws {
            guard output != nil, !passive, !CommandLine.arguments.contains("--permission-free"), CGPreflightScreenCaptureAccess(),
                  let screen = overlay.screen,
                  let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else { return }
            let crop = overlay.frame.insetBy(dx: -24, dy: -24).intersection(screen.frame)
            let backdrop = NSWindow(contentRect: crop.insetBy(dx: -16, dy: -16), styleMask: .borderless, backing: .buffered, defer: false)
            backdrop.isReleasedWhenClosed = false
            backdrop.level = .floating; backdrop.hasShadow = false; backdrop.ignoresMouseEvents = true
            backdrop.animationBehavior = .none
            backdrop.contentView = ProbeBackdrop(frame: CGRect(origin: .zero, size: backdrop.frame.size))
            var observations: [[String: Any]] = []
            func record(_ stage: String, scWindows: [SCWindow] = []) {
                let known = Set([overlay.windowNumber, backdrop.windowNumber] + extra.map(\.windowNumber))
                let cg = (CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]] ?? []).filter {
                    $0[kCGWindowOwnerPID as String] as? Int32 == getpid()
                        && known.contains($0[kCGWindowNumber as String] as? Int ?? -1)
                }.map { row in
                    ["id": row[kCGWindowNumber as String] ?? -1,
                     "onscreen": row[kCGWindowIsOnscreen as String] ?? false,
                     "layer": row[kCGWindowLayer as String] ?? -1,
                     "bounds": row[kCGWindowBounds as String] ?? [:]]
                }
                let observation: [String: Any] = ["stage": stage, "active": app.isActive,
                    "overlayID": overlay.windowNumber, "overlayVisible": overlay.isVisible,
                    "overlayLevel": overlay.level.rawValue,
                    "hidesOnDeactivate": (overlay as? NSPanel)?.hidesOnDeactivate ?? false,
                    "backdropID": backdrop.windowNumber, "backdropVisible": backdrop.isVisible,
                    "backdropLevel": backdrop.level.rawValue, "cg": cg,
                    "sck": scWindows.filter { known.contains(Int($0.windowID)) }.map {
                        ["id": Int($0.windowID), "pid": Int($0.owningApplication?.processID ?? -1),
                         "onscreen": $0.isOnScreen, "layer": $0.windowLayer]
                    }]
                observations.append(observation)
                print("Composite prerequisite \(name). \(observation)")
            }
            record("before-backdrop-order")
            backdrop.order(.below, relativeTo: (extra.first ?? overlay).windowNumber)
            record("after-backdrop-order")
            defer {
                backdrop.orderOut(nil)
                if let output, let data = try? JSONSerialization.data(withJSONObject: observations, options: [.prettyPrinted, .sortedKeys]) {
                    try? data.write(to: output.appendingPathComponent(name + "-prerequisites.json"))
                }
            }
            overlay.contentView?.displayIfNeeded()
            let allowed = Set([CGWindowID(overlay.windowNumber), CGWindowID(backdrop.windowNumber)] + extra.map { CGWindowID($0.windowNumber) })
            let deadline = Date(timeIntervalSinceNow: 2)
            let compositorReady = await observeUntil {
                guard overlay.isVisible, backdrop.isVisible else { return false }
                let rows = (CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? []).filter {
                    $0[kCGWindowOwnerPID as String] as? Int32 == getpid()
                        && allowed.contains($0[kCGWindowNumber as String] as? UInt32 ?? 0)
                        && ($0[kCGWindowBounds as String] as? [String: Any]).flatMap {
                            CGRect(dictionaryRepresentation: $0 as CFDictionary)
                        }.map { !$0.isEmpty } == true
                }
                return rows.count == allowed.count
            }
            record(compositorReady ? "exact-cg-ready" : "exact-cg-deadline")
            var resolved: (SCDisplay, [SCWindow])?
            repeat {
                let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
                let windows = content.windows.filter { allowed.contains($0.windowID) && $0.owningApplication?.processID == getpid() }
                if observations.count == 3 || windows.count == allowed.count { record("sck-observation", scWindows: content.windows) }
                if windows.count == allowed.count, let display = content.displays.first(where: { $0.displayID == displayID }) {
                    resolved = (display, windows); break
                }
                _ = await observeUntil({ false }, deadline: 0.05)
            } while Date() < deadline
            guard compositorReady, let (display, windows) = resolved else {
                record("deadline")
                expect(false, "composite \(name) resolves only its two exact probe-owned window IDs"); return
            }
            let filter = SCContentFilter(display: display, including: windows)
            var startAck = false, stopAck = false
            let capture = SingleFrameCapture(operations: .init(start: { stream in try await stream.startCapture(); startAck = true },
                                                               stop: { stream in try await stream.stopCapture(); stopAck = true }))
            let source = CGRect(x: crop.minX - screen.frame.minX, y: screen.frame.maxY - crop.maxY, width: crop.width, height: crop.height)
            let scale = screen.backingScaleFactor
            let image = try await capture.capture(filter: filter, width: Int(crop.width * scale), height: Int(crop.height * scale), sourceRect: source)
            record("after-native-capture", scWindows: windows)
            expect(startAck && stopAck && capture.state == .stopped, "composite \(name) completes native start and stop acknowledgments")
            let bitmap = NSBitmapImageRep(cgImage: image)
            try bitmap.representation(using: .png, properties: [:])?.write(to: output!.appendingPathComponent(name + ".png"))
            var corner: [CGFloat] = []
            func pixel(_ point: CGPoint) -> NSColor? {
                bitmap.colorAt(x: Int((point.x - crop.minX) * scale), y: Int((crop.maxY - point.y) * scale))?.usingColorSpace(.sRGB)
            }
            var captionContrast: CGFloat = 0
            if shareCaption {
                func luminance(_ color: NSColor) -> CGFloat {
                    func linear(_ value: CGFloat) -> CGFloat { value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4) }
                    return 0.2126 * linear(color.redComponent) + 0.7152 * linear(color.greenComponent) + 0.0722 * linear(color.blueComponent)
                }
                if let background = pixel(CGPoint(x: overlay.frame.minX + 10, y: overlay.frame.minY + 14)) {
                    var brightest = luminance(background), darkest = brightest
                    for x in 16..<Int(overlay.frame.width - 16) {
                        for y in 8..<22 {
                            if let color = pixel(CGPoint(x: overlay.frame.minX + CGFloat(x), y: overlay.frame.minY + CGFloat(y))) {
                                brightest = max(brightest, luminance(color)); darkest = min(darkest, luminance(color))
                            }
                        }
                    }
                    captionContrast = max((brightest + 0.05) / (luminance(background) + 0.05),
                                          (luminance(background) + 0.05) / (darkest + 0.05))
                }
                expect(captionContrast >= 4.5, "composite \(name) keeps its actual caption legible on the fixture backdrop",
                       "captured caption contrast \(captionContrast)")
            }
            if roundedCorner {
                let a = pixel(CGPoint(x: overlay.frame.minX + 2, y: overlay.frame.maxY - 2))
                let b = pixel(CGPoint(x: overlay.frame.minX - 8, y: overlay.frame.maxY + 8))
                if let a, let b {
                    corner = [abs(a.redComponent - b.redComponent), abs(a.greenComponent - b.greenComponent), abs(a.blueComponent - b.blueComponent)]
                }
                expect(corner.count == 3 && corner.allSatisfy { $0 < 0.12 },
                       "composite \(name) leaves its rounded top-left corner on the actual fixture backdrop", "channel differences \(corner)")
            }
            let receipt: [String: Any] = ["name": name, "windowIDs": allowed.sorted(), "ownerPID": getpid(),
                "startAcknowledged": startAck, "stopAcknowledged": stopAck, "stopped": capture.state == .stopped,
                "crop": [crop.minX, crop.minY, crop.width, crop.height], "scale": scale, "cornerChannelDifferences": corner, "captionContrast": captionContrast]
            try JSONSerialization.data(withJSONObject: receipt, options: [.prettyPrinted, .sortedKeys])
                .write(to: output!.appendingPathComponent(name + "-receipt.json"))
        }
        func pump(_ seconds: TimeInterval) {
            let deadline = Date(timeIntervalSinceNow: seconds)
            while Date() < deadline { RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.005)) }
        }
        func observeUntil(_ predicate: @escaping @MainActor () -> Bool, deadline seconds: TimeInterval = 2) async -> Bool {
            if predicate() { return true }
            return await withCheckedContinuation { continuation in
                let deadline = Date(timeIntervalSinceNow: seconds)
                let timer = Timer(timeInterval: 0.005, repeats: true) { timer in
                    MainActor.assumeIsolated {
                        let ready = predicate()
                        if ready || Date() >= deadline { timer.invalidate(); continuation.resume(returning: ready) }
                    }
                }
                RunLoop.main.add(timer, forMode: .common)
            }
        }
        func views(_ view: NSView?) -> [NSView] {
            guard let view else { return [] }
            return [view] + view.subviews.flatMap { views($0) }
        }
        func texts(_ window: NSWindow) -> [String] {
            views(window.contentView).compactMap { ($0 as? NSTextField)?.stringValue }.filter { !$0.isEmpty }
        }
        func key(_ code: UInt16, _ characters: String, to window: NSWindow, flags: NSEvent.ModifierFlags = [],
                 repeating: Bool = false) {
            guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
                                               timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                               context: nil, characters: characters, charactersIgnoringModifiers: characters,
                                               isARepeat: repeating, keyCode: code) else { return }
            window.sendEvent(event)
        }
        let screen = NSScreen.screens[0]
        let visible = screen.visibleFrame
        let free = CGRect(x: visible.midX, y: visible.minY, width: visible.width / 2, height: visible.height)
        let filled = CGRect(x: visible.minX, y: visible.minY, width: visible.width / 2, height: visible.height)
        let sample: [ZoneFillPanel.Candidate] = (0..<5).map {
            ZoneFillPanel.Candidate(app: "Fixture \($0)", title: "Document-free window \($0)",
                                    display: $0 == 4 ? "Other display" : nil, icon: NSWorkspace.shared.icon(for: .application))
        }
        let smallSource = NSImage(size: CGSize(width: 120, height: 80), flipped: false) { rect in
            NSColor.systemTeal.setFill(); rect.fill()
            NSColor.white.setFill(); rect.insetBy(dx: 20, dy: 20).fill()
            return true
        }.cgImage(forProposedRect: nil, context: nil, hints: nil)
        func candidateButtons(_ panel: NSWindow) -> [NSButton] {
            views(panel.contentView).compactMap { $0 as? NSButton }.filter { $0.accessibilityLabel()?.hasPrefix("Fixture ") == true }
        }
        func motion(_ view: NSView, in panel: NSWindow) {
            let point = view.convert(CGPoint(x: 20, y: 20), to: nil)
            if let event = NSEvent.mouseEvent(with: .mouseMoved, location: point, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.windowNumber, context: nil,
                    eventNumber: 0, clickCount: 0, pressure: 0) { view.mouseMoved(with: event) }
        }
        func enter(_ button: NSButton, in panel: NSWindow, exiting: Bool = false) {
            if let event = NSEvent.enterExitEvent(with: exiting ? .mouseExited : .mouseEntered, location: .zero, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.windowNumber, context: nil,
                    eventNumber: 0, trackingNumber: 0, userData: nil) {
                if exiting { button.mouseExited(with: event) } else { button.mouseEntered(with: event) }
            }
        }
        func click(_ view: NSView, in panel: NSWindow) {
            let point = view.convert(CGPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
            func event(_ type: NSEvent.EventType) -> NSEvent? {
                NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                   windowNumber: panel.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                                   pressure: type == .leftMouseUp ? 0 : 1)
            }
            guard let down = event(.leftMouseDown), let up = event(.leftMouseUp) else { return }
            app.postEvent(up, atStart: false)
            panel.sendEvent(down)
            if let release = app.nextEvent(matching: .leftMouseUp, until: .distantPast, inMode: .default, dequeue: true) {
                if release.windowNumber == panel.windowNumber, release.locationInWindow == point { panel.sendEvent(release) }
                else { app.postEvent(release, atStart: true) }
            }
        }
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            app.appearance = NSAppearance(named: appearance)
            let suffix = appearance == .aqua ? "light" : "dark"
            let before = HighlightWindow()
            before.show(at: CGRect(x: 80, y: 100, width: 500, height: 500), hint: HighlightWindow.halfHint)
            expect(before.ignoresMouseEvents && !before.isKeyWindow, "ordinary highlight stays click-through and passive")
            try capture(before, name: "ordinary-\(suffix)")
            before.orderOut(nil)
            let neighbor = HighlightWindow(style: .neighbor)
            neighbor.show(at: CGRect(x: 80, y: 100, width: 250, height: 500), hint: nil)
            expect(neighbor.ignoresMouseEvents && !neighbor.isKeyWindow && !texts(neighbor).contains("Share zone"),
                   "neighbor preview is passive without a duplicate Share zone hint")
            try capture(neighbor, name: "neighbor-\(suffix)"); neighbor.orderOut(nil)
            let rail = ShareRailPanel()
            let targets = ShareTarget.targets(in: CGRect(x: 80, y: 100, width: 500, height: 500))
            rail.show(targets: targets)
            expect(rail.ignoresMouseEvents && !rail.isKeyWindow && rail.level.rawValue > before.level.rawValue,
                   "painted share targets stay passive above the target preview")
            let union = targets[0].rect.union(targets[1].rect)
            expect(rail.frame == CGRect(x: union.minX - 6, y: union.minY - 24, width: union.width + 12, height: union.height + 30)
                    && targets.allSatisfy { rail.frame.contains($0.rect) }, "share platter preserves both exact core target rectangles")
            expect(texts(rail).contains("Share zone"), "idle share caption names the action")
            let railOnScreen = {
                (CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? []).contains {
                    $0[kCGWindowOwnerPID as String] as? Int32 == getpid()
                        && $0[kCGWindowNumber as String] as? Int == rail.windowNumber
                }
            }
            let railPublished = await observeUntil(railOnScreen)
            print("Passive rail prerequisite \(suffix). published \(railPublished), active before deactivate \(app.isActive)")
            app.deactivate()
            let passiveRailReady = await observeUntil { !app.isActive && railOnScreen() }
            if app.isActive {
                gates["passiveDeactivation-\(suffix)"] = "AppKit retained the active probe after deactivate(); forced activation of another application is outside scope"
                print("GATE: passive rail deactivation in \(suffix). AppKit retained the active probe.")
            } else {
                expect(railPublished && passiveRailReady && rail.ignoresMouseEvents && !rail.isKeyWindow,
                       "the actual share rail stays on screen after its probe application deactivates in \(suffix)",
                       "published \(railPublished), inactive/on-screen \(passiveRailReady), active \(app.isActive), key \(rail.isKeyWindow)")
            }
            try capture(rail, name: "share-idle-\(suffix)")
            try await composite(rail, name: "composite-share-idle-\(suffix)", shareCaption: true)
            let idleRail = bitmap(rail)
            rail.show(targets: targets, active: targets[0])
            expect(texts(rail).contains("Side by side") && bitmap(rail) != idleRail, "side target visibly arms and names the result")
            try capture(rail, name: "share-side-\(suffix)")
            try await composite(rail, name: "composite-share-side-\(suffix)", shareCaption: true)
            rail.show(targets: targets, active: targets[1])
            expect(texts(rail).contains("Stacked"), "stacked target names its result")
            try capture(rail, name: "share-stacked-\(suffix)")
            try await composite(rail, name: "composite-share-stacked-\(suffix)", shareCaption: true)
            rail.show(targets: targets)
            expect(texts(rail).contains("Share zone") && bitmap(rail) == idleRail, "leaving a tile restores the idle rail")
            rail.orderOut(nil)
            let grip = DividerGripPanel(bindHeld: { true }, activationKey: { nil }, isKeyDown: { _ in false }, input: { _ in })
            let gripLine = CGRect(x: 611, y: 140, width: 6, height: 400)
            grip.place(CGRect(x: 600, y: 300, width: 28, height: 48), axis: .vertical, line: gripLine)
            grip.apply(.revealed)
            expect(grip.ignoresMouseEvents && !grip.canBecomeKey && abs(grip.alphaValue - 0.8) < 0.001,
                   "a revealed grip is translucent, click-through and cannot take focus", "alpha \(grip.alphaValue)")
            expect(grip.lineWindow.isVisible && grip.lineWindow.ignoresMouseEvents && !grip.lineWindow.canBecomeKey
                    && grip.lineWindow.frame == gripLine && grip.lineWindow.alphaValue == grip.alphaValue
                    && grip.lineWindow.level == grip.level,
                   "the handle's line shows with it, click-through, at the handle's alpha",
                   "visible \(grip.lineWindow.isVisible) frame \(grip.lineWindow.frame) alpha \(grip.lineWindow.alphaValue)/\(grip.alphaValue) level \(grip.lineWindow.level.rawValue)/\(grip.level.rawValue)")
            try capture(grip, name: "grip-revealed-\(suffix)")
            try capture(grip.lineWindow, name: "grip-line-\(suffix)")
            composeOffscreen([grip.lineWindow, grip], around: grip.frame, name: "handle-revealed-\(suffix)")
            try await composite(grip, name: "composite-handle-revealed-\(suffix)", extra: [grip.lineWindow])
            let revealed = bitmap(grip)
            grip.apply(.armed)
            expect(!grip.ignoresMouseEvents && !grip.canBecomeKey && grip.alphaValue == 1 && grip.lineWindow.alphaValue == 1
                    && grip.lineWindow.ignoresMouseEvents,
                   "an entered grip takes the mouse but not the keyboard; its line brightens and stays click-through")
            try capture(grip, name: "grip-armed-\(suffix)")
            composeOffscreen([grip.lineWindow, grip], around: grip.frame, name: "handle-armed-\(suffix)")
            let armed = bitmap(grip)
            let columnCursor: NSCursor
            if #available(macOS 15.0, *) { columnCursor = .columnResize } else { columnCursor = .resizeLeftRight }
            expect(grip.resizeCursor == columnCursor, "an entered vertical handle uses the native column resize cursor")
            grip.showGuide("½")
            let badge = grip.guideWindow
            try capture(grip, name: "grip-guide-\(suffix)")
            try capture(badge, name: "grip-guide-badge-\(suffix)")
            expect(revealed != armed && armed != bitmap(grip), "grip phase and guide lock each change the actual drawing")
            expect(badge.isVisible && badge.ignoresMouseEvents && !badge.canBecomeKey && badge.level == grip.level
                    && badge.alphaValue == grip.alphaValue && !badge.frame.intersects(grip.frame) && badge.frame.minX >= grip.frame.maxX
                    && abs(badge.frame.midY - grip.frame.midY) < 0.5 && bitmap(badge) != nil,
                   "a locked guide is named in a click-through badge beside the handle, outside its hit rect",
                   "badge \(badge.frame) visible \(badge.isVisible) grip \(grip.frame)")
            grip.move(to: grip.frame.offsetBy(dx: 0, dy: 20))
            expect(abs(badge.frame.midY - grip.frame.midY) < 0.5, "the guide badge moves with its handle", "badge \(badge.frame) grip \(grip.frame)")
            grip.move(to: grip.frame.offsetBy(dx: 0, dy: -20))
            grip.showGuide(nil)
            expect(!badge.isVisible, "clearing the guide hides its badge")
            let dividerPreview = HighlightWindow(style: .divider)
            func frontToBack(_ windows: [NSWindow]) -> [Int] {
                let order = (CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? [])
                    .compactMap { $0[kCGWindowNumber as String] as? Int }
                return windows.map { order.firstIndex(of: $0.windowNumber) ?? -1 }
            }
            for (guide, previewFrame) in [("½", CGRect(x: 617, y: 140, width: 300, height: 400)),
                                          ("⅔", CGRect(x: 657, y: 140, width: 260, height: 400)),
                                          ("⅔", nil)] as [(String, CGRect?)] {
                grip.apply(.dragging)
                if let previewFrame { dividerPreview.show(at: previewFrame, hint: nil, below: grip.lineWindow) }
                grip.showGuide(guide)
                var order = frontToBack([badge, grip, grip.lineWindow, dividerPreview])
                let published = await observeUntil {
                    order = frontToBack([badge, grip, grip.lineWindow, dividerPreview])
                    return !order.contains(-1)
                }
                print("Guide badge order \(guide) \(suffix). published \(published), front-to-back \(order)")
                expect(!order.contains(-1) && order == order.sorted(),
                       "the \(guide) badge stays above the handle, its line and the divider preview after a drag sample",
                       "front-to-back indices of badge, handle, line, preview \(order)")
            }
            dividerPreview.orderOut(nil)
            grip.showGuide(nil)
            grip.apply(.pinned)
            if !passive {
                let front = NSWorkspace.shared.frontmostApplication
                grip.pin()
                let pinReady = await observeUntil { grip.isKeyWindow }
                expect(pinReady && grip.canBecomeKey && grip.isKeyWindow && NSWorkspace.shared.frontmostApplication == front,
                       "a pinned grip takes keyboard focus without changing the frontmost app",
                       "key \(grip.isKeyWindow), appActive \(app.isActive), front before \(front?.localizedName ?? "nil"), after \(NSWorkspace.shared.frontmostApplication?.localizedName ?? "nil")")
            }
            try capture(grip, name: "grip-pinned-\(suffix)")
            try await composite(grip, name: "composite-grip-pinned-\(suffix)", extra: [grip.lineWindow])
            grip.move(to: grip.frame.offsetBy(dx: 40, dy: 0))
            expect(grip.lineWindow.frame == gripLine.offsetBy(dx: 40, dy: 0) && grip.frame.minX == 640,
                   "a moving handle carries its line across without changing the line's extent",
                   "line \(grip.lineWindow.frame) grip \(grip.frame)")
            let horizontalLine = CGRect(x: 420, y: 311, width: 400, height: 6)
            grip.place(CGRect(x: 600, y: 300, width: 48, height: 28), axis: .horizontal, line: horizontalLine)
            expect(grip.lineWindow.frame == horizontalLine, "placing a handle on a horizontal line paints that line",
                   "line \(grip.lineWindow.frame)")
            try capture(grip, name: "grip-pinned-horizontal-\(suffix)")
            composeOffscreen([grip.lineWindow, grip], around: grip.frame, name: "handle-pinned-horizontal-\(suffix)")
            let rowCursor: NSCursor
            if #available(macOS 15.0, *) { rowCursor = .rowResize } else { rowCursor = .resizeUpDown }
            expect(grip.resizeCursor == rowCursor, "a horizontal handle uses the native row resize cursor")
            grip.showGuide("⅓")
            grip.hide()
            expect(!grip.isVisible && !grip.lineWindow.isVisible && !grip.guideWindow.isVisible,
                   "hiding the handle hides its line and its guide badge")
            if passive { continue }
            var cancels = 0
            var selected: [Int] = []
            let fill = ZoneFillPanel(select: { selected.append($0) }, cancel: { cancels += 1 })
            let front = NSWorkspace.shared.frontmostApplication
            let keyBefore = app.keyWindow
            fill.show(sample, free: free, filled: filled, visible: visible)
            fill.contentView?.layoutSubtreeIfNeeded()
            let buttons = candidateButtons(fill)
            expect(fill.isVisible && !fill.isKeyWindow && app.keyWindow === keyBefore && fill.firstResponder === fill
                    && NSWorkspace.shared.frontmostApplication == front,
                   "automatic suggestions appear without key focus, a first responder or a frontmost change in \(suffix)",
                   "key \(fill.isKeyWindow), responder \(String(describing: fill.firstResponder)), front \(NSWorkspace.shared.frontmostApplication?.localizedName ?? "nil")")
            let columns = ZoneFillLayout.columns(panelWidth: ZoneFillLayout.chooserFrame(free: free, filled: filled, visible: visible, rows: 1).width)
            expect(fill.frame == ZoneFillLayout.chooserFrame(free: free, filled: filled, visible: visible,
                                                             rows: (sample.count + columns - 1) / columns)
                    && free.contains(fill.frame) && !fill.frame.intersects(filled),
                   "the chooser sits inside the free zone beside the drop, at most 532 by 440 and off the placed window")
            expect(buttons.count == 5 && buttons.allSatisfy { ($0.accessibilityValue() as? String) == "Loading preview" },
                   "suggestions appear with app icons while every preview is pending")
            try capture(fill, name: "chooser-pending-\(suffix)")
            fill.setThumbnail(smallSource, at: 0); fill.setThumbnail(nil, at: 1)
            let heading = views(fill.contentView).compactMap { $0 as? NSTextField }.first { $0.stringValue == "Fill this zone" }
            expect(heading != nil && buttons.count == 5
                    && abs(heading!.convert(heading!.bounds, to: nil).minX - buttons[0].convert(buttons[0].bounds, to: nil).minX) < 0.5,
                   "chooser heading and the first well share the twenty-point content column")
            expect(buttons.count == 5 && (buttons[0].accessibilityValue() as? String) == ""
                    && (buttons[1].accessibilityValue() as? String) == "Preview unavailable"
                    && (buttons[2].accessibilityValue() as? String) == "Loading preview",
                   "loaded, failed and pending previews expose their actual state")
            try capture(fill, name: "chooser-\(suffix)")
            try await composite(fill, name: "composite-chooser-\(suffix)", roundedCorner: true)
            expect(fill.selectedIndex == 0, "appearing cards do not select a stationary pointer target")
            guard let heading, let close = views(fill.contentView).compactMap({ $0 as? NSButton }).first(where: { $0.title == "Close" }) else {
                expect(false, "chooser exposes its heading and Close"); return nil
            }
            expect(buttons.allSatisfy { $0.acceptsFirstMouse(for: nil) } && close.acceptsFirstMouse(for: nil),
                   "every card and Close take the first click in a background panel")
            motion(buttons[2], in: fill)
            expect(fill.selectedIndex == 2 && fill.firstResponder === fill && !fill.isKeyWindow,
                   "pointer motion moves the quiet ring without taking focus in \(suffix)")
            try capture(fill, name: "chooser-hover-unfocused-\(suffix)")
            click(buttons[2], in: fill)
            expect(selected == [2] && NSWorkspace.shared.frontmostApplication == front,
                   "a constructed click through NSWindow.sendEvent on a card in the background chooser selects exactly that window in \(suffix)",
                   "selected \(selected), key \(fill.isKeyWindow), front \(NSWorkspace.shared.frontmostApplication?.localizedName ?? "nil")")
            if !fill.isKeyWindow { click(heading, in: fill) }
            let chooserKeyReady = await observeUntil { fill.isKeyWindow }
            expect(chooserKeyReady && fill.firstResponder === buttons[2] && fill.selectedIndex == 2
                    && NSWorkspace.shared.frontmostApplication == front,
                   "clicking into the chooser gives it key focus on the card under the pointer without changing the frontmost app",
                   "key \(fill.isKeyWindow), responder \(String(describing: fill.firstResponder)), appActive \(app.isActive)")
            selected = []
            let fullKeyboardAccess = app.isFullKeyboardAccessEnabled
            print("Native keyboard setting. Full Keyboard Access \(fullKeyboardAccess), appearance \(suffix)")
            if !fullKeyboardAccess {
                gates["fullKeyboardAccess"] = "native Tab traversal observed with Full Keyboard Access off; enabled traversal remains unverified"
            }
            for (direction, flags) in [("tab", NSEvent.ModifierFlags()), ("shift-tab", NSEvent.ModifierFlags.shift)] {
                fill.makeFirstResponder(buttons[0])
                var visited: Set<Int> = []
                var reachedClose = false, capturedCandidate = false
                for step in 0...buttons.count {
                    let priorSelection = fill.selectedIndex
                    let priorResponder = fill.firstResponder
                    key(48, "\t", to: fill, flags: flags)
                    if fill.firstResponder === priorResponder {
                        print("Native \(direction) \(suffix) step \(step). Responder unchanged, Full Keyboard Access \(fullKeyboardAccess)")
                        if fullKeyboardAccess { expect(false, "native \(direction) changes focus with the current enabled setting in \(suffix)") }
                        break
                    }
                    if let index = buttons.firstIndex(where: { $0 === fill.firstResponder }) {
                        visited.insert(index)
                        print("Native \(direction) \(suffix) step \(step). Candidate \(index), selection \(fill.selectedIndex)")
                        expect(fill.selectedIndex == index, "native \(direction) focus owns the current selection in \(suffix)")
                        let focusedRing = bitmap(fill)
                        motion(buttons[index], in: fill)
                        expect(bitmap(fill) == focusedRing, "native \(direction) already draws the pointer-selected ring in \(suffix)")
                        selected = []
                        key(36, "\r", to: fill)
                        expect(selected == [index], "Return after native \(direction) selects its focused candidate in \(suffix)")
                        if index != 0 && !capturedCandidate {
                            try capture(fill, name: "chooser-native-\(direction)-\(suffix)")
                            try await composite(fill, name: "composite-chooser-native-\(direction)-\(suffix)")
                            capturedCandidate = true
                        }
                        key(124, "\u{f703}", to: fill)
                        let next = min(index + 1, buttons.count - 1)
                        expect(fill.selectedIndex == next && fill.firstResponder === buttons[next],
                               "arrows after native \(direction) start at the actual focused candidate in \(suffix)")
                        fill.makeFirstResponder(buttons[index])
                    } else if let control = fill.firstResponder as? NSButton, control.title == "Close" {
                        reachedClose = true
                        print("Native \(direction) \(suffix) step \(step). Close, selection \(fill.selectedIndex)")
                        expect(fill.selectedIndex == priorSelection, "native \(direction) to Close retains the current quiet selection in \(suffix)")
                        try capture(fill, name: "chooser-native-\(direction)-close-focused-\(suffix)")
                        try await composite(fill, name: "composite-chooser-native-\(direction)-close-focused-\(suffix)")
                    } else {
                        print("Native \(direction) \(suffix) step \(step). Responder \(String(describing: fill.firstResponder))")
                    }
                }
                if fullKeyboardAccess {
                    expect(visited == Set(buttons.indices) && reachedClose && capturedCandidate,
                           "native \(direction) traverses candidates and Close with the current enabled setting in \(suffix)")
                }
            }
            selected = []
            expect(fill.makeFirstResponder(buttons[1]) && fill.firstResponder === buttons[1]
                    && fill.selectedIndex == 1, "direct native responder selection stays synchronized in \(suffix)")
            let nativeFocusedRing = bitmap(fill)
            motion(buttons[1], in: fill)
            expect(bitmap(fill) == nativeFocusedRing, "direct native focus already draws the pointer-selected ring in \(suffix)")
            key(36, "\r", to: fill)
            expect(selected == [1], "Return after direct native focus selects the indicated candidate in \(suffix)")
            try capture(fill, name: "chooser-native-responder-\(suffix)")
            try await composite(fill, name: "composite-chooser-native-responder-\(suffix)")
            if let nativeClose = views(fill.contentView).compactMap({ $0 as? NSButton }).first(where: { $0.title == "Close" }),
               fill.makeFirstResponder(nativeClose), fill.firstResponder === nativeClose {
                expect(fill.selectedIndex == 1 && bitmap(fill) != nativeFocusedRing,
                       "Close after direct native focus retains and quiets the selected ring in \(suffix)")
                try capture(fill, name: "chooser-native-responder-close-focused-\(suffix)")
                try await composite(fill, name: "composite-chooser-native-responder-close-focused-\(suffix)")
            } else { gates["fullKeyboardAccess"] = "Close cannot take focus with the current setting" }
            selected = []
            fill.makeFirstResponder(buttons[0])
            motion(buttons[3], in: fill)
            expect(fill.selectedIndex == 3 && fill.firstResponder === buttons[3], "pointer motion moves the current ring and existing card focus")
            try capture(fill, name: "chooser-hover-\(suffix)")
            buttons[3].highlight(true)
            try capture(fill, name: "chooser-pressed-\(suffix)")
            buttons[3].highlight(false)
            let focused = bitmap(fill)
            expect(close.imagePosition == .imageOnly && close.accessibilityLabel() == "Cancel window selection",
                   "circular Close retains its title and accessible cancellation action")
            if fill.makeFirstResponder(close), fill.firstResponder === close {
                expect(bitmap(fill) != focused, "moving focus to Close visibly quiets the current card ring",
                       "key \(fill.isKeyWindow), close focus \(fill.firstResponder === close)")
                motion(buttons[4], in: fill)
                expect(fill.selectedIndex == 4 && fill.firstResponder === close, "hover preserves Close focus")
                try capture(fill, name: "chooser-close-focused-\(suffix)")
                try await composite(fill, name: "composite-chooser-close-focused-\(suffix)")
                key(36, "\r", to: fill)
                expect(cancels == 1, "Return on Close after hover still cancels")
                key(49, " ", to: fill)
                expect(cancels == 2 && selected.isEmpty && fill.firstResponder === close,
                       "Space on Close after hover cancels without selecting a candidate")
            } else { gates["fullKeyboardAccess"] = "Close cannot take focus with the current setting" }
            fill.makeFirstResponder(buttons[4])
            fill.resignKey()
            try capture(fill, name: "chooser-unfocused-\(suffix)")
            fill.makeKey()
            let longSample = (0..<32).map { ZoneFillPanel.Candidate(app: "Fixture \($0)", title: "Overflow window \($0)", display: nil, icon: sample[0].icon) }
            fill.prepare(longSample, free: free, filled: filled, visible: visible)
            let scrolling = views(fill.contentView).compactMap { $0 as? NSScrollView }.first!
            let origin = scrolling.contentView.bounds.origin
            motion(candidateButtons(fill)[3], in: fill)
            expect(scrolling.contentView.bounds.origin == origin, "hover does not scroll the chooser")
            for _ in 0..<40 { key(125, "\u{f701}", to: fill) }
            let last = candidateButtons(fill).last!
            expect(fill.selectedIndex == 31 && scrolling.contentView.bounds.minY > 0
                    && scrolling.contentView.bounds.contains(last.frame.insetBy(dx: -6, dy: -6)),
                   "keyboard selection clamps to the final card and scrolls its entire focus ring into view")
            try capture(fill, name: "chooser-overflow-\(suffix)")
            key(126, "\u{f700}", to: fill)
            expect(fill.selectedIndex == 28, "up from the final card keeps the current three-column keyboard contract")
            fill.orderOut(nil)
            expect(!fill.isVisible && fill.alphaValue == 1, "cancellation leaves no animation capable of dimming or reopening the panel")
            let narrow = CGRect(x: visible.minX + 20, y: visible.minY + 20, width: 220, height: 260)
            let beside = CGRect(x: narrow.minX - 220, y: narrow.minY, width: 220, height: 260)
            fill.show(sample, free: narrow, filled: beside, visible: narrow)
            let narrowScroll = views(fill.contentView).compactMap { $0 as? NSScrollView }.first!
            expect(narrow.contains(fill.frame) && candidateButtons(fill).allSatisfy { $0.frame.minX >= 0 && $0.frame.maxX <= narrowScroll.contentSize.width },
                   "a narrow display bounds every actionable card inside the actual scroll viewport")
            try capture(fill, name: "chooser-narrow-\(suffix)")
            let short = CGRect(x: narrow.minX, y: narrow.minY, width: 320, height: 70)
            fill.show(sample, free: short, filled: beside, visible: short)
            let closeRect = close.convert(close.bounds, to: nil)
            expect(short.contains(fill.frame) && CGRect(origin: .zero, size: fill.frame.size).contains(closeRect),
                   "a short display retains Close inside the actual panel and clips unavailable grid space")
            try capture(fill, name: "chooser-short-\(suffix)"); fill.orderOut(nil)
            let notice = ZoneNoticePanel()
            notice.show(title: "ZonesNativeProbe didn’t fit", detail: "Windows were put back. The layout wasn’t saved.",
                        near: CGPoint(x: visible.midX, y: visible.midY), visible: visible)
            pump(0.2)
            expect(notice.ignoresMouseEvents && !notice.canBecomeKey && !notice.isKeyWindow && notice.isVisible,
                   "the refusal notice is click-through and never takes focus")
            try capture(notice, name: "notice-\(suffix)"); notice.orderOut(nil)
        }
        app.appearance = nil

        if !passive {
            var actions: [String] = []
            let chooser = ZoneFillPanel(select: { actions.append("select \($0)") }, cancel: { actions.append("cancel") })
            chooser.show(Array(sample.prefix(4)), free: free, filled: filled, visible: visible)
            expect(!chooser.isKeyWindow && chooser.firstResponder === chooser,
                   "an automatic chooser leaves the keyboard alone until someone clicks into it")
            if let heading = views(chooser.contentView).compactMap({ $0 as? NSTextField }).first(where: { $0.stringValue == "Fill this zone" }) {
                click(heading, in: chooser)
            }
            let keyboardReady = await observeUntil { chooser.isKeyWindow }
            let entered = candidateButtons(chooser)
            expect(keyboardReady && entered.count == 4 && chooser.firstResponder === entered[0] && actions.isEmpty,
                   "clicking the chooser's heading gives it actual key-window focus on the ringed card without choosing")
            key(124, "\u{f703}", to: chooser); key(124, "\u{f703}", to: chooser)
            let afterRight = chooser.selectedIndex
            key(125, "\u{f701}", to: chooser)
            let afterDown = chooser.selectedIndex
            key(126, "\u{f700}", to: chooser); key(124, "\u{f703}", to: chooser)
            key(36, "\r", to: chooser)
            expect(afterRight == 2 && afterDown == 3 && actions == ["select 1"],
                   "arrows move the ringed selection without wrapping and Return moves that candidate")
            chooser.prepare(Array(sample.prefix(4)), free: free, filled: filled, visible: visible)
            let focusCards = views(chooser.contentView).compactMap { $0 as? NSButton }.filter { $0.title.isEmpty }
            let movedFocus = focusCards.count == 4 && chooser.makeFirstResponder(focusCards[1])
                && chooser.firstResponder === focusCards[1]
            expect(movedFocus, "native responder traversal reaches a different candidate")
            if movedFocus {
                expect(chooser.selectedIndex == 1, "native card focus synchronizes the current selection ring")
                actions = []
                key(36, "\r", to: chooser)
                expect(actions == ["select 1"], "Return after native focus selects the ringed candidate")
                key(124, "\u{f703}", to: chooser)
                expect(chooser.selectedIndex == 2 && chooser.firstResponder === focusCards[2],
                       "arrows after native focus start from the current candidate")
            }
            let close = views(chooser.contentView).compactMap { $0 as? NSButton }.first { $0.title == "Close" }
            if let close, chooser.makeFirstResponder(close), chooser.firstResponder === close {
                actions = []
                key(36, "\r", to: chooser)
                chooser.makeFirstResponder(close)
                key(49, " ", to: chooser)
                expect(actions == ["cancel", "cancel"], "Return or Space on a focused Close closes and selects no window")
            } else {
                gates["fullKeyboardAccess"] = "Close cannot take focus with the current setting"
                print("GATE: Full Keyboard Access is off, so Close cannot take focus. Return used the ringed candidate above.")
            }
            actions = []
            key(53, "\u{1b}", to: chooser)
            expect(actions == ["cancel"], "Escape closes the chooser")
            chooser.orderOut(nil)
        }

        let dwellInput = ProbeInput()
        dwellInput.trusted = true
        var dwellLayout = Node.halves
        var dwellTrigger = DragSnapTrigger.default
        var dwellInteract = true
        let dwellController = DragSnapController(configProvider: { LineupConfig(defaultLayout: dwellLayout) },
            triggerProvider: { dwellTrigger }, onPlacement: { _, _, _ in }, canInteract: { dwellInteract },
            input: dwellInput.source(), visibleWindows: { _ in [] })
        dwellController.start()
        let screenInfo = ScreenIdentity.info(for: screen)
        func lines(_ root: Node) -> [Layout.DividerHandle] {
            Layout.dividerHandles(root, container: Layout.rootContainer(frame: screen.frame, visibleFrame: visible),
                                  pixelsWide: screenInfo.pixelsWide, thickness: 24)
        }
        func handles() -> [DividerGripPanel] { app.windows.compactMap { $0 as? DividerGripPanel }.filter(\.isVisible) }
        let column = lines(.halves)[0]
        let rest = CGPoint(x: column.line.midX + 3, y: visible.midY)
        func move(_ point: CGPoint) { dwellInput.deliver(.mouseMoved, at: point) }
        func settle() { dwellInput.elapse(DividerDwell.delay) }
        func clearDwell() { move(CGPoint(x: column.line.midX - 200, y: visible.midY)); settle() }

        move(CGPoint(x: column.line.midX - 60, y: visible.midY))
        move(rest)
        move(CGPoint(x: column.line.midX + 60, y: visible.midY))
        settle()
        expect(handles().isEmpty && dwellInput.timers.isEmpty, "crossing a line with the bind held shows nothing")

        move(rest)
        expect(handles().isEmpty && dwellInput.timers.map(\.delay) == [DividerDwell.delay],
               "arriving on a line starts one pause and shows nothing yet")
        dwellInput.elapse(0.2)
        expect(handles().isEmpty, "two tenths of a second on the line still shows nothing")
        dwellInput.elapse(0.1)
        let firstReveal = handles().first
        expect(handles().count == 1 && firstReveal?.frame == DividerGrip.rect(for: column, pointer: rest)
                && firstReveal?.ignoresMouseEvents == true && firstReveal.map { abs($0.alphaValue - 0.8) < 0.001 } == true
                && firstReveal?.lineWindow.frame == DividerGrip.segment(for: column) && firstReveal?.lineWindow.isVisible == true
                && firstReveal?.isKeyWindow == false,
               "resting three tenths of a second reveals the line and an offset, click-through handle",
               "grip \(String(describing: firstReveal?.frame)) want \(String(describing: DividerGrip.rect(for: column, pointer: rest))) line \(String(describing: firstReveal?.lineWindow.frame)) want \(DividerGrip.segment(for: column))")
        guard let revealed = firstReveal else { return nil }
        let shown = revealed.frame
        let towardHandle = shown.midY > rest.y ? CGFloat(1) : -1
        move(CGPoint(x: rest.x, y: rest.y + 20 * towardHandle))
        move(CGPoint(x: rest.x - 4, y: rest.y - 30 * towardHandle))
        expect(revealed.isVisible && revealed.frame == shown && revealed.ignoresMouseEvents && dwellInput.timers.isEmpty,
               "moving along the line near the handle keeps it exactly where it appeared")
        move(CGPoint(x: shown.midX, y: shown.midY))
        expect(!revealed.ignoresMouseEvents && revealed.alphaValue == 1 && revealed.lineWindow.alphaValue == 1 && !revealed.isKeyWindow,
               "entering the handle arms it and brightens its line without taking the keyboard")
        move(rest)
        expect(revealed.ignoresMouseEvents && revealed.frame == shown, "leaving the armed handle makes it click-through in place")
        let farAlong = CGPoint(x: rest.x, y: shown.midY - 150 * towardHandle)
        move(farAlong)
        expect(!revealed.isVisible && !revealed.lineWindow.isVisible && dwellInput.timers.count == 1,
               "moving far along the line hides the handle instead of moving it, and starts a new pause")
        settle()
        expect(revealed.isVisible && revealed.frame == DividerGrip.rect(for: column, pointer: farAlong) && revealed.frame != shown,
               "pausing again farther along shows the handle there")
        move(CGPoint(x: column.line.midX - 40, y: farAlong.y))
        settle()
        expect(handles().isEmpty && dwellInput.timers.isEmpty, "leaving the line hides the handle and starts nothing")

        move(rest)
        dwellInput.elapse(0.2)
        let along = CGPoint(x: rest.x, y: rest.y + 20)
        move(along)
        dwellInput.elapse(0.1)
        expect(handles().isEmpty, "moving twenty points along the line restarts the pause")
        dwellInput.elapse(0.2)
        expect(handles().first?.frame == DividerGrip.rect(for: column, pointer: along), "the restarted pause reveals at its own anchor")
        clearDwell()
        move(rest)
        dwellInput.elapse(0.2)
        let jitter = CGPoint(x: rest.x + 3, y: rest.y + 4)
        move(jitter)
        dwellInput.elapse(0.1)
        expect(handles().first?.frame == DividerGrip.rect(for: column, pointer: jitter), "five points of jitter does not restart the pause")
        clearDwell()

        for (interruption, label) in [(CGEventType.flagsChanged, "a bind release and quick re-press"), (.keyUp, "a typed key"),
                                      (.scrollWheel, "scrolling")] {
            move(rest)
            dwellInput.elapse(0.1)
            dwellInput.happen(interruption)
            dwellInput.elapse(0.2)
            expect(handles().isEmpty && dwellInput.timers.isEmpty, "\(label) during the pause shows nothing")
            clearDwell()
        }
        dwellInput.unreadable = [.scrollWheel]
        move(rest)
        settle()
        dwellInput.unreadable = []
        expect(handles().isEmpty && dwellInput.timers.isEmpty, "one unreadable input age among calm ones shows nothing")
        clearDwell()
        move(rest)
        dwellInput.modifiers = []
        settle()
        expect(handles().isEmpty, "releasing the bind before the pause ends shows nothing")
        dwellInput.modifiers = .shift
        settle()
        expect(handles().isEmpty && dwellInput.timers.isEmpty,
               "re-pressing the bind over a line shows nothing until the pointer moves")
        move(CGPoint(x: rest.x + 2, y: rest.y))
        dwellInput.buttons = 1
        settle()
        expect(handles().isEmpty, "a held mouse button at the deadline shows nothing")
        dwellInput.buttons = 0
        clearDwell()

        move(rest)
        let stale = dwellInput.timers.first?.action
        dwellInput.modifiers = []
        dwellInput.deliver(.leftMouseDown)
        dwellInput.deliver(.leftMouseUp)
        dwellInput.modifiers = .shift
        expect(dwellInput.timers.isEmpty, "a click cancels the pending pause at once")
        stale?()
        expect(handles().isEmpty, "the cancelled pause's late callback cannot reveal")
        move(rest)
        dwellInput.deliver(.rightMouseDown)
        settle()
        expect(handles().isEmpty && dwellInput.timers.isEmpty, "a secondary click cancels the pending pause")
        clearDwell()

        move(rest)
        dwellLayout = Node.columns([Boundary(0.6, .fraction)])
        settle()
        expect(handles().isEmpty, "a layout saved during the pause drops it")
        dwellLayout = .halves
        clearDwell()
        move(rest)
        dwellInput.trusted = false
        settle()
        dwellInput.trusted = true
        expect(handles().isEmpty, "Accessibility lost during the pause shows nothing")
        clearDwell()
        move(rest)
        dwellInteract = false
        settle()
        dwellInteract = true
        expect(handles().isEmpty, "suspended shortcuts or a stopped tool during the pause show nothing")
        clearDwell()
        move(rest)
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        let spaceCancelled = await observeUntil { dwellInput.timers.isEmpty }
        expect(spaceCancelled, "a desktop change cancels the pending pause")
        settle()
        clearDwell()

        dwellTrigger = DragSnapTrigger(keyCode: 40, modifiers: DragSnapModifierMask.shift)
        dwellInput.keys = [40]
        move(rest)
        dwellInput.elapse(0.1); dwellInput.happen(.keyDown)
        dwellInput.elapse(0.1); dwellInput.happen(.keyDown)
        dwellInput.elapse(0.1)
        expect(handles().count == 1, "a held custom bind key repeating key-down still reveals")
        clearDwell()
        move(rest)
        dwellInput.elapse(0.1)
        dwellInput.happen(.keyUp); dwellInput.happen(.keyDown)
        dwellInput.elapse(0.2)
        expect(handles().isEmpty, "releasing and re-pressing the custom bind key during the pause shows nothing")
        dwellTrigger = .default
        dwellInput.keys = []
        clearDwell()

        let rows = Node.split(axis: .horizontal, dividers: [Boundary(0.5, .fraction)], children: [.leaf, .leaf])
        dwellLayout = .split(axis: .vertical, dividers: [Boundary(0.5, .fraction)], children: [rows, .leaf])
        guard let nested = lines(dwellLayout).first(where: { $0.path == [0] }) else { expect(false, "nested layout has a nested line"); return nil }
        let junction = CGPoint(x: nested.container.maxX - 6, y: nested.line.midY + 2)
        move(junction)
        settle()
        expect(handles().first.map { $0.frame == DividerGrip.rect(for: nested, pointer: junction) && $0.frame.height == DividerGrip.thickness }
                == true && handles().first?.lineWindow.frame == DividerGrip.segment(for: nested),
               "near a T-junction the nested line wins and its line spans only its own column",
               "grip \(String(describing: handles().first?.frame)) want \(String(describing: DividerGrip.rect(for: nested, pointer: junction))) line \(String(describing: handles().first?.lineWindow.frame)) want \(DividerGrip.segment(for: nested))")
        if let nestedHandle = handles().first {
            for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                app.appearance = NSAppearance(named: appearance)
                composeOffscreen([nestedHandle.lineWindow, nestedHandle], around: nestedHandle.frame,
                                 name: "handle-nested-revealed-\(appearance == .aqua ? "light" : "dark")")
            }
            app.appearance = nil
        }
        dwellLayout = .halves
        clearDwell()

        dwellInput.realTime = true
        move(rest)
        let started = ProcessInfo.processInfo.systemUptime
        let realReveal = await observeUntil { !handles().isEmpty }
        let waited = ProcessInfo.processInfo.systemUptime - started
        expect(realReveal && waited >= DividerDwell.delay - 0.001 && waited < 1.5,
               "with the production timer a resting pointer reveals after the pause, not before", "waited \(waited)")
        dwellInput.realTime = false
        clearDwell()

        move(rest)
        let stopped = dwellInput.timers.first?.action
        dwellController.stop()
        stopped?()
        expect(handles().isEmpty && dwellInput.timers.isEmpty && dwellInput.monitorCount == 0,
               "stopping Zones cancels the pause, releases its monitor and ignores a late callback")

        if passive {
            expect(keyWindows.isEmpty && !app.isActive, "the passive run never gave a probe window keyboard focus",
                   "key windows \(keyWindows), active \(app.isActive)")
        }
        completed.append(passive ? "passiveViews" : "views")
        func controlledCapture(filter: SCContentFilter) async throws {
            enum OperationError: Error { case start, stop }
            var frameStartAck = false, frameStopAck = false
            let noFrame = SingleFrameCapture(operations: .init(start: { _ in frameStartAck = true },
                stop: { _ in frameStopAck = true }), deadlineNanoseconds: 50_000_000)
            var frameDeadline = false
            do { _ = try await noFrame.capture(filter: filter, width: 10, height: 10) }
            catch SingleFrameCaptureError.deadlineExceeded(let cause) { frameDeadline = cause == nil }
            catch { }
            let noFrameStopped = await observeUntil { noFrame.state == .stopped }
            expect(frameDeadline && frameStartAck && frameStopAck && noFrameStopped,
                   "a missing frame has a bounded deadline and this helper still receives its cleanup acknowledgment")
            let stalledStart = ProbeOperation()
            let lateStop = ProbeOperation()
            var order: [String] = []
            let bounded = SingleFrameCapture(operations: .init(start: { _ in
                order.append("start entered")
                await stalledStart.hold()
                order.append("start acknowledged")
            }, stop: { _ in await lateStop.hold(); order.append("stop acknowledged") }), deadlineNanoseconds: 50_000_000)
            let boundedTask = Task { try await bounded.capture(filter: filter, width: 10, height: 10) }
            await stalledStart.waitForEntry()
            boundedTask.cancel()
            var boundedError = false
            do { _ = try await boundedTask.value }
            catch SingleFrameCaptureError.deadlineExceeded(let cause) { boundedError = cause is CancellationError }
            catch { }
            expect(boundedError && bounded.state == .cleanupPending && order == ["start entered"],
                   "cancellation during stalled start returns a bounded pending-cleanup error, never a stopped claim")
            stalledStart.release()
            await lateStop.waitForEntry()
            lateStop.release()
            let lateStopped = await observeUntil { bounded.state == .stopped }
            expect(lateStopped && order == ["start entered", "start acknowledged", "stop acknowledged"],
                   "late start cleanup receives its stop acknowledgment after the caller deadline")
            do { _ = try await bounded.capture(filter: filter, width: 10, height: 10); expect(false, "single-use helper rejects reuse") }
            catch { expect(order == ["start entered", "start acknowledged", "stop acknowledged"],
                           "the same helper stops a late start in order without completing its caller again") }

            let stalledStop = ProbeOperation()
            let stopEnded = ProbeOperation()
            let stopping = SingleFrameCapture(operations: .init(start: { _ in throw OperationError.start }, stop: { _ in
                await stalledStop.hold()
                await stopEnded.hold()
                throw OperationError.stop
            }), deadlineNanoseconds: 50_000_000)
            let stopTask = Task { try await stopping.capture(filter: filter, width: 10, height: 10) }
            await stalledStop.waitForEntry()
            var stopBounded = false
            do { _ = try await stopTask.value }
            catch SingleFrameCaptureError.deadlineExceeded(let cause) { stopBounded = (cause as? OperationError) == .start }
            catch { }
            expect(stopBounded && stopping.state == .cleanupPending,
                   "the same deadline covers a stalled stop and preserves the preceding start error")
            stalledStop.release()
            await stopEnded.waitForEntry()
            stopEnded.release()
            let stoppedLate = await observeUntil { stopping.state == .cleanupFailed }
            expect(stoppedLate && (stopping.cleanupError as? OperationError) == .stop,
                   "a late throwing stop retains its cleanup error after the caller deadline and never claims stopped")

            var failedStops = 0
            let throwing = SingleFrameCapture(operations: .init(start: { _ in throw OperationError.start },
                stop: { _ in failedStops += 1; throw OperationError.stop }))
            var bothErrors = false
            do { _ = try await throwing.capture(filter: filter, width: 10, height: 10) }
            catch SingleFrameCaptureError.cleanupFailed(let cause, let stop) {
                bothErrors = (cause as? OperationError) == .start && (stop as? OperationError) == .stop
            } catch { }
            expect(bothErrors && failedStops == 2 && throwing.state == .cleanupFailed && (throwing.cleanupError as? OperationError) == .stop,
                   "two failed stop attempts preserve both errors and cannot become image success or stopped")
            completed.append("controlledCapture")

        }

        if passive || CommandLine.arguments.contains("--permission-free") {
            gates["axOwners"] = "separate granted run"
            gates["nativeCapture"] = "separate granted run"
            gates["controlledCapture"] = "fixture capture filter requires separate granted run"
            print("GATE: native AX effects, controller sessions and ScreenCaptureKit require the separate granted run.")
            return try terminal()
        }
        guard AXIsProcessTrusted() else {
            gates["axOwners"] = "existing Accessibility grant unavailable"
            gates["nativeCapture"] = "AX fixture identity prerequisite unavailable"
            gates["controlledCapture"] = "fixture capture filter unavailable"
            print("GATE: existing Accessibility grant unavailable. No permission was requested.")
            return try terminal()
        }

        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("lineup-zones-fixture-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        var children: [Process] = []
        defer {
            for child in children where child.isRunning { child.terminate(); child.waitUntilExit() }
            SnapMemory.shared.reset()
        }
        func launchFixture(_ directory: URL, windows: Int) throws -> (Process, pid_t, [UInt32])? {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
            process.arguments = ["--fixture", directory.path, String(windows)]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            children.append(process)
            let ready = directory.appendingPathComponent("ready.json")
            let deadline = Date(timeIntervalSinceNow: 8)
            while !FileManager.default.fileExists(atPath: ready.path), process.isRunning, Date() < deadline { pump(0.01) }
            guard let data = try? Data(contentsOf: ready),
                  let manifest = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let pid = manifest["pid"] as? Int32, pid == process.processIdentifier,
                  let ids = manifest["ids"] as? [UInt32] else { return nil }
            print("Fixture settings. PID \(pid), IDs \(ids), hasShadow \(manifest["hasShadow"] ?? "unavailable")")
            return (process, pid, ids)
        }
        var commandNumber = 0
        func command(_ text: String, in directory: URL = temporary) -> Bool {
            commandNumber += 1
            let name = String(format: "%03d", commandNumber)
            try? Data(text.utf8).write(to: directory.appendingPathComponent(name + ".request"))
            let deadline = Date(timeIntervalSinceNow: 4)
            while !FileManager.default.fileExists(atPath: directory.appendingPathComponent(name + ".ready").path),
                  Date() < deadline { pump(0.01) }
            return FileManager.default.fileExists(atPath: directory.appendingPathComponent(name + ".ready").path)
        }
        guard case let (_, pid, ids)? = try launchFixture(temporary, windows: 3) else {
            expect(false, "fixture compositor readiness"); return nil
        }
        let owned = (WindowMover.visibleWindows(pids: [pid]) ?? []).filter { ids.contains($0.id) }.sorted { $0.id < $1.id }
        print("Fixture matching. PID \(pid), IDs \(ids), rows \(owned.map { "\($0.id):AX=\($0.window != nil)" })")
        guard owned.count == 3, let a = owned[0].window, let b = owned[1].window, let c = owned[2].window else {
            expect(false, "uniquely match only whitelisted fixture windows"); return nil
        }
        func isFixture(_ window: AXUIElement) -> Bool {
            var owner: pid_t = 0
            return AXUIElementGetPid(window, &owner) == .success && owner == pid
        }
        func frame(_ window: AXUIElement) -> CGRect { WindowMover.frame(of: window) ?? .null }
        func near(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
            SnapRecords<AXUIElement>.matches(lhs, rhs, originTolerance: 1, sizeTolerance: 1)
        }
        let info = ScreenIdentity.info(for: screen)
        let display = AppZonePlacement.Display(key: info.key, frame: screen.frame, visibleFrame: visible, pixelsWide: info.pixelsWide)
        var layout = Node.halves
        var saves: [Node] = []
        let saveFile = temporary.appendingPathComponent("layout.json")
        func zone(_ index: Int, _ root: Node = layout) -> CGRect {
            Layout.zoneRect(index: index, root: root, frame: screen.frame, visibleFrame: visible, pixelsWide: info.pixelsWide)!
        }
        func seed(_ window: AXUIElement, zone index: Int) -> Bool {
            guard isFixture(window) else { return false }
            let target = zone(index)
            let placement = AppZonePlacement(screenKey: info.key, layout: layout, target: target, frame: screen.frame,
                                             visibleFrame: visible, pixelsWide: info.pixelsWide)
            return WindowMover.commit([FrameEffect(window: window, before: frame(window), after: target, placement: placement)],
                                      validate: { true }, persist: {}).isCommitted
        }
        expect(WindowMover.canFitExactly(a) && WindowMover.canFitExactly(b) && WindowMover.canFitExactly(c),
               "native regular-window and exact-setter eligibility")
        expect(seed(c, zone: 0) && seed(a, zone: 0) && seed(b, zone: 1),
               "seed ordinary-shadow fixtures with two same-app windows occupying one identical full leaf")
        let duplicateIdentity = await observeUntil {
            let rows = WindowMover.visibleWindows(pids: [pid]) ?? []
            return near(frame(a), frame(c)) && rows.filter { $0.id == ids[0] || $0.id == ids[2] }.count == 2
                && rows.filter { $0.id == ids[0] || $0.id == ids[2] }.allSatisfy { $0.window == nil }
                && rows.first(where: { $0.id == ids[1] })?.window.map { CFEqual($0, b) } == true
        }
        expect(duplicateIdentity, "two-way same-app uniqueness rejects both overlapping identities and keeps the separate window matched")
        expect(command("hide 2") && command("front"),
               "hide only the duplicate fixture, retaining its remembered full-leaf record")
        expect(!(WindowMover.visibleWindows(pids: [pid]) ?? []).contains { $0.window.map { CFEqual($0, c) } == true },
               "the hidden fixture is not on screen")

        var additionalFixture: (pid: pid_t, ids: [UInt32])?
        func fixtureWindows(_ requested: Set<pid_t>?) -> [WindowMover.VisibleWindow]? {
            let allowed = Set([pid] + (additionalFixture.map { [$0.pid] } ?? []))
            return WindowMover.visibleWindows(pids: requested.map { $0.intersection(allowed) } ?? allowed)?
                .filter { row in (row.pid == pid && ids.contains(row.id))
                    || (additionalFixture.map { row.pid == $0.pid && $0.ids.contains(row.id) } ?? false) }
        }
        func observeShadowBounds(_ stage: String, windows: [(UInt32, AXUIElement)] = []) throws {
            let start = ProcessInfo.processInfo.systemUptime
            let deadline = start + 2
            var samples = 0
            var changes: [[String: Any]] = []
            var previous = ""
            var last: [[String: Any]] = []
            repeat {
                let list = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? []
                last = (windows.isEmpty ? [(ids[0], a), (ids[1], b)] : windows).compactMap { id, window in
                    guard let row = list.first(where: { $0[kCGWindowOwnerPID as String] as? Int32 == pid
                        && $0[kCGWindowNumber as String] as? UInt32 == id }),
                          let bounds = row[kCGWindowBounds as String] as? [String: Any],
                          let cg = CGRect(dictionaryRepresentation: bounds as CFDictionary),
                          let axCocoa = WindowMover.frame(of: window) else { return nil }
                    let surface = Coord.cocoaRect(fromAX: cg, primaryMaxY: NSScreen.screens[0].frame.maxY)
                    let ax = Coord.axRect(fromCocoa: axCocoa, primaryMaxY: NSScreen.screens[0].frame.maxY)
                    return ["pid": pid, "id": id, "cgBounds": NSStringFromRect(cg), "axBounds": NSStringFromRect(ax),
                            "surfaceCocoa": NSStringFromRect(surface), "axCocoa": NSStringFromRect(axCocoa),
                            "borders": [surface.minX - axCocoa.minX, surface.minY - axCocoa.minY,
                                        axCocoa.maxX - surface.maxX, axCocoa.maxY - surface.maxY],
                            "matches": WindowIdentityGeometry.matches(surface: surface, accessibility: axCocoa)]
                }
                samples += 1
                let signature = String(decoding: try JSONSerialization.data(withJSONObject: last, options: [.sortedKeys]), as: UTF8.self)
                if signature != previous {
                    changes.append(["elapsed": ProcessInfo.processInfo.systemUptime - start, "windows": last])
                    print("Default-shadow \(stage) bounds change. \(signature)")
                    previous = signature
                }
                pump(0.005)
            } while ProcessInfo.processInfo.systemUptime < deadline
            let evidence: [String: Any] = ["stage": stage, "fixturePID": pid, "windowIDs": ids,
                "fixtureManifest": try JSONSerialization.jsonObject(with: Data(contentsOf: temporary.appendingPathComponent("ready.json"))),
                "elapsed": ProcessInfo.processInfo.systemUptime - start, "samples": samples, "changes": changes, "final": last]
            print("Default-shadow \(stage) bounded observation. samples \(samples), changes \(changes.count), final \(previous)")
            if let output {
                try JSONSerialization.data(withJSONObject: evidence, options: [.prettyPrinted, .sortedKeys])
                    .write(to: output.appendingPathComponent("ordinary-shadow-\(stage).json"), options: .atomic)
            }
        }
        try observeShadowBounds("initial-snap")
        func requireReady() -> Bool {
            let deadline = Date(timeIntervalSinceNow: 2)
            while Date() < deadline {
                let current = fixtureWindows(nil) ?? []
                let entries = SnapMemory.shared.records.entries.filter { CFEqual($0.window, a) || CFEqual($0.window, b) }
                if entries.count == 2 && entries.allSatisfy({ WindowMover.observe($0, in: current) == .current }) { return true }
                pump(0.005)
            }
            expect(false, "fixture CG/AX readiness deadline before an ordinary divider case")
            return false
        }
        let input = ProbeInput()
        var assistEnabled = false
        var censusMode = "current"
        var sequentialCapture = false
        var sequentialStarts = 0, sequentialStops = 0
        let firstCandidateCapture = ProbeOperation()
        enum SuggestionCaptureError: Error { case noFrame }
        let controller = DragSnapController(
            configProvider: { LineupConfig(defaultLayout: layout) },
            triggerProvider: { .default },
            onPlacement: { _, _, _ in },
            commitDivider: { _, old, new, effects in
                let outcome = WindowMover.commit(effects, validate: { layout == old }, persist: {
                    try JSONEncoder().encode(new).write(to: saveFile, options: .atomic)
                })
                if outcome.isCommitted {
                    saves.append(new)
                    SnapMemory.shared.records.rebasePlacements(on: display, old: old, new: new)
                    layout = new
                }
                return outcome
            },
            assistAllowed: { assistEnabled && CGPreflightScreenCaptureAccess() },
            input: input.source(), visibleWindows: { requested in
                if censusMode == "unavailable" { return nil }
                let rows = fixtureWindows(requested)
                if censusMode == "remembered-ambiguous" {
                    return rows?.map { row in
                        row.pid == additionalFixture?.pid
                            ? WindowMover.VisibleWindow(id: row.id, pid: row.pid, frame: row.frame,
                                window: nil, appName: row.appName, title: row.title) : row
                    }
                }
                if censusMode == "ambiguous" {
                    return rows?.map { row in
                        WindowMover.VisibleWindow(id: row.id, pid: row.pid, frame: row.frame.offsetBy(dx: 25, dy: 0),
                            window: nil, appName: row.appName, title: row.title)
                    }
                }
                return sequentialCapture ? rows?.sorted { $0.id < $1.id } : rows
            }, captureOperations: .init(start: { stream in
                if sequentialCapture {
                    sequentialStarts += 1
                    if sequentialStarts == 1 { await firstCandidateCapture.hold() }
                    throw SuggestionCaptureError.noFrame
                }
                try await stream.startCapture()
            }, stop: { stream in
                if sequentialCapture { sequentialStops += 1; return }
                try await stream.stopCapture()
            }))
        controller.start()
        defer { controller.stop() }
        func window<T: NSWindow>(_ type: T.Type) -> [T] { app.windows.compactMap { $0 as? T }.filter(\.isVisible) }

        func beginDrag(_ window: AXUIElement, modifiers: NSEvent.ModifierFlags = .shift) -> CGPoint? {
            let start = CGPoint(x: frame(window).midX, y: frame(window).maxY - 14)
            let hit = WindowMover.window(atCocoaPoint: start)
            var hitPID: pid_t = -1
            if let hit { AXUIElementGetPid(hit, &hitPID) }
            let point = Coord.axRect(fromCocoa: CGRect(origin: start, size: .zero), primaryMaxY: NSScreen.screens[0].frame.maxY).origin
            let covering = (CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? []).filter {
                guard let bounds = $0[kCGWindowBounds as String] as? [String: Any],
                      let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary) else { return false }
                return rect.contains(point)
            }.prefix(1).map { row -> [String: Any] in
                let owner = row[kCGWindowOwnerPID as String] as? Int32 ?? -1
                let id = row[kCGWindowNumber as String] as? UInt32 ?? 0
                return ["pid": owner, "id": id, "known": owner == getpid() || (owner == pid && ids.contains(id)),
                        "layer": row[kCGWindowLayer as String] ?? -1]
            }
            print("Exact AX prerequisite. point \(start), hitPID \(hitPID), exact \(hit.map { CFEqual($0, window) } ?? false), covering \(covering)")
            guard let hit, isFixture(hit), CFEqual(hit, window) else {
                print("Drag prerequisite did not match the exact fixture at \(start). Source frame \(frame(window)).")
                return nil
            }
            input.modifiers = modifiers
            input.deliver(.leftMouseDown, at: start)
            input.deliver(.leftMouseDragged, at: CGPoint(x: start.x - 12, y: start.y))
            return start
        }
        let zoneOne = zone(0)
        let tiles = ShareTarget.targets(in: zoneOne)
        func enterShareTile() {
            input.deliver(.leftMouseDragged, at: CGPoint(x: tiles[0].rect.midX, y: tiles[0].rect.minY - 60))
            input.deliver(.leftMouseDragged, at: CGPoint(x: tiles[0].rect.midX, y: tiles[0].rect.midY))
        }
        func fixtureFrame(_ index: Int) -> CGRect {
            guard command("report"), let data = try? Data(contentsOf: temporary.appendingPathComponent("frames.json")),
                  let frames = try? JSONSerialization.jsonObject(with: data) as? [[Double]], frames.indices.contains(index)
            else { return .null }
            let f = frames[index]
            return CGRect(x: f[0], y: f[1], width: f[2], height: f[3])
        }
        guard requireReady() else { return nil }
        do {
            let history = SnapMemory.shared.records
            let snapped = frame(b)
            guard let pre = history.entry(b)?.preFrame else {
                expect(false, "drag-away fixture has an original pre-snap frame"); return nil
            }
            var dragTrace: [[String: Any]] = []
            var dragCase = "setup"
            var dragFailureNumber = 0
            func traceDrag(_ stage: String, current: CGRect? = nil, publication: [WindowMover.VisibleWindow]? = nil) {
                let fields: Set<String> = ["dragStart", "dragSuppressed", "captured", "armed",
                    "restoreChecked", "restoreCandidate", "restoreSampling"]
                let state = Dictionary(uniqueKeysWithValues: Mirror(reflecting: controller).children.compactMap { child -> (String, String)? in
                    guard let label = child.label, fields.contains(label) else { return nil }
                    return (label, String(describing: child.value))
                })
                let records: [[String: Any]] = SnapMemory.shared.records.entries.map { entry in
                    let index = [a, b, c].firstIndex { CFEqual($0, entry.window) }
                    return ["fixtureID": index.map { ids[$0] } ?? 0, "preFrame": NSStringFromRect(entry.preFrame),
                            "snappedTo": NSStringFromRect(entry.snappedTo)]
                }
                var sample: [String: Any] = ["stage": stage, "inputNow": input.now,
                    "systemUptime": ProcessInfo.processInfo.systemUptime, "realTime": input.realTime,
                    "pointer": NSStringFromPoint(input.pointer), "buttons": input.buttons,
                    "modifiers": input.modifiers.rawValue, "monitorCount": input.monitorCount,
                    "timers": input.timers.map { ["id": Double($0.id), "due": $0.due, "delay": $0.delay] },
                    "controller": state, "records": records]
                if let current { sample["currentFrame"] = NSStringFromRect(current) }
                if let publication {
                    sample["fixturePublication"] = publication.map { row -> [String: Any] in
                        ["id": row.id, "pid": row.pid, "frame": NSStringFromRect(row.frame),
                         "exactFixture": row.window.map { CFEqual($0, b) } ?? false]
                    }
                }
                dragTrace.append(sample)
                if dragTrace.count > 64 { dragTrace.removeFirst(dragTrace.count - 64) }
            }
            func expectDrag(_ condition: Bool, _ message: String) {
                if !condition {
                    dragFailureNumber += 1
                    traceDrag("failure-before-fixture-report", current: frame(b))
                    let hits: [[String: Any]] = [input.pointer,
                        CGPoint(x: frame(b).midX, y: frame(b).maxY - 14)].map { point in
                        let hit = WindowMover.window(atCocoaPoint: point)
                        var owner: pid_t = -1
                        if let hit { AXUIElementGetPid(hit, &owner) }
                        return ["point": NSStringFromPoint(point), "pid": owner,
                                "exactFixture": hit.map { CFEqual($0, b) } ?? false]
                    }
                    func cgRows(_ option: CGWindowListOption) -> [[String: Any]] {
                        (CGWindowListCopyWindowInfo(option, kCGNullWindowID) as? [[String: Any]] ?? []).filter {
                            $0[kCGWindowOwnerPID as String] as? Int32 == pid
                                && ids.contains($0[kCGWindowNumber as String] as? UInt32 ?? 0)
                        }.map { row in
                            ["id": row[kCGWindowNumber as String] ?? 0, "bounds": row[kCGWindowBounds as String] ?? [:],
                             "layer": row[kCGWindowLayer as String] ?? -1, "onscreen": row[kCGWindowIsOnscreen as String] ?? false]
                        }
                    }
                    let fixture = children.first { $0.processIdentifier == pid }
                    let running = fixture?.isRunning == true
                    var diagnostic: [String: Any] = ["case": dragCase, "failure": message,
                        "fixturePID": pid, "fixtureIDs": ids, "fixtureRunning": running,
                        "preFrame": NSStringFromRect(pre), "originalSnappedFrame": NSStringFromRect(snapped),
                        "axFrames": [a, b, c].map { NSStringFromRect(frame($0)) }, "hits": hits,
                        "cgAll": cgRows(.optionAll), "cgOnscreen": cgRows(.optionOnScreenOnly)]
                    if let fixture, !running { diagnostic["fixtureExitStatus"] = fixture.terminationStatus }
                    diagnostic["fixtureReportedFrame"] = NSStringFromRect(fixtureFrame(1))
                    traceDrag("failure-after-fixture-report", current: frame(b))
                    diagnostic["trace"] = dragTrace
                    do {
                        let data = try JSONSerialization.data(withJSONObject: diagnostic, options: [.prettyPrinted, .sortedKeys])
                        if let output {
                            let path = output.appendingPathComponent("drag-away-\(dragCase.replacingOccurrences(of: " ", with: "-"))-failure-\(dragFailureNumber).json")
                            try data.write(to: path, options: .atomic)
                            print("Drag-away failure diagnostic. \(path.path)")
                        } else { print("Drag-away failure diagnostic. \(String(decoding: data, as: UTF8.self))") }
                    } catch { print("Drag-away failure diagnostic could not be written. \(error)") }
                }
                expect(condition, message)
            }
            defer {
                controller.cancelSessions()
                input.buttons = 0
                input.modifiers = .shift
                expect(command("frame 1 \(snapped.minX) \(snapped.minY) \(snapped.width) \(snapped.height)"),
                       "put back the drag-away fixture before the existing owner cases")
                SnapMemory.shared.records = history
            }
            func setDragFrame(_ rect: CGRect) async -> Bool {
                traceDrag("before-fixture-frame-\(NSStringFromRect(rect))")
                guard command("frame 1 \(rect.minX) \(rect.minY) \(rect.width) \(rect.height)") else { return false }
                var observed = CGRect.null
                let ready = await observeUntil { observed = frame(b); return near(observed, rect) }
                traceDrag("after-fixture-frame", current: observed, publication: fixtureWindows([pid]))
                return ready
            }
            func prepareDragAway(_ target: CGRect) async -> CGPoint? {
                controller.cancelSessions()
                traceDrag("prepare-cancelled-target-\(NSStringFromRect(target))")
                guard await setDragFrame(pre) else {
                    expectDrag(false, "drag-away fixture accepts its original frame"); return nil
                }
                SnapMemory.shared.forget(b)
                let placement = AppZonePlacement(screenKey: info.key, layout: layout, target: target,
                    frame: screen.frame, visibleFrame: visible, pixelsWide: info.pixelsWide)
                guard WindowMover.commit([FrameEffect(window: b, before: pre, after: target, placement: placement)],
                        validate: { true }, persist: {}).isCommitted else {
                    expectDrag(false, "production mover seeds the drag-away fixture"); return nil
                }
                var publication: [WindowMover.VisibleWindow]?
                let ready = await observeUntil {
                    publication = fixtureWindows([pid])
                    let current = frame(b)
                    guard near(current, target), let entry = SnapMemory.shared.records.entry(b),
                          let rows = publication,
                          rows.contains(where: { $0.id == ids[1] && $0.pid == pid
                              && $0.window.map { CFEqual($0, b) } == true }),
                          WindowMover.observe(entry, in: rows) == .current else { return false }
                    let start = CGPoint(x: current.midX, y: current.maxY - 14)
                    guard let hit = WindowMover.window(atCocoaPoint: start) else { return false }
                    return isFixture(hit) && CFEqual(hit, b)
                }
                traceDrag("before-begin-drag", publication: publication)
                guard ready, let start = beginDrag(b, modifiers: []) else {
                    expectDrag(false, "drag-away starts on the exact snapped fixture"); return nil
                }
                input.buttons = 1
                traceDrag("after-begin-drag")
                return start
            }
            let leaf = zone(1)
            let sharedHalf = CGRect(x: leaf.midX, y: leaf.minY, width: leaf.width / 2, height: leaf.height)
            for (name, target) in [("whole leaf", leaf), ("shared half", sharedHalf)] {
                dragCase = name
                dragTrace.removeAll(keepingCapacity: true)
                guard let start = await prepareDragAway(target) else { return nil }
                let pointer = CGPoint(x: start.x - 40, y: start.y - 10)
                var stationary = true
                for _ in 0..<8 {
                    input.elapse(0.025)
                    traceDrag("stationary-after-elapse")
                    input.deliver(.leftMouseDragged, at: pointer)
                    if stationary {
                        let current = frame(b)
                        stationary = near(current, target) && SnapMemory.shared.records.entry(b)?.preFrame == pre
                        traceDrag("stationary-after-drag", current: current)
                    } else { traceDrag("stationary-after-drag") }
                }
                expectDrag(stationary, "\(name) retains its snapped frame and history across eight stationary AX observations")
                let moved = target.offsetBy(dx: -20, dy: -10)
                guard await setDragFrame(moved) else { expectDrag(false, "move only the drag-away fixture"); return nil }
                input.elapse(0.001)
                traceDrag("one-ms-after-elapse")
                input.deliver(.leftMouseDragged, at: pointer)
                let immediateFrame = frame(b)
                traceDrag("one-ms-after-drag", current: immediateFrame)
                expectDrag(near(immediateFrame, moved) && SnapMemory.shared.records.entry(b)?.preFrame == pre,
                       "\(name) spaces AX sampling even when another drag event arrives immediately")
                input.elapse(0.025)
                traceDrag("restore-after-elapse")
                input.deliver(.leftMouseDragged, at: pointer)
                traceDrag("restore-after-drag")
                var current = CGRect.null
                let restored = await observeUntil {
                    current = frame(b)
                    return abs(current.width - pre.width) <= 1 && abs(current.height - pre.height) <= 1
                }
                traceDrag("restore-observation-ended", current: current)
                expectDrag(restored && SnapMemory.shared.records.entry(b) == nil,
                       "\(name) restores the original size after delayed AX movement within the grace period")
                input.deliver(.leftMouseUp)
            }

            guard let start = await prepareDragAway(leaf) else { return nil }
            let pointer = CGPoint(x: start.x - 40, y: start.y - 10)
            input.deliver(.leftMouseDragged, at: pointer)
            input.elapse(0.6)
            expect(near(frame(b), leaf) && SnapMemory.shared.records.entry(b)?.preFrame == pre,
                   "a content drag never resizes the stationary fixture")
            let lateMove = leaf.offsetBy(dx: -20, dy: -10)
            guard await setDragFrame(lateMove) else { expect(false, "move the fixture after grace expires"); return nil }
            input.elapse(0.025)
            input.deliver(.leftMouseDragged, at: pointer)
            expect(near(frame(b), lateMove) && SnapMemory.shared.records.entry(b)?.preFrame == pre,
                   "elapsed grace stops restoration even when later AX movement becomes visible")
            input.deliver(.leftMouseUp)

            guard let resizeStart = await prepareDragAway(leaf) else { return nil }
            let resizePointer = CGPoint(x: resizeStart.x - 40, y: resizeStart.y - 10)
            let resized = CGRect(x: leaf.minX - 20, y: leaf.minY, width: leaf.width + 20, height: leaf.height)
            guard await setDragFrame(resized) else { expect(false, "resize only the drag-away fixture"); return nil }
            input.elapse(0.025)
            input.deliver(.leftMouseDragged, at: resizePointer)
            expect(near(frame(b), resized) && SnapMemory.shared.records.entry(b)?.preFrame == pre,
                   "a changed size refuses drag-away restoration even with origin movement")
            guard await setDragFrame(lateMove) else { expect(false, "return fixture size after resize"); return nil }
            input.elapse(0.025)
            input.deliver(.leftMouseDragged, at: resizePointer)
            expect(near(frame(b), lateMove) && SnapMemory.shared.records.entry(b)?.preFrame == pre,
                   "a resize remains refused for the rest of its drag after its original snapped size returns")
            input.deliver(.leftMouseUp)
        }
        guard requireReady() else { return nil }
        let aShared = frame(a), bShared = frame(b), cHidden = fixtureFrame(2)
        let shareDirectory = temporary.appendingPathComponent("share-ambiguity")
        guard let (shareProcess, sharePID, shareIDs) = try launchFixture(shareDirectory, windows: 1),
              let shareOther = WindowMover.visibleWindows(pids: [sharePID])?.first(where: { shareIDs.contains($0.id) })?.window else {
            expect(false, "resolve an additional whitelisted live share fixture"); return nil
        }
        additionalFixture = (sharePID, shareIDs)
        let otherBefore = frame(shareOther)
        let otherPlacement = AppZonePlacement(screenKey: info.key, layout: layout, target: zone(1),
            frame: screen.frame, visibleFrame: visible, pixelsWide: info.pixelsWide)
        expect(WindowMover.commit([FrameEffect(window: shareOther, before: otherBefore, after: zone(1), placement: otherPlacement)],
            validate: { true }, persist: {}).isCommitted, "snap the additional live remembered fixture into the other leaf")
        let otherFrame = frame(shareOther)
        let otherReady = await observeUntil {
            SnapMemory.shared.records.entry(shareOther).map { WindowMover.observe($0, in: fixtureWindows(nil)) == .current } == true
        }
        expect(otherReady && near(otherFrame, zone(1)), "additional remembered fixture is eligible and positively current before ambiguity")
        expect(command("front"), "keep the incoming fixture title bar above the additional own fixture")
        let shareHitReady = await observeUntil {
            let point = CGPoint(x: frame(b).midX, y: frame(b).maxY - 14)
            guard let hit = WindowMover.window(atCocoaPoint: point) else { return false }
            return isFixture(hit) && CFEqual(hit, b)
        }
        expect(shareHitReady, "fixture front ordering settles to an exact title-bar AX hit before share input")
        let shareHistory = SnapMemory.shared.records.entries
        func unchangedShareHistory() -> Bool {
            let current = SnapMemory.shared.records.entries
            return current.count == shareHistory.count && zip(current, shareHistory).allSatisfy { current, before in
                CFEqual(current.window, before.window) && current.preFrame == before.preFrame && current.snappedTo == before.snappedTo
                    && current.placement == before.placement && current.maximize?.before == before.maximize?.before
                    && current.maximize?.applied == before.maximize?.applied && current.maximize?.screenKey == before.maximize?.screenKey
            }
        }
        for mode in ["unavailable", "remembered-ambiguous"] {
            censusMode = mode
            if mode == "remembered-ambiguous" {
                let rows = fixtureWindows(nil)?.map { row in
                    row.pid == sharePID ? WindowMover.VisibleWindow(id: row.id, pid: row.pid, frame: row.frame,
                        window: nil, appName: row.appName, title: row.title) : row
                }
                expect(SnapMemory.shared.records.entry(a).map { WindowMover.observe($0, in: rows) == .current } == true
                        && SnapMemory.shared.records.entry(shareOther).map { WindowMover.observe($0, in: rows) == .unresolved } == true,
                       "share ambiguity keeps a current whole-leaf incumbent plus another unresolved remembered record")
            }
            guard beginDrag(b) != nil else { expect(false, "start share drag for \(mode)"); return nil }
            enterShareTile()
            expect(window(ShareRailPanel.self).isEmpty && near(frame(a), aShared) && near(frame(b), bShared)
                    && frame(shareOther) == otherFrame && fixtureFrame(2) == cHidden && unchangedShareHistory() && saves.isEmpty,
                   "actual share owner suppresses \(mode) admission without coordinated movement or history changes")
            input.deliver(.keyDown, keyCode: 53)
            input.deliver(.leftMouseUp)
            expect(window(ShareRailPanel.self).isEmpty && near(frame(a), aShared) && near(frame(b), bShared)
                    && frame(shareOther) == otherFrame && fixtureFrame(2) == cHidden && unchangedShareHistory(),
                   "explicit cancellation of the \(mode) share probe preserves every fixture and history")
        }
        censusMode = "current"
        guard beginDrag(b) != nil else { expect(false, "start the resolved share admission counterpart"); return nil }
        enterShareTile()
        expect(window(ShareRailPanel.self).count == 1 && near(frame(a), aShared) && near(frame(b), bShared)
                && frame(shareOther) == otherFrame && unchangedShareHistory(),
               "ordinary resolved census admits the share rail with the same remembered eligible neighbor")
        input.deliver(.keyDown, keyCode: 53)
        input.deliver(.leftMouseUp)
        censusMode = "remembered-ambiguous"
        let lineBeforeSnap = Layout.dividerHandles(layout, container: Layout.rootContainer(frame: screen.frame, visibleFrame: visible),
                                                   pixelsWide: info.pixelsWide, thickness: 24)[0]
        input.deliver(.mouseMoved, at: CGPoint(x: lineBeforeSnap.line.midX, y: visible.midY))
        let pausedBeforeSnap = input.timers.count
        guard beginDrag(b) != nil else { expect(false, "start ordinary fallback with unresolved sharing"); return nil }
        input.deliver(.leftMouseDragged, at: CGPoint(x: zoneOne.midX, y: zoneOne.midY))
        input.deliver(.leftMouseUp)
        input.elapse(DividerDwell.delay)
        expect(pausedBeforeSnap == 1 && input.timers.isEmpty && window(DividerGripPanel.self).isEmpty,
               "a pause pending on a line is cancelled by the press and never delays or hijacks the snap")
        expect(near(frame(b), zoneOne) && near(frame(a), aShared) && fixtureFrame(2) == cHidden
                && frame(shareOther) == otherFrame
                && SnapMemory.shared.records.entry(shareOther)?.preFrame == otherBefore
                && SnapMemory.shared.records.entry(shareOther)?.snappedTo == otherFrame
                && SnapMemory.shared.records.entry(a)?.preFrame == shareHistory.first(where: { CFEqual($0.window, a) })?.preFrame
                && SnapMemory.shared.records.entry(c)?.snappedTo == shareHistory.first(where: { CFEqual($0.window, c) })?.snappedTo
                && SnapMemory.shared.records.entry(b)?.preFrame == shareHistory.first(where: { CFEqual($0.window, b) })?.preFrame
                && window(ShareRailPanel.self).isEmpty && saves.isEmpty,
               "unresolved sharing preserves the ordinary single-window whole-zone snap fallback and neighbor history")
        expect(seed(b, zone: 1), "restore the incoming fixture for the ordinary positive share counterpart")
        SnapMemory.shared.records.forget(shareOther)
        shareProcess.terminate(); shareProcess.waitUntilExit()
        additionalFixture = nil
        censusMode = "current"
        controller.cancelSessions()
        guard requireReady() else { return nil }
        guard beginDrag(b) != nil else {
            gates["axOwners"] = "fixture title bar covered before owner cases"
            gates["nativeCapture"] = "fixture owner prerequisite unavailable"
            gates["controlledCapture"] = "fixture capture filter unavailable"
            print("GATE: another window covers the fixture title bar, so the owner drag cases were not run.")
            return try terminal()
        }
        enterShareTile()
        print("Share observations. \(fixtureWindows(nil)?.map { "\($0.id):\($0.frame):AX=\($0.window != nil)" } ?? [])")
        print("Share records. \(SnapMemory.shared.records.entries.map { "\(frame($0.window)) recorded \($0.snappedTo), leaf \(String(describing: $0.placement?.zoneIndex)), eligible \(WindowMover.canFitExactly($0.window))" })")
        let rails = window(ShareRailPanel.self)
        expect(rails.count == 1 && window(HighlightWindow.self).contains { near($0.frame, CGRect(x: zoneOne.midX, y: zoneOne.minY,
                                                                                               width: zoneOne.width / 2, height: zoneOne.height)) },
               "with a stale record in the zone, the visible incumbent still offers Share zone and previews both halves")
        input.deliver(.keyDown, keyCode: 53)
        input.deliver(.leftMouseDragged, at: CGPoint(x: tiles[0].rect.midX + 1, y: tiles[0].rect.midY))
        input.deliver(.leftMouseUp)
        expect(near(frame(a), aShared) && near(frame(b), bShared) && window(ShareRailPanel.self).isEmpty,
               "a short Escape keyDown cancels the share drag and its release moves nothing")

        guard beginDrag(b) != nil else { expect(false, "restart the share drag on the fixture"); return nil }
        enterShareTile()
        expect(command("move 0 37"), "fixture moves the incumbent externally between preview and release")
        input.deliver(.leftMouseUp)
        let refused = window(ZoneNoticePanel.self).first
        expect(near(frame(b), bShared) && near(frame(a), aShared.offsetBy(dx: 37, dy: 0))
                && refused.map { texts($0) == ["Couldn’t apply this change", "Windows or the layout changed. Nothing moved."] } == true
                && refused.map { $0.ignoresMouseEvents && !$0.isKeyWindow } == true,
               "a changed incumbent refuses the share with a passive notice and no fallback snap")
        if let refused { try capture(refused, name: "notice-share-changed") }
        expect(command("move 0 -37") && near(frame(a), aShared), "fixture returns the incumbent to its recorded frame")
        guard requireReady() else { return nil }
        controller.cancelSessions()
        let shareNoticeGone = await observeUntil { window(ZoneNoticePanel.self).isEmpty }
        expect(shareNoticeGone, "the prior share refusal dismisses before the next ordinary gesture")

        guard beginDrag(b) != nil else { expect(false, "restart the share drag on the fixture"); return nil }
        enterShareTile()
        input.deliver(.leftMouseUp)
        pump(0.3)
        let left = CGRect(x: zoneOne.minX, y: zoneOne.minY, width: zoneOne.width / 2, height: zoneOne.height)
        let right = CGRect(x: zoneOne.midX, y: zoneOne.minY, width: zoneOne.width / 2, height: zoneOne.height)
        expect(near(frame(a), left) && near(frame(b), right) && fixtureFrame(2) == cHidden && window(ZoneNoticePanel.self).isEmpty,
               "release shares the zone: incumbent left, incoming right, the hidden record untouched",
               "a \(frame(a)) b \(frame(b)) c \(fixtureFrame(2)) was \(cHidden) want \(left) \(right) notices \(window(ZoneNoticePanel.self).map { texts($0) })")
        try observeShadowBounds("share")

        guard let handle = Layout.dividerHandles(layout, container: Layout.rootContainer(frame: screen.frame, visibleFrame: visible),
                                                 pixelsWide: info.pixelsWide, thickness: 24).first else {
            expect(false, "halves layout has a root divider"); return nil
        }
        let reveal = CGPoint(x: handle.line.midX + 4, y: handle.container.midY)
        func discoverGrip(_ point: CGPoint = reveal) -> DividerGripPanel? {
            input.modifiers = .shift
            input.deliver(.mouseMoved, at: point)
            input.elapse(DividerDwell.delay)
            return window(DividerGripPanel.self).first
        }
        func mouse(_ type: NSEvent.EventType, _ point: CGPoint, to panel: NSWindow) {
            guard let event = NSEvent.mouseEvent(with: type, location: panel.convertPoint(fromScreen: point),
                                                 modifierFlags: input.modifiers, timestamp: ProcessInfo.processInfo.systemUptime,
                                                 windowNumber: panel.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                                                 pressure: type == .leftMouseUp ? 0 : 1) else { return }
            panel.sendEvent(event)
        }
        func arm(_ grip: DividerGripPanel) -> CGPoint {
            let center = CGPoint(x: grip.frame.midX, y: grip.frame.midY)
            input.deliver(.mouseMoved, at: center)
            return center
        }
        guard requireReady() else { return nil }
        for mode in ["unavailable", "ambiguous", "release-unavailable", "release-ambiguous"] {
            let originalFrames = (frame(a), frame(b))
            let originalHistory = SnapMemory.shared.records.entry(a)?.preFrame
            censusMode = mode.hasPrefix("release-") ? "current" : mode
            guard let probeGrip = discoverGrip() else { expect(false, "reveal for unknown observation"); return nil }
            let point = arm(probeGrip)
            mouse(.leftMouseDown, point, to: probeGrip)
            mouse(.leftMouseDragged, CGPoint(x: point.x + 80, y: point.y), to: probeGrip)
            if mode.hasPrefix("release-") { censusMode = String(mode.dropFirst(8)) }
            mouse(.leftMouseUp, CGPoint(x: point.x + 80, y: point.y), to: probeGrip)
            expect(saves.isEmpty && layout == .halves && near(frame(a), originalFrames.0) && near(frame(b), originalFrames.1)
                    && SnapMemory.shared.records.entry(a)?.preFrame == originalHistory
                    && window(ZoneNoticePanel.self).first.map { texts($0).first == "Couldn’t apply this change" } == true,
                   "actual controller refuses \(mode) census before effects/save and retains Restore history")
            controller.cancelSessions()
            let cleared = await observeUntil { window(ZoneNoticePanel.self).isEmpty }
            expect(cleared, "unknown-observation notice completes dismissal before the next fixture case")
            censusMode = "current"
        }

        let frozenBefore = (frame(a), frame(b))
        expect(command("move 1 37"), "fixture positively moves one participant before admission")
        guard let excludedAtPress = discoverGrip() else { expect(false, "reveal for frozen excluded identity"); return nil }
        let excludedPoint = arm(excludedAtPress)
        mouse(.leftMouseDown, excludedPoint, to: excludedAtPress)
        mouse(.leftMouseDragged, CGPoint(x: excludedPoint.x + 80, y: excludedPoint.y), to: excludedAtPress)
        expect(command("move 1 -37"), "fixture returns the excluded participant after the divider freezes identities")
        let reappeared = await observeUntil {
            guard let entry = SnapMemory.shared.records.entry(b) else { return false }
            return WindowMover.observe(entry, in: fixtureWindows(nil)) == .current
        }
        mouse(.leftMouseUp, CGPoint(x: excludedPoint.x + 80, y: excludedPoint.y), to: excludedAtPress)
        expect(reappeared && saves.isEmpty && near(frame(a), frozenBefore.0) && near(frame(b), frozenBefore.1),
               "release revalidates the frozen excluded identity too and refuses its newly current state",
               "current \(reappeared), saves \(saves.count), frames \(frame(a)) \(frame(b)), notices \(window(ZoneNoticePanel.self).map { texts($0) })")
        controller.cancelSessions()
        _ = await observeUntil { window(ZoneNoticePanel.self).isEmpty }
        guard requireReady() else { return nil }

        guard let grip = discoverGrip() else { expect(false, "the bind reveals a divider grip"); return nil }
        let expected = DividerGrip.rect(for: handle, pointer: reveal)
        expect(grip.frame == expected && !grip.frame.contains(reveal) && grip.ignoresMouseEvents && !grip.isKeyWindow,
               "the revealed grip is offset 32 points from the pointer and click-through")
        try capture(grip, name: "owner-grip-revealed")
        input.deliver(.mouseMoved, at: CGPoint(x: reveal.x, y: reveal.y + 30))
        expect(grip.frame == expected && grip.ignoresMouseEvents, "a nearby move keeps one grip in place without arming it")
        var center = arm(grip)
        expect(!grip.ignoresMouseEvents && !grip.isKeyWindow, "moving into the grip arms it for the mouse only")

        let beforeDivider = (frame(a), frame(b))
        mouse(.leftMouseDown, center, to: grip)
        mouse(.leftMouseDragged, CGPoint(x: center.x - 200, y: center.y), to: grip)
        let previewCount = window(HighlightWindow.self).count
        input.modifiers = []
        pump(0.3)
        mouse(.leftMouseUp, CGPoint(x: center.x - 200, y: center.y), to: grip)
        expect(previewCount == 2 && saves.isEmpty && near(frame(a), beforeDivider.0) && near(frame(b), beforeDivider.1)
                && window(HighlightWindow.self).isEmpty && window(DividerGripPanel.self).isEmpty,
               "releasing the bind during a divider drag cancels it; only the two visible windows were previewed")

        guard let grip2 = discoverGrip() else { expect(false, "the grip returns with the bind"); return nil }
        center = arm(grip2)
        mouse(.leftMouseDown, center, to: grip2)
        mouse(.leftMouseDragged, CGPoint(x: center.x - 200, y: center.y), to: grip2)
        mouse(.leftMouseUp, CGPoint(x: center.x - 200, y: center.y), to: grip2)
        let dragged = layout
        let draggedZone = zone(0, dragged)
        expect(saves.count == 1 && dragged != .halves
                && near(frame(a), CGRect(x: draggedZone.minX, y: draggedZone.minY, width: draggedZone.width / 2, height: draggedZone.height))
                && near(frame(b), CGRect(x: draggedZone.midX, y: draggedZone.minY, width: draggedZone.width / 2, height: draggedZone.height))
                && fixtureFrame(2) == cHidden && (try? JSONDecoder().decode(Node.self, from: Data(contentsOf: saveFile))) == dragged,
               "a divider drag commits once: shared halves follow, the hidden window never moves",
               "saves \(saves.count) zone \(draggedZone) a \(frame(a)) b \(frame(b)) c \(fixtureFrame(2)) was \(cHidden) notices \(window(ZoneNoticePanel.self).map { texts($0) })")

        func pin() -> DividerGripPanel? {
            guard let panel = discoverGrip(CGPoint(x: zone(0).maxX + 4, y: visible.midY)) else { return nil }
            let point = arm(panel)
            mouse(.leftMouseDown, point, to: panel)
            input.modifiers = []
            pump(0.3)
            mouse(.leftMouseUp, point, to: panel)
            return panel
        }
        guard requireReady() else { return nil }
        let frontApp = NSWorkspace.shared.frontmostApplication
        guard let pinned = pin() else { expect(false, "a stationary click pins the grip"); return nil }
        expect(pinned.isKeyWindow && NSWorkspace.shared.frontmostApplication == frontApp && window(DividerGripPanel.self).count == 1,
               "a stationary click pins the grip even though the bind lifted before mouse-up")
        try capture(pinned, name: "owner-grip-pinned")
        let widthBefore = frame(a).width
        key(124, "\u{f703}", to: pinned)
        key(124, "\u{f703}", to: pinned, flags: .shift)
        key(36, "\r", to: pinned)
        let scale = CGFloat(info.pixelsWide) / screen.frame.width
        expect(saves.count == 2 && abs((frame(a).width - widthBefore) - 11 / scale / 2) <= 1,
               "plain and Shift arrows nudge 1 and 10 display pixels and Return commits without the bind",
               "saves \(saves.count) width \(widthBefore) -> \(frame(a).width) b \(frame(b)) scale \(scale) layouts \(saves)")

        guard requireReady() else { return nil }
        guard let unchanged = pin() else { expect(false, "pin again"); return nil }
        key(36, "\r", to: unchanged)
        expect(saves.count == 2 && window(ZoneNoticePanel.self).isEmpty && window(DividerGripPanel.self).isEmpty,
               "Return on an unchanged pinned grip closes without saving or a notice")
        guard let escaping = pin() else { expect(false, "pin again"); return nil }
        let framesBeforeEscape = (frame(a), frame(b))
        key(123, "\u{f702}", to: escaping)
        key(53, "\u{1b}", to: escaping)
        expect(saves.count == 2 && near(frame(a), framesBeforeEscape.0) && near(frame(b), framesBeforeEscape.1)
                && window(DividerGripPanel.self).isEmpty && window(HighlightWindow.self).isEmpty,
               "Escape cancels a nudged pinned grip without moving or saving")
        guard let resigning = pin() else { expect(false, "pin again"); return nil }
        let other = NSPanel(contentRect: CGRect(x: 40, y: 40, width: 120, height: 60),
                            styleMask: [.titled, .nonactivatingPanel], backing: .buffered, defer: false)
        other.makeKeyAndOrderFront(nil)
        pump(0.1)
        expect(!resigning.isVisible && saves.count == 2, "a pinned grip cancels when another window takes key status")
        other.orderOut(nil)
        guard pin() != nil else { expect(false, "pin again"); return nil }
        input.deliver(.rightMouseDown)
        expect(window(DividerGripPanel.self).isEmpty && saves.count == 2, "a press elsewhere cancels a pinned grip")

        expect(command("minimum 0"), "fixture gives the left shared window a minimum size")
        guard let refusing = discoverGrip(CGPoint(x: zone(0).maxX + 4, y: visible.midY)) else { expect(false, "reveal again"); return nil }
        center = arm(refusing)
        let framesBeforeRefusal = (frame(a), frame(b))
        mouse(.leftMouseDown, center, to: refusing)
        mouse(.leftMouseDragged, CGPoint(x: center.x - 300, y: center.y), to: refusing)
        let releaseAnchor = CGPoint(x: refusing.frame.midX, y: refusing.frame.midY)
        mouse(.leftMouseUp, CGPoint(x: center.x - 300, y: center.y), to: refusing)
        let fitNotice = window(ZoneNoticePanel.self).first
        let appName = NSRunningApplication(processIdentifier: pid)?.localizedName ?? ""
        expect(saves.count == 2 && near(frame(a), framesBeforeRefusal.0) && near(frame(b), framesBeforeRefusal.1)
                && SnapMemory.shared.recovery.isEmpty
                && fitNotice.map { texts($0) == ["\(appName) didn’t fit", "Windows were put back. The layout wasn’t saved."] } == true
                && fitNotice.map { hypot($0.frame.midX - releaseAnchor.x, $0.frame.maxY - releaseAnchor.y) <= 40 } == true,
               "a window refusing its frame puts every window back, saves nothing and names the app near the grip",
               "saves \(saves.count) a \(frame(a)) was \(framesBeforeRefusal.0) b \(frame(b)) was \(framesBeforeRefusal.1) recovery \(SnapMemory.shared.recovery.count) notice \(fitNotice.map { texts($0) } ?? []) at \(fitNotice?.frame ?? .null) anchor \(releaseAnchor)")
        if let fitNotice { try capture(fitNotice, name: "notice-divider-refused") }

        controller.cancelSessions()
        let beforeBindNoticeGone = await observeUntil { window(ZoneNoticePanel.self).isEmpty }
        expect(beforeBindNoticeGone, "prior refusal notice finishes dismissal before custom-bind cases")
        for activation in [UInt16(124), 36, 40] {
            for releaseOrder in ["modifier-first", "key-first", "before-pin"] {
                let keyFirst = releaseOrder == "key-first"
                let custom = ProbeInput()
                var customLayout = layout
                var customSaves = 0
                let keyed = DragSnapController(configProvider: { LineupConfig(defaultLayout: customLayout) },
                    triggerProvider: { DragSnapTrigger(keyCode: Int(activation), modifiers: DragSnapModifierMask.shift) },
                    onPlacement: { _, _, _ in },
                    commitDivider: { _, _, new, _ in customLayout = new; customSaves += 1; return .committed },
                    input: custom.source(), visibleWindows: fixtureWindows)
                keyed.start()
                custom.modifiers = .shift
                custom.deliver(.mouseMoved, at: CGPoint(x: zone(0).maxX + 4, y: visible.midY))
                custom.elapse(DividerDwell.delay)
                let withoutKey = window(DividerGripPanel.self).count
                custom.keys = [activation]
                custom.deliver(.mouseMoved, at: CGPoint(x: zone(0).maxX + 4, y: visible.midY - 2))
                custom.elapse(DividerDwell.delay)
                guard let keyedGrip = window(DividerGripPanel.self).first else { expect(false, "key bind reveals grip"); return nil }
                let point = CGPoint(x: keyedGrip.frame.midX, y: keyedGrip.frame.midY)
                custom.deliver(.mouseMoved, at: point)
                mouse(.leftMouseDown, point, to: keyedGrip)
                if releaseOrder == "before-pin" { custom.keys = [] }
                mouse(.leftMouseUp, point, to: keyedGrip)
                if releaseOrder == "before-pin" {
                    custom.modifiers = []
                    key(124, "\u{f703}", to: keyedGrip)
                    key(36, "\r", to: keyedGrip)
                    expect(customSaves == 1 && customLayout != layout && !keyedGrip.isVisible,
                           "activation key \(activation) released before pin accepts an immediate later arrow and Return")
                    keyed.stop()
                    continue
                }
                key(activation, "k", to: keyedGrip, flags: .shift)
                key(activation, "k", to: keyedGrip, flags: .shift, repeating: true)
                expect(withoutKey == 0 && keyedGrip.isKeyWindow && window(HighlightWindow.self).isEmpty
                        && customSaves == 0 && customLayout == layout,
                       "bind key \(activation) held and repeating cannot nudge or confirm the pinned controller")
                if !keyFirst { custom.modifiers = []; pump(0.12) }
                key(activation, "k", to: keyedGrip, repeating: true)
                expect(keyedGrip.isVisible && window(HighlightWindow.self).isEmpty && customSaves == 0,
                       "lifting modifiers alone still leaves activation stroke \(activation) latched")
                custom.keys = []
                if let up = NSEvent.keyEvent(with: .keyUp, location: .zero, modifierFlags: custom.modifiers,
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: keyedGrip.windowNumber,
                    context: nil, characters: "k", charactersIgnoringModifiers: "k", isARepeat: false, keyCode: activation) {
                    keyedGrip.sendEvent(up)
                }
                custom.modifiers = []
                key(124, "\u{f703}", to: keyedGrip)
                expect(!window(HighlightWindow.self).isEmpty && customSaves == 0,
                       "after key-first=\(keyFirst) release, an explicit arrow adjusts bind \(activation)")
                key(36, "\r", to: keyedGrip)
                expect(customSaves == 1 && customLayout != layout && !keyedGrip.isVisible,
                       "after activation release, explicit Return commits once for bind \(activation)")
                keyed.stop()
            }
        }

        let toolInput = ProbeInput()
        let storeDirectory = temporary.appendingPathComponent("tool-config")
        let storeURL = storeDirectory.appendingPathComponent("config.json")
        var toolConfig = LineupConfig(defaultLayout: layout, shortcuts: Shortcuts(bindings: []), appPlacements: [:])
        for current in NSScreen.screens { toolConfig = toolConfig.setting(layout: layout, for: ScreenIdentity.info(for: current), now: nil) }
        let store = LineupAppConfigStore(url: storeURL)
        try store.setSettings(toolConfig, for: .zones)
        let services = ToolServices(id: .zones, config: ToolConfigScope(owner: .zones, store: store),
            permissions: PermissionCenter(), activation: ActivationCoordinator(), termination: TerminationCoordinator(),
            refreshMenu: {}, refreshSettings: {}, peers: { [:] }, keyboardMappings: KeyboardMappingService(readOnly: true))
        let tool = ZonesTool(dragInput: toolInput.source(), visibleWindows: fixtureWindows)
        tool.attach(services)
        tool.start(services)
        let startedConfig = try store.config.settings(LineupConfig.self, for: .zones)
        expect(tool.isRunning && tool.persistedCombos().isEmpty && toolInput.monitorCount == 1
                && startedConfig?.appPlacements?.isEmpty == true
                && startedConfig?.fillAssistEnabled != true,
               "real ZonesTool starts with temporary scope, zero shortcuts/destinations and assist off")
        func toolDivider(_ delta: CGFloat) -> Bool {
            guard let cfg = try? store.config.settings(LineupConfig.self, for: .zones),
                  let handle = Layout.dividerHandles(cfg.layout(forKey: info.key),
                    container: Layout.rootContainer(frame: screen.frame, visibleFrame: visible), pixelsWide: info.pixelsWide,
                    thickness: 24).first else { return false }
            toolInput.modifiers = .shift
            toolInput.deliver(.mouseMoved, at: CGPoint(x: handle.line.midX + 4, y: handle.container.midY))
            toolInput.elapse(DividerDwell.delay)
            guard let panel = window(DividerGripPanel.self).first else { return false }
            let point = CGPoint(x: panel.frame.midX, y: panel.frame.midY)
            toolInput.deliver(.mouseMoved, at: point)
            mouse(.leftMouseDown, point, to: panel)
            mouse(.leftMouseDragged, CGPoint(x: point.x + delta, y: point.y), to: panel)
            mouse(.leftMouseUp, CGPoint(x: point.x + delta, y: point.y), to: panel)
            return true
        }
        guard requireReady() else { return nil }
        let oldBytes = try Data(contentsOf: storeURL)
        let oldFrame = frame(a)
        expect(toolDivider(80), "normal grip action reaches the private ZonesTool divider owner")
        let savedBytes = try Data(contentsOf: storeURL)
        let disk = LineupAppConfigStore(url: storeURL)
        _ = disk.load()
        let saved = try store.config.settings(LineupConfig.self, for: .zones)!
        expect(savedBytes != oldBytes && disk.config == store.config && saved.layout(forKey: info.key) != layout
                && frame(a).width > oldFrame.width,
               "actual ToolConfigScope atomically saves the divider only after fixture frames land")
        try observeShadowBounds("config-divider")
        guard requireReady() else { return nil }
        let keptConfig = store.config
        let keptFrames = (frame(a), frame(b))
        let keptHistory = SnapMemory.shared.records.entry(a)?.preFrame
        let parked = temporary.appendingPathComponent("parked-tool-config")
        try FileManager.default.moveItem(at: storeDirectory, to: parked)
        try Data("non-directory save obstruction".utf8).write(to: storeDirectory)
        expect(toolDivider(80), "second grip reaches the actual config save with a temporary filesystem refusal")
        let parkedBytes = try Data(contentsOf: parked.appendingPathComponent("config.json"))
        expect(store.config == keptConfig && near(frame(a), keptFrames.0) && near(frame(b), keptFrames.1)
                && SnapMemory.shared.records.entry(a)?.preFrame == keptHistory && SnapMemory.shared.recovery.isEmpty
                && parkedBytes == savedBytes
                && window(ZoneNoticePanel.self).first.map { texts($0).first == "Couldn’t save the layout" } == true,
               "actual failed config save compensates frames, keeps disk/history and reports the save refusal",
               "same config \(store.config == keptConfig), frames \(frame(a)) \(frame(b)), was \(keptFrames), history \(String(describing: SnapMemory.shared.records.entry(a)?.preFrame)), was \(String(describing: keptHistory)), recovery \(SnapMemory.shared.recovery.count), notices \(window(ZoneNoticePanel.self).map { texts($0) })")
        try FileManager.default.moveItem(at: storeDirectory, to: temporary.appendingPathComponent("save-obstruction"))
        try FileManager.default.moveItem(at: parked, to: storeDirectory)
        tool.stop()
        expect(!tool.isRunning && toolInput.monitorCount == 0 && SnapMemory.shared.isEmpty,
               "real ZonesTool stop releases fixture input and history")
        tool.start(services)
        let emptyBefore = try Data(contentsOf: storeURL)
        let emptyFrames = (frame(a), frame(b))
        expect(toolDivider(40), "normal tool grip permits a layout-only edit without bound records")
        let emptyAfter = try Data(contentsOf: storeURL)
        expect(emptyBefore != emptyAfter && near(frame(a), emptyFrames.0) && near(frame(b), emptyFrames.1)
                && SnapMemory.shared.isEmpty,
               "a legitimate layout-only edit saves through the actual owner with no window effects")
        tool.stop()

        expect(command("fixed 1"), "fixture makes the right shared window non-resizable")
        let full = Layout.rootContainer(frame: screen.frame, visibleFrame: visible)
        let fixedBefore = frame(b)
        let maximized = WindowMover.maximizeOrReturn(b, current: fixedBefore, target: full, screenKey: info.key)
        let centered = frame(b)
        let returned = WindowMover.maximizeOrReturn(b, current: centered, target: full, screenKey: info.key)
        let back = frame(b)
        let again = WindowMover.maximizeOrReturn(b, current: back, target: full, screenKey: info.key)
        _ = WindowMover.maximizeOrReturn(b, current: frame(b), target: full, screenKey: info.key)
        expect(maximized && sameSize(centered.size, fixedBefore.size) && returned && near(back, fixedBefore) && again,
               "a non-resizable window that maximize centers returns to its frame, and the command keeps working")
        expect(SnapMemory.shared.preFrame(of: b, currentFrame: frame(b)) != nil, "maximize and return keep first-snap Restore history")

        let prePartial = frame(b)
        expect(command("move 1 \(visible.minX - 40 - prePartial.minX)"), "fixture places its fixed window partially outside the usable frame")
        let outside = frame(b)
        let firstSnap = prePartial
        SnapMemory.shared.records.recordSnap(b, from: firstSnap, to: outside)
        _ = WindowMover.maximizeOrReturn(b, current: outside, target: full, screenKey: info.key)
        let partialReturned = WindowMover.maximizeOrReturn(b, current: frame(b), target: full, screenKey: info.key)
        let partialFrame = frame(b)
        let originalTarget = SnapMemory.shared.records.entry(b)?.maximize?.before
        let retryReturned = WindowMover.maximizeOrReturn(b, current: partialFrame, target: full, screenKey: info.key)
        expect(!partialReturned && !retryReturned && !near(partialFrame, outside) && originalTarget == outside
                && SnapMemory.shared.records.entry(b)?.maximize?.before == outside
                && SnapMemory.shared.records.entry(b)?.maximize?.applied == frame(b)
                && SnapMemory.shared.preFrame(of: b, currentFrame: frame(b)) == firstSnap,
               "actual best-effort clamped return retains its original target and first-snap history on retry")
        expect(command("move 1 37"), "fixture then moves the failed-return window externally")
        expect(SnapMemory.shared.records.maximizeAction(b, current: frame(b), full: full, screenKey: info.key) == .maximize(full),
               "genuine external movement still invalidates the partial-return receipt")

        expect(command("resizable 1") && command("minimum 1 0 0"),
               "restore native resize support before the changing-minimum regression")
        let small = CGRect(x: visible.minX + 60, y: visible.minY + 80, width: 400, height: 350)
        expect(command("frame 1 \(small.minX) \(small.minY) 400 350"), "give the resizable fixture its original return frame")
        let smallReady = await observeUntil { near(frame(b), small) }
        let restoreHistory = small.offsetBy(dx: 17, dy: 19)
        SnapMemory.shared.records.recordSnap(b, from: restoreHistory, to: small)
        let grew = WindowMover.maximizeOrReturn(b, current: frame(b), target: full, screenKey: info.key)
        let fullReady = await observeUntil { near(frame(b), full) }
        expect(smallReady && grew && fullReady && command("minimum 1 600 200"),
               "a still-resizable maximized fixture raises its minimum width from below 400 to 600")
        let clampedReturn = WindowMover.maximizeOrReturn(b, current: frame(b), target: full, screenKey: info.key)
        let clampedReady = await observeUntil { abs(frame(b).width - 600) <= 1 }
        let clamped = frame(b)
        expect(clampedReady && !clampedReturn && !near(clamped, small) && !near(clamped, full)
                && SnapMemory.shared.records.entry(b)?.maximize?.before == small
                && SnapMemory.shared.records.entry(b)?.maximize?.applied == clamped
                && SnapMemory.shared.preFrame(of: b, currentFrame: clamped) == restoreHistory,
               "observed resizable partial return keeps the original destination and first-snap history")
        expect(command("minimum 1 0 0"), "release the fixture minimum for a retry of the original return")
        let retriedSmall = WindowMover.maximizeOrReturn(b, current: frame(b), target: full, screenKey: info.key)
        let smallReturned = await observeUntil { near(frame(b), small) }
        expect(retriedSmall && smallReturned && SnapMemory.shared.records.entry(b)?.maximize == nil
                && SnapMemory.shared.preFrame(of: b, currentFrame: frame(b)) == restoreHistory,
               "a resizable changing-minimum return remains retryable and consumes its receipt only at the original destination")

        let second = temporary.appendingPathComponent("second", isDirectory: true)
        guard case let (process, secondPID, _)? = try launchFixture(second, windows: 1),
              let dying = WindowMover.visibleWindows(pids: [secondPID])?.first?.window else {
            expect(false, "second fixture for definitive window death"); return nil
        }
        let dyingBefore = frame(dying)
        _ = WindowMover.maximizeOrReturn(dying, current: dyingBefore, target: full, screenKey: info.key)
        let dyingApplied = frame(dying)
        let deadReceipt = SnapMemory.shared.records.entry(dying)?.maximize
        let liveGone = WindowMover.isGone(dying)
        process.terminate(); process.waitUntilExit()
        let deadReturn = WindowMover.maximizeOrReturn(dying, current: dyingApplied, target: full, screenKey: info.key)
        expect(!deadReturn && deadReceipt != nil
                && SnapMemory.shared.records.entry(dying)?.maximize?.before == deadReceipt?.before
                && SnapMemory.shared.records.entry(dying)?.maximize?.applied == deadReceipt?.applied,
               "an actual mover with no landed result leaves the return receipt untouched")
        expect(!liveGone && WindowMover.isGone(dying) && !WindowMover.isGone(a),
               "only an exited window is classified as definitively gone")
        let tiny = CGRect(x: frame(a).minX, y: frame(a).minY, width: 200, height: 200)
        SnapMemory.shared.recovery = [FrameEffect(window: dying, before: tiny, after: tiny),
                                      FrameEffect(window: a, before: tiny, after: frame(a))]
        let resolved = WindowMover.retryRestore()
        expect(!resolved && SnapMemory.shared.recovery.count == 1 && SnapMemory.shared.recovery.first.map { CFEqual($0.window, a) } == true,
               "Retry Restore drops the exited window and keeps the live window it could not restore")
        SnapMemory.shared.recovery = []

        if let output {
            let receipt: [String: Any] = ["fixturePID": pid, "windowIDs": ids, "savedLayouts": saves.count,
                                          "shared": [NSStringFromRect(left), NSStringFromRect(right)],
                                          "final": [NSStringFromRect(frame(a)), NSStringFromRect(frame(b)), NSStringFromRect(frame(c))]]
            try JSONSerialization.data(withJSONObject: receipt, options: [.prettyPrinted, .sortedKeys])
                .write(to: output.appendingPathComponent("native-frame-receipt.json"))
        }

        completed.append("axOwners")
        guard CGPreflightScreenCaptureAccess() else {
            gates["nativeCapture"] = "existing Screen Recording grant unavailable"
            gates["controlledCapture"] = "fixture capture filter unavailable without existing grant"
            print("GATE: existing Screen Recording grant unavailable. No permission was requested.")
            return try terminal()
        }
        controller.cancelSessions()
        _ = await observeUntil { window(ZoneNoticePanel.self).isEmpty }
        SnapMemory.shared.reset()
        layout = .halves
        assistEnabled = true
        expect(command("hide 0") && command("move 1 \(visible.minX + 30 - frame(b).minX)")
                && command("show 2"), "prepare only whitelisted fixtures for the real fill owner")
        let sourceReady = await observeUntil {
            fixtureWindows(nil)?.contains { $0.id == ids[2] && $0.window != nil } == true
        }
        guard sourceReady, let fillWindow = fixtureWindows(nil)?.first(where: { $0.id == ids[2] })?.window else {
            expect(false, "resolve the current AX identity of the revealed fixture source"); return nil
        }
        let fillSource = frame(fillWindow)
        func dropForFill(candidateCount: Int = 1, waitForPreviews: Bool = true) async -> (ZoneFillPanel, TimeInterval)? {
            let visibleReady = await observeUntil {
                guard let rows = fixtureWindows(nil) else { return false }
                return rows.count == candidateCount + 1 && rows.allSatisfy { $0.window != nil }
            }
            let titlebar = CGPoint(x: frame(fillWindow).midX, y: frame(fillWindow).maxY - 14)
            var externalObstruction = false
            var hitSamples = 0
            let exactHitReady = await observeUntil {
                guard visibleReady else { return false }
                hitSamples += 1
                guard let hit = WindowMover.window(atCocoaPoint: titlebar) else { return false }
                var owner: pid_t = -1
                AXUIElementGetPid(hit, &owner)
                if owner != pid && owner != getpid() {
                    externalObstruction = true
                    print("Fill exact AX prerequisite blocked by external PID \(owner). No fixture ordering or input follows.")
                    return true
                }
                return owner == pid && CFEqual(hit, fillWindow)
            }
            print("Fill exact AX readiness. settled \(exactHitReady), externalObstruction \(externalObstruction), samples \(hitSamples), point \(titlebar)")
            guard visibleReady, exactHitReady, !externalObstruction, beginDrag(fillWindow) != nil else {
                print("Fill drop prerequisite. matched \(visibleReady), source \(frame(fillWindow)), census \(fixtureWindows(nil)?.map { "\($0.id):\($0.frame):AX=\($0.window != nil)" } ?? [])")
                return nil
            }
            let front = NSWorkspace.shared.frontmostApplication
            input.deliver(.leftMouseDragged, at: CGPoint(x: zone(0).midX, y: zone(0).midY))
            input.deliver(.leftMouseUp)
            print("Fill drop observation. permission \(CGPreflightScreenCaptureAccess()), source \(frame(fillWindow)), target \(zone(0)), census \(fixtureWindows(nil)?.map { "\($0.id):\($0.frame):AX=\($0.window != nil)" } ?? [])")
            guard await observeUntil({ window(ZoneFillPanel.self).first != nil }, deadline: 5),
                  let chooser = window(ZoneFillPanel.self).first else { return nil }
            let shownAt = ProcessInfo.processInfo.systemUptime
            expect(!chooser.isKeyWindow && chooser.firstResponder === chooser && NSWorkspace.shared.frontmostApplication == front,
                   "the actual drop presents suggestions without key focus, a first responder or a frontmost change",
                   "key \(chooser.isKeyWindow), front \(NSWorkspace.shared.frontmostApplication?.localizedName ?? "nil")")
            if !waitForPreviews { return (chooser, shownAt) }
            let loaded = await observeUntil({
                let cards = views(chooser.contentView).compactMap { $0 as? NSButton }
                    .filter { $0.accessibilityLabel()?.contains("Zones document-free fixture") == true }
                return cards.count == candidateCount && cards.allSatisfy { $0.accessibilityValue() as? String != "Loading preview" }
            }, deadline: 10)
            return loaded ? (chooser, shownAt) : nil
        }
        func fixtureCard(_ chooser: ZoneFillPanel) -> NSButton? {
            views(chooser.contentView).compactMap { $0 as? NSButton }
                .first { $0.accessibilityLabel()?.contains("Zones document-free fixture 1") == true }
        }
        guard let (idleChooser, idleShown) = await dropForFill() else { expect(false, "successful real drop suggests windows for a free zone"); return nil }
        let expired = await observeUntil({ !idleChooser.isVisible }, deadline: 10)
        let elapsed = ProcessInfo.processInfo.systemUptime - idleShown
        expect(expired && elapsed >= 7.7 && elapsed <= 9 && window(ZoneFillPanel.self).isEmpty,
               "actual suggestions close about eight seconds after appearing while the pointer is elsewhere", "elapsed \(elapsed)")
        guard let (heldChooser, heldShown) = await dropForFill() else { expect(false, "suggest again for a resting pointer"); return nil }
        input.pointer = CGPoint(x: heldChooser.frame.midX, y: heldChooser.frame.midY)
        input.happen(.mouseMoved)
        let closedUnderPointer = await observeUntil({ !heldChooser.isVisible }, deadline: 9)
        expect(!closedUnderPointer && heldChooser.isVisible, "actual suggestions stay past their first deadline while the pointer rests on them")
        input.elapse(1)
        input.happen(.keyDown)
        let closedAfterTyping = await observeUntil({ !heldChooser.isVisible }, deadline: 9)
        let heldElapsed = ProcessInfo.processInfo.systemUptime - heldShown
        expect(closedAfterTyping && heldElapsed >= 15.7 && heldElapsed <= 17.5,
               "a key pressed elsewhere lets suggestions under a resting pointer close at the next deadline", "elapsed \(heldElapsed)")
        input.pointer = CGPoint(x: zone(0).midX, y: zone(0).midY)
        guard let (returnChooser, _) = await dropForFill() else { expect(false, "suggest again for a key press before choosing"); return nil }
        input.happen(.keyDown)
        input.elapse(1)
        input.pointer = CGPoint(x: returnChooser.frame.midX, y: returnChooser.frame.midY)
        input.happen(.mouseMoved)
        let closedAfterReturn = await observeUntil({ !returnChooser.isVisible }, deadline: 9)
        expect(!closedAfterReturn && returnChooser.isVisible,
               "a key press followed by the pointer moving onto suggestions keeps them past their first deadline")
        controller.cancelSessions()
        input.pointer = CGPoint(x: zone(0).midX, y: zone(0).midY)
        guard let (actualChooser, _) = await dropForFill() else { expect(false, "successful real drop suggests windows again"); return nil }
        expect(zone(1).contains(actualChooser.frame) && near(frame(fillWindow), fillSource),
               "actual suggestions sit inside the vacant zone beside the fixture source")
        let candidateLabels = views(actualChooser.contentView).compactMap { ($0 as? NSButton)?.accessibilityLabel() }
            .filter { $0.contains("Zones document-free fixture") }
        expect(candidateLabels.count == 1 && candidateLabels[0].contains("fixture 1")
                && !candidateLabels.contains { $0.contains("fixture 2") },
               "actual suggestions exclude the just-dropped source and capture only the whitelisted other fixture")
        try capture(actualChooser, name: "owner-fill-source-excluded")
        let candidateBeforeStale = frame(b)
        expect(command("move 1 37"), "fixture candidate moves after its actual suggestion thumbnail")
        if let card = fixtureCard(actualChooser) { click(card, in: actualChooser) }
        expect(!actualChooser.isVisible && near(frame(b), candidateBeforeStale.offsetBy(dx: 37, dy: 0)) && near(frame(fillWindow), fillSource),
               "a constructed click through NSWindow.sendEvent on a stale suggestion closes without moving the candidate or the excluded source")

        guard let (vacancyChooser, _) = await dropForFill() else { expect(false, "suggest again for vacancy revalidation"); return nil }
        let hiddenFrame = fixtureFrame(0)
        expect(command("move 0 \(zone(1).minX + 20 - hiddenFrame.minX)") && command("show 0"),
               "a different whitelisted fixture enters the suggested free zone")
        let occupied = await observeUntil {
            fixtureWindows(nil)?.contains { $0.id == ids[0] && $0.window != nil && $0.frame.intersects(zone(1)) } == true
        }
        let candidateBeforeVacancy = frame(b)
        if let card = fixtureCard(vacancyChooser) { click(card, in: vacancyChooser) }
        expect(occupied && !vacancyChooser.isVisible && near(frame(b), candidateBeforeVacancy)
                && near(frame(fillWindow), fillSource),
               "a constructed click through NSWindow.sendEvent refuses newly occupied vacancy while the chosen candidate stays unchanged")
        expect(command("hide 0") && command("resizable 1"), "fixture restores a resizable candidate for a one-click fill")
        guard let (positiveChooser, _) = await dropForFill() else { expect(false, "suggest again for a one-click fill"); return nil }
        let front = NSWorkspace.shared.frontmostApplication
        if let card = fixtureCard(positiveChooser) { click(card, in: positiveChooser) }
        expect(!positiveChooser.isVisible && near(frame(b), zone(1)) && near(frame(fillWindow), fillSource)
                && NSWorkspace.shared.frontmostApplication == front,
               "one constructed click through NSWindow.sendEvent fills exactly the vacant zone, leaves its source untouched and keeps the frontmost app")
        try observeShadowBounds("fill", windows: [(ids[2], fillWindow), (ids[1], b)])
        controller.cancelSessions()
        let candidateLeaf = zone(0)
        expect(command("frame 0 \(candidateLeaf.minX + 20) \(candidateLeaf.minY + 30) \(candidateLeaf.width - 40) \(candidateLeaf.height - 60)")
                && command("frame 1 \(candidateLeaf.minX + 40) \(candidateLeaf.minY + 80) 480 360") && command("show 0") && command("front"),
               "prepare two distinct candidate fixtures inside the filled leaf")
        sequentialCapture = true
        defer { firstCandidateCapture.release() }
        guard let (sequentialChooser, _) = await dropForFill(candidateCount: 2, waitForPreviews: false) else {
            expect(false, "a real drop admits two sequential thumbnail candidates"); return nil
        }
        let firstStarted = await observeUntil { sequentialStarts == 1 }
        let sequentialLabels = views(sequentialChooser.contentView).compactMap { ($0 as? NSButton)?.accessibilityLabel() }
            .filter { $0.contains("Zones document-free fixture") }
        expect(firstStarted && sequentialLabels.count == 2 && sequentialLabels[0].contains("fixture 0")
                && sequentialLabels[1].contains("fixture 1"),
               "the actual first candidate stream awaits with a second concrete candidate admitted")
        expect(command("minimize 1"), "candidate B minimizes while candidate A's actual capture operation awaits")
        let secondExcluded = await observeUntil { fixtureWindows(nil)?.contains { $0.id == ids[1] } == false }
        firstCandidateCapture.release()
        let sequentialCancelled = await observeUntil { !sequentialChooser.isVisible && sequentialStops >= 1 }
        let sequentialCards = views(sequentialChooser.contentView).compactMap { $0 as? NSButton }
            .filter { $0.accessibilityLabel()?.contains("Zones document-free fixture") == true }
        let firstPublished = sequentialCards.first?.accessibilityValue() as? String == "Preview unavailable"
        let secondPending = sequentialCards.last?.accessibilityValue() as? String == "Loading preview"
        expect(secondExcluded && sequentialCancelled && firstPublished && secondPending
                && sequentialStarts == 1 && sequentialStops == 1,
               "the real controller revalidates B before its stream starts and cancels the stale two-candidate offer")
        controller.cancelSessions()
        sequentialCapture = false
        expect(command("unminimize 1") && command("hide 0"), "restore only the sequential-capture fixtures")
        let candidateRestored = await observeUntil { fixtureWindows(nil)?.contains { $0.id == ids[1] && $0.window != nil } == true }
        expect(candidateRestored, "the restored fixture is visible before native helper capture cases")
        assistEnabled = false

        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        guard let sc = content.windows.first(where: { $0.windowID == owned[1].id && $0.owningApplication?.processID == pid }) else {
            expect(false, "ScreenCaptureKit resolves the exact fixture ID"); return nil
        }
        try await controlledCapture(filter: SCContentFilter(desktopIndependentWindow: sc))
        let size = ThumbnailSize.fit(sc.frame.size, maximum: CGSize(width: 312, height: 192))
        var startAck = false, stopAck = false
        let once = SingleFrameCapture(operations: .init(start: { stream in try await stream.startCapture(); startAck = true },
                                                       stop: { stream in try await stream.stopCapture(); stopAck = true }))
        let image = try await once.capture(filter: SCContentFilter(desktopIndependentWindow: sc), width: Int(size.width), height: Int(size.height))
        var reused = false
        do { _ = try await once.capture(filter: SCContentFilter(desktopIndependentWindow: sc), width: 10, height: 10) }
        catch { reused = true }
        expect(image.width == Int(size.width) && startAck && stopAck && once.state == .stopped && reused,
               "native frame success follows start/stop API acknowledgments and a used helper refuses reuse")
        if let output {
            try NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?
                .write(to: output.appendingPathComponent("fixture-thumbnail.png"))
        }
        enum NativeOperationError: Error { case stop }
        var transientStartAck = false, transientStopAck = false, transientReturned = false, transientCompleted = false
        var transientStops = 0
        let retryStop = ProbeOperation()
        let transient = SingleFrameCapture(operations: .init(start: { stream in
            try await stream.startCapture(); transientStartAck = true
        }, stop: { stream in
            transientStops += 1
            if transientStops == 1 { throw NativeOperationError.stop }
            await retryStop.hold()
            try await stream.stopCapture(); transientStopAck = true
        }))
        let transientTask = Task {
            defer { transientCompleted = true }
            let image = try await transient.capture(filter: SCContentFilter(desktopIndependentWindow: sc), width: 10, height: 10)
            transientReturned = true
            return image
        }
        let reachedRetry = await observeUntil({ transientStops == 2 || transientCompleted }, deadline: 10)
        expect(reachedRetry && transientStartAck && transientStops == 2 && !transientReturned && transient.state == .stopping,
               "a transient stop failure retries in the same helper and withholds the complete image until stop acknowledgment")
        retryStop.release()
        let transientImage = try await transientTask.value
        expect(transientImage.width == 10 && transientReturned && transientStopAck && transient.state == .stopped
                && transient.cleanupError == nil && transientStops == 2,
               "the second acknowledged stop completes the same native one-frame capture exactly once")

        var throwingStartAck = false, throwingStopAck = false
        var permanentStops = 0
        let stopFailure = SingleFrameCapture(operations: .init(start: { stream in
            try await stream.startCapture(); throwingStartAck = true
        }, stop: { stream in
            permanentStops += 1
            if !throwingStopAck { try await stream.stopCapture(); throwingStopAck = true }
            throw NativeOperationError.stop
        }))
        var refusedImage = false
        do { _ = try await stopFailure.capture(filter: SCContentFilter(desktopIndependentWindow: sc), width: 10, height: 10) }
        catch SingleFrameCaptureError.cleanupFailed(let cause, let error) {
            refusedImage = cause == nil && (error as? NativeOperationError) == .stop
        } catch { }
        expect(refusedImage && throwingStartAck && throwingStopAck && permanentStops == 2 && stopFailure.state == .cleanupFailed,
               "a complete native frame cannot become success when its stop operation throws")

        let acknowledgedStart = ProbeOperation()
        var cancelledStartAck = false, cancelledStopAck = false
        let inflight = SingleFrameCapture(operations: .init(start: { stream in
            try await stream.startCapture(); cancelledStartAck = true
            await acknowledgedStart.hold()
        }, stop: { stream in try await stream.stopCapture(); cancelledStopAck = true }))
        let task = Task { @MainActor in
            try await inflight.capture(filter: SCContentFilter(desktopIndependentWindow: sc), width: Int(size.width), height: Int(size.height))
        }
        await acknowledgedStart.waitForEntry()
        task.cancel()
        inflight.cancel()
        acknowledgedStart.release()
        do {
            _ = try await task.value
            expect(false, "an acknowledged native stream cancelled in-flight cannot return an image")
        } catch is CancellationError {
            expect(cancelledStartAck && cancelledStopAck && inflight.state == .stopped,
                   "native cancellation follows an independently acknowledged start and stop")
        }
        completed.append("nativeCapture")
        return try terminal()
    }
}

private func sameSize(_ lhs: CGSize, _ rhs: CGSize) -> Bool {
    abs(lhs.width - rhs.width) <= 1 && abs(lhs.height - rhs.height) <= 1
}

@MainActor
private final class ProbeBackdrop: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill(); bounds.fill()
        NSColor.secondaryLabelColor.withAlphaComponent(0.12).setFill()
        let inner = bounds.insetBy(dx: 64, dy: 64)
        guard inner.width > 0, inner.height > 0 else { return }
        for row in 0..<Int(inner.height / 24) {
            CGRect(x: inner.minX, y: inner.minY + CGFloat(row) * 24, width: inner.width, height: 6).fill()
        }
    }
}

extension ZonesNativeProbe {
    @MainActor
    static func offscreen() -> Int32 {
        let arguments = CommandLine.arguments
        guard let tokenIndex = arguments.firstIndex(of: "--invocation"), let pathIndex = arguments.firstIndex(of: "--receipt"),
              arguments.count > tokenIndex + 1, arguments.count > pathIndex + 1 else {
            print("FAIL: --offscreen needs --invocation and --receipt"); return 1
        }
        setvbuf(stdout, nil, _IONBF, 0)
        let app = NSApplication.shared
        func policyName() -> String {
            switch app.activationPolicy() {
            case .regular: "regular"
            case .accessory: "accessory"
            case .prohibited: "prohibited"
            @unknown default: "raw \(app.activationPolicy().rawValue)"
            }
        }
        let policyBefore = policyName()
        let policyAccepted = app.setActivationPolicy(.prohibited)
        let policy = policyName()
        var running = app.isRunning
        let output = ProcessInfo.processInfo.environment["LINEUP_ZONES_CAPTURE_DIR"].map { URL(fileURLWithPath: $0) }
        var passes = 0, failures = 0, drewViews = false
        var images: [[String: Any]] = []
        func expect(_ condition: Bool, _ message: String, _ detail: @autoclosure () -> String = "") {
            print("\(condition ? "PASS" : "FAIL"): \(message)")
            if condition { passes += 1 } else { failures += 1; if !detail().isEmpty { print("  observed: \(detail())") } }
        }
        func ownWindowsOnScreen() -> Int {
            (CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? [])
                .filter { $0[kCGWindowOwnerPID as String] as? Int32 == getpid() }.count
        }
        func finish() -> Int32 {
            running = running || app.isRunning
            let finalPolicy = policyName()
            let receipt: [String: Any] = [
                "version": 1, "invocation": arguments[tokenIndex + 1], "mode": "offscreen", "endpoint": "gated",
                "passed": passes, "failed": failures, "cleanup": app.windows.allSatisfy { !$0.isVisible } && ownWindowsOnScreen() == 0,
                "completed": drewViews ? ["offscreenViews"] : [],
                "gates": [
                    "views": "offscreen drawing orders no window; run --permission-free on an unoccupied desktop",
                    "controlledCapture": "offscreen mode never calls ScreenCaptureKit",
                    "axOwners": "offscreen mode never reads Accessibility",
                    "nativeCapture": "offscreen mode never calls ScreenCaptureKit",
                    "material": "glass, popover material and window shadows need the window server compositor",
                    "keyFocus": "the native focus ring of a key window needs an on-screen key panel",
                    "cursorDelivery": "cursor rects in an inactive nonactivating panel need a physical pointer",
                    "firstMouseDelivery": "a first click reaching a card in the inactive, non-key chooser needs a physical pointer",
                    "activation": "without a run loop, isActive and the frontmost app are cached values; activation is prevented by the observed .prohibited policy, not observed live",
                    "systemIncreaseContrast": "only the handle's Increase Contrast input is drawn; system color changes under the real setting are not shown",
                    "systemReduceTransparency": "material is not drawn offscreen, so Reduce Transparency is not shown",
                ],
                "images": images,
                "activationPolicyBefore": policyBefore,
                "activationPolicyAccepted": policyAccepted,
                "activationPolicy": finalPolicy == policy ? policy : "\(policy) then \(finalPolicy)",
                "applicationRunning": running,
            ]
            do {
                try JSONSerialization.data(withJSONObject: receipt, options: [.prettyPrinted, .sortedKeys])
                    .write(to: URL(fileURLWithPath: arguments[pathIndex + 1]), options: .atomic)
            } catch { print("FAIL: offscreen receipt \(error)"); return 1 }
            print("TERMINAL: gated invocation \(arguments[tokenIndex + 1]) offscreen, \(passes) passed, \(failures) failed, \(images.count) images")
            return failures == 0 ? 0 : 1
        }
        expect((policyAccepted || policyBefore == "prohibited") && policy == "prohibited" && !running,
               "offscreen observes the .prohibited activation policy and no running application before creating any view",
               "policy before \(policyBefore), request accepted \(policyAccepted), policy after \(policy), running \(running)")
        guard failures == 0 else { return finish() }
        func stillPassive(_ stage: String) {
            let visible = app.windows.filter(\.isVisible).count, onScreen = ownWindowsOnScreen()
            expect(visible == 0 && onScreen == 0 && app.keyWindow == nil,
                   "offscreen \(stage) has no own window visible or on screen and no own key window",
                   "visible \(visible), on screen \(onScreen), key \(String(describing: app.keyWindow))")
        }
        stillPassive("startup")
        if let output {
            do { try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true) }
            catch { expect(false, "create the requested capture directory", "\(error)") }
        }

        let chooser = CGRect(x: 800, y: 300, width: 532, height: 230)
        func inUse(loading: Bool = false, focused: Bool = false, _ steps: (ProbeInput) -> Void) -> Bool {
            let input = ProbeInput()
            input.pointer = CGPoint(x: chooser.minX - 40, y: chooser.midY)
            steps(input)
            return DragSnapController.fillInUse(loading: loading, focused: focused, frame: chooser, input: input.source())
        }
        func enter(_ input: ProbeInput) { input.pointer = CGPoint(x: chooser.midX, y: chooser.midY); input.happen(.mouseMoved) }
        func autorepeat(_ input: ProbeInput, for seconds: TimeInterval) {
            for _ in 0..<Int((seconds / 0.05).rounded()) { input.happen(.keyDown); input.elapse(0.05) }
        }
        let keyThenHover = inUse { $0.elapse(2); $0.happen(.keyDown); $0.elapse(4); enter($0); $0.elapse(2.2) }
        expect(keyThenHover, "the production deadline keeps suggestions when the pointer moves onto them after a key press")
        let restingThenKey = inUse { enter($0); $0.elapse(9); $0.happen(.keyDown); $0.elapse(7.2) }
        let restingNoKey = inUse { enter($0); $0.elapse(7.2) }
        expect(!restingThenKey && restingNoKey,
               "a key pressed elsewhere under a resting pointer lets the production deadline close suggestions that the resting pointer alone keeps",
               "resting then key \(restingThenKey), resting without a key \(restingNoKey)")
        let noPointer = inUse { $0.happen(.mouseMoved); $0.elapse(8) }
        expect(!noPointer, "the production deadline closes suggestions with the pointer elsewhere and no key pressed")
        let loadingHold = inUse(loading: true) { $0.happen(.keyDown); $0.elapse(8) }
        let keyHold = inUse(focused: true) { $0.happen(.keyDown); $0.elapse(8) }
        expect(loadingHold && keyHold, "loading previews and a key chooser hold the production deadline with a recent key press and the pointer elsewhere",
               "loading \(loadingHold), key \(keyHold)")
        let releasedTrigger = inUse { autorepeat($0, for: 0.5); $0.elapse(1.5); enter($0); $0.elapse(6.2) }
        let heldKey = inUse { enter($0); $0.elapse(1); autorepeat($0, for: 7.2) }
        expect(releasedTrigger && !heldKey,
               "an autorepeating drag key released before the pointer moves onto suggestions keeps them, a key still repeating under a parked pointer does not",
               "released \(releasedTrigger), held \(heldKey)")
        let scrolled = inUse { enter($0); $0.elapse(2); $0.happen(.keyDown); $0.elapse(2); $0.happen(.scrollWheel); $0.elapse(4.2) }
        let unreadable = inUse { enter($0); $0.unreadable = [.keyDown]; $0.elapse(8) }
        expect(scrolled && !unreadable, "scrolling suggestions after a key press holds the production deadline and an unreadable key age never does",
               "scrolled \(scrolled), unreadable \(unreadable)")
        stillPassive("deadline decisions")

        let scale: CGFloat = 2
        func raster(_ view: NSView) -> NSBitmapImageRep? {
            let size = view.bounds.size
            guard size.width >= 1, size.height >= 1,
                  let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int((size.width * scale).rounded(.up)),
                                             pixelsHigh: Int((size.height * scale).rounded(.up)), bitsPerSample: 8,
                                             samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .calibratedRGB,
                                             bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
            rep.size = size
            view.layoutSubtreeIfNeeded()
            view.cacheDisplay(in: view.bounds, to: rep)
            return rep
        }
        func png(_ rep: NSBitmapImageRep?) -> Data? { rep?.representation(using: .png, properties: [:]) }
        func save(_ data: Data?, _ name: String, _ provenance: [String: Any]) {
            guard let output else { return }
            let file = name + ".png"
            guard let data else { expect(false, "encode \(file)"); return }
            do {
                try data.write(to: output.appendingPathComponent(file))
                images.append(provenance.merging(["file": file]) { a, _ in a })
            } catch { expect(false, "write \(file)", "\(error)") }
        }
        func opaqueWidth(_ rep: NSBitmapImageRep?, row y: Int) -> CGFloat {
            guard let rep else { return 0 }
            return (0..<rep.pixelsWide).reduce(CGFloat(0)) { sum, x in
                (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.5 ? sum + 1 : sum
            } / scale
        }

        struct Look { let name: String; let appearance: NSAppearance; let content: (NSColor, NSColor); let contrast: Bool }
        func srgb(_ value: CGFloat) -> NSColor { NSColor(srgbRed: value, green: value, blue: value + 0.006, alpha: 1) }
        let light = (NSColor.white, srgb(0.965)), dark = (srgb(0.118), srgb(0.165))
        let looks = [
            Look(name: "light", appearance: NSAppearance(named: .aqua)!, content: light, contrast: false),
            Look(name: "dark", appearance: NSAppearance(named: .darkAqua)!, content: dark, contrast: false),
            Look(name: "mixed-dark", appearance: NSAppearance(named: .darkAqua)!, content: (.white, dark.0), contrast: false),
            Look(name: "mixed-light", appearance: NSAppearance(named: .aqua)!, content: (dark.0, .white), contrast: false),
            Look(name: "contrast-light", appearance: NSAppearance(named: .aqua)!, content: light, contrast: true),
            Look(name: "contrast-dark", appearance: NSAppearance(named: .darkAqua)!, content: dark, contrast: true),
        ]
        let backdropNote = "probe-drawn document-free backdrop: two window content colors meeting at the line, each with a hairline edge"

        func compose(_ scene: CGRect, look: Look, vertical: Bool = true, split: CGFloat? = nil,
                     standIn: [(CGRect, CGFloat)] = [], windows: [NSWindow], overlay: () -> Void = {}) -> Data? {
            let layers = windows.compactMap { window in raster(window.contentView!).map { ($0, window.frame, window.alphaValue) } }
            guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(scene.width * scale), pixelsHigh: Int(scene.height * scale),
                                             bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                             colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
            rep.size = scene.size
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            look.appearance.performAsCurrentDrawingAppearance {
                let bounds = CGRect(origin: .zero, size: scene.size)
                let seam = (split ?? (vertical ? scene.midX : scene.midY)) - (vertical ? scene.minX : scene.minY)
                let first = vertical ? CGRect(x: 0, y: 0, width: seam, height: bounds.height)
                    : CGRect(x: 0, y: seam, width: bounds.width, height: bounds.height - seam)
                look.content.0.setFill(); bounds.fill()
                look.content.1.setFill(); bounds.fill()
                look.content.0.setFill(); first.fill()
                for (edge, color) in [(seam - 1, look.content.0), (seam, look.content.1)] {
                    let bright = (color.usingColorSpace(.sRGB)?.brightnessComponent ?? 1) > 0.5
                    (bright ? NSColor.black : .white).withAlphaComponent(0.12).setFill()
                    (vertical ? CGRect(x: edge, y: 0, width: 1, height: bounds.height) : CGRect(x: 0, y: edge, width: bounds.width, height: 1)).fill()
                }
                for (rect, radius) in standIn {
                    let path = NSBezierPath(roundedRect: rect.offsetBy(dx: -scene.minX, dy: -scene.minY), xRadius: radius, yRadius: radius)
                    NSColor.windowBackgroundColor.withAlphaComponent(0.94).setFill(); path.fill()
                    NSColor.separatorColor.setStroke(); path.lineWidth = 0.5; path.stroke()
                }
                for (layer, frame, alpha) in layers {
                    layer.draw(in: frame.offsetBy(dx: -scene.minX, dy: -scene.minY), from: .zero, operation: .sourceOver,
                               fraction: alpha, respectFlipped: true, hints: nil)
                }
                overlay()
            }
            NSGraphicsContext.current?.flushGraphics()
            NSGraphicsContext.restoreGraphicsState()
            return png(rep)
        }
        let materialHost: String
        if #available(macOS 26.0, *) { materialHost = "NSGlassEffectView.contentView" } else { materialHost = "popover NSVisualEffectView" }
        func insideMaterial(_ view: NSView) -> Bool {
            var ancestor = view.superview
            while let current = ancestor {
                if #available(macOS 26.0, *) {
                    if let glass = current as? NSGlassEffectView { return glass.contentView.map { view.isDescendant(of: $0) } ?? false }
                } else if current is NSVisualEffectView { return true }
                ancestor = current.superview
            }
            return false
        }
        let materialNote = "probe-drawn windowBackgroundColor stand-in under the content raster; the raster holds AppKit's offscreen cacheDisplay drawing of the \(materialHost) host, not compositor material; native material is gated"
        func draw(_ cursor: NSCursor, at point: CGPoint, in scene: CGRect) {
            let size = cursor.image.size
            cursor.image.draw(in: CGRect(x: point.x - scene.minX - cursor.hotSpot.x, y: point.y - scene.minY - (size.height - cursor.hotSpot.y),
                                         width: size.width, height: size.height))
        }

        let screen = NSScreen.screens[0].frame
        var lineRaster: [String: Data] = [:]
        for look in looks {
            app.appearance = look.appearance
            let tag = look.name
            let provenance: [String: Any] = ["look": tag, "appearance": look.appearance.name.rawValue, "backdrop": backdropNote, "scale": scale,
                                             "increaseContrastInput": look.contrast]

            let scene = CGRect(x: screen.minX + 200, y: screen.minY + 200, width: 240, height: 260)
            let lineX = scene.midX, pointer = CGPoint(x: lineX, y: scene.minY + 70)
            let gripRect = CGRect(x: lineX - DividerGrip.thickness / 2, y: pointer.y + DividerGrip.clearance,
                                  width: DividerGrip.thickness, height: DividerGrip.length)
            let segment = CGRect(x: lineX - DividerGrip.segmentThickness / 2, y: scene.minY + DividerGrip.segmentInset,
                                 width: DividerGrip.segmentThickness, height: scene.height - 2 * DividerGrip.segmentInset)
            let grip = DividerGripPanel(bindHeld: { true }, activationKey: { nil }, isKeyDown: { _ in false }, input: { _ in })
            grip.place(gripRect, axis: .vertical, line: segment)
            let knobRing = { grip.contentView?.focusRingMaskBounds ?? .null }

            grip.prepare(.revealed, increaseContrast: look.contrast)
            expect(abs(grip.alphaValue - 0.8) < 0.001 && grip.lineWindow.alphaValue == grip.alphaValue && grip.ignoresMouseEvents
                    && knobRing() == CGRect(x: 10, y: 5, width: 8, height: 38),
                   "revealed handle in \(tag): 0.8 alpha, click-through, 6 by 36 knob centered in the 28 by 48 hit rect",
                   "alpha \(grip.alphaValue) ring \(knobRing())")
            let revealedGrip = png(raster(grip.contentView!))
            let line = raster(grip.lineWindow.contentView!)
            lineRaster[tag] = png(line)
            let core = opaqueWidth(line, row: (line?.pixelsHigh ?? 0) / 2)
            expect(core == (look.contrast ? 3 : 2), "the line in \(tag) is one \(look.contrast ? 3 : 2) point rule", "core \(core) points")
            save(compose(scene, look: look, windows: [grip.lineWindow, grip]) { draw(.arrow, at: pointer, in: scene) },
                 "offscreen-divider-revealed-\(tag)@2x", provenance.merging(["state": "revealed", "windows": ["line", "grip"],
                     "cursor": "NSCursor.arrow image at the revealing pointer"]) { a, _ in a })

            grip.prepare(.armed, increaseContrast: look.contrast)
            let armedGrip = png(raster(grip.contentView!))
            let column: NSCursor
            if #available(macOS 15.0, *) { column = .columnResize } else { column = .resizeLeftRight }
            expect(grip.alphaValue == 1 && !grip.ignoresMouseEvents && knobRing() == CGRect(x: 8.5, y: 3, width: 11, height: 42)
                    && grip.resizeCursor == column && armedGrip != revealedGrip,
                   "entered handle in \(tag): full alpha, takes the mouse, 9 by 40 knob and the native column resize cursor",
                   "alpha \(grip.alphaValue) ring \(knobRing())")
            save(compose(scene, look: look, windows: [grip.lineWindow, grip]) { draw(grip.resizeCursor, at: CGPoint(x: gripRect.midX + 3, y: gripRect.midY - 4), in: scene) },
                 "offscreen-divider-armed-\(tag)@2x", provenance.merging(["state": "armed", "windows": ["line", "grip"],
                     "cursor": "production resizeCursor image, drawn by the probe; delivery to an inactive panel is gated"]) { a, _ in a })

            grip.prepare(.dragging, increaseContrast: look.contrast)
            let left = HighlightWindow(style: .divider), right = HighlightWindow(style: .divider)
            let leftFrame = CGRect(x: scene.minX - 40, y: scene.minY + 10, width: lineX - scene.minX + 40, height: scene.height - 20)
            let rightFrame = CGRect(x: lineX, y: scene.minY + 10, width: scene.maxX + 40 - lineX, height: scene.height - 20)
            left.prepare(at: leftFrame, hint: nil); right.prepare(at: rightFrame, hint: nil)
            let preview = raster(right.contentView!)
            let edge = { (x: CGFloat) in preview?.colorAt(x: Int(x * scale), y: (preview?.pixelsHigh ?? 0) / 2)?.alphaComponent ?? 0 }
            expect(left.frame == leftFrame && right.frame == rightFrame && edge(1) == 0 && edge(3.5) > 0.3 && edge(10) > 0,
                   "divider previews in \(tag) keep their exact window frames and draw 3 points inside them",
                   "frames \(left.frame) \(right.frame) alpha at 1pt \(edge(1)), 3.5pt \(edge(3.5)), 10pt \(edge(10))")
            grip.showGuide("½")
            let badge = grip.guideWindow
            let lockedGrip = png(raster(grip.contentView!))
            expect(!badge.isVisible && badge.ignoresMouseEvents && !badge.canBecomeKey && lockedGrip != armedGrip
                    && badge.frame == CGRect(x: gripRect.maxX + 4, y: gripRect.midY - 15, width: 36, height: 30)
                    && !badge.frame.insetBy(dx: 4, dy: 4).intersects(gripRect),
                   "a locked guide in \(tag) fills the knob and names itself beside the hit rect without ordering a window",
                   "badge \(badge.frame) visible \(badge.isVisible)")
            save(compose(scene, look: look, windows: [left, right, grip.lineWindow, grip, badge]) {
                    draw(grip.resizeCursor, at: CGPoint(x: gripRect.midX + 3, y: gripRect.midY - 4), in: scene) },
                 "offscreen-divider-dragging-guide-\(tag)@2x", provenance.merging(["state": "dragging, guide ½ locked",
                     "windows": ["divider preview left", "divider preview right", "line", "grip", "guide badge"],
                     "note": "preview frames stand in for two ZoneScene effects meeting at the line"]) { a, _ in a })
            save(png(raster(badge.contentView!)), "offscreen-raw-badge-\(tag)@2x", provenance.merging(["state": "guide badge content view"]) { a, _ in a })
            grip.showGuide(nil)

            grip.prepare(.pinned, increaseContrast: look.contrast)
            let pinnedGrip = png(raster(grip.contentView!))
            expect(pinnedGrip == armedGrip && !badge.isVisible, "a pinned handle in \(tag) draws the entered knob and hides the badge without a guide")
            save(compose(scene, look: look, windows: [grip.lineWindow, grip]) {
                    NSGraphicsContext.saveGraphicsState()
                    let shift = NSAffineTransform()
                    shift.translateX(by: gripRect.minX - scene.minX, yBy: gripRect.minY - scene.minY); shift.concat()
                    NSFocusRingPlacement.only.set()
                    grip.contentView?.drawFocusRingMask()
                    NSGraphicsContext.restoreGraphicsState()
                    draw(.arrow, at: CGPoint(x: scene.maxX - 40, y: scene.minY + 40), in: scene) },
                 "offscreen-divider-pinned-\(tag)@2x", provenance.merging(["state": "pinned",
                     "focus": "AppKit NSFocusRingPlacement.only applied to the production drawFocusRingMask; a key window's ring is gated"]) { a, _ in a })
            if look.name == "light" || look.name == "dark" {
                for (state, data) in [("revealed", revealedGrip), ("armed", armedGrip), ("guide", lockedGrip)] {
                    save(data, "offscreen-raw-grip-\(state)-\(tag)@2x", provenance.merging(["state": "grip content view, \(state)"]) { a, _ in a })
                }
                save(png(line), "offscreen-raw-line-\(tag)@2x", provenance.merging(["state": "line content view"]) { a, _ in a })
                save(png(preview), "offscreen-raw-divider-preview-\(tag)@2x", provenance.merging(["state": "divider preview content view"]) { a, _ in a })
            }

            let hScene = CGRect(x: screen.minX + 200, y: screen.minY + 200, width: 260, height: 200)
            let lineY = hScene.midY
            let hGrip = CGRect(x: hScene.minX + 70 + DividerGrip.clearance, y: lineY - DividerGrip.thickness / 2,
                               width: DividerGrip.length, height: DividerGrip.thickness)
            grip.place(hGrip, axis: .horizontal, line: CGRect(x: hScene.minX + 4, y: lineY - 3, width: hScene.width - 8, height: 6))
            grip.prepare(.pinned, increaseContrast: look.contrast)
            let row: NSCursor
            if #available(macOS 15.0, *) { row = .rowResize } else { row = .resizeUpDown }
            expect(knobRing() == CGRect(x: 3, y: 8.5, width: 42, height: 11) && grip.resizeCursor == row,
                   "a horizontal handle in \(tag) transposes the knob and uses the native row resize cursor", "ring \(knobRing())")
            grip.showGuide("⅓")
            expect(!badge.isVisible && badge.frame.minY == hGrip.maxY + 4 && abs(badge.frame.midX - hGrip.midX) < 0.5,
                   "a horizontal handle in \(tag) names its guide above itself", "badge \(badge.frame)")
            save(compose(hScene, look: look, vertical: false, windows: [grip.lineWindow, grip, badge]) {
                    draw(grip.resizeCursor, at: CGPoint(x: hGrip.midX - 4, y: hGrip.midY + 2), in: hScene) },
                 "offscreen-divider-horizontal-guide-\(tag)@2x", provenance.merging(["state": "pinned horizontal, guide ⅓ locked",
                     "windows": ["line", "grip", "guide badge"]]) { a, _ in a })
            grip.hide()

            let edgeGrip = CGRect(x: screen.maxX - 30, y: screen.minY + 300, width: DividerGrip.thickness, height: DividerGrip.length)
            grip.place(edgeGrip, axis: .vertical, line: CGRect(x: edgeGrip.midX - 3, y: screen.minY + 4, width: 6, height: 600))
            grip.prepare(.dragging, increaseContrast: look.contrast)
            grip.showGuide("¾")
            expect(badge.frame.maxX == edgeGrip.minX - 4 && screen.contains(badge.frame),
                   "at the display edge in \(tag) the badge flips beside the handle and stays on the display", "badge \(badge.frame)")
            grip.hide()
            stillPassive("divider \(tag)")

            let zone = CGRect(x: screen.minX + 220, y: screen.minY + 220, width: 420, height: 300)
            let shareScene = zone.insetBy(dx: -20, dy: -20)
            let targets = ShareTarget.targets(in: zone)
            let rail = ShareRailPanel()
            var railBitmaps: [Data?] = []
            for (state, active) in [("idle", nil), ("side", targets.first { $0.axis == .vertical }), ("stacked", targets.first { $0.axis == .horizontal })] as [(String, ShareTarget?)] {
                rail.prepare(targets: targets, active: active)
                let union = targets.dropFirst().reduce(targets[0].rect) { $0.union($1.rect) }
                let tiles = views(rail.contentView).filter { $0.accessibilityRole() == .image }
                expect(rail.appearance == nil && rail.ignoresMouseEvents && !rail.hidesOnDeactivate && !rail.isVisible
                        && rail.frame == CGRect(x: union.minX - 6, y: union.minY - 24, width: union.width + 12, height: union.height + 30)
                        && tiles.count == 2 && tiles.allSatisfy { $0.frame.size == CGSize(width: 40, height: 32) }
                        && views(rail.contentView).contains { ($0 as? NSTextField)?.stringValue == (active.map { $0.axis == .vertical ? "Side by side" : "Stacked" } ?? "Share zone") },
                       "the \(state) share rail in \(tag) follows the system appearance with its exact 40 by 32 targets and caption",
                       "frame \(rail.frame) tiles \(tiles.map(\.frame)) appearance \(String(describing: rail.appearance))")
                let target = HighlightWindow(), neighbor = HighlightWindow(style: .neighbor)
                var context: [NSWindow] = [target]
                switch active?.axis {
                case .vertical?:
                    target.prepare(at: CGRect(x: zone.midX, y: zone.minY, width: zone.width / 2, height: zone.height), hint: nil)
                    neighbor.prepare(at: CGRect(x: zone.minX, y: zone.minY, width: zone.width / 2, height: zone.height), hint: nil)
                    context.insert(neighbor, at: 0)
                case .horizontal?:
                    target.prepare(at: CGRect(x: zone.minX, y: zone.minY, width: zone.width, height: zone.height / 2), hint: nil)
                    neighbor.prepare(at: CGRect(x: zone.minX, y: zone.midY, width: zone.width, height: zone.height / 2), hint: nil)
                    context.insert(neighbor, at: 0)
                case nil:
                    target.prepare(at: zone, hint: nil)
                }
                let content = raster(rail.contentView!)
                railBitmaps.append(png(content))
                save(compose(shareScene, look: look, split: zone.minX + 140, standIn: [(rail.frame, 14)], windows: context + [rail]),
                     "offscreen-share-\(state)-\(tag)@2x", provenance.merging(["state": "share \(state)",
                         "windows": (active == nil ? [] : ["neighbor preview"]) + ["target preview", "share rail content"],
                         "material": materialNote]) { a, _ in a })
                if look.name == "light" || look.name == "dark" {
                    save(png(content), "offscreen-raw-share-\(state)-\(tag)@2x", provenance.merging(["state": "share rail root view, \(state)",
                         "material": "AppKit's offscreen cacheDisplay drawing of the \(materialHost) host, not compositor material"]) { a, _ in a })
                }
            }
            expect(Set(railBitmaps.compactMap { $0 }).count == 3, "idle, side by side and stacked rails in \(tag) each draw differently")
            let railForeground = views(rail.contentView).filter { $0.accessibilityRole() == .image || $0 is NSTextField }
            expect(railForeground.count == 3 && railForeground.allSatisfy(insideMaterial),
                   "the share rail's two tiles and caption in \(tag) are inside the native \(materialHost)",
                   "foreground \(railForeground.map { type(of: $0) }) inside \(railForeground.map(insideMaterial))")
            stillPassive("share \(tag)")

            let visible = CGRect(x: screen.minX + 200, y: screen.minY + 200, width: 1200, height: 700)
            let free = CGRect(x: visible.midX, y: visible.minY, width: visible.width / 2, height: visible.height)
            let filled = CGRect(x: visible.minX, y: visible.minY, width: visible.width / 2, height: visible.height)
            let icon = NSWorkspace.shared.icon(for: .application)
            let sample = (0..<5).map { ZoneFillPanel.Candidate(app: "Fixture \($0)", title: "Document-free window \($0)",
                                                                display: $0 == 4 ? "Other display" : nil, icon: icon) }
            func source(_ size: CGSize, _ color: NSColor) -> CGImage? {
                NSImage(size: size, flipped: false) { rect in
                    color.setFill(); rect.fill()
                    NSColor.white.setFill(); rect.insetBy(dx: rect.width / 6, dy: rect.height / 6).fill()
                    return true
                }.cgImage(forProposedRect: nil, context: nil, hints: nil)
            }
            var selected: [Int] = [], cancels = 0
            let fill = ZoneFillPanel(select: { selected.append($0) }, cancel: { cancels += 1 })
            fill.prepare(sample, free: free, filled: filled, visible: visible)
            func shot(_ state: String, _ note: String, split: CGFloat) -> Data? {
                save(compose(fill.frame.insetBy(dx: -40, dy: -28), look: look, split: split, standIn: [(fill.frame, 16)], windows: [fill]),
                     "offscreen-chooser-\(state)-\(tag)@2x", provenance.merging(["state": "window suggestions \(note)",
                         "windows": ["chooser content"], "material": materialNote,
                         "focus": "automatic presentation without key focus; a key window's accent ring is gated"]) { a, _ in a })
                return png(raster(fill.contentView!))
            }
            let cards = views(fill.contentView).compactMap { $0 as? NSButton }.filter { $0.accessibilityLabel()?.hasPrefix("Fixture ") == true }
            let close = views(fill.contentView).compactMap { $0 as? NSButton }.first { $0.title == "Close" }
            let heading = views(fill.contentView).compactMap { $0 as? NSTextField }.first { $0.stringValue == "Fill this zone" }
            guard cards.count == 5, let close, let heading else { expect(false, "the chooser in \(tag) exposes five cards, Close and its heading"); continue }
            let columns = ZoneFillLayout.columns(panelWidth: ZoneFillLayout.chooserFrame(free: free, filled: filled, visible: visible, rows: 1).width)
            expect(!fill.isVisible && !fill.isKeyWindow && fill.firstResponder === fill && app.keyWindow == nil
                    && fill.frame == ZoneFillLayout.chooserFrame(free: free, filled: filled, visible: visible, rows: (5 + columns - 1) / columns)
                    && free.insetBy(dx: 12, dy: 12).contains(fill.frame) && fill.frame.minX > filled.maxX,
                   "suggestions in \(tag) are prepared inside the free zone beside the drop without ordering, key focus or a first responder",
                   "frame \(fill.frame) visible \(fill.isVisible) responder \(String(describing: fill.firstResponder))")
            expect(cards.allSatisfy { $0.acceptsFirstMouse(for: nil) } && close.acceptsFirstMouse(for: nil)
                    && cards.allSatisfy { ($0.accessibilityValue() as? String) == "Loading preview" }
                    && close.accessibilityLabel() == "Cancel window selection",
                   "every card and Close in \(tag) take the first click, pending cards say so and Close keeps its accessible action")
            let foreground = views(fill.contentView).filter { $0 is NSTextField || $0 is NSButton || $0 is NSScrollView }
            expect(foreground.count >= 8 && foreground.allSatisfy(insideMaterial)
                    && abs(heading.convert(heading.bounds, to: nil).minX - cards[0].convert(cards[0].bounds, to: nil).minX) < 0.5,
                   "the chooser's heading, Close, cards and scroll view in \(tag) sit inside the native \(materialHost) on one content column")
            var drawings = [shot("pending", "with every preview pending", split: free.minX)]
            fill.setThumbnail(source(CGSize(width: 960, height: 600), .systemTeal), at: 0)
            fill.setThumbnail(nil, at: 1)
            fill.setThumbnail(source(CGSize(width: 120, height: 80), .systemIndigo), at: 2)
            fill.setThumbnail(source(CGSize(width: 600, height: 900), .systemOrange), at: 3)
            expect(cards.map { $0.accessibilityValue() as? String } == ["", "Preview unavailable", "", "", "Loading preview"],
                   "loaded, failed and pending previews in \(tag) expose their actual state")
            drawings.append(shot("loaded", "with loaded, unavailable and pending previews", split: free.minX))
            if let event = NSEvent.mouseEvent(with: .mouseMoved, location: cards[2].convert(CGPoint(x: 20, y: 20), to: nil), modifierFlags: [],
                    timestamp: 0, windowNumber: fill.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0) {
                cards[2].mouseMoved(with: event)
            }
            expect(fill.selectedIndex == 2 && fill.firstResponder === fill && !fill.isKeyWindow,
                   "pointer motion in \(tag) moves the quiet ring without taking focus")
            drawings.append(shot("hover", "with the pointer on the third card", split: free.minX))
            cards[2].highlight(true)
            drawings.append(shot("pressed", "with the third card pressed", split: free.minX))
            cards[2].highlight(false)
            close.highlight(true)
            drawings.append(shot("close-pressed", "with Close pressed", split: free.minX))
            close.highlight(false)
            expect(Set(drawings.compactMap { $0 }).count == 5,
                   "pending, loaded, hover, pressed and Close-pressed suggestions in \(tag) each draw differently")
            _ = cards[3].sendAction(cards[3].action, to: cards[3].target)
            _ = close.sendAction(close.action, to: close.target)
            expect(selected == [3] && cancels == 1 && !fill.isVisible && app.keyWindow == nil,
                   "a card's action in \(tag) selects exactly its own window and Close cancels, without ordering or focus")
            if tag == "light" {
                selected = []; cancels = 0
                fill.prepare(Array(sample.prefix(4)), free: free, filled: filled, visible: visible)
                func press(_ code: UInt16, _ characters: String) {
                    if let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                            windowNumber: fill.windowNumber, context: nil, characters: characters,
                            charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code) {
                        fill.sendEvent(event)
                    }
                }
                press(124, "\u{f703}"); press(124, "\u{f703}")
                let afterRight = fill.selectedIndex
                press(125, "\u{f701}")
                let afterDown = fill.selectedIndex
                press(126, "\u{f700}"); press(124, "\u{f703}"); press(36, "\r"); press(53, "\u{1b}")
                expect(afterRight == 2 && afterDown == 3 && selected == [1] && cancels == 1 && !fill.isVisible && app.keyWindow == nil,
                       "the production key handling used after explicit entry moves the ring without wrapping, Return selects it and Escape cancels",
                       "right \(afterRight), down \(afterDown), selected \(selected), cancels \(cancels)")
            }
            if tag == "light" || tag == "dark" {
                let long = (0..<32).map { ZoneFillPanel.Candidate(app: "Fixture \($0)", title: "Overflow window \($0)", display: nil, icon: icon) }
                fill.prepare(long, free: free, filled: filled, visible: visible)
                let scroller = views(fill.contentView).compactMap { $0 as? NSScrollView }.first
                expect(fill.frame.height == ZoneFillLayout.maximum.height
                        && (scroller?.documentView?.frame.height ?? 0) > (scroller?.contentSize.height ?? .infinity),
                       "32 suggestions in \(tag) keep the 440-point chooser and scroll inside it")
                _ = shot("overflow", "with 32 windows", split: free.minX)
                let narrowFree = CGRect(x: visible.maxX - 400, y: visible.minY, width: 400, height: visible.height)
                let narrowFilled = CGRect(x: visible.minX, y: visible.minY, width: visible.width - 400, height: visible.height)
                fill.prepare(sample, free: narrowFree, filled: narrowFilled, visible: visible)
                expect(narrowFree.insetBy(dx: 12, dy: 12).contains(fill.frame) && ZoneFillLayout.columns(panelWidth: fill.frame.width) == 2
                        && fill.frame.minX > narrowFilled.maxX,
                       "a 400-point free zone in \(tag) gets a two-column chooser inside it, off the placed window", "frame \(fill.frame)")
                _ = shot("narrow", "in a 400-point free zone", split: narrowFree.minX)
                let small = CGRect(x: visible.midX - 100, y: visible.minY, width: 200, height: visible.height)
                let placed = CGRect(x: visible.minX, y: visible.minY, width: small.minX - visible.minX, height: visible.height)
                fill.prepare(sample, free: small, filled: placed, visible: visible)
                expect(fill.frame.minX == placed.maxX + 12 && visible.contains(fill.frame) && fill.frame.intersects(small),
                       "a free zone too small for one column in \(tag) moves the chooser 12 points past the placed window, still over its zone",
                       "frame \(fill.frame)")
                _ = shot("too-small", "for a 200-point free zone, moved off the placed window", split: placed.maxX)
                let leftFree = CGRect(x: visible.minX, y: visible.minY, width: 300, height: visible.height)
                let leftFilled = CGRect(x: leftFree.maxX, y: visible.minY, width: 300, height: visible.height)
                fill.prepare(sample, free: leftFree, filled: leftFilled, visible: visible)
                expect(fill.frame == CGRect(x: visible.minX + 92, y: visible.minY + 130, width: 196, height: 440)
                        && ZoneFillLayout.columns(panelWidth: fill.frame.width) == 1 && !fill.isVisible && fill.firstResponder === fill,
                       "a 300-point free zone left of the drop in \(tag) keeps a one-column chooser inside it, beside the placed window",
                       "frame \(fill.frame)")
                _ = shot("left-one-column", "in a 300-point free zone left of the drop", split: leftFree.maxX)
                let edgeFree = CGRect(x: visible.minX, y: visible.minY, width: 200, height: visible.height)
                let edgeFilled = CGRect(x: edgeFree.maxX, y: visible.minY, width: 200, height: visible.height)
                fill.prepare(sample, free: edgeFree, filled: edgeFilled, visible: visible)
                expect(fill.frame == CGRect(x: visible.minX + 12, y: visible.minY + 156, width: 532, height: 388),
                       "a free zone too small for one column at the left display edge in \(tag) keeps the chooser over it instead of past the placed window",
                       "frame \(fill.frame)")
                _ = shot("left-too-small", "for a 200-point free zone at the left display edge, overlapping the placed window", split: edgeFree.maxX)
            }
            stillPassive("chooser \(tag)")
        }
        expect(lineRaster["light"] != lineRaster["dark"] && lineRaster["light"] != lineRaster["contrast-light"],
               "the line resolves its color per appearance and widens with Increase Contrast")
        app.appearance = nil
        drewViews = true
        stillPassive("end")
        return finish()
    }

    private static func views(_ view: NSView?) -> [NSView] {
        guard let view else { return [] }
        return [view] + view.subviews.flatMap { views($0) }
    }
}

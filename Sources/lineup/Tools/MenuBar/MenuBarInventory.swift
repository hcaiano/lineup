import AppKit
import AppCore
import ApplicationServices

struct MenuBarObservedItem: Identifiable {
    let id: String
    let owner: String
    let appName: String
    let title: String
    let icon: NSImage
    let element: AXUIElement
    let pid: pid_t
    let launchDate: Date?
    let frame: CGRect
}

enum MenuBarInventory {
    private static let queue = DispatchQueue(label: "lineup.menu-bar.inventory", qos: .userInitiated)
    @MainActor private static var pendingMouseUp: (() -> Void)?

    @MainActor
    static func cancelMove() {
        let release = pendingMouseUp
        pendingMouseUp = nil
        release?()
    }

    @MainActor
    static func read(completion: @escaping ([MenuBarObservedItem]) -> Void) {
        guard AXIsProcessTrusted() else { completion([]); return }
        let apps = NSWorkspace.shared.runningApplications.filter {
            !$0.isTerminated && $0.bundleIdentifier.map {
                MenuBarPreferences.isOrganizable($0, excluding: Set([Bundle.main.bundleIdentifier, Product.bundleID].compactMap { $0 }))
            } == true
        }.map { app in
            (app.processIdentifier, app.bundleIdentifier!, app.localizedName ?? app.bundleIdentifier!,
             app.icon ?? NSImage(named: NSImage.applicationIconName)!, app.launchDate,
             app.bundleURL?.path ?? "")
        }
        queue.async {
            var result: [MenuBarObservedItem] = []
            for (pid, owner, name, icon, date, bundlePath) in apps {
                let app = AXUIElementCreateApplication(pid)
                AXUIElementSetMessagingTimeout(app, 0.1)
                var bar: CFTypeRef?
                guard AXUIElementCopyAttributeValue(app, kAXExtrasMenuBarAttribute as CFString, &bar) == .success,
                      let bar, CFGetTypeID(bar) == AXUIElementGetTypeID() else { continue }
                var children: CFTypeRef?
                guard AXUIElementCopyAttributeValue(bar as! AXUIElement, kAXChildrenAttribute as CFString,
                                                   &children) == .success,
                      let items = children as? [AXUIElement] else { continue }
                for (index, item) in items.enumerated() {
                    guard let frame = frame(item) else { continue }
                    let title = string(item, kAXDescriptionAttribute) ?? string(item, kAXTitleAttribute) ?? name
                    // Development copies can share a bundle ID with an installed app.
                    // Their rows must remain distinct, although visibility is per owner.
                    var id = "\(owner)#\(bundlePath)#\(index)"
                    if result.contains(where: { $0.id == id }) { id += "@\(pid)" }
                    result.append(MenuBarObservedItem(id: id, owner: owner,
                        appName: name, title: title.isEmpty ? name : title, icon: icon,
                        element: item, pid: pid, launchDate: date, frame: frame))
                }
            }
            let ordered = result.sorted { $0.frame.minX < $1.frame.minX }
            DispatchQueue.main.async { completion(ordered) }
        }
    }

    @MainActor
    static func read() async -> [MenuBarObservedItem] {
        await withCheckedContinuation { continuation in
            read { continuation.resume(returning: $0) }
        }
    }

    private static func string(_ element: AXUIElement, _ key: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, key as CFString, &value) == .success else { return nil }
        return value as? String
    }

    static func frame(_ element: AXUIElement) -> CGRect? {
        var position: CFTypeRef?, size: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &position) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &size) == .success,
              let position, let size, CFGetTypeID(position) == AXValueGetTypeID(),
              CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero, dimensions = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &point),
              AXValueGetValue(size as! AXValue, .cgSize, &dimensions),
              dimensions.width > 0, dimensions.height > 0 else { return nil }
        return CGRect(origin: point, size: dimensions)
    }

    @MainActor
    static func move(_ source: MenuBarObservedItem, before target: MenuBarObservedItem) async throws {
        func failure(_ text: String) -> MenuBarPreferenceAccess.Failure { .init(message: text) }
        guard AXIsProcessTrusted(), CGPreflightPostEventAccess() else {
            throw failure("Allow Accessibility for Lineup before arranging menu bar items.")
        }
        guard NSEvent.pressedMouseButtons == 0,
              CGEventSource.flagsState(.combinedSessionState).intersection([.maskCommand, .maskShift, .maskControl, .maskAlternate]).isEmpty else {
            throw failure("Release the mouse and modifier keys, then try again.")
        }
        guard NSRunningApplication(processIdentifier: source.pid)?.launchDate == source.launchDate,
              NSRunningApplication(processIdentifier: target.pid)?.launchDate == target.launchDate,
              let from = frame(source.element), let to = frame(target.element),
              from.minX >= 0, to.minX >= 0, abs(from.midY - to.midY) < 2 else {
            throw failure("Show the items on the same menu bar before moving them.")
        }
        let start = CGPoint(x: from.midX, y: from.midY)
        let end = CGPoint(x: to.minX + (from.minX < to.minX ? -2 : 2), y: to.midY)
        let cursor = CGEvent(source: nil)?.location
        let eventSource = CGEventSource(stateID: .privateState)
        var lastPoint = start
        func post(_ type: CGEventType, at point: CGPoint) {
            let event = CGEvent(mouseEventSource: eventSource, mouseType: type, mouseCursorPosition: point, mouseButton: .left)
            event?.flags = .maskCommand
            event?.post(tap: .cghidEventTap)
        }
        pendingMouseUp = {
            post(.leftMouseUp, at: lastPoint)
            if let cursor, let now = CGEvent(source: nil)?.location,
               abs(now.x - lastPoint.x) < 3, abs(now.y - lastPoint.y) < 3 { CGWarpMouseCursorPosition(cursor) }
        }
        post(.leftMouseDown, at: start)
        defer { cancelMove() }
        for step in 1...12 {
            try await Task.sleep(nanoseconds: 20_000_000)
            let t = CGFloat(step) / 12
            lastPoint = CGPoint(x: start.x + (end.x - start.x) * t, y: start.y)
            post(.leftMouseDragged, at: lastPoint)
        }
    }
}

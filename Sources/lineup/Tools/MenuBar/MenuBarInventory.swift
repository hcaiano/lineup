import AppKit
import AppCore
import ApplicationServices

struct MenuBarObservedItem: Identifiable {
    let id: String
    let owner: String
    let appName: String
    let title: String
    let icon: NSImage
    let frame: CGRect
}

/// Reads other apps' menu bar items through Accessibility. It never reads their menus and never
/// posts input events: users arrange items themselves with Command-drag.
enum MenuBarInventory {
    private static let queue = DispatchQueue(label: "lineup.menu-bar.inventory", qos: .userInitiated)

    @MainActor
    static func read(completion: @escaping ([MenuBarObservedItem]) -> Void) {
        guard AXIsProcessTrusted() else { completion([]); return }
        let own = Set([Bundle.main.bundleIdentifier, Product.bundleID].compactMap { $0 })
        let apps = NSWorkspace.shared.runningApplications.filter {
            !$0.isTerminated && $0.bundleIdentifier.map {
                !$0.isEmpty && !own.contains($0) && !$0.hasPrefix("com.apple.")
            } == true
        }.map { app in
            return (app.processIdentifier, app.bundleIdentifier!, app.localizedName ?? app.bundleIdentifier!,
                    app.icon ?? NSImage(named: NSImage.applicationIconName)!, app.bundleURL?.path ?? "")
        }
        queue.async {
            var result: [MenuBarObservedItem] = []
            for (pid, owner, name, icon, bundlePath) in apps {
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
                    result.append(MenuBarObservedItem(id: id, owner: owner, appName: name,
                        title: title.isEmpty ? name : title, icon: icon, frame: frame))
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

    /// Global top-left bounds shared by Accessibility and Core Graphics.
    @MainActor
    static func displayBounds() -> [CGRect] {
        NSScreen.screens.compactMap { screen -> CGRect? in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
            return CGDisplayBounds(CGDirectDisplayID(number.uint32Value))
        }
    }

    /// The menu bar strip of each display, in the same coordinates.
    @MainActor
    static func menuBars() -> [CGRect] {
        NSScreen.screens.compactMap { screen -> CGRect? in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
            let bounds = CGDisplayBounds(CGDirectDisplayID(number.uint32Value))
            let height = max(NSStatusBar.system.thickness, screen.frame.maxY - screen.visibleFrame.maxY)
            return CGRect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: height)
        }
    }

    /// Owner, layer and bounds are available without Screen Recording; titles are not read.
    static func windows() -> [MenuBarAutoHide.Window] {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        return list.compactMap { info in
            guard let pid = info[kCGWindowOwnerPID as String] as? Int32,
                  let layer = info[kCGWindowLayer as String] as? Int,
                  let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary) else { return nil }
            return MenuBarAutoHide.Window(pid: pid, layer: layer, bounds: rect)
        }
    }
}

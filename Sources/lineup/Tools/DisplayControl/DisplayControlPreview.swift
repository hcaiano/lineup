#if DEBUG
import AppKit
import AppCore
import DisplayControlCore
import SwiftUI

/// Uses the actual controls and read-only hardware discovery before the app shell opens config.
@MainActor
enum DisplayControlPreview {
    static func render(to directory: String) {
        DispatchQueue(label: "com.caiano.lineup.display-preview").async {
            let transport = DisplayTransport()
            let displays = transport.discover()
            transport.invalidate()
            DispatchQueue.main.async {
                let tool = DisplayControlTool.preview(displays: displays)
                let settings = ToolPane(id: tool.id, title: tool.displayName, summary: tool.summary,
                                        isOn: .constant(true)) {
                    tool.makeSettingsPane()
                }
                write(NSHostingView(rootView: settings.background(Color(nsColor: .windowBackgroundColor))), size: NSSize(width: 720, height: 1000),
                      path: "\(directory)/display-control-settings.png")
                write(NSHostingView(rootView: settings.background(Color(nsColor: .windowBackgroundColor))),
                      size: NSSize(width: 640, height: 540),
                      path: "\(directory)/display-control-settings-compact.png")
                write(NSHostingView(rootView: DisplayControlMenuView(tool: tool).background(Color(nsColor: .windowBackgroundColor))),
                      size: NSSize(width: 320, height: min(520, CGFloat(max(1, displays.count)) * 235 + 45)),
                      path: "\(directory)/display-control-menu.png")

                var synchronized = DisplayControlSettings()
                synchronized.brightnessKeys = true
                synchronized.synchronizeBrightness = true
                synchronized.blackScreenBelowMinimum = true
                if let first = displays.first {
                    var preferences = DisplayControlSettings.MonitorPreferences()
                    preferences.brightnessMinimum = 0.1
                    preferences.brightnessLimit = 0.8
                    synchronized.monitors[first.monitor.stableID] = preferences
                }
                let synchronizedTool = DisplayControlTool.preview(displays: displays, settings: synchronized)
                let synchronizedSettings = ToolPane(id: synchronizedTool.id, title: synchronizedTool.displayName,
                                                    summary: synchronizedTool.summary, isOn: .constant(true)) {
                    synchronizedTool.makeSettingsPane()
                }
                write(NSHostingView(rootView: synchronizedSettings.background(Color(nsColor: .windowBackgroundColor))),
                      size: NSSize(width: 720, height: 1000),
                      path: "\(directory)/display-control-sync-settings.png")

                if let first = displays.first {
                    // This fixture enters only an isolated view model, never a transport.
                    let sample = DisplayTransportMonitor(
                        monitor: DisplayControlMonitor(stableID: "preview:sample-second-display",
                                                       connection: UUID(), name: "Sample second display",
                                                       brightness: .init(availability: .supported,
                                                                         level: DisplayControlLevel(current: 50, maximum: 100)),
                                                       volume: .init(availability: .unsupported("Sample display has no volume control."))),
                        displayID: 0, connectionDescription: "Sample layout; not connected")
                    let twoDisplays = DisplayControlTool.preview(displays: [first, sample], settings: synchronized)
                    writeQuickPanel(twoDisplays, path: "\(directory)/preview-two-display-controls.png")
                    print("Two-display layout includes ‘Sample second display’; only the first display is detected hardware.")
                    let blackState = DisplayControlTool.preview(displays: [first, sample], settings: synchronized,
                                                               blackedOutConnections: [sample.monitor.connection])
                    writeQuickPanel(blackState, path: "\(directory)/preview-black-screen-controls.png")
                    write(NSHostingView(rootView: DisplayControlMonitorView(tool: blackState, monitor: sample.monitor)
                        .padding(24).background(Color(nsColor: .windowBackgroundColor))),
                        size: NSSize(width: 540, height: 280),
                        path: "\(directory)/preview-black-screen-settings-row.png")
                    print("Sample black-screen state previews recovery controls; no display is covered or changed.")
                }
                for display in displays {
                    let monitor = display.monitor
                    print("\(monitor.name) [\(display.connectionDescription)]")
                    for control in [DisplayControlCore.DisplayControl.brightness, .volume] {
                        if let level = monitor[control].level {
                            print("  \(control.rawValue): \(level.current)/\(level.maximum)")
                        } else { print("  \(control.rawValue): \(monitor[control].availability), \(monitor[control].error ?? "no confirmed value")") }
                    }
                }
                NSApp.terminate(nil)
            }
        }
    }

    private static func writeQuickPanel(_ tool: DisplayControlTool, path: String) {
        let controller = NSHostingController(rootView: DisplayControlQuickPanel(tool: tool)
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 16)
            .frame(width: 352))
        let size = NSSize(width: 352, height: ceil(controller.view.fittingSize.height))
        controller.preferredContentSize = size
        let anchor = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 40, height: 20),
                             styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        anchor.isReleasedWhenClosed = false
        anchor.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 40, height: 20))
        anchor.center()
        anchor.orderFrontRegardless()
        let popover = NSPopover()
        popover.behavior = .applicationDefined
        popover.animates = false
        popover.contentViewController = controller
        popover.contentSize = size
        popover.show(relativeTo: anchor.contentView!.bounds, of: anchor.contentView!, preferredEdge: .minY)
        // Capture composed native material; caching an offscreen glass view omits its backdrop.
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        if let window = controller.view.window {
            let capture = Process()
            capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            capture.arguments = ["-x", "-l", String(window.windowNumber), path]
            do {
                try capture.run()
                capture.waitUntilExit()
            } catch {
                fputs("Display preview capture failed: \(error.localizedDescription)\n", stderr)
            }
        }
        popover.close()
        anchor.orderOut(nil)
    }

    private static func write(_ view: NSView, size: NSSize, path: String) {
        view.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = view
        window.appearance = NSAppearance(named: .aqua)
        view.layoutSubtreeIfNeeded()
        view.display()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
}
#endif

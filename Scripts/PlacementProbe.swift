import AppKit
#if DISCOVERY_CHECK
import ApplicationServices
import ZonesCore
#endif

// Manual Zones verification fixture. It owns no documents, saved window frames, or user data.
// Every process starts at the same frame, so macOS window restoration cannot fake a PASS.
final class PlacementProbe: NSObject, NSApplicationDelegate {
    private var windows: [NSWindow] = []
    private var splash: NSPanel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let menu = NSMenu()
        let appItem = NSMenuItem()
        menu.addItem(appItem)
        let appMenu = NSMenu()
        appItem.submenu = appMenu
        appMenu.addItem(withTitle: "New Window", action: #selector(newWindow), keyEquivalent: "n").target = self
        let move = appMenu.addItem(withTitle: "Move Freely", action: #selector(moveFreely), keyEquivalent: "m")
        move.keyEquivalentModifierMask = [.command, .shift]
        move.target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Placement Probe", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        NSApp.mainMenu = menu
        NSApp.activate(ignoringOtherApps: true)
        if CommandLine.arguments.contains("--busy-start") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                Thread.sleep(forTimeInterval: 2)
            }
        }
        let splashDelay: TimeInterval = CommandLine.arguments.contains("--long-splash") ? 8 : 3
        if CommandLine.arguments.contains("--splash") || CommandLine.arguments.contains("--long-splash") {
            let panel = NSPanel(contentRect: CGRect(x: 160, y: 200, width: 650, height: 300),
                                styleMask: [.titled, .utilityWindow], backing: .buffered, defer: false)
            panel.title = "Transient launch panel"
            panel.contentView = label("Transient panel\nThe first regular window opens in \(Int(splashDelay)) seconds.")
            panel.orderFrontRegardless()
            splash = panel
            DispatchQueue.main.asyncAfter(deadline: .now() + splashDelay) { [self] in
                splash?.orderOut(nil)
                splash = nil
                newWindow()
            }
        } else {
            newWindow()
        }
    }

    @objc private func newWindow() {
        let number = windows.count + 1
        let frame = CGRect(x: 180 + number * 30, y: 180 + number * 30, width: 900, height: 740)
        let window = NSWindow(contentRect: frame, styleMask: [.titled, .closable, .resizable, .miniaturizable],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "Placement Probe: window \(number)"
        window.contentView = label("Window \(number)\n\nPlace with a Zones shortcut or Shift-drag.\nShift-Command-M: move freely\nCommand-N: another window\nCommand-Q: quit\n\nEvery launch starts at a fixed frame.\nThis app never saves window positions.")
        windows.append(window)
        window.makeKeyAndOrderFront(nil)
        if number == 1, CommandLine.arguments.contains("--busy-document") {
            NSAccessibility.post(element: window, notification: .created)
            Thread.sleep(forTimeInterval: 2)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [self] in newWindow() }
        }
    }

    @objc private func moveFreely() {
        NSApp.keyWindow?.setFrame(CGRect(x: 300, y: 240, width: 950, height: 760), display: true)
    }

    private func label(_ text: String) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 24)
        label.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 36),
            label.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -36),
            label.topAnchor.constraint(equalTo: view.topAnchor, constant: 40)
        ])
        return view
    }
}

#if DISCOVERY_CHECK
/// Optional live check, compiled with the production controller by placement-probe.sh.
/// It measures discovery latency without launching Lineup or changing any user settings.
@main
@MainActor
struct DiscoveryCheck {
    static func main() {
        guard AXIsProcessTrusted(), CommandLine.arguments.count >= 2 else {
            print("BLOCKED: Accessibility access and the probe app path are required.")
            exit(2)
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let cancelDuringStartup = CommandLine.arguments.contains("--cancel")
        let unreadableDocument = CommandLine.arguments.contains("--unknown-window")
        let started = ProcessInfo.processInfo.systemUptime
        var lastTick = started
        var longestTick: TimeInterval = 0
        var fixture: NSRunningApplication?
        var controller: AppLaunchPlacementController!
        var finished = false
        let config = NSWorkspace.OpenConfiguration()
        config.arguments = ["--long-splash", unreadableDocument ? "--busy-document" : "--busy-start"]
        config.createsNewApplicationInstance = true
        let frame = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let target = AppZonePlacement(screenKey: "probe", layout: .halves,
                                      target: CGRect(x: 500, y: 0, width: 500, height: 800),
                                      frame: frame, visibleFrame: frame, pixelsWide: 1000)
        func fixtureWindowCount() -> Int {
            guard let fixture else { return 0 }
            let element = AXUIElementCreateApplication(fixture.processIdentifier)
            AXUIElementSetMessagingTimeout(element, 0.25)
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, kAXWindowsAttribute as CFString, &value) == .success else { return 0 }
            return (value as? [AXUIElement])?.count ?? 0
        }
        func finish(_ success: Bool, _ message: String) {
            guard !finished else { return }
            finished = true
            controller.stop()
            fixture?.terminate()
            print(message)
            // Allow the document-free fixture to process termination before the checker exits.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { exit(success ? 0 : 1) }
        }
        controller = AppLaunchPlacementController(placement: { bundle in
            bundle == "com.caiano.lineup.placement-probe" ? target : nil
        }, restore: { _, _ in
            if cancelDuringStartup { finish(false, "FAIL: discovery delivered a window after stop."); return }
            if unreadableDocument { finish(false, "FAIL: an unreadable first document allowed a later restoration."); return }
            let elapsed = ProcessInfo.processInfo.systemUptime - started
            let responsive = longestTick < 0.2
            finish(responsive && elapsed >= 7,
                   "\(responsive && elapsed >= 7 ? "PASS" : "FAIL"): first regular window after \(String(format: "%.2f", elapsed))s; maximum main-loop tick gap \(String(format: "%.3f", longestTick))s (limit 0.200s).")
        })
        controller.start()
        let timer = Timer.scheduledTimer(withTimeInterval: 0.02, repeats: true) { _ in
            let now = ProcessInfo.processInfo.systemUptime
            longestTick = max(longestTick, now - lastTick)
            lastTick = now
        }
        NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: CommandLine.arguments[1]), configuration: config) { running, error in
            DispatchQueue.main.async {
                fixture = running
                if let error { finish(false, "FAIL: probe launch: \(error.localizedDescription)") }
            }
        }
        if cancelDuringStartup {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { controller.stop() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 10) {
                let passed = longestTick < 0.2 && fixtureWindowCount() >= 1
                finish(passed,
                       "\(passed ? "PASS" : "FAIL"): stop during busy startup discarded later window; maximum main-loop tick gap \(String(format: "%.3f", longestTick))s.")
            }
        }
        if unreadableDocument {
            DispatchQueue.main.asyncAfter(deadline: .now() + 12) {
                let passed = longestTick < 0.2 && fixtureWindowCount() >= 2
                finish(passed,
                       "\(passed ? "PASS" : "FAIL"): unreadable first document left both windows untouched; maximum main-loop tick gap \(String(format: "%.3f", longestTick))s.")
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) {
            finish(false, "FAIL: no regular window discovered; maximum main-loop tick gap \(longestTick)s.")
        }
        withExtendedLifetime(timer) { app.run() }
    }
}
#else
@main
struct ProbeMain {
    static func main() {
        let app = NSApplication.shared
        let delegate = PlacementProbe()
        app.setActivationPolicy(.regular)
        app.delegate = delegate
        app.run()
    }
}
#endif

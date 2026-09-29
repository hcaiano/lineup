import AppKit

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
        if CommandLine.arguments.contains("--splash") {
            let panel = NSPanel(contentRect: CGRect(x: 160, y: 200, width: 650, height: 300),
                                styleMask: [.titled, .utilityWindow], backing: .buffered, defer: false)
            panel.title = "Transient launch panel"
            panel.contentView = label("Transient panel\nThe first regular window opens in 3 seconds.")
            panel.orderFrontRegardless()
            splash = panel
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [self] in
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

let app = NSApplication.shared
let delegate = PlacementProbe()
app.setActivationPolicy(.regular)
app.delegate = delegate
app.run()

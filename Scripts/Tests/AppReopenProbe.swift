import AppKit
@testable import lineup

// Calls the real reopen delegate without launching tools or loading the user's configuration.
// AppKit focus acknowledgement needs a GUI session; no keyboard or mouse events are processed.
@main
struct AppReopenProbe {
    @MainActor
    static func main() {
        exit(run())
    }

    @MainActor
    private static func run() -> Int32 {
        let app = NSApplication.shared
        var failures = 0
        func expect(_ condition: Bool, _ message: String) {
            print("\(condition ? "PASS" : "FAIL"): \(message)")
            if !condition { failures += 1 }
        }
        func pump(_ seconds: TimeInterval = 0.2) {
            let deadline = Date(timeIntervalSinceNow: seconds)
            while Date() < deadline {
                if let event = app.nextEvent(matching: [.appKitDefined, .systemDefined, .applicationDefined],
                                             until: Date(), inMode: .default, dequeue: true) {
                    app.sendEvent(event)
                }
                RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
            }
        }
        func settingsWindows() -> [NSWindow] {
            app.windows.filter { $0.title == "Lineup Settings" }
        }
        func waitForKeyWindow(_ window: NSWindow) -> Bool {
            let deadline = Date(timeIntervalSinceNow: 5)
            while !window.isKeyWindow, Date() < deadline { pump(0.05) }
            return window.isKeyWindow
        }
        defer {
            for window in settingsWindows() { window.close() }
            pump()
        }
        guard app.delegate == nil else {
            expect(false, "the probe must not install an application delegate")
            return 1
        }
        app.finishLaunching()
        let delegate: NSApplicationDelegate = AppShell()
        expect(delegate.applicationShouldHandleReopen?(app, hasVisibleWindows: false) == false,
               "the delegate consumes explicit reopen requests")
        for window in settingsWindows() { window.ignoresMouseEvents = true }
        pump()
        guard let first = settingsWindows().first else {
            expect(false, "reopen opens Settings with the menu-bar icon visible by default")
            return 1
        }
        expect(first.isVisible && settingsWindows().count == 1, "reopen creates one visible Settings window")
        _ = delegate.applicationShouldHandleReopen?(app, hasVisibleWindows: true)
        expect(settingsWindows().count == 1 && settingsWindows().first === first, "visible Settings is reused")
        first.miniaturize(nil)
        pump(0.5)
        expect(first.isMiniaturized, "Settings is minimized before reopening")
        _ = delegate.applicationShouldHandleReopen?(app, hasVisibleWindows: false)
        expect(waitForKeyWindow(first) && !first.isMiniaturized && first.isVisible,
               "reopen restores minimized Settings to the front")
        expect(settingsWindows().count == 1 && settingsWindows().first === first, "minimized Settings is reused")
        first.close()
        pump()
        _ = delegate.applicationShouldHandleReopen?(app, hasVisibleWindows: false)
        for window in settingsWindows() { window.ignoresMouseEvents = true }
        pump()
        expect(settingsWindows().filter(\.isVisible).count == 1, "Settings reopens after closing")
        for window in settingsWindows() { window.close() }
        pump()
        expect(app.delegate == nil, "the shell was never installed as the application delegate")
        expect(ActivationCoordinator.shared.activeReasons.isEmpty, "closing Settings releases activation")
        return failures == 0 ? 0 : 1
    }
}

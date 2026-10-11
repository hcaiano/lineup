import AppKit
import Darwin
import HyperkeyCore
import IOKit

@MainActor private var secureInputSamples = [true, true]
@MainActor private var consoleUsers: Any?
@MainActor private var registryReads = 0
@MainActor private var registryReleases = 0
@MainActor private var registryAvailable = true
@MainActor private var appNames: [Int32: String] = [:]
@MainActor private var resolvedPIDs: [Int32] = []

@MainActor let IsSecureEventInputEnabled: () -> Bool = { secureInputSamples.removeFirst() }
@MainActor func IORegistryGetRootEntry(_ port: mach_port_t) -> io_registry_entry_t {
    registryReads += 1
    return registryAvailable ? 1 : IO_OBJECT_NULL
}
@MainActor func IORegistryEntryCreateCFProperty(_ entry: io_registry_entry_t, _ key: CFString,
                                              _ allocator: CFAllocator?, _ options: IOOptionBits) -> Unmanaged<CFTypeRef>? {
    guard let consoleUsers else { return nil }
    return Unmanaged.passRetained(consoleUsers as CFTypeRef)
}
@MainActor func IOObjectRelease(_ object: io_object_t) -> kern_return_t {
    registryReleases += 1
    return KERN_SUCCESS
}
@MainActor final class NSRunningApplication {
    let localizedName: String?
    init?(processIdentifier: Int32) {
        resolvedPIDs.append(processIdentifier)
        guard let name = appNames[processIdentifier] else { return nil }
        localizedName = name
    }
}

@MainActor final class NSScreen {
    let visibleFrame: NSRect
    init(_ frame: NSRect) { visibleFrame = frame }
    static var main: NSScreen? = AppKit.NSScreen.main.map { NSScreen($0.visibleFrame) }
    static var screens: [NSScreen] { main.map { [$0] } ?? [] }
}

@MainActor final class NSWorkspace {
    static let shared = NSWorkspace()
    var accessibilityDisplayShouldReduceMotion = false
}

@MainActor final class NoticeClock {
    struct Scheduled {
        let delay: TimeInterval
        let action: () -> Void
        var cancelled = false
    }
    var scheduled: [Scheduled] = []
    func schedule(_ delay: TimeInterval, _ action: @escaping () -> Void) -> () -> Void {
        let index = scheduled.count
        scheduled.append(Scheduled(delay: delay, action: action))
        return { self.scheduled[index].cancelled = true }
    }
}

@main
struct HyperkeyBlockedWarningProbe {
    @MainActor
    static func main() throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let appearance = ProcessInfo.processInfo.environment["LINEUP_WARNING_APPEARANCE"]
        if let appearance {
            guard appearance == "light" || appearance == "dark" else {
                print("FAIL: LINEUP_WARNING_APPEARANCE must be light or dark")
                exit(1)
            }
            NSApp.appearance = NSAppearance(named: appearance == "light" ? .aqua : .darkAqua)
        }
        var failures = 0
        func expect(_ condition: Bool, _ message: String) {
            if !condition { failures += 1; print("FAIL: \(message)") }
        }
        func finishAnimations() {
            let deadline = Date().addingTimeInterval(0.3)
            while Date() < deadline { RunLoop.main.run(until: min(deadline, Date().addingTimeInterval(0.01))) }
        }
        func labels(in view: NSView) -> [NSTextField] {
            (view as? NSTextField).map { [$0] } ?? view.subviews.flatMap { labels(in: $0) }
        }
        func checkAppearance(_ panel: NSPanel) {
            guard let appearance else { return }
            let dark = appearance == "dark"
            expect(panel.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == (dark ? .darkAqua : .aqua),
                   "the native panel inherits the isolated process appearance")
            guard let content = panel.contentView else { return }
            expect(content.appearance == nil, "native material inherits appearance without a pinned override")
            content.effectiveAppearance.performAsCurrentDrawingAppearance {
                for label in labels(in: content) {
                    guard let color = label.textColor?.usingColorSpace(.deviceRGB) else {
                        expect(false, "native label color resolves in the selected appearance")
                        continue
                    }
                    let brightness = (color.redComponent + color.greenComponent + color.blueComponent) / 3
                    expect(dark ? brightness > 0.4 : brightness < 0.6,
                           "native label contrast follows \(appearance), observed brightness \(brightness)")
                }
            }
        }
        func session(_ pid: Int32) -> [String: Any] {
            ["kCGSSessionUserIDKey": getuid(), "kCGSSessionOnConsoleKey": true,
             "kCGSSessionSecureInputPID": pid]
        }
        func sample(_ before: Bool, _ after: Bool, sessions: Any?) -> SecureInputDiagnostic {
            secureInputSamples = [before, after]
            consoleUsers = sessions
            resolvedPIDs = []
            return SecureInputDiagnostics.sample()
        }

        appNames = [42: "Safari"]
        expect(sample(true, true, sessions: [session(42)]).suspectedAppName == "Safari"
               && resolvedPIDs == [42] && registryReleases == 1,
               "shipping diagnostics resolve one current-session PID and release the registry root")
        expect(sample(true, true, sessions: [session(999)]).suspectedAppName == nil,
               "stale or helper PIDs with no running app name stay unknown")
        expect(sample(true, true, sessions: [session(42), session(43)]).suspectedAppName == nil
               && resolvedPIDs.isEmpty,
               "multiple candidates are unknown before running-app resolution")
        let readsBeforeInactive = registryReads
        expect(sample(false, true, sessions: [session(42)]).suspectedAppName == nil
               && registryReads == readsBeforeInactive,
               "inactive Secure Input cannot expose a stale registry app")
        let releasesBeforeRace = registryReleases
        expect(sample(true, false, sessions: [session(42)]).suspectedAppName == nil
               && registryReleases == releasesBeforeRace + 1,
               "Secure Input must remain active after sampling and the raced read must release its root")
        expect(sample(true, true, sessions: nil).suspectedAppName == nil,
               "unreadable registry properties stay unknown")
        registryAvailable = false
        let releasesBeforeMissingRoot = registryReleases
        expect(sample(true, true, sessions: [session(42)]).suspectedAppName == nil
               && registryReleases == releasesBeforeMissingRoot,
               "missing registry roots do not resolve an app or release a null object")
        registryAvailable = true

        let clock = NoticeClock()
        var notice: HyperKeyBlockedPill? = HyperKeyBlockedPill(scheduleDismissal: clock.schedule)
        notice?.show(message: "Secure Input", diagnostic: SecureInputDiagnostic(suspectedAppName: "Safari"))
        guard let panel = NSApp.windows.first(where: { $0 is NSPanel && $0.isVisible }) as? NSPanel else {
            print("FAIL: shipping notice must create a visible native panel")
            exit(1)
        }
        finishAnimations()
        checkAppearance(panel)
        expect(panel.isVisible && !panel.isKeyWindow && panel.ignoresMouseEvents
               && panel.styleMask.contains(.nonactivatingPanel),
               "shipping notice is visible without activating or receiving clicks")
        expect(clock.scheduled.count == 1 && clock.scheduled[0].delay == 4,
               "a blocked episode schedules exactly one four-second dismissal")
        notice?.show(message: "Secure Input", diagnostic: SecureInputDiagnostic(suspectedAppName: "Another App"))
        expect(labels(in: panel.contentView!).contains { $0.stringValue == "Possibly Another App. Details in Lineup Settings." }
               && clock.scheduled.count == 1 && clock.scheduled[0].delay == 4 && !clock.scheduled[0].cancelled,
               "visible diagnostic updates change the native label without resetting the original deadline")
        notice?.show(message: "Secure Input", diagnostic: SecureInputDiagnostic(suspectedAppName: "Safari"))
        let visible = panel.screen?.visibleFrame ?? .zero
        expect(visible.contains(panel.frame) && panel.frame.width <= 340
               && abs(panel.frame.maxX - (visible.maxX - 16)) < 1
               && abs(panel.frame.maxY - (visible.maxY - 16)) < 1,
               "shipping notice fits the selected display's top-right visible frame")
        try capture(panel, name: "known")

        clock.scheduled[0].action()
        finishAnimations()
        expect(!panel.isVisible, "the shipping panel auto-dismisses at its deadline")
        notice?.show(message: "New diagnostic while still blocked", diagnostic: SecureInputDiagnostic())
        expect(!panel.isVisible && clock.scheduled.count == 1,
               "auto-dismissed blocks cannot reappear on app activation or diagnostic changes")

        notice?.endEpisode()
        notice?.show(message: "Secure Input", diagnostic: SecureInputDiagnostic())
        finishAnimations()
        expect(panel.isVisible && clock.scheduled.count == 2,
               "blocked to active to blocked begins a fresh visible episode")
        try capture(panel, name: "unknown")
        checkAppearance(panel)
        clock.scheduled[0].action()
        expect(panel.isVisible, "an old timer cannot dismiss a newer blocked episode")
        clock.scheduled[1].action()
        notice?.endEpisode()
        notice?.show(message: "Secure Input", diagnostic: SecureInputDiagnostic(suspectedAppName: "A very long application name " + String(repeating: "x", count: 150)))
        finishAnimations()
        expect(panel.isVisible && panel.alphaValue > 0.99 && clock.scheduled.count == 3,
               "an old fade completion cannot order out a newer episode")
        try capture(panel, name: "long-name")
        checkAppearance(panel)

        let originalScreen = NSScreen.main
        NSScreen.main = NSScreen(NSRect(x: 0, y: 0, width: 320, height: 220))
        notice?.endEpisode()
        notice?.show(message: "Secure Input", diagnostic: SecureInputDiagnostic(suspectedAppName: String(repeating: "Long App ", count: 30)))
        finishAnimations()
        expect(NSScreen.main!.visibleFrame.contains(panel.frame),
               "shipping position and wrapped content fit a small selected screen, observed \(panel.frame)")
        for label in labels(in: panel.contentView!) {
            let required = label.cell!.cellSize(forBounds: NSRect(x: 0, y: 0, width: label.bounds.width, height: 1000)).height
            expect(label.bounds.height >= required - 1,
                   "small-screen native labels retain every wrapped line of state and Settings hint")
        }
        try capture(panel, name: "small-screen")
        checkAppearance(panel)
        NSScreen.main = originalScreen

        for frame in [NSRect(x: 0, y: 0, width: 320, height: 220),
                      NSRect(x: -1920, y: 40, width: 1920, height: 1000),
                      NSRect(x: 1500, y: -900, width: 400, height: 300)] {
            let placed = HyperKeyBlockedPill.frame(in: frame, height: 90)
            expect(frame.contains(placed) && placed.width <= 340,
                   "small and secondary displays contain the entire notice in their own coordinates")
        }
        notice?.endEpisode()
        expect(clock.scheduled.last!.cancelled, "stop cancels the pending dismissal")
        clock.scheduled.last!.action()
        finishAnimations()
        expect(!panel.isVisible, "stale delivery after stop cannot reopen or retain the panel")
        weak var releasedNotice = notice
        notice = nil
        expect(releasedNotice == nil, "the dismissal callback must not retain the notice owner")

        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion = true
        let instant = HyperKeyBlockedPill(scheduleDismissal: clock.schedule)
        instant.show(message: "Input Monitoring permission required")
        guard let instantPanel = NSApp.windows.first(where: { $0 is NSPanel && $0.isVisible }) else { fatalError("Missing instant panel") }
        expect(instantPanel.alphaValue == 1, "Reduce Motion shows the native notice without a fade")
        instant.endEpisode()
        RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        expect(!instantPanel.isVisible, "Reduce Motion dismisses without waiting for a fade")
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion = false

        let attempts = NoticeClock()
        let attempted = HyperKeyBlockedPill(scheduleDismissal: attempts.schedule)
        attempted.show(message: "Secure Input", diagnostic: SecureInputDiagnostic())
        guard let attemptPanel = NSApp.windows.first(where: { $0 is NSPanel && $0.isVisible }) as? NSPanel else {
            fatalError("Missing attempt panel")
        }
        attempts.scheduled[0].action()
        finishAnimations()
        attempted.show(message: "App activated", diagnostic: SecureInputDiagnostic(suspectedAppName: "Safari"))
        expect(!attemptPanel.isVisible && attempts.scheduled.count == 1,
               "ordinary updates keep a dismissed attempt hidden")
        attempted.showAfterAttempt(message: "Secure Input", diagnostic: SecureInputDiagnostic(suspectedAppName: "Safari"))
        finishAnimations()
        expect(attemptPanel.isVisible && attempts.scheduled.count == 2 && attempts.scheduled[1].delay == 4,
               "a deliberate attempt after dismissal starts a fresh four-second notice")
        guard attempts.scheduled.count == 2 else {
            print("\(failures) blocked-warning checks failed")
            exit(1)
        }
        for _ in 0..<8 { attempted.showAfterAttempt(message: "Secure Input", diagnostic: SecureInputDiagnostic()) }
        expect(attemptPanel.isVisible && attempts.scheduled.count == 2 && !attempts.scheduled[1].cancelled,
               "attempts during a visible deadline update content without extending its lifetime")
        attempts.scheduled[0].action()
        finishAnimations()
        expect(attemptPanel.isVisible, "the prior episode deadline cannot dismiss the new attempted notice")
        attempts.scheduled[1].action()
        attempted.showAfterAttempt(message: "Secure Input", diagnostic: SecureInputDiagnostic())
        finishAnimations()
        expect(attemptPanel.isVisible && attemptPanel.alphaValue > 0.99 && attempts.scheduled.count == 3,
               "an attempt during dismissal invalidates its stale fade completion")
        attempts.scheduled[1].action()
        finishAnimations()
        expect(attemptPanel.isVisible, "the replaced attempt deadline cannot hide its successor")
        attempts.scheduled[2].action()
        finishAnimations()
        expect(!attemptPanel.isVisible, "the new attempt dismisses on its own unchanged deadline")
        attempted.endEpisode()

        let timed = HyperKeyBlockedPill()
        timed.show(message: "Secure Input", diagnostic: SecureInputDiagnostic())
        let started = Date()
        guard let timedPanel = NSApp.windows.first(where: { $0 is NSPanel && $0.isVisible }) else { fatalError("Missing timed panel") }
        RunLoop.main.run(until: started.addingTimeInterval(3.8))
        expect(timedPanel.isVisible, "the production timer retains the notice before four seconds")
        timed.show(message: "Still blocked after app activation", diagnostic: SecureInputDiagnostic(suspectedAppName: "Safari"))
        RunLoop.main.run(until: started.addingTimeInterval(4.5))
        expect(!timedPanel.isVisible, "the production timer dismisses after four seconds despite a repeated block")
        timed.show(message: "Still blocked")
        expect(!timedPanel.isVisible, "the real-timer dismissal remains latched for its blocked episode")
        timed.endEpisode()

        if failures > 0 { print("\(failures) blocked-warning checks failed"); exit(1) }
        print("PASS: shipping diagnostics and native blocked notice retain four-second deadlines, reappear after deliberate attempts, reject stale delivery, inherit appearance, and release on stop")
    }

    @MainActor
    static func capture(_ panel: NSPanel, name: String) throws {
        guard let directory = ProcessInfo.processInfo.environment["LINEUP_WARNING_CAPTURE_DIR"],
              let view = panel.contentView,
              let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { return }
        let url = URL(fileURLWithPath: directory, isDirectory: true).appendingPathComponent("after-\(name).png")
        try data.write(to: url)
    }
}

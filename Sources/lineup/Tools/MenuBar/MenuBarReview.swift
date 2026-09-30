#if DEBUG
import AppKit
import AppCore

/// An opt-in manual review of the real tool, with its own config and recovery
/// journal. It never starts the app shell or the other tools. This mirrors the
/// existing LINEUP_RENDER_PREVIEW workflow, but permits interaction and crashes.
@MainActor
final class MenuBarReview: NSObject, NSApplicationDelegate {
    private var registry: ToolRegistry?
    private var settingsWindow: SettingsWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            // The isolated config does not isolate the system menu bar. Two managers create
            // two arrows and competing groups, even when they use different bundle IDs.
            guard !NSRunningApplication.runningApplications(withBundleIdentifier: Product.bundleID)
                .contains(where: { !$0.isTerminated && $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) else {
                throw MenuBarPreferenceAccess.Failure(message: "Quit the installed Lineup before opening the Menu Bar review. Two copies would manage the same menu bar.")
            }
            let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["LINEUP_MENU_BAR_REVIEW_DIR"]!, isDirectory: true)
            guard root.standardizedFileURL != Product.configURL.deletingLastPathComponent().standardizedFileURL else {
                throw MenuBarPreferenceAccess.Failure(message: "The review must use a separate config directory.")
            }
            let store = LineupAppConfigStore(url: root.appendingPathComponent("review-config.json"))
            _ = store.load()
            guard store.canWrite else { throw MenuBarPreferenceAccess.Failure(message: "The review config cannot be loaded.") }
            if store.config.section(for: .menuBar) == nil {
                try store.setSettings(MenuBarSettings(), for: .menuBar)
                try store.setEnabled(true, for: .menuBar)
            }
            let registry = ToolRegistry(store: store)
            self.registry = registry
            registry.register(MenuBarTool(recoveryURL: root.appendingPathComponent("review-recovery.json")))
            TerminationCoordinator.shared.installSignalHandlers()
            registry.startEnabledTools()
            let model = SettingsStore(registry: registry, permissions: .shared,
                showMenuBarIcon: true, onMenuBarIconChange: { _ in true })
            model.selection = .tool(.menuBar)
            let window = SettingsWindowController(store: model)
            settingsWindow = window
            registry.onSettingsChange = { [weak model] in model?.refresh() }
            window.show()
        } catch {
            fputs("Menu Bar review failed: \(error.localizedDescription)\n", stderr)
            NSApp.terminate(nil)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        TerminationCoordinator.shared.runCleanups()
        registry?.stopAll()
    }
}
#endif

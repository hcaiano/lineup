import AppKit

// Bootstrap only. Everything else lives in App/AppShell.swift.
//
// Top-level code is not MainActor-isolated in Swift 5 mode, but the bootstrap factually runs on
// the main thread. `shell` stays alive for the whole app: NSApplication.delegate is unsafe
// unretained, and run() only returns at process exit.
if !runMenuBarRecoveryIfRequested() {
    MainActor.assumeIsolated {
        let app = NSApplication.shared
        #if DEBUG
        if ProcessInfo.processInfo.environment["LINEUP_MENU_PANEL_REVIEW_DIR"] != nil {
            let review = MenuPanelReview()
            app.delegate = review
            withExtendedLifetime(review) { app.run() }
            return
        }
        if ProcessInfo.processInfo.environment["LINEUP_MENU_BAR_REVIEW_DIR"] != nil {
            let review = MenuBarReview()
            app.delegate = review
            withExtendedLifetime(review) { app.run() }
            return
        }
        #endif
        let shell = AppShell()
        app.delegate = shell
        app.run()
    }
}

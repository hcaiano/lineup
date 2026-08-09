import AppKit

// Bootstrap only. Everything else lives in App/AppShell.swift.
//
// Top-level code is not MainActor-isolated in Swift 5 mode, but the bootstrap factually runs on
// the main thread. `shell` stays alive for the whole app: NSApplication.delegate is unsafe
// unretained, and run() only returns at process exit.
MainActor.assumeIsolated {
    let app = NSApplication.shared
    let shell = AppShell()
    app.delegate = shell
    app.run()
}

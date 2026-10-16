import AppCore
import AppKit

/// The menu bar shows this menu only while a window such as Settings makes Lineup a regular app,
/// but AppKit routes Command-key equivalents through it at all times. Without its Edit menu, text
/// fields in the panel and in Settings ignore Command-A, C, V, X and Z.
@MainActor
enum MainMenu {
    static func make(openSettings: @escaping () -> Void) -> NSMenu {
        let app = NSMenu(title: Product.name)
        app.addItem(MenuActionItem(title: "About \(Product.name)") { AboutWindowController.show() })
        app.addItem(.separator())
        app.addItem(MenuActionItem(title: "Settings…", keyEquivalent: ",", run: openSettings))
        app.addItem(.separator())
        app.addItem(withTitle: "Quit \(Product.name)", action: #selector(NSApplication.terminate(_:)),
                    keyEquivalent: "q")

        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        let main = NSMenu()
        for submenu in [app, edit] {
            main.addItem(withTitle: submenu.title, action: nil, keyEquivalent: "").submenu = submenu
        }
        return main
    }
}

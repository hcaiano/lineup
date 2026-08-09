import AppKit
import AppCore
import SwiftUI
import ZonesCore

/// The Zones pane: Lineup 1.x's Shortcuts tab plus the drag-snap rows of its General tab, on the
/// shared `Settings/Components/*`. Everything else 1.x's window held (permissions, launch at
/// login, About) belongs to the shell now.
///
/// Capture goes through one `ShortcutRecorder`, which routes the global hotkey suspension through
/// `SettingsStore` — that is what lets a recorder here receive a combo any of the three tools
/// owns, and hand every one of them back afterwards. The pane never touches `HotkeyManager`.
/// The window's `SettingsStore` arrives through the environment (injected by
/// `SettingsStore.pane(for:)`). It has to be read here and passed down by value, because the
/// recorder is a `@StateObject` and an `@EnvironmentObject` is not available during `init`.
struct ZonesSettingsPane: View {
    @ObservedObject var model: ZonesSettingsModel
    @EnvironmentObject private var settings: SettingsStore

    var body: some View {
        ZonesSettingsPaneBody(model: model, settings: settings)
    }
}

private struct ZonesSettingsPaneBody: View {
    @ObservedObject var model: ZonesSettingsModel
    @StateObject private var recorder: ShortcutRecorder

    /// The drag bind's recorder id. Shortcut rows use their action id, so no collision.
    private static let dragBindID = "zones.dragBind"

    @MainActor
    init(model: ZonesSettingsModel, settings: SettingsStore) {
        self.model = model
        _recorder = StateObject(wrappedValue: ShortcutRecorder(store: settings))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                // The recorder instructions used to float here, above "Drag to snap", where they
                // read as a description of drag-snapping. They belong to the shortcut sections,
                // so they are a caption on the first of them.
                if !model.canWrite {
                    Label(model.blockedMessage ?? "Editing is disabled.", systemImage: "lock.fill")
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }

                SettingsSectionView("Drag to snap") {
                    SettingsRow(title: "Drag to snap",
                                detail: "Hold the drag bind while dragging a window.") {
                        Toggle("", isOn: Binding(get: { model.dragSnapOn },
                                                 set: { model.setDragSnapOn($0) }))
                            .labelsHidden()
                            .toggleStyle(.switch)
                    }

                    SettingsRow(title: "Drag bind",
                                detail: "Click to record a key or modifier combo.") {
                        HStack(spacing: 8) {
                            RecorderButton(
                                text: model.dragTriggerDisplay,
                                emptyText: "Click to set",
                                isRecording: recorder.isRecording(Self.dragBindID),
                                enabled: model.canWrite,
                                accessibilityLabel: "Drag snap bind",
                                action: { recordDragBind() })

                            CircleClearButton(
                                help: "Reset drag bind to Shift",
                                accessibilityLabel: "Reset drag bind to Shift",
                                disabled: !model.canWrite,
                                action: { model.resetDragBind() })
                        }
                    }
                }

                SettingsSectionView(
                    "Window",
                    caption: "Click a shortcut, then press a key combo. Esc cancels, Delete clears.") {
                    ForEach(model.quickShortcutRows) { row in
                        shortcutRow(row)
                    }
                }

                SettingsSectionView("Zones") {
                    ForEach(model.zoneShortcutRows) { row in
                        shortcutRow(row)
                    }
                }
            }
            .frame(width: SettingsMetrics.contentWidth, alignment: .leading)
            .padding(.top, 22)
            .padding(.bottom, 18)
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .navigationTitle("Zones")
        .onAppear { model.refresh() }
        // Switching to another pane must not leave a live capture — and therefore must not leave
        // every tool's hotkeys suspended. The window's own close/blur path is handled by
        // SettingsWindowController -> SettingsStore.stopAllRecording().
        .onDisappear { recorder.cancel() }
    }

    // MARK: - Rows

    @ViewBuilder
    private func shortcutRow(_ row: ZonesSettingsModel.ShortcutRow) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text(row.label)
                Spacer(minLength: 24)
                RecorderButton(
                    text: model.shortcutDisplay(for: row.id),
                    emptyText: "Click to set",
                    isRecording: recorder.isRecording(row.id),
                    enabled: model.canWrite,
                    accessibilityLabel: "\(row.label) shortcut",
                    action: { record(row.id) })

                CircleClearButton(
                    help: "Clear shortcut",
                    accessibilityLabel: "Clear shortcut for \(row.label)",
                    disabled: !model.canWrite || model.shortcutDisplay(for: row.id).isEmpty,
                    action: { model.clearShortcut(row.id) })
            }
            // Denser than a stock SettingsRow: thirteen of these stack up (4 quick actions + 9
            // zones), and at the default row height the list stops fitting in one look.
            .frame(minHeight: SettingsMetrics.shortcutRowHeight)
            .padding(.vertical, 3)

            Divider()
        }
    }

    // MARK: - Capture

    private func record(_ action: String) {
        guard model.canWrite else { return }
        recorder.toggle(action, options: .combo) { capture in
            model.apply(capture, to: action)
        }
    }

    private func recordDragBind() {
        guard model.canWrite else { return }
        // The drag bind is the one field that accepts modifiers on their own (Shift-drag).
        recorder.toggle(Self.dragBindID, options: .comboOrModifiers) { capture in
            model.applyDragBind(capture)
        }
    }
}

// MARK: - Model

/// The pane's view model. Owns no resources — every read and write goes back through `ZonesTool`
/// via `Context`, so the pane can be rebuilt (or the tool stopped) without state drifting apart.
@MainActor
final class ZonesSettingsModel: ObservableObject {
    struct Context {
        var canWrite: () -> Bool
        var blockedMessage: () -> String?
        var shortcuts: () -> Shortcuts
        var setShortcuts: (Shortcuts) -> Void
        var isDragSnapOn: () -> Bool
        var setDragSnapOn: (Bool) -> Void
        var dragTrigger: () -> DragSnapTrigger
        var setDragTrigger: (DragSnapTrigger) -> Void
        /// Which OTHER tool already owns this combo, if any (§5.6 cross-tool collisions).
        var foreignOwner: (Int, UInt32) -> ToolID?
    }

    struct ShortcutRow: Identifiable {
        var id: String
        var label: String
    }

    @Published private(set) var canWrite = true
    @Published private(set) var blockedMessage: String?
    @Published private(set) var shortcuts = Shortcuts()
    @Published private(set) var dragSnapOn = true
    @Published private(set) var dragTrigger = DragSnapTrigger.default

    private let ctx: Context

    init(context: Context) {
        self.ctx = context
        refresh()
    }

    var quickShortcutRows: [ShortcutRow] {
        ShortcutKit.quickActions.map { ShortcutRow(id: $0.id, label: $0.label) }
    }

    var zoneShortcutRows: [ShortcutRow] {
        (1...ShortcutKit.zoneRows).map { ShortcutRow(id: ZoneAction.id($0), label: "Zone \($0)") }
    }

    var dragTriggerDisplay: String {
        ShortcutKit.dragSnapDisplay(keyCode: dragTrigger.keyCode, modifiers: dragTrigger.modifiers)
    }

    func refresh() {
        canWrite = ctx.canWrite()
        blockedMessage = ctx.blockedMessage()
        shortcuts = ctx.shortcuts()
        dragSnapOn = ctx.isDragSnapOn()
        dragTrigger = ctx.dragTrigger()
    }

    func shortcutDisplay(for action: String) -> String {
        shortcuts.binding(for: action)
            .map { ShortcutKit.display(keyCode: $0.keyCode, modifiers: $0.modifiers) } ?? ""
    }

    func setDragSnapOn(_ value: Bool) {
        guard value != dragSnapOn else { return }
        ctx.setDragSnapOn(value)
        refresh()
    }

    func clearShortcut(_ action: String) {
        guard canWrite else { return }
        ctx.setShortcuts(shortcuts.removing(action: action))
        refresh()
    }

    func resetDragBind() {
        guard canWrite else { return }
        ctx.setDragTrigger(.default)
        refresh()
    }

    // MARK: - Captures
    //
    // The recorder has already restored every tool's hotkeys by the time these run, so the
    // conflict alerts below can run their modal loop with shortcuts live behind them — the 1.x
    // ordering, kept deliberately.

    func apply(_ capture: ShortcutRecorder.Capture, to action: String) {
        guard canWrite else { return }
        switch capture {
        case .clear:
            ctx.setShortcuts(shortcuts.removing(action: action))
            refresh()

        case .modifiersOnly:
            NSSound.beep() // not offered for shortcut rows (Options.combo); a key is required

        case .combo(let keyCode, let modifiers):
            // `Shortcuts` stores Int modifiers; the recorder speaks the canonical UInt32 mask.
            let mask = Int(modifiers)
            let conflicts = shortcuts.conflicts(keyCode: keyCode, modifiers: mask, excluding: action)
            if !conflicts.isEmpty, !confirmConflict(conflicts) { return }
            if dragTrigger.keyCode == keyCode, dragTrigger.modifiers == mask {
                showAlert("Shortcut already in use",
                          "This combo is assigned to the drag bind. Choose a different shortcut, "
                            + "or change the drag bind above.")
                return
            }
            if let owner = ctx.foreignOwner(keyCode, modifiers) {
                showAlert("Shortcut already in use",
                          "This combo is used by \(owner.rawValue.capitalized). Choose a different "
                            + "shortcut, or change it in that tool's settings.")
                return
            }
            var updated = shortcuts
            for conflict in conflicts { updated = updated.removing(action: conflict) }
            ctx.setShortcuts(updated.setting(action: action, keyCode: keyCode, modifiers: mask))
            refresh()
        }
    }

    func applyDragBind(_ capture: ShortcutRecorder.Capture) {
        guard canWrite else { return }
        switch capture {
        case .clear:
            // Delete RESETS the drag bind rather than clearing it: there is no "unbound" drag.
            ctx.setDragTrigger(.default)
            refresh()

        case .modifiersOnly(let modifiers):
            ctx.setDragTrigger(DragSnapTrigger(keyCode: nil, modifiers: Int(modifiers)))
            refresh()

        case .combo(let keyCode, let modifiers):
            let mask = Int(modifiers)
            let conflicts = shortcuts.conflicts(keyCode: keyCode, modifiers: mask, excluding: "")
            if !conflicts.isEmpty {
                let names = conflicts.map(ZonesTool.label(for:)).joined(separator: ", ")
                showAlert("Drag bind already in use",
                          "This key combination is already assigned to: \(names). Choose a "
                            + "different drag bind so dragging does not trigger a shortcut.")
                return
            }
            ctx.setDragTrigger(DragSnapTrigger(keyCode: keyCode, modifiers: mask))
            refresh()
        }
    }

    private func confirmConflict(_ conflicts: [String]) -> Bool {
        let names = conflicts.map(ZonesTool.label(for:)).joined(separator: ", ")
        let alert = NSAlert()
        alert.messageText = "Shortcut already in use"
        alert.informativeText = "This combo is assigned to: \(names). Reassign it here? "
            + "The other action becomes unassigned."
        alert.addButton(withTitle: "Reassign")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func showAlert(_ title: String, _ message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}

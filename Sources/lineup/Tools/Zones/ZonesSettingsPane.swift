import AppKit
import AppCore
import SwiftUI
import ZonesCore

/// The Zones pane: Lineup 1.x's Shortcuts tab plus the drag-snap rows of its General tab, on the
/// shared `Settings/Components/*`. Everything else 1.x's window held (permissions, launch at
/// login, About) belongs to the shell now.
///
/// Capture goes through one `ShortcutRecorder`, which routes the global hotkey suspension through
/// `SettingsStore` — that is what lets a recorder here receive a combo any tool
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
    /// Held only to name a conflicting tool the way the sidebar does; the pane does not observe it.
    private let settings: SettingsStore

    /// The drag bind's recorder id. Shortcut rows use their action id, so no collision.
    private static let dragBindID = "zones.dragBind"

    @MainActor
    init(model: ZonesSettingsModel, settings: SettingsStore) {
        self.model = model
        self.settings = settings
        _recorder = StateObject(wrappedValue: ShortcutRecorder(store: settings))
    }

    var body: some View {
        VStack(spacing: 0) {
            // Pinned, not scrolled. Inside the scroll view the one line explaining why every
            // control below is dead slid out of sight and left a pane that looked broken.
            if !model.canWrite {
                PinnedBannerStrip {
                    BlockedBanner(
                        message: model.blockedMessage ?? "Editing is disabled.",
                        actionTitle: "Reset Zones Settings…",
                        action: { model.resetSection() },
                        actionEnabled: model.canReset)
                }
            }

            ScrollView {
                VStack(alignment: .leading, spacing: SettingsMetrics.sectionSpacing) {
                    SettingsSectionView("Behavior") {
                        SettingsRow(title: "Drag to snap",
                                    detail: "Hold the drag bind while dragging a window.") {
                            Toggle("", isOn: Binding(get: { model.dragSnapOn },
                                                     set: { model.setDragSnapOn($0) }))
                                .labelsHidden()
                                .toggleStyle(.switch)
                                // Every other control on the pane is off while writes are blocked;
                                // this one flipped, said nothing, and was back at the next launch.
                                .disabled(!model.canWrite)
                                .accessibilityLabel("Drag to snap")
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
                                    accessibilityValue: model.dragTriggerSpokenValue,
                                    rejectionCount: recorder.rejectionCount,
                                    action: { recordDragBind() })

                                CircleClearButton(
                                    help: "Reset drag bind to Shift",
                                    accessibilityLabel: "Reset drag bind to Shift",
                                    disabled: !model.canWrite,
                                    action: { model.resetDragBind() })
                            }
                        }

                        // Without this the layout editor is reachable only from the menu-bar icon
                        // — which General lets the user hide. The pane that owns zones has to be
                        // able to open the thing that draws them.
                        SettingsRow(title: "Zone layout",
                                    detail: "Draw the zones windows snap into, per display.") {
                            Button("Open Layout Editor…") { model.openLayoutEditor() }
                                .disabled(!model.canOpenLayoutEditor)
                                .help(model.canOpenLayoutEditor
                                      ? "Draw this display's zones"
                                      : "Turn Zones on to edit its layout")
                        }
                    }

                    SettingsSectionView(
                        "Window",
                        caption: "Click a shortcut, then press a key combo. Esc cancels, Delete clears.") {
                        ForEach(model.quickShortcutRows) { row in
                            shortcutRow(row)
                        }
                    }

                    SettingsSectionView(
                        "Zone shortcuts",
                        caption: "One shortcut per zone in the current layout, in visual order.") {
                        ForEach(model.zoneShortcutRows) { row in
                            shortcutRow(row)
                        }
                    }
                }
                .frame(width: SettingsMetrics.contentWidth, alignment: .leading)
                .padding(.vertical, SettingsMetrics.panePaddingVertical)
                .frame(maxWidth: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .navigationTitle("Zones")
        .onAppear {
            model.refresh()
            // The model has to be able to end a capture from a non-recorder action (clearing a
            // row), and the recorder is the view's.
            model.recorder = recorder
            model.cancelRecording = { [weak recorder] in recorder?.cancel() }
            // Conflict alerts name the owning tool the way the sidebar does.
            model.toolDisplayName = { [weak settings] id in
                settings?.displayName(for: id) ?? id.rawValue.capitalized
            }
        }
        // Switching to another pane must not leave a live capture — and therefore must not leave
        // every tool's hotkeys suspended. The window's own close/blur path is handled by
        // SettingsWindowController -> SettingsStore.stopAllRecording().
        .onDisappear {
            recorder.cancel()
            // Only if the hook is still OURS. SwiftUI can build a replacement pane before tearing
            // the old one down, and an unconditional clear left the live pane unable to end a
            // capture — every tool's hotkeys then stayed suspended until the window blurred.
            guard model.recorder === recorder else { return }
            model.recorder = nil
            model.cancelRecording = nil
        }
    }

    // MARK: - Rows

    @ViewBuilder
    private func shortcutRow(_ row: ZonesSettingsModel.ShortcutRow) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text(row.label)
                // A binding survives a layout change, so a Zone 7 row on a three-zone layout is
                // not junk to be hidden — it is a shortcut that does nothing UNTIL the layout
                // grows. Say so instead of leaving the user to press it and wonder.
                if row.isBeyondLayout {
                    Text("(not in current layout)")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 24)
                RecorderButton(
                    text: model.shortcutDisplay(for: row.id),
                    emptyText: "Click to set",
                    isRecording: recorder.isRecording(row.id),
                    enabled: model.canWrite,
                    accessibilityLabel: "\(row.label) shortcut",
                    rejectionCount: recorder.rejectionCount,
                    action: { record(row.id) })

                CircleClearButton(
                    help: "Clear shortcut",
                    accessibilityLabel: "Clear shortcut for \(row.label)",
                    disabled: !model.canWrite || model.shortcutDisplay(for: row.id).isEmpty,
                    action: { model.clearShortcut(row.id) })
            }
            // Denser than a stock SettingsRow: sixteen of these stack up (7 quick actions + 9
            // zones), and at the default row height the list stops fitting in one look.
            .frame(minHeight: SettingsMetrics.shortcutRowHeight)
            .padding(.vertical, 3)

            Divider()
        }
    }

    // MARK: - Capture

    private func record(_ action: String) {
        guard model.canWrite else { return }
        // Once per capture, never per keystroke: this decodes every registered tool's section.
        model.prepareForRecording()
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
        /// Whether the STORE would accept a write, which is what the recovery reset needs — normal
        /// editing is off while our own section is unreadable, but the reset is exactly the way out
        /// of that. Mirrors `CyclerSettingsModel.canReset`.
        var canReset: () -> Bool
        /// Preserve the unreadable blob and start again from built-in defaults.
        var resetSection: () -> Void
        var shortcuts: () -> Shortcuts
        var setShortcuts: (Shortcuts) -> Void
        var isDragSnapOn: () -> Bool
        var setDragSnapOn: (Bool) -> Void
        var dragTrigger: () -> DragSnapTrigger
        var setDragTrigger: (DragSnapTrigger) -> Void
        /// Open the same layout overlay the menu bar's "Edit Layout…" opens.
        var openLayoutEditor: () -> Void
        /// True only while Zones is actually running — the overlay is one of the resources
        /// `ZonesTool.stop()` gives back, so it cannot be opened on a stopped tool.
        var isRunning: () -> Bool
        /// How many zones the layout on the main display actually has, so the rows past it can
        /// say so.
        var zoneCount: () -> Int
        /// Every combo any registered tool has bound, running or not (§5.6 cross-tool collisions).
        var boundCombos: () -> [ToolCombo]
    }

    struct ShortcutRow: Identifiable {
        var id: String
        var label: String
        /// A zone row past the end of the saved layout. The binding is kept and shown — it starts
        /// working again the moment the layout grows — but the row says it does nothing today.
        var isBeyondLayout = false
    }

    @Published private(set) var canWrite = true
    @Published private(set) var canReset = false
    @Published private(set) var blockedMessage: String?
    @Published private(set) var shortcuts = Shortcuts()
    @Published private(set) var dragSnapOn = true
    @Published private(set) var dragTrigger = DragSnapTrigger.default
    @Published private(set) var isRunning = false
    @Published private(set) var zoneCount = 0

    private let ctx: Context
    /// Snapshot of every tool's bound combos, taken when a capture STARTS. Rebuilding it decodes
    /// each tool's config section, so it must not be recomputed per keystroke — and by the time
    /// the capture is delivered the list can no longer have changed anyway.
    private var boundCombos: [ToolCombo] = []
    /// Cancels the pane's live capture. Set by the pane, which owns the recorder.
    var cancelRecording: (() -> Void)?
    /// Whose `cancelRecording` this is. A pane instance being torn down must only clear the hook
    /// when it still belongs to its own recorder.
    weak var recorder: ShortcutRecorder?
    /// Names another tool in a conflict alert. Replaced by the pane with the window's
    /// `SettingsStore.displayName(for:)`; the fallback is only used before the pane appears.
    var toolDisplayName: (ToolID) -> String = { $0.rawValue.capitalized }

    init(context: Context) {
        self.ctx = context
        refresh()
    }

    var quickShortcutRows: [ShortcutRow] {
        ShortcutKit.quickActions.map { ShortcutRow(id: $0.id, label: $0.label) }
    }

    var zoneShortcutRows: [ShortcutRow] {
        (1...ShortcutKit.zoneRows).map {
            ShortcutRow(id: ZoneAction.id($0), label: "Zone \($0)",
                        isBeyondLayout: zoneCount > 0 && $0 > zoneCount)
        }
    }

    var dragTriggerDisplay: String {
        ShortcutKit.dragSnapDisplay(keyCode: dragTrigger.keyCode, modifiers: dragTrigger.modifiers)
    }

    /// The same bind in words. The field SHOWS glyphs, like every other shortcut in the window,
    /// and VoiceOver cannot read a glyph — so the spoken value is the worded form.
    var dragTriggerSpokenValue: String {
        guard dragTrigger.keyCode == nil else { return dragTriggerDisplay }
        return ShortcutKit.modifierWords(dragTrigger.modifiers)
    }

    /// The editor is a live overlay, so it needs a running tool AND a config it can write back to.
    var canOpenLayoutEditor: Bool { isRunning && canWrite }

    func refresh() {
        canWrite = ctx.canWrite()
        canReset = ctx.canReset()
        blockedMessage = ctx.blockedMessage()
        shortcuts = ctx.shortcuts()
        dragSnapOn = ctx.isDragSnapOn()
        dragTrigger = ctx.dragTrigger()
        isRunning = ctx.isRunning()
        zoneCount = ctx.zoneCount()
    }

    /// Preserve the unreadable section and start again from defaults. Offered by the pane's
    /// blocked banner — the same recovery the menu bar's warning row offers.
    func resetSection() {
        cancelRecording?()
        ctx.resetSection()
        refresh()
    }

    func openLayoutEditor() {
        guard canOpenLayoutEditor else { return }
        // The editor takes over the screen; a capture left live would keep every tool's hotkeys
        // suspended behind it.
        cancelRecording?()
        ctx.openLayoutEditor()
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

    /// Refresh the cross-tool conflict snapshot. Called as a capture starts.
    func prepareForRecording() {
        boundCombos = ctx.boundCombos()
    }

    func clearShortcut(_ action: String) {
        guard canWrite else { return }
        // Clearing a row while it (or a sibling row) is capturing would leave the capture live and
        // therefore every tool's hotkeys suspended until the window blurred.
        cancelRecording?()
        ctx.setShortcuts(shortcuts.removing(action: action))
        refresh()
    }

    func resetDragBind() {
        guard canWrite else { return }
        // Resetting the bind while the bind (or a shortcut row) is capturing would leave the
        // capture live, and with it every tool's hotkeys suspended — the same reason
        // `clearShortcut` cancels first.
        cancelRecording?()
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
            if let owner = boundCombos.conflictOwner(keyCode: keyCode, modifiers: modifiers,
                                                     excluding: .zones) {
                showAlert("Shortcut already in use",
                          "This combo is used by \(toolDisplayName(owner)). Choose a different "
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

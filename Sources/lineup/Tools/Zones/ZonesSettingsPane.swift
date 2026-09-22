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
                        caption: "Saved zones are numbered across displays.") {
                        if model.zoneShortcutGroups.isEmpty {
                            Text("Open the layout editor to create zones, then assign shortcuts here.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 8)
                        } else {
                            ForEach(model.zoneShortcutGroups) { group in
                                zoneShortcutGroup(group)
                            }
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
        // VIEW-scoped display-change refresh: while this pane is visible, its connected/
        // disconnected group statuses stay live even when the Zones TOOL is disabled —
        // refresh() is a read-only projection through the Context; it never starts tool
        // resources, grabs hotkeys, monitors drags, or writes/creates config. The running
        // tool's own observer remains the single owner of reconciliation and open-editor
        // refreshes; this is deliberately a second, write-free subscriber.
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didChangeScreenParametersNotification)) { _ in
            model.refresh()
        }
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

    private func zoneShortcutGroup(_ group: ZonesSettingsModel.ZoneShortcutGroup) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(group.title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Spacer(minLength: 12)
                if let rangeLabel = group.rangeLabel {
                    Text(rangeLabel)
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Text(group.status.label)
                    .font(.caption)
                    .foregroundStyle(group.status == .connected
                                     ? Color(nsColor: Brand.blue)
                                     : Color(nsColor: .secondaryLabelColor))
            }
            .padding(.top, 10)
            .padding(.bottom, 4)
            .accessibilityElement(children: .combine)

            ForEach(group.rows) { row in
                shortcutRow(row)
            }
        }
    }

    @ViewBuilder
    private func shortcutRow(_ row: ZonesSettingsModel.ShortcutRow) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text(row.label)
                    .accessibilityLabel(row.labelAccessibilityLabel)
                Spacer(minLength: 24)
                RecorderButton(
                    text: model.shortcutDisplay(for: row.id),
                    emptyText: "Click to set",
                    isRecording: recorder.isRecording(row.id),
                    enabled: model.canWrite,
                    accessibilityLabel: row.recorderAccessibilityLabel,
                    rejectionCount: recorder.rejectionCount,
                    action: { record(row.id) })

                CircleClearButton(
                    help: "Clear shortcut",
                    accessibilityLabel: row.clearAccessibilityLabel,
                    disabled: !model.canWrite || model.shortcutDisplay(for: row.id).isEmpty,
                    action: { model.clearShortcut(row.id) })
            }
            // Shortcut rows stay denser than a stock SettingsRow. Large saved layouts can expose
            // many zones, so the recorder list needs to remain easy to scan while it scrolls.
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
        /// Globally numbered saved zones, grouped by their owning display. `ZonesTool` chooses
        /// the candidate or committed numbering snapshot so presentation matches write/routing
        /// safety rather than reconstructing that policy in the view model.
        var zoneShortcutGroups: () -> [ZoneShortcutGroup]
        /// Every combo any registered tool has bound, running or not (§5.6 cross-tool collisions).
        var boundCombos: () -> [ToolCombo]
    }

    struct ShortcutRow: Identifiable {
        var id: String
        var label: String
        /// Display and availability context for VoiceOver. Visible grouping carries the same
        /// information without repeating it in every compact row.
        var accessibilityContext: String?

        var recorderAccessibilityLabel: String {
            ["\(label) shortcut", accessibilityContext].compactMap { $0 }.joined(separator: ", ")
        }

        var labelAccessibilityLabel: String {
            [label, accessibilityContext].compactMap { $0 }.joined(separator: ", ")
        }

        var clearAccessibilityLabel: String {
            ["Clear shortcut for \(label)", accessibilityContext].compactMap { $0 }.joined(separator: ", ")
        }
    }

    struct ZoneShortcutGroup: Identifiable {
        enum Status: Equatable {
            case connected
            case notConnected
            case notInSavedLayout

            var label: String {
                switch self {
                case .connected: return "Connected"
                case .notConnected: return "Not connected"
                case .notInSavedLayout: return "Not in a saved layout"
                }
            }

            var accessibilityDescription: String { label.lowercased() }
        }

        var id: String
        var title: String
        var rangeLabel: String?
        var status: Status
        var rows: [ShortcutRow]
    }

    @Published private(set) var canWrite = true
    @Published private(set) var canReset = false
    @Published private(set) var blockedMessage: String?
    @Published private(set) var shortcuts = Shortcuts()
    @Published private(set) var dragSnapOn = true
    @Published private(set) var dragTrigger = DragSnapTrigger.default
    @Published private(set) var isRunning = false
    @Published private(set) var zoneShortcutGroups: [ZoneShortcutGroup] = []

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
        ShortcutKit.quickActions.map { ShortcutRow(id: $0.id, label: $0.label, accessibilityContext: nil) }
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
        zoneShortcutGroups = ctx.zoneShortcutGroups()
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

import AppKit
import AppCore
import Carbon.HIToolbox
import CyclerCore
import SwiftUI

// Cycler's Settings pane, from standalone Cycler's `ShortcutsTab` + `SettingsModel`.
//
// Two deliberate differences from the 1.x original:
//   * every hyper-key member is gone — Hyperkey is its own tool with its own section (plan §2.2);
//   * the model no longer owns an `NSEvent` monitor. Capture is `ShortcutRecorder`'s job, because
//     it is what routes through `SettingsStore` and therefore suspends ALL THREE tools' hotkeys
//     while a combo is being recorded. What is kept from the old `handle()` is exactly the part
//     that is Cycler's: merge-on-duplicate-combo, the reverse-collision warning, and `apply()`.

/// The pane's view model: a draft list of rows that is written back through `CyclerTool.save`.
@MainActor
final class CyclerSettingsModel: ObservableObject {
    struct AppEntry: Identifiable, Equatable {
        var bundleIdentifier: String
        var name: String
        var icon: NSImage?
        var installed: Bool
        var id: String { bundleIdentifier }
    }

    struct Row: Identifiable {
        let id = UUID()
        var apps: [AppEntry]
        var keyCode: Int?
        var modifiers: UInt32?

        var isGroup: Bool { apps.count > 1 }
        var missingCount: Int { apps.filter { !$0.installed }.count }
        /// Every app in this binding is gone — the row cannot do anything until one comes back.
        var isOrphaned: Bool { !apps.isEmpty && missingCount == apps.count }
        var missingHelp: String {
            missingCount == 1 && apps.count == 1
                ? "This app is not installed"
                : "\(missingCount) of these apps are not installed"
        }
        var title: String {
            guard !apps.isEmpty else { return "Empty Shortcut" }
            if apps.count <= 2 { return apps.map(\.name).joined(separator: " + ") }
            return "\(apps[0].name) + \(apps[1].name) + \(apps.count - 2) more"
        }
        var detailText: String {
            if missingCount > 0 {
                return missingCount == 1 ? "1 app not installed" : "\(missingCount) apps not installed"
            }
            return isGroup ? "First app launches when none are running" : "Cycles windows"
        }
        var shortcutText: String {
            guard let keyCode, let modifiers else { return "" }
            return ShortcutKit.display(keyCode: keyCode, modifiers: modifiers)
        }
        var binding: AppBinding? {
            guard let keyCode, let modifiers, !apps.isEmpty else { return nil }
            return AppBinding(
                keyCode: keyCode,
                modifiers: modifiers,
                bundleIdentifiers: apps.map(\.bundleIdentifier))
        }
    }

    struct AlertItem: Identifiable { let id = UUID(); let title: String; let message: String }
    struct PickerRequest: Identifiable {
        let id = UUID()
        var targetRowID: UUID?
    }

    @Published var rows: [Row] = []
    @Published var pickerRequest: PickerRequest?
    @Published var alert: AlertItem?
    /// A freshly added row drops straight into recording. The recorder lives in the view, so the
    /// model asks for it here and the view starts the capture.
    @Published var pendingRecordRowID: UUID?

    private unowned let tool: CyclerTool
    /// Snapshot of every tool's bound combos, taken when a capture STARTS (§5.6). Rebuilding it
    /// decodes each tool's config section, so it must not be recomputed per keystroke.
    private var boundCombos: [ToolCombo] = []
    /// Cancels the pane's live capture. Set by the pane, which owns the recorder.
    var cancelRecording: (() -> Void)?
    /// Whose `cancelRecording` this is. A pane instance being torn down must only clear the hook
    /// when it still belongs to its own recorder.
    weak var recorder: ShortcutRecorder?
    /// Names another tool in a conflict alert. Replaced by the pane with the window's
    /// `SettingsStore.displayName(for:)`; the fallback is only used before the pane appears.
    var toolDisplayName: (ToolID) -> String = { $0.rawValue.capitalized }

    init(tool: CyclerTool) {
        self.tool = tool
        reload()
    }

    var boundIdentifiers: Set<String> {
        Set(rows.flatMap { row in row.apps.map(\.bundleIdentifier) })
    }

    /// True when edits can actually be persisted. The tool holds its `ToolServices` from
    /// registration, so shortcuts stay editable while Cycler is switched off — a write-blocked
    /// store, or a section of our own that could not be read, turns this false.
    var canEdit: Bool { tool.canEdit }

    /// Whether the STORE would accept a write — what the recovery reset needs, even though
    /// ordinary editing is off while the section is unreadable.
    var canReset: Bool { tool.canPersist }

    /// Why editing is off, if it is.
    var blockedMessage: String? { tool.configBlockedMessage }

    var loadErrorMessage: String? { tool.sectionLoadError }

    /// Preserve the unreadable blob and start again from an empty binding set.
    func resetSection() {
        cancelRecording?()
        tool.resetSection()
    }

    /// Re-read the live bindings. Called when the tool reloads its section from the store.
    func reload() {
        // The rows are about to be replaced, so a capture aimed at one of them has nothing left
        // to write into — and leaving it live would strand every tool's hotkeys suspended.
        cancelRecording?()
        rows = tool.settings.bindings.map { b in
            Row(apps: b.bundleIdentifiers.map(Self.appEntry),
                keyCode: b.keyCode, modifiers: b.modifiers)
        }
    }

    /// Refresh the cross-tool conflict snapshot. Called as a capture starts.
    func prepareForRecording() {
        boundCombos = tool.boundCombos()
    }

    // MARK: - Editing

    // Both pickers stop the capture first. The sheet has a search field, and a recorder left live
    // behind it would swallow every keystroke typed into it. (Carried over from standalone
    // Cycler, whose SettingsModel called stopRecording() here.)

    func showAddShortcutPicker() {
        cancelRecording?()
        pickerRequest = PickerRequest(targetRowID: nil)
    }

    func showAddAppPicker(for row: Row) {
        cancelRecording?()
        pickerRequest = PickerRequest(targetRowID: row.id)
    }

    func finishPicking(_ choice: AppChoice?, request: PickerRequest) {
        guard let choice else { return }
        if let rowID = request.targetRowID {
            add(choice, to: rowID)
        } else {
            addShortcut(choice)
        }
    }

    func addShortcut(_ choice: AppChoice) {
        let row = Row(apps: [Self.appEntry(for: choice)])
        rows.append(row)
        // An app with no combo yet isn't persisted, so send the user straight into recording.
        pendingRecordRowID = row.id
    }

    func add(_ choice: AppChoice, to rowID: UUID) {
        guard let idx = rows.firstIndex(where: { $0.id == rowID }),
              !boundIdentifiers.contains(choice.bundleIdentifier) else { return }
        rows[idx].apps.append(Self.appEntry(for: choice))
        apply()
    }

    func remove(_ row: Row) {
        // The row being deleted may be the one capturing; the recorder would then hold the whole
        // registry suspended until the window blurred, with nothing left to deliver into.
        cancelRecording?()
        rows.removeAll { $0.id == row.id }
        apply()
    }

    func remove(_ app: AppEntry, from row: Row) {
        guard let rowIdx = rows.firstIndex(where: { $0.id == row.id }) else { return }
        rows[rowIdx].apps.removeAll { $0.bundleIdentifier == app.bundleIdentifier }
        if rows[rowIdx].apps.isEmpty {
            rows.remove(at: rowIdx)
        }
        apply()
    }

    func move(_ app: AppEntry, in row: Row, by offset: Int) {
        guard let rowIdx = rows.firstIndex(where: { $0.id == row.id }),
              let appIdx = rows[rowIdx].apps.firstIndex(of: app) else { return }
        let maxIdx = rows[rowIdx].apps.count - 1
        let newIdx = min(max(appIdx + offset, 0), maxIdx)
        guard newIdx != appIdx else { return }
        let moved = rows[rowIdx].apps.remove(at: appIdx)
        rows[rowIdx].apps.insert(moved, at: newIdx)
        apply()
    }

    // MARK: - Capture

    /// What `ShortcutRecorder` hands back for one row. This is the Cycler-specific half of the old
    /// `handle(_:)`: Esc/Delete/bare-key handling now lives in the recorder, the merge and the
    /// reverse-collision warning stay here.
    func handleCapture(_ capture: ShortcutRecorder.Capture, for rowID: UUID) {
        guard let idx = rows.firstIndex(where: { $0.id == rowID }) else { return }

        switch capture {
        case .clear:
            rows[idx].keyCode = nil
            rows[idx].modifiers = nil
            apply()

        case .modifiersOnly:
            // Cycler rows are always key + modifiers; the recorder only offers this to Zones'
            // drag bind, and we never ask for it. Ignore rather than persist half a combo.
            break

        case .combo(let keyCode, let modifiers):
            // Another TOOL's combo is refused outright — there is nothing sensible to merge into,
            // and Cycler would only lose the race at registration time. Checked before the
            // same-pane merge so a foreign owner is never silently overwritten.
            if let owner = boundCombos.conflictOwner(keyCode: keyCode, modifiers: modifiers,
                                                     excluding: .cycler) {
                alert = AlertItem(
                    title: "Shortcut already in use",
                    message: "This combo is used by \(toolDisplayName(owner)). Choose a "
                        + "different shortcut, or change it in that tool's settings.")
                return
            }
            // Recording a combo another row already owns means "these apps belong together":
            // fold this row into that one instead of writing a duplicate the coalescer would
            // silently merge later anyway. ASK first — two rows collapsing into one with no
            // warning looks like the other row was deleted. Zones confirms its equivalent
            // reassign the same way.
            if let other = rows.firstIndex(where: {
                $0.id != rowID && $0.keyCode == keyCode && $0.modifiers == modifiers
            }) {
                guard confirmMerge(source: rows[idx], target: rows[other],
                                   combo: ShortcutKit.display(keyCode: keyCode,
                                                              modifiers: modifiers)) else { return }
                merge(rowID: rowID, into: rows[other].id)
                return
            }
            rows[idx].keyCode = keyCode
            rows[idx].modifiers = modifiers
            let collision = reverseShortcutCollision(for: rowID, keyCode: keyCode, modifiers: modifiers)
            if apply(), let collision {
                alert = reverseCollisionWarning(recordedKeyCode: keyCode,
                                                recordedModifiers: modifiers,
                                                source: collision)
            }
        }
    }

    /// Persist only complete rows (app + shortcut) and re-register; an incomplete row stays
    /// visible in the pane until its shortcut is recorded.
    @discardableResult
    func apply() -> Bool {
        do {
            try tool.save(CyclerToolSettings(bindings: rows.compactMap(\.binding)))
            return true
        } catch {
            let item = AlertItem(title: "Couldn’t save your shortcuts.",
                                 message: error.localizedDescription)
            // On the NEXT runloop turn, not now. `add(_:to:)` runs while the app-picker sheet is
            // dismissing, and an alert published inside that same transaction is dropped — adding
            // an app to a group with writes blocked produced no feedback at all.
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated { self?.alert = item }
            }
            return false
        }
    }

    /// A Shift combo collides when some other row's combo would generate it as its reverse — that
    /// generated reverse is skipped, so say so rather than leave the user wondering.
    private func reverseShortcutCollision(for rowID: UUID, keyCode: Int, modifiers: UInt32) -> Row? {
        guard modifiers & UInt32(shiftKey) != 0 else { return nil }
        let generatedForwardModifiers = modifiers & ~UInt32(shiftKey)
        return rows.first {
            $0.id != rowID && $0.keyCode == keyCode && $0.modifiers == generatedForwardModifiers
        }
    }

    private func reverseCollisionWarning(recordedKeyCode: Int, recordedModifiers: UInt32, source: Row) -> AlertItem {
        let recorded = ShortcutKit.display(keyCode: recordedKeyCode, modifiers: recordedModifiers)
        let sourceShortcut = ShortcutKit.display(keyCode: recordedKeyCode,
                                                 modifiers: recordedModifiers & ~UInt32(shiftKey))
        return AlertItem(
            title: "Reverse shortcut will be skipped.",
            message: "\(recorded) is the generated reverse shortcut for \(source.title) (\(sourceShortcut)). Lineup saved it, but that reverse shortcut will not be registered.")
    }

    /// Name both rows and let the user back out. Runs a modal loop, which is safe here: the
    /// recorder has already handed every tool's hotkeys back by the time a capture is delivered.
    private func confirmMerge(source: Row, target: Row, combo: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Combine these shortcuts?"
        alert.informativeText = "\(combo) is already assigned to \(target.title). "
            + "\(source.title) will join that shortcut as one group, and \(source.title) will no "
            + "longer have a shortcut of its own."
        alert.addButton(withTitle: "Merge")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func merge(rowID sourceID: UUID, into targetID: UUID) {
        guard sourceID != targetID,
              let sourceIdx = rows.firstIndex(where: { $0.id == sourceID }),
              let targetIdx = rows.firstIndex(where: { $0.id == targetID }) else { return }

        var seen = Set(rows[targetIdx].apps.map(\.bundleIdentifier))
        for app in rows[sourceIdx].apps where !seen.contains(app.bundleIdentifier) {
            rows[targetIdx].apps.append(app)
            seen.insert(app.bundleIdentifier)
        }
        rows.removeAll { $0.id == sourceID }
        apply()
    }

    // MARK: - App entries

    private static func appEntry(_ bundleIdentifier: String) -> AppEntry {
        let installed = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) != nil
        return AppEntry(bundleIdentifier: bundleIdentifier,
                        // `displayName`, not `name`: an uninstalled app has no Launch Services
                        // entry to ask, and the raw identifier is not a name.
                        name: AppInfo.displayName(forBundleIdentifier: bundleIdentifier),
                        icon: AppInfo.icon(forBundleIdentifier: bundleIdentifier),
                        installed: installed)
    }

    private static func appEntry(for choice: AppChoice) -> AppEntry {
        AppEntry(bundleIdentifier: choice.bundleIdentifier, name: choice.name,
                 icon: choice.icon, installed: true)
    }
}

// MARK: - Pane

/// The window's `SettingsStore` arrives through the environment (injected by
/// `SettingsStore.pane(for:)`). It has to be read here and passed down by value, because the
/// recorder is a `@StateObject` and an `@EnvironmentObject` is not available during `init`.
struct CyclerSettingsPane: View {
    @ObservedObject var model: CyclerSettingsModel
    @EnvironmentObject private var settings: SettingsStore

    var body: some View {
        CyclerSettingsPaneBody(model: model, settings: settings)
    }
}

private struct CyclerSettingsPaneBody: View {
    @ObservedObject var model: CyclerSettingsModel
    /// One recorder for the whole pane; `activeID` is the row `UUID` capturing right now.
    @StateObject private var recorder: ShortcutRecorder
    /// Held only to name a conflicting tool the way the sidebar does; the pane does not observe it.
    private let settings: SettingsStore

    init(model: CyclerSettingsModel, settings: SettingsStore) {
        self.model = model
        self.settings = settings
        _recorder = StateObject(wrappedValue: ShortcutRecorder(store: settings))
    }

    var body: some View {
        // Same shape as every other pane now: a pinned banner strip, then the 540pt content
        // column of `SettingsSectionView`s. The hero divider, the List inset background and the
        // fixed footer bar this used to draw were the three things that made Cycler read as a
        // different app's window — and the footer's own divider ran to the pane edge while the
        // list's stopped at the inset.
        VStack(alignment: .leading, spacing: 0) {
            // Two INDEPENDENT conditions, not an either/or: an unreadable section and a
            // write-blocked envelope can both be true, and the store-level banner is the one that
            // explains why even the reset below is unavailable.
            if let message = model.blockedMessage {
                PinnedBannerStrip {
                    BlockedBanner(message: message,
                                  actionTitle: "Reset Cycler Shortcuts…",
                                  action: { model.resetSection() },
                                  actionEnabled: model.canReset)
                }
            }

            // A section we could not read is NOT an empty binding list. Showing the "No shortcuts
            // yet" empty state there told the user their shortcuts were gone and offered an Add
            // button that could not save — say what happened and offer the recovery instead.
            if let message = model.loadErrorMessage {
                CyclerLoadErrorState(detail: message, canReset: model.canReset) {
                    model.resetSection()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.rows.isEmpty {
                CyclerEmptyState(enabled: model.canEdit) { model.showAddShortcutPicker() }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: SettingsMetrics.sectionSpacing) {
                        // The reverse-shortcut hint is the only guidance the hero summary does
                        // not already give, and as a section caption it is attached to the rows
                        // it describes instead of floating in a footer bar.
                        SettingsSectionView(
                            "Shortcuts",
                            caption: "Keep 1–4 and letters for apps. Tiles uses U/I/O/P for workspaces. Add ⇧ to cycle backwards.") {
                            ForEach(model.rows) { row in
                                VStack(spacing: 0) {
                                    CyclerBindingRow(row: row, model: model, recorder: recorder)
                                    Divider()
                                }
                            }
                        }

                        Button { model.showAddShortcutPicker() } label: {
                            Label("Add Shortcut", systemImage: "plus")
                        }
                        .disabled(!model.canEdit)
                    }
                    .frame(width: SettingsMetrics.contentWidth, alignment: .leading)
                    .padding(.vertical, SettingsMetrics.panePaddingVertical)
                    .frame(maxWidth: .infinity)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .navigationTitle("Cycler")
        .onAppear {
            // The model has to be able to end a capture from a non-recorder action (opening a
            // picker, deleting a row, reloading), and the recorder is the view's.
            model.recorder = recorder
            model.cancelRecording = { [weak recorder] in recorder?.cancel() }
            // Conflict alerts name the owning tool the way the sidebar does.
            model.toolDisplayName = { [weak settings] id in
                settings?.displayName(for: id) ?? id.rawValue.capitalized
            }
        }
        .onChange(of: model.pendingRecordRowID) { rowID in
            guard let rowID else { return }
            model.pendingRecordRowID = nil
            model.prepareForRecording()
            recorder.begin(rowID) { capture in
                model.handleCapture(capture, for: rowID)
            }
        }
        .onDisappear {
            recorder.cancel()
            // Only if the hook is still OURS. SwiftUI can build a replacement pane before tearing
            // the old one down, and an unconditional clear left the live pane unable to end a
            // capture — every tool's hotkeys then stayed suspended until the window blurred.
            guard model.recorder === recorder else { return }
            model.recorder = nil
            model.cancelRecording = nil
        }
        .sheet(item: $model.pickerRequest) { request in
            AppPickerView(excluding: model.boundIdentifiers) { choice in
                model.finishPicking(choice, request: request)
            }
        }
        .alert(item: $model.alert) { a in
            Alert(title: Text(a.title), message: Text(a.message), dismissButton: .default(Text("OK")))
        }
    }

    // No instruction paragraph here on purpose. The same guidance was reaching the user three
    // times over — the `ToolPane` hero summary, a paragraph at the top of this pane, and the
    // empty state. The hero summary and the empty state are kept; what is left over (the reverse
    // shortcut) is the "Shortcuts" section caption, where it is only shown once there are
    // shortcuts to describe.
}

private struct CyclerBindingRow: View {
    let row: CyclerSettingsModel.Row
    @ObservedObject var model: CyclerSettingsModel
    @ObservedObject var recorder: ShortcutRecorder

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                CyclerAppIconStack(apps: row.apps)
                    // A row whose apps are all gone is dimmed the way a missing group member is,
                    // so "this binding does nothing right now" reads before the text does.
                    .opacity(row.isOrphaned ? 0.55 : 1)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(row.title).font(.system(size: 14, weight: .medium)).lineLimit(1)
                        if row.missingCount > 0 {
                            // Was a tertiary grey glyph — invisible at the exact moment it had
                            // something to say. Orange, and named for VoiceOver.
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.caption)
                                .foregroundStyle(.orange)
                                .help(row.missingHelp)
                                .accessibilityLabel(row.missingHelp)
                        }
                    }
                    .opacity(row.isOrphaned ? 0.7 : 1)
                    Text(row.detailText).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 12)
                ShortcutField(
                    text: row.shortcutText,
                    isRecording: recorder.isRecording(row.id),
                    accent: Color(nsColor: Brand.cyclerAccent),
                    enabled: model.canEdit,
                    accessibilityLabel: "Shortcut for \(row.title)",
                    rejectionCount: recorder.rejectionCount
                ) {
                    // Once per capture, never per keystroke: this decodes every tool's section.
                    model.prepareForRecording()
                    recorder.toggle(row.id) { capture in
                        model.handleCapture(capture, for: row.id)
                    }
                }
                Button {
                    model.showAddAppPicker(for: row)
                } label: {
                    Image(systemName: "plus.circle").foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .disabled(!model.canEdit)
                .help("Add app to this shortcut")
                .accessibilityLabel("Add app to \(row.title)")
                Button {
                    model.remove(row)
                } label: {
                    Image(systemName: "minus.circle.fill").foregroundStyle(.tertiary)
                }
                .buttonStyle(.borderless)
                .disabled(!model.canEdit)
                .help("Remove shortcut")
                .accessibilityLabel("Remove shortcut for \(row.title)")
            }

            if row.isGroup {
                CyclerGroupAppList(row: row, model: model)
                    .padding(.leading, 38)
            }
        }
        .padding(.vertical, 6)
    }
}

private struct CyclerAppIconStack: View {
    let apps: [CyclerSettingsModel.AppEntry]

    var body: some View {
        let visibleApps = apps.count > 3 ? Array(apps.prefix(2)) : Array(apps.prefix(3))
        HStack(spacing: -6) {
            ForEach(visibleApps) { app in
                Image(nsImage: app.icon ?? NSWorkspace.shared.icon(for: .applicationBundle))
                    .resizable()
                    .frame(width: 26, height: 26)
                    .clipShape(RoundedRectangle(cornerRadius: 5))
                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color(nsColor: .separatorColor), lineWidth: 0.5))
            }
            if apps.count > 3 {
                Text("+\(apps.count - visibleApps.count)")
                    .font(.system(size: 10, weight: .semibold))
                    .frame(width: 26, height: 26)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 5))
            }
        }
        .frame(width: 66, alignment: .leading)
    }
}

private struct CyclerGroupAppList: View {
    let row: CyclerSettingsModel.Row
    @ObservedObject var model: CyclerSettingsModel
    @State private var draggingID: String?

    var body: some View {
        VStack(spacing: 4) {
            ForEach(Array(row.apps.enumerated()), id: \.element.id) { idx, app in
                HStack(spacing: 8) {
                    Image(systemName: "line.3.horizontal")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .help("Drag to reorder")
                    Text("\(idx + 1)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 16, alignment: .trailing)
                    Image(nsImage: app.icon ?? NSWorkspace.shared.icon(for: .applicationBundle))
                        .resizable().frame(width: 18, height: 18)
                    Text(app.name).font(.caption).lineLimit(1)
                    if idx == 0 {
                        Label("Primary", systemImage: "flag.fill")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .help("Launches first when none of the group apps are running")
                    }
                    if !app.installed {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                            .help("App not installed")
                            .accessibilityLabel("\(app.name) is not installed")
                    }
                    Spacer(minLength: 8)
                    Button {
                        model.move(app, in: row, by: -1)
                    } label: {
                        Image(systemName: "chevron.up").font(.caption)
                    }
                    .buttonStyle(.borderless)
                    .disabled(idx == 0 || !model.canEdit)
                    .help("Move up")
                    .accessibilityLabel("Move \(app.name) up")
                    Button {
                        model.move(app, in: row, by: 1)
                    } label: {
                        Image(systemName: "chevron.down").font(.caption)
                    }
                    .buttonStyle(.borderless)
                    .disabled(idx == row.apps.count - 1 || !model.canEdit)
                    .help("Move down")
                    .accessibilityLabel("Move \(app.name) down")
                    Button {
                        model.remove(app, from: row)
                    } label: {
                        Image(systemName: "minus.circle").font(.caption).foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.borderless)
                    .disabled(!model.canEdit)
                    .help("Remove app from group")
                    .accessibilityLabel("Remove \(app.name) from group")
                }
                .padding(.vertical, 2)
                .opacity(app.installed ? 1 : 0.55)
                .background(draggingID == app.bundleIdentifier ? Color(nsColor: .selectedContentBackgroundColor).opacity(0.12) : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: 5))
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 4)
                    .onChanged { _ in
                        draggingID = app.bundleIdentifier
                    }
                    .onEnded { value in
                        let rowHeight: CGFloat = 26
                        let offset = Int((value.translation.height / rowHeight).rounded())
                        if offset != 0, model.canEdit {
                            model.move(app, in: row, by: offset)
                        }
                        draggingID = nil
                    })
                .accessibilityAction(named: "Move Up") {
                    model.move(app, in: row, by: -1)
                }
                .accessibilityAction(named: "Move Down") {
                    model.move(app, in: row, by: 1)
                }
                .onDisappear {
                    if draggingID == app.bundleIdentifier {
                        draggingID = nil
                    }
                }
                .help("Drag to reorder")
            }
        }
    }
}

/// Shown INSTEAD of the empty state when the cycler section is on disk but does not decode. The
/// distinction matters: the empty state says "you have no shortcuts", which is a lie here, and its
/// Add button could only fail. This says what happened and offers the one action that helps.
private struct CyclerLoadErrorState: View {
    let detail: String
    let canReset: Bool
    let onReset: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 40))
                .foregroundStyle(.orange)
            Text("Your shortcuts couldn’t be read")
                .font(.system(size: 17, weight: .semibold))
            Text("They were left exactly as they are on disk, so nothing is lost yet. Resetting "
                 + "keeps a copy of the unreadable file next to your settings and starts again "
                 + "from an empty list.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
            Text(detail)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .frame(maxWidth: 380)
            Button(action: onReset) { Label("Reset Shortcuts…", systemImage: "arrow.counterclockwise") }
                .controlSize(.large)
                .disabled(!canReset)
                .padding(.top, 4)
        }
        .padding(40)
    }
}

private struct CyclerEmptyState: View {
    let enabled: Bool
    let onAdd: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "command").font(.system(size: 40)).foregroundStyle(.tertiary)
            Text("No shortcuts yet").font(.system(size: 17, weight: .semibold))
            Text("Add apps to 1–4 or letters. Tiles uses U/I/O/P for workspaces.")
                .font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).frame(maxWidth: 340)
            Button(action: onAdd) { Label("Add Shortcut", systemImage: "plus") }
                .controlSize(.large)
                .disabled(!enabled)
                .padding(.top, 4)
        }
        .padding(40)
    }
}

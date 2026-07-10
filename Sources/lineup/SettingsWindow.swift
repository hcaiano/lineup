import AppKit
import ApplicationServices
import LineupCore
import Sparkle
import SwiftUI

/// Hooks the Settings window needs from the app.
struct SettingsContext {
    var config: () -> LineupConfig
    var canWrite: () -> Bool                             // false when config writes are blocked
    var blockedMessage: () -> String?                    // why editing is disabled, if so
    var shortcuts: () -> Shortcuts                       // effective shortcut set
    var setShortcuts: (Shortcuts) -> Void                // persist + re-register hotkeys
    var setRecording: (Bool) -> Void                     // suspend global hotkeys while capturing a combo
    var isDragSnapOn: () -> Bool
    var toggleDragSnap: () -> Void
    var dragSnapTrigger: () -> DragSnapTrigger
    var setDragSnapTrigger: (DragSnapTrigger) -> Void
    var isMenuBarIconShown: () -> Bool
    var setMenuBarIconShown: (Bool) -> Void
    var isLaunchAtLoginOn: () -> Bool
    var toggleLaunchAtLogin: () -> Void
    var isTrusted: () -> Bool
    var requestAccessibility: () -> Void
}

/// Native SwiftUI settings hosted from the existing AppKit menu-bar app.
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private let window: NSWindow
    private let model: SettingsModel
    var onClose: (() -> Void)?

    init(context: SettingsContext) {
        self.model = SettingsModel(context: context)
        let root = SettingsRootView(model: model)
        let hosting = NSHostingView(rootView: root)
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 500),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false)
        window.title = "Lineup Settings"
        window.contentMinSize = NSSize(width: 560, height: 440)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        super.init()
        window.delegate = self
    }

    func show() {
        model.refresh()
        NSApp.activate(ignoringOtherApps: true)
        window.center()
        window.makeKeyAndOrderFront(nil)
    }

    /// Called when the app detects Accessibility was granted/revoked while Settings is open.
    func refreshAccessibility() { model.refresh() }

    func windowDidResignKey(_ notification: Notification) {
        model.stopAllRecording()
    }

    func windowWillClose(_ notification: Notification) {
        model.stopAllRecording()
        onClose?()
    }
}

private enum SettingsTab: Hashable {
    case general
    case shortcuts
    case about
}

private struct ShortcutRow: Identifiable {
    var id: String
    var label: String
}

private let settingsContentWidth: CGFloat = 540

private final class SettingsModel: ObservableObject {
    private let ctx: SettingsContext
    private var monitor: Any?
    private var modifierOnlyTimer: Timer?
    private var pendingModifierOnly: Int?

    @Published var selectedTab: SettingsTab = .general
    @Published private(set) var canWrite = true
    @Published private(set) var blockedMessage: String?
    @Published private(set) var shortcuts = Shortcuts()
    @Published private(set) var dragSnapOn = true
    @Published private(set) var dragTrigger = DragSnapTrigger.default
    @Published private(set) var menuBarIconShown = true
    @Published private(set) var launchAtLoginOn = false
    @Published private(set) var accessibilityGranted = false
    @Published var recordingAction: String?
    @Published var isRecordingDrag = false

    init(context: SettingsContext) {
        self.ctx = context
        refresh()
    }

    deinit {
        if let m = monitor { NSEvent.removeMonitor(m) }
        modifierOnlyTimer?.invalidate()
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
        dragTrigger = ctx.dragSnapTrigger()
        menuBarIconShown = ctx.isMenuBarIconShown()
        launchAtLoginOn = ctx.isLaunchAtLoginOn()
        accessibilityGranted = ctx.isTrusted()
    }

    func setDragSnapOn(_ value: Bool) {
        guard value != dragSnapOn else { return }
        ctx.toggleDragSnap()
        refresh()
    }

    func setLaunchAtLoginOn(_ value: Bool) {
        guard value != launchAtLoginOn else { return }
        ctx.toggleLaunchAtLogin()
        refresh()
    }

    func setMenuBarIconShown(_ value: Bool) {
        guard value != menuBarIconShown else { return }
        ctx.setMenuBarIconShown(value)
        refresh()
    }

    func requestAccessibility() {
        ctx.requestAccessibility()
        refresh()
    }

    func shortcutDisplay(for action: String) -> String {
        shortcuts.binding(for: action).map { ShortcutKit.display(keyCode: $0.keyCode, modifiers: $0.modifiers) } ?? ""
    }

    func clearShortcut(_ action: String) {
        guard canWrite else { return }
        if recordingAction != nil { stopAllRecording() }
        ctx.setShortcuts(shortcuts.removing(action: action))
        refresh()
    }

    func beginShortcutRecording(_ action: String) {
        guard canWrite else { return }
        if recordingAction == action {
            stopAllRecording()
            return
        }
        stopAllRecording()
        recordingAction = action
        ctx.setRecording(true)
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            self?.handleShortcutEvent(event) == true ? nil : event
        }
    }

    func beginDragRecording() {
        guard canWrite else { return }
        if isRecordingDrag {
            stopAllRecording()
            return
        }
        stopAllRecording()
        isRecordingDrag = true
        ctx.setRecording(true)
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            self?.handleDragRecording(event) == true ? nil : event
        }
    }

    func resetDragBind() {
        guard canWrite else { return }
        stopAllRecording()
        ctx.setDragSnapTrigger(.default)
        refresh()
    }

    func stopAllRecording() {
        let wasRecording = recordingAction != nil || isRecordingDrag
        recordingAction = nil
        isRecordingDrag = false
        pendingModifierOnly = nil
        modifierOnlyTimer?.invalidate()
        modifierOnlyTimer = nil
        if let m = monitor {
            NSEvent.removeMonitor(m)
            monitor = nil
        }
        if wasRecording { ctx.setRecording(false) }
        refresh()
    }

    private func handleShortcutEvent(_ event: NSEvent) -> Bool {
        guard let action = recordingAction else { return false }
        guard canWrite else { stopAllRecording(); return true }

        let keyCode = Int(event.keyCode)
        let bare = !ShortcutKit.hasModifier(event.modifierFlags)
        if keyCode == 53, bare { stopAllRecording(); return true }       // Esc cancels
        if keyCode == 51, bare {                                      // Delete clears
            ctx.setShortcuts(shortcuts.removing(action: action))
            stopAllRecording()
            return true
        }
        guard ShortcutKit.hasModifier(event.modifierFlags) else {
            NSSound.beep()
            return true
        }

        let mods = ShortcutKit.carbonModifiers(from: event.modifierFlags)
        let conflicts = shortcuts.conflicts(keyCode: keyCode, modifiers: mods, excluding: action)
        stopAllRecording()
        if !conflicts.isEmpty, !confirmConflict(conflicts) { return true }
        if dragBindConflicts(keyCode: keyCode, modifiers: mods) {
            showDragBindConflict()
            return true
        }

        var updated = shortcuts
        for conflict in conflicts { updated = updated.removing(action: conflict) }
        ctx.setShortcuts(updated.setting(action: action, keyCode: keyCode, modifiers: mods))
        refresh()
        return true
    }

    private func handleDragRecording(_ event: NSEvent) -> Bool {
        guard isRecordingDrag else { return false }
        guard canWrite else { stopAllRecording(); return true }

        switch event.type {
        case .keyDown:
            let keyCode = Int(event.keyCode)
            let bare = !ShortcutKit.hasModifier(event.modifierFlags)
            if keyCode == 53, bare { stopAllRecording(); return true } // Esc cancels
            if keyCode == 51, bare { resetDragBind(); return true }    // Delete resets

            let mods = ShortcutKit.carbonModifiers(from: event.modifierFlags)
            let conflicts = shortcuts.conflicts(keyCode: keyCode, modifiers: mods, excluding: "")
            stopAllRecording()
            if !conflicts.isEmpty {
                showDragConflict(conflicts)
                return true
            }
            ctx.setDragSnapTrigger(DragSnapTrigger(keyCode: keyCode, modifiers: mods))
            refresh()
            return true

        case .flagsChanged:
            let mods = ShortcutKit.carbonModifiers(from: event.modifierFlags)
            guard mods != 0 else {
                if let pending = pendingModifierOnly {
                    stopAllRecording()
                    ctx.setDragSnapTrigger(DragSnapTrigger(keyCode: nil, modifiers: pending))
                    refresh()
                    return true
                }
                modifierOnlyTimer?.invalidate()
                modifierOnlyTimer = nil
                return true
            }

            pendingModifierOnly = preferredModifierOnlyCandidate(current: pendingModifierOnly, new: mods)
            modifierOnlyTimer?.invalidate()
            modifierOnlyTimer = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: false) { [weak self] _ in
                guard let self, self.isRecordingDrag, let mods = self.pendingModifierOnly else { return }
                self.stopAllRecording()
                self.ctx.setDragSnapTrigger(DragSnapTrigger(keyCode: nil, modifiers: mods))
                self.refresh()
            }
            return true

        default:
            return false
        }
    }

    private func preferredModifierOnlyCandidate(current: Int?, new: Int) -> Int {
        guard let current else { return new }
        return new.nonzeroBitCount >= current.nonzeroBitCount ? new : current
    }

    private func confirmConflict(_ conflicts: [String]) -> Bool {
        let names = conflicts.map(displayName(for:))
        let alert = NSAlert()
        alert.messageText = "Shortcut already in use"
        alert.informativeText = "This combo is assigned to: \(names.joined(separator: ", ")). Reassign it here? The other action becomes unassigned."
        alert.addButton(withTitle: "Reassign")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func dragBindConflicts(keyCode: Int, modifiers: Int) -> Bool {
        dragTrigger.keyCode == keyCode && dragTrigger.modifiers == modifiers
    }

    private func showDragBindConflict() {
        let alert = NSAlert()
        alert.messageText = "Shortcut already in use"
        alert.informativeText = "This combo is assigned to the drag bind. Choose a different shortcut or change the drag bind in General."
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func showDragConflict(_ conflicts: [String]) {
        let names = conflicts.map(displayName(for:))
        let alert = NSAlert()
        alert.messageText = "Drag bind already in use"
        alert.informativeText = "This key combination is already assigned to: \(names.joined(separator: ", ")). Choose a different drag bind so dragging does not trigger a shortcut."
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func displayName(for id: String) -> String {
        ShortcutKit.quickActions.first(where: { $0.id == id })?.label
            ?? ZoneAction.zeroBasedIndex(from: id).map { "Zone \($0 + 1)" }
            ?? id
    }
}

private struct SettingsRootView: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        TabView(selection: $model.selectedTab) {
            GeneralSettingsView(model: model)
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(SettingsTab.general)
            ShortcutsSettingsView(model: model)
                .tabItem { Label("Shortcuts", systemImage: "keyboard") }
                .tag(SettingsTab.shortcuts)
            AboutSettingsView()
                .tabItem { Label("About", systemImage: "info.circle") }
                .tag(SettingsTab.about)
        }
        .padding(.top, 12)
        .padding(.horizontal, 24)
        .padding(.bottom, 20)
        .frame(minWidth: 560, minHeight: 440)
        .tint(Color(nsColor: Brand.blue))
    }
}

private struct GeneralSettingsView: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                SettingsSectionView("Permissions") {
                    SettingsRow(
                        title: "Accessibility",
                        detail: "Required so Lineup can move and resize windows.") {
                        HStack(spacing: 10) {
                            Label(
                                model.accessibilityGranted ? "Granted" : "Not granted",
                                systemImage: model.accessibilityGranted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
                            )
                            .foregroundStyle(model.accessibilityGranted ? Color.secondary : Color.orange)

                            if !model.accessibilityGranted {
                                Button("Open System Settings") {
                                    model.requestAccessibility()
                                }
                            }
                        }
                    }
                }

                SettingsSectionView("Behavior") {
                    SettingsRow(
                        title: "Drag to snap",
                        detail: "Hold the drag bind while dragging a window.") {
                        Toggle("", isOn: Binding(
                            get: { model.dragSnapOn },
                            set: { model.setDragSnapOn($0) }))
                        .labelsHidden()
                        .toggleStyle(.switch)
                    }

                    SettingsRow(
                        title: "Drag bind",
                        detail: "Click to record a key or modifier combo.") {
                        HStack(spacing: 8) {
                            RecorderButton(
                                text: model.dragTriggerDisplay,
                                emptyText: "Click to set",
                                isRecording: model.isRecordingDrag,
                                enabled: model.canWrite,
                                accessibilityLabel: "Drag snap bind",
                                action: { model.beginDragRecording() })

                            CircleClearButton(
                                help: "Reset drag bind to Shift",
                                accessibilityLabel: "Reset drag bind to Shift",
                                disabled: !model.canWrite
                            ) {
                                model.resetDragBind()
                            }
                        }
                    }

                    SettingsRow(
                        title: "Show in menu bar",
                        detail: "Open Lineup again from Applications or Spotlight to return to Settings.") {
                        Toggle("", isOn: Binding(
                            get: { model.menuBarIconShown },
                            set: { model.setMenuBarIconShown($0) }))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .disabled(!model.canWrite)
                        .accessibilityLabel("Show in menu bar")
                    }

                    SettingsRow(
                        title: "Launch at login",
                        detail: "Start Lineup automatically when you sign in.") {
                        Toggle("", isOn: Binding(
                            get: { model.launchAtLoginOn },
                            set: { model.setLaunchAtLoginOn($0) }))
                        .labelsHidden()
                        .toggleStyle(.switch)
                    }
                }

                if !model.canWrite {
                    SettingsSectionView("Configuration") {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: "lock.fill")
                                .foregroundStyle(.secondary)
                            Text(model.blockedMessage ?? "Editing is disabled.")
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .font(.callout)
                    }
                }
            }
            .frame(width: settingsContentWidth, alignment: .leading)
            .padding(.top, 24)
            .padding(.bottom, 18)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

private struct SettingsSectionView<Content: View>: View {
    private let title: String
    private let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.headline)
            VStack(spacing: 0) {
                content
            }
            .padding(.vertical, 2)
        }
    }
}

private struct SettingsRow<Content: View>: View {
    var title: String
    var detail: String?
    var content: Content

    init(title: String, detail: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.detail = detail
        self.content = content()
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 18) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                    if let detail {
                        Text(detail)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 24)
                content
            }
            .frame(minHeight: 44)
            .padding(.vertical, 6)

            Divider()
                .padding(.leading, 0)
        }
    }
}

private struct ShortcutsSettingsView: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Text("Click a shortcut, then press a key combo. Esc cancels, Delete clears.")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                if !model.canWrite {
                    Label(model.blockedMessage ?? "Editing is disabled.", systemImage: "lock.fill")
                        .font(.callout)
                        .foregroundStyle(.orange)
                }

                SettingsSectionView("Window") {
                    ForEach(model.quickShortcutRows) { row in
                        ShortcutSettingsRow(row: row, model: model)
                    }
                }

                SettingsSectionView("Zones") {
                    ForEach(model.zoneShortcutRows) { row in
                        ShortcutSettingsRow(row: row, model: model)
                    }
                }
            }
            .frame(width: settingsContentWidth, alignment: .leading)
            .padding(.top, 20)
            .padding(.bottom, 18)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

private struct ShortcutSettingsRow: View {
    let row: ShortcutRow
    @ObservedObject var model: SettingsModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text(row.label)
                Spacer(minLength: 24)
                RecorderButton(
                    text: model.shortcutDisplay(for: row.id),
                    emptyText: "Click to set",
                    isRecording: model.recordingAction == row.id,
                    enabled: model.canWrite,
                    accessibilityLabel: "\(row.label) shortcut",
                    action: { model.beginShortcutRecording(row.id) })

                CircleClearButton(
                    help: "Clear shortcut",
                    accessibilityLabel: "Clear shortcut for \(row.label)",
                    disabled: !model.canWrite || model.shortcutDisplay(for: row.id).isEmpty
                ) {
                    model.clearShortcut(row.id)
                }
            }
            .frame(minHeight: 38)
            .padding(.vertical, 4)

            Divider()
        }
    }
}

private struct CircleClearButton: View {
    var help: String
    var accessibilityLabel: String
    var disabled: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark.circle.fill")
                .imageScale(.medium)
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .help(help)
        .disabled(disabled)
        .accessibilityLabel(accessibilityLabel)
    }
}

private struct RecorderButton: View {
    var text: String
    var emptyText: String
    var isRecording: Bool
    var enabled: Bool
    var accessibilityLabel: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(labelText)
                .font(.system(size: 13, weight: text.isEmpty ? .regular : .medium))
                .foregroundStyle(isRecording || !text.isEmpty ? .primary : .secondary)
                .lineLimit(1)
                .frame(width: 164)
        }
        .buttonStyle(.bordered)
        .controlSize(.regular)
        .disabled(!enabled)
        .help(isRecording ? "Press keys" : accessibilityLabel)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(isRecording ? "Recording" : (text.isEmpty ? "Not set" : text))
    }

    private var labelText: String {
        if isRecording { return "Press keys..." }
        return text.isEmpty ? emptyText : text
    }
}

private struct AboutSettingsView: View {
    var body: some View {
        VStack(spacing: 18) {
            Image(nsImage: appIcon())
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 84, height: 84)
                .accessibilityHidden(true)

            VStack(spacing: 3) {
                Text("Lineup")
                    .font(.title2.weight(.semibold))
                Text(versionLine())
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if let buildDate = buildDateLine() {
                    Text(buildDate)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            VStack(spacing: 8) {
                Link("lineup.caiano.com", destination: URL(string: "https://lineup.caiano.com")!)
                Link("github.com/hcaiano/lineup", destination: URL(string: "https://github.com/hcaiano/lineup")!)
            }

            Button("Check for Updates...") {
                AppUpdater.shared.checkForUpdates(nil)
            }

            Text("Copyright 2026 Henrique Caiano. MIT License.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.top, 16)
    }

    private func appIcon() -> NSImage {
        if let icon = NSImage(named: "AppIcon") { return icon }
        let path = Bundle.main.bundlePath
        if path.hasSuffix(".app") { return NSWorkspace.shared.icon(forFile: path) }
        return NSApplication.shared.applicationIconImage
    }

    private func versionLine() -> String {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "0.0.0"
        let build = info["CFBundleVersion"] as? String ?? "0"
        return "Version \(version) (\(build))"
    }

    private func buildDateLine() -> String? {
        guard
            let url = Bundle.main.executableURL,
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey]),
            let date = values.contentModificationDate
        else { return nil }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return "Built \(formatter.string(from: date))"
    }
}

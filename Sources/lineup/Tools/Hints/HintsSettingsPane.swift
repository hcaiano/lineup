import AppCore
import AppKit
import HintsCore
import SwiftUI

/// Pane-local state for Hints settings. HintsTool remains the only persistence owner; this model
/// keeps drafts honest, restores committed values after a refused write, and snapshots cross-tool
/// conflicts once when shortcut recording begins.
@MainActor
final class HintsSettingsPaneModel: ObservableObject {
    struct AlertItem: Identifiable {
        let id = UUID()
        let title: String
        let message: String
    }

    @Published private(set) var settings: HintsSettings
    @Published var alphabetDraft: String
    @Published private(set) var canEdit = false
    @Published private(set) var storeBlockedMessage: String?
    @Published private(set) var sectionLoadErrorMessage: String?
    @Published private(set) var isAccessibilityTrusted = false
    @Published var alert: AlertItem?

    private unowned let tool: HintsTool
    private var boundCombos: [ToolCombo] = []
    var toolDisplayName: (ToolID) -> String = { $0.rawValue.capitalized }

    init(tool: HintsTool) {
        self.tool = tool
        let snapshot = tool.settingsSnapshot
        settings = snapshot
        alphabetDraft = snapshot.alphabet
        refresh()
    }

    var shortcutDisplay: String {
        guard let shortcut = assignedShortcut else { return "" }
        return ShortcutKit.display(keyCode: shortcut.keyCode, modifiers: shortcut.modifiers)
    }

    var hasAssignedShortcut: Bool { assignedShortcut != nil }

    var alphabetValidationMessage: String? {
        do {
            _ = try HintLabelMaker(alphabet: alphabetDraft)
            return nil
        } catch let error as HintLabelMaker.LabelError {
            switch error {
            case .emptyAlphabet:
                return "Enter at least one letter."
            case .invalidCharacter:
                return "Use letters A through Z only."
            case .duplicateCharacter:
                return "Use each letter once, ignoring case."
            case .nonPositiveMaxLength, .overflow:
                return "Use one or more unique letters A through Z."
            }
        } catch {
            return "Use one or more unique letters A through Z."
        }
    }

    var canSaveAlphabet: Bool {
        canEdit && alphabetValidationMessage == nil && alphabetDraft != settings.alphabet
    }

    /// Refreshes live permission/blocking state. Returning from System Settings preserves a draft
    /// the user has not saved, while an ordinary pane appearance starts from committed settings.
    func refresh(preservingAlphabetDraft: Bool = false) {
        let previousAlphabet = settings.alphabet
        let hadDraft = alphabetDraft != previousAlphabet
        let snapshot = tool.settingsSnapshot
        settings = snapshot
        if !preservingAlphabetDraft || !hadDraft {
            alphabetDraft = snapshot.alphabet
        }
        canEdit = tool.canEditSettings
        storeBlockedMessage = tool.storeBlockedMessage
        sectionLoadErrorMessage = tool.sectionLoadErrorMessage
        isAccessibilityTrusted = tool.isAccessibilityTrusted
    }

    func discardAlphabetDraft() {
        alphabetDraft = settings.alphabet
    }

    /// Called only when a new recording starts. `boundCombos()` may decode every tool section, so
    /// this snapshot is intentionally never rebuilt per keystroke.
    func prepareForRecording() {
        boundCombos = tool.boundCombos()
    }

    func handleShortcutCapture(_ capture: ShortcutRecorder.Capture) {
        guard canEdit else { return }
        switch capture {
        case .clear:
            guard hasAssignedShortcut else { return }
            saveShortcut(nil)

        case .modifiersOnly:
            // Hints uses the recorder's combo-only rules. Keep this fail-closed if a future caller
            // accidentally supplies a modifier-only capture.
            NSSound.beep()

        case .combo(let keyCode, let modifiers):
            if let owner = boundCombos.conflictOwner(
                keyCode: keyCode,
                modifiers: modifiers,
                excluding: .hints
            ) {
                alert = AlertItem(
                    title: "Shortcut already in use",
                    message: "This combo is used by \(toolDisplayName(owner)). Choose a different "
                        + "shortcut, or change it in that tool’s settings."
                )
                return
            }
            saveShortcut(HintShortcut(keyCode: keyCode, modifiers: modifiers))
        }
    }

    func clearShortcut() {
        guard canEdit, hasAssignedShortcut else { return }
        saveShortcut(nil)
    }

    func saveAlphabet() {
        guard canSaveAlphabet else { return }
        do {
            accept(try tool.updateAlphabet(alphabetDraft), preservingAlphabetDraft: false)
        } catch {
            // The alphabet draft is the value whose save failed. Revert it as well as the
            // settings snapshot so the editor cannot keep showing an unpersisted alphabet.
            springBackToCommittedSettings(preservingAlphabetDraft: false)
            alert = AlertItem(
                title: "Couldn’t save the label alphabet",
                message: error.localizedDescription
            )
        }
    }

    func openAccessibilitySettings() {
        tool.openAccessibilitySettings()
        refresh(preservingAlphabetDraft: true)
    }

    private var assignedShortcut: HintShortcut? {
        guard let shortcut = settings.activationShortcut, shortcut.isAssigned else { return nil }
        return shortcut
    }

    private func saveShortcut(_ shortcut: HintShortcut?) {
        do {
            accept(try tool.updateActivationShortcut(shortcut), preservingAlphabetDraft: true)
        } catch {
            // Only the shortcut write failed. Reload its committed value, but keep a separate
            // alphabet draft the user has not tried to save or discard.
            springBackToCommittedSettings(preservingAlphabetDraft: true)
            alert = AlertItem(
                title: "Couldn’t save the activation shortcut",
                message: error.localizedDescription
            )
        }
    }

    private func accept(_ committed: HintsSettings, preservingAlphabetDraft: Bool) {
        let hadDraft = alphabetDraft != settings.alphabet
        settings = committed
        if !preservingAlphabetDraft || !hadDraft {
            alphabetDraft = committed.alphabet
        }
        canEdit = tool.canEditSettings
        storeBlockedMessage = tool.storeBlockedMessage
        sectionLoadErrorMessage = tool.sectionLoadErrorMessage
        isAccessibilityTrusted = tool.isAccessibilityTrusted
    }

    private func springBackToCommittedSettings(preservingAlphabetDraft: Bool) {
        let hadDraft = alphabetDraft != settings.alphabet
        let committed = tool.settingsSnapshot
        settings = committed
        if !preservingAlphabetDraft || !hadDraft {
            alphabetDraft = committed.alphabet
        }
        canEdit = tool.canEditSettings
        storeBlockedMessage = tool.storeBlockedMessage
        sectionLoadErrorMessage = tool.sectionLoadErrorMessage
        isAccessibilityTrusted = tool.isAccessibilityTrusted
    }
}

/// Settings › Hints. The shell owns the title and enable switch; this pane stays visible while the
/// tool is disabled so the user can choose a shortcut before turning it on.
struct HintsSettingsPane: View {
    @EnvironmentObject private var settingsStore: SettingsStore
    @StateObject private var model: HintsSettingsPaneModel

    @MainActor
    init(tool: HintsTool) {
        _model = StateObject(wrappedValue: HintsSettingsPaneModel(tool: tool))
    }

    var body: some View {
        HintsSettingsPaneBody(model: model, settingsStore: settingsStore)
    }
}

private struct HintsSettingsPaneBody: View {
    @ObservedObject var model: HintsSettingsPaneModel
    @StateObject private var recorder: ShortcutRecorder
    private let settingsStore: SettingsStore

    private static let activationRecorderID = "hints.activation"

    @MainActor
    init(model: HintsSettingsPaneModel, settingsStore: SettingsStore) {
        self.model = model
        self.settingsStore = settingsStore
        _recorder = StateObject(wrappedValue: ShortcutRecorder(store: settingsStore))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // These are independent conditions. Store, section, and permission warnings can
            // coexist, and Accessibility setup remains useful even while Hints is switched off.
            if model.storeBlockedMessage != nil
                || model.sectionLoadErrorMessage != nil
                || !model.isAccessibilityTrusted {
                PinnedBannerStrip {
                    if let message = model.storeBlockedMessage {
                        BlockedBanner(message: message)
                    }
                    if model.sectionLoadErrorMessage != nil {
                        BlockedBanner(
                            message: "Your Hints settings couldn’t be read. They were left "
                                + "unchanged, so editing is off until Lineup settings are reset.",
                            systemImage: "exclamationmark.triangle.fill"
                        )
                    }
                    if !model.isAccessibilityTrusted {
                        BlockedBanner(
                            message: "Accessibility is required for Hints to find and use controls "
                                + "exposed by the frontmost app.",
                            systemImage: "exclamationmark.triangle.fill",
                            actionTitle: "Open System Settings…",
                            action: {
                                recorder.cancel()
                                model.openAccessibilitySettings()
                            }
                        )
                    }
                }
            }

            ScrollView {
                VStack(alignment: .leading, spacing: SettingsMetrics.sectionSpacing) {
                    shortcutSection
                    alphabetSection
                    accessibilitySection
                    keyboardSection
                    supportedSurfacesSection
                }
                .frame(width: SettingsMetrics.contentWidth, alignment: .leading)
                .padding(.vertical, SettingsMetrics.panePaddingVertical)
                .frame(maxWidth: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .navigationTitle("Hints")
        .onAppear {
            model.refresh()
            model.toolDisplayName = { [weak settingsStore] id in
                settingsStore?.displayName(for: id) ?? id.rawValue.capitalized
            }
        }
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification
        )) { _ in
            model.refresh(preservingAlphabetDraft: true)
        }
        .onDisappear {
            recorder.cancel()
            model.discardAlphabetDraft()
        }
        .alert(item: $model.alert) { alert in
            Alert(
                title: Text(alert.title),
                message: Text(alert.message),
                dismissButton: .default(Text("OK"))
            )
        }
    }

    private var shortcutSection: some View {
        SettingsSectionView(
            "Shortcut",
            caption: "Press a key with at least one modifier. Esc cancels recording; Delete clears."
        ) {
            SettingsRow(
                title: "Activation shortcut",
                detail: "Shows hints for controls in the frontmost app."
            ) {
                HStack(spacing: 8) {
                    ShortcutField(
                        text: model.shortcutDisplay,
                        isRecording: recorder.isRecording(Self.activationRecorderID),
                        emptyText: "Set Shortcut",
                        accent: Color(nsColor: Brand.blue),
                        enabled: model.canEdit,
                        accessibilityLabel: "Hints activation shortcut",
                        rejectionCount: recorder.rejectionCount
                    ) {
                        if !recorder.isRecording(Self.activationRecorderID) {
                            model.prepareForRecording()
                        }
                        recorder.toggle(Self.activationRecorderID, options: .combo) { capture in
                            model.handleShortcutCapture(capture)
                        }
                    }

                    CircleClearButton(
                        help: "Clear Hints activation shortcut",
                        accessibilityLabel: "Clear Hints activation shortcut",
                        disabled: !model.canEdit || !model.hasAssignedShortcut,
                        action: {
                            recorder.cancel()
                            model.clearShortcut()
                        }
                    )
                }
            }
        }
    }

    private var alphabetSection: some View {
        SettingsSectionView(
            "Hint labels",
            caption: "Use letters A through Z. Each letter can appear once, ignoring case."
        ) {
            SettingsRow(
                title: "Label alphabet",
                detail: "Lineup uses these letters to build fixed-length hint labels."
            ) {
                HintsSettingsAlphabetEditor(
                    model: model,
                    cancelRecording: { recorder.cancel() }
                )
            }
        }
    }

    private var accessibilitySection: some View {
        SettingsSectionView("Permission") {
            SettingsRow(
                title: "Accessibility",
                detail: model.isAccessibilityTrusted
                    ? "Granted. Hints can read and use exposed controls."
                    : "Required to find and use exposed controls."
            ) {
                HStack(spacing: 12) {
                    HintsSettingsPermissionStatus(granted: model.isAccessibilityTrusted)
                    Button("Open System Settings…") {
                        recorder.cancel()
                        model.openAccessibilitySettings()
                    }
                    .help("Open Accessibility settings")
                    .accessibilityLabel("Open Accessibility settings")
                }
            }
        }
    }

    private var keyboardSection: some View {
        SettingsSectionView("Keyboard") {
            HintsKeyboardHelpView(alphabet: model.settings.alphabet)
        }
    }

    private var supportedSurfacesSection: some View {
        SettingsSectionView("Supported controls") {
            SettingsCaption(
                text: "Hints works with controls the frontmost app exposes through macOS "
                    + "Accessibility. Safari, Chromium browsers, and Electron apps are best "
                    + "effort, so some controls may not appear."
            )
        }
    }
}

private struct HintsSettingsAlphabetEditor: View {
    @ObservedObject var model: HintsSettingsPaneModel
    let cancelRecording: () -> Void

    var body: some View {
        VStack(alignment: .trailing, spacing: 5) {
            HStack(spacing: 8) {
                TextField(
                    "Label alphabet",
                    text: $model.alphabetDraft,
                    onEditingChanged: { editing in
                        if editing { cancelRecording() }
                    }
                )
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced).weight(.medium))
                    .frame(width: 156)
                    .disabled(!model.canEdit)
                    .help("Use unique letters A through Z")
                    .accessibilityLabel("Hint label alphabet")
                    .accessibilityHelp("Use one or more unique letters A through Z.")
                    .onSubmit {
                        cancelRecording()
                        model.saveAlphabet()
                    }

                Button("Save") {
                    cancelRecording()
                    model.saveAlphabet()
                }
                    .disabled(!model.canSaveAlphabet)
                    .help("Save hint label alphabet")
                    .accessibilityLabel("Save hint label alphabet")
            }

            if let message = model.alphabetValidationMessage {
                HStack(spacing: 5) {
                    Image(systemName: "exclamationmark.circle.fill")
                        .foregroundStyle(.orange)
                        .accessibilityHidden(true)
                    Text(message)
                        .foregroundStyle(.secondary)
                }
                .font(.caption)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Invalid alphabet. \(message)")
            }
        }
    }
}

private struct HintsSettingsPermissionStatus: View {
    let granted: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(granted ? Color(nsColor: Brand.blue) : Color.orange)
                .accessibilityHidden(true)
            Text(granted ? "Granted" : "Not granted")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(granted ? "Accessibility granted" : "Accessibility not granted")
    }
}

private struct HintsKeyboardHelpView: View {
    let alphabet: String

    var body: some View {
        VStack(spacing: 0) {
            helpRow(
                key: alphabetSample,
                spokenKey: "Label letters",
                detail: "Type a hint label to narrow the visible controls."
            )
            Divider()
            helpRow(
                key: "↩",
                spokenKey: "Return",
                detail: "Use the selected control."
            )
            Divider()
            helpRow(
                key: "/",
                spokenKey: "Slash",
                detail: "Search accessible control names."
            )
            Divider()
            helpRow(
                key: "Space",
                spokenKey: "Space",
                detail: "Choose a scroll area, then use arrows, Page Up, Page Down, Home, or End."
            )
            Divider()
            helpRow(
                key: "Esc",
                spokenKey: "Escape",
                detail: "Cancel Hints. Pressing the activation shortcut again also cancels."
            )
        }
        .padding(.bottom, -SettingsMetrics.dividerThickness)
        .clipped()
        .padding(.vertical, 2)
    }

    private var alphabetSample: String {
        let uppercase = alphabet.uppercased()
        guard uppercase.count > 7 else { return uppercase }
        return String(uppercase.prefix(7)) + "…"
    }

    private func helpRow(key: String, spokenKey: String, detail: String) -> some View {
        HStack(alignment: .center, spacing: 18) {
            KeyCapRow(display: key)
                .frame(width: 136, alignment: .leading)
            Text(detail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .frame(minHeight: SettingsMetrics.rowHeight)
        .padding(.vertical, 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(spokenKey). \(detail)")
    }
}
